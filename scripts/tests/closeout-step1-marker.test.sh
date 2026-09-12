#!/usr/bin/env bash
# closeout-step1-marker.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 대체).
#
# 이 헬퍼가 답하는 질문은 하나다: **③-1(1단계 마감 검증)을 건너뛰어도 되는가.**
# 옛 마커표의 한 줄("`마감 검증:` 코멘트가 있으면 건너뜀")이 **세 방향으로** 거짓일 수
# 있었고(#271), 그 셋이 곧 이 파일의 세 축이다:
#   (A) 마커가 `⚠ 보류` — 1단계를 통과하지 **못했다**는 기록이라 완료 마커가 아니다
#   (B) 마커가 현재 head 커밋보다 이르다 — 옛 코드에 대한 판정(#171 규칙의 1단계 판)
#   (C) 마커가 최신 반송 마커보다 앞이다 — 반송 뒤 새 커밋 없이 ✅ 만 찍힌 창
# 셋은 **AND** 다: (B) 하나만으로는 (A)·(C) 가 안 닫힌다(둘 다 head 시각이 그대로라
# (B) 기준으로 "신선" 하다). 그 사실을 아래 뮤테이션 격자의 `want` 열이 못박는다.
#
# bats 미도입 레포라 bounce-state.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/closeout-step1-marker.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# ── 코멘트 픽스처 조립 ──────────────────────────────────────────────────
# 토큰 열 → `[{body,createdAt}]`. createdAt 은 인덱스 순으로 1시간씩 늘어난다
# (배열 순서 = 생성 순서라는 pr-comments.sh 의 계약과 같은 형상).
#   S = `마감 검증: ✅ CLEAN`      (1단계 완료 마커)
#   W = `마감 검증: ⚠ 보류 — …`   (③-1 ⓑ 보류 — 완료 마커가 아니다)
#   B = 반송 마커(`재디스패치: #271 — …`)
#   V = `머지 판정: ✅ …`          (워커 완결 — 반송을 푸는 판정)
#   X = 무관한 코멘트
mkfix() {  # mkfix <파일> <토큰들…>
  local out="$1"; shift
  local t b bodies=""
  for t in "$@"; do
    case "$t" in
      S) b='마감 검증: ✅ CLEAN' ;;
      W) b='마감 검증: ⚠ 보류 — 정책 질문' ;;
      B) b='재디스패치: #271 — 마감 검증 BLOCKER(코드 회귀)' ;;
      V) b='머지 판정: ✅ 머지 가능(재검증)' ;;
      X) b='검증자 리뷰: BLOCKER 0' ;;
      *) echo "  ✗ mkfix 알 수 없는 토큰: [$t]"; return 1 ;;
    esac
    bodies="$bodies$b
"
  done
  printf '%s' "$bodies" | jq -Rs 'split("\n") | map(select(length > 0)) | to_entries
    | map({body: (.value + "\n<!-- bodat:worker -->"),
           createdAt: "2026-09-11T0\(.key):00:00Z"})' > "$out"
}

