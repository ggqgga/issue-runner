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
# 우선순위 집계를 산문 휴리스틱(바로 아래)보다 **먼저** 한다(#207 attempt4) — 순서가 뒤집혀
# 있으면 정당한 [P1]/[P2]/[P3] 항목의 *설명문*이 "diff 못 봄" 패턴에 걸려 verdict=NONE 으로
# 지워지고, 폴백이 CLEAN 을 내면 BLOCKER 가 조용히 증발한다(실증: f1 아래).
p1=$(grep -c -E '^\s*[-*]\s.*\[P[01]\]' "$REVIEW"); p2=$(grep -c -E '^\s*[-*]\s.*\[P2\]' "$REVIEW")
p3=$(grep -c -E '^\s*[-*]\s.*\[P[3-9]\]' "$REVIEW")

# 한국어/영어 "판정 근거 없음" 패턴(#207): 리뷰어가 "판정 근거로 지정된 diff가 메시지에
# 포함되어 있지 않아 ... 검증할 수 없습니다 ... 판정할 근거도 없습니다" 류의 산문만 남기면
# 옛 분류는 이걸 CLEAN 으로 읽었다(머지 게이트의 절반이 fail-open — 실증: PR #195 closeout
# ③-1, 10초 만에 verdict=CLEAN). [Pn] 항목이 **하나도 없을 때만**(위에서 이미 집계) 적용한다
# — 항목이 있는 리뷰는 정의상 미산출이 아니라서 이 산문 휴리스틱을 탈 이유가 없다(#207 반송:
# 항목 있는 [P1] 설명문의 "누락" 이 이 grep 에 걸려 BLOCKER 가 NONE 으로 증발했었다).
#
# 항목 0일 때: "근거/대상이 없다"는 축(diff 미포함·근거/정보 부족)과 "판정/검증/확인/검토/
# 판단/평가할 수 없다"는 축이 **함께** 나올 때만 잡는다(동사 하나만으로는 "정적으로는
# 검증할 수 없지만 변경분 자체는 부합" 같은 정상 CLEAN 의 부분 서술과 못 가른다, f3).
# "diff...누락"(부정문 "diff에 테스트 누락은 없습니다" 와 겹쳐 뺐다, f2) 대신 "diff...포함되어
# 있지" 만 남긴다 — 실제 fail-open 원문(f5)은 이 표현으로 이미 걸린다. "불가능"·"불가"는
# 여전히 뺀다("판정 불가능할 정도로 미미합니다" 처럼 정도를 서술하는 정상 CLEAN 과 겹친다).
# 각 갈래를 픽스처로 검증: scripts/tests/codex-review-gate.test.sh.
if [ "$p1" -eq 0 ] && [ "$p2" -eq 0 ] && [ "$p3" -eq 0 ]; then
  LEGACY_UNABLE='unable to inspect|could not be inspected|execution tool was unavailable|tool (was|is) unavailable|cannot (access|inspect|read) the (commit|diff|repository)|no changes to review|not a substantive'
  BASIS_ABSENT='diff.{0,40}포함되어 있지|(판정|검증|확인).{0,20}근거.{0,15}(없|부족)|근거.{0,15}(없|부족).{0,20}(판정|검증|확인)|제공된 (정보|diff|자료)만으로'
  CANNOT_VERB='(판정|검증|확인|검토|판단|평가).{0,10}할 수 없'
  if grep -q -i -E "$LEGACY_UNABLE" "$REVIEW" 2>/dev/null \
    || { grep -q -E "$BASIS_ABSENT" "$REVIEW" 2>/dev/null && grep -q -E "$CANNOT_VERB" "$REVIEW" 2>/dev/null; }; then
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
