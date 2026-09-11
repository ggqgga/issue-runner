#!/usr/bin/env bash
# hold-gate.test.sh — 네 게이트가 `needs-human` 과 `hold:` **접두** 라벨을 **같은 정의로**
# 배제하는지, 하나의 격자를 네 SUT 에 전수 적용해 단언한다 (#242, 플랜 1단계).
#
#   SUT: eligible-issues.sh · claim-issue.sh · closeout-eligible.sh · verify-eligible.sh
#
# 왜 한 파일에 네 SUT 인가: 이 이슈가 막으려는 결함은 "네 자리의 필터가 갈라져 두 번째
# 계산기가 생기는 것" 이다. 격자를 네 벌 쓰면 갈라짐이 테스트에서 안 보이므로, 격자는
# **한 벌**이고 SUT 만 바뀐다. 어느 한 자리가 규칙을 달리 구현하면 그 칸만 빨개진다.
#
# 가장 위험한 실패는 '더 많이 제외하는' 방향이다(정상 후보 소실 — 조용한 큐 사망).
# 그래서 격자에 `holding`·`on-hold`·`area:hold`·`hold-ladder` 처럼 `hold:` 로 **시작하지
# 않는** 라벨을 넣어 통과를 함께 못박는다.
#
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# 작업 cwd — $PWD/.loop/repos 부재라 in_scope 는 전 레포 허용(fail-open, 실증 전제)
cwd="$tmp/cwd"
mkdir -p "$cwd"
# repo-dir.sh 해석 대상 — bin/ci 없는 레포(closeout-ci-pass 의 GitHub rollup 폴백 고정)
mkdir -p "$tmp/proj/repo"

ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
# closeout 후보가 되는 최소 코멘트 형상(✅ 가 head 시각보다 늦다 · 반송 마커 없음).
CLOSEOUT_COMMENTS='[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]'

# names_json <string-array-json> → [{name: …}, …]
names_json() { jq -c -n --argjson l "$1" '[$l[] | {name: .}]'; }
merge_labels() { jq -c -n --argjson a "$1" --argjson b "$2" '$a + $b'; }

# ── gh 스텁 ① 이슈 조회(eligible-issues.sh) ────────────────────────────────
mkdir -p "$tmp/bin.eligible"
cat > "$tmp/bin.eligible/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"api user"*|*"api graphql"*) printf 'tester\n' ;;
  *"search/issues"*) printf '%s\n' "$STUB_CANDS" ;;
  *"--json body"*) printf '\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin.eligible/gh"

# ── gh 스텁 ② claim 경로(claim-issue.sh) — 게이트를 통과하면 실제로 claim 까지 간다 ──
# 게이트가 열렸음을 "skip 이 안 났다" 로 재지 않고 **`claimed:` 출력**으로 재는 이유:
# 뒤 단계(잠금 ref·라벨 부착)가 스텁 부재로 죽어도 같은 "skip 없음" 이 되기 때문이다.
mkdir -p "$tmp/bin.claim"
cat > "$tmp/bin.claim/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"api user"*|*"api graphql"*) printf 'tester\n' ;;
  *"--json labels,state"*) printf '%s\n' "$STUB_PRE" ;;
  # 브랜치 미존재(신규 claim) → 앵커는 기본 브랜치 head
  *"git/ref/heads/agent/issue-"*) exit 1 ;;
  *"git/ref/heads/"*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
  *"git/refs"*) printf '{}\n' ;;
  *".default_branch"*) printf 'main\n' ;;
  *"issue edit"*) : ;;
  *"--json labels"*) printf '%s\n' "$STUB_POST" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin.claim/gh"

# ── gh 스텁 ③ PR 조회(closeout-eligible.sh · verify-eligible.sh 공용) ───────
# 코멘트는 실 gh 처럼 `--paginate` 갈래에서 전량을 준다(pr-comments.sh 계약).
mkdir -p "$tmp/bin.pr"
cat > "$tmp/bin.pr/gh" <<'STUB'
#!/usr/bin/env bash
paginate=0; jqf='.'; prev=''
for a in "$@"; do
  [ "$prev" = "--jq" ] && jqf="$a"
  [ "$a" = "--paginate" ] && paginate=1
  prev="$a"
done
if [ "$paginate" = 1 ]; then
  printf '%s' "$STUB_COMMENTS" \
    | jq -c '[.[] | {body: .body, created_at: .createdAt}]' | jq -c "$jqf"
  exit 0
fi
case "$*" in
  *"api user"*|*"api graphql"*) printf 'tester\n' ;;
  *"search/issues"*) printf '%s\n' "$STUB_PRS" ;;
  *"--json headRefName"*) printf '%s\n' "$STUB_META" ;;
  *"pr view"*"--json headRefOid"*) printf '{"headRefOid":"feed0070ab"}\n' ;;
  *"commits/"*) printf '{"commit":{"committer":{"date":"%s"}}}\n' "$STUB_HEAD_AT" ;;
  *"--json statusCheckRollup"*) printf '%s\n' "$STUB_ROLLUP" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin.pr/gh"

# ── SUT 러너 — 각각 후보로 남으면 `pass`, 게이트에 걸리면 `block` 을 낸다 ────
run_eligible() {
  local labels="$1" cands out n
  cands=$(jq -c -n --argjson l "$(names_json "$labels")" \
    '[{repository: {nameWithOwner: "owner/repo"}, number: 7, title: "t",
       labels: $l, createdAt: "2026-01-01T00:00:00Z"}]')
  out=$(cd "$cwd" && PATH="$tmp/bin.eligible:$PATH" STUB_CANDS="$cands" \
    bash "$DIR/eligible-issues.sh" 2>/dev/null)
  n=$(printf '%s' "$out" | jq 'length' 2>/dev/null)
  [ "${n:-0}" -ge 1 ] && printf 'pass\n' || printf 'block\n'
}

