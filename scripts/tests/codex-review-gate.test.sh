#!/usr/bin/env bash
# codex-review-gate.sh 픽스처 테스트 — 네트워크 무접속(codex 스텁). Plans/codex-native-review-gate.md (#134)
#   P1 → exit 1/BLOCKER · P2 만 → 0/WARN · P3 만 → 0/NIT · 항목 없음 → 0/CLEAN · 모델 오류 → 2 ·
#   타임아웃 → 2(손자 프로세스까지 종료) · codex 부재 → 2 · usage 64 · 스코프/프롬프트 인자 전달.
# bats 미도입 레포 — 순수 bash assert 관행.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/codex-review-gate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stub"
export STUB_LOG="$TMP/calls.log"
# codex 스텁 — 인자를 기록하고, STUB_MODE 에 따라 review.md(-o 경로)를 쓰거나 오류/행(hang)을 흉내낸다
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG:?}"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
case "${STUB_MODE:-p1}" in
  p1)    printf 'Summary.\n\nReview comment:\n\n- [P1] fail-open — scripts/x.sh:10\n  body\n- [P2] minor — scripts/y.sh:3\n' > "$out" ;;
  p2)    printf 'Summary.\n\n- [P2] minor — a.sh:1\n- [P2] minor2 — b.sh:2\n' > "$out" ;;
  p3)    printf 'Summary.\n\n- [P3] nit — a.sh:1\n' > "$out" ;;
  p0)    printf 'Summary.\n\n- [P0] critical — a.sh:1\n' > "$out" ;;
  selfref) printf 'Summary.\n\n- [P2] minor — a.sh:1\n' > "$out"
           # 리뷰어가 읽은 파일 내용이 --json 스트림(=events.jsonl)에 실리는 상황을 흉내낸다
           echo '{"type":"item.completed","item":{"type":"command_execution","output":"grep does not exist or you do not have access / not supported when using Codex / requires a newer version of Codex"}}' ;;
  clean) printf 'No issues found in the reviewed changes.\n' > "$out" ;;
  model) echo 'ERROR: unexpected status 404 Not Found: The model `gpt-5.5` does not exist or you do not have access to it.' >&2; exit 1 ;;
  hang)  sh -c 'sleep 30.31' & sleep 30.31 ;;   # 고유 마커 — 박스의 다른 sleep 과 안 겹치게
  fail)  exit 3 ;;
esac
STUB
chmod +x "$TMP/stub/codex"
export PATH="$TMP/stub:$PATH"
# 범위 검사용 진짜 git 레포(base 브랜치 + 1커밋 + 미커밋 변경)
R="$TMP/repo"; mkdir -p "$R"; git -C "$R" init -q; printf 'a\n' > "$R/f"; git -C "$R" add f
git -C "$R" -c user.name=t -c user.email=t@t commit -q -m base; git -C "$R" branch -q base
printf 'b\n' > "$R/f"; git -C "$R" -c user.name=t -c user.email=t@t commit -q -am change; printf 'c\n' > "$R/f"
cd "$R"
pass=0; fail=0
ok() { pass=$((pass + 1)); }; bad() { fail=$((fail + 1)); echo "  ✗ $*"; }
assert_eq() { [ "$2" = "$3" ] && ok || bad "$1 — 기대=$3 실제=$2"; }
run() { rc=0; last=$("$SUT" "$@" --out "$TMP/out" 2>"$TMP/err" | tail -1) || rc=$?; }

echo "[gate] 1) P1 → BLOCKER exit 1 · verdict 줄 · review.md"
STUB_MODE=p1 run --base base
assert_eq "P1 exit" "$rc" 1
case "$last" in "verdict=BLOCKER p1=1 p2=1 p3=0 model=gpt-5.6-sol secs="*) ok ;; *) bad "P1 verdict 줄: $last" ;; esac
[ -s "$TMP/out/review.md" ] && ok || bad "review.md 없음"
grep -q -- '--base base' "$STUB_LOG" && grep -q -- '-m gpt-5.6-sol' "$STUB_LOG" && grep -q 'model_reasoning_effort="medium"' "$STUB_LOG" && ok || bad "스코프/모델/effort 인자 미전달: $(tail -1 "$STUB_LOG")"
grep -q -- '--ephemeral --json -o' "$STUB_LOG" && grep -q "web_search" "$STUB_LOG" && ok || bad "ephemeral/json/절감 오버라이드 미전달"

