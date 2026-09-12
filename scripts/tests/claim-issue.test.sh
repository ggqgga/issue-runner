#!/usr/bin/env bash
# claim-issue.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# #281: claim 이 이슈에 `agent:claimed` 를 붙이는 그 자리에서 같은 레포의 열린
# `agent/issue-<N>` PR 에 issue-runner 칸을 미러(`flow:claimed` 부착·`flow:agent-ready` 제거)한다.
# 미러는 best-effort — PR 이 없으면 무동작, PR 편집 실패는 claim 을 되돌리지 않고 stderr 한 줄.
# (잠금·경합·스테일 인수는 bin/ci 의 #108 스모크가 문다 — 여기서는 미러만 본다.)
# bats 미도입 레포라 transition.test.sh 와 같은 순수 bash assert + 상태 있는 스텁 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/claim-issue.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# SUT 는 sibling 경로로 gh-login.sh 를 부른다 — SUT 사본과 가짜를 tmp 에 나란히 둔다.
cp "$SUT" "$tmp/claim-issue.sh"
SUT="$tmp/claim-issue.sh"
printf '#!/usr/bin/env bash\necho tester\n' > "$tmp/gh-login.sh"
chmod +x "$tmp/gh-login.sh"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 상태: $STUB_DIR/claimed(이슈 edit 이 만든다) · $STUB_DIR/prs.json(pr list 응답)
# 스위치: STUB_PRLIST_FAIL=1(pr list 실패) · STUB_PREDIT_FAIL=1(pr edit 실패)
# $STUB_DIR/calls.log 에 **쓰기 호출만** 남긴다: issue-edit N <args> / pr-edit N <args>
set -uo pipefail
sub="${1:-} ${2:-}"
shift 2 || true
case "$sub" in
  "issue view")
    if [ -f "$STUB_DIR/claimed" ]; then echo '{"state":"OPEN","labels":[{"name":"agent:claimed"}]}'
    else echo '{"state":"OPEN","labels":[]}'; fi ;;
  "issue edit")
    num=$1; shift
    printf 'issue-edit %s %s\n' "$num" "$*" >> "$STUB_DIR/calls.log"
    : > "$STUB_DIR/claimed" ;;
  "pr list")
    [ "${STUB_PRLIST_FAIL:-0}" = "1" ] && { echo "gh: connection refused" >&2; exit 1; }
    cat "$STUB_DIR/prs.json" ;;
  "pr edit")
    num=$1; shift
    printf 'pr-edit %s %s\n' "$num" "$*" >> "$STUB_DIR/calls.log"
    [ "${STUB_PREDIT_FAIL:-0}" = "1" ] && { echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; }
    exit 0 ;;
  "api repos/o/r/git/ref/heads/agent/issue-5")
    # 원격 브랜치 있음(재디스패치) — 잠금 앵커는 이 sha. PR 존재 여부와는 별개다.
    echo "cafebabecafebabecafebabecafebabecafebabe" ;;
  "api repos/o/r/git/refs") echo '{"ref":"refs/issue-runner/claim/5/x"}' ;;
  *) echo "gh: unexpected call: $sub $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

pass=0
fail=0
check() {
  if [ "$2" = "ok" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; fi
}
ck() { check "$1" "$([ "$2" = "$3" ] && echo ok || echo no)"; }

# run <prs.json> — 스텁으로 SUT 를 돌리고 exit code 를 RC 에.
run() {
  rm -rf "$tmp/state"; mkdir -p "$tmp/state"
  printf '%s\n' "$1" > "$tmp/state/prs.json"
  : > "$tmp/state/calls.log"
  STUB_DIR="$tmp/state" STUB_PRLIST_FAIL="${STUB_PRLIST_FAIL:-0}" STUB_PREDIT_FAIL="${STUB_PREDIT_FAIL:-0}" \
  CLAIM_STALE_WAIT=0 PATH="$tmp/bin:$PATH" bash "$SUT" o/r 5 >"$tmp/out" 2>"$tmp/err"
  RC=$?
}
pr_edits() { grep -c '^pr-edit ' "$tmp/state/calls.log"; }

# ── ① 열린 agent/issue-5 PR 이 있다 → PR 에 flow:claimed 부착·flow:agent-ready 제거 ──
run '[{"number":42}]'
ck "PR 있음: exit 0" "$RC" 0
check "PR 있음: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 있음: PR edit 1회" "$(pr_edits)" 1
check "PR 있음: PR #42 에 --add-label flow:claimed" \
  "$(grep -q '^pr-edit 42 .*--add-label flow:claimed' "$tmp/state/calls.log" && echo ok || echo no)"
check "PR 있음: PR #42 에 --remove-label flow:agent-ready" \
  "$(grep -q '^pr-edit 42 .*--remove-label flow:agent-ready' "$tmp/state/calls.log" && echo ok || echo no)"
check "PR 있음: --repo 전달" \
  "$(grep -q '^pr-edit 42 .*--repo o/r' "$tmp/state/calls.log" && echo ok || echo no)"
# 이슈 쪽 claim 은 PR 미러와 무관하게 그대로 — 이슈에 PR 전용 라벨을 붙이지 않는다.
check "PR 있음: 이슈 edit 은 agent:claimed 만" \
  "$(grep -q '^issue-edit 5 .*--add-label agent:claimed' "$tmp/state/calls.log" \
     && ! grep -q '^issue-edit 5 .*flow:' "$tmp/state/calls.log" && echo ok || echo no)"

# ── ② 열린 PR 이 없다 → PR 편집 없음, claim 은 그대로 ─────────────────────────
run '[]'
ck "PR 없음: exit 0" "$RC" 0
check "PR 없음: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 없음: PR edit 0회" "$(pr_edits)" 0
check "PR 없음: stderr 에 미러 경고 없음" "$(grep -q '미러' "$tmp/err" && echo no || echo ok)"

# ── ③ PR 편집 실패 → claim 성공 유지(exit 0·claimed 출력) + stderr 한 줄 ────────
STUB_PREDIT_FAIL=1 run '[{"number":42}]'
ck "PR 편집 실패: exit 0(claim 유지)" "$RC" 0
check "PR 편집 실패: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 편집 실패: PR edit 시도 1회" "$(pr_edits)" 1
check "PR 편집 실패: stderr 한 줄(PR 번호·best-effort)" \
  "$(grep -q 'PR #42 미러 실패(best-effort' "$tmp/err" && echo ok || echo no)"
ck "PR 편집 실패: stderr 정확히 1줄" "$(wc -l < "$tmp/err" | tr -d ' ')" 1

# ── ④ PR 조회 자체 실패 → "PR 없음" 이 아니라 조회 실패다: claim 은 유지, 편집 시도 없이 stderr ──
STUB_PRLIST_FAIL=1 run '[{"number":42}]'
ck "PR 조회 실패: exit 0(claim 유지)" "$RC" 0
check "PR 조회 실패: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 조회 실패: PR edit 0회" "$(pr_edits)" 0
check "PR 조회 실패: stderr 한 줄" \
  "$(grep -q 'PR 조회 실패(best-effort' "$tmp/err" && echo ok || echo no)"

echo "claim-issue: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
