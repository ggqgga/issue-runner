#!/usr/bin/env bash
# timebox-check.sh <repo> <num> --claim-at <ISO8601>
#
# ① Reconcile 의 **timebox 판정자** (#200). `working` 이슈(살아있는 워커·PR 없음)에 대해
# "지금 죽여도 되는가" 를 stdout 한 줄로 결정적으로 답한다. SKILL prose 는 이 결과를 읽어
# 분기하기만 한다(판정 로직을 프롬프트에 두지 않는다).
#
# 왜 있는가 — 종전 판정 입력은 `agent:claimed` 이후 **벽시계 경과** 하나뿐이었다. 그 경과에는
# 워커가 통제할 수 없는 대기(박스 전역 직렬 CI 큐, `ci-queue.sh` #127)가 통째로 들어간다.
# 실측 2건(bodat #5020 72분 · #5024 64분)이 규칙 문자 그대로면 죽었을 자리에서 살아 진행
# 중이었고, 유예 뒤 PR #5029·#5032 로 정상 완결됐다. 그래서 판정 입력을 경과가 아니라
# **진행 증거**로 바꾸되, 무한 유예가 되지 않게 유예 횟수에 상한을 둔다.
#
# 출력(한 줄, 공백 구분 — 앞 두 토큰이 판정·사유, 나머지는 Report 용 필드):
#   <verdict> <reason> elapsed=<분>m commit=<분>m|none|- queue=<state> grace=<쓴 횟수>/<상한>
#
#   ok      경과가 아직 ISSUE_TIMEBOX_HOURS 이내         (exit 0 — 손대지 마라)
#   grace   경과는 넘었지만 진행 증거가 있어 이번 틱 유예 (exit 0 — 손대지 마라, 정보 줄로 Report)
#   stop    무진전(또는 유예 상한 소진) — 규칙대로 중단   (exit 1 — TaskStop·worktree 폐기·claim 해제)
#   unknown 판정 입력을 못 얻음                          (exit 2 — 중단하지 말고 warn 으로)
#
# `unknown` 이 exit 1(중단)이 아닌 이유: 조회 실패로 살아있는 워커를 죽이는 것은 되돌릴 수
# 없는(미push 잔여물 폐기) 손해인데, gh 가 고장 난 틱은 어차피 뒤 단계도 못 간다. 빈 결과와
# 실패를 구분해(PR#139) 실패는 warn 으로 사람 눈에 올린다.
#
# 진행 증거(둘 중 하나라도 참이면 유예):
#   ① 원격 브랜치 `agent/issue-<num>` 의 최신 커밋이 STALL_MIN 이내
#   ② 그 head SHA 의 CI 티켓이 큐에 살아 있음(queue.log 의 그 SHA **마지막 줄**이 `대기열 N번째`)
#
# queue.log 판정은 반드시 **그 SHA 의 마지막 줄**로 한다. 같은 SHA 가 여러 줄인 것이 정상이다 —
# `폐기 — 실행 시점 HEAD 가 …` · `중단(INT/TERM)` · `유령 티켓 회수(pid 사망)` 뒤의 재큐는 정상
# 동작이라, "어딘가에 대기열 줄이 있나" 로 재면 이미 끝난 티켓을 살아 있다고 읽는다.
#
# 연속 유예 횟수 — **새 상태를 만들지 않는다**(상태 enum·상태기계 금지). 유예할 때마다 이슈에
# append 전용 마커 코멘트(`<!-- timebox-grace: N -->`)를 남기고, 횟수는 매 틱 GitHub(SSOT)에서
# 다시 센다. "연속" 은 **현재 claim 시각 이후에 달린 마커만** 세어 재파생한다 — 재디스패치로
# claim 이 새로 붙으면 옛 마커는 자동으로 계산에서 빠지므로 리셋용 쓰기가 필요 없다.
#
# 상수 기본값(정의·근거는 SKILL.md 의 상수 절 — 여기는 그 값을 읽는 자리다):
#   ISSUE_TIMEBOX_HOURS  기본 1   MAX_TIMEBOX_GRACE 기본 3   STALL_MIN 기본 25
#
# 테스트/재현용 env 오버라이드 (없으면 gh/date 실조회):
#   TB_NOW             현재 epoch(초)
#   TB_CLAIM_AT        claim 시각 ISO8601 — `--claim-at` 대체
#   TB_LAST_COMMIT_AT  브랜치 최신 커밋 시각 ISO8601, 또는 `none`(브랜치·커밋 없음)
#   TB_HEAD_SHA        브랜치 head SHA, 또는 `none`
#   TB_QUEUE_LOG       queue.log 경로(기본 ~/.claude/.local-ci/queue.log)
#   TB_COMMENTS_JSON   이슈 코멘트 배열 JSON([{body,created_at},…]) — 실조회 대체
#   TB_NO_POST         비어있지 않으면 유예 마커 코멘트를 쓰지 않는다(판정만 보고 싶을 때)
# macOS bash 3.2 대상.
set -uo pipefail

