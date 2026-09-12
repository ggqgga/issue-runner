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
      *"label:verifying"*)
        [ "${STUB_FAIL_VERIFYING:-0}" = 1 ] && { echo "gh: HTTP 502" >&2; exit 1; }
        printf '%s\n' "${STUB_PRS_VERIFYING:-[]}" ;;
      *"label:flow:verify"*)
        [ "${STUB_FAIL_VERIFY:-0}" = 1 ] && { echo "gh: HTTP 502" >&2; exit 1; }
        printf '%s\n' "${STUB_PRS_VERIFY:-[]}" ;;
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

# stderr 는 $tmp/err 에 남긴다(검색 실패 보고 단언용). STUB_FAIL_* 로 갈래별 gh 실패를 재현한다.
run_sut() {
  (cd "$cwd" && PATH="$tmp/bin:$PATH" ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" \
    STUB_PRS_VERIFYING="$1" STUB_PRS_VERIFY="$2" STUB_META_DIR="$STUB_META_DIR" \
    STUB_ROLLUP="$ROLLUP" STUB_CAPTURE="${STUB_CAPTURE:-}" \
    STUB_FAIL_VERIFYING="${STUB_FAIL_VERIFYING:-0}" STUB_FAIL_VERIFY="${STUB_FAIL_VERIFY:-0}" \
    bash "$SUT" 2>"$tmp/err")
}

reset() { rm -rf "$tmp/meta"; mkdir -p "$tmp/meta"; STUB_META_DIR="$tmp/meta"; }
prs_of()    { printf '%s\n' "$1" | jq -r '.pr' | tr '\n' ' ' | sed 's/ *$//'; }
orphan_of() { printf '%s\n' "$1" | jq -r 'select(.pr == '"$2"') | .orphan'; }

# ── 1) verifying 우선 + orphan:true ─────────────────────────────────────────
# search 순서상 flow:verify PR(#3, 더 오래됨)이 먼저 만들어졌어도 verifying PR(#5)이 앞이다.
reset
meta 3 103 '["flow:verify"]'
meta 5 105 '["verifying"]'
STUB_CAPTURE="$tmp/capture"; : > "$STUB_CAPTURE"
out=$(run_sut '[{"repo":"owner/repo","pr":5}]' '[{"repo":"owner/repo","pr":3}]')
ck "verifying 우선: 순서 = 5 3" "$(prs_of "$out")" "5 3"
# search 는 두 갈래를 **각각** 부른다(라벨 OR 한 쿼리가 아니다) — verifying 갈래가 먼저.
v_line=$(grep -n -- 'label:verifying' "$STUB_CAPTURE" | head -1 | cut -d: -f1)
f_line=$(grep -n -- 'label:flow:verify' "$STUB_CAPTURE" | head -1 | cut -d: -f1)
ck "verifying 우선: search 두 갈래 각각 1회" "$(grep -c 'search/issues' "$STUB_CAPTURE")" 2
check "verifying 우선: verifying 갈래 search 가 먼저" \
  "$([ -n "$v_line" ] && [ -n "$f_line" ] && [ "$v_line" -lt "$f_line" ] && echo ok || echo no)"
STUB_CAPTURE=""
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

# ── 5-b) 갈래 경계에서도 FIFO — 검증대기 줄은 search 갈래가 아니라 created 순 ─────
# verifying 갈래로 왔지만 meta 가 flow:verify 뿐인 PR(unpick 직후·인덱스 지연)은 검증대기
# 줄로 가되, 더 오래된 flow:verify PR 보다 **뒤**여야 한다(갈래 순서가 FIFO 를 깨지 않는다).
reset
meta 61 161 '["flow:verify"]'
meta 62 162 '["flow:verify"]'
out=$(run_sut '[{"repo":"owner/repo","pr":61,"created":"2026-02-01T00:00:00Z"}]' \
              '[{"repo":"owner/repo","pr":62,"created":"2026-01-01T00:00:00Z"}]')
ck "갈래 경계 FIFO: 순서 = 62 61" "$(prs_of "$out")" "62 61"
ck "갈래 경계 FIFO: 전부 orphan:false" "$(printf '%s\n' "$out" | jq -r '.orphan' | sort -u)" "false"

# ── 5-c) meta 에 verifying 도 flow:verify 도 없으면 후보 아님(라벨 = SSOT) ──────────
# verify-pass 직후 search 인덱스에만 남은 PR(meta 는 flow:ready) — 이미 이 루프 소유가
# 아니다. search 결과만 믿고 내보내면 closeout 대기 PR 을 다시 검증한다.
reset
meta 71 171 '["flow:ready"]'
meta 72 172 '[]'
meta 73 173 '["flow:verify"]'
out=$(run_sut '[{"repo":"owner/repo","pr":72}]' '[{"repo":"owner/repo","pr":71},{"repo":"owner/repo","pr":73}]')
ck "소유 라벨 없음: 순서 = 73 만" "$(prs_of "$out")" "73"

# ── 5-d) 한 갈래 search 실패 → 후보 0 + stderr 한 줄(fail-closed) ─────────────────
# verifying 갈래만 실패하면 고아를 조용히 건너뛰고 flow:verify FIFO 를 내는 것이 최악이다
# ("verifying 먼저" 가 그 틱에 깨지는데 흔적이 없다). 실패는 빈 결과(`[]`)와 구분한다.
reset
meta 81 181 '["verifying"]'
meta 82 182 '["flow:verify"]'
out=$(STUB_FAIL_VERIFYING=1 run_sut '[{"repo":"owner/repo","pr":81}]' '[{"repo":"owner/repo","pr":82}]'); rc=$?
ck "verifying 갈래 실패: exit 0" "$rc" 0
ck "verifying 갈래 실패: 후보 0" "$(printf '%s' "$out" | grep -c . || true)" 0
check "verifying 갈래 실패: stderr 에 검색 실패 한 줄" \
  "$(grep -q 'search(verifying) 실패' "$tmp/err" && echo ok || echo no)"
out=$(STUB_FAIL_VERIFY=1 run_sut '[{"repo":"owner/repo","pr":81}]' '[{"repo":"owner/repo","pr":82}]'); rc=$?
ck "flow:verify 갈래 실패: exit 0" "$rc" 0
ck "flow:verify 갈래 실패: 후보 0" "$(printf '%s' "$out" | grep -c . || true)" 0
check "flow:verify 갈래 실패: stderr 에 검색 실패 한 줄" \
  "$(grep -q 'search(flow:verify) 실패' "$tmp/err" && echo ok || echo no)"
# 빈 결과는 실패가 아니다 — 두 갈래 다 `[]` 면 stderr 도 비어 있어야 한다(아래 6 과 짝).

# ── 6) 후보 0 → 출력 없음, exit 0 ────────────────────────────────────────────
reset
out=$(run_sut '[]' '[]'); rc=$?
ck "후보 0: exit 0" "$rc" 0
ck "후보 0: 출력 없음" "$(printf '%s' "$out" | grep -c . || true)" 0
ck "후보 0: stderr 없음(빈 결과 ≠ 실패)" "$(grep -c . "$tmp/err" || true)" 0

echo "verify-eligible.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
