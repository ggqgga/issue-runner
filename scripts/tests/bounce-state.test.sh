#!/usr/bin/env bash
# bounce-state.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
#
# #196: closeout ①-b 의 **CONFLICTING 입양** 경로에 반송 안전망을 붙이기 위해, 반송
# 판정을 `closeout-eligible.sh` 안에서 이 헬퍼 한 자리로 뽑았다. 그래서 이 파일이
# 반송 마커 판정 자체의 SSOT 테스트다(closeout-eligible.test.sh 는 그 판정이 후보
# 필터에 **배선돼 있는지**를 잰다 — 두 층을 일부러 나눠 둔다).
#
# 이 헬퍼가 답하는 질문은 하나다: **최신 반송 마커 뒤에 오는 판정 코멘트 중 가장 늦은
# 것이 무엇인가**(#218 attempt 3 이 규칙으로 옮기고, attempt 4 가 후보에 `🔄` 를 더했다).
#   ok      = 반송 마커가 없거나, 그 뒤 마지막 판정이 `머지 판정: ✅` → 마감 레인이 만져도 된다
#   bounced = 반송 뒤 판정이 하나도 없거나, 그 뒤 마지막 판정이 `머지 판정: 🔄`(교체 워커가
#             재개했다) → **워커 레인 소유**(closeout 무접촉). `🔄` 가 후보라는 것이
#             `held` 의 **해제 경로**다 — 사람이 보류를 풀고 워커가 재개하면 여기로 온다
#   held    = 반송 뒤 마지막 판정이 `머지 판정: ⚠ 보류` → **①-b 스윕은 무접촉**(#218 사람
#             결정 (c) — 스윕의 홀드 재부착 폐지). 이 값으로 `needs-human` 을 승격하지
#             않는다(재디스패치로도 가지 않는다 — 살아있는 교체 워커와 충돌하는 건 그 갈래다)
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

# ── #212: 콜론 리터럴 매칭이 문구 변형을 놓친다 ──────────────────────────
# 마커 판정을 콜론 리터럴 startswith 에서 **접두(단어) 매칭**으로 넓힌다 — 코멘트
# 첫 줄이 `재디스패치`/`재검증 실패` 로 **시작**하면 뒤에 무엇이 오든(`:`·` attempt N`·
# `(round 2)`) 반송으로 센다. 실사고(PR #202): 콜론 없는 `재디스패치 attempt 3 — …`
# 를 옛 구현이 못 잡아 closeout-eligible.sh 가 반송된 PR 을 다시 후보로 올렸다.

# 5-b) 콜론 없는 `attempt N` 변형(closeout 채널) → bounced. 사고 재현 형태 그대로.
run_case "#212 콜론 없는 attempt 변형→bounced" bounced '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-11T07:00:00Z"},
  {"body":"재디스패치 attempt 3 — 마감 검증 BLOCKER(코드 회귀) <!-- bodat:worker -->","createdAt":"2026-09-11T07:30:00Z"}
]'

# 5-c) 콜론 있는 기존 형태도 **여전히** bounced — 접두 매칭으로 넓혀도 무회귀.
run_case "#212 콜론 있는 기존 형태도 무회귀→bounced" bounced '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-11T07:00:00Z"},
  {"body":"재디스패치: #193 — 마감 검증 BLOCKER(코드 회귀) <!-- bodat:worker -->","createdAt":"2026-09-11T07:30:00Z"}
]'

# 5-d) verify-runner 채널의 콜론 없는 변형(`(round 2)`) → bounced. 두 채널 모두
#      같은 규칙을 적용한다는 계약(BOUNCE_MARKERS 한 자리).
run_case "#212 재검증 실패 콜론 없는 (round 2) 변형→bounced" bounced '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-11T07:00:00Z"},
  {"body":"재검증 실패 (round 2) — E2E 실패 <!-- bodat:worker -->","createdAt":"2026-09-11T07:30:00Z"}
]'

# 5-e) **과잉 매칭 금지**: 본문 중간에 `재디스패치` 를 언급만 하는 설명 코멘트(이 이슈
#      본문과 같은 실제 형태 — 결함을 서술하며 마커 단어를 인용)는 반송으로 세면 안
#      된다. 첫 줄이 그 단어로 **시작하지 않으므로** ok 로 남아야 한다(#197 이 고치는
#      "인용된 마커가 제어 신호로 읽히는" 축과 같은 자리 — 여기서는 판정 쪽을 좁혀 막는다).
run_case "#212 본문 중간 언급만·시작 아님→ok(과잉매칭 금지)" ok '[
  {"body":"이 PR 은 #212(반송 마커가 콜론 리터럴이라 「재디스패치 attempt N」 이 안전망을 통과하는 결함)를 고친다. BOUNCE_MARKERS 매칭을 접두 검사로 바꿨다.\n<!-- bodat:worker -->","createdAt":"2026-09-11T07:00:00Z"}
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

