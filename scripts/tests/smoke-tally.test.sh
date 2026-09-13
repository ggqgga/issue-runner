#!/usr/bin/env bash
# smoke-tally.sh 픽스처 테스트 — 네트워크 무접속(PATH 에 gh 스텁을 깔아 호출을 드러낸다).
#
# #448: closeout 5단계 스모크의 집계 규칙(표식 판별 · 분모 제외 · 보류 합산)이 SKILL 산문과
# smoke-prompt 양쪽에 있던 "계산기 둘" 을 하나로 접은 스크립트의 SSOT 테스트다. 무는 것:
#   ⑴ `[칸 ③]` 표식 항목은 **판정 토큰이 무엇이든** 보류 — 분모에서 빠진다(#309)
#   ⑵ 표식 없는 미밟음(`보류`)도 분모에서 빠지고 표식과 **합산**된다
#   ⑶ 분모 0 → `skip`(0/0 은 통과가 아니라 아무것도 안 본 것 — 거짓 초록)
#   ⑷ fail 과 보류는 **동시에 참**일 수 있다(verdict=fail 이어도 held 가 남으면 안 닫는다)
#   ⑸ 문법에 안 맞거나 어느 항목에도 안 붙는 줄이 **조용히 사라지지 않는다**(unparsed → held)
#   ⑹ `--checks` 모드의 `steppable` 이 "스모크를 돌릴 것인가" 를 가른다(`없음` 절 = 0)
#   ⑺ **분모의 진실은 원본 체크리스트다**(#467 P1-2) — 모델이 항목을 빠뜨리거나 두 번 내면
#      그 항목은 보류로 세어지고 그 틱은 green 이 될 수 없다
#   ⑻ 표식은 **항목 줄의 접두**에서만 본다(#467 P2-2) — 근거에 표식을 언급한 정상 pass 가
#      보류로 뒤집히면 안 된다
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/smoke-tally.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub"

# 이 스크립트는 읽기 전용이다 — gh 를 부르면 스텁이 exit 1 로 드러낸다(다른 테스트와 같은 규율).
cat > "$tmp/stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "$tmp/stub/gh"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

field() {  # field <키> — OUT(JSON 한 줄)에서 값을 꺼낸다(형식이 우리 것이라 jq 없이 가능)
  printf '%s' "$OUT" | sed -e 's/.*"'"$1"'":"\{0,1\}//' -e 's/[",}].*//'
}

# want <desc> <체크리스트> <결과|-> <키=값>... — 결과가 `-` 면 체크 모드.
want() {
  desc=$1; printf '%s' "$2" > "$tmp/checks.txt"; res=$3; shift 3
  if [ "$res" = "-" ]; then
    OUT=$(PATH="$tmp/stub:$PATH" bash "$SUT" --checks "$tmp/checks.txt" 2>/dev/null)
  else
    printf '%s' "$res" > "$tmp/result.txt"
    OUT=$(PATH="$tmp/stub:$PATH" bash "$SUT" --checks "$tmp/checks.txt" "$tmp/result.txt" 2>/dev/null)
  fi
  RC=$?
  if [ "$RC" != 0 ]; then bad "$desc — rc=$RC (기대 0) out=[$OUT]"; return; fi
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    got=$(field "$k")
    if [ "$got" = "$v" ]; then ok; else bad "$desc — $k=$got (기대 $v) · out=[$OUT]"; fi
  done
}

CHECKS_2='- [ ] /pcs 렌더
- [ ] [칸 ③] TEST 워커 프로필 #18 드라이런
'

echo "── 결과 모드 격자 ────────────────────────────────────────────────"

# ① 표식 항목은 판정이 pass 로 적혀 있어도 보류 — 분모에서 뺀다(#309 의 핵심 회귀).
#    뮤테이션: SUT 의 `it_marked` 갈래를 지우면 pass=2·denominator=2 로 실장비가 통과로
#    세어지며 여기가 빨개진다.
want "① 표식 항목은 pass 로 적혀도 보류" "$CHECKS_2" \
'pass - [ ] /pcs 렌더 — 카드 12개
pass - [ ] [칸 ③] TEST 워커 프로필 #18 드라이런 — 통과라고 우김
' pass=1 held=1 held_marked=1 denominator=1 verdict=held

