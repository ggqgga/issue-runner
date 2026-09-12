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
# 판정(내장 리뷰어 출력은 마크다운 — 요약 문단 + `- [P<n>] 제목 — 파일:줄` 항목; --json 스트림엔 agent_message 텍스트만
# 있고 구조화 findings 는 없다, 0.153.4 실측): 리뷰 본문의 `[P1]` → BLOCKER · `[P2]` → WARN · `[P3]`/기타 항목 → NIT · 항목 0 → CLEAN.
# **응답 계약(구조 신호, #207)** — `--prompt` 호출에 한해 이 스크립트가 프롬프트 끝에 "마지막 줄은
# `<STATUS_KEY>: <STATUS_REVIEWED>|<STATUS_NO_BASIS>`(아래 상수) 여야 한다"는 계약을 덧붙이고, 판정은
# **그 줄로만** 가른다: 값이 `$STATUS_REVIEWED` → 위 항목 집계대로 · `$STATUS_NO_BASIS`/줄 없음/형식
# 깨짐 → `verdict=NONE`(미산출, fail-closed). 그 줄은 **줄 전체**가 그 형식이어야 한다 — 같은 줄에
# 다른 텍스트가 함께 있으면(앞이든 뒤든, 어형 불문) 판정으로 읽지 않는다(#283 재심 ①).
# 그 "마지막 줄"은 **문서의** 마지막 줄이 아니라 **모델 통제 구역의** 마지막 줄이다(#283) — codex 는
# 발견이 있으면 총평 뒤에 자기 헤더(RENDER_HEADER_*)와 항목 목록을 렌더해 붙이므로, 문서의 마지막
# 줄은 모델이 아니라 codex 가 정한다. 문서 기준으로 물었더니 발견을 낸 리뷰만 전부 미산출이 됐다
# (3/3 실측 — CLEAN 만 통과하고 BLOCKER·WARN 은 폴백으로 버려지는 방향).
# 산문(한국어/영어 "판정할 근거가 없다" 류)은 판정 입력이 **아니다** — 어형 열거는 닫히지 않아
# 세 라운드 연속 fail-open 을 냈다(#207 round2~4). 형식 문자열은 아래 STATUS_* 상수 **한 자리**에서
# 정의하고 프롬프트 계약문과 파서가 둘 다 그것을 참조한다(두 자리에 적으면 이 이슈가 고치려던
# SKILL↔템플릿 불일치가 파서 쪽에서 재발한다). `--prompt` 없는 내장 스코프 리뷰는 계약을 실을
# 자리가 없어 main 의 영문 '도구 부재' 휴리스틱(#137)만 유지한다.
# 출력: 진행은 stderr. stdout **마지막 줄** `verdict=<BLOCKER|WARN|NIT|CLEAN> p1=<n> p2=<n> p3=<n> model=<M> secs=<t>`
#       (호출자가 파싱). 본문은 <out>/review.md (기본 out = mktemp -d, 경로를 stderr 에 찍는다).
# 종료: 0 = 비차단(CLEAN/NIT/WARN) · 1 = BLOCKER · 2 = 리뷰 미산출(codex 부재·모델 오류·타임아웃·본문 없음 —
#       fail-closed, 호출자는 general-purpose 폴백) · 64 = usage.
# 타임아웃: CODEX_GATE_TIMEOUT 초(기본 900). 모델 오류(404·not supported·requires a newer version)는 원문을
# stderr 에 남기고 `codex debug models` 안내. macOS bash 3.2 · 결정론 · 네트워크는 codex 호출뿐.
set -u

MODEL="${CODEX_GATE_MODEL:-gpt-5.6-sol}"
EFFORT="${CODEX_GATE_EFFORT:-medium}"
TIMEOUT="${CODEX_GATE_TIMEOUT:-900}"
OUT=""; CD=""; SCOPE=(); PROMPT=""

