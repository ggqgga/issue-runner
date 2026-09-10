#!/usr/bin/env bash
# timebox-check.sh 픽스처 테스트 (#200) — 네트워크 무접속(모든 입력을 env·스텁으로 주입).
# 판정을 "경과" 가 아니라 "진행 증거" 로 바꾼 계약을 결정적으로 검증한다:
#   ⓐ 경과 초과 + 최신 커밋 STALL_MIN 이내            → 유예
#   ⓑ 경과 초과 + 낡은 커밋 + 큐에 티켓 없음          → 중단
#   ⓒ 경과 초과 + 낡은 커밋 + 그 SHA 가 큐에 살아있음 → 유예
#   ⓓ ⓒ 와 같은데 그 SHA 뒤에 pass 줄이 있음(큐 이탈) → 중단
#   ⓔ 연속 유예가 MAX_TIMEBOX_GRACE 소진              → 중단
# 여기에 queue.log **마지막 줄** 규칙(재큐 정상 형상)·마커 카운트 창(claim 이후만)·
# 조회 실패와 빈 결과의 구분(unknown vs 정상)을 함께 문다.
# bats 미도입 레포 — finish-classify.test.sh 와 같은 순수 bash assert 관행.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/timebox-check.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stub"

# gh 스텁 — 인자를 GH_LOG 에 기록하고 GH_MODE 로 응답을 고른다(네트워크 무접속).
cat > "$TMP/stub/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "${GH_MODE:-ok}" in
  fail_branch)   echo "gh: could not connect" >&2; exit 1 ;;
  # 없는 브랜치의 실제 지문 — 이 엔드포인트는 404 가 아니라 422 를 낸다(실측).
  missing_branch) echo "gh: No commit found for SHA: agent/issue-200 (HTTP 422)" >&2; exit 1 ;;
  # 레포 자체를 못 찾음 — 이건 부재가 아니라 조회 실패다(권한 상실·오타).
  repo_404)      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  fail_comments)
    # 코멘트 **조회** 실패(게시 실패와 다른 갈래) — commits 는 정상 응답한다.
    case "$*" in
      *"/issues/"*"/comments"*) exit 1 ;;
      *"repos/"*"/commits/"*) echo "cafe1234deadbeef 2026-09-11T04:55:00Z" ;;
      *) : ;;
    esac ;;
  fail_comment)
    case "$*" in
      *"issue comment"*) exit 1 ;;
      *"repos/"*"/commits/"*) echo "cafe1234deadbeef 2026-09-11T04:55:00Z" ;;
      *) : ;;
    esac ;;
  *)
    case "$*" in
      *"repos/"*"/commits/"*) echo "cafe1234deadbeef 2026-09-11T04:55:00Z" ;;
      *) : ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$TMP/stub/gh"
export PATH="$TMP/stub:$PATH"
export GH_LOG="$TMP/gh.log"

# 고정 시각 — NOW = 2026-09-11T05:00:00Z, claim = 03:48Z (경과 72분, 실측 bodat #5020 형상)
NOW=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-09-11T05:00:00Z" +%s 2>/dev/null \
  || date -u -d "2026-09-11T05:00:00Z" +%s)
CLAIM="2026-09-11T03:48:00Z"
SHA="505c5f0e1234567890abcdef1234567890abcdef"   # short = 505c5f0e
OTHER="da323b67fedcba0987654321fedcba0987654321"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $*"; }

# run_raw <env=val …> — SUT 를 부르고 판정 줄은 stdout, **종료코드는 파일**($TMP/rc)에 남긴다.
# 종료코드를 셸 변수로 넘기지 않는 이유: 호출부가 `out=$(run …)` 형태라 run 이 서브셸에서
# 돌아 그 안의 대입은 호출자에 남지 않는다 — 그러면 rc 단언이 항상 0 을 보며 조용히
# 공회전한다(이 파일 첫 실행에서 실제로 그랬다).
run_raw() {
  local rc=0
  env "$@" "$SUT" owner/repo 200 >"$TMP/out" 2>/dev/null || rc=$?
  printf '%s' "$rc" > "$TMP/rc"
  cat "$TMP/out"
}