# ② 표식 + 표식 없는 미밟음(보류) 합산
want "② 표식 + 미밟음 합산" '- [ ] /pcs 렌더
- [ ] [칸 ③] 실장비 드라이런
- [ ] ssh 로 log/*.out grep
' 'pass - [ ] /pcs 렌더
보류 - [ ] [칸 ③] 실장비 드라이런
보류 - [ ] ssh 로 log/*.out grep — 브라우저 밖 수단
' pass=1 held=2 held_marked=1 held_unstepped=1 denominator=1 verdict=held

# ③ 전부 통과 + 보류 0 → green (이슈 close 갈래)
want "③ 전부 통과 → green" '- [ ] a
- [ ] b
' 'pass - [ ] a
PASS - [ ] b — 대소문자 무시
' pass=2 fail=0 held=0 denominator=2 verdict=green

# ④ fail 과 보류는 동시에 참이다 — verdict 는 fail 이지만 held 가 남는다.
want "④ fail + 보류 동시" '- [ ] a
- [ ] b
- [ ] [칸 ③] 실장비
' 'pass - [ ] a
fail - [ ] b — 기대와 다른 값
보류 - [ ] [칸 ③] 실장비
' pass=1 fail=1 held=1 denominator=2 verdict=fail

# ⑤ 표식만 남은 절 → 분모 0 → skip (0/0 통과로 찍으면 거짓 초록)
want "⑤ 분모 0 → skip" '- [ ] [칸 ③] 실장비 하나뿐
' '보류 - [ ] [칸 ③] 실장비 하나뿐
' pass=0 fail=0 held=1 denominator=0 verdict=skip

# ⑥ 이미 밟힌 `- [x]` 항목은 보류에도 분모에도 안 들어간다(smoke-prompt 와 같은 범위).
want "⑥ - [x] 는 skipped" '- [x] 이미 밟은 줄
- [x] [칸 ③] 이미 밟은 표식 줄
- [ ] 남은 줄
' 'pass - [x] 이미 밟은 줄
pass - [ ] 남은 줄
' pass=1 skipped=2 held=0 denominator=1 verdict=green

# ⑦ 문법 위반·요약 줄은 **조용히 사라지지 않는다** — unparsed 로 세어져 held 에 합산되고
#    그 틱은 green 이 될 수 없다(판정 못 한 줄을 흘려보내는 것이 곧 거짓 초록).
want "⑦ 문법 위반·요약 줄 → unparsed" '- [ ] a
' 'pass - [ ] a
- [ ] 판정 토큰이 없는 줄
스모크: 1/1 통과
' pass=1 unparsed=2 held=2 verdict=held

# ⑧ 근거에 `fail` 이라는 낱말이 있어도 판정은 **첫 토큰**뿐이다.
want "⑧ 판정은 첫 토큰뿐" '- [ ] 배포가 fail 하지 않았는지 확인
' 'pass - [ ] 배포가 fail 하지 않았는지 확인 — 정상
' pass=1 fail=0 verdict=green

# ⑨ 영문 프롬프트 어휘 `held` 수용
want "⑨ held 어휘 수용" '- [ ] a
- [ ] outside-browser means
' 'pass - [ ] a
held - [ ] outside-browser means
' pass=1 held=1 held_unstepped=1 verdict=held

# ⑩ 빈 줄·`#` 주석은 무시(항목이 아니다)
want "⑩ 빈 줄·주석 무시" '<!-- 형태 고정 -->
- [ ] a
' '
# 이건 주석
pass - [ ] a
' pass=1 unparsed=0 verdict=green

echo "── 원본 체크리스트 대조 (#467 P1-2·P2-2) ─────────────────────────"

# ⑪ 2항목 중 1개만 판정 → 누락은 보류다. **여기가 `1/1 통과` 거짓 초록을 막는 자리다.**
#    뮤테이션: 결과 파일만 읽고 세면 pass=1·denominator=1·verdict=green 이 되어 빨개진다.
want "⑪ 항목 누락 → 보류·green 불가" '- [ ] a
- [ ] b
' 'pass - [ ] a — 확인
' pass=1 unparsed=1 held=1 denominator=1 verdict=held

# ⑫ 같은 항목에 판정이 둘 → 어느 것이 참인지 모른다 → 보류(+duplicate)
want "⑫ 중복 판정 → 보류" '- [ ] a
' 'pass - [ ] a — 확인
fail - [ ] a — 다시 보니 실패
' pass=0 fail=0 duplicate=1 held_unstepped=1 held=1 denominator=0 verdict=skip

# ⑬ 근거에 표식 문자열을 언급한 **정상 pass** 는 뒤집히지 않는다(표식은 항목 접두에서만).
#    뮤테이션: 표식 검색을 줄 전체로 되돌리면 held_marked=1·verdict=held 로 빨개진다.
want "⑬ 근거의 [칸 ③] 언급은 표식이 아니다" '- [ ] /pcs 렌더
' 'pass - [ ] /pcs 렌더 — 표식 [칸 ③] 없음, 크롬으로 직접 확인
' pass=1 held=0 held_marked=0 denominator=1 verdict=green

# ⑭ 체크리스트에 없는 항목을 지어내면 그 줄은 붙을 데가 없다 → unparsed
want "⑭ 체크리스트에 없는 판정 줄 → unparsed" '- [ ] a
' 'pass - [ ] a
pass - [ ] 내가 만든 항목
' pass=1 unparsed=1 held=1 verdict=held

# ⑮ 한 항목이 다른 항목의 **접두**여도 각자 제 판정을 받는다 (#467 2회차 P2).
#    뮤테이션: 매칭을 "첫 일치에서 break" 로 되돌리면 두 판정이 모두 짧은 항목에 붙어
#    duplicate=1·unparsed=1·verdict=held 로 빨개진다.
want "⑮ 접두 관계 항목 둘 → 각자 매칭" '- [ ] open page
- [ ] open page and click
' 'pass - [ ] open page — 열림 확인
pass - [ ] open page and click — 클릭까지 확인
' pass=2 unparsed=0 duplicate=0 held=0 denominator=2 verdict=green

echo "── 체크 모드 격자 ────────────────────────────────────────────────"

# ⑮ `없음` 절 → steppable 0 (스모크를 돌리지 않는다)
want "⑮ 없음 절 → steppable 0" '<!-- 형태 고정: `- [ ]` 체크박스 목록만 -->
없음
' - steppable=0 held_marked=0 open=0

# ⑯ 표식 줄만 있는 절도 steppable 0 — 크롬을 띄우면 안 된다.
want "⑯ 표식만 → steppable 0" '- [ ] [칸 ③] 실장비 드라이런
- [ ] [칸 ③] 또 하나
' - steppable=0 held_marked=2 open=2

# ⑰ 혼합 절 — 열린 일반 줄만 센다(`- [x]` 는 skipped).
want "⑰ 혼합 절" '- [ ] /pcs 렌더
- [ ] [칸 ③] 실장비
- [x] 이미 밟음
' - steppable=1 held_marked=1 skipped=1 open=2

echo "── 계약(usage·실행비트) ────────────────────────────────────────"

# ⑱ 인자 없음 → usage exit 64
PATH="$tmp/stub:$PATH" bash "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 64 ] && ok || bad "⑱ 인자 없음 exit $rc (기대 64)"

# ⑲ 결과 파일만 주고 `--checks` 를 빼면 exit 64 — 결과만 보고 세면 누락이 사라진다(P1-2).
: > "$tmp/result.txt"
PATH="$tmp/stub:$PATH" bash "$SUT" "$tmp/result.txt" >/dev/null 2>&1; rc=$?
[ "$rc" = 64 ] && ok || bad "⑲ --checks 없는 결과 모드 exit $rc (기대 64)"

# ⑳ 값 없는 `--checks` 가 마지막에 와도 무한루프가 아니라 즉시 64 (#467 P2-3 동형)
PATH="$tmp/stub:$PATH" bash "$SUT" --checks >/dev/null 2>&1; rc=$?
[ "$rc" = 64 ] && ok || bad "⑳ --checks 값 누락 exit $rc (기대 64)"

# ㉑ 파일 없음 → exit 66 (빈 집계를 정상값으로 내지 않는다)
out=$(PATH="$tmp/stub:$PATH" bash "$SUT" --checks "$tmp/nope.txt" 2>/dev/null); rc=$?
{ [ "$rc" = 66 ] && [ -z "$out" ]; } && ok || bad "㉑ 파일 없음 rc=$rc out=[$out] (기대 66·무출력)"

# ㉒ 실행 비트 — SKILL 5단계가 `$SCRIPTS/smoke-tally.sh` 로 직접 exec 한다(PR#173 함정).
[ -x "$SUT" ] && ok || bad "㉒ smoke-tally.sh 실행 비트 없음"

echo "smoke-tally.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