repo=${1:-}
num=${2:-}
if [ $# -ge 2 ]; then shift 2; else shift $#; fi
claim_at="${TB_CLAIM_AT:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --claim-at) claim_at="${2:-}"; shift 2 ;;
    *) echo "usage: timebox-check.sh <repo> <num> --claim-at <ISO8601>" >&2; exit 64 ;;
  esac
done
if [ -z "$repo" ] || [ -z "$num" ]; then
  echo "usage: timebox-check.sh <repo> <num> --claim-at <ISO8601>" >&2; exit 64
fi

TIMEBOX_HOURS="${ISSUE_TIMEBOX_HOURS:-1}"
STALL_MIN="${STALL_MIN:-25}"
MAX_GRACE="${MAX_TIMEBOX_GRACE:-3}"
QUEUE_LOG="${TB_QUEUE_LOG:-$HOME/.claude/.local-ci/queue.log}"
BRANCH="agent/issue-$num"

# 마커 필터는 **한 곳에만** 둔다 — 실조회(gh --jq)와 픽스처(jq) 두 경로가 같은 문자열을 쓴다.
# 두 벌로 복제하면 언젠가 한쪽만 고쳐져 "센 것"과 "쓴 것"이 어긋난다(PR#191 교훈).
GRACE_FILTER='.[] | select(.body | test("<!--\\s*timebox-grace:\\s*[0-9]+\\s*-->")) | .created_at'

# ISO8601(...Z) → epoch. 형식 검사를 먼저 한다 — GNU date 는 빈 문자열·느슨한 표현을
# 실패시키지 않고 그럴듯한 값으로 돌려주므로(finish-classify.sh 주석 참조) 입구에서 막는다.
iso_to_epoch() {
  local iso="${1:-}"
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  date -u -d "$iso" +%s 2>/dev/null
}

emit() {  # emit <verdict> <reason> <exit>
  printf '%s %s elapsed=%sm commit=%s queue=%s grace=%s/%s\n' \
    "$1" "$2" "${elapsed_min:--}" "${commit_field:--}" "${queue_state:--}" \
    "${grace_used:-0}" "$MAX_GRACE"
  exit "$3"
}

elapsed_min=""
commit_field="-"
queue_state="-"
grace_used=0

# ── 경과 ────────────────────────────────────────────────────────────────
now="${TB_NOW:-$(date -u +%s)}"
case "$now" in ''|*[!0-9]*) emit unknown now_invalid 2 ;; esac
if ! claim_epoch=$(iso_to_epoch "$claim_at"); then
  emit unknown claim_at_invalid 2
fi
elapsed_sec=$((now - claim_epoch))
[ "$elapsed_sec" -lt 0 ] && elapsed_sec=0
elapsed_min=$((elapsed_sec / 60))
if [ "$elapsed_sec" -le $((TIMEBOX_HOURS * 3600)) ]; then
  emit ok within_timebox 0
fi

# ── 진행 증거 ① 브랜치 최신 커밋 ────────────────────────────────────────
# 실조회는 `gh api repos/<repo>/commits/<branch>` 한 번으로 head SHA 와 커밋 시각을 함께 얻는다.
# 브랜치 **부재**(404)와 조회 **실패**를 구분한다 — 부재는 "아직 push 가 없다"는 정상 입력이고
# (커밋 증거 없음으로 진행), 실패는 판정 불가다(PR#139: 빈 결과와 실패를 섞지 마라).
head_sha=""
last_commit_at=""
if [ -n "${TB_LAST_COMMIT_AT:-}" ] || [ -n "${TB_HEAD_SHA:-}" ]; then
  last_commit_at="${TB_LAST_COMMIT_AT:-none}"
  head_sha="${TB_HEAD_SHA:-none}"
else
  api_err=$(mktemp) || emit unknown tmpfile_failed 2
  if api_out=$(gh api "repos/$repo/commits/$BRANCH" \
        --jq '(.sha // "") + " " + (.commit.committer.date // "")' 2>"$api_err"); then
    head_sha="${api_out%% *}"
    last_commit_at="${api_out##* }"
    [ -n "$head_sha" ] || head_sha=none
    [ -n "$last_commit_at" ] || last_commit_at=none
  elif grep -q -e '404' -e 'Not Found' -- "$api_err" 2>/dev/null; then
    head_sha=none; last_commit_at=none     # 브랜치 없음 = push 된 커밋이 아직 없다(정상 입력)
  else
    rm -f "$api_err"
    emit unknown branch_lookup_failed 2
  fi
  rm -f "$api_err"