# ── 마커 뒤 형태 격자(#221 · #251) — "마커 뒤가 무엇이냐" 를 전수 단언 ──────
# **규칙 한 줄**(#251 이 두 축을 닫으며 한 술어로 다시 씀): 반송 마커는 코멘트 **첫 줄
# 맨 앞**에 있어야 하고, 그 뒤에 남는 꼬리(`$t`)의 형태가 셋 중 어디냐로 갈린다.
#   ⑴ **반송 관용 구분자**로 시작한다(`:` · 공백?+`#` · 공백?+`(` · 공백?+대시 ·
#      공백?+숫자 · 줄 끝/개행) → **무조건 bounced**. `bounce-comment.sh` 가 찍는 기계
#      채널 본문(`마커: #N — 사유`)이 전부 여기 들어와 아래 예외로도 안 샌다.
#   ⑵ **산문이 이어진다**(한글 음절이 바로 붙거나 — 조사·어미 — 공백 뒤에 낱말이 온다)
#      → 마커가 문장 안 낱말로 쓰인 것이다. 여기서만 두 축을 가른다:
#        · **반송 표식**(`#숫자` · `attempt` · 대시 · `반송`)이 있을 때만 `bounced`
#          (#251 ① — 조사가 붙은 진짜 반송), 없으면 `ok`. 해소·완료 어휘는 판정에
#          **관여하지 않는다** — attempt 2 의 어휘 거부권은 진짜 반송을 `ok` 로 흘려
#          attempt 3 에서 걷어냈다(SUT 헤더 "② 는 문안으로 닫았다" 절). 반송 해소
#          보고는 판정기가 아니라 문안(`반송 반영 …` 접두 — 마커 집합 밖)으로 닫는다.
#   ⑶ 그 밖(공백 없는 문장부호·라틴 부착 등) → bounced.
#
# 왜 ⑴ 을 열거로 두고도 안전한가: 열거 밖으로 새는 형태는 ⑵ 의 **반송 표식**이 다시
# 받는다 — 두 겹이라 `[attempt 3] — 사유`·` 3회차` 같은 진짜 반송이 열거 밖에 있어도
# 잡힌다(#212 가 막은 fail-open 으로 되돌아가지 않는다). 단 표식 없는 꼬리 앞에 공백이
# 두 칸 이상·탭이거나 ` :`·` [` 면 둘째 겹도 못 받는다 — 파생 #299.
# (PR#202 교훈: 리뷰가 짚은 개별 반례만 차례로 막지 말고 규칙 자체를 옮긴 뒤 `want`
# 열을 가진 격자로 전수 단언하라 — 근사가 '더 지우는' 방향으로 틀리면 원래 버그보다
# 나쁘다.)
#
# #251 이 뒤집은 두 칸(SUT 헤더 주석의 "값과 대가" 절과 짝 — 그 절도 같이 고쳤다):
#   · **①(fail-open 이었다)** — 마커 + 한글 조사 + 반송 표식(`재검증 실패로 반송합니다
#     — #193`)은 이제 `bounced`. 손으로 쓴 반송이 안전망을 조용히 지나가던 구멍이다.
#     표식이 전혀 없는 `…가 필요한지 확인했습니다`·`…를 분석합니다` 는 `ok` 그대로다.
#   · **②(fail-closed 였다)** — 마커 + 공백 + 표식 없는 산문(`재디스패치 필요 여부를
#     검토합니다`)은 이제 `ok`. 아무도 반송하지 않은 PR 을 마감 레인이 다음 판정성
#     코멘트까지 뺐던 정체다. 옛 문안 해소 보고(`재디스패치 attempt 2 — … 해소.`)는
#     표식 때문에 `bounced` 그대로다 — 새 해소 보고는 `반송 반영 …` 으로 쓴다.
#
# 경계 판단(#251 이 고른 쪽, 이슈가 "본문에 근거를 적고 want 열에 못박아라" 한 칸):
# `재검증 실패로 반송합니다` — 뒤에 `#N`·`attempt`·대시가 **하나도 없는** 반송 문장 —
# 은 `bounced` 로 정한다. `반송` 을 반송 표식 어휘에 넣어 닫았다. 근거: 이 축은
# **유실(fail-open)이 정체(fail-closed)보다 나쁘다**(이슈 ① 절). 대가는 `재디스패치
# 반송 규칙을 정리했습니다` 류가 `bounced` 로 정체하는 것인데, 그건 다음 판정성
# 코멘트 한 건으로 풀리고 반송 유실은 **잘못된 코드가 머지되는 것**이라 값이 다르다.
#
# 격자의 마커는 **SUT 에서 읽는다** — 테스트가 리터럴을 복제하면 ②와 똑같은 "두 벌" 이
# 된다(SSOT 마커를 바꿨을 때 격자가 낡은 채로 초록).
markers_json=$(sed -n "s/^BOUNCE_MARKERS='\\(.*\\)'\$/\\1/p" "$SUT" | head -1)
if printf '%s' "$markers_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ SUT 에서 BOUNCE_MARKERS 를 읽지 못했다(격자가 마커 리터럴을 복제하지 않는다는 계약): [$markers_json]"
fi

# grid_case <name> <want: ok|bounced> <후보 코멘트 본문>
#   선행 ✅ 하나를 깔고 후보를 마지막 코멘트로 둔다 — `bounced` = 마커로 인식됨,
#   `ok` = 인식 안 됨. 주입 경로를 쓰므로 네트워크·gh 무접속이다.
grid_ran=0
grid_case() {
  local name="$1" want="$2" body="$3"
  jq -n --arg b "$body" '[
    {body:"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->", createdAt:"2026-09-11T07:00:00Z"},
    {body:$b, createdAt:"2026-09-11T07:30:00Z"}
  ]' > "$tmp/grid.json"
  grid_ran=$((grid_ran + 1))
  run_file_case "$name" "$want" "$tmp/grid.json"
}

# 마커 목록은 공백을 담으므로(`재검증 실패`) IFS 를 개행으로 두고 위치 인자에 싣는다.
# `set -f` 로 글롭 확장을 끈다 — 마커에 `*`·`?` 가 섞이면 경로로 번질 자리다.
grid_old_ifs=$IFS
set -f
IFS='
'
# shellcheck disable=SC2046
set -- $(printf '%s' "$markers_json" | jq -r '.[]')
IFS=$grid_old_ifs
set +f
grid_markers=$#
for gm in "$@"; do
  # 격자 행은 **fd 3** 으로 읽는다 — 루프 본문이 stdin 을 먹는 명령을 부르면 남은 행이
  # 조용히 사라지고 스위트는 초록이 된다(안 돌린 테스트는 CI 를 못 빨갛게 한다 —
  # PR#219 교훈). 아래 총 실행 건수 단언이 그 사각지대의 두 번째 자물쇠다.
  while IFS='|' read -r g_want g_suffix g_label <&3; do
    [ -n "$g_want" ] || continue
    grid_case "격자[$gm]$g_label" "$g_want" "$gm$g_suffix"
  done 3<<'GRID'
