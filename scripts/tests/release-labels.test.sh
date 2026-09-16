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
  # 레포에 라벨 **정의**가 없는 상태 모사 — gh 는 제거조차 편집을 통째로 실패시킨다.
  if [ "${STUB_NOLABEL:-0}" = 1 ]; then
    case " $* " in *" verify:반송 "*)
      printf 'FAILED %s\n' "$*" >> "$STUB_EDIT_LOG"
      echo "gh: 'verify:반송' not found" >&2; exit 1 ;;
    esac
  fi
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
  STUB_STATE="$1" STUB_EDIT_LOG="$tmp/edit.log" STUB_NOLABEL="${STUB_NOLABEL:-0}" \
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
check "OPEN: verifying 정리(#275)"    "$(has  "$out" 'verifying')"
# `verify:반송`(#577)도 **실행 흔적**이다 — 반송당했다는 이 회차의 사실이지 자격이 아니다.
# `closeout-dup` 의 이슈 정리 경로(전이 ④)가 이 스크립트이므로, 여기 한 줄이 그 제거 지점이다.
check "OPEN: verify:반송 정리(#577)"  "$(has  "$out" 'verify:반송')"

# ── ② CLOSED 이슈 — 종전대로 전부 정리(무회귀) ─────────────────────────────
out=$(run CLOSED)
check "CLOSED: agent-ready 정리"      "$(has "$out" 'agent-ready')"
check "CLOSED: agent:claimed 정리"    "$(has "$out" 'agent:claimed')"
check "CLOSED: harvesting 정리"       "$(has "$out" 'harvesting')"
check "CLOSED: verify:반송 정리(#577)" "$(has "$out" 'verify:반송')"

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

# ── ⑤ (#577) 라벨 **정의**가 없는 레포 — 표식 하나 때문에 정리 전체가 유실되면 안 된다 ──
# `verify:반송` 은 옵트인만 하고 setup-labels.sh 를 다시 안 돌린 레포에 정의가 없고, gh 는 제거조차
# 편집을 통째로 실패시킨다. 이 스크립트는 `|| true` 라 그 실패가 **조용히** 삼켜져 실행 흔적 정리가
# 전부 사라진다 — 이 스크립트가 막으려는 바로 그 조용한 좌초다(사전 리뷰 WARN).
STUB_NOLABEL=1 out=$(run CLOSED)
check "⑤ 정의 부재: 첫 edit 은 실패한다(대조군 — 스텁이 실제로 문다)" \
  "$(printf '%s' "$out" | grep -q '^FAILED ' && echo ok || echo no)"
check "⑤ 정의 부재: verify:반송 만 빼고 재시도한다" \
  "$(printf '%s' "$out" | grep -v '^FAILED ' | grep -q -- '--remove-label verify:반송' && echo no || echo ok)"
check "⑤ 정의 부재: 나머지 실행 흔적 정리는 간다" \
  "$(printf '%s' "$out" | grep -v '^FAILED ' | grep -q -- '--remove-label harvesting' && echo ok || echo no)"
# `--remove-label` 과 값은 쌍이다 — 값만 빼면 다음 플래그가 값으로 먹혀 agent-ready 회수가 어긋난다.
check "⑤ 정의 부재: 쌍으로 빠져 agent-ready 회수가 살아 있다(CLOSED)" \
  "$(printf '%s' "$out" | grep -v '^FAILED ' | grep -q -- '--remove-label agent-ready' && echo ok || echo no)"

echo "release-labels: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