fi

commit_recent=0
if [ "$last_commit_at" = none ]; then
  commit_field=none
elif commit_epoch=$(iso_to_epoch "$last_commit_at"); then
  commit_age=$((now - commit_epoch))
  [ "$commit_age" -lt 0 ] && commit_age=0
  commit_field="$((commit_age / 60))m"
  [ "$commit_age" -le $((STALL_MIN * 60)) ] && commit_recent=1
else
  emit unknown commit_at_invalid 2
fi

# ── 진행 증거 ② CI 큐 티켓 ──────────────────────────────────────────────
# queued = 그 SHA 의 **마지막** 줄이 `대기열 N번째` (실행 중인 잡도 여기 머문다 — ci-queue.sh 는
#          실행 시작을 따로 로깅하지 않고 끝날 때 pass/fail 을 찍는다).
# left   = 마지막 줄이 그 밖(pass/fail/폐기/중단/유령 티켓 회수/이미 검사됨 …) = 큐를 떠났다.
# none   = 그 SHA 줄이 아예 없음 · nolog = queue.log 부재(로컬 CI 미사용 박스) ·
# logerr = 로그를 읽지 못함(부재와 구분해 남긴다 — 증거로는 쓰지 않는다).
queue_alive() {  # queue_alive <sha> → stdout: queued|left|none|nolog|logerr
  local sha="$1" short line msg rc=0
  short="${sha:0:8}"
  [ -f "$QUEUE_LOG" ] || { printf 'nolog'; return 0; }
  # 패턴은 `-e` 로 넘긴다 — 맨몸으로 넘기면 `-` 로 시작하는 값이 옵션으로 먹혀 grep 이
  # stdin 을 읽고 호출자가 매달린다(PR#202 교훈, 실측 12분 행업).
  line=$(grep -F -e "$short" -- "$QUEUE_LOG") || rc=$?
  if [ "$rc" -gt 1 ]; then printf 'logerr'; return 0; fi
  [ -n "$line" ] || { printf 'none'; return 0; }
  line=$(printf '%s\n' "$line" | tail -1)
  # 로그 줄 = `<ts> pid=<pid> <msg>` — 앞 두 필드를 걷어낸다.
  msg="${line#*pid=}"; msg="${msg#* }"
  case "$msg" in
    "$short 대기열 "*) printf 'queued' ;;
    *) printf 'left' ;;
  esac
}

if [ "$head_sha" = none ] || [ -z "$head_sha" ]; then
  queue_state=none
else
  queue_state=$(queue_alive "$head_sha")
fi

if [ "$commit_recent" = 1 ]; then
  progress=recent_commit
elif [ "$queue_state" = queued ]; then
  progress=ci_queued
else
  progress=""
fi

[ -n "$progress" ] || emit stop no_progress 1

# ── 유예 상한 — 현재 claim 이후의 마커만 센다 ───────────────────────────
if [ -n "${TB_COMMENTS_JSON:-}" ]; then
  marker_times=$(printf '%s' "$TB_COMMENTS_JSON" | jq -r "$GRACE_FILTER" 2>/dev/null) \
    || emit unknown comments_parse_failed 2
else
  marker_times=$(gh api "repos/$repo/issues/$num/comments" --paginate --jq "$GRACE_FILTER" 2>/dev/null) \
    || emit unknown comments_lookup_failed 2
fi
# 빈 출력 = 마커 0개(정상). 위 분기가 실패를 따로 걸렀으므로 여기서 섞이지 않는다.
if [ -n "$marker_times" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if m_epoch=$(iso_to_epoch "$t"); then
      [ "$m_epoch" -ge "$claim_epoch" ] && grace_used=$((grace_used + 1))
    fi
  done <<EOF
$marker_times
EOF
fi

if [ "$grace_used" -ge "$MAX_GRACE" ]; then
  emit stop grace_exhausted 1
fi

# 유예 확정 — 마커를 남겨야 다음 틱이 이 유예를 셀 수 있다. 마커를 못 남기면 유예가 무한이
# 되므로 grace 로 통과시키지 않고 unknown(warn)으로 올린다 — 상한 없는 유예를 조용히 만들지 않는다.
next=$((grace_used + 1))
if [ -z "${TB_NO_POST:-}" ]; then
  if ! gh issue comment "$num" --repo "$repo" \
      --body "타임박스 유예 $next/$MAX_GRACE: 경과 ${elapsed_min}분 · 진행 증거 $progress (마지막 커밋 $commit_field · CI 큐 $queue_state) — <!-- timebox-grace: $next --><!-- bodat:worker -->" \
      >/dev/null 2>&1; then
    emit unknown grace_marker_post_failed 2
  fi
fi
grace_used="$next"
emit grace "$progress" 0