echo "[gate] 2) P2 만 → WARN exit 0 · P3 만 → NIT · 항목 없음 → CLEAN"
HEADSHA=$(git rev-parse HEAD); STUB_MODE=p2 run --commit "$HEADSHA"; assert_eq "P2 exit" "$rc" 0; case "$last" in "verdict=WARN p1=0 p2=2 p3=0 "*) ok ;; *) bad "P2: $last" ;; esac
grep -q -- "--commit $HEADSHA" "$STUB_LOG" && ok || bad "--commit 미전달"
STUB_MODE=p3 run --uncommitted; assert_eq "P3 exit" "$rc" 0; case "$last" in "verdict=NIT p1=0 p2=0 p3=1 "*) ok ;; *) bad "P3: $last" ;; esac
STUB_MODE=clean run --base base; assert_eq "clean exit" "$rc" 0; case "$last" in "verdict=CLEAN p1=0 p2=0 p3=0 "*) ok ;; *) bad "clean: $last" ;; esac

echo "[gate] 3) --model/--effort 오버라이드 · --prompt 커스텀 스코프 · 스코프+프롬프트 동시 = usage"
STUB_MODE=clean run --base base --model gpt-5.6-terra --effort low
grep -q -- '-m gpt-5.6-terra' "$STUB_LOG" && grep -q 'model_reasoning_effort="low"' "$STUB_LOG" && ok || bad "오버라이드 미전달"
case "$last" in *"model=gpt-5.6-terra"*) ok ;; *) bad "verdict 줄 model: $last" ;; esac
STUB_MODE=clean run --prompt "계획 부합 검토"
grep -q '^exec review 계획 부합 검토 -m' "$STUB_LOG" && ok || bad "--prompt 미전달: $(tail -1 "$STUB_LOG")"
STUB_MODE=clean run --base base --prompt "계획 부합"
grep -q 'exec review Review ONLY the committed changes `git diff base...HEAD`' "$STUB_LOG" && ok || bad "--prompt+--base 범위 머리말 없음: $(tail -1 "$STUB_LOG" | cut -c1-120)"
grep -q -- 'code_mode_host' "$STUB_LOG" && bad "code_mode_host 를 끄면 리뷰어가 도구를 못 쓴다 — 넘기지 말 것" || ok
rc=0; "$SUT" >/dev/null 2>&1 || rc=$?; assert_eq "인자 없음 usage" "$rc" 64

