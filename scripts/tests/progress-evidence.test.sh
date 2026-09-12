#!/usr/bin/env bash
# progress-evidence.sh 격자 테스트 (#428) — 네트워크 무접속(입력은 전부 인자·env·픽스처 로그).
# 무는 계약: 진행 증거 3축(① 커밋 신선도 ② 그 SHA 의 CI 큐 티켓 ③ claim 신선도)의 판정과
# **3값 어휘**(<값>/none/unknown)의 분리 — 조회 실패(unknown·logerr)는 "증거 없음"(none)이
# 아니라 exit 2 다. 출력은 `<verdict> <reason> commit=… queue=… claim=…` **한 줄 전체**로
# 단언해 필드 방출 순서까지 못 박는다.
# 이 헬퍼를 직접 exec 하는 소비자: scripts/timebox-check.sh · scripts/finish-classify.sh.
# bats 미도입 레포라 finish-classify.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/progress-evidence.sh"

TMP=$(mktemp -d)
trap 'chmod u+rw "$TMP"/*.log 2>/dev/null; rm -rf "$TMP"' EXIT

# gh 스텁 — 이 스크립트는 어떤 경로로도 네트워크를 타면 안 된다. 실수로 타면 시끄럽게 실패한다.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/sh
echo "progress-evidence.sh 가 gh 를 불렀다: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

# 고정 NOW = 2026-09-13T12:00:00Z (BSD/GNU date 양쪽 파싱).
NOW=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-09-13T12:00:00Z" +%s 2>/dev/null \
  || date -u -d "2026-09-13T12:00:00Z" +%s)

