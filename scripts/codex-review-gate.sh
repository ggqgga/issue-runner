#!/usr/bin/env bash
# codex-review-gate.sh — Codex **내장 리뷰어**(`codex exec review`)로 머지 게이트 판정을 낸다.
# 설계: Plans/codex-native-review-gate.md (#134). rescue 서브에이전트의 프롬프트 리뷰를 대체한다
# (2026-09-07 실측: 같은 커밋에서 프롬프트 리뷰 실 결함 0 vs 내장 리뷰어 1~3건).
#
#   codex-review-gate.sh (--base <ref> | --commit <sha> | --uncommitted | --prompt <text>)
#                        [--model M] [--effort E] [--out <dir>] [--cd <repo-dir>]
#
# 실행: codex exec review <스코프> -m M -c model_reasoning_effort='"E"' --ephemeral --json -o <out>/review.md
#       + 절감 오버라이드(web_search 끔·memories 생성 끔·reasoning 숨김). 리뷰는 작업 트리를 바꾸지 않는다.
# 판정 입력은 **codex 구조 신호**뿐이다 — 모델 문장은 읽지 않는다(설계:
# Plans/review-round-cap-and-gate-signals.md §규칙 ②, 사람 결정 2026-09-13):
#   ① 리뷰 본문에 렌더된 항목(`- [P<n>] 제목 — 파일:줄`) ≥1 → `[P1]`(P0 포함) BLOCKER ·
#      `[P2]` WARN · `[P3]`+ NIT. 항목은 파일:줄을 달고 나오므로 그 자체가 "읽었다"의 증거다.
#   ② 항목 0 이고 본문에 `REVIEW_STATUS: no-basis` **줄 전체**가 있으면 미산출 — 리뷰어가
#      스스로 근거 없음을 밝힌 **선택** 신호다(프롬프트 힌트로 권하되 요구하지 않는다).
#   ③ 항목 0 → `--json` 이벤트 스트림(<out>/events.jsonl)의 `item.completed`·`command_execution`
#      기록 중 `command` 에 `git ` 또는 `--cd` 경로가 든 것이 ≥1 이면 CLEAN, 아니면 미산출
#      ("읽지 않은 문제 없음" 은 판정이 아니다 — fail-closed). `--prompt` 유무 두 경로 동일.
# 옛 응답 계약(역사 한 문단): #207 → #283 → #279 → #280 은 "리뷰 본문 **마지막 줄**이
# `REVIEW_STATUS: reviewed|no-basis` 여야 하고 아니면 미산출" 이라는 계약으로 같은 구분(안 본
# CLEAN 걸러내기)을 하려 했다. 그 조건은 못 맞출 시험이었다 — 프로덕션 크기 프롬프트(10~30KB)에서
# 모델은 그 줄을 내지 않는다(2026-09-13 실호출 0/4 · 2026-09-11 0/4; 짧은 스모크만 1/1). 리뷰어는
# 매번 판정을 냈고 버린 쪽은 게이트였다. 그래서 계약 줄 파서(contract_re)·모델 통제 구역 awk
# (cli_rendered)·렌더 헤더 상수(RENDER_HEADER_*)·산문 휴리스틱(LEGACY_UNABLE)을 전부 걷어내고
# 판정 입력을 위 셋으로 옮겼다. 남은 `no-basis` 는 요구가 아니라 선택 신호다.
# 출력: 진행은 stderr. stdout **마지막 줄** `verdict=<BLOCKER|WARN|NIT|CLEAN> p1=<n> p2=<n> p3=<n> model=<M> secs=<t>`
#       (호출자가 파싱). 본문은 <out>/review.md (기본 out = mktemp -d, 경로를 stderr 에 찍는다).
# 종료: 0 = 비차단(CLEAN/NIT/WARN) · 1 = BLOCKER · 2 = 리뷰 미산출(codex 부재·모델 오류·타임아웃·본문 없음 ·
#       항목 0 인데 no-basis 줄이 있거나 명령 실행 기록이 0 —
#       fail-closed, 호출자는 general-purpose 폴백) · 64 = usage.
# 타임아웃: CODEX_GATE_TIMEOUT 초(기본 900). 모델 오류(404·not supported·requires a newer version)는 원문을
# stderr 에 남기고 `codex debug models` 안내. macOS bash 3.2 · 결정론 · 네트워크는 codex 호출뿐.
set -u

