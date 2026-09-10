#!/usr/bin/env bash
# closeout-eligible.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# #171: 반송(재디스패치)된 PR 이 낡은 `머지 판정: ✅` 로 다시 머지 후보에 오르지
# 않는지 검증한다. 두 방어선을 함께 문다:
#   1·2) finish-classify.sh 재사용 — ✅ 가 head 커밋보다 이르면(또는 두 시각 중 하나를
#        못 얻어 신선도를 증명 못 하면) done_verdict 가 아니므로 후보에서 빠진다.
#   3)   반송 마커 안전망 — 반송 뒤 아직 새 커밋이 없어 head 시각이 그대로라 1·2 가
#        못 잡는 창을 막는다. 마커 집합은 두 채널(`재디스패치:` closeout · `재검증 실패:`
#        verify-runner)이고, 선후는 createdAt 이 아니라 **코멘트 배열의 마지막 매칭
#        인덱스**로 잰다(초 단위 시각으로는 동초 선후를 못 가린다).
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

# build_meta <comments-json> <head_at> → 전체 PR meta JSON(comments·commits 를
# 끼워 넣는다 — closeout-eligible.sh 가 이제 commits 도 meta 로 함께 받아 FC_HEAD_AT
# 로 넘긴다, 사전 리뷰 WARN 반영: 후보마다 별도 gh 조회 없이 재사용).
build_meta() {
  jq -n --argjson comments "$1" --arg head_at "$2" '{
    headRefName: "agent/issue-166",
    mergeable: "MERGEABLE",
    labels: [],
    comments: $comments,
    closingIssuesReferences: [{number: 166}],
    commits: (if $head_at == "" then [] else [{committedDate: $head_at}] end)
  }'
}

# run_case <name> <expect_candidate:yes|no> <comments-json> <head_at>
run_case() {
  local name="$1" expect="$2" comments="$3" head_at="$4"
  local meta out n verdict
  meta=$(build_meta "$comments" "$head_at")
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

# ── 반송 회차 보강: 동초 경계 + verify-runner 채널 + 조회 실패 ───────────

# 5) **동초** 반송 마커 후행 → 후보 아님. ✅ 와 `재디스패치:` 의 createdAt 이 같은 초라
#    시각 비교(`재디스패치_at > verdict_at`)로는 거짓이 되어 통과했다(GitHub 코멘트
#    시각은 초 단위). 코멘트 배열의 마지막 매칭 **인덱스**로 재면 마커가 뒤라 배제된다.
run_case "동초·반송마커후행→후보아님" no '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:00:00Z"},
  {"body":"재디스패치: #166 — 마감 검증 BLOCKER <!-- bodat:worker -->","createdAt":"2026-07-05T07:00:00Z"}
]' "2026-07-05T06:50:00Z"

# 6) **동초** 새 ✅ 후행 → 후보 맞음. 5 의 역방향 — 같은 초에 마커 뒤 새 ✅ 가 달린
#    정상 재완결은 통과해야 한다(인덱스 비교가 양방향을 다 가리는지 확인).
run_case "동초·새✅후행→후보맞음" yes '[
  {"body":"재디스패치: #166 — 마감 검증 BLOCKER <!-- bodat:worker -->","createdAt":"2026-07-05T07:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:00:00Z"}
]' "2026-07-05T06:59:00Z"

# 7) verify-runner 반송(`재검증 실패:`) 후 새 커밋 없음 → 후보 아님. 반송 채널이 둘인데
#    가드가 closeout 어휘(`재디스패치:`) 하나만 보면, 검증자가 방금 반려한 PR 이 곧바로
#    머지 후보로 뜬다(교체 워커의 새 커밋 전이라 head 가 그대로 = 시각 비교도 통과).
run_case "재검증실패후·새커밋없음→후보아님" no '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:13:00Z"},
  {"body":"재검증 실패: #166 — E2E 실패 (attempt 2)\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:24:00Z"}
]' "2026-07-05T07:05:00Z"

# 8) 반송 채널 무관 회귀 — `재검증 실패:` 뒤에 새 커밋 + 새 ✅ 면 후보로 복귀한다
#    (마커 집합이 넓어진 것이 정상 재완결을 영구 억제하지 않는다).
run_case "재검증실패후재완결→후보맞음" yes '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:13:00Z"},
  {"body":"재검증 실패: #166 — E2E 실패 (attempt 2)\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:24:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:55:00Z"}
]' "2026-07-05T07:45:00Z"

# 9) head 커밋 시각 조회 실패(빈 commits — gh 부분 실패·권한 등) → 후보 아님.
#    ✅ 가 현재 head 이후임을 **증명하지 못한** 상태를 통과로 처리하지 않는다.
run_case "head시각못얻음→후보아님" no '[
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:10:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' ""

echo "closeout-eligible.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