# run <sut> <name> <want: skip|verify|fail> <head_at> <토큰들…>
run() {
  local sut="$1" name="$2" want="$3" head_at="$4"; shift 4
  mkfix "$tmp/fix.json" "$@" || { fail=$((fail + 1)); return; }
  local out rc=0 verdict=ok
  out=$(STEP1_COMMENTS_FILE="$tmp/fix.json" STEP1_HEAD_AT="$head_at" \
    bash "$sut" owner/repo 5 2>/dev/null) || rc=$?
  if [ "$want" = fail ]; then
    { [ "$rc" != 0 ] && [ -z "$out" ]; } || verdict=no
  else
    { [ "$rc" = 0 ] && [ "$out" = "$want" ]; } || verdict=no
  fi
  if [ "$verdict" = ok ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name — 기대=$want 실제 rc=$rc out=[$out]"
  fi
}

# ── 1) 본체 격자 ────────────────────────────────────────────────────────
# head_at 은 "00:00" 이면 첫 코멘트보다 이르고(= 마커가 신선), "09:00" 이면 모든
# 코멘트보다 늦다(= 마커가 낡음 — 새 커밋이 올라온 형상).
echo "[격자] 1단계 마커 판정"
run "$SUT" "마커 없음"                     verify "2026-09-11T00:00:00Z" X
run "$SUT" "✅ 마커 · head 이전 · 반송 없음" skip   "2026-09-11T00:00:00Z" X S
run "$SUT" "(B) ✅ 마커 · head 가 더 늦다"   verify "2026-09-11T09:00:00Z" X S
run "$SUT" "(A) ⚠ 보류만 있다"              verify "2026-09-11T00:00:00Z" X W
run "$SUT" "(A) ⚠ 보류 뒤 ✅ — 가장 늦은 것이 ✅" skip "2026-09-11T00:00:00Z" W S
run "$SUT" "(A) ✅ 뒤 ⚠ 보류 — 더 늦은 ⚠ 이 덮는다" verify "2026-09-11T00:00:00Z" S W
run "$SUT" "(A) ✅ → ⚠ → ✅ — 마지막이 ✅"   skip   "2026-09-11T00:00:00Z" S W S
run "$SUT" "(C) ✅ 뒤 반송 · 새 커밋 없음"   verify "2026-09-11T00:00:00Z" S B V
run "$SUT" "(C) 반송 뒤 새 ✅ 마커"          skip   "2026-09-11T00:00:00Z" S B V S
run "$SUT" "(B)+(C) 반송 뒤 ✅ 이나 head 가 늦다" verify "2026-09-11T09:00:00Z" S B V S
run "$SUT" "코멘트 0건"                     verify "2026-09-11T00:00:00Z"
# 동초 — GitHub 코멘트 시각은 초 단위라 head 와 마커가 같은 초에 걸릴 수 있다.
# `<=` 라 통과해야 한다(정상 판정을 막지 않는다 — finish-classify 의 ✅ 갈래와 같은 방향).
run "$SUT" "head 와 마커가 동초"            skip   "2026-09-11T01:00:00Z" X S

# ── 2) 증명 실패는 전부 exit 1 ─────────────────────────────────────────
echo "[fail-closed] 증명 실패"
run "$SUT" "head 시각 형상 깨짐"            fail   "not-a-date"           X S
run "$SUT" "head 시각 빈 문자열은 실조회로 안 샌다" fail ""                X S
# ↑ 빈 STEP1_HEAD_AT 은 오버라이드 미지정과 구분이 안 되므로 실조회로 간다 —
#   gh 가 없는 이 테스트에서 pr-head-at.sh 는 비0이라 결과는 같은 exit 1 이다.
rc=0; out=$(bash "$SUT" owner/repo 2>/dev/null) || rc=$?
{ [ "$rc" != 0 ] && [ -z "$out" ]; } && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); echo "  ✗ 인자 누락→비정상 종료·무출력 이어야 한다 rc=$rc out=[$out]"; }
rc=0; out=$(STEP1_COMMENTS_FILE="$tmp/none.json" STEP1_HEAD_AT="2026-09-11T00:00:00Z" \
  bash "$SUT" owner/repo 5 2>/dev/null) || rc=$?
{ [ "$rc" != 0 ] && [ -z "$out" ]; } && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); echo "  ✗ 코멘트 파일 부재→exit 1 이어야 한다 rc=$rc out=[$out]"; }
: > "$tmp/empty.json"
rc=0; out=$(STEP1_COMMENTS_FILE="$tmp/empty.json" STEP1_HEAD_AT="2026-09-11T00:00:00Z" \
  bash "$SUT" owner/repo 5 2>/dev/null) || rc=$?
{ [ "$rc" != 0 ] && [ -z "$out" ]; } && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); echo "  ✗ 빈 코멘트 파일→exit 1(코멘트 0건 '[]' 와 구분) rc=$rc out=[$out]"; }
mkfix "$tmp/fix.json" X S
rc=0; out=$(STEP1_COMMENTS_FILE="$tmp/fix.json" STEP1_HEAD_AT="2026-09-11T00:00:00Z" \
  STEP1_BOUNCE_INDEX="열두번째" bash "$SUT" owner/repo 5 2>/dev/null) || rc=$?
{ [ "$rc" != 0 ] && [ -z "$out" ]; } && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); echo "  ✗ 반송 인덱스 형상 깨짐→exit 1 rc=$rc out=[$out]"; }