MODEL="${CODEX_GATE_MODEL:-gpt-5.6-sol}"
EFFORT="${CODEX_GATE_EFFORT:-medium}"
TIMEOUT="${CODEX_GATE_TIMEOUT:-900}"
OUT=""; CD=""; SCOPE=(); PROMPT=""

# ── 리뷰어가 쓸 수 있는 구조 신호의 형식 — **여기가 유일한 정의 자리**. 프롬프트 힌트와
# 판정부 파서가 둘 다 이 상수로 만들어진다: 쓰라고 한 형식과 읽는 형식이 갈릴 수 없다.
# (`STATUS_KEY`·`STATUS_NO_BASIS` 두 값은 bin/ci 의 "문서에 하드코딩 금지" 검사도 읽는다.)
STATUS_KEY='REVIEW_STATUS'
STATUS_NO_BASIS='no-basis'
# 프롬프트에 얹는 **힌트 한 문단** — 요구가 아니다. 이 줄이 없어도 판정은 구조 신호로 난다.
# 이게 막는 것은 하나다: 못 읽었을 때 발견을 **지어내는** 것 — 지어낸 항목은 ① 로 판정되어 버리므로
# 구조 신호로는 걸러지지 않는다(그래서 요구가 아니라 힌트로 남긴다).
STATUS_CONTRACT_TEXT="참고 — 지정된 범위의 diff 를 실제로 읽지 못했으면 발견을 지어내지 말고 \`${STATUS_KEY}: ${STATUS_NO_BASIS}\` 한 줄만 써라."

usage() {
  printf 'usage: codex-review-gate.sh (--base <ref> | --commit <sha> | --uncommitted | --prompt <text>) [--model M] [--effort E] [--out <dir>] [--cd <dir>]\n' >&2
  exit 64
}
log() { printf 'codex-gate: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base)        SCOPE=(--base "${2:?}"); shift 2 ;;
    --commit)      SCOPE=(--commit "${2:?}"); shift 2 ;;
    --uncommitted) SCOPE=(--uncommitted); shift ;;
    --prompt)      PROMPT="${2:?}"; shift 2 ;;
    --model)       MODEL="${2:?}"; shift 2 ;;
    --effort)      EFFORT="${2:?}"; shift 2 ;;
    --out)         OUT="${2:?}"; shift 2 ;;
    --cd)          CD="${2:?}"; shift 2 ;;
    *) usage ;;
  esac
done
[ ${#SCOPE[@]} -gt 0 ] || [ -n "$PROMPT" ] || usage
# codex 는 스코프 플래그와 커스텀 프롬프트를 동시에 안 받는다 — --prompt 에 --base/--commit 을 같이 주면
# 그 범위를 프롬프트 머리에 명시해 넘긴다(계획 부합 검토가 커밋된 diff 를 실제로 보게 — 안 그러면 작업 트리만 본다).
if [ -n "$PROMPT" ] && [ ${#SCOPE[@]} -gt 0 ]; then
  case "${SCOPE[0]}" in
    --base)   PROMPT="Review ONLY the committed changes \`git diff ${SCOPE[1]}...HEAD\` (run it yourself; ignore the working tree). $PROMPT" ;;
    --commit) PROMPT="Review ONLY the changes introduced by commit ${SCOPE[1]} (\`git show ${SCOPE[1]}\`; run it yourself). $PROMPT" ;;
    *) usage ;;
  esac
  RANGE_CHECK=("${SCOPE[@]}"); SCOPE=()
else
  RANGE_CHECK=("${SCOPE[@]+"${SCOPE[@]}"}")   # bash 3.2: 빈 배열 확장은 set -u 에 걸린다
fi
# 프롬프트가 있는 호출엔 위 힌트를 **끝에** 얹는다(최근성). 판정 순서는 힌트 유무와 무관하다 —
# `--prompt` 없는 내장 스코프 리뷰도 같은 셋(항목 → no-basis 줄 → events 명령 기록)으로 판정한다.
if [ -n "$PROMPT" ]; then
  PROMPT="$PROMPT

$STATUS_CONTRACT_TEXT"
fi

command -v codex >/dev/null 2>&1 || { log "codex CLI 없음 — 폴백(general-purpose)으로"; echo "verdict=NONE p1=0 p2=0 p3=0 model=$MODEL secs=0"; exit 2; }
[ -n "$OUT" ] || OUT=$(mktemp -d)
mkdir -p "$OUT" 2>/dev/null || { log "out 디렉터리 생성 실패: $OUT"; exit 2; }
REVIEW="$OUT/review.md"; EVENTS="$OUT/events.jsonl"; ERR="$OUT/stderr.log"
rm -f "$REVIEW"

# 범위에 변경이 없으면 리뷰를 돌리지 않고 미산출(2) — "볼 게 없어서 깨끗함"이 CLEAN 으로 새지 않게(fail-closed)
none() { echo "verdict=NONE p1=0 p2=0 p3=0 model=$MODEL secs=${1:-0}"; exit 2; }
if [ ${#RANGE_CHECK[@]} -gt 0 ]; then
  g=(git); [ -n "$CD" ] && g=(git -C "$CD")
  case "${RANGE_CHECK[0]}" in
    --base)
      "${g[@]}" rev-parse --verify -q "${RANGE_CHECK[1]}" >/dev/null 2>&1 || { log "base 를 풀 수 없음: ${RANGE_CHECK[1]}"; none; }
      "${g[@]}" diff --quiet "${RANGE_CHECK[1]}...HEAD" 2>/dev/null && { log "변경 없음: ${RANGE_CHECK[1]}...HEAD — 리뷰할 diff 가 없다"; none; } ;;
    --commit)
      [ -n "$("${g[@]}" show --stat --format= "${RANGE_CHECK[1]}" 2>/dev/null)" ] || { log "커밋을 풀 수 없거나 변경 없음: ${RANGE_CHECK[1]}"; none; } ;;
    --uncommitted)
      [ -n "$("${g[@]}" status --porcelain 2>/dev/null)" ] || { log "미커밋 변경 없음"; none; } ;;
  esac
