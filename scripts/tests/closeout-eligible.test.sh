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

# ── gh 스텁 — 호출 형태별 응답 ──────────────────────────────────────────
# 코멘트 경로는 실 gh 처럼 **두 갈래를 다르게** 응답한다(#171 [P1-2] 재현):
#   `pr view --json comments`               → 페이지네이션 없이 **첫 100건만**
#   `api .../issues/N/comments --paginate`  → 전량(넘겨받은 --jq 를 그대로 적용)
# 그래야 "코멘트 100건 초과" 픽스처가 실제로 무언가를 잰다 — 옛 경로로 되돌리면
# 상한에 갇혀 판정이 뒤집히고 아래 10·11 이 빨개진다.
# head 시각 경로도 실 gh 처럼 **두 갈래를 다르게** 응답한다(#171 반송 4회차 [P1-1] 재현):
#   `pr view --json commits`     → GraphQL commits(first:100) — 커밋이 101건 이상이면
#                                  head 가 아니라 **100번째** 커밋(STUB_CAPPED_AT)
#   `pr view --json headRefOid`  + `api repos/o/r/commits/<sha>` → **진짜 head**(STUB_HEAD_AT)
# 호출 순서도 캡처한다 — [P1-2](head 스냅샷을 코멘트 조회 **뒤**에 뜨기)를 재기 위해.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_CAPTURE:-}" ] && printf '%s\n' "$*" >> "$STUB_CAPTURE"
paginate=0; jqf='.'; prev=''
for a in "$@"; do
  [ "$prev" = "--jq" ] && jqf="$a"
  [ "$a" = "--paginate" ] && paginate=1
  prev="$a"
done
# 타임라인(#174) — 코멘트와 **다른** 엔드포인트다. 코멘트 갈래보다 먼저 가른다
# (둘 다 --paginate 라 순서를 뒤집으면 타임라인 조회가 코멘트 배열을 받는다).
# STUB_TIMELINE=fail → gh 비정상 종료(조회 실패 재현).
case "$*" in
  */timeline*)
    [ "${STUB_TIMELINE:-[]}" = "fail" ] && exit 1
    printf '%s' "${STUB_TIMELINE:-[]}" | jq -r "$jqf"
    exit 0 ;;
esac
if [ "$paginate" = 1 ]; then
  # 픽스처는 GraphQL 형상(createdAt)이라 REST 형상(created_at)으로 되돌린 뒤
  # 실 gh 처럼 --jq 를 적용한다.
  printf '%s' "$STUB_COMMENTS" \
    | jq -c '[.[] | {body: .body, created_at: .createdAt}]' | jq -c "$jqf"
  exit 0
fi
case "$*" in
  *"api user"*) printf '%s\n' "${STUB_ME:-tester}" ;;
  *"search/issues"*) printf '%s\n' "$STUB_PRS" ;;
  *"--json headRefName"*) printf '%s\n' "$STUB_META" ;;
  *"--json comments -q"*) printf '%s' "$STUB_COMMENTS" | jq -c '.[0:100]' ;;
  *"--json statusCheckRollup -q"*) printf '%s\n' "${STUB_FAILING:-0}" ;;
  *"pr view"*"--json headRefOid"*)
    [ -n "${STUB_HEAD_SHA:-}" ] || exit 1
    printf '{"headRefOid":"%s"}\n' "$STUB_HEAD_SHA" ;;
  *"commits/"*)
    [ -n "${STUB_HEAD_AT:-}" ] || exit 1
    printf '{"commit":{"committer":{"date":"%s"}}}\n' "$STUB_HEAD_AT" ;;
  *"--json commits -q"*) printf '%s\n' "${STUB_CAPPED_AT:-${STUB_HEAD_AT:-}}" ;;
  *"--json statusCheckRollup"*) printf '%s\n' "$STUB_ROLLUP" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

stub_rollup='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'