# ── 응답 계약(구조 신호) 형식 — **여기가 유일한 정의 자리**(#207). 아래 프롬프트 계약문과
# 판정부의 파서가 둘 다 이 상수들로 만들어진다: 요구하는 형식과 읽는 형식이 갈릴 수 없다.
STATUS_KEY='REVIEW_STATUS'
STATUS_REVIEWED='reviewed'
STATUS_NO_BASIS='no-basis'
# ── codex 가 리뷰 문서에 **스스로 덧붙이는** 발견 섹션 헤더(#283 실측) ─────────────
# `codex exec review` 의 산출은 "모델이 쓴 총평" + (발견이 있으면) 헤더 + codex 가 렌더한
# 항목 목록이다. 즉 **문서의 마지막 줄은 모델이 아니라 codex 가 정한다** — 발견이 하나라도
# 있으면 마지막 줄은 항상 항목 본문이라 "마지막 줄 = 계약 줄" 요구는 충족될 수가 없었다
# (이 이슈의 3/3 NONE). 더 나쁜 방향이었다: 발견 0 인 리뷰만 계약을 지킬 수 있어 **CLEAN 은
# 통과하고 BLOCKER·WARN 은 전부 폴백으로 버려졌다.**
# 그래서 판정 창을 "문서의 마지막 줄" → **"모델 통제 구역(= 첫 헤더 앞)의 마지막 줄"** 로
# 옮긴다. 판별 입력은 여전히 산문이 아니라 **구조**다 — codex 자신의 렌더 헤더.
# 두 값은 codex 바이너리에 인접 리터럴로 박혀 있다(0.153.4 `strings` 실측: 단수/복수 두 형태가
# 전부). 헤더는 정확히 일치해야 한다 — 느슨하게 잡으면 총평 속 유사 문장에서 구역이 잘려
# 계약 줄을 놓치고, 놓친 방향은 미산출(fail-closed)이라 조용한 통과로는 새지 않는다.
RENDER_HEADER_ONE='Review comment:'
RENDER_HEADER_MANY='Full review comments:'
STATUS_CONTRACT_TEXT="출력 계약(필수) — 아래를 지키지 않은 응답은 판정이 아니라 **미산출**로 버려지고 리뷰가 다시 돌려진다.
리뷰 본문의 **마지막 줄**은 다음 둘 중 하나와 **정확히 같아야** 한다 — 그 줄에 다른 텍스트를 함께 두지 말고(앞에도 뒤에도), 줄 머리를 들여쓰지 말고(공백·탭 금지), 그 줄 뒤에는 빈 줄이나 닫는 코드펜스 외의 텍스트를 두지 마라(닫는 코드펜스는 리뷰 전체를 하나의 코드펜스로 감쌌을 때만 — 본문 중간에 연 코드펜스 안에 이 줄을 넣지 마라):
${STATUS_KEY}: ${STATUS_REVIEWED}
${STATUS_KEY}: ${STATUS_NO_BASIS}
'${STATUS_REVIEWED}' = 지정된 범위의 변경을 실제로 열어 읽고 판정했다는 뜻이다. 범위를 읽지 못했거나 판정 근거를 얻지 못했으면 '${STATUS_NO_BASIS}' 를 쓰고, 그때는 발견 항목을 지어내지 마라. 키와 값은 위 문자열 그대로 쓰고 값 뒤에 다른 텍스트를 붙이지 마라."

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
# 커스텀 프롬프트에는 응답 계약을 **끝에** 덧붙이고(최근성), 그 호출에서만 구조 줄을 요구한다.
# 내장 스코프 리뷰(--prompt 없음)는 프롬프트를 실을 자리가 없다 — 거기까지 구조 줄을 요구하면
# 모든 correctness 호출이 미산출이 되어 게이트가 통째로 멈춘다.
STATUS_CONTRACT=0
if [ -n "$PROMPT" ]; then
  PROMPT="$PROMPT

$STATUS_CONTRACT_TEXT"
  STATUS_CONTRACT=1
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
# 항목 = `- ` 로 시작하는 줄 안의 `[P<n>]` 토큰(볼드·번호 변형 허용). 항목 줄에 없는 `[P1]` 언급은 세지 않는다.
# P0 은 P1 과 함께 BLOCKER 로 센다 — 안 그러면 최우선 발견이 어느 카운터에도 안 잡혀 CLEAN 으로 샌다(#137).
# 우선순위 집계 — 아래 판정부가 쓴다(`reviewed` 로 계약이 충족된 뒤에만 verdict 로 이어진다).
# 항목 정규식은 **여기가 유일한 정의 자리**다: 아래 구역 경계 판정도 "codex 가 렌더한 항목"을
# 이 셋으로 가린다(#283 반송 회차 3). 두 자리에 적으면 "verdict 를 세는 항목"과 "경계를 만드는
# 항목"이 갈려, 한쪽만 맞는 입력에서 창이 조용히 어긋난다.
ITEM_P1_RE='^\s*[-*]\s.*\[P[01]\]'
ITEM_P2_RE='^\s*[-*]\s.*\[P2\]'
ITEM_P3_RE='^\s*[-*]\s.*\[P[3-9]\]'
p1=$(grep -c -E "$ITEM_P1_RE" "$REVIEW"); p2=$(grep -c -E "$ITEM_P2_RE" "$REVIEW")
p3=$(grep -c -E "$ITEM_P3_RE" "$REVIEW")

