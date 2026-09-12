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
# 라벨은 기본 빈 배열 — 소유 라벨 제외 케이스(11-b)만 STUB_LABELS 로 심는다.
build_meta() {
  jq -n --arg capped_at "$1" --argjson labels "${STUB_LABELS:-[]}" '{
    headRefName: "agent/issue-166",
    mergeable: "MERGEABLE",
    labels: $labels,
    closingIssuesReferences: [{number: 166}],
    commits: (if $capped_at == "" then [] else [{committedDate: $capped_at}] end)
  }'
}

# run_case <name> <expect_candidate:yes|no> <comments-json> <head_at> [capped_at]
#   head_at   = **진짜 head** 커밋 시각(headRefOid 경로가 주는 값). 빈 값이면 조회 실패.
#   capped_at = `--json commits` 상한 목록의 마지막(=100번째) 커밋 시각. 미지정 시 head_at
#               과 같다(커밋 100건 이하 = 두 경로가 같은 답을 주는 평범한 PR).
# 선택 변수 STUB_STDERR — 비어 있으면 SUT 의 stderr 를 버린다(기존 케이스 전부). 파일
#   경로를 담으면 거기로 받아, 탈락 사유 `warn:` 줄을 단언할 수 있다(#379 — 아래 21).
run_case() {
  local name="$1" expect="$2" comments="$3" head_at="$4" capped_at="${5:-$4}"
  local meta out n verdict
  meta=$(build_meta "$capped_at")
  out=$(cd "$cwd" && PATH="$tmp/bin:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS='[{"repo":"owner/repo","pr":5}]' \
    STUB_META="$meta" STUB_COMMENTS="$comments" STUB_HEAD_AT="$head_at" \
    STUB_CAPPED_AT="$capped_at" STUB_HEAD_SHA="${STUB_HEAD_SHA:-feed0070ab}" \
    STUB_CAPTURE="${STUB_CAPTURE:-}" \
    STUB_ROLLUP="$stub_rollup" \
    bash "$SUT" 2>"${STUB_STDERR:-/dev/null}")
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

# 11-b) `verifying`(#275 — verify-runner 점유) 라벨 PR → 후보 아님. `flow:verify` 제외와
#     대칭: verify-runner 가 지금 검증 중인 PR 을 closeout 이 함께 물면 두 루프가 같은
#     PR 을 잡는다. ✅·head 시각은 1) 과 같은 정상 형상이라 라벨이 없었다면 후보였을 입력이다.
STUB_LABELS='[{"name":"verifying"}]'
run_case "verifying 라벨→후보아님(verify-runner 소유)" no '[
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:10:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T03:55:00Z"
unset STUB_LABELS

# ── #379: 미해결 사람 코멘트는 **최신 ✅ 이후**만 센다 ──────────────────────
# 종전 필터는 PR 의 무마커 코멘트를 **전부** 셌다 — ✅ 이전에 남은 워커 보고·사람
# 세션 메모까지 "미해결 사람 리뷰" 로 집계한 것이다. 그 코멘트들은 verify-runner 가
# 보고 나서 ✅ 를 찍은 것이라 같은 사실을 두 번 센 셈이고, 재심을 여러 번 거친 PR 일수록
# 무마커 코멘트가 쌓여 **더 잘 걸리는 역방향**이었다(#379 — 실측 #5106). 아래 16~21 이
# 그 경계를 양방향으로 고정한다. 공통 형상: head 는 ✅ 보다 이른 시각(정상 PR).

# 16) **핵심 뮤테이션 대상** — ✅ **앞** 무마커 사람 코멘트 → 후보.
#     뮤테이션: unresolved jq 의 인덱스 비교(`.key > $vi`)를 없애면 = 모든 무마커
#     코멘트를 다시 세게 되어 이 케이스가 **탈락으로 빨개진다**(#379 재현).
run_case "✅앞 무마커 코멘트→후보(#379)" yes '[
  {"body":"## 리베이스 해소 2회차: #5114 합류 — 사람 세션 인수(2026-09-12)","createdAt":"2026-07-05T04:05:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:10:00Z"

# 17) ✅ **뒤** 무마커 코멘트(진짜 새 사람 리뷰) → 탈락. 16 의 역방향 — 경계를 ✅ 로
#     옮겼다고 해서 ✅ 이후의 사람 리뷰까지 통과시키면 안 된다(fail-open 금지).
run_case "✅뒤 무마커 코멘트→탈락(#379)" no '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"},
  {"body":"이 부분 다시 봐 주세요","createdAt":"2026-07-05T04:25:00Z"}
]' "2026-07-05T04:10:00Z"

# 18) ✅ 뒤 **마커 있는** 코멘트(closeout 자기 코멘트) → 후보. 마커 술어(#72)는 경계
#     이동과 무관하게 그대로 살아 있어야 한다 — 안 그러면 마감 루프가 자기 코멘트에
#     걸려 제 큐를 지운다.
run_case "✅뒤 마커 코멘트→후보(#379)" yes '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"},
  {"body":"마감 검증: 통과\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:25:00Z"}
]' "2026-07-05T04:10:00Z"

# 19) ✅ 가 아예 없음(🔄 만) + 무마커 코멘트 → 종전대로 탈락. ✅ 부재는 **긍정 게이트**가
#     먼저 거른다(`$vi` 폴백 -1 로 전량을 세느냐와 무관) — 회귀 확인용.
run_case "✅없음(🔄만)+무마커→탈락(#379)" no '[
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T04:00:00Z"},
  {"body":"이 부분 다시 봐 주세요","createdAt":"2026-07-05T04:25:00Z"}
]' "2026-07-05T04:10:00Z"