bounced|: #193 — 마감 검증 BLOCKER(코드 회귀)|⑴+콜론(기계 채널 bounce-comment.sh 형태)
bounced|: #193 — 지적 사항 해소 요망|⑴+콜론은 '해소' 어휘로도 안 풀린다(기계 채널 불가침)
bounced| #193 — 반송|⑴+공백 #N
bounced| #193 — 이전 지적 해소 요망|⑴+공백 #N 은 '해소' 어휘로도 안 풀린다
bounced| (round 2) — E2E 실패|⑴+공백 (괄호
bounced| — 사유만 대시로|⑴+공백 대시
bounced|2회차 — 반송|⑴+숫자 직접 부착
bounced| 3회차 — 반송|⑴+공백 숫자
bounced||⑴마커만·줄 끝
bounced|[attempt 3] — 사유|⑶+공백 없는 대괄호 부착(열거 밖이어도 잡힌다)
ok|가 필요한지 확인했습니다|①대조 +조사 '가'·반송 표식 없음
ok|를 분석합니다|①대조 +조사 '를'·반송 표식 없음
ok|가 fail-open 인지 확인했습니다|①대조 하이픈은 대시가 아니다(반송 표식 아님)
bounced|로 반송합니다 — #193|① +조사 '로'+반송 표식(#N·대시)
bounced|했습니다 — #193|① +어미+반송 표식(#N·대시)
bounced|했다(attempt 3)|① +어미+attempt
bounced|로 반송합니다|① 경계 판단 — '반송' 낱말만으로도 bounced(유실이 더 나쁘다)
ok| 필요 여부를 검토합니다|② +공백 평범한 명사·표식 없음(#251 이 연 칸)
bounced| 회차 완료 — 마감 검증 BLOCKER 를 고쳤다|(가) 옛 보고 문안 — 대시 표식이 있으면 어휘와 무관하게 반송이다
bounced| 반영 완료(BLOCKER 1건 해소) — 재푸시했다|(가) 옛 보고 문안 — '완료·해소' 가 표식을 무르지 않는다
bounced| 반영(attempt 3) — P1 BLOCKER·P2 WARN 해소|(가) 옛 보고 문안 — attempt+대시
bounced| attempt 2 — 마감 검증 BLOCKER(#193) 해소.|(가) 옛 보고 문안 — attempt+#N+대시
bounced| attempt 3 — 마감 검증 BLOCKER|① 표식만으로 반송
bounced| attempt 3 — 마감 검증 BLOCKER 미해소|① 부정 접두 '미' 가 섞여도 표식이 이긴다
bounced| 요청 — BLOCKER 해소 요망|① 해소 **요구**(명령형)
bounced| 바랍니다 — #193 (BLOCKER 미해소 항목 해소 필요)|① 해소 필요
bounced| 재현 — 회귀 해소 바람|① 해소 바람
bounced| 부탁 — #193 지적 해소해 주세요|① 해소해 주세요
bounced| 요청 — BLOCKER 해소가 필요합니다|① 회귀7-1 조사 '가' 가 낀 요구형(검증자 BLOCKER)
bounced| 요청 — BLOCKER가 아직 해소되지 않았습니다|① 회귀7-2 부정 어미 '되지 않았'(검증자 BLOCKER)
bounced| 요청 — #193 BLOCKER 가 해소되지 않았다|① 회귀7-3 부정 어미+#N
bounced| 요청 — #193 BLOCKER 가 아직 해소 안 됨|① 회귀7-4 부정 종결 '안 됨'
bounced| 재현 — E2E 완료 후에도 회귀가 남는다|① 회귀7-5 '완료' 과거 인용
bounced| attempt 4 — #193 회귀 재발(이전 해소분이 되돌아왔다)|① 회귀7-6 과거 인용 '이전 해소분'
bounced| attempt 3 — 마감 검증 BLOCKER 2건, 이전 1건만 해소|① 회귀7-7 부분 해소 인용
bounced| 3건을 검토했습니다|⒜ 공백+숫자가 산문보다 먼저 — 옛 규칙 그대로 정체(안전 방향, 못박는다)
bounced|(재검토) 여부를 묻는다|⒜ 괄호 부착도 산문보다 먼저 — 옛 규칙 그대로 정체
GRID
  # 마커 바로 뒤 **개행** 도 구분자다(첫 줄이 마커 하나로만 이뤄진 반송).
  grid_case "격자[$gm]+개행" bounced "$gm
둘째 줄 — 사유"
  # 첫 줄 **시작이 아닌** 인용은 여전히 반송이 아니다 — #212 수용 기준 4번의 축은
  # 그대로 유지된다(구분자 요구는 앵커를 대체하지 않고 덧붙는다).
  grid_case "격자[$gm]본문 중간 인용" ok "이 코멘트는 $gm 라는 마커가 무엇인지 설명한다."
  # 표식은 **첫 줄에서만** 센다(이슈가 "같은 줄 뒤쪽" 이라 적은 범위). 제목처럼 마커만
  # 쓰고 사유를 다음 줄로 내린 손 반송은 옛 규칙과 똑같이 `ok` 다 — 의도한 범위이므로
  # 다음 사람이 버그로 오인하지 않게 `want` 로 못박는다(첫 줄이 마커 하나면 ⒜ 로 떨어져
  # `bounced` 인 위 "+개행" 행과 갈리는 자리다 — 여기선 첫 줄에 어미가 붙어 있다).
  grid_case "격자[$gm]제목형 개행(어미 부착·첫 줄에 표식 없음)" ok "${gm}합니다
— #193 마감 검증 BLOCKER"
done

# 격자가 **실제로 다 돌았는지** 를 센다 — 행이 조용히 사라져도 스위트가 초록이면 격자는
# 아무것도 못 막는다(PR#219: 안 돌린 테스트는 CI 를 못 빨갛게 한다). 마커당 40행
# (heredoc 37 + 개행 1 + 중간 인용 1 + 제목형 개행 1).
grid_expected=$((grid_markers * 40))
if [ "$grid_ran" = "$grid_expected" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 격자 실행 건수 — 기대=$grid_expected(마커 $grid_markers × 40) 실제=$grid_ran"
fi
# ── 리터럴 절 — 조립 없이 **완성된 첫 줄 그대로** 먹인다 ──────────────────
# 격자 행은 마커를 파라미터로 조립하므로 원문 그대로는 아니다(조립 과정에서 형태를
# 놓치면 이 절이 잡는다). 픽스처 형상은 이슈가 적은 실패 시나리오 그대로다:
# **최신 `머지 판정: ✅` 뒤에** 후보가 달린다.
#
# 세 묶음이다:
#  ⑴ **원장 실측 보고 4건** — 이슈 #251 ② 가 든 형태. 이슈 본문은 `…` 로 줄인
#     인용이라 여기 문자열은 그 생략부를 실제 형태로 채운 것이다(원문 축약이 아니다).
#     (가) 를 고른 뒤 이 넷의 `want` 는 **bounced** 다 — 대시·attempt 표식을 달고 있으니
#     판정기는 반송으로 읽는다. 이 정체를 없애는 것은 판정기가 아니라 **문안**이다
#     (아래 ⑵ — `references/worker-template.md` 가 규정한 새 접두).
#  ⑵ **새 보고 문안 3건**(`반송 반영…`) — 마커 집합 밖이라 판정에 아예 안 걸린다(`ok`).
#     ② 축이 여기서 닫힌다: 아무도 반송하지 않은 PR 이 마감 후보에서 빠지지 않는다.
#  ⑶ **회귀 7형태** — 검증자·독립 소스가 main 대조로 실측한, 직전 회차가 `ok` 로
#     흘린 진짜 반송들(want=bounced). 전부 "표식 + 해소/완료 어휘" 조합이다.
lit_ran=0
lit_case() {
  local want="$1" body="$2"
  jq -n --arg b "$body" '[
    {body:"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->", createdAt:"2026-09-11T07:00:00Z"},
    {body:$b, createdAt:"2026-09-11T07:30:00Z"}
  ]' > "$tmp/lit.json"
  lit_ran=$((lit_ran + 1))
  run_file_case "형태[$want] $body" "$want" "$tmp/lit.json"
}
while IFS='|' read -r l_want l_body <&3; do
  [ -n "$l_want" ] || continue
  lit_case "$l_want" "$l_body"
done 3<<'LIT'
bounced|재디스패치 회차 완료 — 마감 검증 BLOCKER 를 닫았다
bounced|재디스패치 반영 완료(BLOCKER 1건 해소) — 재푸시·로컬 CI pass
bounced|재디스패치 반영(attempt 3) — P1 BLOCKER·P2 WARN 해소, 로컬 CI pass
bounced|재디스패치 attempt 2 — 마감 검증 BLOCKER(계획 부합) 해소.
ok|반송 반영: 마감 검증 BLOCKER 를 닫았다 — 재푸시·로컬 CI pass
ok|반송 반영(attempt 3): P1 BLOCKER·P2 WARN 해소, 로컬 CI pass
ok|반송 반영 — 마감 검증 BLOCKER(계획 부합) 해소.
bounced|재디스패치 요청 — BLOCKER 해소가 필요합니다
bounced|재디스패치 요청 — BLOCKER가 아직 해소되지 않았습니다
bounced|재디스패치 요청 — #193 BLOCKER 가 해소되지 않았다
bounced|재디스패치 요청 — #193 BLOCKER 가 아직 해소 안 됨
bounced|재검증 실패 재현 — E2E 완료 후에도 회귀가 남는다
bounced|재디스패치 attempt 4 — #193 회귀 재발(이전 해소분이 되돌아왔다)
bounced|재디스패치 attempt 3 — 마감 검증 BLOCKER 2건, 이전 1건만 해소
ok|재디스패치 필요 여부를 검토합니다
ok|재검증 실패를 분석합니다
LIT
lit_expected=16
if [ "$lit_ran" = "$lit_expected" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 리터럴 절 실행 건수 — 기대=$lit_expected 실제=$lit_ran"
fi

# 빈 body 코멘트(#251 사전 리뷰 WARN) — 첫 줄 추출이 `null` 을 내면 `startswith` 가
# jq 런타임 에러를 던져 **그 PR 의 판정 전체가 exit 1(판정 실패)** 이 된다. 코멘트 한
# 건 때문에 마감이 통째로 막히는 새 경로라 정상 판정으로 받는다(옛 코드도 무해했다).
printf '%s' '[
  {"body":"","createdAt":"2026-09-11T07:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-11T07:30:00Z"}
]' > "$tmp/emptybody.json"
run_file_case "빈 body 코멘트가 섞여도 판정은 계속된다→ok" ok "$tmp/emptybody.json"
printf '%s' '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-11T07:00:00Z"},
  {"body":"","createdAt":"2026-09-11T07:15:00Z"},
  {"body":"재디스패치: #193 — 완결 유실(검증 전 사망)","createdAt":"2026-09-11T07:30:00Z"}
]' > "$tmp/emptybody2.json"
run_file_case "빈 body 가 반송 마커를 가리지 않는다→bounced" bounced "$tmp/emptybody2.json"

# ── 뮤테이션 방증(#251) — 네 가드를 **따로** 지우면 **서로 다른** 칸이 빨개진다 ──────
# 이슈가 명시적으로 요구한 방증이다: "각 축의 가드를 따로 지우는 뮤테이션이 서로 다른
# 테스트를 빨갛게 하는지 실측하라 — 한 테스트가 두 축을 동시에 물면 한 축이 조용히
# 회귀한다."
#   MUT-1 (⒝ 한글 갈래 → false) = 구 #221 규칙(조사·어미가 붙으면 **무조건** 반송 아님)
#   MUT-2 (⒝ 공백 갈래 → true)  = 구 #221 규칙(공백은 **무조건** 구분자 = 반송)
#   MUT-A (⒜ 구분자 갈래 → false) = 관용 구분자 우선 판정을 통째로 없앤 판
#   MUT-V ($bmark 에 해소 어휘 거부권 복원) = **직전 회차(attempt 2)의 판**. 이 회차가
#         되돌린 바로 그 근사라, 회귀 7형태가 여기서 `ok` 로 뒤집히는지가 이 PR 의 핵심
#         방증이다(검증자가 main 대조로 실측한 그 표를 뮤테이션으로 재현한다).
# 앵커는 **코드 형태까지** 요구한다 — `.*# MUT-N` 만으로는 SUT 헤더 주석에서 이 앵커를
# 설명하는 줄까지 물어 뮤턴트 최상위에 벌거벗은 값이 주입된다(사전 리뷰 WARN). 그래서
# 결과식/정의식 줄의 **시작 형태**까지 못박고, **정확히 한 줄만** 바뀌었는지도 센다.
mut1_sut="$tmp/mut1-bounce-state.sh"
mut2_sut="$tmp/mut2-bounce-state.sh"
muta_sut="$tmp/muta-bounce-state.sh"
mutv_sut="$tmp/mutv-bounce-state.sh"
sed -E 's@^ *\$bmark +# MUT-1.*@                        false@' "$SUT" > "$mut1_sut"
sed -E 's@^ *\$bmark +# MUT-2.*@                        true@'  "$SUT" > "$mut2_sut"
sed -E 's@^ *\| \(\$t \| test.*# MUT-A.*@                    | false as $sep@' "$SUT" > "$muta_sut"
sed -E 's@^ *\| \(\$t \| test.*# MUT-V.*@                    | (($t | test("#[0-9]|attempt|[–—]|반송"; "i")) and (($t | test("(^|[^미불])(완료|해소)")) | not)) as $bmark@' "$SUT" > "$mutv_sut"
for mpair in "MUT-1:$mut1_sut" "MUT-2:$mut2_sut" "MUT-A:$muta_sut" "MUT-V:$mutv_sut"; do
  mname=${mpair%%:*}; mfile=${mpair#*:}
  changed=$(diff "$SUT" "$mfile" | grep -c '^< ' || true)
  if [ "$changed" = 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ 뮤테이션 앵커($mname) 가 정확히 한 줄을 바꾸지 않았다(바뀐 줄=$changed) — 0 이면 앵커 실종, 2+ 면 주석까지 물었다"
  fi
done

ax_pass=0
ax_fail=0
# ax_run <sut> <라벨> <want> <후보 본문>  — 격자와 같은 형상(선행 ✅ + 후보)으로 먹인다.
ax_run() {
  local sut="$1" label="$2" want="$3" body="$4" out rc=0
  jq -n --arg b "$body" '[
    {body:"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->", createdAt:"2026-09-11T07:00:00Z"},
    {body:$b, createdAt:"2026-09-11T07:30:00Z"}
  ]' > "$tmp/ax.json"
  out=$(PATH="$tmp/bin:$PATH" STUB_FAIL_COMMENTS=1 BOUNCE_COMMENTS_FILE="$tmp/ax.json" \
    bash "$sut" owner/repo 5 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then
    ax_pass=$((ax_pass + 1))
  else
    ax_fail=$((ax_fail + 1))
    echo "  ✗ 뮤테이션 대조 — $label 기대=$want 실제 rc=$rc out=[$out]"
  fi
}

# **원본 / MUT-1 / MUT-2 / MUT-A / MUT-V** 다섯 벌에 같은 입력을 먹여 어느 칸이 뒤집히는지
# 본다. want 열: <원본>|<MUT-1>|<MUT-2>|<MUT-A>|<MUT-V>
# 읽는 법 — 한 줄에서 원본과 다른 칸이 그 뮤턴트가 **혼자 무는** 자리다:
#   · MUT-1 = ① 축(조사·어미가 붙은 진짜 반송) 4칸
#   · MUT-2 = ② 축(공백 뒤 산문 중 표식 없는 것) 1칸
#   · MUT-A = ⒜ 가 **혼자** 지키는 1칸(` 3건을 검토했습니다` — 숫자 구분자). 나머지 ⒜
#     형태(`: #193 —`·` #193 —`·` — 사유`)는 ⒞ `else true` 와 ⒝ 의 표식이 두 겹으로
#     받아 MUT-A 로도 안 뒤집힌다 — 그 사실 자체를 want 열에 못박는다(직전 회차 NIT ⑵:
#     "⒜ 를 무력화해도 2건만 빨개진다" 는 관측을 여기서 칸별로 설명한다).
#   · MUT-V = 직전 회차의 어휘 거부권 8칸(회귀 7형태 + 옛 보고 문안 1건)
while IFS='|' read -r a_base a_m1 a_m2 a_ma a_mv a_body <&3; do
  [ -n "$a_base" ] || continue
  ax_run "$SUT"      "원본   [$a_body]" "$a_base" "$a_body"
  ax_run "$mut1_sut" "MUT-1 [$a_body]" "$a_m1"   "$a_body"
  ax_run "$mut2_sut" "MUT-2 [$a_body]" "$a_m2"   "$a_body"
  ax_run "$muta_sut" "MUT-A [$a_body]" "$a_ma"   "$a_body"
  ax_run "$mutv_sut" "MUT-V [$a_body]" "$a_mv"   "$a_body"
done 3<<'AX'
bounced|ok|bounced|bounced|bounced|재검증 실패로 반송합니다 — #193
bounced|ok|bounced|bounced|bounced|재디스패치했습니다 — #193
bounced|ok|bounced|bounced|bounced|재디스패치했다(attempt 3)
bounced|ok|bounced|bounced|bounced|재검증 실패로 반송합니다
ok|ok|bounced|ok|ok|재디스패치 필요 여부를 검토합니다
ok|ok|ok|ok|ok|재디스패치가 필요한지 확인했습니다
bounced|bounced|bounced|bounced|bounced|재디스패치: #193 — 완결 유실(검증 전 사망)
bounced|bounced|bounced|bounced|bounced|재디스패치 attempt 3 — 마감 검증 BLOCKER
bounced|bounced|bounced|ok|bounced|재디스패치 3건을 검토했습니다
bounced|bounced|bounced|bounced|bounced|재디스패치(재검토) 여부를 묻는다
bounced|bounced|bounced|bounced|bounced|재디스패치 #193 — 사유
bounced|bounced|bounced|bounced|bounced|재디스패치 — 사유만 대시로
bounced|bounced|bounced|bounced|ok|재디스패치 요청 — BLOCKER 해소가 필요합니다
bounced|bounced|bounced|bounced|ok|재디스패치 요청 — BLOCKER가 아직 해소되지 않았습니다
bounced|bounced|bounced|bounced|ok|재디스패치 요청 — #193 BLOCKER 가 해소되지 않았다
bounced|bounced|bounced|bounced|ok|재디스패치 요청 — #193 BLOCKER 가 아직 해소 안 됨
bounced|bounced|bounced|bounced|ok|재검증 실패 재현 — E2E 완료 후에도 회귀가 남는다
bounced|bounced|bounced|bounced|ok|재디스패치 attempt 4 — #193 회귀 재발(이전 해소분이 되돌아왔다)
bounced|bounced|bounced|bounced|ok|재디스패치 attempt 3 — 마감 검증 BLOCKER 2건, 이전 1건만 해소
bounced|bounced|bounced|bounced|ok|재디스패치 attempt 2 — 마감 검증 BLOCKER(계획 부합) 해소.
ok|ok|ok|ok|ok|반송 반영: 마감 검증 BLOCKER(계획 부합) 해소 — 재푸시·로컬 CI pass
AX
if [ "$ax_fail" = 0 ] && [ "$ax_pass" = 105 ]; then
  pass=$((pass + 1))
  echo "  ✓ 뮤테이션 방증(#251): MUT-1 ①4칸 · MUT-2 ②1칸 · MUT-A ⒜단독1칸 · MUT-V 어휘거부권8칸 — 축이 겹치지 않는다(ax_pass=$ax_pass)"
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 방증(#251) 실패 — ax_pass=$ax_pass ax_fail=$ax_fail (기대 ax_pass=105)"
fi

# ── held(#218 attempt 2 — codex BLOCKER) ─────────────────────────────────
# attempt 1 은 bounced 를 무조건 조기 종료해, 반송 뒤 교체 워커가 새로 올린
# `머지 판정: ⚠ 보류` 를 영원히 못 봤다. ✅ 와 대칭으로 ⚠ 도 마지막 매칭 인덱스로 잰다.
# (해제 방향 — `held` 가 어떻게 풀리는가 — 은 아래 "해제 경로 격자(#218 attempt 4)".)

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

# ── 격자(#218 attempt 2 BLOCKER 방증) — 반송 이후 마지막 종결 판정이 이긴다 ──────
# 판정 규칙(말로 적는다): "반송 마커 이후에 오는 종결 판정(✅/⚠) 중 **가장 늦은 것**이
# 결과를 정한다. 반송 마커가 없으면 ok. 반송 이후 종결 판정이 없으면 bounced."
# attempt 1 은 `$vi != null and $bi <= $vi` 를 **존재 검사**로만 써서, ✅ 가 반송 뒤에
# 한 번이라도 오면 그 뒤에 더 늦은 ⚠ 이 있어도 그 사실을 보지 못하고 ok 로 새는
# BLOCKER 를 남겼다 — 아래 18)이 그 정확한 반례다(bodat PR #225 검증자 리뷰 재현).
# 이 레포 lessons.md(PR#202)가 "짚힌 반례 하나만 차례로 막지 말고 규칙을 옮긴 뒤 순열
# 격자로 전수 단언하라" 고 남겼으므로, 최소 순열을 여기 한 자리에 모은다.

# 18) **BLOCKER 방증**: 반송 → ✅ → ⚠ → held. attempt 1 은 $bi<=$vi 가 먼저 참이 되어
#     ok 로 새면서 그 뒤의 ⚠ 을 못 봤다 — 사람 보류를 요청한 PR 이 closeout 에 그대로
#     rebase·입양 경로로 넘어간다.
run_case "격자·반송→✅→⚠→held(BLOCKER 방증)" held '[
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:30:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T04:00:00Z"}
]'

# 19) 역순: 반송 → ⚠ → ✅ → ok. ⚠ 뒤에 더 늦은 ✅ 가 오면 정상 완결로 되돌아간다 —
#     18)만 있으면 "⚠ 이 한 번이라도 있으면 무조건 held" 로 과잉 일반화될 수 있어
#     양방향을 함께 문다.
run_case "격자·반송→⚠→✅→ok(역순)" ok '[
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:30:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-09-11T04:00:00Z"}
]'

# 20) ✅ 단독(반송 없음) → ok. $bi == null 이면 뒤 판정과 무관하게 즉시 ok 여야 한다.
run_case "격자·✅ 단독→ok" ok '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"}
]'

# 21) ⚠ 단독(반송 없음) → ok. held 는 **반송 뒤**의 ⚠ 만 본다 — 반송이 아예 없는데
#     ⚠ 만 있는 PR 을 이 스크립트가 needs-human 으로 올리면 안 된다(그건
#     finish-classify.sh 의 held 행 몫).
run_case "격자·⚠ 단독→ok(반송 없음)" ok '[
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"}
]'

# 22) ✅ → 반송 → bounced. 종결 판정이 반송보다 **앞**이면 무의미하다 — 반송이
#     마지막이면 그 앞에 무엇이 있든 워커 레인 소유.
run_case "격자·✅→반송→bounced" bounced '[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"},
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-09-11T03:30:00Z"}
]'