fi

# 실행 — 별도 프로세스 그룹으로 띄운다. `features.code_mode_host` 는 **끄지 않는다**: 리뷰 모드의 도구 실행은 code-mode
# 호스트를 거치므로 끄면 리뷰어가 눈을 감은 채 CLEAN 을 낸다(0.153.4 실측: 0 명령·"execution tool was unavailable").
# 호스트 바이너리(`codex-code-mode-host`)가 없으면 도구 호출마다 협상 타임아웃 ~45s 가 붙는다 — 설치가 답이다(README).
# 실행 — 별도 프로세스 그룹으로 띄워 타임아웃 시 손자(codex 가 띄운 셸)까지 함께 끊는다.
start=$SECONDS
set -m
( if [ -n "$CD" ]; then cd "$CD" || exit 2; fi
  if [ -n "$PROMPT" ]; then
    exec codex exec review "$PROMPT" -m "$MODEL" -c model_reasoning_effort="\"$EFFORT\"" \
      -c web_search='"disabled"' -c memories.generate_memories=false -c hide_agent_reasoning=true \
      --ephemeral --json -o "$REVIEW"
  else
    exec codex exec review "${SCOPE[@]}" -m "$MODEL" -c model_reasoning_effort="\"$EFFORT\"" \
      -c web_search='"disabled"' -c memories.generate_memories=false -c hide_agent_reasoning=true \
      --ephemeral --json -o "$REVIEW"
  fi
) >"$EVENTS" 2>"$ERR" &
child=$!
set +m
rc=0
while :; do
  if ! kill -0 "$child" 2>/dev/null; then wait "$child"; rc=$?; break; fi
  if [ $((SECONDS - start)) -ge "$TIMEOUT" ]; then
    kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
    sleep 1; kill -KILL -- "-$child" 2>/dev/null
    log "타임아웃(${TIMEOUT}s) — 리뷰 미산출(fail-closed). 로그: $ERR"
    echo "verdict=NONE p1=0 p2=0 p3=0 model=$MODEL secs=$TIMEOUT"; exit 2
  fi
  sleep 2
done
secs=$((SECONDS - start))