# build_meta <capped_at> → 전체 PR meta JSON. **comments 도 commits 도 판정에 쓰지 않는다**:
#   · 코멘트는 pr-comments.sh(페이지네이션)로 따로 읽는다(#171 [P1-2] 3회차).
#   · head 시각은 pr-head-at.sh(headRefOid + 그 커밋 조회)로 따로 읽는다(4회차 [P1-1]).
# 그럼에도 meta 에 `commits` 를 **일부러 남긴다** — 실 gh 가 그 필드를 요청받으면 주는
# 값(상한 100 에 갇힌 목록)을 그대로 흉내내야, head 시각을 meta.commits 에서 줍던 옛
# 경로로 되돌리는 뮤테이션이 여기서 빨개진다(아래 13 참조).
build_meta() {
  jq -n --arg capped_at "$1" '{
    headRefName: "agent/issue-166",
    mergeable: "MERGEABLE",
    labels: [],
    closingIssuesReferences: [{number: 166}],
    commits: (if $capped_at == "" then [] else [{committedDate: $capped_at}] end)
  }'
}

# run_case <name> <expect_candidate:yes|no> <comments-json> <head_at> [capped_at]
#   head_at   = **진짜 head** 커밋 시각(headRefOid 경로가 주는 값). 빈 값이면 조회 실패.
#   capped_at = `--json commits` 상한 목록의 마지막(=100번째) 커밋 시각. 미지정 시 head_at
#               과 같다(커밋 100건 이하 = 두 경로가 같은 답을 주는 평범한 PR).
run_case() {
  local name="$1" expect="$2" comments="$3" head_at="$4" capped_at="${5:-$4}"
  local meta out n verdict
  meta=$(build_meta "$capped_at")
  out=$(cd "$cwd" && PATH="$tmp/bin:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS='[{"repo":"owner/repo","pr":5}]' \
    STUB_META="$meta" STUB_COMMENTS="$comments" STUB_HEAD_AT="$head_at" \
    STUB_CAPPED_AT="$capped_at" STUB_HEAD_SHA="${STUB_HEAD_SHA:-feed0070ab}" \
    STUB_CAPTURE="${STUB_CAPTURE:-}" STUB_TIMELINE="${STUB_TIMELINE:-[]}" \
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

# ── 반송 3회차 [P1-2]: 코멘트 100건 상한을 넘겨 판정한다 ────────────────────
# `gh pr view --json comments` 는 페이지네이션 없이 첫 100건만 준다 — 이 레포가 이미
# 아는 함정(scripts/tests/loop-status.test.sh:267 이 `range(0;100)` 픽스처로 같은 경계를
# 잰다; 거긴 `capped`=모른다 로 끝내지만 머지 게이트는 그럴 수 없다). 반송을 여러 번
# 도는 PR 은 워커·verify·closeout 코멘트가 겹겹이 쌓여 100건이 먼 숫자가 아니고, 상한에
# 갇히면 **양방향으로** 조용히 틀린다. 아래 둘이 그 두 갈래다.
# 잡담 채움 코멘트엔 sentinel 마커를 박는다 — 안 박으면 unresolved 로 집계돼 이 테스트가
# 재려는 것(상한) 대신 엉뚱한 이유로 탈락한다.

# 10) 새 커밋 + 새 ✅ 가 **101번째 이후** → 후보 맞음.
#     상한에 갇히면 첫 100건의 낡은 ✅(04:00, head 07:00 보다 이름)만 보여
#     finish-classify 가 active → **머지 가능한 PR 이 영영 후보에 안 뜬다**(조용한 큐
#     사망 — 아무도 눈치 못 채는 방향이라 더 위험하다).
big_new_verdict=$(jq -n '
  [ {body:"머지 판정: ✅ 머지 가능(구판정)\n<!-- bodat:worker -->", createdAt:"2026-07-05T04:00:00Z"} ]
  + [ range(0;120) | {body:("검증자 리뷰: 진행 메모 \(.)\n<!-- bodat:worker -->"), createdAt:"2026-07-05T05:00:00Z"} ]
  + [ {body:"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->", createdAt:"2026-07-05T08:00:00Z"} ]')
run_case "코멘트100건초과·새✅가101번째이후→후보맞음" yes "$big_new_verdict" "2026-07-05T07:00:00Z"

# 11) 반송 마커가 **101번째 이후** → 후보 아님.
#     상한에 갇히면 마커가 안 보여 안전망에서 누락되고, ✅(08:00)는 head(07:00)보다
#     늦어 시각 비교도 통과한다 → 방금 반려된 PR 이 머지 후보로 뜬다.
big_late_bounce=$(jq -n '
  [ {body:"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->", createdAt:"2026-07-05T08:00:00Z"} ]
  + [ range(0;120) | {body:("검증자 리뷰: 진행 메모 \(.)\n<!-- bodat:worker -->"), createdAt:"2026-07-05T08:10:00Z"} ]
  + [ {body:"재검증 실패: #166 — E2E 실패 (attempt 3)\n<!-- bodat:worker -->", createdAt:"2026-07-05T09:00:00Z"} ]')
run_case "코멘트100건초과·반송마커가101번째이후→후보아님" no "$big_late_bounce" "2026-07-05T07:00:00Z"

# ── 반송 4회차 [P1-1]: 커밋도 100건 상한을 넘겨 읽는다 ──────────────────────
# `gh pr view --json commits` 는 GraphQL `commits(first:100)` 이라 커밋이 101건 이상이면
# `last` 가 head 가 아니라 **100번째** 커밋이다. 그 이른 시각으로 비교하면 낡은 ✅ 가
# `head <= verdict` 를 만족해 done_verdict → 이 PR 이 없애려던 fail-open 이 커밋 쪽에
# 그대로 남는다(코멘트 100건 상한과 같은 함정).

# 13) **핵심 뮤테이션 대상** — 커밋 101건 이상: 상한 목록의 마지막(04:10)은 ✅(04:20)보다
#     이르지만 진짜 head(04:30)는 ✅ 보다 늦다 → 후보 아님.
#     뮤테이션: head 시각을 meta 의 `(.commits//[])[-1].committedDate` 로 되돌리면
#     head=04:10 이 되어 done_verdict → **후보로 뜨며 빨개진다**(fail-open 재현).
run_case "커밋100건상한·진짜head가✅보다늦음→후보아님" no '[
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:15:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:30:00Z" "2026-07-05T04:10:00Z"

# 14) 무회귀 쌍 — 같은 상한 형상이어도 진짜 head(04:10)가 ✅(04:20)보다 이르면 후보 맞음
#     (상한 회피가 정상 후보를 막지 않는다).
run_case "커밋100건상한·진짜head가✅보다이름→후보맞음" yes '[
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:15:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:10:00Z" "2026-07-05T03:00:00Z"

# 15) [P1-2] head 스냅샷은 코멘트 조회 **뒤**에 떠야 한다. 먼저 뜨면 그 사이 워커가 push
#     했을 때 head_at 이 **이전 커밋**을 가리키고, 기존 ✅ 가 그보다 늦어 보여 검증 안 된
#     head 가 후보로 나간다. 호출 순서를 캡처해 고정한다(창을 없애진 못해도 — 완전 해소는
#     #175 — 순서가 뒤집히면 창이 다시 열리므로 순서 자체가 계약이다).
STUB_CAPTURE="$tmp/order-capture"; : > "$STUB_CAPTURE"
run_case "호출순서·코멘트→head(P1-2)" yes '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:10:00Z"
c_line=$(grep -n -- '--paginate' "$STUB_CAPTURE" | head -1 | cut -d: -f1)
h_line=$(grep -n -- '--json headRefOid' "$STUB_CAPTURE" | head -1 | cut -d: -f1)
if [ -n "$c_line" ] && [ -n "$h_line" ] && [ "$c_line" -lt "$h_line" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 호출순서 — 코멘트(--paginate, 줄 ${c_line:-없음}) 가 head(headRefOid, 줄 ${h_line:-없음}) 보다 먼저여야 한다:"
  sed 's/^/      /' "$STUB_CAPTURE"
fi
STUB_CAPTURE=""

# ── #174: 사람이 보류를 풀면 다시 후보로 뜬다 ─────────────────────────────
# 실측 형상(BodaT PR #4922): `머지 판정: ✅` 뒤에 `마감 검증: ⚠ 보류` 가 달리고
# closeout-blocked 가 `needs-human`+`hold:policy` 를 붙였다. 운영자가 결정문을 코멘트로
# 남기고(머신 마커 없음) 5초 뒤 두 라벨을 뗐다. 그 뒤 이 PR 은 **양쪽 큐 어디에도**
# 안 떴다 — 라벨은 풀렸는데 (a) 낡은 `⚠ 보류` 가 최신 판정 형식 코멘트로 남아 있고
# (b) 운영자 결정문이 "미해결 사람 코멘트" 로 집계됐기 때문이다.
#
# **뮤테이션 표적**: finish-classify 의 해제 시각 비교(`해제 > 보류`)를 되돌리면
# 아래 첫 케이스가 후보에서 빠져 빨개진다.
held_then_released='[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-07-05T05:52:21Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T06:16:01Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T06:16:02Z"},
  {"body":"마감 검증: ⚠ 보류 — 계획 부합 게이트 BLOCKER(P1 1건)\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:00:21Z"},
  {"body":"사람 확인(policy): 빈 uid fail-closed 가드가 없다\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:00:24Z"},
  {"body":"사람 결정(운영자): **P1 기각 — 원안 그대로 머지.**","createdAt":"2026-07-05T08:18:51Z"}
]'
released_timeline='[
  {"event":"labeled","label":{"name":"needs-human"},"created_at":"2026-07-05T07:00:26Z"},
  {"event":"labeled","label":{"name":"hold:policy"},"created_at":"2026-07-05T07:00:26Z"},
  {"event":"unlabeled","label":{"name":"needs-human"},"created_at":"2026-07-05T08:18:56Z"},
  {"event":"unlabeled","label":{"name":"hold:policy"},"created_at":"2026-07-05T08:18:56Z"}
]'

# 16) 보류 해제됨(해제 > 보류) + 결정문이 해제 **이전** → 후보로 뜬다.
STUB_TIMELINE="$released_timeline"
run_case "보류해제→후보로뜬다(#174)" yes "$held_then_released" "2026-07-05T05:00:00Z"

# 17) 해제 이벤트 없음(사람이 아직 안 풀었다) → 후보 아님. `needs-human` 라벨이 이미
#     떨어진 뒤에도 낡은 `⚠ 보류` 하나로 게이트가 닫혀 있어야 한다(라벨 편집만으로는
#     열리지 않는 두 번째 자물쇠 — 해제 **시각**이 증명돼야 열린다).
STUB_TIMELINE='[]'
run_case "해제이벤트없음→후보아님" no "$held_then_released" "2026-07-05T05:00:00Z"

# 18) 타임라인 조회 실패 → 후보 아님(fail-closed). 조회 실패가 머지 게이트를 여는
#     방향으로 작동하면 안 된다.
STUB_TIMELINE="fail"
run_case "타임라인조회실패→후보아님" no "$held_then_released" "2026-07-05T05:00:00Z"

# 19) 해제 **뒤에** 달린 사람 코멘트는 여전히 미해결이다 → 후보 아님.
#     해제로 답해진 것은 해제 시점까지의 사람 코멘트뿐이다(#72 보호를 해제 이후로는
#     그대로 유지한다 — 사람이 새 질문을 던졌는데 자동 머지가 지나가면 안 된다).
after_release_comment='[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T06:16:02Z"},
  {"body":"마감 검증: ⚠ 보류 — P1 1건\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:00:21Z"},
  {"body":"사람 결정(운영자): P1 기각 — 원안 그대로 머지.","createdAt":"2026-07-05T08:18:51Z"},
  {"body":"잠깐, 이 부분은 다시 봐야 할 것 같다.","createdAt":"2026-07-05T09:30:00Z"}
]'
STUB_TIMELINE="$released_timeline"
run_case "해제이후사람코멘트→후보아님" no "$after_release_comment" "2026-07-05T05:00:00Z"

# 20) 해제 후 **새 커밋** — 사람이 방향을 정해 주고 워커가 고치는 중(반송 레인) →
#     후보 아님. #171 규칙이 이어 걸린다(두 규칙의 순서 계약).
STUB_TIMELINE="$released_timeline"
run_case "해제후새커밋→후보아님(#171우선)" no "$held_then_released" "2026-07-05T09:00:00Z"

# 21) 보류 코멘트보다 **앞선** 사람 코멘트는 그 해제로 답해진 것이 아니다 → 후보 아님.
#     해제 시각 하나로 "그 이전 전부" 를 면제하면 그 보류와 무관한 옛 미결 질문까지
#     삼킨다. 면제 창은 반개구간 `(보류 코멘트, 해제]` 다.
pre_hold_comment='[
  {"body":"이건 별개 건인데 확인 좀 부탁합니다.","createdAt":"2026-07-05T05:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T06:16:02Z"},
  {"body":"마감 검증: ⚠ 보류 — P1 1건\n<!-- bodat:worker -->","createdAt":"2026-07-05T07:00:21Z"},
  {"body":"사람 결정(운영자): P1 기각 — 원안 그대로 머지.","createdAt":"2026-07-05T08:18:51Z"}
]'
STUB_TIMELINE="$released_timeline"
run_case "보류이전사람코멘트→후보아님(면제창 밖)" no "$pre_hold_comment" "2026-07-05T05:00:00Z"

# 22) **무회귀 + 비용 계약** — `마감 검증: ⚠` 가 없는 평범한 PR 은 타임라인을 **아예
#     호출하지 않는다**. 호출 여부를 STUB_CAPTURE 로 직접 잰다 — 스텁 응답으로 재려 하면
#     이 형상은 해제 시각이 있든 없든 판정이 안 바뀌어(가릴 ⚠ 도 사람 코멘트도 없다)
#     아무것도 못 재는 껍데기 픽스처가 된다.
STUB_CAPTURE="$tmp/timeline-capture"; : > "$STUB_CAPTURE"
STUB_TIMELINE='[]'
run_case "평범한PR→후보맞음(기준선)" yes '[
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:10:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:10:00Z"
if grep -q -- '/timeline' "$STUB_CAPTURE"; then
  fail=$((fail + 1))
  echo "  ✗ 평범한PR→타임라인 미호출 — 호출됐다:"
  grep -- '/timeline' "$STUB_CAPTURE" | sed 's/^/      /'
else
  pass=$((pass + 1))
fi

# 23) 반대쪽 — `마감 검증: ⚠` 가 있으면 **호출한다**(위 22 가 "영영 호출 안 함" 을 굳혀
#     기능을 죽이는 뮤테이션을 잡는다).
: > "$STUB_CAPTURE"
STUB_TIMELINE="$released_timeline"
run_case "보류있는PR→후보맞음(호출 확인용)" yes "$held_then_released" "2026-07-05T05:00:00Z"
if grep -q -- '/timeline' "$STUB_CAPTURE"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 보류있는PR→타임라인 호출돼야 한다 — 호출 기록 없음:"
  sed 's/^/      /' "$STUB_CAPTURE"
fi
STUB_CAPTURE=""
STUB_TIMELINE='[]'

# 12) 코멘트 조회 자체가 실패(gh 비정상 종료) → 후보 아님.
#     반송되지 않았음을 **증명하지 못한** 상태를 통과로 처리하지 않는다(fail-closed).
#     ✅·head 시각은 정상 형상이라, 조회 실패가 아니었다면 후보였을 입력이다.
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--paginate" ] && exit 1; done
case "$*" in
  *"api user"*) printf '%s\n' "${STUB_ME:-tester}" ;;
  *"search/issues"*) printf '%s\n' "$STUB_PRS" ;;
  *"--json headRefName"*) printf '%s\n' "$STUB_META" ;;
  *"--json statusCheckRollup"*) printf '%s\n' "$STUB_ROLLUP" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
run_case "코멘트조회실패→후보아님" no '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:10:00Z"

echo "closeout-eligible.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