# 23) 반송 → ✅ → 반송 → bounced. $bi 는 **마지막** 반송 마커 인덱스라 두 번째 반송이
#     기준이 된다 — 그 앞의 ✅ 는 이미 낡은 신호라 못 살린다.
run_case "격자·반송→✅→반송→bounced" bounced '[
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:30:00Z"},
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) (attempt 2) <!-- bodat:worker -->","createdAt":"2026-09-11T04:00:00Z"}
]'

# 24) 반송 → ⚠ → 반송 → ✅ → ok. 15)(held 뒤 재반송→bounced)의 연장 — 재반송 뒤에
#     새 ✅ 까지 찍히면(교체 워커가 정상 완결) 다시 ok 로 돌아온다.
run_case "격자·반송→⚠→반송→✅→ok" ok '[
  {"body":"재검증 실패: #218 — codex BLOCKER (attempt 1) <!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:30:00Z"},
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) (attempt 2) <!-- bodat:worker -->","createdAt":"2026-09-11T04:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증)\n<!-- bodat:worker -->","createdAt":"2026-09-11T04:30:00Z"}
]'

# 25) 반송 → ⚠ → ⚠(같은 종류 반복) → held. $hi 는 마지막 매칭 인덱스라 반복돼도
#     흔들리지 않아야 한다.
run_case "격자·반송→⚠→⚠→held(반복)" held '[
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문 1\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:30:00Z"},
  {"body":"머지 판정: ⚠ 보류 — 정책 질문 2\n<!-- bodat:worker -->","createdAt":"2026-09-11T04:00:00Z"}
]'

