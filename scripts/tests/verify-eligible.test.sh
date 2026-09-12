#!/usr/bin/env bash
# verify-eligible.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# #275: verify-runner 점유 라벨 `verifying` 의 큐 규칙을 문다.
#   1) `verifying` PR(이전 틱이 못 끝낸 고아)은 **먼저** 나오고 그 줄에 `orphan:true`.
#   2) `flow:verify` PR 은 그 뒤에 FIFO(search 가 준 순서 = created asc)로, `orphan:false`.
#   3) `harvesting` 제외 규칙은 그대로(closeout 소유).
# 스텁은 search 호출을 **두 갈래**(label:verifying · label:flow:verify)로 다르게 응답한다 —
# 한 쿼리로 합치는 뮤테이션은 두 갈래를 구분 못 해 순서 단언에서 갈린다. 한 PR 이 두
# 쿼리에 다 잡히는 형상(인덱스 지연·부분 전이)도 넣어 중복 출력이 없는지 본다.
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/verify-eligible.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() {
  if [ "$2" = "ok" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; fi
}
ck() { check "$1" "$([ "$2" = "$3" ] && echo ok || echo no)"; }

# 작업 cwd — $PWD/.loop/repos 부재라 in_scope 는 전 레포 허용(fail-open, 실증 전제)
cwd="$tmp/cwd"
mkdir -p "$cwd"
# repo-dir.sh 해석 대상 — bin/ci 없는 레포(closeout-ci-pass 의 GitHub rollup 폴백 고정)
mkdir -p "$tmp/proj/repo"
ROLLUP='{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'

# ── gh 스텁 ────────────────────────────────────────────────────────────────
# search: 쿼리 문자열의 label: 로 갈래를 가른다. STUB_PRS_VERIFYING / STUB_PRS_VERIFY 가
# 각 갈래의 응답(JSON 배열 [{repo,pr}])이다. 그 밖의 search 는 **실패**(알 수 없는 쿼리 —
# 두 라벨을 한 쿼리로 합치면 여기서 빈 결과가 나와 단언이 갈린다).
# pr view: PR 번호별 meta — $STUB_META_DIR/<pr>.json.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_CAPTURE:-}" ] && printf '%s\n' "$*" >> "$STUB_CAPTURE"
case "$*" in
  *"api user"*) printf 'tester\n' ;;
  *"search/issues"*)
    q=""
    prev=""
    for a in "$@"; do
      case "$prev" in -f) case "$a" in q=*) q=${a#q=} ;; esac ;; esac
      prev="$a"
    done
    case "$q" in
      *"label:verifying"*"label:flow:verify"*|*"label:flow:verify"*"label:verifying"*) exit 1 ;;
      *"label:verifying"*)   printf '%s\n' "${STUB_PRS_VERIFYING:-[]}" ;;
      *"label:flow:verify"*) printf '%s\n' "${STUB_PRS_VERIFY:-[]}" ;;
      *) exit 1 ;;
    esac ;;
  "pr view "*"--json headRefName"*)
    shift 2; n=$1
    [ -f "$STUB_META_DIR/$n.json" ] || exit 1
    cat "$STUB_META_DIR/$n.json" ;;
  *"--json statusCheckRollup"*) printf '%s\n' "$STUB_ROLLUP" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# meta <pr> <issue> <labels-json-array-of-strings>
meta() {
  jq -c -n --arg pr "$1" --arg issue "$2" --argjson l "$3" \
    '{headRefName: ("agent/issue-" + $issue), mergeable: "MERGEABLE",
      labels: [$l[] | {name: .}], closingIssuesReferences: [{number: ($issue|tonumber)}]}' \
    > "$STUB_META_DIR/$1.json"
}

