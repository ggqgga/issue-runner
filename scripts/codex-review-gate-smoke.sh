#!/usr/bin/env bash
# codex-review-gate-smoke.sh — `codex-review-gate.sh --prompt` 의 **실호출** 스모크 (#283)
#
#   scripts/codex-review-gate-smoke.sh [--model M] [--effort E] [--keep]
#
# 왜 따로 있나: 격자 테스트(`scripts/tests/codex-review-gate.test.sh`)는 `codex` 를 스텁으로
# 바꿔 돈다. 스텁은 우리가 시킨 대로 응답 계약 줄을 얌전히 내주므로, **실제 CLI 가 그 줄을
# 낼 수 있는가**는 스텁 밖의 사실이고 격자가 구조적으로 못 잡는다. #283 이 정확히 그 사각이었다:
# codex 는 발견이 있으면 총평 뒤에 자기 헤더와 항목 목록을 렌더해 붙여 문서의 마지막 줄을
# 가져가므로 "문서의 마지막 줄 = 계약 줄" 요구가 **영원히** 충족되지 않았는데, 격자는 만점이었다.
# 그래서 진짜 codex 를 한 번 부르는 이 스모크를 둔다.
#
# **`bin/ci` 밖이다 — 일부러.** 네트워크와 codex 로그인이 필요해 CI 게이트에 넣으면 결정론이
# 깨진다. 사람이 필요할 때 손으로 돌린다(README 런북 한 줄): 게이트 판정부·프롬프트 계약문을
# 건드린 PR, codex CLI 업그레이드 뒤, 그리고 계획부합 판정이 또 폴백으로만 날 때.
#
# 하는 일: 임시 git 레포에 **발견이 확실히 나는** 작은 diff 를 만들고(셸 주입) 게이트를
# `--base base --prompt` 로 1회 호출해, verdict 가 `NONE` 이 **아님**을 단언한다.
# 종료: 0 = 통과(판정이 났고 회귀 창을 실제로 통과) · 1 = 실패(verdict=NONE — 회귀) ·
#       2 = 돌릴 수 없음(codex 부재) · 3 = 미결정(호출은 됐으나 발견 섹션이 안 렌더돼
#       #283 회귀 창을 건드리지 못함 — 초록으로 치지 마라, 다시 돌려라).
# macOS bash 3.2 호환. 임시 디렉터리는 끝나면 지운다(--keep 로 남길 수 있다).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$DIR/codex-review-gate.sh"
MODEL=""; EFFORT=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model)  MODEL="${2:?}"; shift 2 ;;
    --effort) EFFORT="${2:?}"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    *) printf 'usage: codex-review-gate-smoke.sh [--model M] [--effort E] [--keep]\n' >&2; exit 64 ;;
  esac
done
say() { printf 'smoke: %s\n' "$*" >&2; }

[ -x "$GATE" ] || { say "게이트 스크립트를 실행할 수 없다: $GATE"; exit 2; }
command -v codex >/dev/null 2>&1 || { say "codex CLI 없음 — 이 스모크는 실호출이 목적이라 스텁으로 대체하지 않는다(격자 테스트가 그 몫)"; exit 2; }

TMP=$(mktemp -d) || exit 2
if [ "$KEEP" = 1 ]; then trap 'say "산출물 보존: $TMP"' EXIT; else trap 'rm -rf "$TMP"' EXIT; fi
R="$TMP/repo"; OUT="$TMP/out"; mkdir -p "$R" "$OUT"

# 발견이 확실한 diff — 외부 입력을 셸에 그대로 넘긴다. 실측 재현용이라 레포 밖 임시 파일이다.
git -C "$R" init -q || { say "git init 실패"; exit 2; }
printf 'x = 1\n' > "$R/app.py"
git -C "$R" add app.py
git -C "$R" -c user.name=smoke -c user.email=smoke@local commit -q -m base
git -C "$R" branch -q base
cat > "$R/app.py" <<'PY'
import subprocess