echo "[gate] 4) 모델 오류 → 2 · NONE · 안내 문구 · codex 비정상 종료 → 2 · review.md 없음 → 2"
STUB_MODE=model run --base base; assert_eq "모델 오류 exit" "$rc" 2; case "$last" in "verdict=NONE "*) ok ;; *) bad "모델 오류 verdict: $last" ;; esac
grep -q "codex debug models" "$TMP/err" && grep -q "does not exist" "$TMP/err" && ok || bad "모델 오류 안내 없음: $(cat "$TMP/err")"
STUB_MODE=fail run --base base; assert_eq "codex exit 3 → 2" "$rc" 2
echo "[gate] 4b) 범위에 변경 없음 → 2(리뷰 미실행) · 리뷰어가 '볼 수 없음' 이라 답함 → 2 · 볼드 [P1] 도 항목"
: > "$STUB_LOG"; STUB_MODE=clean run --base HEAD; assert_eq "변경 없음 exit" "$rc" 2; [ ! -s "$STUB_LOG" ] && ok || bad "변경 없음인데 codex 호출됨"
STUB_MODE=clean run --commit 0000000000000000000000000000000000000000; assert_eq "없는 커밋 exit" "$rc" 2
git -C "$R" stash -q; STUB_MODE=clean run --uncommitted; assert_eq "미커밋 없음 exit" "$rc" 2; git -C "$R" stash pop -q
printf 'No findings are reported because the workspace execution tool was unavailable, so commit X could not be inspected. This verdict is therefore not a substantive correctness assessment.\n' > "$TMP/unable.md"
cat > "$TMP/stub/codex2" <<'S2'
#!/bin/sh
prev=""; for a in "$@"; do [ "$prev" = "-o" ] && cp "${UNABLE:?}" "$a"; prev="$a"; done
S2
chmod +x "$TMP/stub/codex2"; cp "$TMP/stub/codex2" "$TMP/stub/codex.bak"; mv "$TMP/stub/codex" "$TMP/stub/codex.real"; mv "$TMP/stub/codex2" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "'볼 수 없음' exit" "$rc" 2
mv "$TMP/stub/codex.real" "$TMP/stub/codex"
printf -- '- **[P1]** bold — a.sh:1\n\n(참고: [P1] 표기는 항목이 아님)\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "볼드 [P1] BLOCKER" "$rc" 1; case "$last" in "verdict=BLOCKER p1=1 "*) ok ;; *) bad "볼드 P1 집계: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-2) 한국어 '판정 근거 없음' 응답 → CLEAN 아니라 미산출(#207 — fail-open 게이트 재발)"
# #207 실측 재현: diff 를 못 본 리뷰어가 항목([Pn]) 없이 "판정할 근거가 없다" 산문만 남기면
# 옛 분류는 이걸 CLEAN 으로 읽었다(머지 게이트의 절반이 fail-open). 미산출(exit 2)이어야 한다.
printf '판정 근거로 지정된 diff가 메시지에 포함되어 있지 않아 변경 내용과 수용 기준 충족 여부를 검증할 수 없습니다. 명시된 금지사항에 따라 로컬 git 명령으로 diff를 조회하지 않았으며, 따라서 CLEAN으로 판정할 근거도 없습니다.\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "한국어 '판정 근거 없음' exit" "$rc" 2; case "$last" in "verdict=NONE "*) ok ;; *) bad "한국어 판정불가 verdict(CLEAN 으로 샘): $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-3) 한국어 진짜 CLEAN(항목 0·근거 있음)은 여전히 CLEAN — 과잉 차단 금지(#207)"
# 4b-2 의 분류를 넓혀 잡다 "판정"·"검증" 같은 낱말만으로 걸면, 실제로 다 보고 결함이
# 없다고 답한 정상 CLEAN 까지 미산출로 떨어뜨린다 — 그러면 이 이슈가 막으려던 fail-open
# 을 반대편(과잉 fail-closed)에서 깨뜨린다.
printf '이 변경 사항을 검토했습니다. 추가된 함수의 예외 처리와 테스트를 확인했으며 결함을 발견하지 못했습니다. 판정: CLEAN\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "한국어 진짜 CLEAN 과잉차단 방지" "$rc" 0; case "$last" in "verdict=CLEAN "*) ok ;; *) bad "한국어 진짜 CLEAN 오탐(미산출로 샘): $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-4) 사전 리뷰 WARN 반증(#207): '근거 없는 폴백은 없습니다' 류의 정상 CLEAN 은 과잉 차단되지 않는다"
# 4b-2 의 정규식을 "근거...없" 만으로 넓게 잡으면, 이 레포 리뷰 기준(silent-failure-hunter:
# 근거 없는 폴백 지적)을 정상적으로 통과한 CLEAN 리뷰가 "근거 없는 폴백은 없습니다" 같은
# 문장을 남길 때 오탐한다(사전 리뷰가 실측 WARN). 판정 동사(판정/검증/확인)가 근처에 없는
# "근거...없" 는 걸리지 않아야 한다.
printf '이 diff 는 근거 없는 폴백을 추가하지 않았습니다. 결함을 발견하지 못했습니다. CLEAN
' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "'근거 없는 폴백은 없습니다' 과잉차단 방지" "$rc" 0; case "$last" in "verdict=CLEAN "*) ok ;; *) bad "'근거 없는 폴백' 정상 서술 오탐: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-5) 사전 리뷰 WARN 반증(#207): '판정 불가능할 정도로 미미합니다' 류의 정도 서술은 과잉 차단되지 않는다"
# "(판정|검증) 불가능/불가" 를 허용하면 "부작용은 판정 불가능할 정도로 미미합니다" 처럼
# 정도를 서술하는 정상 CLEAN 까지 미산출로 떨어진다(사전 리뷰가 실측 WARN) — "할 수 없"
# 처럼 판정 동사에 직접 붙는 형태만 잡아야 한다.
printf '이 변경의 부작용은 판정 불가능할 정도로 미미합니다. 결함을 발견하지 못했습니다. CLEAN
' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "'판정 불가능할 정도로' 과잉차단 방지" "$rc" 0; case "$last" in "verdict=CLEAN "*) ok ;; *) bad "'판정 불가능할 정도로' 정상 서술 오탐: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-6) 반송 격자(#207 attempt4, f1) — [P1] 항목의 설명문에 '누락' 이 있어도 BLOCKER 로 산다"
# 옛 분류는 우선순위 집계보다 먼저 본문 전체를 grep 해, 정당한 [P1] 의 설명문이 산문
# 패턴에 걸리면 verdict=NONE 으로 지워버렸다(폴백이 CLEAN 을 내면 BLOCKER 가 조용히 증발).
printf -- '- [P1] 필수 변경이 diff에서 누락 — scripts/foo.sh:12\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "f1 [P1] 설명문 '누락' 은 BLOCKER 로 산다" "$rc" 1; case "$last" in "verdict=BLOCKER p1=1 "*) ok ;; *) bad "f1: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-7) 반송 격자(f2) — '누락은 없습니다'(부정문) 는 CLEAN 으로 남는다(과잉 차단 금지)"
printf 'CLEAN. diff에 테스트 누락은 없습니다. 수용 기준을 모두 충족합니다.\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "f2 '누락은 없습니다' CLEAN" "$rc" 0; case "$last" in "verdict=CLEAN "*) ok ;; *) bad "f2: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-8) 반송 격자(f3) — 일부만 정적 검증 불가라 밝힌 정상 CLEAN 은 과잉 차단되지 않는다"
printf 'CLEAN. 나머지는 런타임 동작이라 정적으로는 검증할 수 없지만, 변경분 자체는 부합합니다.\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "f3 부분 서술 CLEAN" "$rc" 0; case "$last" in "verdict=CLEAN "*) ok ;; *) bad "f3: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-9) 반송 격자(f4) — 동의어('검토') + '정보만으로' 축이 함께면 미산출로 차단된다"
printf '제공된 정보만으로 변경 내용을 검토할 수 없습니다.\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "f4 '검토할 수 없습니다' 미산출" "$rc" 2; case "$last" in "verdict=NONE "*) ok ;; *) bad "f4: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-10) 반송 격자(f7) — 한 속성만 못 쟀다는 곁다리 '제공된 정보만으로' 는 결론(결함 없음)이 있으면 과잉 차단되지 않는다(#207 round2 P2)"
# round2 검증자 실측: "제공된 정보만으로 성능은 검증할 수 없습니다. 코드 변경은 검토했고
# 결함은 없습니다." 처럼 리뷰가 실제로 diff 를 보고 결론(결함 없음)까지 낸 정상 CLEAN 인데,
# '제공된...만으로' 가 응답 어디에 있든 매치돼 CLEAN → NONE 으로 뒤집혔다. 결함이 새지는
# 않지만(NONE 은 폴백행이라 fail-closed) closeout 이 불필요하게 막힌다.
printf '제공된 정보만으로 성능은 검증할 수 없습니다. 코드 변경은 검토했고 결함은 없습니다.\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "f7 결함없음 결론 있는 '정보만으로' 과잉차단 방지" "$rc" 0; case "$last" in "verdict=CLEAN "*) ok ;; *) bad "f7: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-11) 반송 격자(f8) — 결론 없이 리뷰 전체가 '제공된 정보만으로' 판정 불가로 끝나면 여전히 미산출(f7 의 반증)"
# f7 의 완화가 과해지면 진짜 미산출(리뷰 전체가 실패)까지 CLEAN 으로 새는 반대 방향
# fail-open 이 재발한다 — 결론 문장(결함 없음/CLEAN 류)이 없는 순수 '못 봤다' 응답은
# 계속 차단돼야 한다.
printf '제공된 정보만으로는 diff 내용을 확인할 수 없어 판정할 수 없습니다.\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "f8 결론 없는 '정보만으로' 는 계속 미산출" "$rc" 2; case "$last" in "verdict=NONE "*) ok ;; *) bad "f8: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-12) 판정-결론 격자(#207 round3 attempt3) — REVIEW_CONCLUDED 는 '부합'·'CLEAN' 의 긍정 단정만 결론으로 센다"
# 판정 규칙(말로): 항목([Pn]) 0건에 캐비엇(BASIS_ABSENT_CAVEAT)·판정불능 동사(CANNOT_VERB)가
# 함께 있을 때만 "미산출 후보"다. 그 상태에서 리뷰 본문이 이미 긍정 단정 결론을 냈으면
# (REVIEW_CONCLUDED — '결함 없'·'이상 없'·'문제 없'·'부합한다/합니다/함'·bare CLEAN) 캐비엇은
# 곁다리로 보고 CLEAN 을 유지한다. 그런데 '부합'·'CLEAN' 두 토큰은 의문형·부정형 문장 안에도
# 맨몸으로 나타난다(부합하는지·부합하지 않·CLEAN 이라고/인지) — 그 경우는 결론이 아니라
# 오히려 "못 봤다"는 뜻이므로 결론으로 세면 안 된다(REVIEW_CONCLUDED_NEGATED 로 되돌린다).
# want=NONE ⇢ verdict=NONE(exit 2) · want=CLEAN ⇢ verdict=CLEAN(exit 0). 각 행은 별도 UNABLE
# 파일로 돌려 독립 검증한다(grep -q 는 파일 어디에서든 매치되면 참이라 문장을 줄로 나눠도 무방).
grid_row() {
  name="$1"; want="$2"; printf '%s' "$3" > "$TMP/unable.md"
  mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
  case "$want" in
    NONE)  UNABLE="$TMP/unable.md" run --base base; assert_eq "격자: $name" "$rc" 2
           case "$last" in "verdict=NONE "*) ok ;; *) bad "격자[$name] want=NONE 실제: $last" ;; esac ;;
    CLEAN) UNABLE="$TMP/unable.md" run --base base; assert_eq "격자: $name" "$rc" 0
           case "$last" in "verdict=CLEAN "*) ok ;; *) bad "격자[$name] want=CLEAN 실제: $last" ;; esac ;;
  esac
  mv "$TMP/stub/codex.real" "$TMP/stub/codex"
}
# name                                              | want  | input
grid_row "의문 — 부합하는지 확인할 수 없다(round3 BLOCKER 원문)" NONE \
  '제공된 정보만으로 변경 사항이 계획에 부합하는지 확인할 수 없습니다.'