# 모델·인증 오류는 원문을 그대로 보여준다 — "스톨"로 오진하지 않게(메모리: 5.5 404 · 5.4 not supported · astra newer version)
# **$ERR(=codex 자신의 stderr)만** 본다. $EVENTS 에는 리뷰어가 읽은 파일 내용이 들어가는데, 이 스크립트가 바로
# 아래 패턴 문자열들을 담고 있어 이 레포를 리뷰하면 자기참조로 매번 "모델 오류"가 되어 늘 폴백으로 떨어졌다(#137 실측).
if grep -q -E 'does not exist or you do not have access|not supported when using Codex|requires a newer version of Codex|401 Unauthorized|token invalid' "$ERR" 2>/dev/null; then
  log "모델/인증 오류 — $(grep -o -E '"message":"[^"]{0,140}|status [0-9]{3}[^,]{0,100}' "$ERR" | head -1)"
  log "가용 모델 확인: codex debug models · config 의 model 은 유효 모델로(0.153 은 미설정 시 Astra 기본)"
  echo "verdict=NONE p1=0 p2=0 p3=0 model=$MODEL secs=$secs"; exit 2
fi
if [ "$rc" != 0 ] || [ ! -s "$REVIEW" ]; then
  log "리뷰 미산출(exit $rc, review.md $( [ -s "$REVIEW" ] && echo 있음 || echo 없음)) — fail-closed. 로그: $ERR"
  echo "verdict=NONE p1=0 p2=0 p3=0 model=$MODEL secs=$secs"; exit 2
fi

# 판정 — 내장 리뷰어 항목 형식 `- [P1] 제목 — 파일:줄`. 본문에 항목이 하나도 없으면 CLEAN.
# 판정 ① — 내장 리뷰어 항목 형식 `- [P1] 제목 — 파일:줄`. 항목이 하나라도 있으면 그 집계가 곧 판정이다.
# 항목 = `- ` 로 시작하는 줄 안의 `[P<n>]` 토큰(볼드·번호 변형 허용). 항목 줄에 없는 `[P1]` 언급은 세지 않는다.
# P0 은 P1 과 함께 BLOCKER 로 센다 — 안 그러면 최우선 발견이 어느 카운터에도 안 잡혀 CLEAN 으로 샌다(#137).
ITEM_P1_RE='^\s*[-*]\s.*\[P[01]\]'
ITEM_P2_RE='^\s*[-*]\s.*\[P2\]'
ITEM_P3_RE='^\s*[-*]\s.*\[P[3-9]\]'
p1=$(grep -c -E "$ITEM_P1_RE" "$REVIEW"); p2=$(grep -c -E "$ITEM_P2_RE" "$REVIEW")
p3=$(grep -c -E "$ITEM_P3_RE" "$REVIEW")

# ── 판정 ②③ — 항목이 0 일 때 "읽고 낸 CLEAN" 과 "안 보고 낸 CLEAN" 을 가른다 ──────────
# 이 게이트의 원래 결함은 "CLEAN 이 틀렸다"가 아니라 **둘을 구분하지 못한다**였다(diff 를 한 줄도
# 못 본 리뷰가 항목 0 → CLEAN 으로 통과). 초 수로도 못 가른다(10s vs 30s 가 겹친다). 앞선 네
# 이슈는 그 구분을 **모델이 쓴 문장**에 걸었다 — 한국어 산문 정규식(#207 round2~4) → 고정 계약
# 줄(#207 재심) → 계약 줄의 위치·펜스·어형(#283·#279·#280). 산문 열거는 닫히지 않고, 계약 줄은
# 모델이 내지 않았다. 그래서 구분자를 **모델 밖**으로 옮긴다: codex 자신이 남긴 실행 기록.
#
# events.jsonl 은 `codex exec … --json` 의 이벤트 스트림이다 — CLI 가 쓴 구조 기록이고 모델
# 문장이 아니다. 한 줄 = 한 이벤트이며 명령 실행 항목은 실측(2026-09-13, 4호출) 이 형태다:
#   {"type":"item.completed","item":{"id":"item_2","type":"command_execution",
#    "command":"/bin/zsh -lc \"git diff --stat base...HEAD\"","aggregated_output":"…",
#    "exit_code":0,"status":"completed"}}
# 호출당 항목이 8~15개였고 `command` 는 전부 `/bin/zsh -lc "git …"` 였다. 그래서 신호는 `command`
# 안의 `git `(주 경로)이거나 `--cd` 로 준 경로(보조 — codex 가 cwd 를 옮긴 뒤라 경로 리터럴은 잘
# 안 나타난다)다. jq 는 쓰지 않는다(없는 박스가 있다) — awk 의 index/substr 로만 읽고, 그래서
# 경로의 정규식 메타문자를 탈출할 일도 없다.
#
# 자기참조 주의(#137 과 같은 함정, 방향은 반대다 — 오탐이면 미산출→CLEAN 이라 fail-open 이다):
# 이 레포를 리뷰하면 리뷰어가 읽은 파일 내용이 이벤트에 실리고 거기엔 위 JSON 리터럴도 들어 있다.
# 그 자리를 막는 것은 **JSON 이스케이프 자체**다 — 문자열 값 안에 실린 텍스트는 `\"type\":…` 로
# 이스케이프돼 있어 아래 이스케이프 없는 `index()` 패턴에 걸리지 않는다. 더해서 한 줄에서 **첫**
# `command` 필드만 읽는다(실 스키마에서 진짜 명령은 `aggregated_output` 앞에 온다) — 남의 텍스트가
# 그 뒤에 뭘 담고 있든 안 본다.
# 줄 **머리**를 봉투 리터럴로 앵커하지는 않는다: 그건 표본 한 판본의 키 순서·감싸개 모양에 판정을
# 걸어, 모양이 조금 바뀌면 발견 0 인 리뷰가 전부 미산출로 접힌다(과잉 차단은 원래 결함보다 나쁘다 —
# 이 게이트가 멈추면 검증 레인이 통째로 정체한다). 포함 검사 + 첫 필드 규칙이면 방향이 안전하다.
review_read_commands() {
  [ -s "$EVENTS" ] || return 0                          # 파일 없음/빈 파일 = 기록 0 줄
  awk -v cd="$CD" '
    # JSON 문자열 값 하나를 p 위치부터 풀어 읽는다(\" 이스케이프를 넘긴다)
    function json_str(s, p,   c, out) {
      out = ""
      for (; p <= length(s); p++) {
        c = substr(s, p, 1)
        if (c == "\\") { p++; out = out substr(s, p, 1); continue }
        if (c == "\"") break
        out = out c
      }
      return out
    }
    {
      if (index($0, "\"type\":\"item.completed\"") == 0) next   # 완료된 이벤트 봉투(codex 저작)만
      if (index($0, "\"type\":\"command_execution\"") == 0) next
      c = index($0, "\"command\":\"")                    # 한 줄의 첫 command 필드만 본다
      if (c == 0) next
      cmd = json_str($0, c + 11)                         # 11 = `"command":"` 길이
      if (index(cmd, "git ") > 0) { print cmd; next }
      if (cd != "" && index(cmd, cd) > 0) print cmd
    }' "$EVENTS" 2>/dev/null
}

if [ "$((p1 + p2 + p3))" -eq 0 ]; then
  # ② no-basis — 줄이 (앞뒤 공백·CR 만 빼고) 그 형식일 때만 신호다. 같은 줄에 다른 텍스트가
  # 있으면 신호가 아니다: 인접·포함은 저작의 증거가 아니라는 이 파일의 규칙 그대로다.
  if grep -qE "^[[:space:]]*${STATUS_KEY}:[[:space:]]*${STATUS_NO_BASIS}[[:space:]]*$" "$REVIEW" 2>/dev/null; then
    log "리뷰어가 근거 없음으로 답함($STATUS_KEY: $STATUS_NO_BASIS) — 미산출(fail-closed): $(head -c 160 "$REVIEW")"
    none "$secs"
  fi
  # ③ 명령 실행 기록
  reads=$(review_read_commands | wc -l | tr -d ' ')
  if [ "${reads:-0}" -gt 0 ]; then
    log "항목 0 · codex 명령 실행 ${reads}건(대상을 열어 봤다) → CLEAN"
  else
    log "항목 0 · events 에 명령 실행 기록 0 — 대상을 열어 본 증거가 없다. 미산출(fail-closed): $EVENTS"
    log "진단: 리뷰 본문 머리 = $(head -c 160 "$REVIEW")"
    none "$secs"
  fi
fi

if   [ "$p1" -gt 0 ]; then verdict=BLOCKER; code=1
elif [ "$p2" -gt 0 ]; then verdict=WARN; code=0
elif [ "$p3" -gt 0 ]; then verdict=NIT; code=0
else verdict=CLEAN; code=0; fi
log "$verdict (P1 $p1 · P2 $p2 · P3+ $p3) · $MODEL/$EFFORT · ${secs}s → $REVIEW"
echo "verdict=$verdict p1=$p1 p2=$p2 p3=$p3 model=$MODEL secs=$secs"
exit "$code"
