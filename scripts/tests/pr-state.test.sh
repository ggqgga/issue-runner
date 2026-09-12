#!/usr/bin/env bash
# pr-state.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# #449: `references/state-machine.md` 의 행 이름을 기계가 읽는 진입점이 표와 1:1 인지 고정한다.
#   · 정상 사다리 여섯 칸(S0~S5) 각각
#   · 정지 네 종(H:policy·H:conflict·H:ladder·H:human) + 겹칠 때의 우선순위
#   · 반송(B) · 종료(E)
#   · mismatch 네 축(rung·stage·stop·verdict)과 **안 내는** 자리
#   · 조회 실패 → exit 2(추측한 상태를 내지 않는다)
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
#
# 스텁 계약: `gh pr view … --json state,labels,closingIssuesReferences` ·
# `gh issue view … --json labels` · `gh api …/comments --paginate`(pr-comments.sh) 셋만 안다.
# 그 밖의 호출은 **exit 1** — SUT 가 다른 gh 경로로 새면 그 케이스가 즉시 빨개진다.
# `bounce-state.sh` 는 `BOUNCE_COMMENTS_FILE` 로 같은 코멘트를 받으므로 gh 를 타지 않는다
# (그 계약이 깨지면 코멘트 조회가 두 번 뜨고 아래 "조회 실패" 케이스가 달라진다).
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/pr-state.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
paginate=0; jqf='.'; prev=''
for a in "$@"; do
  [ "$prev" = "--jq" ] && jqf="$a"
  [ "$a" = "--paginate" ] && paginate=1
  prev="$a"
done
if [ "$paginate" = 1 ]; then
  [ "${STUB_COMMENTS_RC:-0}" = 0 ] || exit "$STUB_COMMENTS_RC"
  # 픽스처는 GraphQL 형상(createdAt)이라 실 gh 처럼 REST 형상(created_at)으로 되돌린 뒤
  # 넘겨받은 --jq 를 적용한다(pr-comments.sh 의 실제 계약).
  printf '%s' "$STUB_COMMENTS" \
    | jq -c '[.[] | {body: .body, created_at: .createdAt}]' | jq -c "$jqf"
  exit 0
fi
case "$*" in
  *"pr view"*"--json state,labels,closingIssuesReferences"*)
    [ "${STUB_PR_RC:-0}" = 0 ] || exit "$STUB_PR_RC"
    printf '%s\n' "$STUB_PR_META" ;;
  *"issue view"*"--json labels"*)
    [ "${STUB_ISSUE_RC:-0}" = 0 ] || exit "$STUB_ISSUE_RC"
    printf '%s\n' "$STUB_ISSUE_LABELS" ;;
  *)
    echo "STUB: 예상 밖 gh 호출: $*" >&2
    exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# meta <labels-json> <state> <issue|->  → gh pr view 응답
meta() {
  jq -n --argjson l "$1" --arg s "$2" --arg i "$3" '{
    state: $s,
    labels: [$l[] | {name: .}],
    closingIssuesReferences: (if $i == "-" then [] else [{number: ($i | tonumber)}] end)
  }'
}
# ilabels <labels-json> → gh issue view 응답
ilabels() { jq -n --argjson l "$1" '{labels: [$l[] | {name: .}]}'; }

# 코멘트 픽스처
C_NONE='[]'
C_PENDING='[{"body":"머지 판정: 🔄 진행 중","createdAt":"2026-09-01T00:00:00Z"}]'
C_OK='[{"body":"머지 판정: 🔄 진행 중","createdAt":"2026-09-01T00:00:00Z"},
       {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-01T00:10:00Z"}]'
# 반송 — ✅ 뒤에 반송 마커가 오고 그 뒤 판정이 없다(bounce-state.sh 의 `bounced`).
C_BOUNCED='[{"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-01T00:10:00Z"},
            {"body":"재검증 실패: #449 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-01T00:20:00Z"}]'