# 26) 반송 → ✅ → ✅(같은 종류 반복) → ok. $vi 도 반복에 흔들리지 않는지.
run_case "격자·반송→✅→✅→ok(반복)" ok '[
  {"body":"재디스패치: #218 — 완결 유실(검증 전 사망) <!-- bodat:worker -->","createdAt":"2026-09-11T03:00:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증 1)\n<!-- bodat:worker -->","createdAt":"2026-09-11T03:30:00Z"},
  {"body":"머지 판정: ✅ 머지 가능(재검증 2)\n<!-- bodat:worker -->","createdAt":"2026-09-11T04:00:00Z"}
]'

# ── 해제 경로 격자(#218 attempt 4) — `머지 판정: 🔄` 도 후보다 ───────────────
# 규칙은 attempt 3 이 적은 그대로 한 줄이다: **반송 마커 이후에 오는 판정 코멘트 중
# 가장 늦은 것이 결과를 정한다.** 그런데 후보 집합이 ✅·⚠ 둘뿐이라 `머지 판정: 🔄` 가
# 빠져 있었고, 그래서 새 종결 상태 `held` 에 **진입만 있고 해제가 없었다**:
#   ⑴ 반송 마커  ⑵ 워커 `머지 판정: ⚠ 보류` → closeout 이 `held` → `closeout-blocked`
#   로 `needs-human`+`hold:policy` 부착  ⑶ **사람이 그 보류를 풀어 라벨을 뗀다**
#   ⑷ 교체 워커가 `머지 판정: 🔄` 를 찍고 일을 재개한다  ⑸ 다음 closeout 틱:
#   `needs-human` 이 없으니 PR 이 다시 스윕 대상 → 판정이 **여전히 `held`** → 게이트가
#   `closeout-blocked` 를 **다시** 부른다 → 사람이 방금 푼 보류가 되살아나고, 연결 이슈의
#   단계 라벨이 정리되면서 **살아있는 교체 워커가 끊긴다.** 워커가 `✅` 에 도달해야만
#   풀리는데 끊기니까 도달할 수 없다 — 매 틱 반복되는 영구 정체다.
# 이 레포가 명시적으로 막아 온 "루프 대 사람 싸움"(#151: 스윕이 방금 건 사람 대기를
# 되돌린다)이 방향만 바뀐 형태고, 게이트가 **closeout 매 틱**에 도는 자리라 조용히 반복된다.
#
# 해소는 규칙을 그대로 두고 **후보 집합만 대칭으로 채우는 것**이다 — `🔄` 를 넣되
# 결과값은 `ok` 가 아니라 `bounced`(= 워커 레인 소유). `ok` 로 두면 attempt 1 이 막은
# "CONFLICTING 갈래가 살아있는 워커 PR 을 입양·rebase" 가 되돌아온다.
# (PR#202 교훈: 짚힌 반례 하나만 막지 말고 규칙을 옮긴 뒤 `want` 열 격자로 전수 단언하라.
#  그래서 아래는 해제 방향뿐 아니라 **과잉 해제 반증**까지 같은 격자에 넣는다.)