run_claim() {
  local labels="$1" pre post out
  pre=$(jq -c -n --argjson l "$(names_json "$labels")" '{labels: $l, state: "OPEN"}')
  post=$(jq -c -n --argjson l "$(names_json "$labels")" \
    '{labels: ($l + [{name: "agent:claimed"}])}')
  out=$(cd "$cwd" && PATH="$tmp/bin.claim:$PATH" CLAIM_STALE_WAIT=0 \
    STUB_PRE="$pre" STUB_POST="$post" \
    bash "$DIR/claim-issue.sh" owner/repo 7 2>/dev/null)
  case "$out" in
    *"claimed: owner/repo#7"*) printf 'pass\n' ;;
    *) printf 'block\n' ;;
  esac
}

# PR 러너 공용 meta — head 는 agent/issue-* (두 SUT 의 레인 판별을 통과시킨다)
pr_meta() {
  jq -c -n --argjson l "$(names_json "$1")" \
    '{headRefName: "agent/issue-7", mergeable: "MERGEABLE", labels: $l,
      closingIssuesReferences: [{number: 7}]}'
}

run_closeout() {
  local labels="$1" out n
  out=$(cd "$cwd" && PATH="$tmp/bin.pr:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS='[{"repo":"owner/repo","pr":5}]' STUB_META="$(pr_meta "$labels")" \
    STUB_COMMENTS="$CLOSEOUT_COMMENTS" STUB_HEAD_AT="2026-07-05T04:10:00Z" \
    STUB_ROLLUP="$ROLLUP" \
    bash "$DIR/closeout-eligible.sh" 2>/dev/null)
  n=$(printf '%s' "$out" | grep -c . || true)
  [ "$n" -ge 1 ] && printf 'pass\n' || printf 'block\n'
}

run_verify() {
  local labels="$1" out n
  out=$(cd "$cwd" && PATH="$tmp/bin.pr:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS='[{"repo":"owner/repo","pr":5}]' STUB_META="$(pr_meta "$labels")" \
    STUB_COMMENTS="$CLOSEOUT_COMMENTS" STUB_HEAD_AT="2026-07-05T04:10:00Z" \
    STUB_ROLLUP="$ROLLUP" \
    bash "$DIR/verify-eligible.sh" 2>/dev/null)
  n=$(printf '%s' "$out" | grep -c . || true)
  [ "$n" -ge 1 ] && printf 'pass\n' || printf 'block\n'
}

# ── 격자 한 벌 — `이름|추가라벨(JSON)|기대` ────────────────────────────────
# 기대 `pass` = 후보로 남는다 · `block` = 게이트가 제외한다.
grid=(
  '라벨 없음 → 통과(회귀)|[]|pass'
  'needs-human 단독 → 제외(회귀)|["needs-human"]|block'
  'hold:ladder 단독 → 제외(신규 · 3단계 선반영)|["hold:ladder"]|block'
  'hold:policy 단독 → 제외(신규)|["hold:policy"]|block'
  'hold:conflict 단독 → 제외(신규)|["hold:conflict"]|block'
  'hold:<미래사유> 단독 → 제외(접두 판별이라 사유가 늘어도 안 깨진다)|["hold:newreason"]|block'
  'needs-human + hold:ladder → 제외|["needs-human","hold:ladder"]|block'
  'holding → 통과(과잉 제외 금지)|["holding"]|pass'
  'on-hold → 통과(과잉 제외 금지)|["on-hold"]|pass'
  'area:hold → 통과(과잉 제외 금지)|["area:hold"]|pass'
  'hold-ladder(하이픈) → 통과(과잉 제외 금지)|["hold-ladder"]|pass'
  'holder:x → 통과(과잉 제외 금지)|["holder:x"]|pass'
  # 사유 없는 `hold:` 도 접두를 만족한다 — 두 구현(글롭·startswith)이 같은 답을 내는지.
  'hold:(사유 없음) → 제외|["hold:"]|block'
  # 대소문자는 **구분한다**(글롭도 startswith 도). 라벨을 만드는 건 setup-labels.sh 와
  # transition.sh 뿐이고 전부 소문자라 실물이 없지만, 손으로 `Hold:ladder` 를 붙여도
  # 게이트가 안 선다는 사실 자체를 여기 못박아 조용한 드리프트를 막는다.
  'Hold:ladder(대문자) → 통과(대소문자 구분 · 실물 라벨 아님)|["Hold:ladder"]|pass'
)

for sut in eligible claim closeout verify; do
  case "$sut" in
    # 이슈 두 자리는 `agent-ready` 가 서버 쿼리 조건 — 후보 형상에 실어 재현한다.
    eligible|claim) base='["agent-ready"]' ;;
    # closeout 은 `flow:verify` 가 붙어 있으면 verify-runner 소유라 제외된다 → 빈 기준선.
    closeout)       base='[]' ;;
    # verify 는 `flow:verify` 가 서버 쿼리 조건.
    verify)         base='["flow:verify"]' ;;
    *)              base='[]' ;;
  esac
  for row in "${grid[@]}"; do
    name=${row%%|*}
    rest=${row#*|}
    extra=${rest%%|*}
    want=${rest##*|}
    labels=$(merge_labels "$base" "$extra")
    got=$("run_$sut" "$labels")
    if [ "$got" = "$want" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "  ✗ [$sut] $name — 기대=$want 실제=$got labels=$labels"
    fi
  done
done

echo "hold-gate.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
