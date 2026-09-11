#!/usr/bin/env bash
# progress-evidence.sh --now <epoch> --commit-at <ISO8601|none> --head-sha <sha|none>
#
# 질문 하나에만 답한다: **이 브랜치의 워커가 지금도 진행 중이라는 증거가 있는가.**
# 판정 입력은 두 가지뿐이고(커밋 시각·head SHA), 큐 로그는 이 스크립트가 직접 읽는다.
#
# 출력(한 줄, 공백 구분):
#   <verdict> <reason> commit=<분>m|none|- queue=<state>|-
#
#   progress <recent_commit|ci_queued>  exit 0  진행 증거 있음 — 워커는 살아 있다
#   none     no_progress                exit 0  증거 없음 — 무진전
#   unknown  <사유>                     exit 2  판정 입력을 못 얻음(증거 없음이 **아니다**)
#
# ── 왜 스크립트로 뽑았나 (#206) ──────────────────────────────────────────────
# 이 술어의 소비자가 둘이 됐다:
#   1. `timebox-check.sh` (#200) — ① Reconcile 의 timebox 판정. 원래 주인.
#   2. `finish-classify.sh` (#206) — 완결 유실 갈래에서 "🔄 가 낡았지만 워커가 살아
#      있는가" 를 묻는다. 커밋 신선도를 빼먹으면 **살아 있는 attempt N+1 워커를 죽인다**
#      (이 레포의 반복 오탐).
# 두 벌로 복제하면 사람 눈에 안 보이는 두 번째 계산기가 다른 수를 센다 — 마커 집합을
# `bounce-state.sh` 한 자리에 묶은 것과 같은 규율이다(#171·#196, PR#191 교훈).
# `bin/ci` 가 `^STALL_MIN=`·`^queue_alive()` 정의가 이 파일 밖에 생기면 실패시킨다.
#
# ── 진행 증거 (둘 중 하나라도 참이면 progress) ───────────────────────────────
#   ① 최신 커밋이 STALL_MIN 이내
#   ② 그 head SHA 의 CI 티켓이 큐에 살아 있음(queue.log 의 그 SHA **마지막 줄**이
#      `대기열 N번째`) — 박스 전역 직렬 CI 큐(#127) 대기는 워커가 통제할 수 없는
#      시간이다(실측 bodat #5020 72분 · #5024 64분, 둘 다 살아 있었다).
#
# queue.log 판정은 반드시 **그 SHA 의 마지막 줄**로 한다. 같은 SHA 가 여러 줄인 것이
# 정상이다 — `폐기 — 실행 시점 HEAD 가 …` · `중단(INT/TERM)` · `유령 티켓 회수(pid 사망)`
# 뒤의 재큐는 정상 동작이라, "어딘가에 대기열 줄이 있나" 로 재면 이미 끝난 티켓을 살아
# 있다고 읽는다.
#
# `unknown` 을 `none` 과 섞지 않는 이유: 조회 실패로 살아있는 워커를 죽이는 것은 되돌릴
# 수 없는 손해다. 빈 결과와 실패를 구분해(PR#139) 실패는 호출자가 보수적으로 받는다.
#
# env 오버라이드:
#   PE_QUEUE_LOG  queue.log 경로(기본 ~/.claude/.local-ci/queue.log)
#   STALL_MIN     커밋 신선도 임계(분, 기본 25) — **이 파일이 이 상수의 한 자리다**
# macOS bash 3.2 대상.
set -uo pipefail

STALL_MIN="${STALL_MIN:-25}"
QUEUE_LOG="${PE_QUEUE_LOG:-$HOME/.claude/.local-ci/queue.log}"

usage() {
  echo "usage: progress-evidence.sh --now <epoch> --commit-at <ISO8601|none> --head-sha <sha|none>" >&2
  exit 64
}

now=""
commit_at=""
head_sha=""
while [ $# -gt 0 ]; do
  # 값이 없는데 `shift 2` 를 하면 `set -e` 가 꺼져 있어 인자 목록이 그대로 남아 같은
  # 플래그를 무한히 다시 읽는다(timebox-check.sh 가 실제로 밟은 자리).
  case "$1" in
    --now)       [ $# -ge 2 ] || usage; now="$2"; shift 2 ;;
    --commit-at) [ $# -ge 2 ] || usage; commit_at="$2"; shift 2 ;;
    --head-sha)  [ $# -ge 2 ] || usage; head_sha="$2"; shift 2 ;;
    *) usage ;;
  esac
done

commit_field="-"
queue_state="-"

emit() {  # emit <verdict> <reason> <exit>
  printf '%s %s commit=%s queue=%s\n' "$1" "$2" "$commit_field" "$queue_state"
  exit "$3"
}

case "$now" in ''|*[!0-9]*) emit unknown now_invalid 2 ;; esac

# ISO8601(...Z) → epoch. 형식 검사를 먼저 한다 — GNU date 는 빈 문자열·느슨한 표현을
# 실패시키지 않고 그럴듯한 값으로 돌려준다(finish-classify.sh 주석 참조).
iso_to_epoch() {
  local iso="${1:-}"
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  date -u -d "$iso" +%s 2>/dev/null
}