# seq_case <name> <want> <토큰열>
#   B=`재디스패치`(반송 마커) · V=`머지 판정: ✅` · H=`머지 판정: ⚠ 보류` ·
#   P=`머지 판정: 🔄` · R=`검증자 리뷰:`(판정 코멘트가 아닌 잡음 — 후보 아님) ·
#   소문자 v/h/p = 같은 값의 **영문** 변종(`Merge verdict: …`)
#   코멘트는 토큰 순서대로 배열에 담긴다 — 선후는 인덱스로 재므로 createdAt 은 형식만 맞춘다.
#   주입 경로(BOUNCE_COMMENTS_FILE)를 쓰므로 네트워크·gh 무접속이다.
seq_ran=0
seq_case() {
  local name="$1" want="$2" toks="$3" t b bodies=""
  for t in $toks; do
    case "$t" in
      B) b='재디스패치: #218 — 완결 유실(검증 전 사망)' ;;
      V) b='머지 판정: ✅ 머지 가능(재검증)' ;;
      H) b='머지 판정: ⚠ 보류 — 정책 질문' ;;
      P) b='머지 판정: 🔄 진행 중 — attempt 4' ;;
      R) b='검증자 리뷰: CLEAN' ;;
      v) b='Merge verdict: ✅ ready to merge' ;;
      h) b='Merge verdict: ⚠ hold — policy question' ;;
      p) b='Merge verdict: 🔄 in progress' ;;
      *) fail=$((fail + 1)); echo "  ✗ seq_case 알 수 없는 토큰: [$t] ($name)"; return ;;
    esac
    bodies="$bodies$b
