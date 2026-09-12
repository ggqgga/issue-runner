#!/usr/bin/env bash
# bounce-comment.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
#
# #212 (권장 2): 반송 코멘트 문구를 SKILL.md 예시 문자열 손타이핑 대신 한 자리에서
# 생성·게시하게 뽑은 헬퍼. 여기서 재는 축은 하나다 — **이 스크립트가 만드는 본문이
# 기존 SKILL.md 문구와 바이트 단위로 같은가**(달라지면 bounce-state.sh 매칭이 다시
# 깨질 수 있다). bats 미도입 레포라 다른 테스트와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/bounce-comment.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# gh 스텁 — `pr comment <pr> --repo <repo> --body <body>` 호출의 인자를 그대로
# 파일에 기록한다(널 바이트 구분 — 본문에 개행이 섞여도 인자 경계가 흐려지지 않게).
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
: > "$STUB_CAPTURE"
for a in "$@"; do printf '%s\0' "$a" >> "$STUB_CAPTURE"; done
exit 0
STUB
chmod +x "$tmp/bin/gh"

pass=0
fail=0

# get_body <capture-file> — --body 다음 인자를 뽑는다(널 구분 파싱).
get_body() {
  python3 - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
parts = data.split(b"\0")
parts = [p for p in parts if p != b""] if data.endswith(b"\0") else parts
for i, p in enumerate(parts):
    if p == b"--body" and i + 1 < len(parts):
        sys.stdout.buffer.write(parts[i + 1])
        break
PY
}

check_eq() {
  local name="$1" expect="$2" actual="$3"
  if [ "$expect" = "$actual" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name"
    echo "    기대: [$expect]"
    echo "    실제: [$actual]"
  fi
}

# ── redispatch 채널 ───────────────────────────────────────────────────
STUB_CAPTURE="$tmp/cap1"
PATH="$tmp/bin:$PATH" STUB_CAPTURE="$STUB_CAPTURE" bash "$SUT" redispatch owner/repo 42 166 >/dev/null 2>&1
rc=$?
body=$(get_body "$STUB_CAPTURE")
check_eq "redispatch rc=0" "0" "$rc"
check_eq "redispatch 본문 — SKILL.md 문구와 바이트 동일" \
  "재디스패치: #166 — 완결 유실(검증 전 사망) <!-- bodat:worker -->" "$body"

# 인자 캡처에 pr 번호·repo 가 실제로 들어갔는지(오호출 방지)
if grep -qz -- "42" "$STUB_CAPTURE" 2>/dev/null && grep -qz -- "owner/repo" "$STUB_CAPTURE" 2>/dev/null; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ redispatch — pr/repo 인자가 gh 호출에 전달되지 않음"
fi

# ── reverify-fail 채널 ────────────────────────────────────────────────
STUB_CAPTURE="$tmp/cap2"
PATH="$tmp/bin:$PATH" STUB_CAPTURE="$STUB_CAPTURE" \
  bash "$SUT" reverify-fail owner/repo 42 166 3 "codex BLOCKER" >/dev/null 2>&1
rc=$?
body=$(get_body "$STUB_CAPTURE")
expect_body="재검증 실패: #166 — codex BLOCKER (attempt 3)
<!-- bodat:worker -->"
check_eq "reverify-fail rc=0" "0" "$rc"
check_eq "reverify-fail 본문 — SKILL.md 문구와 바이트 동일(개행 포함)" "$expect_body" "$body"

# ── human-review 채널 (#334 WARN — ①-c 3) 시정의 손타이핑을 대체) ──────────
STUB_CAPTURE="$tmp/cap4"
PATH="$tmp/bin:$PATH" STUB_CAPTURE="$STUB_CAPTURE" \
  bash "$SUT" human-review owner/repo 42 166 "재심: 좁힌다 — 이렇게 고쳐라" >/dev/null 2>&1
rc=$?
body=$(get_body "$STUB_CAPTURE")
check_eq "human-review rc=0" "0" "$rc"
check_eq "human-review 본문 — SKILL.md 문구와 바이트 동일" \
  "재디스패치: #166 — 사람 재심이 시정 방향(재심: 좁힌다 — 이렇게 고쳐라) <!-- bodat:worker -->" "$body"

# 인용에 개행이 섞여도 **한 줄**로 접힌다 — 반송 마커는 첫 줄 접두로 판정되므로
# 인용이 줄을 넘기면 뒤따르는 줄이 마커 밖으로 샌다.
STUB_CAPTURE="$tmp/cap5"
PATH="$tmp/bin:$PATH" STUB_CAPTURE="$STUB_CAPTURE" \
  bash "$SUT" human-review owner/repo 42 166 "$(printf '판정이 맞다\n고쳐라')" >/dev/null 2>&1
body=$(get_body "$STUB_CAPTURE")
check_eq "human-review — 인용 안 개행을 한 줄로 접는다" \
  "재디스패치: #166 — 사람 재심이 시정 방향(판정이 맞다 고쳐라) <!-- bodat:worker -->" "$body"
if [ "$(printf '%s' "$body" | wc -l | tr -d ' ')" = "0" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  ✗ human-review 본문이 여러 줄이다"
fi

STUB_CAPTURE="$tmp/cap6"; : > "$STUB_CAPTURE"
rc=0
PATH="$tmp/bin:$PATH" STUB_CAPTURE="$STUB_CAPTURE" bash "$SUT" human-review owner/repo 42 166 >/dev/null 2>&1 || rc=$?
check_eq "human-review 인용 누락 → exit 2" "2" "$rc"
if [ -s "$STUB_CAPTURE" ]; then
  fail=$((fail + 1)); echo "  ✗ human-review 인용 누락인데 gh 가 호출됨"
else
  pass=$((pass + 1))
fi

# ── 인자 누락 — usage(exit 2), gh 호출 없음 ──────────────────────────────
STUB_CAPTURE="$tmp/cap3"; : > "$STUB_CAPTURE"
rc=0
PATH="$tmp/bin:$PATH" STUB_CAPTURE="$STUB_CAPTURE" bash "$SUT" redispatch owner/repo 42 >/dev/null 2>&1 || rc=$?
check_eq "redispatch 인자 누락(issue) → exit 2" "2" "$rc"
if [ -s "$STUB_CAPTURE" ]; then
  fail=$((fail + 1)); echo "  ✗ redispatch 인자 누락인데 gh 가 호출됨"
else
  pass=$((pass + 1))
fi

rc=0
PATH="$tmp/bin:$PATH" bash "$SUT" reverify-fail owner/repo 42 166 3 >/dev/null 2>&1 || rc=$?
check_eq "reverify-fail 사유 누락 → exit 2" "2" "$rc"

# ── 알 수 없는 채널 → usage(exit 2) ──────────────────────────────────────
rc=0
PATH="$tmp/bin:$PATH" bash "$SUT" bogus-channel owner/repo 42 166 >/dev/null 2>&1 || rc=$?
check_eq "미상 채널 → exit 2" "2" "$rc"

# ── 실행 비트 회귀 (#173: 빠지면 exit 126 으로 값이 조용히 빈 문자열로 degrade) ──
if [ -x "$SUT" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "  ✗ bounce-comment.sh 실행 비트 없음"
fi

echo "bounce-comment.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