iso_ago() {  # iso_ago <초> → NOW 보다 그만큼 이전의 ISO8601 (음수면 미래)
  local e=$((NOW - $1))
  date -u -j -f %s "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}

SHA=505c5f0e1234567890abcdef1234567890abcdef    # short = 505c5f0e (우리 티켓)
OTHER=abcd1234ffffffffffffffffffffffffffffffff  # short = abcd1234 (남의 티켓)

pass=0
fail=0
QLOG="$TMP/absent.log"   # 기본은 **부재**(queue=nolog). 큐 축 케이스만 덮어쓴다.

run_case() {  # run_case <이름> <기대 출력 한 줄> <기대 exit> <인자...>
  local name="$1" expect="$2" erc="$3"; shift 3
  local got rc
  got=$(PATH="$TMP/bin:$PATH" STALL_MIN=25 ISSUE_TIMEBOX_HOURS=1 PE_QUEUE_LOG="$QLOG" \
    bash "$SUT" "$@" 2>/dev/null); rc=$?
  if [ "$got" = "$expect" ] && [ "$rc" = "$erc" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=[$expect](exit $erc) 실제=[$got](exit $rc)"
  fi
}

# ── 증거 ① 커밋 신선도 ──────────────────────────────────────────────────
run_case "커밋 10분 전 → 진행" \
  "progress recent_commit commit=10m queue=none claim=none" 0 \
  --now "$NOW" --commit-at "$(iso_ago 600)" --head-sha none

# 경계 쌍 — 1500s 와 1501s 는 **표시가 둘 다 25m** 이고 판정만 갈린다(임계는 `-le`, 포함).
run_case "커밋이 정확히 STALL_MIN(1500s) → 진행" \
  "progress recent_commit commit=25m queue=none claim=none" 0 \
  --now "$NOW" --commit-at "$(iso_ago 1500)" --head-sha none
run_case "커밋이 STALL_MIN+1s → 무진전" \
  "none no_progress commit=25m queue=none claim=none" 0 \
  --now "$NOW" --commit-at "$(iso_ago 1501)" --head-sha none

# 시계 어긋남(커밋이 미래) — 음수 경과는 0 으로 클램프된다.
run_case "커밋 시각이 미래 → 0m 로 클램프·진행" \
  "progress recent_commit commit=0m queue=none claim=none" 0 \
  --now "$NOW" --commit-at "$(iso_ago -600)" --head-sha none

run_case "커밋 none·SHA none → 증거 없음" \
  "none no_progress commit=none queue=none claim=none" 0 \
  --now "$NOW" --commit-at none --head-sha none

# ── 증거 ② CI 큐 티켓 (판정은 그 SHA 의 **마지막 줄**) ───────────────────
# 아래 큐 케이스는 커밋을 60분 전으로 고정해 증거 ①을 꺼 둔다 — 갈리는 것이 큐뿐이게.
OLD=$(iso_ago 3600)

QLOG="$TMP/queue.log"
cat > "$QLOG" <<EOF
2026-09-13T11:02:00 pid=90210 505c5f0e 대기열 3번째
EOF
run_case "우리 SHA 마지막 줄이 대기열 → 진행" \
  "progress ci_queued commit=60m queue=queued claim=none" 0 \
  --now "$NOW" --commit-at "$OLD" --head-sha "$SHA"

cat > "$QLOG" <<EOF
2026-09-13T11:02:00 pid=90210 505c5f0e 대기열 3번째
2026-09-13T11:40:00 pid=90210 505c5f0e pass (2280s) → /cache/505c5f0e.result
EOF
run_case "대기열 뒤 pass 줄 → 큐 이탈" \
  "none no_progress commit=60m queue=left claim=none" 0 \
  --now "$NOW" --commit-at "$OLD" --head-sha "$SHA"

# 소유권 필터 — 남의 티켓 **폐기 줄 본문**에만 우리 SHA 가 언급된 형상(새 push 가 앞선
# 티켓을 폐기시킨 정상 형상). 우리 줄이 아니므로 티켓 없음(none)이다.
cat > "$QLOG" <<EOF
2026-09-13T11:05:00 pid=90211 abcd1234 폐기 — 실행 시점 HEAD 가 505c5f0e ≠ abcd1234 (새 push 가 있었거나 로컬 HEAD 만 움직임)
EOF
run_case "남의 폐기 줄 본문 언급뿐 → 티켓 없음" \
  "none no_progress commit=60m queue=none claim=none" 0 \
  --now "$NOW" --commit-at "$OLD" --head-sha "$SHA"

cat > "$QLOG" <<EOF
2026-09-13T11:02:00 pid=90210 505c5f0e 대기열 3번째
2026-09-13T11:05:00 pid=90211 abcd1234 폐기 — 실행 시점 HEAD 가 505c5f0e ≠ abcd1234 (새 push 가 있었거나 로컬 HEAD 만 움직임)
EOF
run_case "우리 대기열 뒤에 남의 폐기 줄 → 여전히 대기 중" \
  "progress ci_queued commit=60m queue=queued claim=none" 0 \
  --now "$NOW" --commit-at "$OLD" --head-sha "$SHA"

# 회수 줄은 메시지가 짧은SHA 로 시작하지 않는다 — 티켓 이름(<epoch>.<pid>.<전체SHA>)으로 문다.
cat > "$QLOG" <<EOF
2026-09-13T11:02:00 pid=90210 505c5f0e 대기열 3번째
2026-09-13T11:30:00 pid=90212 유령 티켓 회수(pid 사망) 1789000000.0000090210.$SHA
EOF
run_case "유령 티켓 회수 줄(티켓 이름 매칭) → 큐 이탈" \
  "none no_progress commit=60m queue=left claim=none" 0 \
  --now "$NOW" --commit-at "$OLD" --head-sha "$SHA"

QLOG="$TMP/absent.log"
run_case "queue.log 부재 → nolog(증거 없음일 뿐)" \
  "none no_progress commit=60m queue=nolog claim=none" 0 \
  --now "$NOW" --commit-at "$OLD" --head-sha "$SHA"

# 로그를 **읽지 못한 것**은 "큐에 없다" 가 아니라 판정 불가(exit 2)다.
QLOG="$TMP/unreadable.log"
printf '2026-09-13T11:02:00 pid=90210 505c5f0e 대기열 3번째\n' > "$QLOG"
chmod 000 "$QLOG"
if [ -r "$QLOG" ]; then
  echo "  … 읽기 권한 제거가 먹지 않는 환경(root?) — logerr 행 생략"
else
  run_case "queue.log 읽기 실패 → 판정 불가" \
    "unknown queue_log_read_failed commit=60m queue=logerr claim=-" 2 \
    --now "$NOW" --commit-at "$OLD" --head-sha "$SHA"
fi
chmod u+rw "$QLOG"
QLOG="$TMP/absent.log"

# ── 3값 어휘 — unknown/빈 문자열/none 은 각각 다른 뜻이다 ────────────────
run_case "커밋 조회 실패(unknown) → 판정 불가" \
  "unknown commit_at_unknown commit=unknown queue=- claim=-" 2 \
  --now "$NOW" --commit-at unknown --head-sha "$SHA"
run_case "커밋 시각 형식 불량 → 판정 불가" \
  "unknown commit_at_invalid commit=- queue=- claim=-" 2 \
  --now "$NOW" --commit-at "2026-09-13 12:00:00" --head-sha none
# 빈 문자열은 none 이 아니다 — 호출자가 "커밋 없음" 을 말하려면 문자열 none 을 써야 한다.
run_case "커밋 빈 문자열 → none 이 아니라 형식 불량" \
  "unknown commit_at_invalid commit=- queue=- claim=-" 2 \
  --now "$NOW" --commit-at "" --head-sha none
# 진행 증거 ①이 살아 있어도 **조회 실패가 이긴다**(fail-shut).
run_case "SHA 조회 실패는 최신 커밋보다 앞선다" \
  "unknown head_sha_unknown commit=10m queue=unknown claim=-" 2 \
  --now "$NOW" --commit-at "$(iso_ago 600)" --head-sha unknown
# --head-sha 의 빈 문자열은 --commit-at 과 달리 none 과 같이 다룬다(계약 차이).
run_case "SHA 빈 문자열 → none 과 같이 다룬다" \
  "none no_progress commit=none queue=none claim=none" 0 \
  --now "$NOW" --commit-at none --head-sha ""
run_case "--now 가 정수가 아니면 판정 불가" \
  "unknown now_invalid commit=- queue=- claim=-" 2 \
  --now "" --commit-at none --head-sha none

# ── 증거 ③ 현재 회차 claim 신선도 (옵션 입력) ───────────────────────────
run_case "커밋·큐 없어도 claim 이 신선하면 진행(첫 푸시 전 창)" \
  "progress claim_fresh commit=none queue=none claim=30m" 0 \
  --now "$NOW" --commit-at none --head-sha none --claimed-at "$(iso_ago 1800)"
run_case "claim 이 정확히 ISSUE_TIMEBOX_HOURS(3600s) → 진행" \
  "progress claim_fresh commit=none queue=none claim=60m" 0 \
  --now "$NOW" --commit-at none --head-sha none --claimed-at "$(iso_ago 3600)"
run_case "claim 이 상한+1s → 무진전" \
  "none no_progress commit=none queue=none claim=60m" 0 \
  --now "$NOW" --commit-at none --head-sha none --claimed-at "$(iso_ago 3601)"
run_case "claim 조회 실패(unknown) → 판정 불가" \
  "unknown claimed_at_unknown commit=none queue=none claim=unknown" 2 \
  --now "$NOW" --commit-at none --head-sha none --claimed-at unknown
run_case "claim 시각 형식 불량 → 판정 불가" \
  "unknown claimed_at_invalid commit=none queue=none claim=-" 2 \
  --now "$NOW" --commit-at none --head-sha none --claimed-at "20260913"
# ③ 은 옵션이라 빈 문자열 = "안 줬다" = none (①의 빈 문자열과 정반대 계약).
run_case "claim 빈 문자열 → none 과 같이 다룬다" \
  "none no_progress commit=none queue=none claim=none" 0 \
  --now "$NOW" --commit-at none --head-sha none --claimed-at ""

# ── usage(exit 64) ──────────────────────────────────────────────────────
# 값 없는 플래그를 흘리면 인자 목록이 안 줄어 무한 재독으로 매달린다 — 그래서 usage 로 끊는다.
run_case "값 없는 플래그 → usage" "" 64 --now "$NOW" --commit-at none --head-sha
run_case "모르는 인자 → usage" "" 64 --now "$NOW" --bogus x

echo "progress-evidence.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