"
  done
  printf '%s' "$bodies" | jq -Rs 'split("\n") | map(select(length > 0)) | to_entries
    | map({body: (.value + "\n<!-- bodat:worker -->"),
           createdAt: "2026-09-11T0\(.key):00:00Z"})' > "$tmp/seq.json" \
    || { fail=$((fail + 1)); echo "  ✗ seq_case 픽스처 생성 실패: $name"; return; }
  seq_ran=$((seq_ran + 1))
  run_file_case "$name" "$want" "$tmp/seq.json"
}

# 격자 행은 **fd 3** 으로 읽는다 — 루프 본문이 stdin 을 먹으면 남은 행이 조용히 사라지고
# 스위트는 초록이 된다(안 돌린 테스트는 CI 를 못 빨갛게 한다 — PR#219 교훈). 아래 실행
# 건수 단언이 그 사각지대의 두 번째 자물쇠다.
while IFS='|' read -r s_want s_toks s_label <&3; do
  [ -n "$s_want" ] || continue
  seq_case "해제격자·$s_label" "$s_want" "$s_toks"
done 3<<'SEQ'
bounced|B H P|반송→⚠→🔄(사람이 풀고 교체워커 재개)→bounced ✱BLOCKER 방증: 되살아나지 않는다
bounced|B H P R|반송→⚠→🔄→검증자 리뷰→bounced(검증자까지 돌아도 마지막 판정은 🔄)
bounced|B H p|영문 🔄 변종도 같은 후보(한/영 병행 워커)
held|B H|과잉해제 반증⑴ 🔄 없이 ⚠ 만이면 여전히 held
ok|B V|과잉해제 반증⑵ 반송 뒤 ✅ 는 종전대로 ok(무회귀)
held|B V H|과잉해제 반증⑵ 반송→✅→⚠ 는 attempt 3 대로 held(무회귀)
held|P B H|과잉해제 반증⑶ 반송 **전** 옛 🔄 는 해제 근거가 아니다(시점 비교)
held|B P H|🔄 뒤에 다시 ⚠ 가 오면 다시 held(양방향)
bounced|B P|반송 뒤 🔄 만→bounced(9 번과 같은 축, 무회귀)
bounced|B R|판정 코멘트가 아닌 잡음(검증자 리뷰)은 후보가 아니다→bounced 유지
bounced|B V P|반송→✅→🔄 는 워커가 다시 붙은 것→bounced(워커 레인 소유)
ok|B H P V|교체 워커가 끝내면 정상 복귀→ok(해제 경로가 열려도 완결은 막히지 않는다)
ok|B P V|반송→🔄→✅ 정상 완결(무회귀)
ok|H P|반송 마커가 없으면 $bi==null 이라 즉시 ok(🔄 가 있어도)
SEQ