# run <queue.log 내용|-> [env=val ...] — 공통 env 를 붙인 run_raw
run() {
  local qlog="$1"; shift
  local qpath="$TMP/queue.log"
  if [ "$qlog" = "-" ]; then rm -f "$qpath"; else printf '%s\n' "$qlog" > "$qpath"; fi
  run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$qpath" TB_NO_POST=1 \
      STALL_MIN=25 MAX_TIMEBOX_GRACE=3 ISSUE_TIMEBOX_HOURS=1 "$@"
}

# assert <이름> <기대 verdict> <기대 reason> <기대 rc> <출력>
assert_verdict() {
  local name="$1" v="$2" r="$3" rc="$4" out="$5" got_rc
  local got_v="${out%% *}" rest="${out#* }" got_r
  got_r="${rest%% *}"
  got_rc=$(cat "$TMP/rc" 2>/dev/null)
  if [ "$got_v" = "$v" ] && [ "$got_r" = "$r" ] && [ "$got_rc" = "$rc" ]; then ok
  else bad "$name — 기대='$v $r' rc=$rc, 실제='$got_v $got_r' rc=$got_rc (전체: $out)"; fi
}

QUEUED="2026-09-11T04:32:00 pid=11111 505c5f0e 대기열 2번째"
PASSLINE="2026-09-11T04:50:00 pid=11111 505c5f0e pass (487s) → /Users/x/.claude/.local-ci/repo/$SHA.result"

echo "[timebox-check] ⓐ~ⓔ 코어 5케이스"

