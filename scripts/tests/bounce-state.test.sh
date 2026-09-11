#!/usr/bin/env bash
# bounce-state.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
#
# #196: closeout ①-b 의 **CONFLICTING 입양** 경로에 반송 안전망을 붙이기 위해, 반송
# 판정을 `closeout-eligible.sh` 안에서 이 헬퍼 한 자리로 뽑았다. 그래서 이 파일이
# 반송 마커 판정 자체의 SSOT 테스트다(closeout-eligible.test.sh 는 그 판정이 후보
# 필터에 **배선돼 있는지**를 잰다 — 두 층을 일부러 나눠 둔다).
#
# 이 헬퍼가 답하는 질문은 두 개다: "최신 반송 마커가 최신 `머지 판정: ✅` 보다 뒤인가"
# 그리고(#218 attempt 2) "그 마커보다 뒤에 새 `머지 판정: ⚠ 보류` 가 있는가."
#   ok      = 반송 마커가 없거나, 그 뒤에 새 ✅ 가 찍혔다 → 마감 레인이 만져도 된다
#   bounced = 반송이 최신이고, 그 뒤에 새 ⚠ 도 없다 → **워커 레인 소유**(closeout 무접촉)
#   held    = 반송이 최신이지만 그 뒤에 새 ⚠ 가 찍혔다 → needs-human 승격 대상
#             (재디스패치로는 가지 않는다 — 살아있는 교체 워커와 충돌하는 건 그 갈래다)
#   exit 1  = 판정 못 함 → 호출자가 fail-closed 로 받는다(증명 실패는 통과가 아니다)
#
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/bounce-state.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# ── gh 스텁 ─────────────────────────────────────────────────────────────
# 실 gh 처럼 **두 갈래를 다르게** 응답한다(#171 [P1-2] 재현):
#   `pr view --json comments`               → 페이지네이션 없이 **첫 100건만**
#   `api .../issues/N/comments --paginate`  → 전량(넘겨받은 --jq 를 그대로 적용)
# 그래야 "코멘트 100건 초과" 픽스처가 실제로 무언가를 잰다 — 옛 경로로 되돌리는
# 뮤테이션이 상한에 갇혀 판정이 뒤집히고 그 케이스가 빨개진다.
# 호출 형태도 캡처한다(어느 경로로 읽었는지 단언하기 위해).
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_CAPTURE:-}" ] && printf '%s\n' "$*" >> "$STUB_CAPTURE"
[ -n "${STUB_FAIL_COMMENTS:-}" ] && exit 1
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
  *"--json comments"*) printf '%s' "$STUB_COMMENTS" | jq -c '.[0:100]' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# run_case <name> <expect: ok|bounced|fail> <comments-json>
#   실조회 경로(pr-comments.sh)를 탄다 — 페이지네이션 계약까지 함께 잰다.
run_case() {
  local name="$1" expect="$2" comments="$3"
  local out rc=0 verdict=ok
  out=$(PATH="$tmp/bin:$PATH" STUB_COMMENTS="$comments" \
    STUB_CAPTURE="${STUB_CAPTURE:-}" STUB_FAIL_COMMENTS="${STUB_FAIL_COMMENTS:-}" \
    bash "$SUT" owner/repo 5 2>/dev/null) || rc=$?

  if [ "$expect" = fail ]; then
    # 판정 실패는 **무출력 + 비정상 종료** 여야 한다 — 빈 출력만으로는 부족하다
    # (호출자가 `= ok` 로 거르지만, 빈 값을 "정상 판정" 으로 오해할 여지를 남기지 않는다).
    { [ "$rc" != 0 ] && [ -z "$out" ]; } || verdict="no"
  else
    { [ "$rc" = 0 ] && [ "$out" = "$expect" ]; } || verdict="no"
  fi

  if [ "$verdict" = ok ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$expect 실제 rc=$rc out=[$out]"
  fi
}

# ── #196 Test plan 신규 픽스처 3종 ────────────────────────────────────────
# 셋 다 closeout ①-b 가 보는 형상(CONFLICTING + 단계 라벨 0)이다. 라벨·mergeable 은
# ①-b 프로즈가 이미 걸러 이 헬퍼에 오지 않으므로, 여기서 재는 건 **코멘트 축** 하나다.

# 1) 마지막 판정 코멘트가 `재검증 실패:` (✅ 0건) → bounced = **입양 후보 아님**.
#    이번 사고(bodat PR #5009)의 재현: 판정 코멘트 4건, 마지막이 재검증 실패, ✅ 0건인데
#    CONFLICTING 하나만 보고 입양해 살아있는 워커의 워크트리에서 rebase 까지 갔다.
run_case "①-b 사고재현·마지막이 재검증 실패·✅0건→bounced" bounced '[
  {"body":"머지 판정: 🔄 진행 중 — 검증 전, 머지 보류\n<!-- bodat:worker -->","createdAt":"2026-09-10T04:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 1건\n<!-- bodat:worker -->","createdAt":"2026-09-10T05:00:00Z"},
  {"body":"머지 판정: 🔄 진행 중 — 재수정\n<!-- bodat:worker -->","createdAt":"2026-09-10T06:00:00Z"},
  {"body":"재검증 실패: #4973 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"}
]'

