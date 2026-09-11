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

# ── 경계값: 항목 수 == 캡(등호 쪽) — 무변경이어야 한다 ─────────────────
cat > "$tmp/eq.md" <<'EOF'
# preamble
---
- [2026-03-01 PR#1] one
- [2026-03-02 PR#2] two
- [2026-03-03 PR#3] three
EOF
cp "$tmp/eq.md" "$tmp/eq.orig.md"
out=$(bash "$SUT" "$tmp/eq.md" 3 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ] && diff -q "$tmp/eq.md" "$tmp/eq.orig.md" >/dev/null; then
  ok
else
  bad "(경계) 항목수==캡 무변경 — rc=$rc out=[$out]"
fi

# ── 잠금 — 다른 프로세스가 잠금을 쥐고 있으면 fail-closed, 원본 안 건드림 ──
cat > "$tmp/lock.md" <<'EOF'
# preamble
---
- [2026-04-01 PR#1] one
- [2026-04-02 PR#2] two
- [2026-04-03 PR#3] three
- [2026-04-04 PR#4] four
EOF
cp "$tmp/lock.md" "$tmp/lock.orig.md"
mkdir "$tmp/lock.md.lock"
rc=0
out=$(LESSONS_TRIM_LOCK_WAIT=1 bash "$SUT" "$tmp/lock.md" 2 2>/dev/null) || rc=$?
if [ "$rc" = 3 ] && [ -z "$out" ] && diff -q "$tmp/lock.md" "$tmp/lock.orig.md" >/dev/null; then
  ok
else
  bad "(잠금) 다른 보유자 있으면 exit 3·무출력·원본 무변경 — rc=$rc out=[$out]"
fi
rmdir "$tmp/lock.md.lock"

# ── 잠금 — 정상 실행 후 잠금 디렉터리가 남지 않는다(멱등 경로·트리밍 경로 둘 다) ──
out=$(bash "$SUT" "$tmp/lock.orig.md" 2 2>/dev/null)
if [ ! -d "$tmp/lock.orig.md.lock" ]; then ok; else bad "(잠금) 트리밍 후 lock 디렉터리 잔존"; fi

cat > "$tmp/nolockleak.md" <<'EOF'
# preamble
---
- [2026-05-01 PR#1] one
EOF
bash "$SUT" "$tmp/nolockleak.md" 5 >/dev/null 2>&1
if [ ! -d "$tmp/nolockleak.md.lock" ]; then ok; else bad "(잠금) 무변경(no-op) 경로 후 lock 디렉터리 잔존"; fi

# ── append 서브커맨드 — 기본 동작 ────────────────────────────────────
# (append-a) 파일이 없으면 append 가 새로 만든다.
out=$(bash "$SUT" append "$tmp/append-new.md" 5 "- [2026-06-01 PR#1] new" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ] && grep -qF -- '- [2026-06-01 PR#1] new' "$tmp/append-new.md"; then
  ok
else
  bad "(append-a) 파일 없음 → 생성 — rc=$rc out=[$out]"
fi

# (append-b) 캡 이하로 유지되면 트림 없음(무출력) — 기존 항목 + 새 항목 모두 남는다.
cat > "$tmp/append-under.md" <<'EOF'
# preamble
---
- [2026-06-01 PR#1] one
EOF
out=$(bash "$SUT" append "$tmp/append-under.md" 5 "- [2026-06-02 PR#2] two" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ] \
  && grep -qF 'PR#1]' "$tmp/append-under.md" && grep -qF 'PR#2]' "$tmp/append-under.md"; then
  ok
else
  bad "(append-b) 캡 이하 — 무트림·둘 다 잔존 — rc=$rc out=[$out]"
fi

# (append-c) 캡 초과 — append 직후 같은 호출 안에서 오래된 것부터 정리된다.
cat > "$tmp/append-over.md" <<'EOF'
# preamble
---
- [2026-06-01 PR#1] one
- [2026-06-02 PR#2] two
- [2026-06-03 PR#3] three
EOF
out=$(bash "$SUT" append "$tmp/append-over.md" 3 "- [2026-06-04 PR#4] four" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "- [2026-06-01 PR#1] one" ] \
  && ! grep -qF 'PR#1]' "$tmp/append-over.md" \
  && grep -qF 'PR#2]' "$tmp/append-over.md" && grep -qF 'PR#3]' "$tmp/append-over.md" \
  && grep -qF 'PR#4]' "$tmp/append-over.md"; then
  ok
else
  bad "(append-c) 캡 초과 — append+정리 한 호출 — rc=$rc out=[$out] file=$(cat "$tmp/append-over.md")"
fi

# ── 동시성 — append 가 트림의 read→write 창에 끼어들어도 유실 안 된다(#208 BLOCKER②) ──
# A(트림, 다른 세션을 흉내)가 잠금을 쥔 채 read(awk)까지 마치고 write(mv) 직전에
# LESSONS_TRIM_TEST_HOLD_BEFORE_WRITE 로 멈춰 있는 동안, B(append, 다른 세션)가 같은
# 파일에 새 항목을 넣으려 한다. append 가 잠금 **안**에서 일어나면 B 는 A 가 끝날 때까지
# 자기 read 조차 시작 못 하므로 A 의 mv 가 B 의 값을 볼 수도 밟을 수도 없다 — 검증자
# 리뷰가 지적한 "A 읽음→B append→A 의 mv 가 B 를 덮음" 유실 경로가 원천 차단되는지를
# 실제 두 프로세스로 잰다(딜레이 훅으로 창을 인위적으로 벌려 타이밍 의존 없이 결정론적).
cat > "$tmp/race.md" <<'EOF'
- [2026-07-01 PR#1] one
- [2026-07-02 PR#2] two
- [2026-07-03 PR#3] three
- [2026-07-04 PR#4] four
EOF
LESSONS_TRIM_TEST_HOLD_BEFORE_WRITE=1.5 bash "$SUT" "$tmp/race.md" 3 > "$tmp/raceA.out" 2>&1 &
race_a_pid=$!
# A 가 잠금을 쥘 때까지 짧게 폴링(최대 2초) — B 를 그 전에 쏘면 경합 자체가 안 걸린다.
waited=0
while [ ! -d "$tmp/race.md.lock" ] && [ "$waited" -lt 40 ]; do
  sleep 0.05
  waited=$((waited + 1))
done
race_b_rc=0
bash "$SUT" append "$tmp/race.md" 3 "- [2026-07-05 PR#999] concurrent" > "$tmp/raceB.out" 2>&1 || race_b_rc=$?
race_a_rc=0
wait "$race_a_pid" || race_a_rc=$?
if [ -d "$tmp/race.md.lock" ] && [ "$waited" -lt 40 ]; then
  bad "(동시성) A 가 실제로 잠금을 쥔 채 창을 열었는지 못 확인(폴링 실패)"
elif [ "$race_a_rc" != 0 ] || [ "$race_b_rc" != 0 ]; then
  bad "(동시성) A 또는 B 비정상 종료 — a_rc=$race_a_rc b_rc=$race_b_rc a_out=[$(cat "$tmp/raceA.out")] b_out=[$(cat "$tmp/raceB.out")]"
elif grep -qF 'PR#999]' "$tmp/race.md"; then
  ok
else
  bad "(동시성) B(append) 의 항목이 유실됐다 — A 의 mv 가 덮어썼다: $(cat "$tmp/race.md")"
fi
if [ ! -d "$tmp/race.md.lock" ]; then ok; else bad "(동시성) 레이스 후 lock 디렉터리 잔존"; fi

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

rc=0
out=$(bash "$SUT" append "$tmp/append-new.md" 5 2>/dev/null) || rc=$?
if [ "$rc" != 0 ] && [ -z "$out" ]; then ok; else bad "append 줄 인자 누락 — rc=$rc out=[$out]"; fi

rc=0
out=$(bash "$SUT" append "$tmp/append-new.md" abc "- [2026-06-01 PR#1] x" 2>/dev/null) || rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok; else bad "append cap 비숫자 — rc=$rc out=[$out]"; fi

echo "lessons-trim.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
