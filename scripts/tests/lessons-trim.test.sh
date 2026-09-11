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

# ── (#232 h1) `- [` bullet 뒤의 독립 산문은 그 bullet 이 지워져도 남는다 ──────
# bullet 은 정의상 그 한 줄뿐이다 — 다음 경계 직전까지를 통째로 그 bullet 소유로 보면
# (구 버전 결함) 뒤따르는 산문까지 함께 지워진다. PR#1 만 드롭되는 캡으로 부른다.
cat > "$tmp/h1.md" <<'EOF'
- [2026-08-01 PR#1] one
independent prose after one — 이 줄은 살아남아야 한다
- [2026-08-02 PR#2] two
- [2026-08-03 PR#3] three
- [2026-08-04 PR#4] four
EOF
out=$(bash "$SUT" "$tmp/h1.md" 3 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "- [2026-08-01 PR#1] one" ] \
  && grep -qF -- 'independent prose after one — 이 줄은 살아남아야 한다' "$tmp/h1.md" \
  && ! grep -qF 'PR#1]' "$tmp/h1.md" \
  && grep -qF 'PR#2]' "$tmp/h1.md" && grep -qF 'PR#3]' "$tmp/h1.md" && grep -qF 'PR#4]' "$tmp/h1.md"; then
  ok
else
  bad "(h1) bullet 삭제해도 독립 산문은 남아야 한다 — rc=$rc out=[$out] file=$(cat "$tmp/h1.md")"
fi

# ── (#232 h1 회귀) `##` 블록의 산문은 블록이 지워질 때 함께 지워진다 ─────────
# h1 수정이 "bullet 뒤 산문 보존"과 정반대 방향(`##` 산문도 항상 보존)으로 과잉교정
# 되지 않았는지를 전용 픽스처로 문다(기존 (c) 케이스와 별도로, 이슈가 지정한 6개
# 픽스처 중 하나로 명시).
cat > "$tmp/h1reg.md" <<'EOF'
## [2026-08-11 PR#11] title eleven
prose eleven line A — 지워져야 한다
prose eleven line B — 지워져야 한다
- [2026-08-12 PR#12] twelve
- [2026-08-13 PR#13] thirteen
- [2026-08-14 PR#14] fourteen
EOF
out=$(bash "$SUT" "$tmp/h1reg.md" 3 2>/dev/null); rc=$?
expected_removed='## [2026-08-11 PR#11] title eleven'
if [ "$rc" = 0 ] && [ "$out" = "$expected_removed" ] \
  && ! grep -qF 'title eleven' "$tmp/h1reg.md" \
  && ! grep -qF 'prose eleven line' "$tmp/h1reg.md"; then
  ok
else
  bad "(h1 회귀) ## 블록 삭제 시 산문도 함께 지워져야 한다 — rc=$rc out=[$out] file=$(cat "$tmp/h1reg.md")"
fi

# ── (#232 h2) 잠금 획득 후 mktemp 실패해도 <file>.lock 이 남지 않는다 ────────
# macOS mktemp 는 `-t` 기본 템플릿에서 `_CS_DARWIN_USER_TEMP_DIR` 를 TMPDIR 보다
# 우선해 TMPDIR 조작만으로는 실패를 재현할 수 없다(실측). PATH 앞단에 항상 실패하는
# mktemp 스텁을 얹어 OS 무관하게 결정론적으로 재현한다.
h2tmp=$(mktemp -d)
mkdir "$h2tmp/stubbin"
cat > "$h2tmp/stubbin/mktemp" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$h2tmp/stubbin/mktemp"
cat > "$tmp/h2.md" <<'EOF'
- [2026-08-05 PR#5] five
EOF
rc=0
out=$(PATH="$h2tmp/stubbin:$PATH" bash "$SUT" "$tmp/h2.md" 5 2>/dev/null) || rc=$?
if [ "$rc" != 0 ] && [ ! -d "$tmp/h2.md.lock" ]; then
  ok
else
  bad "(h2) mktemp 실패 시 lock 잔존 — rc=$rc lockdir_exists=$([ -d "$tmp/h2.md.lock" ] && echo yes || echo no)"
fi
rm -rf "$h2tmp"

# ── (#232 h2 회귀) 정상 경로에서 임시파일 3개 + lock 디렉터리가 여전히 치워진다 ──
# 실제 mktemp 를 그대로 호출하되 만들어진 경로를 로그에 남기는 스텁으로 감싸,
# 트랩이 그 경로들을 실제로 rm 했는지(=존재하지 않는지) 정면으로 단언한다.
h2rtmp=$(mktemp -d)
mkdir "$h2rtmp/stubbin"
real_mktemp=$(command -v mktemp)
cat > "$h2rtmp/stubbin/mktemp" <<STUB
#!/bin/sh
p=\$("$real_mktemp" "\$@")
rc=\$?
echo "\$p" >> "$h2rtmp/created.log"
echo "\$p"
exit \$rc
STUB
chmod +x "$h2rtmp/stubbin/mktemp"
cat > "$tmp/h2reg.md" <<'EOF'
- [2026-08-06 PR#6] six
EOF
PATH="$h2rtmp/stubbin:$PATH" bash "$SUT" "$tmp/h2reg.md" 5 >/dev/null 2>&1
leftover=""
if [ -f "$h2rtmp/created.log" ]; then
  while IFS= read -r p; do
    [ -e "$p" ] && leftover="$leftover $p"
  done < "$h2rtmp/created.log"
fi
if [ -s "$h2rtmp/created.log" ] && [ -z "$leftover" ] && [ ! -d "$tmp/h2reg.md.lock" ]; then
  ok
else
  bad "(h2 회귀) 정상 경로 후 임시파일·lock 잔존 — leftover=[$leftover] created_log_size=$(wc -l < "$h2rtmp/created.log" 2>/dev/null || echo 0)"
fi
rm -rf "$h2rtmp"

# ── (#232 h3) 종결 개행 없는 파일에 append 하면 새 항목이 자기 줄에서 시작한다 ──
printf -- '- [2026-08-07 PR#7] seven' > "$tmp/h3.md"
out=$(bash "$SUT" append "$tmp/h3.md" 5 "- [2026-08-08 PR#8] eight" 2>/dev/null); rc=$?
nb=$(grep -c '^- \[' "$tmp/h3.md")
if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$nb" = 2 ] \
  && grep -qF -- '- [2026-08-07 PR#7] seven' "$tmp/h3.md" \
  && grep -qF -- '- [2026-08-08 PR#8] eight' "$tmp/h3.md"; then
  ok
else
  bad "(h3) 종결개행 없는 파일 append — rc=$rc out=[$out] nb=$nb file=$(cat "$tmp/h3.md")"
fi

# ── (#232 h3 회귀) 이미 개행으로 끝나는 정상 파일에 append 해도 빈 줄이 안 늘어난다 ──
printf -- '- [2026-08-09 PR#9] nine\n' > "$tmp/h3reg.md"
out=$(bash "$SUT" append "$tmp/h3reg.md" 5 "- [2026-08-10 PR#10] ten" 2>/dev/null); rc=$?
blank_count=$(grep -c '^$' "$tmp/h3reg.md" || true)
line_count=$(wc -l < "$tmp/h3reg.md" | tr -d ' ')
if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$blank_count" = 0 ] && [ "$line_count" = 2 ]; then
  ok
else
  bad "(h3 회귀) 정상 파일 append 후 빈 줄 증가 — rc=$rc blank_count=$blank_count line_count=$line_count file=$(cat "$tmp/h3reg.md")"
fi

# ── (#232 h1 격자 — 빈 줄 구분자 gap) 사전 리뷰 BLOCKER 실측·회귀 ──────────
# 사전 리뷰가 지적한 실측 재현: gap 을 드롭 여부와 무관하게 항상 흘리면, 원장의
# 지배적 패턴인 "빈 줄만 있는 gap" 도 살아남아 bstart[1] 이전 프리앰블로 편입되고,
# 프리앰블은 이후 모든 실행에서 무조건 통과되는 구간이라 트림을 반복할 때마다 빈
# 줄이 영구 누적된다(실측: `- [A] a / 빈줄 / - [B] b / 빈줄 / - [C] c` 에 cap=1 →
# A·B 드롭 후 파일 맨 앞에 빈 줄 2개가 영구 잔존). 개별 반례 하나만 막지 않고
# 입력 형태 × cap × 기대 출력(want) 격자로 전수 단언한다(PR#202 교훈 — 근사가
# "더 지우는" 방향과 "덜 지우는" 방향 둘 다에서 틀릴 수 있다).
check_gap_case() {
  label="$1"; input="$2"; cap="$3"; expected_removed="$4"; expected_final="$5"
  printf '%s' "$input" > "$tmp/gap-case.md"
  out=$(bash "$SUT" "$tmp/gap-case.md" "$cap" 2>/dev/null); rc=$?
  actual_final=$(cat "$tmp/gap-case.md")
  if [ "$rc" = 0 ] && [ "$out" = "$expected_removed" ] && [ "$actual_final" = "$expected_final" ]; then
    ok
  else
    bad "(h1 격자: $label) rc=$rc removed=[$out] want_removed=[$expected_removed] file=[$actual_final] want_file=[$expected_final]"
  fi
}

# 1) 빈 줄 구분자만 있는 gap — 연속 2건 드롭(원 BLOCKER 재현 형태) → 잔존 없이 완전 제거.
check_gap_case "빈 줄 gap, 연속 드롭 2건" \
  "- [2026-09-02 PR#33] a

- [2026-09-03 PR#34] b

- [2026-09-04 PR#35] c
" \
  1 \
  "- [2026-09-02 PR#33] a
- [2026-09-03 PR#34] b" \
  "- [2026-09-04 PR#35] c"
# 1-idempotent) 같은 cap 으로 한 번 더 불러도(=멱등 구간) 바이트 불변 — 빈 줄이 또
# 늘어나지 않는지 직접 확인한다.
before_idem=$(shasum "$tmp/gap-case.md")
bash "$SUT" "$tmp/gap-case.md" 1 >/dev/null 2>&1
after_idem=$(shasum "$tmp/gap-case.md")
if [ "$before_idem" = "$after_idem" ]; then ok; else bad "(h1 격자: 빈 줄 gap 멱등) 2차 실행 후 파일이 또 바뀜 — before=$before_idem after=$after_idem"; fi

# 2) 독립 산문이 있는 gap — 드롭돼도 산문은 보존(h1 의 원래 목적).
check_gap_case "산문 gap, 드롭" \
  "- [2026-08-18 PR#18] a
prose line — 지워지면 안 됨
- [2026-08-19 PR#19] b
- [2026-08-20 PR#20] c
" \
  2 \
  "- [2026-08-18 PR#18] a" \
  "prose line — 지워지면 안 됨
- [2026-08-19 PR#19] b
- [2026-08-20 PR#20] c"

# 3) 빈 줄 + 산문 + 빈 줄이 섞인 gap — 드롭돼도 gap 전체(빈 줄 포함) 보존.
check_gap_case "혼합 gap(빈줄+산문+빈줄), 드롭" \
  "- [2026-08-21 PR#21] a

prose in middle — 지워지면 안 됨

- [2026-08-22 PR#22] b
- [2026-08-23 PR#23] c
- [2026-08-24 PR#24] d
" \
  3 \
  "- [2026-08-21 PR#21] a" \
  "
prose in middle — 지워지면 안 됨

- [2026-08-22 PR#22] b
- [2026-08-23 PR#23] c
- [2026-08-24 PR#24] d"

# 4) 빈 줄 gap — 유지되는(kept) bullet 뒤에서는 기존과 동일하게 그대로 보존(회귀:
# 이번 수정은 "드롭되는" 쪽 분기만 좁혔다 — kept 쪽은 안 건드렸는지 확인).
check_gap_case "빈 줄 gap, kept 항목 뒤(불변 확인)" \
  "- [2026-08-28 PR#28] a

- [2026-08-29 PR#29] b

- [2026-08-30 PR#30] c
" \
  2 \
  "- [2026-08-28 PR#28] a" \
  "- [2026-08-29 PR#29] b

- [2026-08-30 PR#30] c"

# 5) 공백 문자만 있는 gap(완전 빈 줄이 아니라 스페이스 3개) — 드롭 시 여전히 "빈 줄"로
# 취급돼 제거된다(정규식이 완전 공백뿐 아니라 공백 문자도 블랭크로 인식하는지 확인).
check_gap_case "공백 전용 gap, 드롭" \
  "- [2026-09-05 PR#36] a
   
- [2026-09-06 PR#37] b
- [2026-09-07 PR#38] c
" \
  2 \
  "- [2026-09-05 PR#36] a" \
  "- [2026-09-06 PR#37] b
- [2026-09-07 PR#38] c"

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