# run <pr-labels-json> <issue-labels-json|-> <pr_state> <comments-json>
#   두 번째 인자가 `-` 면 연결 이슈 없음(closingIssuesReferences 빈 배열).
run() {
  local pl="$1" il="$2" st="$3" cm="$4" m
  if [ "$il" = "-" ]; then m=$(meta "$pl" "$st" "-"); else m=$(meta "$pl" "$st" 449); fi
  out=$(PATH="$tmp/bin:$PATH" \
    STUB_PR_META="$m" \
    STUB_ISSUE_LABELS="$( [ "$il" = "-" ] && echo '{"labels":[]}' || ilabels "$il" )" \
    STUB_COMMENTS="$cm" \
    STUB_PR_RC="${STUB_PR_RC:-0}" STUB_ISSUE_RC="${STUB_ISSUE_RC:-0}" \
    STUB_COMMENTS_RC="${STUB_COMMENTS_RC:-0}" \
    bash "$SUT" owner/repo 5 2>"$tmp/last.err")
  rc=$?
}

# expect <name> <state> <owner> <mismatch-jq-단언> <pr-labels> <issue-labels|-> <pr_state> <comments>
expect() {
  local name="$1" want_state="$2" want_owner="$3" mm="$4"
  run "$5" "$6" "$7" "$8"
  if [ "$rc" != 0 ]; then bad "$name — exit $rc (기대 0) err=[$(cat "$tmp/last.err")]"; return; fi
  local got_state got_owner
  got_state=$(printf '%s' "$out" | jq -r '.state')
  got_owner=$(printf '%s' "$out" | jq -r '.owner')
  if [ "$got_state" = "$want_state" ] && [ "$got_owner" = "$want_owner" ] \
     && printf '%s' "$out" | jq -e "$mm" >/dev/null 2>&1; then
    ok
  else
    bad "$name — state=$got_state owner=$got_owner (기대 $want_state/$want_owner) out=$out"
  fi
}

NOMM='.mismatch == []'

# ── 정상 사다리 여섯 칸 ─────────────────────────────────────────────────
expect "S0 반송 뒤 대기칸" S0 issue-runner "$NOMM" \
  '["flow:agent-ready"]' '["agent-ready"]' OPEN "$C_NONE"
# `flow:ci`·`flow:codex` 는 S1 안의 워커 내부 단계라 칸으로 안 센다 — stage 축이 오발하면 안 된다.
expect "S1 워커 구현 중(+flow:ci·flow:codex)" S1 worker "$NOMM" \
  '["flow:claimed","flow:ci","flow:codex"]' '["agent:claimed","agent-ready"]' OPEN "$C_PENDING"
expect "S2 검증 대기" S2 verify-runner "$NOMM" \
  '["flow:verify"]' '["flow:verify","agent-ready"]' OPEN "$C_PENDING"
expect "S3 검증 중(점유)" S3 verify-runner "$NOMM" \
  '["verifying"]' '["verifying","agent-ready"]' OPEN "$C_PENDING"
expect "S4 마감 대기" S4 closeout "$NOMM" \
  '["flow:ready"]' '["flow:ready","agent-ready"]' OPEN "$C_OK"
expect "S5 마감 진행(점유)" S5 closeout "$NOMM" \
  '["harvesting"]' '["harvesting","agent-ready"]' OPEN "$C_OK"

# ── 정지 네 종 ──────────────────────────────────────────────────────────
expect "H:ladder" "H:ladder" resume-sweep "$NOMM" \
  '["hold:ladder","flow:verify"]' '["hold:ladder","flow:verify","agent-ready"]' OPEN "$C_PENDING"
expect "H:policy" "H:policy" issue-runner "$NOMM" \
  '["hold:policy","flow:verify"]' '["hold:policy","flow:verify","agent-ready"]' OPEN "$C_PENDING"
expect "H:conflict" "H:conflict" human "$NOMM" \
  '["hold:conflict","flow:verify"]' '["hold:conflict","flow:verify","agent-ready"]' OPEN "$C_PENDING"
expect "H:human" "H:human" human "$NOMM" \
  '["needs-human","hold:policy"]' '["needs-human","hold:policy","agent-ready"]' OPEN "$C_PENDING"