grid_row "의문 — 부합하는지 판단할 수 없다" NONE \
  '제공된 정보만으로는 계획에 부합하는지 판단할 수 없습니다.'
grid_row "부정 — 부합하지 않는다(캐비엇 동반, 결론 아님)" NONE \
  '제공된 정보만으로는 판단할 수 없습니다만, 이 변경은 계획에 부합하지 않습니다.'
grid_row "CLEAN 부정 — CLEAN 이라고 볼 수 없다" NONE \
  '제공된 정보만으로는 판정할 수 없습니다.
계획 부합 여부가 CLEAN 이라고 볼 수 없습니다.'
grid_row "CLEAN 부정 — CLEAN 인지 확신할 수 없다" NONE \
  '제공된 정보만으로는 검증할 수 없습니다.
이 변경이 CLEAN 인지 확신할 수 없습니다.'
grid_row "긍정 단정 — 부합한다(캐비엇 동반, 결론 유지)" CLEAN \
  '제공된 정보만으로는 부하 테스트를 확인할 수 없습니다. 이 변경은 계획에 부합한다.'
grid_row "긍정 단정 — 부합합니다(캐비엇 동반, 결론 유지)" CLEAN \
  '제공된 정보만으로는 검증할 수 없습니다. 이 변경은 계획에 부합합니다.'