# 2) 마지막 판정 코멘트가 `머지 판정: ✅` → ok = 종전대로 **입양**.
#    회귀 방지: 진짜 좌초 CONFLICTING(검증까지 끝났는데 마감이 죽음)을 못 집게 되면
#    그게 새 결함이다. 안전망이 과잉 억제로 흐르지 않는지 여기서 문다.
run_case "✅ 가 마지막→ok(진짜 좌초 CONFLICTING 은 종전대로 입양)" ok '[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-09-10T04:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-09-10T05:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-10T06:00:00Z"}
]'

# 3) 판정 코멘트 0건(워커가 아무것도 안 남기고 죽음) → ok = 종전대로 **입양**.
#    반송된 적이 없다 = 워커 레인이 이 PR 을 되돌려 받은 적이 없다.
run_case "판정 코멘트 0건→ok(종전대로 입양)" ok '[]'

# ── 경계·역방향 ──────────────────────────────────────────────────────────

# 4) 반송 뒤 새 ✅ → ok. 반송 회차가 정상 완결되면 마감 레인으로 돌아와야 한다.
run_case "반송 뒤 새 ✅→ok" ok '[
  {"body":"재검증 실패: #166 — E2E 실패 (attempt 2)\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-09-10T08:00:00Z"}
]'

# 5) closeout 채널(`재디스패치:`)도 같은 집합이다 — 마커 집합이 한 자리라는 계약.
run_case "재디스패치 채널도 잡는다→bounced" bounced '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"},
  {"body":"재디스패치: #166 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-09-10T07:30:00Z"}
]'

# 6) **동초** 반송 마커 후행 → bounced. GitHub 코멘트 시각은 초 단위라 createdAt 비교로는
#    거짓이 된다 — 선후는 **코멘트 배열의 마지막 매칭 인덱스**로 잰다는 계약의 고정핀.
run_case "동초·반송마커 후행→bounced" bounced '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"},
  {"body":"재디스패치: #166 — 마감 검증 BLOCKER <!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"}
]'

# 7) **동초** 새 ✅ 후행 → ok. 6 의 역방향(인덱스 비교가 양방향을 다 가리는지).
run_case "동초·새 ✅ 후행→ok" ok '[
  {"body":"재디스패치: #166 — 마감 검증 BLOCKER <!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"}
]'

# 8) 영문 ✅(`Merge verdict: ✅`)도 긍정 게이트다(한/영 병행 워커).
run_case "영문 Merge verdict ✅ 후행→ok" ok '[
  {"body":"재검증 실패: #166 — E2E 실패\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"},
  {"body":"Merge verdict: ✅ ready to merge\n<!-- bodat:worker -->","createdAt":"2026-09-10T08:00:00Z"}
]'

# 9) **반송 해제는 오직 새 ✅ 뿐이다** — 반송 뒤에 `검증자 리뷰:`·`머지 판정: 🔄` 만
#    쌓이고 새 ✅ 가 없으면 계속 `bounced`. 이 좁힘은 의도된 설계다(사전 리뷰 NIT 로 지적):
#    이슈 #196 본문은 "판정성 코멘트 전체 중 마지막이 반송 마커면 워커 레인 소유" 라고
#    적었는데, 그 넓은 집합으로 재면 여기 형상이 `ok` 로 뒤집혀 **교체 워커가 지금 일하는
#    중인 PR 을 입양한다**(🔄·검증자 리뷰야말로 워커가 살아 있다는 가장 강한 증거인데
#    그게 반송을 덮는 셈). 좁힘이 리팩터로 조용히 풀리지 않게 여기 못을 박는다.
run_case "반송 뒤 🔄·검증자 리뷰만·새 ✅ 없음→bounced 유지" bounced '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"},
  {"body":"재검증 실패: #166 — E2E 실패 (attempt 2)\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:30:00Z"},
  {"body":"머지 판정: 🔄 진행 중 — 재수정\n<!-- bodat:worker -->","createdAt":"2026-09-10T08:00:00Z"},
  {"body":"검증자 리뷰: CLEAN\n<!-- bodat:worker -->","createdAt":"2026-09-10T08:30:00Z"}
]'