# ── 3) 반송 인덱스를 bounce-state.sh 한 자리에서 받는지 ────────────────
# 마커 집합을 여기 베끼지 않았다는 것을 실행으로 잰다: `bounce-state.sh --marker-index`
# 를 인자 캡처 스텁으로 갈아끼우고, 그 값이 실제로 (C) 판정에 쓰이는지 본다.
echo "[SSOT] 반송 인덱스는 bounce-state.sh --marker-index 에서 온다"
mkdir -p "$tmp/sc"
cp "$SUT" "$tmp/sc/closeout-step1-marker.sh"
cp "$DIR/pr-comments.sh" "$DIR/pr-head-at.sh" "$tmp/sc/"
cat > "$tmp/sc/bounce-state.sh" <<'CAP'
#!/bin/sh
printf '%s\n' "$*" >> "$CAP_FILE"
printf '%s\n' "$FAKE_INDEX"
CAP
chmod +x "$tmp/sc/bounce-state.sh"
mkfix "$tmp/fix.json" S B V S   # ✅(0) 반송(1) 머지판정(2) ✅(3)
# 스텁이 "반송 마커는 인덱스 2" 라고 답하면 마지막 ✅(인덱스 3)는 그보다 뒤 → skip
out=$(CAP_FILE="$tmp/cap" FAKE_INDEX=2 STEP1_COMMENTS_FILE="$tmp/fix.json" \
  STEP1_HEAD_AT="2026-09-11T00:00:00Z" bash "$tmp/sc/closeout-step1-marker.sh" owner/repo 5 2>/dev/null)
out2=$(CAP_FILE="$tmp/cap" FAKE_INDEX=9 STEP1_COMMENTS_FILE="$tmp/fix.json" \
  STEP1_HEAD_AT="2026-09-11T00:00:00Z" bash "$tmp/sc/closeout-step1-marker.sh" owner/repo 5 2>/dev/null)
if [ "$out" = skip ] && [ "$out2" = verify ] \
   && grep -qF -- '--marker-index owner/repo 5' "$tmp/cap"; then
  pass=$((pass + 1))
  echo "  ✓ --marker-index 호출값이 (C) 판정을 뒤집는다(2→skip · 9→verify)"
else
  fail=$((fail + 1))
  echo "  ✗ 반송 인덱스 배선 — out=[$out] out2=[$out2] cap='$(cat "$tmp/cap" 2>/dev/null)'"
fi

