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
# 깨짐 → `verdict=NONE`(미산출, fail-closed).
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
리뷰 본문의 **마지막 줄**은 다음 둘 중 하나여야 한다(그 뒤에는 빈 줄이나 닫는 코드펜스 외의 텍스트를 두지 마라):
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
# 위치 판정은 **모델 통제 구역의 마지막 줄**이다(#283). 구역 = 문서 처음부터 codex 가 렌더한
# 발견 섹션(헤더 + 그 뒤에 실제로 따라오는 항목) **바로 앞**까지 — 그런 섹션이 없으면
# (발견 0, 또는 헤더 문자열이 모델 산문일 때) 문서 전체다. 그 뒤는
# codex 가 조립한 항목 목록이라 모델이 한 글자도 정할 수 없으므로, 거기까지 계약을 물으면
# **발견을 낸 리뷰만 골라 버리는** 게이트가 된다(이 이슈의 3/3).
# 구역 안에서 꼬리에서 벗기는 것은 **빈 줄과 닫는 코드펜스뿐**이고(계약문이 명시한 그 두 가지
# 예외), 그렇게 벗기고 남은 **마지막 한 줄**이 계약 줄이어야 한다. 창을 N줄로 두면 안 된다:
# 계약 줄 뒤에 임의 산문이 와도 통과해 "못 봤다"고 스스로 적은 응답이 CLEAN 으로 샜다
# (#207 attempt4 반송 — 빈 줄은 이미 지워진 뒤라 3줄 창이 허용한 것은 artifact 가 아니라
# 산문 2줄이었다). 그 봉인은 구역을 옮겨도 그대로다: 총평 안에서 계약 줄 뒤에 산문이 오면
# 여전히 미산출이다(격자 4b-2d 가 문다).
# 형식은 관대하지 않다: 키·구분자·값이 STATUS_* 와 정확히 같아야 하고 **값 뒤 꼬리 텍스트는
# 형식 위반**이다. 값 **앞**의 같은 줄 텍스트는 아래 **허용 목록**에 맞을 때만 허용한다 —
# 실호출에서 모델이 총평 문단 끝에 계약 줄을 이어 붙이는 형태가 실제로 나왔고(#283 probe3),
# 이건 계약을 어긴 게 아니라 줄바꿈 하나 차이다. 앞을 허용해도 (가)"문서 어디든" 의 인용
# 오탐은 생기지 않는다: 구역의 **마지막 한 줄**만 보므로, 리뷰어가 계약문을 인용하면 그
# 인용의 꼬리가 채택돼 미산출로 접힌다.
# 계약 줄 뒤 산문은 곧 미산출이므로, 구 `LEGACY_UNABLE` 산문 휴리스틱이 계약 경로에 없어도
# 그 문구를 단 응답은 여기서 형식으로 접힌다.
if [ "$STATUS_CONTRACT" = 1 ]; then
  # 헤더는 **혼자서는 경계가 아니다**(#283 반송 회차 3). 앞 회차는 헤더 문자열을 보면 무조건
  # 거기서 끊었는데, 그 줄을 **누가 썼는지**는 검사하지 않는다 — 모델이 자기 총평 안에 그
  # 문자열을 한 줄로 적으면 그 뒤(여전히 모델 산문)가 통째로 판정에서 사라져, "diff 를 못
  # 열었다"고 적은 응답이 CLEAN 으로 샜다(검증자 실측 3형태 · main 은 전부 미산출 = 회귀).
  # 존재 단독 조건을 **동반 조건**으로 바꾼다: 헤더가 경계이려면 그 뒤에 codex 가 렌더한
  # 항목이 실제로 따라와야 한다. '항목' 의 정의는 위 ITEM_P*_RE — verdict 를 세는 그 정의
  # 그대로다(줄 번호를 awk 에 넘겨 재사용한다: 정규식을 두 자리에 적으면 갈린다).
  #   헤더 발견 && 그 뒤 첫 비공백 줄이 항목이다  →  경계(그 앞까지가 모델 구역)
  #   헤더 발견 && 뒤에 항목이 없다               →  경계 아님(자르지 않는다 = 문서 전체가 모델 구역)
  # 문서 전체 항목이 0이면 어떤 헤더도 뒤에 항목을 못 가지므로 "헤더 발견 && p1+p2+p3==0 →
  # 경계 아님" 이 그대로 따라 나오고, 더해서 "가짜 헤더 뒤에 진짜 렌더가 이어지는" 끼임 형태
  # (항목 ≥1 이라 개수 조건만으로는 안 걸린다)까지 같은 술어가 닫는다 — **첫** 자격 헤더에서만
  # 끊으므로 항목 본문이 헤더 문자열을 인용해도 진짜 섹션이 먼저 이긴다.
  # 자르기가 일어나려면 항목이 ≥1 이므로 **잘린 판정이 CLEAN 으로 나오는 경로는 없다** —
  # 창이 틀리면 계약 줄을 못 찾아 미산출(폴백)로 접힌다.
  ITEM_LINES=$(grep -n -E "$ITEM_P1_RE|$ITEM_P2_RE|$ITEM_P3_RE" "$REVIEW" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
  region=$(awk -v h1="$RENDER_HEADER_ONE" -v hn="$RENDER_HEADER_MANY" -v items="$ITEM_LINES" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { n = split(items, a, " "); for (k = 1; k <= n; k++) if (a[k] != "") isitem[a[k] + 0] = 1 }
    { line[NR] = $0 }
    END {
      tail = NR; cut = 0; hdr = 0                             # 모델 통제 구역의 끝(기본: 문서 끝)
      for (i = 1; i <= NR; i++) {
        if (trim(line[i]) != h1 && trim(line[i]) != hn) continue
        hdr++
        if (cut) continue                                     # 경계는 이미 정해졌다(첫 자격 헤더)
        for (j = i + 1; j <= NR; j++) {                       # 헤더 뒤 **첫 비공백 줄**을 본다
          if (trim(line[j]) == "") continue
          if (isitem[j]) { cut = i; tail = i - 1 }             # 항목이 따라온다 = 진짜 렌더 섹션
          break                                               # 아니면 이 헤더는 경계가 아니다
        }
      }
      last = ""
      for (i = tail; i >= 1; i--) {
        s = trim(line[i])
        if (s == "") continue                                 # 빈 줄 — 꼬리 artifact
        if (s ~ /^(```+|~~~+)[ \t]*$/) continue                # 닫는 코드펜스(언어 태그 없는 맨 펜스)만 —
                                                                # 꼬리 artifact. 언어 태그가 붙으면(예: "```python")
                                                                # 그건 여는 펜스다 — 벗기면 그 뒤(위) 줄을 계약
                                                                # 줄로 오판해 응답 계약을 어긴 응답이 새는 방향으로
                                                                # 틀린다(#207 attempt8, 닫는 펜스는 관례상 맨몸이다)
        last = s; break
      }
      printf "%d\t%d\t%s\n", cut, hdr, last
    }' "$REVIEW" 2>/dev/null)
  TAB=$(printf '\t')
  cut_at=${region%%"$TAB"*}; region_rest=${region#*"$TAB"}
  hdr_seen=${region_rest%%"$TAB"*}; last_line=${region_rest#*"$TAB"}
  # 값 앞의 같은 줄 텍스트는 **허용 목록**에 맞을 때만 판정으로 읽는다(#283 재심).
  # 앞 회차는 이 자리를 "표식만 아니면(= 산문이 있으면) 통과" 로 열었는데, 그 창은 산문의
  # **존재**만 보고 그 산문이 무엇을 말하는지는 안 본다 — 리뷰어가 *"이것을 <키>: <값> 으로
  # 읽지 마라"* 고 **부정문**으로 적은 응답이 발견 0 에서 CLEAN 으로 샜다(검증자 실측 A 칸).
  # 그건 수용 기준 2항(fail-open 0) 위반이자 main 대비 회귀다(옛 `^` 앵커는 값 앞 텍스트를
  # 아예 안 받아 미산출이었다).
  # 어형(부정 어휘)을 **블랙리스트로 세지 않는다** — 이 파일이 그 길로 세 라운드 연속
  # fail-open 을 냈다(#207 round2~4). 대신 접두가 **무엇이어야 하는가**를 정의한다:
  #
  #   허용 접두 ::= (없음)                                    ← 계약문이 요구한 본래 형태
  #                | [블록 표식 …] <문장> <문장 종결부호> <공백>   ← (가) 산문 꼬리형(probe3 실측)
  #
  # 값 앞에 올 수 있는 것은 **끝난 문장** 하나뿐이다. 문장이 안 끝났으면 계약 줄은 그 문장의
  # **목적어**이지 판정 주장이 아니다(A·H 가 그 모양). 블록 표식(`> `·`- `·`1. `·`## `)은
  # 문장 앞에 붙을 수 있지만 표식**뿐**이면 문장이 없으니 접힌다 — #197 계열("인용된 마커는
  # 제어 신호가 아니다")이 여기서 함께 닫힌다. 번호 목록 `1. ` 의 마침표를 문장 종결로 오인하지
  # 않도록 표식을 **먼저** 벗기고 남은 것에서 종결을 묻는다.
  # 겹쳐 두는 두 번째 가드: 같은 줄에 계약 키가 **두 번 이상**이면 거부한다. 판정을 *언급*하는
  # 문장은 거의 항상 키를 조건절·인용과 함께 끌고 오기 때문이다("… this as <키>: <값>.
  # <키>: <값>" 처럼 끝난 문장 뒤에 재주장하는 형태가 문장 규칙만으로는 통과한다).
  # 어느 쪽에 걸리든 방향은 fail-closed(미산출 → 폴백)다.
  PREFIX_MARKER_RE='^(([>*+-]|#+|[0-9]+[.)])[[:space:]]+)+'
  PREFIX_SENTENCE_RE='[^[:space:]](\.|!|\?|。|！|？)[[:space:]]+$'
  contract_re="(^|[[:space:]])${STATUS_KEY}:[[:space:]]+(${STATUS_REVIEWED}|${STATUS_NO_BASIS})$"
  status=""
  if printf '%s\n' "$last_line" | grep -qE "$contract_re"; then
    prefix=${last_line%"${STATUS_KEY}:"*}                  # 마지막 키 앞의 같은 줄 텍스트
    key_hits=$(printf '%s\n' "$last_line" | grep -o "${STATUS_KEY}:" | grep -c .)
    sentence=$(printf '%s' "$prefix" | sed -E "s/$PREFIX_MARKER_RE//")   # 블록 표식을 먼저 벗긴다
    if [ "$key_hits" != 1 ]; then
      log "계약 줄에 키가 ${key_hits}회 등장한다 — 판정을 주장한 게 아니라 언급한 줄로 보고 판정으로 안 읽는다(fail-closed)"
    elif [ -z "$prefix" ] || printf '%s\n' "$sentence" | grep -qE "$PREFIX_SENTENCE_RE"; then
      status=$(printf '%s\n' "$last_line" | sed -e "s/^.*${STATUS_KEY}:[[:space:]]*//")
    else
      log "계약 줄 앞이 끝난 문장이 아니다([$prefix]) — 리뷰어가 계약 줄을 문장 안에서 언급·인용한 것으로 보고 판정으로 안 읽는다(fail-closed)"
    fi
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
        log "진단: 렌더 헤더 문자열이 본문에 ${hdr_seen}줄 있지만 뒤에 렌더 항목이 안 따라와 경계로 보지 않았다(모델 산문으로 판단) — 구역은 문서 전체다"
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
