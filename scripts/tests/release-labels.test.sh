#!/usr/bin/env bash
# release-labels.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# #117: 스윕이 `Refs` 부분착지 이슈의 agent-ready 를 떼어 조용히 좌초시키던 결함의 가드.
# bats 미도입 레포라 finish-classify.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/release-labels.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# gh 스텁 — `issue view … --json state` 는 STUB_STATE 를 돌려주고(빈 값이면 실패 모사),
# `issue edit …` 은 인자를 그대로 기록한다. 그 밖의 호출은 실패시켜 새는 경로를 드러낸다.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  [ -n "${STUB_STATE:-}" ] || exit 1
  printf '%s\n' "$STUB_STATE"
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  printf '%s\n' "$*" >> "$STUB_EDIT_LOG"
  exit 0
fi
exit 1
STUB
chmod +x "$tmp/bin/gh"

pass=0
fail=0

check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name"
  fi
}

# run <state> — 스텁 상태로 SUT 를 돌리고 gh issue edit 인자 한 줄을 돌려준다.
run() {
  : > "$tmp/edit.log"
  STUB_STATE="$1" STUB_EDIT_LOG="$tmp/edit.log" \
    PATH="$tmp/bin:$PATH" "$SUT" owner/repo 42 >/dev/null 2>&1
  cat "$tmp/edit.log"
}

has()  { case "$1" in *"--remove-label $2"*) echo ok ;; *) echo no ;; esac; }
lacks() { case "$1" in *"--remove-label $2"*) echo no ;; *) echo ok ;; esac; }

# ── ① OPEN 이슈 — agent-ready 를 남긴다(이 이슈의 핵심 가드) ────────────────
out=$(run OPEN)
check "OPEN: agent-ready 유지"        "$(lacks "$out" 'agent-ready')"
check "OPEN: agent:claimed 정리"      "$(has  "$out" 'agent:claimed')"
check "OPEN: flow:verify 정리"        "$(has  "$out" 'flow:verify')"
check "OPEN: flow:ready 정리"         "$(has  "$out" 'flow:ready')"
check "OPEN: harvesting 정리"         "$(has  "$out" 'harvesting')"

# ── ② CLOSED 이슈 — 종전대로 전부 정리(무회귀) ─────────────────────────────
out=$(run CLOSED)
check "CLOSED: agent-ready 정리"      "$(has "$out" 'agent-ready')"
check "CLOSED: agent:claimed 정리"    "$(has "$out" 'agent:claimed')"
check "CLOSED: harvesting 정리"       "$(has "$out" 'harvesting')"

# ── ③ 상태 조회 실패 — fail-safe 로 agent-ready 를 남긴다 ───────────────────
# 잘못 남기면 eligible-issues.sh 의 `is:open` 이 삼키고, 잘못 떼면 조용히 좌초한다.
out=$(run "")
check "조회 실패: agent-ready 유지"   "$(lacks "$out" 'agent-ready')"
check "조회 실패: 흔적 라벨은 정리"   "$(has  "$out" 'agent:claimed')"
check "조회 실패에도 edit 은 1회 호출" "$([ "$(printf '%s' "$out" | grep -c .)" = 1 ] && echo ok || echo no)"

# ── ④ 비공허 실증 — 스텁이 실제로 소비되는지(테스트가 공회전하지 않는지) ────
out=$(run OPEN)
check "스텁 경유 실증: edit 호출이 기록된다" \
  "$([ -n "$out" ] && echo ok || echo no)"
check "스텁 경유 실증: 대상 이슈가 인자에 실린다" \
  "$(has "$out" 'agent:claimed')"
check "스텁 경유 실증: repo·issue 인자가 그대로 전달된다" \
  "$(printf '%s' "$out" | grep -q -- '--repo owner/repo' && printf '%s' "$out" | grep -qw 42 && echo ok || echo no)"

echo "release-labels: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
