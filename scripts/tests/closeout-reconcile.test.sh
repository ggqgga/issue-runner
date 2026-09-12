#!/usr/bin/env bash
# closeout-reconcile.sh 격자 테스트 (#428) — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
# 무는 계약: `harvesting` 붙은 PR 을 상태별로 처리해 **이벤트 JSON lines** 를 내는 틱
# 스크립트(closeout ① Reconcile 이 부른다 — 헬퍼가 아니라 단계 본체다).
#   MERGED → harvesting 제거 + worktree 정리(best-effort) + merged_cleanup
#   OPEN   → needs-human 있으면 human_hold, 없으면 resume, **못 읽으면 human_hold**(fail-closed)
#   그 외  → harvesting 제거 + stale
# 앞단 조회(로그인·검색)가 실패하면 아무것도 하지 않고 조용히 끝난다(무접촉).
# 레포 해석은 픽스처 안에 가둔다(ISSUE_RUNNER_REPOS_CONF·ISSUE_RUNNER_PROJECTS_ROOT) —
# worktree 정리가 머신의 진짜 경로를 건드리면 안 된다.
# bats 미도입 레포라 closeout-eligible.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/closeout-reconcile.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/cwd" "$TMP/proj/fixture-428"
: > "$TMP/repos.conf"

REPO=fixture-owner/fixture-428
PR=5

# gh 스텁 — 검색은 실 gh 가 `-q` 로 걸러 낸 **결과 배열**을 그대로 돌려준다(필터 자체는
# 이 테스트의 대상이 아니다). PR 상태·브랜치는 번호별 맵 파일(`<번호> <상태> <브랜치>`)에서
# 찾고, 없으면 STUB_STATE/STUB_BRANCH 기본값을 쓴다. FAIL 은 조회 실패(비0)다.
# 그 밖의 호출은 exit 1 — 의도치 않은 네트워크 경로가 조용히 통과하지 않게.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_ARGS:-/dev/null}"
lookup() {  # lookup <번호> <필드번호> <기본값>
  local v=""
  [ -n "${STUB_MAP:-}" ] && [ -f "$STUB_MAP" ] \
    && v=$(awk -v n="$1" -v f="$2" '$1==n {print $f; exit}' "$STUB_MAP")
  [ -n "$v" ] || v="$3"
  [ "$v" = FAIL ] && { echo "gh: could not connect" >&2; exit 1; }
  [ "$v" = EMPTY ] && exit 0
  printf '%s\n' "$v"
}
case "$*" in
  "api user"*)
    [ "${STUB_ME:-tester}" = FAIL ] && { echo "gh: bad credentials" >&2; exit 1; }
    printf '%s\n' "${STUB_ME:-tester}" ;;
  *"search/issues"*)
    [ "${STUB_ITEMS:-}" = FAIL ] && { echo "gh: could not connect" >&2; exit 1; }
    printf '%s' "${STUB_ITEMS:-}" ;;
  *"--json state"*)      lookup "$3" 2 "${STUB_STATE:-OPEN}" ;;
  *"--json headRefName"*) lookup "$3" 3 "${STUB_BRANCH:-session/manual-428}" ;;
  *"issue edit"*) exit 0 ;;
  *) echo "예상 못한 gh 호출: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

pass=0
fail=0
STUB_ME=tester
STUB_ITEMS=""
STUB_STATE=OPEN
STUB_BRANCH=session/manual-428
STUB_MAP=""

