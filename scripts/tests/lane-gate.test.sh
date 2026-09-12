#!/usr/bin/env bash
# lane-gate.test.sh — verify·closeout 두 후보 게이트가 PR 의 **레인**을 head 이름
# (`agent/issue-*`) 과 `full-cycle` 라벨 **두 축**으로 같은 정의로 가르는지, 하나의 격자를
# 두 SUT 에 전수 적용해 단언한다 (#246, 플랜 5단계).
#
#   SUT: closeout-eligible.sh · verify-eligible.sh
#
# 규칙(두 SUT 공통): 후보 = head 가 `agent/issue-*` **이고** `full-cycle` 라벨이 **없다**.
#   · head 필터는 지우지 않는다 — 라벨이 아직 없는 옛 PR 들이 있다(라벨은 보강이지 대체가 아니다).
#   · `full-cycle` 은 **명시적 제외 축**이다 — head 가 무엇이든 붙어 있으면 "루프 소유 아님".
#     OR 로 넓히는 게 아니다: 라벨이 없다고 head 필터를 우회하지 않는다.
#
# 가장 위험한 실패는 '더 많이 제외하는' 방향이다(정상 후보 소실 — 조용한 큐 사망).
# 그래서 `full-cycle` 과 **정확히 같지 않은** 라벨(`full-cycle-legacy`·`x:full-cycle`)을 넣어
# 통과를 함께 못박는다 — 판별은 배열 원소의 완전 일치(index)지 부분 문자열이 아니다.
#
# 스텁·러너 형상은 hold-gate.test.sh 의 PR 갈래와 같다(같은 게이트를 다른 축으로 본다).
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

cwd="$tmp/cwd"
mkdir -p "$cwd"
mkdir -p "$tmp/proj/repo"

ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
CLOSEOUT_COMMENTS='[
  {"body":"머지 판정: ✅ 머지 가능\n<!-- bodat:worker -->","createdAt":"2026-07-05T04:20:00Z"}
]'

names_json() { jq -c -n --argjson l "$1" '[$l[] | {name: .}]'; }
merge_labels() { jq -c -n --argjson a "$1" --argjson b "$2" '$a + $b'; }

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

# pr_meta <head> <labels-json> — 격자의 두 축을 meta 에 싣는다.
pr_meta() {
  jq -c -n --arg h "$1" --argjson l "$(names_json "$2")" \
    '{headRefName: $h, mergeable: "MERGEABLE", labels: $l,
      closingIssuesReferences: [{number: 7}]}'
}

# run_sut <script> <head> <labels-json> — 후보로 남으면 `pass`, 게이트에 걸리면 `block`.
run_sut() {
  local script="$1" head="$2" labels="$3" out n
  out=$(cd "$cwd" && PATH="$tmp/bin.pr:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS='[{"repo":"owner/repo","pr":5}]' STUB_META="$(pr_meta "$head" "$labels")" \
    STUB_COMMENTS="$CLOSEOUT_COMMENTS" STUB_HEAD_AT="2026-07-05T04:10:00Z" \
    STUB_ROLLUP="$ROLLUP" \
    bash "$DIR/$script" 2>/dev/null)
  n=$(printf '%s' "$out" | grep -c . || true)
  [ "$n" -ge 1 ] && printf 'pass\n' || printf 'block\n'
}

# ── 격자 한 벌 — `이름|head|추가라벨(JSON)|기대` ────────────────────────────
grid=(
  # 수용 기준 3건
  'agent 헤드 + full-cycle → 제외(신규 — 라벨이 명시적 제외 축)|agent/issue-7|["full-cycle"]|block'
  'agent 헤드 + 라벨 없음 → 통과(회귀 — 옛 PR 은 라벨이 없다)|agent/issue-7|[]|pass'
  '사람 헤드 + 라벨 없음 → 제외(회귀 — head 필터는 유지)|feat/x|[]|block'
  # 경계
  '사람 헤드 + full-cycle → 제외(두 축 모두 루프 소유 아님)|feat/x|["full-cycle"]|block'
  'agent 헤드 + full-cycle-legacy → 통과(완전 일치 — 과잉 제외 금지)|agent/issue-7|["full-cycle-legacy"]|pass'
  'agent 헤드 + x:full-cycle → 통과(완전 일치 — 과잉 제외 금지)|agent/issue-7|["x:full-cycle"]|pass'
  'agent 헤드 + Full-Cycle(대문자) → 통과(대소문자 구분 · 실물 라벨 아님)|agent/issue-7|["Full-Cycle"]|pass'
  'agent 헤드 + full-cycle 이 다른 라벨 사이에 → 제외(위치 무관)|agent/issue-7|["enhancement","full-cycle","P1"]|block'
)

for sut in closeout verify; do
  case "$sut" in
    closeout) script='closeout-eligible.sh'; base='[]' ;;
    verify)   script='verify-eligible.sh';   base='["flow:verify"]' ;;
  esac
  for row in "${grid[@]}"; do
    name=${row%%|*}
    rest=${row#*|}
    head=${rest%%|*}
    rest=${rest#*|}
    extra=${rest%%|*}
    want=${rest##*|}
    labels=$(merge_labels "$base" "$extra")
    got=$(run_sut "$script" "$head" "$labels")
    if [ "$got" = "$want" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "  ✗ [$sut] $name — 기대=$want 실제=$got head=$head labels=$labels"
    fi
  done
done

echo "lane-gate.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