# ⓐ 경과 초과(72분) + 최신 커밋 5분 전 → 유예(진행 증거=커밋). 큐 증거는 없어도 된다.
out=$(run "-" TB_LAST_COMMIT_AT="2026-09-11T04:55:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "ⓐ 커밋 5분 전 → 유예" grace recent_commit 0 "$out"

# ⓑ 경과 초과 + 커밋 90분 전 + 큐에 그 SHA 줄 없음 → 중단
out=$(run "2026-09-11T04:32:00 pid=22222 da323b67 대기열 1번째" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "ⓑ 낡은 커밋 + 큐 부재 → 중단" stop no_progress 1 "$out"

# ⓒ 경과 초과 + 커밋 90분 전 + 그 SHA 가 `대기열 2번째` 로 살아있음 → 유예
out=$(run "$QUEUED" TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "ⓒ 큐에 살아있음 → 유예" grace ci_queued 0 "$out"

# ⓓ ⓒ 와 같은데 그 SHA 뒤에 pass 줄이 있음(=큐를 떠났다) → 중단
out=$(run "$QUEUED
$PASSLINE" TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "ⓓ 뒤에 pass → 중단" stop no_progress 1 "$out"

# ⓔ 연속 유예 3회(=MAX) 소진 → 진행 증거가 있어도 중단
out=$(run "$QUEUED" TB_LAST_COMMIT_AT="2026-09-11T04:55:00Z" TB_HEAD_SHA="$SHA" \
  TB_COMMENTS_JSON='[
    {"body":"타임박스 유예 1/3 <!-- timebox-grace: 1 -->","created_at":"2026-09-11T04:00:00Z"},
    {"body":"타임박스 유예 2/3 <!-- timebox-grace: 2 -->","created_at":"2026-09-11T04:20:00Z"},
    {"body":"타임박스 유예 3/3 <!-- timebox-grace: 3 -->","created_at":"2026-09-11T04:40:00Z"}
  ]')
assert_verdict "ⓔ 유예 상한 소진 → 중단" stop grace_exhausted 1 "$out"

echo "[timebox-check] 경과·경계"

# 경과가 아직 타임박스 이내 → ok (진행 증거를 볼 필요조차 없다)
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="2026-09-11T04:30:00Z" TB_NO_POST=1 \
  TB_QUEUE_LOG="$TMP/none.log" TB_LAST_COMMIT_AT=none TB_HEAD_SHA=none TB_COMMENTS_JSON='[]')
assert_verdict "경과 30분 → ok" ok within_timebox 0 "$out"

# 커밋이 정확히 STALL_MIN(25분) 전 → 아직 '무진전' 이 아니다(경계 포함)
out=$(run "-" TB_LAST_COMMIT_AT="2026-09-11T04:35:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "커밋 정확히 25분 전 → 유예(경계 포함)" grace recent_commit 0 "$out"

# 26분 전 + 큐 증거 없음 → 중단
out=$(run "-" TB_LAST_COMMIT_AT="2026-09-11T04:34:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "커밋 26분 전 + 큐 없음 → 중단" stop no_progress 1 "$out"

# 브랜치·커밋이 아예 없음(아직 push 없음) + 큐 없음 → 중단 (빈 입력은 정상 입력이다)
out=$(run "-" TB_LAST_COMMIT_AT=none TB_HEAD_SHA=none TB_COMMENTS_JSON='[]')
assert_verdict "브랜치 없음 → 중단" stop no_progress 1 "$out"
case "$out" in *"commit=none"*"queue=none"*) ok ;; *) bad "브랜치 없음 필드 — 실제: $out" ;; esac

echo "[timebox-check] queue.log 는 그 SHA 의 **마지막 줄**로 판정한다(재큐가 정상)"

# 폐기 뒤 재큐 — 마지막 줄이 대기열이면 살아있다
out=$(run "$QUEUED
2026-09-11T04:40:00 pid=11111 505c5f0e 폐기 — 실행 시점 HEAD 가 aaaa1111 ≠ 505c5f0e (새 push 가 있었거나 로컬 HEAD 만 움직임)
2026-09-11T04:41:00 pid=33333 505c5f0e 대기열 3번째" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "폐기 → 재큐 → 유예" grace ci_queued 0 "$out"

# 중단(INT/TERM) 이 마지막 → 떠났다
out=$(run "$QUEUED
2026-09-11T04:40:00 pid=11111 505c5f0e 중단(INT/TERM)" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "중단(INT/TERM) 이 마지막 → 중단" stop no_progress 1 "$out"

# 유령 티켓 회수 — 이 줄은 **티켓 이름(전체 SHA)** 을 담는다(짧은 SHA 접두가 아니다).
# 대기열 줄 뒤에 오면 그 티켓은 회수된 것이므로 살아있다고 읽으면 안 된다.
out=$(run "$QUEUED
2026-09-11T04:45:00 pid=44444 유령 티켓 회수(pid 사망) 0001757000.0000011111.$SHA" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "유령 티켓 회수가 마지막 → 중단" stop no_progress 1 "$out"

# 회수 뒤 재큐 → 다시 살아있다
out=$(run "$QUEUED
2026-09-11T04:45:00 pid=44444 유령 티켓 회수(pid 사망) 0001757000.0000011111.$SHA
2026-09-11T04:46:00 pid=55555 505c5f0e 대기열 1번째" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "회수 → 재큐 → 유예" grace ci_queued 0 "$out"

# fail 로 끝난 뒤 재큐하지 않은 상태 → 떠났다
out=$(run "$QUEUED
2026-09-11T04:50:00 pid=11111 505c5f0e fail (501s) → /x/$SHA.result" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "fail 이 마지막 → 중단" stop no_progress 1 "$out"

# **소유권 필터** — 앞선 옛 티켓(aaaa1111)의 폐기 줄은 본문에 우리 SHA 를 담는다
# (`… 폐기 — 실행 시점 HEAD 가 <우리SHA> ≠ aaaa1111`). 새 push 가 자기 티켓을 낸 흔한
# 형상이라 이 줄을 우리 줄로 세면 큐에서 기다리는 살아있는 워커가 죽는다.
out=$(run "$QUEUED
2026-09-11T04:43:00 pid=66666 aaaa1111 폐기 — 실행 시점 HEAD 가 505c5f0e ≠ aaaa1111 (새 push 가 있었거나 로컬 HEAD 만 움직임)" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "남의 폐기 줄이 우리 SHA 를 언급 → 여전히 유예" grace ci_queued 0 "$out"

# 우리 SHA 를 **언급만** 하는 남의 줄뿐이면 우리 티켓은 큐에 없던 것(left 가 아니라 none)
out=$(run "2026-09-11T04:43:00 pid=66666 aaaa1111 폐기 — 실행 시점 HEAD 가 505c5f0e ≠ aaaa1111" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "남의 줄만 있음 → 중단" stop no_progress 1 "$out"
case "$out" in *"queue=none"*) ok ;; *) bad "남의 줄만 있음 — 기대 queue=none, 실제: $out" ;; esac

# 중단 갈래의 grace 필드는 **미집계**(-)여야 한다 — 0 으로 찍으면 "유예를 한 번도 안 썼다" 로
# 읽히는데 실제로는 세기 전에 나간 것이다.
case "$out" in *"grace=-/3"*) ok ;; *) bad "중단 시 grace 미집계 표기 — 기대 grace=-/3, 실제: $out" ;; esac

# 다른 SHA 의 대기열 줄은 내 증거가 아니다(SHA 매칭)
out=$(run "2026-09-11T04:32:00 pid=22222 ${OTHER:0:8} 대기열 1번째" \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "다른 SHA 의 대기열 → 중단" stop no_progress 1 "$out"

# queue.log 자체가 없는 박스(로컬 CI 미사용) → 큐 증거 없음(unknown 아님)
out=$(run "-" TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "queue.log 부재 → 중단" stop no_progress 1 "$out"
case "$out" in *"queue=nolog"*) ok ;; *) bad "queue.log 부재 필드 — 실제: $out" ;; esac

echo "[timebox-check] 유예 횟수 — 현재 claim 이후 마커만 센다(재파생)"

# claim(03:48) **이전** 마커 3개는 지난 회차의 것 — 세지 않는다 → 이번 유예는 1/3
out=$(run "$QUEUED" TB_LAST_COMMIT_AT="2026-09-11T04:55:00Z" TB_HEAD_SHA="$SHA" \
  TB_COMMENTS_JSON='[
    {"body":"<!-- timebox-grace: 1 -->","created_at":"2026-09-11T01:00:00Z"},
    {"body":"<!-- timebox-grace: 2 -->","created_at":"2026-09-11T01:20:00Z"},
    {"body":"<!-- timebox-grace: 3 -->","created_at":"2026-09-11T01:40:00Z"}
  ]')
assert_verdict "claim 이전 마커는 무시 → 유예" grace recent_commit 0 "$out"
case "$out" in *"grace=1/3"*) ok ;; *) bad "claim 이전 마커 카운트 — 기대 grace=1/3, 실제: $out" ;; esac

# claim 이후 2개 → 마지막 유예(3/3)
out=$(run "$QUEUED" TB_LAST_COMMIT_AT="2026-09-11T04:55:00Z" TB_HEAD_SHA="$SHA" \
  TB_COMMENTS_JSON='[
    {"body":"<!-- timebox-grace: 1 -->","created_at":"2026-09-11T04:00:00Z"},
    {"body":"<!-- timebox-grace: 2 -->","created_at":"2026-09-11T04:20:00Z"}
  ]')
assert_verdict "claim 이후 2개 → 마지막 유예" grace recent_commit 0 "$out"
case "$out" in *"grace=3/3"*) ok ;; *) bad "마지막 유예 카운트 — 기대 grace=3/3, 실제: $out" ;; esac

# 마커가 아닌 코멘트는 세지 않는다
out=$(run "$QUEUED" TB_LAST_COMMIT_AT="2026-09-11T04:55:00Z" TB_HEAD_SHA="$SHA" \
  TB_COMMENTS_JSON='[
    {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","created_at":"2026-09-11T04:10:00Z"},
    {"body":"타임박스 유예 1/3 … <!-- timebox-grace: 1 --><!-- bodat:worker -->","created_at":"2026-09-11T04:30:00Z"}
  ]')
case "$out" in *"grace=2/3"*) ok ;; *) bad "마커 아닌 코멘트 제외 — 기대 grace=2/3, 실제: $out" ;; esac

echo "[timebox-check] 조회 실패와 빈 결과를 구분한다(unknown)"

# claim 시각이 없거나 형식 불량 → 판정 불가(exit 2). 절대 '중단' 으로 새지 않는다.
out=$(run_raw TB_NOW="$NOW" TB_NO_POST=1 TB_QUEUE_LOG="$TMP/none.log")
assert_verdict "claim 시각 부재 → unknown" unknown claim_at_invalid 2 "$out"
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="어제" TB_NO_POST=1 TB_QUEUE_LOG="$TMP/none.log")
assert_verdict "claim 시각 형식 불량 → unknown" unknown claim_at_invalid 2 "$out"

