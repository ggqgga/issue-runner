#!/usr/bin/env bash
# pr-head-at.sh 격자 테스트 (#428) — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# 무는 계약: PR head 커밋 시각을 **커밋 목록 상한과 무관한 경로**(headRefOid → 그 커밋 조회)
# 로 얻고, 단계마다 종료코드와 빈 값을 따로 검사해 **하나라도 못 얻으면 exit 1·무출력**
# (호출자는 fail-closed). `--with-sha` 는 같은 조회로 SHA 를 함께 낸다.
# 이 헬퍼를 직접 exec 하는 소비자: scripts/finish-classify.sh · scripts/closeout-eligible.sh ·
# scripts/closeout-step1-marker.sh.
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/pr-head-at.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

REPO=fixture-owner/fixture-428
PR=5
SHA=feed0070abcdef1234567890abcdef1234567890
AT=2026-09-13T11:20:00Z

# gh 스텁 — 두 조회를 따로 응답한다(FAIL=비0 · EMPTY=빈 출력 · 그 외=그 문자열).
# 그 밖의 호출(예: 옛 경로 `--json commits`)은 exit 1 로 시끄럽게 실패한다.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_ARGS:-/dev/null}"
emit() {
  case "$1" in
    FAIL)  echo "gh: could not connect" >&2; exit 1 ;;
    EMPTY) exit 0 ;;
    *) printf '%s\n' "$1" ;;
  esac
}
case "$*" in
  *"--json headRefOid"*) emit "${STUB_PRVIEW:-FAIL}" ;;
  *"/commits/"*)         emit "${STUB_COMMIT:-FAIL}" ;;
  *) echo "예상 못한 gh 호출: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

pass=0
fail=0
OUT=""
RC=0

check() {  # check <이름> <기대 stdout> <기대 exit>
  if [ "$OUT" = "$2" ] && [ "$RC" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $1 — 기대=[$2](exit $3) 실제=[$OUT](exit $RC)"
  fi
}

run_case() {  # run_case <이름> <기대> <기대exit> <prview 응답> <commit 응답> [--with-sha]
  local name="$1" expect="$2" erc="$3" prview="$4" commit="$5" flag="${6:-}"
  : > "$TMP/gh.args"
  if [ -n "$flag" ]; then
    OUT=$(PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" STUB_PRVIEW="$prview" \
      STUB_COMMIT="$commit" bash "$SUT" "$flag" "$REPO" "$PR" 2>/dev/null); RC=$?
  else
    OUT=$(PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" STUB_PRVIEW="$prview" \
      STUB_COMMIT="$commit" bash "$SUT" "$REPO" "$PR" 2>/dev/null); RC=$?
  fi
  check "$name" "$expect" "$erc"
}

OK_PRVIEW="{\"headRefOid\":\"$SHA\"}"
OK_COMMIT="{\"commit\":{\"committer\":{\"date\":\"$AT\"}}}"

# ── 정상 ────────────────────────────────────────────────────────────────
run_case "head 시각 한 줄" "$AT" 0 "$OK_PRVIEW" "$OK_COMMIT"
run_case "--with-sha → SHA 와 시각 두 필드" "$SHA $AT" 0 "$OK_PRVIEW" "$OK_COMMIT" --with-sha

# 커밋 목록 상한(GraphQL commits(first:100))을 타지 않는다 — 물어보는 것은 headRefOid 와
# **그 커밋 하나**뿐이다. 옛 경로(`--json commits`)로 되돌리면 스텁이 exit 1 로 터진다.
if grep -qF -- "pr view $PR --repo $REPO --json headRefOid" "$TMP/gh.args" \
  && grep -qF -- "api repos/$REPO/commits/$SHA" "$TMP/gh.args" \
  && ! grep -qF -- "--json commits" "$TMP/gh.args"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  ✗ 조회 경로 — 기대=[headRefOid + commits/<sha>] 실제=[$(cat "$TMP/gh.args")]"
fi

# ── 1단계(head SHA) 실패 갈래 ───────────────────────────────────────────
run_case "pr view 비0 → 실패" "" 1 FAIL "$OK_COMMIT"
run_case "pr view 빈 응답 → 실패" "" 1 EMPTY "$OK_COMMIT"
run_case "headRefOid 가 null → 실패" "" 1 '{"headRefOid":null}' "$OK_COMMIT"
run_case "pr view 가 JSON 이 아님 → 실패" "" 1 'not-json{' "$OK_COMMIT"

# 형태 검사 — 16진수가 아닌 값이 그럴듯한 API 경로를 만들지 못하게 **입구에서** 막는다.
run_case "headRefOid 가 16진수가 아님 → 실패" "" 1 '{"headRefOid":"refs/heads/agent/issue-428"}' "$OK_COMMIT"
if grep -qF -- "/commits/" "$TMP/gh.args"; then
  fail=$((fail + 1)); echo "  ✗ 비16진수 SHA 로 커밋 조회를 했다: [$(cat "$TMP/gh.args")]"
else
  pass=$((pass + 1))
fi

# ── 2단계(커밋 조회) 실패 갈래 ──────────────────────────────────────────
run_case "커밋 조회 비0 → 실패" "" 1 "$OK_PRVIEW" FAIL
run_case "커밋 조회 빈 응답 → 실패" "" 1 "$OK_PRVIEW" EMPTY
run_case "커밋 JSON 에 committer.date 없음 → 실패" "" 1 "$OK_PRVIEW" '{"commit":{"committer":{}}}'
# 실패는 --with-sha 여도 **아무것도 내지 않는다**(부분 출력으로 새지 않는다).
run_case "--with-sha 여도 실패면 무출력" "" 1 "$OK_PRVIEW" FAIL --with-sha

# ── 인자 누락 — 머리 주석엔 없는 갈래다(현재 동작을 못 박는다) ──────────
OUT=$(PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" bash "$SUT" "$REPO" 2>/dev/null); RC=$?
check "PR 번호 누락 → 비0 종료(무출력)" "" 1

echo "pr-head-at.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