# ── 증거 ① 커밋 신선도 ──────────────────────────────────────────────────
# `none` 만 "커밋 없음(정상 입력)" 이다. **빈 문자열은 `none` 이 아니다** — 호출자가
# 시각을 못 얻었다는 뜻이고, 그걸 증거 없음으로 접으면 조회 실패가 곧바로 되돌릴 수 없는
# 쪽(timebox 는 stop, finish-classify 는 재디스패치)으로 흐른다(PR#139: 빈 결과와 실패를
# 구분하라). 아래 iso_to_epoch 이 형식 불량으로 걸러 `unknown commit_at_invalid` 가 된다.
# 호출자가 "커밋 증거 없음" 을 말하고 싶으면 **문자열 `none` 을 명시**해야 한다.
commit_recent=0
if [ "$commit_at" = none ]; then
  commit_field=none
elif commit_epoch=$(iso_to_epoch "$commit_at"); then
  commit_age=$((now - commit_epoch))
  [ "$commit_age" -lt 0 ] && commit_age=0
  commit_field="$((commit_age / 60))m"
  [ "$commit_age" -le $((STALL_MIN * 60)) ] && commit_recent=1
else
  emit unknown commit_at_invalid 2
fi

# ── 증거 ② CI 큐 티켓 ───────────────────────────────────────────────────
# queued = 그 SHA 의 **마지막** 줄이 `대기열 N번째` (실행 중인 잡도 여기 머문다 —
#          ci-queue.sh 는 실행 시작을 따로 로깅하지 않고 끝날 때 pass/fail 을 찍는다).
# left   = 마지막 줄이 그 밖(pass/fail/폐기/중단/유령 티켓 회수/이미 검사됨 …) = 큐를 떠났다.
# none   = 그 SHA 줄이 아예 없음 · nolog = queue.log 부재(로컬 CI 미사용 박스) ·
# logerr = 로그를 읽지 못함(부재와 구분해 남긴다 — 증거로는 쓰지 않는다).
queue_alive() {  # queue_alive <sha> → stdout: queued|left|none|nolog|logerr
  local sha="$1" short cand line msg last="" rc=0
  short="${sha:0:8}"
  [ -f "$QUEUE_LOG" ] || { printf 'nolog'; return 0; }
  # 패턴은 `-e` 로 넘긴다 — 맨몸으로 넘기면 `-` 로 시작하는 값이 옵션으로 먹혀 grep 이
  # stdin 을 읽고 호출자가 매달린다(PR#202 교훈, 실측 12분 행업).
  cand=$(grep -F -e "$short" -- "$QUEUE_LOG") || rc=$?
  if [ "$rc" -gt 1 ]; then printf 'logerr'; return 0; fi
  [ -n "$cand" ] || { printf 'none'; return 0; }
  # **소유권 필터** — 그 SHA 를 본문에 언급만 하는 *남의 티켓* 줄을 걸러낸다. 폐기 줄 형식이
  # `<티켓SHA> 폐기 — 실행 시점 HEAD 가 <다른SHA> ≠ <티켓SHA>` 라서, 워커가 새로 push 한
  # 우리 SHA 는 **앞선 옛 티켓의 폐기 줄 본문**에 정상적으로 등장한다(새 push 가 자기 티켓을
  # 낸 흔한 형상). 그 줄을 우리 줄로 세면 큐에서 CI 를 기다리는 살아있는 워커가 `left` 로
  # 읽혀 죽는다 — 이 술어가 없애려는 바로 그 사고다.
  # 우리 줄 = 메시지가 `<짧은SHA> ` 로 시작하는 줄(대기열·pass·fail·폐기·중단·이미 검사됨 …)
  #          또는 회수 줄처럼 **티켓 이름**(`<epoch>.<pid>.<전체SHA>`)이 그 SHA 로 끝나는 줄.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # 로그 줄 = `<ts> pid=<pid> <msg>` — 앞 두 필드를 걷어낸다.
    msg="${line#*pid=}"; msg="${msg#* }"
    case "$msg" in
      "$short "*)      last="$msg" ;;
      *".$sha"|*".$sha "*) last="$msg" ;;
    esac
  done <<EOF
$cand
EOF
  [ -n "$last" ] || { printf 'none'; return 0; }
  case "$last" in
    "$short 대기열 "*) printf 'queued' ;;
    *) printf 'left' ;;
  esac
}

if [ "$head_sha" = none ] || [ -z "$head_sha" ]; then
  queue_state=none
else
  queue_state=$(queue_alive "$head_sha")
fi
# 로그를 **읽지 못한 것**은 "큐에 없다" 가 아니다 — 조회 실패와 같은 취급으로 판정
# 불가다(부재 `nolog`·무매칭 `none` 과 구분해 여기서만 갈라낸다).
[ "$queue_state" = logerr ] && emit unknown queue_log_read_failed 2

if [ "$commit_recent" = 1 ]; then
  emit progress recent_commit 0
elif [ "$queue_state" = queued ]; then
  emit progress ci_queued 0
fi

emit none no_progress 0