# ── 코멘트 100건 상한 회귀 (#173 · #171 [P1-2]) ──────────────────────────
# `gh pr view --json comments` 는 페이지네이션 없이 첫 100건만 준다. 반송 마커가
# 101번째 이후면 상한에 갇힌 구현은 그것을 못 보고 `ok` 를 내 **반송된 PR 이 입양된다**.
# 채움 코멘트는 판정 접두사가 아닌 잡담으로 둔다(이 케이스가 재려는 축을 흐리지 않게).
big_late_bounce=$(jq -n '
  [ {body:"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->", createdAt:"2026-09-10T08:00:00Z"} ]
  + [ range(0;120) | {body:("진행 메모 \(.)\n<!-- bodat:worker -->"), createdAt:"2026-09-10T08:10:00Z"} ]
  + [ {body:"재검증 실패: #166 — E2E 실패 (attempt 3)\n<!-- bodat:worker -->", createdAt:"2026-09-10T09:00:00Z"} ]')
STUB_CAPTURE="$tmp/capture"; : > "$STUB_CAPTURE"
run_case "코멘트 100건 초과·반송마커가 101번째 이후→bounced" bounced "$big_late_bounce"

# 8-b) 같은 실행에서 **어느 경로로 읽었는지**까지 고정한다 — `--paginate` 를 탔고
#      `--json comments`(상한 100) 는 아예 안 썼다. 상한 경로로 되돌리는 뮤테이션은
#      위 케이스만이 아니라 이 단언에서도 잡힌다(#173: 상한은 목록 필드마다 따로 걸린다).
if grep -q -- '--paginate' "$STUB_CAPTURE" && ! grep -q -- '--json comments' "$STUB_CAPTURE"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 조회 경로 — pr-comments.sh(--paginate) 만 써야 한다(상한 100 인 --json comments 금지):"
  sed 's/^/      /' "$STUB_CAPTURE"
fi
STUB_CAPTURE=""

# 9) 코멘트 조회 실패(gh 비정상 종료) → 판정 실패(exit≠0·무출력).
#    반송되지 않았음을 **증명하지 못한** 상태를 `ok` 로 내지 않는다(PR#139 교훈:
#    빈 결과와 실패를 구분하고, 실패는 가드 분기로 보내라).
STUB_FAIL_COMMENTS=1
run_case "코멘트 조회 실패→판정 실패(fail-closed)" fail '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-10T08:00:00Z"}
]'
STUB_FAIL_COMMENTS=""

# ── 주입 경로(BOUNCE_COMMENTS_FILE) ──────────────────────────────────────
# closeout-eligible.sh 는 이미 읽은 코멘트를 파일로 넘겨 중복 gh 조회를 피한다
# (finish-classify 의 FC_COMMENTS_FILE 과 같은 계약).
run_file_case() {
  local name="$1" expect="$2" file="$3"
  local out rc=0 verdict=ok
  # PATH 에 gh 스텁을 두되 **모든 호출을 실패**시킨다 — 주입 경로가 실조회로 새면
  # 여기서 즉시 빨개진다.
  out=$(PATH="$tmp/bin:$PATH" STUB_FAIL_COMMENTS=1 BOUNCE_COMMENTS_FILE="$file" \
    bash "$SUT" owner/repo 5 2>/dev/null) || rc=$?
  if [ "$expect" = fail ]; then
    { [ "$rc" != 0 ] && [ -z "$out" ]; } || verdict="no"
  else
    { [ "$rc" = 0 ] && [ "$out" = "$expect" ]; } || verdict="no"
  fi
  if [ "$verdict" = ok ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$expect 실제 rc=$rc out=[$out]"
  fi
}

printf '%s' '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:00:00Z"},
  {"body":"재검증 실패: #166 — E2E 실패\n<!-- bodat:worker -->","createdAt":"2026-09-10T07:30:00Z"}
]' > "$tmp/injected.json"
run_file_case "주입 파일 경로→bounced(실조회로 새지 않는다)" bounced "$tmp/injected.json"