def run_report(user_input):
    # 외부 입력을 셸 문자열로 이어 붙인다
    return subprocess.check_output("report --for " + user_input, shell=True)
PY
git -C "$R" -c user.name=smoke -c user.email=smoke@local commit -q -am "add report runner"

set -- --base base --prompt '이 변경이 계획에 부합하는지, 그리고 정확성 결함이 있는지 보라.' --cd "$R" --out "$OUT"
[ -n "$MODEL" ]  && set -- "$@" --model "$MODEL"
[ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"

say "실호출 중 — codex exec review (수 분 걸린다)"
# 게이트의 종료코드를 **파이프 없이** 받는다 — `cmd | tail -1` 로 받으면 `$?` 는 tail 의 것(늘 0)이라
# BLOCKER(1)·미산출(2)·실행 실패(127)가 전부 "exit 0" 으로 기록돼 진단 줄이 거짓말을 한다.
rc=0
"$GATE" "$@" >"$TMP/gate.out" 2>"$TMP/gate.err" || rc=$?
sed 's/^/  | /' "$TMP/gate.err" >&2
last=$(tail -1 "$TMP/gate.out")
verdict=$(printf '%s\n' "$last" | sed -n 's/^verdict=\([A-Z]*\) .*/\1/p')
say "게이트 출력: ${last:-<출력 없음>} (exit $rc)"

# 회귀와 "못 돌림" 을 가른다. 리뷰 본문이 아예 안 나왔으면(codex 부재·모델 오류·타임아웃·인증)
# 그건 이 이슈의 회귀가 아니라 인프라 실패다 — 헤더가 약속한 exit 2 로 보낸다. 본문은 나왔는데
# verdict 가 NONE 이면 그게 바로 #283 이 고친 그 실패다(응답 계약을 못 읽었다).
if [ -z "$verdict" ] || { [ "$verdict" = NONE ] && [ ! -s "$OUT/review.md" ]; }; then
  say "✗ 못 돌림 — 리뷰 본문이 안 나왔다(verdict=${verdict:-<없음>}, gate exit $rc). codex 부재·모델 오류·타임아웃·인증을 의심하라."
  say "  codex stderr: $OUT/stderr.log · 게이트 stderr 는 위에 그대로 찍었다 (--keep 로 보존)"
  exit 2
fi
if [ "$verdict" = NONE ]; then
  say "✗ 실패 — 리뷰 본문은 나왔는데 verdict=NONE 이다. 구조 신호(발견 항목 · events.jsonl 명령)로 판정이 서지 않았다 = #283/#375 회귀."
  say "  리뷰 본문·이벤트를 직접 보라: $OUT/review.md · $OUT/events.jsonl (--keep 로 보존)"
  exit 1
fi

# 회귀 창을 실제로 건드렸는가 — 발견 항목이 렌더됐어야 이 스모크가 #283/#375 를 문 것이다(#375 부터
# 판정 입력은 항목 수다). 항목 0 인 응답은 "안 읽은 문제 없음" 과 구분이 안 되므로 통과로 치지 않는다.
items=$(printf '%s\n' "$last" | sed -n 's/.* p1=\([0-9]*\) p2=\([0-9]*\) p3=\([0-9]*\).*/\1 \2 \3/p')
set -- ${items:-0 0 0}
if [ $(( ${1:-0} + ${2:-0} + ${3:-0} )) -gt 0 ]; then
  say "✓ 통과 — verdict=$verdict · 발견 항목이 렌더된 응답에서 판정이 났다(#283/#375 회귀 창 통과)"
  exit 0
fi
say "△ 미결정 — verdict=$verdict 이지만 발견 항목이 0 이다(리뷰어가 심은 결함을 못 찾음)."
say "  항목 0 인 응답은 회귀 창을 안 건드린다 — 이 초록은 무죄의 증거가 아니다. 다시 돌려라."
exit 3