# 20) **실측 재현(#5106)** — 2026-09-12 마커 PATCH 이전 형상의 재구성. 무마커 워커 보고
#     → 🔄 → 무마커 사람 세션 인수 → 무마커 사람 세션 재심 → ✅(재심 CLEAN) 순서다.
#     종전 필터는 앞의 무마커 3건을 "미해결 사람 리뷰 3건" 으로 세어 이 PR 을 조용히
#     큐에서 지웠다 — 재심을 거칠수록 더 잘 걸리는 역방향. 이제 후보여야 한다.
run_case "실측#5106 재심형상→후보(#379)" yes '[
  {"body":"## 리베이스 해소: #5103 — 충돌 3파일 해소 후 재푸시","createdAt":"2026-07-05T03:00:00Z"},
  {"body":"머지 판정: 🔄 진행 중","createdAt":"2026-07-05T03:10:00Z"},
  {"body":"## 리베이스 해소 2회차: #5114 합류 — 사람 세션 인수(2026-09-12)","createdAt":"2026-07-05T03:40:00Z"},
  {"body":"사람 세션 재심(policy 해제): 사용자 결정 — codex P1·P2 를 이 PR 에서 닫는다.","createdAt":"2026-07-05T03:50:00Z"},
  {"body":"머지 판정: ✅ 머지 가능 (attempt 4 재심 CLEAN)\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]' "2026-07-05T04:10:00Z"

# 21) 탈락은 **stderr 로 드러난다**(조용한 큐 사망 금지 — SKILL #206 원칙). 17 과 같은
#     형상을 stderr 를 파일로 받아 한 번 더 돌려, `warn:` 으로 시작하고 PR 번호(`#5`)와
#     건수(`1건`)가 든 줄이 있는지 본다. `eligible-issues.sh` 의 `warn: ` 관례와 같은 꼴.
#     (run_case 는 stderr 를 버리므로 선택적 `STUB_STDERR` 로만 잡는다 — 기존 호출부 무변경.)
STUB_STDERR="$tmp/warn-379"; : > "$STUB_STDERR"
run_case "✅뒤 무마커→탈락+warn(#379)" no '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"},
  {"body":"이 부분 다시 봐 주세요","createdAt":"2026-07-05T04:25:00Z"}
]' "2026-07-05T04:10:00Z"
if [ "$(grep -c '^warn:.*#5.*1건' "$STUB_STDERR")" = 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ warn 노출(#379) — stderr 에 'warn: … #5 … 1건' 한 줄이 있어야 한다:"
  sed 's/^/      /' "$STUB_STDERR"
fi
STUB_STDERR=""

# 22) ✅ 가 **두 번** 찍힌 형상 — 구판정 ✅ → 무마커 사람 코멘트 → 재검증 ✅ → 후보.
#     경계는 "어느 ✅ 냐" 까지 고정해야 한다: 16~21 에는 ✅ 가 하나뿐이라 **마지막**
#     매칭을 쓰는지 **첫** 매칭을 쓰는지 구별하지 못한다. 사이에 낀 사람 코멘트는
#     재검증 ✅ 로 이미 해소된 것이므로 세면 안 된다.
#     뮤테이션: unresolved jq 의 `| last` 를 `first` 로 바꾸면 $vi 가 구판정(인덱스 0)을
#     가리켜 사이의 무마커 코멘트를 다시 세고, 이 케이스가 **탈락으로 빨개진다**.
run_case "✅ 두 번·사이 무마커→후보(#379)" yes '[
  {"body":"머지 판정: ✅ 머지 가능(구판정)\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"},
  {"body":"이 부분 다시 봐 주세요","createdAt":"2026-07-05T04:25:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:40:00Z"}
]' "2026-07-05T04:10:00Z"

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
