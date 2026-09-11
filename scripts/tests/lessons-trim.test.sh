#!/usr/bin/env bash
# lessons-trim.sh 픽스처 테스트 — 네트워크 무접속, 순수 파일 입출력.
#
# #208: `.loop/lessons-verifier.md` 캡 규칙이 append(+1)/단발삭제(-1) 로 순증 0 이라
# 한 번 캡(20)을 넘으면 영원히 안 줄던 결함을 고친 스크립트의 SSOT 테스트다. 항목 정의
# (`- [` 한 줄, 또는 `##` 헤더부터 다음 항목 직전까지)와 "캡 이하가 될 때까지 오래된
# 것부터" 수렴 규칙을 여기서 문다. bats 미도입 레포라 다른 scripts/tests/*.test.sh 와
# 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/lessons-trim.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

# ── (a) 캡 이하 — 무변경(멱등, 쓰기조차 하지 않는다) ─────────────────────
cat > "$tmp/a.md" <<'EOF'
# preamble
본문 설명 줄.
---
- [2026-01-01 PR#1] one
- [2026-01-02 PR#2] two
EOF
cp "$tmp/a.md" "$tmp/a.orig.md"
before_sum=$(shasum "$tmp/a.md" | awk '{print $1}')
out=$(bash "$SUT" "$tmp/a.md" 5 2>/dev/null); rc=$?
after_sum=$(shasum "$tmp/a.md" | awk '{print $1}')
if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$before_sum" = "$after_sum" ]; then
  ok
else
  bad "(a) 캡 이하 무변경 — rc=$rc out=[$out] before=$before_sum after=$after_sum"
fi

# (a-2) 항목이 아예 없는 파일(프리앰블뿐)도 무변경 — 파일 없음과 동치의 경계.
printf '# preamble\nno items here\n' > "$tmp/a2.md"
cp "$tmp/a2.md" "$tmp/a2.orig.md"
out=$(bash "$SUT" "$tmp/a2.md" 5 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ] && diff -q "$tmp/a2.md" "$tmp/a2.orig.md" >/dev/null; then
  ok
else
  bad "(a-2) 항목 0개 무변경 — rc=$rc out=[$out]"
fi

# ── (b) `- [` 한 줄 항목만 초과 ────────────────────────────────────────
cat > "$tmp/b.md" <<'EOF'
# preamble
---
- [2026-01-01 PR#1] one
- [2026-01-02 PR#2] two
- [2026-01-03 PR#3] three
- [2026-01-04 PR#4] four
- [2026-01-05 PR#5] five
EOF
out=$(bash "$SUT" "$tmp/b.md" 3 2>/dev/null); rc=$?
expected_removed='- [2026-01-01 PR#1] one
- [2026-01-02 PR#2] two'
if [ "$rc" = 0 ] && [ "$out" = "$expected_removed" ]; then
  ok
else
  bad "(b) 제거 목록(오래된 2개, 순서 보존) — rc=$rc out=[$out]"
fi
remaining=$(grep -c '^- \[' "$tmp/b.md")
if [ "$remaining" = 3 ]; then ok; else bad "(b) 잔존 항목 수=3 기대, 실제 $remaining"; fi
# 남은 항목이 최신 쪽(PR#3·4·5)인지 — PR#1·2(오래된 쪽)가 파일에서 사라졌는지.
if ! grep -q 'PR#1\]' "$tmp/b.md" && ! grep -q 'PR#2\]' "$tmp/b.md" \
  && grep -q 'PR#3\]' "$tmp/b.md" && grep -q 'PR#4\]' "$tmp/b.md" && grep -q 'PR#5\]' "$tmp/b.md"; then
  ok
else
  bad "(b) 남은 항목이 최신(PR#3·4·5)이어야 한다: $(cat "$tmp/b.md")"
fi

# ── (c) `##` 블록이 섞인 초과 — 산문이 찢어지지 않는지 ────────────────
cat > "$tmp/c.md" <<'EOF'
# preamble
---
## [2026-01-01 PR#1] title one
prose one line A
prose one line B
- [2026-01-02 PR#2] two
## [2026-01-03 PR#3] title three
prose three line A
prose three line B
prose three line C
- [2026-01-04 PR#4] four
- [2026-01-05 PR#5] five
## [2026-01-06 PR#6] title six
prose six line A — 이 줄이 살아남아야 한다
prose six line B
EOF
out=$(bash "$SUT" "$tmp/c.md" 3 2>/dev/null); rc=$?
expected_removed='## [2026-01-01 PR#1] title one
- [2026-01-02 PR#2] two
## [2026-01-03 PR#3] title three'
if [ "$rc" = 0 ] && [ "$out" = "$expected_removed" ]; then
  ok
else
  bad "(c) 제거 목록(오래된 항목 3개, ## 블록 포함, 순서 보존) — rc=$rc out=[$out]"
fi
remaining=$(( $(grep -c '^- \[' "$tmp/c.md") + $(grep -c '^## ' "$tmp/c.md") ))
if [ "$remaining" = 3 ]; then ok; else bad "(c) 잔존 항목 수=3 기대, 실제 $remaining"; fi
# 지워진 ## 블록의 잔재(제목·프로즈)가 하나도 안 남아야 한다 — 통째 삭제 확인.
if grep -q 'title one' "$tmp/c.md" || grep -q 'prose one line' "$tmp/c.md" \
  || grep -q 'title three' "$tmp/c.md" || grep -q 'prose three line' "$tmp/c.md"; then
  bad "(c) 지워진 ## 블록의 잔재가 남아 있다: $(cat "$tmp/c.md")"
else
  ok
fi
# 살아남은 마지막 ## 블록(PR#6)은 헤더+프로즈 3줄이 통째로 안 찢어지고 남아야 한다.
if grep -q '## \[2026-01-06 PR#6\] title six' "$tmp/c.md" \
  && grep -q 'prose six line A — 이 줄이 살아남아야 한다' "$tmp/c.md" \
  && grep -q 'prose six line B' "$tmp/c.md"; then
  ok
else
  bad "(c) 살아남은 ## 블록 프로즈가 찢어졌다: $(cat "$tmp/c.md")"
fi
# 남은 항목이 최신(PR#4·5·6)인지.
if grep -q 'PR#4\]' "$tmp/c.md" && grep -q 'PR#5\]' "$tmp/c.md" && grep -q 'PR#6\]' "$tmp/c.md"; then
  ok
else
  bad "(c) 남은 항목이 최신(PR#4·5·6)이어야 한다: $(cat "$tmp/c.md")"
fi
# 프리앰블(캡·항목과 무관한 머리말)도 그대로 보존되는지.
if head -2 "$tmp/c.md" | grep -q '^# preamble$'; then ok; else bad "(c) 프리앰블 보존 실패"; fi

# ── 초과분이 캡보다 훨씬 큰 경우(수렴 확인 — 한 번에 여러 개를 지운다) ──
: > "$tmp/big.md"
for i in $(seq 1 10); do
  printf -- '- [2026-02-%02d PR#%d] item%d\n' "$i" "$i" "$i" >> "$tmp/big.md"
done
out=$(bash "$SUT" "$tmp/big.md" 2 2>/dev/null); rc=$?
removed_lines=$(printf '%s\n' "$out" | grep -c '^- \[' || true)
remaining=$(grep -c '^- \[' "$tmp/big.md")
if [ "$rc" = 0 ] && [ "$removed_lines" = 8 ] && [ "$remaining" = 2 ] \
  && grep -q 'PR#9\]' "$tmp/big.md" && grep -q 'PR#10\]' "$tmp/big.md"; then
  ok
else
  bad "(수렴) 10개→캡2, 한 번에 8개 제거해 캡까지 내려가야 한다 — removed=$removed_lines remaining=$remaining"
fi

# ── 오류 경계 ────────────────────────────────────────────────────────
rc=0
out=$(bash "$SUT" 2>/dev/null) || rc=$?
if [ "$rc" != 0 ] && [ -z "$out" ]; then ok; else bad "인자 누락 — rc=$rc out=[$out]"; fi

rc=0
out=$(bash "$SUT" "$tmp/a.md" abc 2>/dev/null) || rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok; else bad "cap 비숫자 — rc=$rc out=[$out]"; fi

rc=0
out=$(bash "$SUT" "$tmp/a.md" 0 2>/dev/null) || rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok; else bad "cap=0 — rc=$rc out=[$out]"; fi

rc=0
out=$(bash "$SUT" "$tmp/does-not-exist.md" 5 2>/dev/null) || rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok; else bad "파일 없음 — rc=$rc out=[$out]"; fi

echo "lessons-trim.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