# 브랜치 조회가 **실패**(404 아님) → unknown. 살아있는 워커를 조회 실패로 죽이지 않는다.
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$TMP/none.log" TB_NO_POST=1 \
  GH_MODE=fail_branch)
assert_verdict "브랜치 조회 실패 → unknown" unknown branch_lookup_failed 2 "$out"

# 422 `No commit found`(브랜치 없음)는 **정상 입력** — 커밋 증거 없음으로 진행해 중단까지 간다.
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$TMP/none.log" TB_NO_POST=1 \
  TB_COMMENTS_JSON='[]' GH_MODE=missing_branch)
assert_verdict "브랜치 422(부재) → 중단(unknown 아님)" stop no_progress 1 "$out"

# 반대편 — 레포 404 는 **부재가 아니라 실패**다. 404 를 부재로 접으면 권한 상실 한 번에
# 살아있는 워커를 죽인다(이 경계를 넓게 잡았다가 실 gh 스모크에서 뒤집힌 자리).
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$TMP/none.log" TB_NO_POST=1 \
  TB_COMMENTS_JSON='[]' GH_MODE=repo_404)
assert_verdict "레포 404 → unknown(중단 아님)" unknown branch_lookup_failed 2 "$out"

# queue.log 를 **읽지 못함**(권한) → "큐에 없다" 가 아니라 판정 불가. 읽기 실패를 증거
# 없음으로 접으면 파일 하나 깨진 박스가 살아있는 워커를 전부 죽인다.
unreadable="$TMP/unreadable.log"
printf '%s\n' "$QUEUED" > "$unreadable"; chmod 000 "$unreadable"
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$unreadable" TB_NO_POST=1 \
  TB_LAST_COMMIT_AT="2026-09-11T03:30:00Z" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "queue.log 읽기 실패 → unknown" unknown queue_log_read_failed 2 "$out"