# ── 4) 뮤테이션 방증 ────────────────────────────────────────────────────
# 세 축을 **각각** 옛 동작(마커표 한 줄)으로 되돌린 사본 셋을 만들어, 서로 **다른** 칸이
# 뒤집히는지 격자로 잰다. 한 축이 다른 축을 대신 막아 주고 있으면 여기서 드러난다.
#   MUT-A = 가장 늦은 `마감 검증:` 이 ✅ 인지를 묻지 않는다 — 옛 마커표 그대로
#   MUT-B = head 신선도 제거(항상 신선으로 취급)
#   MUT-C = 반송 선후 제거
echo "[뮤테이션] 세 축이 각각 혼자 지키는 칸"
# 뮤턴트는 형제 헬퍼(bounce-state.sh·pr-comments.sh·pr-head-at.sh)가 같이 있는
# 디렉토리에 둔다 — SUT 가 $SCRIPT_DIR 로 그것들을 부르므로, 없으면 축과 무관하게
# 전건 exit 1 이 되어 격자가 아무것도 못 잰다.
mkdir -p "$tmp/mut"
cp "$DIR/bounce-state.sh" "$DIR/pr-comments.sh" "$DIR/pr-head-at.sh" "$tmp/mut/"
muta="$tmp/mut/muta.sh"; mutb="$tmp/mut/mutb.sh"; mutc="$tmp/mut/mutc.sh"
sed -E 's@^ *elif \(\(\.\[\$si\]\.body.*# MUT-A.*@    elif false then "verify"@' "$SUT" > "$muta"
sed -E 's@^ *elif \$h <= \$m then "skip".*# MUT-B.*@        elif true then "skip"@' "$SUT" > "$mutb"
sed -E 's@^ *elif \(\$bi != "none".*# MUT-C.*@    elif false then "verify"@' "$SUT" > "$mutc"
anchor_fail=0
for mpair in "MUT-A:$muta" "MUT-B:$mutb" "MUT-C:$mutc"; do
  mname="${mpair%%:*}"; mfile="${mpair#*:}"
  n=$(diff <(cat "$SUT") <(cat "$mfile") | grep -c '^<') || true
  if [ "$n" != 1 ]; then
    anchor_fail=1
    echo "  ✗ 뮤테이션 앵커($mname) 가 정확히 1줄을 안 바꿨다(바뀐 줄=$n) — 방증이 의미를 잃었다"
  fi
done
[ "$anchor_fail" = 0 ] && pass=$((pass + 1)) || fail=$((fail + 1))

# ax <name> <원본> <MUT-A> <MUT-B> <MUT-C> <head_at> <토큰들…>
ax_pass=0; ax_fail=0
ax() {
  local name="$1" w0="$2" wa="$3" wb="$4" wc="$5" head_at="$6"; shift 6
  local sut want n
  for n in "orig:$SUT:$w0" "MUT-A:$muta:$wa" "MUT-B:$mutb:$wb" "MUT-C:$mutc:$wc"; do
    sut=$(printf '%s' "$n" | cut -d: -f2); want=$(printf '%s' "$n" | cut -d: -f3)
    mkfix "$tmp/fix.json" "$@" || { ax_fail=$((ax_fail + 1)); return; }
    local out rc=0
    out=$(STEP1_COMMENTS_FILE="$tmp/fix.json" STEP1_HEAD_AT="$head_at" \
      bash "$sut" owner/repo 5 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then
      ax_pass=$((ax_pass + 1))
    else
      ax_fail=$((ax_fail + 1))
      echo "  ✗ ${n%%:*} [$name] 기대=$want 실제 rc=$rc out=[$out]"
    fi
  done
}
#   이름                                원본    MUT-A   MUT-B   MUT-C   head_at
ax "(A) ⚠ 보류만"                       verify  skip    verify  verify  "2026-09-11T00:00:00Z" X W
ax "(A) ✅ 뒤 더 늦은 ⚠"                 verify  skip    verify  verify  "2026-09-11T00:00:00Z" S W
ax "(B) ✅ 가 head 보다 이르다"          verify  verify  skip    verify  "2026-09-11T09:00:00Z" X S
ax "(C) ✅ 뒤 반송·새 커밋 없음"         verify  verify  verify  skip    "2026-09-11T00:00:00Z" S B V
ax "정상(건너뜀)"                        skip    skip    skip    skip    "2026-09-11T00:00:00Z" X S
ax "마커 없음"                           verify  verify  verify  verify  "2026-09-11T00:00:00Z" X
if [ "$ax_fail" = 0 ]; then
  pass=$((pass + 1))
  echo "  ✓ 뮤테이션 방증: 세 축이 서로 겹치지 않는다 — (A)는 MUT-A 만, (B)는 MUT-B 만, (C)는 MUT-C 만 뒤집는다(ax_pass=$ax_pass)"
else
  fail=$((fail + 1))
  echo "  ✗ 뮤테이션 방증 실패 — ax_pass=$ax_pass ax_fail=$ax_fail"
fi

echo "closeout-step1-marker.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