# 겹칠 때의 순서 — 사람 > conflict > policy > ladder.
expect "겹침: needs-human 이 hold:ladder 를 이긴다" "H:human" human "$NOMM" \
  '["needs-human","hold:ladder"]' '["needs-human","hold:ladder","agent-ready"]' OPEN "$C_PENDING"
expect "겹침: conflict 가 ladder 를 이긴다" "H:conflict" human "$NOMM" \
  '["hold:conflict","hold:ladder"]' '["hold:conflict","hold:ladder","agent-ready"]' OPEN "$C_PENDING"
# 표에 행이 없는 새 사유 → 자동 재개 칸이 아니라 사람 재심이 있는 H:policy 로 접는다.
expect "미지의 hold:<사유> → H:policy" "H:policy" issue-runner "$NOMM" \
  '["hold:quota"]' '["hold:quota","agent-ready"]' OPEN "$C_PENDING"
# 정지는 사다리 칸을 이긴다 — harvesting 이 붙어 있어도 상태는 정지다(세 게이트가 제외한다).
expect "정지가 사다리 칸을 이긴다" "H:policy" issue-runner "$NOMM" \
  '["harvesting","hold:policy"]' '["harvesting","hold:policy","agent-ready"]' OPEN "$C_OK"

expect "verdict 축 억제 — 정지(H:*) 상태" "H:policy" issue-runner \
  '.mismatch | any(startswith("verdict: ")) | not' \
  '["hold:policy"]' '["hold:policy","agent-ready"]' OPEN "$C_OK"

# ── 반송 · 종료 ─────────────────────────────────────────────────────────
expect "B 반송 회차" B worker "$NOMM" \
  '["flow:agent-ready"]' '["agent-ready"]' OPEN "$C_BOUNCED"
# 종료 행은 mismatch 를 안 낸다 — 미러가 어긋난 채 머지돼도 고칠 주체가 없다.
expect "E 머지됨(미러 어긋나 있어도 mismatch 없음)" E - "$NOMM" \
  '["harvesting","flow:verify"]' '["agent-ready"]' MERGED "$C_OK"
expect "E 닫힘" E - "$NOMM" \
  '[]' '["agent-ready"]' CLOSED "$C_NONE"

# ── mismatch 네 축 ──────────────────────────────────────────────────────
expect "mismatch rung — PR 은 S2 인데 이슈는 S1" S2 verify-runner \
  '.mismatch | index("rung: pr=S2 issue=S1") != null' \
  '["flow:verify"]' '["agent:claimed","agent-ready"]' OPEN "$C_PENDING"
expect "mismatch stage — PR 에 소유 라벨 둘(반쯤 이동)" S3 verify-runner \
  '.mismatch | any(startswith("stage: "))' \
  '["flow:verify","verifying"]' '["verifying","agent-ready"]' OPEN "$C_PENDING"
expect "mismatch stop — 정지가 PR 에만" "H:policy" issue-runner \
  '.mismatch | any(startswith("stop: "))' \
  '["hold:policy","flow:verify"]' '["flow:verify","agent-ready"]' OPEN "$C_PENDING"
# 규칙0 안전망 — 미러 없이 열린 옛 PR. 항목은 **붙일 라벨**을 낸다(행 이름이 아니다):
# 소비자가 S4→flow:ready 를 자기 벌로 다시 외우면 그 매핑이 두 벌이 된다.
expect "mismatch verdict — 무라벨 PR + ✅ → flow:ready" S0 issue-runner \
  '.mismatch | index("verdict: pr=S0 target=flow:ready") != null' \
  '[]' '["agent-ready"]' OPEN "$C_OK"
expect "mismatch verdict — 무라벨 PR + 🔄 → flow:verify" S0 issue-runner \
  '.mismatch | index("verdict: pr=S0 target=flow:verify") != null' \
  '[]' '["agent-ready"]' OPEN "$C_PENDING"