# 10) 주입 파일을 못 읽으면 **실조회로 갈아타지 않고** 판정 실패다 — 호출자가 "이 파일이
#     곧 판정 입력" 이라 계약한 이상 다른 출처로 조용히 바꾸면 무엇으로 판정했는지 알 수
#     없다(FC_COMMENTS_FILE 과 같은 방향).
run_file_case "주입 파일 읽기 실패→판정 실패" fail "$tmp/does-not-exist.json"

# 11) 주입 파일이 비어 있으면(쓰다 만 파일) 역시 판정 실패 — `[]`(코멘트 0건, 정상)와
#     구분한다. 빈 문자열은 "조회 결과가 없다" 가 아니라 "입력을 못 받았다" 다.
: > "$tmp/empty.json"
run_file_case "주입 파일이 빈 문자열→판정 실패(코멘트 0건과 구분)" fail "$tmp/empty.json"

printf '%s' '[]' > "$tmp/zero.json"
run_file_case "주입 파일이 []→ok(코멘트 0건은 정상 판정)" ok "$tmp/zero.json"

# ── held(#218 attempt 2 — codex BLOCKER) ─────────────────────────────────
# attempt 1 은 bounced 를 무조건 조기 종료해, 반송 뒤 교체 워커가 새로 올린
# `머지 판정: ⚠ 보류` 를 영원히 못 봤다. ✅ 와 대칭으로 ⚠ 도 마지막 매칭 인덱스로 잰다.

# 13) 반송 마커 → 그 뒤 새 `⚠ 보류` → held. #218 attempt 2 가 닫는 바로 그 구멍
#     (bodat PR #225 검증자 리뷰 재현: "a later ⚠ verdict never becomes held").
run_case "반송 마커 뒤 새 ⚠ 보류→held" held '[
  {"body":"머지 판정: 🔄 진행 중\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:00:00Z"},
  {"body":"검증자 리뷰: BLOCKER 1건\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:30:00Z"},
  {"body":"재검증 실패: #218 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T02:00:00Z"}
]'

# 14) `⚠ 보류` → 그 뒤 반송 마커(활동 없음, "반송 직후" 형상) → bounced 유지.
#     ⚠ 가 마커보다 **앞**이면 그건 반송 뒤 활동이 아니라 반송 전에 이미 쌓인 낡은
#     신호다 — held 로 승격하면 살아있는 반송 회차를 사람 대기로 잘못 끊는다.
run_case "⚠ 보류 뒤 반송 마커(활동 없음)→bounced 유지" bounced '[
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:00:00Z"},
  {"body":"재검증 실패: #218 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"}
]'

# 15) held 뒤 재반송(다른 마커가 또 달림) → bounced. 최신 반송 마커가 다시 ⚠ 보다
#     뒤로 가면 워커 레인 소유로 되돌아간다 — ✅ 축의 "최신이 이긴다" 규칙과 대칭.
run_case "held 뒤 재반송→bounced(최신 마커가 이긴다)" bounced '[
  {"body":"재검증 실패: #218 — codex BLOCKER (attempt 1)\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:00:00Z"},
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) (attempt 2)\n<!-- bodat:worker -->","createdAt":"2026-09-11T01:10:00Z"}
]'

# 16) 동초 — 반송 마커와 같은 초에 ⚠ 후행 → held. 6)·7) 의 ✅ 대칭 케이스와 같은
#     이유(GitHub 코멘트 시각은 초 단위라 인덱스로만 가려낼 수 있다).
run_case "동초·⚠ 후행→held" held '[
  {"body":"재검증 실패: #218 — codex BLOCKER <!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"}
]'

# 17) 영문 `Merge verdict: ⚠` 도 held 를 낸다(한/영 병행 워커, ✅ 의 영문 게이트와 대칭).
run_case "영문 Merge verdict ⚠ 후행→held" held '[
  {"body":"재검증 실패: #218 — codex BLOCKER <!-- bodat:worker -->","createdAt":"2026-09-11T00:50:00Z"},
  {"body":"Merge verdict: ⚠ hold — policy question\n<!-- bodat:worker -->","createdAt":"2026-09-11T02:00:00Z"}
]'

# 12) 인자 누락 — 호출자 실수를 조용한 `ok` 로 만들지 않는다.
rc=0
out=$(PATH="$tmp/bin:$PATH" bash "$SUT" 2>/dev/null) || rc=$?
if [ "$rc" != 0 ] && [ -z "$out" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 인자 누락→비정상 종료·무출력 이어야 한다 rc=$rc out=[$out]"
fi

echo "bounce-state.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
