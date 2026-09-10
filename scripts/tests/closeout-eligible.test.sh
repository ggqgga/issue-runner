#!/usr/bin/env bash
# closeout-eligible.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# #171: 반송(재디스패치)된 PR 이 낡은 `머지 판정: ✅` 로 다시 머지 후보에 오르지
# 않는지 검증한다. 두 방어선을 함께 문다:
#   1·2) finish-classify.sh 재사용 — ✅ 가 head 커밋보다 이르면 done_verdict 가
#        아니므로 후보에서 빠진다(반송 뒤 새 커밋이 올라온 형상).
#   3)   재디스패치 마커 안전망 — 반송 뒤 아직 새 커밋이 없어 head 시각이 그대로라
#        1·2 가 못 잡는 창을 막는다(최신 재디스패치: 코멘트가 최신 ✅ 보다 뒤면 제외).
# bats 미도입 레포라 reconcile.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/closeout-eligible.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# ── 작업 cwd — $PWD/.loop/repos 부재라 in_scope 는 전 레포 허용(fail-open, 실증 전제) ──
cwd="$tmp/cwd"
mkdir -p "$cwd"

# ── repo-dir.sh 해석 대상 — bin/ci 없는 레포(GitHub rollup 폴백 경로 고정) ──
mkdir -p "$tmp/proj/repo"

# ── gh 스텁 — 호출 형태별 응답. STUB_META 의 .comments 를 STUB_COMMENTS 로도 함께 준다
#    (closeout-eligible 자신의 meta 조회와 finish-classify 서브프로세스의 재조회가
#    같은 값을 봐야 픽스처가 일관된다). ──
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"api user"*) printf '%s\n' "${STUB_ME:-tester}" ;;
  *"search/issues"*) printf '%s\n' "$STUB_PRS" ;;
  *"--json headRefName"*) printf '%s\n' "$STUB_META" ;;
  *"--json comments -q"*) printf '%s\n' "$STUB_COMMENTS" ;;
  *"--json statusCheckRollup -q"*) printf '%s\n' "${STUB_FAILING:-0}" ;;
  *"--json commits -q"*) printf '%s\n' "${STUB_HEAD_AT:-}" ;;
  *"--json statusCheckRollup"*) printf '%s\n' "$STUB_ROLLUP" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

stub_rollup='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'

# build_meta <comments-json> → 전체 PR meta JSON(comments 를 끼워 넣는다)
build_meta() {
  jq -n --argjson comments "$1" '{
    headRefName: "agent/issue-166",
    mergeable: "MERGEABLE",
    labels: [],
    comments: $comments,
    closingIssuesReferences: [{number: 166}]
  }'
}

# run_case <name> <expect_candidate:yes|no> <comments-json> <head_at>
run_case() {
  local name="$1" expect="$2" comments="$3" head_at="$4"
  local meta out n verdict
  meta=$(build_meta "$comments")
  out=$(cd "$cwd" && PATH="$tmp/bin:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS='[{"repo":"owner/repo","pr":5}]' \
    STUB_META="$meta" STUB_COMMENTS="$comments" STUB_HEAD_AT="$head_at" \
    STUB_ROLLUP="$stub_rollup" \
    bash "$SUT" 2>/dev/null)
  n=$(printf '%s' "$out" | grep -c . || true)

  if [ "$expect" = yes ]; then
    verdict="ok"
    { [ "$n" = 1 ] && printf '%s' "$out" | jq -e '.pr == 5' >/dev/null 2>&1; } || verdict="no"
  else
    verdict="ok"
    [ "$n" = 0 ] || verdict="no"
  fi

  if [ "$verdict" = ok ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$([ "$expect" = yes ] && echo candidate || echo no-candidate) 실제 라인수=$n out=[$out]"
  fi
}

# 1) 정상 형상(반송 없음) — ✅ 가 유일한 판정, head 도 그 전 커밋 → 후보 맞음(기준선).
run_case "정상·반송없음→후보" yes '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T04:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:10:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T03:55:00Z"

# 2) ✅ 가 head 커밋보다 이름(마커 없이) — finish-classify 재사용(1·2항) 단독으로
#    걸러지는지 확인. 재디스패치 마커가 전혀 없는데도 제외돼야 한다.
run_case "head가✅보다늦음·마커없음→제외(1·2항)" no '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T04:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:30:00Z"

# 3) 반송 직후(재디스패치 마커 있음 + 새 커밋 없음) → 후보 아님. head 시각이 옛 ✅
#    보다도 이르므로(새 커밋 없음) finish-classify 는 done_verdict 를 내지만(1·2항
#    만으로는 못 거른다), 마커 안전망(3항)이 걸러야 한다 — 실측 재현(이슈 본문 표).
run_case "반송직후·마커있음·새커밋없음→후보아님(3항)" no '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:49:00Z"},
  {"body":"마감 검증: ⚠ 보류 — BLOCKER 2건\n<!-- bodat:worker -->","createdAt":"2026-07-05T06:34:00Z"},
  {"body":"재디스패치: #166 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-07-05T07:03:00Z"}
]' "2026-07-05T04:40:00Z"

# 4) 반송 후 재완결(새 커밋 + 새 ✅) → 후보 맞음. 마커가 있어도 그 뒤에 새 ✅ 가
#    찍혔으면(재검증 통과) 정상 후보로 복귀해야 한다(과잉 억제 아님을 확인).
run_case "반송후재완결·새커밋·새✅→후보맞음" yes '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:49:00Z"},
  {"body":"마감 검증: ⚠ 보류 — BLOCKER 2건\n<!-- bodat:worker -->","createdAt":"2026-07-05T06:34:00Z"},
  {"body":"재디스패치: #166 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-07-05T07:03:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:50:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:55:00Z"}
]' "2026-07-05T07:45:00Z"

echo "closeout-eligible.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