grid_row "긍정 단정 — 부합함(캐비엇 동반, 결론 유지)" CLEAN \
  '제공된 정보만으로는 확인할 수 없습니다. 구현은 계획에 부합함.'
grid_row "긍정 단정 — 이상 없음(캐비엇 동반, 결론 유지)" CLEAN \
  '제공된 정보만으로는 검토할 수 없습니다. 이상 없음.'
grid_row "긍정 단정 — 문제 없습니다(캐비엇 동반, 결론 유지)" CLEAN \
  '제공된 정보만으로는 판정할 수 없습니다. 문제 없습니다.'
grid_row "긍정 단정 — bare CLEAN(캐비엇 동반, 결론 유지)" CLEAN \
  '제공된 정보만으로는 검증할 수 없습니다. 이 변경은 CLEAN 입니다.'
unset -f grid_row

echo "[gate] 4c) [P0] 도 BLOCKER · events 의 오류 문자열은 오탐 안 냄(codex stderr 만 본다, #137)"
STUB_MODE=p0 run --base base; assert_eq "P0 exit" "$rc" 1; case "$last" in "verdict=BLOCKER p1=1 p2=0 p3=0 "*) ok ;; *) bad "P0 집계: $last" ;; esac
STUB_MODE=selfref run --base base; assert_eq "events 자기참조 exit" "$rc" 0; case "$last" in "verdict=WARN p1=0 p2=1 "*) ok ;; *) bad "events 자기참조로 오탐: $last" ;; esac

echo "[gate] 5) 타임아웃 → 2 · 손자 프로세스(sleep 30.31)까지 종료"
pkill -f 'sleep 30.31' 2>/dev/null; sleep 0.2   # 이전 실행 잔재 제거(판정 오염 방지)
STUB_MODE=hang CODEX_GATE_TIMEOUT=3 run --base base
assert_eq "타임아웃 exit" "$rc" 2; case "$last" in "verdict=NONE "*"secs=3") ok ;; *) bad "타임아웃 verdict: $last" ;; esac
sleep 1; [ -z "$(pgrep -f 'sleep 30.31' 2>/dev/null)" ] && ok || bad "타임아웃 뒤 손자 sleep 30.31 생존"

echo "[gate] 6) codex 부재 → 2"
rc=0; PATH="/usr/bin:/bin" "$SUT" --base base >/dev/null 2>&1 || rc=$?; assert_eq "codex 부재 exit" "$rc" 2

echo "codex-review-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