run_case() {  # run_case <이름> <기대 stdout 전체>
  local name="$1" expect="$2" got rc
  : > "$TMP/gh.args"
  got=$(cd "$TMP/cwd" && PATH="$TMP/bin:$PATH" GH_ARGS="$TMP/gh.args" \
    ISSUE_RUNNER_REPOS_CONF="$TMP/repos.conf" ISSUE_RUNNER_PROJECTS_ROOT="$TMP/proj" \
    STUB_ME="$STUB_ME" STUB_ITEMS="$STUB_ITEMS" STUB_STATE="$STUB_STATE" \
    STUB_BRANCH="$STUB_BRANCH" STUB_MAP="$STUB_MAP" \
    bash "$SUT" 2>/dev/null); rc=$?
  if [ "$got" = "$expect" ] && [ "$rc" = 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=[$expect] 실제=[$got](exit $rc)"
  fi
}

assert_args() {  # assert_args <이름> <있어야|없어야> <문자열>
  if grep -qF -- "$3" "$TMP/gh.args"; then
    [ "$2" = 있어야 ] && { pass=$((pass + 1)); return; }
  else
    [ "$2" = 없어야 ] && { pass=$((pass + 1)); return; }
  fi
  fail=$((fail + 1)); echo "  ✗ $1 — [$3] 가 $2 하는데 호출 로그=[$(tr '\n' '|' < "$TMP/gh.args")]"
}

row() {  # row <hh JSON 조각> → 검색 결과 한 건
  printf '[{"repo":"%s","num":%s%s}]' "$REPO" "$PR" "$1"
}

# ── 앞단 조회 실패 — 아무것도 하지 않는다 ───────────────────────────────
STUB_ITEMS=$(row ',"hh":"false"')
STUB_ME=FAIL
run_case "로그인 조회 실패 → 무접촉" ""
assert_args "로그인 실패" 없어야 "search/issues"
STUB_ME=tester

STUB_ITEMS=FAIL
run_case "검색 조회 실패 → 무접촉" ""
STUB_ITEMS=""
run_case "검색 결과 없음 → 무접촉" ""

# ── OPEN — needs-human 게이트(fail-closed) ──────────────────────────────
STUB_ITEMS=$(row ',"hh":"false"')
run_case "OPEN·needs-human 없음 → 재개" \
  '{"event":"resume","repo":"fixture-owner/fixture-428","pr":5}'
# 재개 갈래는 `harvesting` 을 **떼지 않는다** — 레인 밖으로 새면 다음 틱에 못 돌아온다.
assert_args "재개" 없어야 "issue edit"

STUB_ITEMS=$(row ',"hh":"true"')
run_case "OPEN·needs-human 있음 → 사람 보류" \
  '{"event":"human_hold","repo":"fixture-owner/fixture-428","pr":5,"why":"needs-human"}'

# 문자열 "false" 와 **불리언** false 두 형상을 모두 재개로 읽어야 한다 — `.hh // "unknown"`
# 관용구를 쓰면 불리언 false 가 unknown 으로 둔갑해 레인이 통째로 멈춘다.
STUB_ITEMS=$(row ',"hh":false')
run_case "hh 가 불리언 false → 재개(// 함정)" \
  '{"event":"resume","repo":"fixture-owner/fixture-428","pr":5}'

# 라벨을 **못 읽은 것**은 "보류 없음" 이 아니다 — 증명 못 한 상태를 통과시키면 fail-open 이다.
STUB_ITEMS=$(row '')
run_case "hh 필드 부재 → 판정 실패는 보류로" \
  '{"event":"human_hold","repo":"fixture-owner/fixture-428","pr":5,"why":"라벨 판정 실패"}'

# ── MERGED — 라벨 제거 + worktree 정리(best-effort) ─────────────────────
STUB_ITEMS=$(row ',"hh":"false"')
STUB_STATE=MERGED
run_case "MERGED·head 가 agent/issue-* 아님 → worktree 정리 건너뜀" \
  '{"event":"merged_cleanup","repo":"fixture-owner/fixture-428","pr":5}'
assert_args "MERGED" 있어야 "issue edit $PR --repo $REPO --remove-label harvesting"

# worktree 키는 **PR head 에서 파싱**한다 — head 가 `agent/issue-77` 이면 그 워크트리를
# 정리한다. 더티 픽스처를 심어 헬퍼가 실제로 불렸음을 warn 줄로 관측한다(그래도 best-effort
# 라 merged_cleanup 은 그대로 난다).
WT="$TMP/proj/fixture-428/.claude/worktrees/issue-77"
mkdir -p "$WT"
git -C "$WT" init -q 2>/dev/null
printf 'dirty\n' > "$WT/uncommitted.txt"
STUB_BRANCH=agent/issue-77
run_case "MERGED·head 가 agent/issue-77 → 그 worktree 를 정리(더티라 보류 warn)" \
  '{"event":"warn","repo":"fixture-owner/fixture-428","number":77,"msg":"worktree dirty — 제거 보류"}
{"event":"merged_cleanup","repo":"fixture-owner/fixture-428","pr":5}'
STUB_BRANCH=session/manual-428

# ── 그 외 상태 ──────────────────────────────────────────────────────────
STUB_STATE=CLOSED
run_case "CLOSED → 라벨 제거 + stale" \
  '{"event":"stale","repo":"fixture-owner/fixture-428","pr":5}'
assert_args "CLOSED" 있어야 "issue edit $PR --repo $REPO --remove-label harvesting"

# 상태 **조회 실패**(gh 실패 → 빈 값)는 CLOSED 가 아니다(#433): 라벨을 떼지 않고
# `lookup_failed` 만 낸다(fail-closed — 위 `hh` 라벨 판정 실패와 같은 방향). 뮤테이션:
# `'')` 갈래를 지우면 `그 외` 로 떨어져 `harvesting` 제거 호출이 생겨 아래 없어야 가 빨개진다.
STUB_STATE=FAIL
run_case "상태 조회 실패 → lookup_failed, 라벨 무접촉" \
  '{"event":"lookup_failed","repo":"fixture-owner/fixture-428","pr":5}'
assert_args "상태 조회 실패" 없어야 "issue edit $PR --repo $REPO --remove-label harvesting"
STUB_STATE=OPEN

# ── 범위 필터 — .loop/repos 가 있으면 거기 적힌 레포만 ──────────────────
mkdir -p "$TMP/cwd/.loop"
cat > "$TMP/cwd/.loop/repos" <<EOF
# 주석 줄과 빈 줄은 무시된다

$REPO
EOF
printf '%s %s %s\n' "$PR" OPEN "$STUB_BRANCH" > "$TMP/map"
printf '%s %s %s\n' 9 MERGED "$STUB_BRANCH" >> "$TMP/map"
STUB_MAP="$TMP/map"
STUB_ITEMS="[{\"repo\":\"$REPO\",\"num\":$PR,\"hh\":\"false\"},{\"repo\":\"other-owner/other-repo\",\"num\":9,\"hh\":\"false\"}]"
run_case "범위 밖 레포는 건드리지 않는다(범위 안 것만 처리)" \
  '{"event":"resume","repo":"fixture-owner/fixture-428","pr":5}'
assert_args "범위 밖" 없어야 "other-owner/other-repo"
rm -rf "$TMP/cwd/.loop"
STUB_MAP=""

echo "closeout-reconcile.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