# 반송 회차(B)도 정상 레인이라 같은 안전망을 받는다 — 항목의 `pr=` 는 실제 행 이름이다.
expect "mismatch verdict — B 행도 target 을 낸다" B worker \
  '.mismatch | index("verdict: pr=B target=flow:verify") != null' \
  '[]' '["agent-ready"]' OPEN '[{"body":"재검증 실패: #449 — E2E 1건 (attempt 1)","createdAt":"2026-09-01T00:00:00Z"},
                                {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-09-01T00:10:00Z"}]'
# **안 내는** 자리 — #420·#275. flow:agent-ready·소유 라벨이 붙은 PR 은 판정만 보고 올리지 않는다.
expect "verdict 축 억제 — flow:agent-ready PR" S0 issue-runner \
  '.mismatch | any(startswith("verdict: ")) | not' \
  '["flow:agent-ready"]' '["agent-ready"]' OPEN "$C_OK"
expect "verdict 축 억제 — flow:claimed PR(살아있는 워커)" S1 worker \
  '.mismatch | any(startswith("verdict: ")) | not' \
  '["flow:claimed"]' '["agent:claimed","agent-ready"]' OPEN "$C_OK"
expect "verdict 축 억제 — ⚠ 보류는 단계 라벨 없음이 정답" S0 issue-runner \
  '.mismatch | any(startswith("verdict: ")) | not' \
  '[]' '["agent-ready"]' OPEN '[{"body":"머지 판정: ⚠ 보류 — 사람 결정 필요","createdAt":"2026-09-01T00:10:00Z"}]'

# ── 연결 이슈 없음 — 이슈 축이 없으니 rung·stop 을 비교하지 않는다 ───────
expect "연결 이슈 없음 — 미러 축 없음" "H:policy" issue-runner "$NOMM" \
  '["hold:policy","flow:verify"]' '-' OPEN "$C_PENDING"
expect "연결 이슈 없음 — 사다리 칸은 PR 라벨로 낸다" S2 verify-runner "$NOMM" \
  '["flow:verify"]' '-' OPEN "$C_PENDING"

# ── 조회 실패 → exit 2 · 무출력 (추측한 상태를 내지 않는다) ─────────────
STUB_PR_RC=1
run '["flow:verify"]' '["flow:verify"]' OPEN "$C_PENDING"
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok; else bad "PR 조회 실패 → exit 2 무출력 (rc=$rc out=[$out])"; fi
STUB_PR_RC=0

STUB_ISSUE_RC=1
run '["flow:verify"]' '["flow:verify"]' OPEN "$C_PENDING"
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok; else bad "이슈 조회 실패 → exit 2 무출력 (rc=$rc out=[$out])"; fi
STUB_ISSUE_RC=0

STUB_COMMENTS_RC=1
run '["flow:verify"]' '["flow:verify"]' OPEN "$C_PENDING"
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok; else bad "코멘트 조회 실패 → exit 2 무출력 (rc=$rc out=[$out])"; fi
STUB_COMMENTS_RC=0

# ── 호출 형태 오류 → exit 64 ────────────────────────────────────────────
for bad_args in "" "owner/repo" "owner/repo x" "owner/repo 5 extra"; do
  # shellcheck disable=SC2086
  out=$(PATH="$tmp/bin:$PATH" bash "$SUT" $bad_args 2>/dev/null); rc=$?
  if [ "$rc" = 64 ] && [ -z "$out" ]; then ok; else
    bad "usage '$bad_args' → exit 64 무출력 (rc=$rc out=[$out])"; fi
done

# ── 실행 비트 — SKILL 이 `$SCRIPTS/pr-state.sh` 로 직접 exec 한다 ────────
# (비트가 빠지면 조용히 exit 126 → 상태가 항상 빈 값으로 degrade 한다 —
#  pr-head-at·bounce-state·bounce-comment 가 이미 밟은 함정.)
if [ -x "$SUT" ]; then ok; else bad "pr-state.sh 실행 비트 없음"; fi

echo "pr-state.test.sh: pass=$pass fail=$fail"
[ "$fail" = 0 ]