# ── 응답 계약 판정(#207 재심 (c) — 구조 신호 요구) ─────────────────────────────
# 이 이슈의 결함은 "CLEAN 이 틀렸다"가 아니라 **"안 본 CLEAN 과 본 CLEAN 을 게이트가 구분하지
# 못한다"** 였다(diff 를 한 줄도 못 본 리뷰가 항목 0 → CLEAN 으로 통과). 초 수로도 못 가른다
# (10s vs 30s 가 겹친다 — 이슈 본문 실측). 앞선 세 라운드는 한국어 산문을 정규식으로 읽어
# "결론이 섰는가"를 가리려다 어형마다 fail-open 을 냈다(round2 캐비엇 · round3 '부합하는지'
# · round4 '부합함을'). 열거는 닫히지 않는다 — 그래서 **구분자를 산문이 아니라 형식에 둔다.**
#
# 규칙(전부 이 한 곳): 계약 줄이 있으면 그 값대로, 없으면 미산출.
#   `$STATUS_KEY: $STATUS_REVIEWED` → 위 항목 집계로 판정(항목 0이면 CLEAN — 과잉 차단 금지:
#      캐비엇 문장이 섞였다는 이유로 접지 않는다. 이슈 Test plan 의 명시 요구다)
#   `$STATUS_KEY: $STATUS_NO_BASIS` → 미산출(리뷰어 스스로 근거 없음을 구조로 밝혔다)
#   줄이 없음 / 형식이 다름        → 미산출(fail-closed — 계약을 어긴 응답은 판정으로 신뢰하지 않는다)
# 미산출은 **통과가 아니라 폴백행**이다(SKILL ③-1: exit 2 → VERIFIER 폴백 → 그것도 미산출이면
# BLOCKER 보류). 그래서 항목이 있는 응답이라도 계약 줄이 없으면 미산출로 접는다 — 옛 반송 f1
# ([P1] 설명문이 산문 패턴에 우연히 걸려 발견이 지워짐)과는 성격이 다르다: 여기서 접히는 것은
# 리뷰어가 **출력 계약 자체를 어긴** 응답뿐이고, 계약을 지킨 발견은 산문과 무관하게 그대로 산다.
#
# ── 신뢰 규칙(#283 재심) — 모델 텍스트에서는 **부분 일치를 신호로 읽지 않는다** ──────
# 이 파서가 모델이 자유롭게 쓴 텍스트에서 읽는 것은 둘뿐이다: ⑴ 신뢰 토큰(계약 줄)
# ⑵ 구조 경계(codex 렌더 섹션의 시작). 두 자리 모두 지금까지 **부분 일치**를 신호로
# 인정했다가 같은 방식으로 fail-open 을 냈다 — ⑴ 은 "줄 안에 계약 형식이 들어 있으면"
# (→ `…못 읽었다. <키>: <값>` 이 CLEAN), ⑵ 는 "헤더 뒤에 항목이 붙어 있으면"
# (→ 모델이 헤더+불릿을 함께 지어내면 그 뒤 면책 문단이 사라져 WARN/NIT). 인접·포함은
# 저작의 증거가 아니다. 그래서 두 자리에 **같은 규칙**을 세운다:
#
#   신호는 그 신호 **전체**가 신호의 형식일 때만 신호다.
#     ⑴ 계약 줄   = 줄 **전체**가 `<키>: <값>` 이어야 한다(같은 줄에 다른 텍스트가 있으면 어형 불문 거절)
#     ⑵ 렌더 섹션 = 헤더부터 **문서 끝까지 전부** codex 렌더(항목 줄 또는 그 들여쓴 본문)여야 한다
#
# ⑵ 가 "접미(suffix)"인 근거는 구조다: codex 는 모델 메시지를 다 받은 **뒤에** 자기 섹션을
# 덧붙여 문서를 조립하므로(0.153.4 실측 구조), 진짜 렌더 뒤에는 모델이 한 글자도 놓을 수
# 없다. 렌더 뒤에 들여쓰지 않은 산문이 한 줄이라도 있으면 그 헤더는 codex 가 쓴 게 아니다.
# 더해서 **중복**도 본다: codex 는 섹션을 하나만 렌더하므로 자격 헤더가 둘 이상이면 어느 쪽이
# CLI 인지 알 수 없다 → 자르지 않는다(모호하면 막는 쪽 = 미산출).
# 두 규칙이 틀리는 방향은 둘 다 fail-closed 다: 신호를 못 알아보면 계약 줄을 못 찾아 미산출
# (폴백)이 되지, 조용한 통과가 되지 않는다.
#
# 위치 판정은 **모델 통제 구역의 마지막 줄**이다(#283). 구역 = 문서 처음부터 위 ⑵ 를 만족하는
# codex 렌더 섹션 **바로 앞**까지 — 그런 섹션이 없으면(발견 0, 또는 헤더 문자열이 모델
# 산문일 때) 문서 전체다. 그 뒤는
# codex 가 조립한 항목 목록이라 모델이 한 글자도 정할 수 없으므로, 거기까지 계약을 물으면
# **발견을 낸 리뷰만 골라 버리는** 게이트가 된다(이 이슈의 3/3).
# 구역 안에서 꼬리에서 벗기는 것은 **빈 줄과 닫는 코드펜스뿐**이고(계약문이 명시한 그 두 가지
# 예외), 그렇게 벗기고 남은 **마지막 한 줄**이 계약 줄이어야 한다. 창을 N줄로 두면 안 된다:
# 계약 줄 뒤에 임의 산문이 와도 통과해 "못 봤다"고 스스로 적은 응답이 CLEAN 으로 샜다
# (#207 attempt4 반송 — 빈 줄은 이미 지워진 뒤라 3줄 창이 허용한 것은 artifact 가 아니라
# 산문 2줄이었다). 그 봉인은 구역을 옮겨도 그대로다: 총평 안에서 계약 줄 뒤에 산문이 오면
# 여전히 미산출이다(격자 4b-2d 가 문다).
# 형식은 관대하지 않다: 키·구분자·값이 STATUS_* 와 정확히 같아야 하고 **값 뒤 꼬리 텍스트도
# 값 앞 같은 줄 텍스트도 형식 위반**이다(위 신뢰 규칙 ⑴ — 줄 전체가 계약 형식이어야 한다).
# 계약 줄 뒤 산문은 곧 미산출이므로, 구 `LEGACY_UNABLE` 산문 휴리스틱이 계약 경로에 없어도
# 그 문구를 단 응답은 여기서 형식으로 접힌다.
#
# **닫는 펜스는 짝으로 가른다(#279).** 맨몸 펜스(``` · ~~~)는 문자열만으로 여닫이가 구분되지
# 않는다 — 계약 줄을 제대로 낸 **뒤** 군더더기 블록을 하나 더 *열고* 잘린 응답의 꼬리도 맨몸
# 펜스이고, 리뷰 전체를 감싼 블록의 *닫는* 줄도 맨몸 펜스다. 그래서 벗기기 전에 본문 처음부터
# 펜스를 세어(아래 awk 한 패스 — 상태기계·새 의존 없음) 그 꼬리 펜스가 **앞에서 열린 블록을
# 닫는 줄인지** 판정하고, **짝이 맞는 것만** 벗긴다. 짝이 없으면(=여는 펜스) 안 벗기므로 마지막
# 줄은 펜스 자신이 되고 → 계약 위반 → 미산출(fail-closed).
# 세는 규칙은 한 반례가 아니라 CommonMark 규칙 자체를 옮긴 것이다(PR#202 교훈):
#   · 펜스는 줄 머리 들여쓰기 **≤3칸**에서만 열고 닫는다. **4칸 이상 들여쓴 줄은 코드 블록
#     본문이라 펜스가 아니다** — 그런 줄을 닫는 펜스로 보고 벗기면 과잉 벗김(= 계약 위반 응답이
#     새는 옛 방향)이다. 줄 머리 탭도 펜스로 보지 않는다(CommonMark 는 탭을 4칸 탭스톱으로
#     펴므로 ≥4 들여쓰기다).
#   · 닫는 펜스는 **정보 문자열을 가질 수 없다**(런 뒤 공백만) — 그래서 "```json" 은 언제나
#     여는 펜스다(#207 attempt8 이 닫은 칸을 이 규칙이 그대로 품는다).
#   · 닫는 펜스는 여는 펜스와 **같은 문자**이고 **같은 길이 이상**이어야 한다 — ``` 로 연 블록은
#     ~~~ 로 안 닫히고, ```` 로 연 블록은 ``` 로 안 닫힌다(길이 부족).
#   · 백틱 **여는** 펜스의 정보 문자열에는 백틱이 올 수 없다(CommonMark). 이 제약이 없으면 줄
#     머리의 인라인 코드 스팬(```예시```)이 여는 펜스로 오인돼 그 뒤가 통째로 코드로 삼켜진다.
# 방향은 명시적으로 정한다: **과잉 차단이 원래 결함보다 나쁘다.** 이 게이트가 멈추면 검증 레인이
# 통째로 정체하므로, 리뷰 전체를 펜스로 감싼 정상 응답(여는 펜스 → 본문 → 계약 줄 → 닫는 펜스)은
# 짝이 맞아 종전대로 벗겨지고 판정이 그대로 산다. 격자(4b-2)가 양방향을 전수로 못박는다.
#
# **짝이 맞아도 리뷰 전체를 감싼 블록의 짝만 벗긴다(#339).** 짝 세기만으로는 안 닫히는 형상이
# 하나 남는다 — 리뷰어가 diff 를 못 열고 계약문을 *되읊는* 응답: "판정 근거를 얻지 못했습니다.
# 계약 형식은 다음과 같습니다:" + 펜스 블록 안의 계약 줄 + 닫는 펜스. 짝이 맞으니 닫는 펜스가
# 벗겨지고 인용된 계약 줄이 마지막 줄로 채택돼 발견 0 → CLEAN(closeout 폴백 검증자 실측 P1).
# 그 응답과 "리뷰 전체를 펜스로 감싼 정상 응답"을 가르는 것은 산문의 뜻이 아니라 **여는 펜스의
# 위치**다: 정상 형태는 구역의 첫 비공백 줄이 여는 펜스이고(모델 산문이 펜스 밖에 없다), 인용
# 형태는 산문 **뒤에** 펜스가 열린다. 그래서 꼬리 닫는 펜스는 그 짝인 여는 펜스가 구역의 첫
# 비공백 줄일 때만 artifact 로 벗긴다. 산문 뒤에 열린 블록의 닫는 펜스는 벗기지 않는다 → 마지막
# 줄이 펜스 자신 → 계약 위반 → 미산출(fail-closed). 산문 정규식으로 되돌아가는 게 아니다(#207·
# #283) — 새 판별 입력도 여전히 구조(펜스 줄의 위치)뿐이다.
# **판정 줄의 선행 공백은 지우지 않는다(#339 두 번째 변종).** 옛 trim() 은 마지막 줄의 양끝
# 공백을 지워, 4칸/탭으로 들여쓴 계약 줄(markdown 코드 블록 인용 — 같은 실측 P2)이 맨몸 계약
# 줄과 같아졌다. 들여쓰기는 인용 표식이다(4b-2e 의 `>`·`-`·`1.`·`##` 과 같은 가족) — 줄 전체
# 규칙(#283 재심 ①) 그대로 선행 공백도 "같은 줄의 다른 텍스트"로 본다. 끝 공백만 벗긴다(꼬리
# artifact — 계약 위반의 표식이 아니다). 리뷰 전체 펜스 안 정상 형태는 들여쓰기 0 이라 회귀 없음.
if [ "$STATUS_CONTRACT" = 1 ]; then
  # 경계 = **CLI 가 쓴 것**일 때만이다(#283 재심 ②). 앞 회차는 "헤더 + 그 뒤에 항목"이면
  # 경계로 봤는데, 헤더도 항목도 **같은 무제약 텍스트**에서 나온다 — 모델이 헤더를 적고 그
  # 아래 `- [P2] …` 한 줄을 지어내면 인접 조건이 충족돼 그 뒤 면책 문단이 판정에서 사라지고
  # WARN/NIT(exit 0 = 게이트 통과)가 났다. 인접은 CLI 저작의 증거가 아니다.
  # 그래서 아래 `cli_rendered()` 한 술어로 **무엇이 codex 렌더인가**를 정의한다(유일한 정의
  # 자리 — 경계 판정과 진단이 같은 값을 읽는다). codex 는 모델 메시지를 다 받은 뒤 자기
  # 섹션을 덧붙여 문서를 조립하므로(0.153.4 실측 구조), 렌더 섹션은 **문서의 접미**다:
  #   ⓐ 헤더 뒤 첫 비공백 줄이 항목이고,                       ← 형식(앞 회차가 세운 조건)
  #   ⓑ 거기부터 **문서 끝까지** 전부 항목 줄이거나 항목 본문(들여쓴 줄)이고,  ← 위치
  #   ⓒ 그런 자격 헤더가 문서에 **정확히 하나**여야 한다.        ← 중복
  # 하나라도 어긋나면 경계가 아니다 = 자르지 않는다(문서 전체가 모델 구역). ⓑ 는 "렌더 뒤에
  # 모델 산문이 있다"를 잡고(모델이 헤더+불릿을 지어낸 뒤 면책을 쓰는 그 형태), ⓒ 는 codex 가
  # 섹션을 하나만 렌더한다는 사실을 쓴다 — 둘 이상이면 어느 쪽이 CLI 인지 알 수 없으므로
  # 모호 = 막는 쪽(미산출)으로 떨어진다.
  # '항목' 의 정의는 위 ITEM_P*_RE — verdict 를 세는 그 정의 그대로다(줄 번호를 awk 에 넘겨
  # 재사용한다: 정규식을 두 자리에 적으면 갈린다).
  # 남는 한 형태는 **구조적으로 판별 불가**다: 모델이 면책 문단까지 항목 본문처럼 들여쓰면
  # 문서가 진짜 렌더와 바이트 단위로 구분되지 않는다. 그건 텍스트 파서의 한계이고, 닫으려면
  # CLI 의 구조화 출력이 필요하다(0.153.4 의 --json 엔 findings 가 없다 — 파일 머리 참조).
  # 자르기가 일어나려면 항목이 ≥1 이므로 **잘린 판정이 CLEAN 으로 나오는 경로는 없다** —
  # 창이 틀리면 계약 줄을 못 찾아 미산출(폴백)로 접힌다.
  ITEM_LINES=$(grep -n -E "$ITEM_P1_RE|$ITEM_P2_RE|$ITEM_P3_RE" "$REVIEW" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
  region=$(awk -v h1="$RENDER_HEADER_ONE" -v hn="$RENDER_HEADER_MANY" -v items="$ITEM_LINES" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function rtrim(s) { sub(/[ \t]+$/, "", s); return s }    # 판정 줄용 — 선행 공백은 남긴다(#339)
    BEGIN { n = split(items, a, " "); for (k = 1; k <= n; k++) if (a[k] != "") isitem[a[k] + 0] = 1 }
    # CLI 저작의 증거 — 이 술어가 유일한 정의 자리다(ⓐ 형식 · ⓑ 위치=접미).
    function cli_rendered(i,   j, k, seen) {
      for (j = i + 1; j <= NR; j++) {              # ⓐ 헤더 뒤 첫 비공백 줄
        if (trim(line[j]) == "") continue
        if (!isitem[j]) return 0                   #    항목이 아니면 렌더가 아니다
        break
      }
      if (j > NR) return 0                         #    헤더 뒤에 아무것도 없다
      seen = 0
      for (k = j; k <= NR; k++) {                  # ⓑ 거기부터 문서 끝까지 전부 렌더인가
        if (trim(line[k]) == "") continue
        if (isitem[k]) { seen = 1; continue }
        if (line[k] ~ /^[ \t]/) continue           #    항목 본문(들여쓴 줄)
        return 0                                   #    렌더 뒤의 모델 산문 = 접미가 아니다
      }
      return seen
    }
    # 줄 머리 공백 수(탭은 세지 않는다 — scan_fence 가 탭 머리를 펜스에서 제외한다)
    function indent_of(s,   n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }
    # 줄의 펜스 런을 잰다 → fc(펜스 문자) · fn(런 길이) · frest(런 뒤 나머지 = 정보 문자열 자리).
    # 펜스가 아니면 fn = 0. (awk 에 다중 반환이 없어 세 전역에 담는다)
    function scan_fence(s,   n, c, i) {
      fc = ""; fn = 0; frest = ""
      n = indent_of(s)
      if (n > 3) return                       # 4칸 이상 들여쓰기 = 코드 블록 본문, 펜스 아님
      s = substr(s, n + 1)
      c = substr(s, 1, 1)
      if (c != "`" && c != "~") return
      i = 0
      while (substr(s, i + 1, 1) == c) i++
      if (i < 3) return                       # 펜스는 같은 문자 3개 이상
      fc = c; fn = i; frest = substr(s, i + 1)
    }
    { line[NR] = $0 }
    END {
      tail = NR; cut = 0; hdr = 0; qual = 0                   # 모델 통제 구역의 끝(기본: 문서 끝)
      for (i = 1; i <= NR; i++) {
        if (trim(line[i]) != h1 && trim(line[i]) != hn) continue
        hdr++
        if (!cli_rendered(i)) continue
        qual++
        if (qual == 1) { cut = i; tail = i - 1 }
      }
      if (qual != 1) { cut = 0; tail = NR }                   # ⓒ 0개=경계 없음 · 2개 이상=모호 → 안 자른다
      # 펜스 짝 세기(#279) — 구역 [1..tail] 안에서 한 패스로 각 줄이 "앞에서 열린 블록을 닫는 줄"인지 표시한다.
      # 닫는 줄마다 그 짝인 여는 펜스의 줄 번호(opener[])도 남긴다 — 꼬리 벗기기가 "리뷰 전체를 감싼
      # 블록의 짝인가"(#339) 를 이 번호로 묻는다.
      first = 0                                              # 구역의 첫 비공백 줄(정상 형태의 여는 펜스 자리)
      for (i = 1; i <= tail; i++) if (trim(line[i]) != "") { first = i; break }
      open_c = ""; open_n = 0; open_at = 0
      for (i = 1; i <= tail; i++) {                            # 렌더 섹션 뒤는 모델 텍스트가 아니다 — 구역 안에서만 센다
        closer[i] = 0; opener[i] = 0
        scan_fence(line[i])
        if (fn == 0) continue
        if (open_n == 0) {
          if (fc == "`" && index(frest, "`") > 0) continue   # 백틱 info 에 백틱 금지 → 여는 펜스 아님
          open_c = fc; open_n = fn; open_at = i              # 여는 펜스(정보 문자열 허용)
        } else if (fc == open_c && fn >= open_n && frest ~ /^[ \t]*$/) {
          closer[i] = 1; opener[i] = open_at                 # 닫는 펜스 — 같은 문자·길이 이상·info 없음
          open_c = ""; open_n = 0; open_at = 0
        }
        # 열린 블록 안에서 짝이 안 맞는 펜스 줄은 그냥 블록 본문이다(위 두 갈래 어디에도 안 든다)
      }
      last = ""; quoted = 0
      for (i = tail; i >= 1; i--) {
        s = trim(line[i])
        if (s == "") continue                                 # 빈 줄 — 꼬리 artifact
        if (closer[i] == 1 && opener[i] == first) continue    # 닫는 코드펜스 — 꼬리 artifact. **짝이 맞고** 그 짝이
                                                                # 구역 첫 비공백 줄(= 리뷰 전체를 감싼 블록)인 줄만 여기
                                                                # 온다(#279 짝 · #339 위치). 짝 없는 맨몸 펜스 = 여는
                                                                # 펜스 → 안 벗긴다 → 그 줄이 마지막 줄이 되어 계약 위반
                                                                # → 미산출(fail-closed). 언어 태그가 붙은 펜스(예:
                                                                # "```python")도 같은 규칙으로 여는 펜스다(#207 attempt8).
                                                                # 산문 **뒤에** 열린 블록의 닫는 펜스(#339 — 계약문을
                                                                # 펜스로 되읊은 응답)도 안 벗긴다 → 같은 경로로 미산출.
        if (closer[i] == 1) quoted = 1                        # 진단용 — 산문 뒤 블록의 닫는 펜스가 마지막 줄이 됐다
        last = rtrim(line[i]); break                          # 선행 공백은 남긴다(#339) — 들여쓴 계약 줄은 줄 전체가 아니다
      }
      printf "%d\t%d\t%d\t%d\t%s\n", cut, hdr, qual, quoted, last
    }' "$REVIEW" 2>/dev/null)
  TAB=$(printf '\t')
  cut_at=${region%%"$TAB"*}; region_rest=${region#*"$TAB"}
  hdr_seen=${region_rest%%"$TAB"*}; region_rest=${region_rest#*"$TAB"}
  qual_seen=${region_rest%%"$TAB"*}; region_rest=${region_rest#*"$TAB"}
  quoted_fence=${region_rest%%"$TAB"*}; last_line=${region_rest#*"$TAB"}
  # 계약 줄은 **줄 전체**일 때만 판정이다(#283 재심 ① — 위 신뢰 규칙 ⑴).
  # 두 회차를 태운 자리다. 앞 회차들은 값 **앞**의 같은 줄 텍스트를 조건부로 받았다:
  # 처음엔 "표식만 아니면 통과"(→ *"이것을 <키>: <값> 으로 읽지 마라"* 는 부정문이 CLEAN 으로
  # 샘), 다음엔 "끝난 문장 하나까지 통과"(→ *"diff 를 못 봤다. <키>: <값>"* 이 CLEAN 으로 샘 —
  # 앞 반송의 세미콜론을 마침표로 바꾼 것뿐인 한 글자 차이다).
  # 두 번 다 같은 실수다: 같은 줄 앞 텍스트가 **무엇을 말하는지**로 가르려 했고, 그건 어형
  # 판별이라 닫히지 않는다(#207 round2~4 가 같은 길에서 세 번 샜다). 문장이 끝났는지 여부는
  # 그 문장이 판정을 **주장**하는지 **부정**하는지를 구분하지 못한다.
  # 그래서 어형을 아예 묻지 않는다 — 계약 줄은 줄 **전체**가 `<키>: <값>` 일 때만 판정이고,
  # 같은 줄에 다른 텍스트가 있으면 어형 불문 거절한다(옛 `^` 앵커와 같은 자리로 되돌린다).
  # 대가: 모델이 총평 문단 끝에 계약 줄을 이어 붙이는 형태(#283 probe3 실측)는 이제 미산출
  # (폴백)이다. 그건 프롬프트 계약문 쪽에서 막는다 — STATUS_CONTRACT_TEXT 가 "그 줄에 다른
  # 텍스트를 함께 두지 말고(앞에도 뒤에도)" 를 명시한다(요구하는 형식 = 읽는 형식, 이 파일의 단일 정의 원칙).
  # 방향은 fail-closed(미산출 → 폴백)다: 놓치면 게이트가 막는 쪽으로 틀린다.
  contract_re="^${STATUS_KEY}:[[:space:]]+(${STATUS_REVIEWED}|${STATUS_NO_BASIS})$"
  status=""
  if printf '%s\n' "$last_line" | grep -qE "$contract_re"; then
    status=$(printf '%s\n' "$last_line" | sed -e "s/^${STATUS_KEY}:[[:space:]]*//")
  elif printf '%s\n' "$last_line" | grep -qE "^[[:space:]]+${STATUS_KEY}:"; then
    log "계약 줄이 들여쓰여 있다 — 선행 공백/탭은 인용(코드 블록) 표식이라 판정으로 안 읽는다(fail-closed, #339)"
  elif printf '%s\n' "$last_line" | grep -qF "${STATUS_KEY}:"; then
    log "계약 줄이 줄 전체가 아니다 — 같은 줄에 다른 텍스트가 있으면 판정으로 안 읽는다(fail-closed)"
  fi
  if [ "${quoted_fence:-0}" = 1 ]; then
    log "모델 통제 구역의 마지막 줄이 산문 뒤에 연 펜스 블록의 닫는 펜스다 — 리뷰 전체를 감싼 블록이 아니면 벗기지 않는다(계약문을 펜스로 되읊은 응답, fail-closed, #339)"
  fi
  case "$status" in
    "$STATUS_REVIEWED") : ;;   # 계약 충족 — 아래 항목 집계가 verdict 를 낸다
    "$STATUS_NO_BASIS")
      log "리뷰어가 판정 근거 없음으로 답함($STATUS_KEY: $STATUS_NO_BASIS) — 미산출(fail-closed): $(head -c 160 "$REVIEW")"
      none "$secs" ;;
    *)
      log "응답 계약 위반 — 모델 통제 구역의 마지막 줄에 '$STATUS_KEY: $STATUS_REVIEWED|$STATUS_NO_BASIS' 가 없다(P1 $p1 · P2 $p2 · P3+ $p3) — 미산출(fail-closed): $(head -c 160 "$REVIEW")"
      # 진단(#283) — 같은 사고를 **첫 틱에** 알아보게 한다. 게이트가 계약 줄을 못 찾았을 때
      # 사람이 알아야 할 것은 두 가지다: ⑴ 판정에 실제로 쓴 줄이 무엇이었나 ⑵ 그런데 본문엔
      # 발견이 몇 건이나 있었나. 발견이 있는데 계약 줄만 없다면 그건 "리뷰어가 게을렀다"가
      # 아니라 **출력 구조가 계약을 담을 수 없다**는 신호다(이 이슈가 정확히 그 모양이었다).
      # 자르기는 `cut -c` 가 아니라 awk substr — C 로케일의 `cut -c` 는 바이트로 잘라 한국어 총평을
      # UTF-8 중간에서 토막 내고, 사람이 첫 틱에 읽으라고 만든 이 줄이 깨진 바이트로 끝난다.
      log "진단: 판정에 쓴 줄(모델 통제 구역 마지막) = [$(printf '%s\n' "$last_line" | awk '{print substr($0, 1, 100)}')]"
      # 헤더 문자열이 본문에 있는데도 안 잘렸다면 그 헤더 뒤에 렌더 항목이 안 따라온 것이다 —
      # codex 렌더가 아니라 **모델 산문**일 가능성이 높다(#283 반송 회차 3). 그 사실을 적어야
      # 읽는 사람이 "구역을 잘못 잡았나"를 헛짚지 않는다.
      if [ "${hdr_seen:-0}" -gt 0 ] && [ "${cut_at:-0}" = 0 ]; then
        if [ "${qual_seen:-0}" -gt 1 ]; then
          log "진단: CLI 렌더 자격을 갖춘 헤더가 ${qual_seen}개다(헤더 문자열은 ${hdr_seen}줄) — codex 는 섹션을 하나만 렌더하므로 어느 쪽이 CLI 인지 알 수 없다(모호 → 안 자름): 구역은 문서 전체다"
        else
          log "진단: 렌더 헤더 문자열이 본문에 ${hdr_seen}줄 있지만 CLI 렌더 조건(뒤에 항목이 따라오고 거기부터 문서 끝까지 전부 항목/항목 본문)을 못 채워 경계로 보지 않았다(모델 산문으로 판단) — 구역은 문서 전체다"
        fi
      fi
      if [ "$((p1 + p2 + p3))" -gt 0 ]; then
        log "진단: 본문엔 발견이 $((p1 + p2 + p3))건 있었는데 계약 줄만 없다 — 리뷰어가 판정을 못 낸 게 아니라 그 판정이 버려졌다. codex 렌더 헤더('$RENDER_HEADER_ONE'/'$RENDER_HEADER_MANY') 뒤는 모델 통제 밖이니 구역 판정을 의심하라: $REVIEW"
      fi
      none "$secs" ;;
  esac
elif [ "$p1" -eq 0 ] && [ "$p2" -eq 0 ] && [ "$p3" -eq 0 ]; then
  # 비계약 경로(내장 스코프 리뷰) — 프롬프트를 실을 자리가 없어 구조 줄을 요구할 수 없다.
  # main 부터 있던 영문 '도구 부재' 휴리스틱(#137)을 그대로 유지한다(리뷰어가 도구를 못 써
  # 아무것도 못 본 채 항목 0을 냈다고 스스로 적는 정형 문구들). 항목이 0일 때만 본다 —
  # 항목이 있는 리뷰는 정의상 미산출이 아니다.
  LEGACY_UNABLE='unable to inspect|could not be inspected|execution tool was unavailable|tool (was|is) unavailable|cannot (access|inspect|read) the (commit|diff|repository)|no changes to review|not a substantive'
  if grep -q -i -E "$LEGACY_UNABLE" "$REVIEW" 2>/dev/null; then
    log "리뷰어가 대상을 못 봤다고 답함 — 미산출(fail-closed): $(head -c 160 "$REVIEW")"
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