chmod 644 "$unreadable"

# 커밋 시각을 얻었는데 형식이 아님 → 판정 불가(그럴듯한 값으로 새지 않는다)
out=$(run "-" TB_LAST_COMMIT_AT="어제" TB_HEAD_SHA="$SHA" TB_COMMENTS_JSON='[]')
assert_verdict "커밋 시각 형식 불량 → unknown" unknown commit_at_invalid 2 "$out"

# 코멘트 **조회** 실패 → unknown. 조회 실패를 "마커 0개" 로 읽으면 상한이 영영 안 걸린다.
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$TMP/none.log" TB_NO_POST=1 \
  GH_MODE=fail_comments)
assert_verdict "코멘트 조회 실패 → unknown" unknown comments_lookup_failed 2 "$out"

echo "[timebox-check] 유예 마커는 실제로 append 된다(그래야 다음 틱이 셀 수 있다)"

# 실조회 경로 — gh 스텁이 commits 로 최신 커밋(04:55Z)을 주고, 코멘트 조회는 빈 출력(마커 0개).
: > "$GH_LOG"
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$TMP/none.log" \
  GH_MODE=ok)
assert_verdict "실조회 경로 → 유예" grace recent_commit 0 "$out"
if grep -q -e 'issue comment 200 --repo owner/repo' -- "$GH_LOG" \
   && grep -q -e 'timebox-grace: 1' -- "$GH_LOG"; then ok
else bad "유예 마커 코멘트 미게시 — gh 호출: $(cat "$GH_LOG")"; fi

# 마커를 못 남기면 유예를 셀 수 없다 → grace 로 통과시키지 않고 unknown(warn)
out=$(run_raw TB_NOW="$NOW" TB_CLAIM_AT="$CLAIM" TB_QUEUE_LOG="$TMP/none.log" \
  GH_MODE=fail_comment)
assert_verdict "마커 게시 실패 → unknown" unknown grace_marker_post_failed 2 "$out"

echo "  timebox-check: $pass 통과 / $fail 실패"
[ "$fail" = 0 ]