# 격자가 **실제로 다 돌았는지** 를 센다(PR#219: 안 돌린 테스트는 CI 를 못 빨갛게 한다).
seq_expected=14
if [ "$seq_ran" = "$seq_expected" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 해제 경로 격자 실행 건수 — 기대=$seq_expected 실제=$seq_ran"
fi

# ── 뮤테이션 방증(#218 attempt 4) — `$p_after` 를 후보에서 빼면 해제가 다시 막힌다 ──
# SUT 사본에서 후보 배열의 `$p_after` 줄 하나만 지우고(= attempt 3 상태) 같은 격자를
# 다시 돌린다. 기대: **🔄 가 마지막 판정인 행만** 옛 값으로 뒤집히고, 나머지는 그대로다
# (대조군이 전부 어긋나는 게 아니라는 증거 — 새 가드가 자기가 막겠다는 회귀를 실제로 문다).
mut_sut="$tmp/mut-bounce-state.sh"
sed '/MUT-P: 해제 경로 후보(#218 attempt 4)/d' "$SUT" > "$mut_sut"
if ! cmp -s "$SUT" "$mut_sut"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 앵커(MUT-P) 를 못 찾았다 — 방증이 아무것도 안 바꾼다"
fi
mut_pass=0
mut_fail=0
mut_run() {
  local name="$1" want="$2" toks="$3" t b bodies="" out rc=0
  for t in $toks; do
    case "$t" in
      B) b='재디스패치: #218 — 완결 유실(검증 전 사망)' ;;
      V) b='머지 판정: ✅ 머지 가능(재검증)' ;;
      H) b='머지 판정: ⚠ 보류 — 정책 질문' ;;
      P) b='머지 판정: 🔄 진행 중 — attempt 4' ;;
      *) echo "  ✗ mut_run 알 수 없는 토큰: [$t]"; mut_fail=$((mut_fail + 1)); return ;;
    esac
    bodies="$bodies$b
"
  done
  printf '%s' "$bodies" | jq -Rs 'split("\n") | map(select(length > 0)) | to_entries
    | map({body: (.value + "\n<!-- bodat:worker -->"),
           createdAt: "2026-09-11T0\(.key):00:00Z"})' > "$tmp/mut.json"
  out=$(PATH="$tmp/bin:$PATH" STUB_FAIL_COMMENTS=1 BOUNCE_COMMENTS_FILE="$tmp/mut.json" \
    bash "$mut_sut" owner/repo 5 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then
    mut_pass=$((mut_pass + 1))
  else
    mut_fail=$((mut_fail + 1))
    echo "  ✗ 뮤테이션 대조 — $name 기대=$want 실제 rc=$rc out=[$out]"
  fi
}
# 뒤집히는 행(옛 결함이 정확히 되살아난다): 🔄 가 반송 뒤 마지막 판정인 형상
mut_run "반송→⚠→🔄(뒤집힘)"   held    "B H P"
mut_run "반송→✅→🔄(뒤집힘)"   ok      "B V P"
mut_run "반송→🔄(불변)"        bounced "B P"
# 대조군(안 뒤집힌다): 🔄 가 결과를 정하지 않는 행들
mut_run "반송→⚠(대조군)"        held    "B H"
mut_run "반송→✅(대조군)"        ok      "B V"
mut_run "반송→✅→⚠(대조군)"     held    "B V H"
mut_run "반송→⚠→🔄→✅(대조군)"  ok      "B H P V"
if [ "$mut_fail" = 0 ]; then
  pass=$((pass + 1))
  echo "  ✓ 뮤테이션 방증: \$p_after 를 후보에서 빼면 🔄 가 마지막인 두 행만 옛 값으로 뒤집힌다(mut_pass=$mut_pass)"
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 방증 실패 — mut_pass=$mut_pass mut_fail=$mut_fail"
fi

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