run_sut() {
  (cd "$cwd" && PATH="$tmp/bin:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS_VERIFYING="$1" STUB_PRS_VERIFY="$2" STUB_META_DIR="$STUB_META_DIR" \
    STUB_ROLLUP="$ROLLUP" STUB_CAPTURE="${STUB_CAPTURE:-}" \
    bash "$SUT" 2>/dev/null)
}

reset() { rm -rf "$tmp/meta"; mkdir -p "$tmp/meta"; STUB_META_DIR="$tmp/meta"; }
prs_of()    { printf '%s\n' "$1" | jq -r '.pr' | tr '\n' ' ' | sed 's/ *$//'; }
orphan_of() { printf '%s\n' "$1" | jq -r 'select(.pr == '"$2"') | .orphan'; }

# ── 1) verifying 우선 + orphan:true ─────────────────────────────────────────
# search 순서상 flow:verify PR(#3, 더 오래됨)이 먼저 만들어졌어도 verifying PR(#5)이 앞이다.
reset
meta 3 103 '["flow:verify"]'
meta 5 105 '["verifying"]'
out=$(run_sut '[{"repo":"owner/repo","pr":5}]' '[{"repo":"owner/repo","pr":3}]')
ck "verifying 우선: 순서 = 5 3" "$(prs_of "$out")" "5 3"
ck "verifying 우선: #5 orphan:true"  "$(orphan_of "$out" 5)" "true"
ck "verifying 우선: #3 orphan:false" "$(orphan_of "$out" 3)" "false"
check "verifying 우선: 필드 형상(repo·pr·issue·head·ci·orphan)" \
  "$(printf '%s\n' "$out" | jq -e 'select(.pr==5) | has("repo") and has("pr") and has("issue") and has("head") and has("ci") and has("orphan")' >/dev/null 2>&1 && echo ok || echo no)"
ck "verifying 우선: ci 필드 유지(pass)" "$(printf '%s\n' "$out" | jq -r 'select(.pr==5)|.ci')" "pass"

# ── 2) flow:verify FIFO — search 가 준 순서(created asc)를 그대로 ─────────────
reset
meta 11 111 '["flow:verify"]'
meta 12 112 '["flow:verify"]'
meta 13 113 '["flow:verify"]'
out=$(run_sut '[]' '[{"repo":"owner/repo","pr":11},{"repo":"owner/repo","pr":12},{"repo":"owner/repo","pr":13}]')
ck "FIFO: 순서 = 11 12 13" "$(prs_of "$out")" "11 12 13"
ck "FIFO: 전부 orphan:false" "$(printf '%s\n' "$out" | jq -r '.orphan' | sort -u)" "false"
# verifying 여러 건도 자기 갈래 안에서는 FIFO, 그리고 전부 flow:verify 앞.
reset
meta 21 121 '["verifying"]'
meta 22 122 '["verifying"]'
meta 23 123 '["flow:verify"]'
out=$(run_sut '[{"repo":"owner/repo","pr":21},{"repo":"owner/repo","pr":22}]' '[{"repo":"owner/repo","pr":23}]')
ck "두 갈래 FIFO: 순서 = 21 22 23" "$(prs_of "$out")" "21 22 23"

# ── 3) harvesting 제외는 그대로(closeout 소유) — 두 갈래 모두 ─────────────────
reset
meta 31 131 '["flow:verify","harvesting"]'
meta 32 132 '["verifying","harvesting"]'
meta 33 133 '["flow:verify"]'
out=$(run_sut '[{"repo":"owner/repo","pr":32}]' '[{"repo":"owner/repo","pr":31},{"repo":"owner/repo","pr":33}]')
ck "harvesting 제외: 순서 = 33 만" "$(prs_of "$out")" "33"

# ── 4) 한 PR 이 두 쿼리에 다 잡혀도(인덱스 지연·부분 전이) 한 줄만, 앞자리에 ───────
reset
meta 41 141 '["verifying","flow:verify"]'
meta 42 142 '["flow:verify"]'
out=$(run_sut '[{"repo":"owner/repo","pr":41}]' '[{"repo":"owner/repo","pr":41},{"repo":"owner/repo","pr":42}]')
ck "중복 없음: 순서 = 41 42" "$(prs_of "$out")" "41 42"
ck "중복 없음: #41 orphan:true" "$(orphan_of "$out" 41)" "true"

# ── 5) orphan 은 search 갈래가 아니라 **현재 라벨**(meta)로 판정 ───────────────
# search 인덱스가 늦어 flow:verify 갈래로 돌아온 PR 에 실제로는 verifying 이 붙어 있으면
# (unpick 직전 창) 고아로 취급해 앞자리 + orphan:true — 라벨이 진실이다(GitHub = SSOT).
reset
meta 51 151 '["verifying"]'
meta 52 152 '["flow:verify"]'
out=$(run_sut '[]' '[{"repo":"owner/repo","pr":52},{"repo":"owner/repo","pr":51}]')
ck "라벨 기준 판정: 순서 = 51 52" "$(prs_of "$out")" "51 52"
ck "라벨 기준 판정: #51 orphan:true" "$(orphan_of "$out" 51)" "true"

# ── 6) 후보 0 → 출력 없음, exit 0 ────────────────────────────────────────────
reset
out=$(run_sut '[]' '[]'); rc=$?
ck "후보 0: exit 0" "$rc" 0
ck "후보 0: 출력 없음" "$(printf '%s' "$out" | grep -c . || true)" 0

echo "verify-eligible.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
