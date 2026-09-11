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
# 프롬프트 뒤에 응답 계약(구조 줄 형식)이 덧붙으므로 지시문은 argv 첫 줄로 끝난다(4b-3 이 계약문을 문다)
grep -q '^exec review 계획 부합 검토$' "$STUB_LOG" && ok || bad "--prompt 미전달: $(head -1 "$STUB_LOG")"
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

echo "[gate] 4b-2) 응답 계약(구조 신호) — --prompt 호출은 리뷰어의 고정 형식 줄로만 판정한다(#207 재심 (c))"
# 이 이슈는 세 라운드를 **한국어 산문 정규식**으로 "리뷰어가 결론을 냈는가"를 가리려다 태웠다
# (round2 캐비엇 어형 · round3 '부합하는지' · round4 '부합함을' — 어형은 닫히지 않는다).
# 재심 결정(c): 산문을 판정 입력에서 **빼고**, 프롬프트가 요구한 고정 형식 줄의 유무로 가른다.
#   구조 줄 있음 → 그 값대로(reviewed = 항목 집계로 판정, no-basis = 미산출)
#   구조 줄 없음/형식 깨짐/위치 아님 → verdict=NONE(exit 2, fail-closed)
# 위치 = 꼬리에서 빈 줄·닫는 코드펜스만 벗기고 남은 **마지막 한 줄**(아래 위치 격자가 전수 단언).
# 이 격자는 (구조 줄 있음/없음) × (CLEAN·발견·긍정 산문·부정 산문·빈 출력·깨진 형식) 을
# `want` 열로 전수 단언한다 — 개별 반례만 차례로 닫는 접근(PR#202 교훈)을 쓰지 않는다.
# 계약은 `--prompt` 호출에만 붙는다(내장 스코프 리뷰는 프롬프트를 실을 자리가 없다) — 그래서
# 모든 행을 `--base base --prompt` 로 돌린다. 비계약 경로의 회귀는 4b-3 에서 따로 문다.
srow() {
  name="$1"; want="$2"; printf '%s' "$3" > "$TMP/unable.md"
  mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
  UNABLE="$TMP/unable.md" run --base base --prompt "계획 부합 검토"
  case "$want" in
    NONE)    assert_eq "격자: $name" "$rc" 2; case "$last" in "verdict=NONE "*)    ok ;; *) bad "격자[$name] want=NONE 실제: $last" ;; esac ;;
    CLEAN)   assert_eq "격자: $name" "$rc" 0; case "$last" in "verdict=CLEAN "*)   ok ;; *) bad "격자[$name] want=CLEAN 실제: $last" ;; esac ;;
    BLOCKER) assert_eq "격자: $name" "$rc" 1; case "$last" in "verdict=BLOCKER "*) ok ;; *) bad "격자[$name] want=BLOCKER 실제: $last" ;; esac ;;
    WARN)    assert_eq "격자: $name" "$rc" 0; case "$last" in "verdict=WARN "*)    ok ;; *) bad "격자[$name] want=WARN 실제: $last" ;; esac ;;
  esac
  mv "$TMP/stub/codex.real" "$TMP/stub/codex"
}

# ── 구조 줄 있음(reviewed) ──────────────────────────────────────────────────
# 과잉 차단 반증(이슈 Test plan 의 명시 요구): 구조 줄을 갖춘 진짜 CLEAN 은 캐비엇 문장이
# 섞여 있어도 CLEAN 이다 — round2 가 고친 f7(곁다리 캐비엇)이 여기서 산문 판정 없이 유지된다.
srow "구조 줄 reviewed + 발견 0 = 진짜 CLEAN" CLEAN \
  '변경 전체를 읽고 수용 기준과 대조했습니다. 결함 없음.
REVIEW_STATUS: reviewed'
srow "구조 줄 reviewed + 한 속성만 못 쟀다는 캐비엇 동반(과잉 차단 금지, round2 f7)" CLEAN \
  '제공된 정보만으로 성능은 검증할 수 없습니다. 코드 변경은 검토했고 결함은 없습니다.
REVIEW_STATUS: reviewed'
srow "구조 줄 reviewed + '부합하는지 확인할 수 없다' 문장이 섞인 부분 서술(과잉 차단 금지)" CLEAN \
  '런타임 동작이 계획에 부합하는지 확인할 수 없지만, 변경분 자체는 수용 기준을 충족합니다.
REVIEW_STATUS: reviewed'
srow "구조 줄 reviewed + [P1] 발견 = BLOCKER" BLOCKER \
  '- [P1] 필수 변경이 diff에서 누락 — scripts/foo.sh:12
REVIEW_STATUS: reviewed'
srow "구조 줄 reviewed + [P2] 발견 = WARN" WARN \
  '- [P2] 사소한 편차 — scripts/foo.sh:12
REVIEW_STATUS: reviewed'
srow "구조 줄 reviewed 가 닫는 코드펜스 앞(꼬리 artifact 만 벗기면 마지막 한 줄)" CLEAN \
  '```
결함 없음.
REVIEW_STATUS: reviewed
```'

# ── 계약 줄의 **위치**: 꼬리 artifact 만 벗기고 남은 마지막 한 줄이어야 한다 ──
# attempt4 반송(#207): 판정 창이 "빈 줄을 지운 뒤의 마지막 3줄"이라 계약 줄 뒤에 임의 산문이
# 두 줄까지 와도 통과했다 — 허용하려던 것(빈 줄)은 파이프라인 첫 단계가 이미 지웠고, 실제로
# 통과한 것(산문)은 계약이 금지한 것이다. 그래서 **"못 봤다"고 스스로 적은 응답이 CLEAN** 으로
# 머지 게이트를 지났다. 아래 6행이 창의 정의를 전수로 못박는다: 꼬리에서 벗기는 것은 빈 줄과
# 닫는 코드펜스**뿐**이고, 그 뒤 남은 마지막 한 줄이 계약 줄이어야 한다.
srow "계약 줄 뒤 산문 1줄 = 계약 위반(미산출)" NONE \
  'REVIEW_STATUS: reviewed
Please re-run with repository access.'
srow "계약 줄 뒤 산문 2줄 = 계약 위반(attempt4 반송 원문 픽스처)" NONE \
  'REVIEW_STATUS: reviewed
I could not inspect the diff because the execution tool was unavailable.
Please re-run with repository access.'
srow "계약 줄 + 뒤따르는 빈 줄(꼬리 artifact — 판정 유지)" CLEAN \
  '결함 없음.
REVIEW_STATUS: reviewed

'
srow "계약 줄 + 닫는 코드펜스(꼬리 artifact — 판정 유지)" CLEAN \
  '결함 없음.
REVIEW_STATUS: reviewed
```'
srow "계약 줄 + 빈 줄 + 닫는 코드펜스(꼬리 artifact — 판정 유지)" CLEAN \
  '결함 없음.
REVIEW_STATUS: reviewed

```
'
srow "계약 줄이 유일한 줄(판정 유지)" CLEAN 'REVIEW_STATUS: reviewed'

# ── 구조 줄 no-basis ────────────────────────────────────────────────────────
# 리뷰어가 스스로 "근거 없음"을 구조로 밝힌 경우 — 산문 해석 없이 곧장 미산출.
srow "구조 줄 no-basis (#207 원문 산문 동반)" NONE \
  '판정 근거로 지정된 diff가 메시지에 포함되어 있지 않아 검증할 수 없습니다.
REVIEW_STATUS: no-basis'
srow "구조 줄 no-basis + [P1] 항목 병존(계약 모순 응답은 신뢰하지 않는다)" NONE \
  '- [P1] 무언가 — a.sh:1
REVIEW_STATUS: no-basis'

# ── 구조 줄 없음 ────────────────────────────────────────────────────────────
# 산문이 긍정이든 부정이든, 발견이 있든 없든 **전부 미산출**이다. 세 라운드를 태운
# 어형 판별을 여기서 통째로 버린다. (미산출은 통과가 아니라 폴백행이다 — SKILL ③-1.)
srow "구조 줄 없음 + 긍정 산문(다 봤고 부합한다)" NONE \
  '변경 전체를 읽고 대조했습니다. 이 변경은 계획에 부합합니다. 결함 없음. CLEAN'
srow "구조 줄 없음 + 부정 산문(round3 BLOCKER 원문 — 부합하는지 확인할 수 없다)" NONE \
  '제공된 정보만으로 변경 사항이 계획에 부합하는지 확인할 수 없습니다.'
srow "구조 줄 없음 + 부정 산문(round4 BLOCKER 원문 — 부합함을 확인할 수 없다)" NONE \
  '제공된 정보만으로는 변경이 계획에 부합함을 확인할 수 없습니다.'
srow "구조 줄 없음 + #207 원문(fail-open 을 낳은 그 응답)" NONE \
  '판정 근거로 지정된 diff가 메시지에 포함되어 있지 않아 변경 내용과 수용 기준 충족 여부를 검증할 수 없습니다. 따라서 CLEAN으로 판정할 근거도 없습니다.'
srow "구조 줄 없음 + 공백뿐인 출력" NONE '
'
srow "구조 줄 없음 + [P1] 발견(출력 계약 위반 응답 — 미산출, f1 과 달리 산문 우연 매치가 아니다)" NONE \
  '- [P1] 필수 변경이 diff에서 누락 — scripts/foo.sh:12'

# ── 형식이 깨진 구조 줄 ─────────────────────────────────────────────────────
# 파서가 읽는 형식 = 프롬프트가 요구한 형식(codex-review-gate.sh 의 STATUS_* 상수 한 자리).
# 값·구분자·꼬리표가 어긋나면 형식이 아니므로 미산출이다.
srow "형식 깨짐 — 값이 사전에 없음(yes)" NONE \
  '다 봤습니다.
REVIEW_STATUS: yes'
srow "형식 깨짐 — 구분자가 콜론이 아님" NONE \
  '다 봤습니다.
REVIEW_STATUS = reviewed'
srow "형식 깨짐 — 값 뒤 꼬리 텍스트" NONE \
  '다 봤습니다.
REVIEW_STATUS: reviewed (범위 일부 제외)'
srow "형식 깨짐 — 키 없이 값만" NONE \
  '다 봤습니다.
reviewed'
srow "형식 깨짐 — 구조 줄이 본문 중간(마지막 줄 창 밖)" NONE \
  'REVIEW_STATUS: reviewed
그 뒤로 판정을 이어 적었습니다.
추가 서술 1.
추가 서술 2.
추가 서술 3.'
unset -f srow

echo "[gate] 4b-3) 계약 줄은 프롬프트로 실제로 요구된다 — 파서가 읽는 형식과 같은 문자열(한 자리 정의)"
# 이 이슈가 고치려던 결함은 SKILL↔템플릿이 서로 다른 말을 한 것이다. 형식을 두 자리에
# 적으면 그 불일치가 파서 쪽에서 재발한다 — 그래서 형식은 codex-review-gate.sh 의 STATUS_*
# 상수 한 자리에서만 정의하고, 프롬프트 계약문·파서가 둘 다 그것을 참조한다. 아래는 실제로
# 나간 프롬프트(스텁이 기록한 argv)에 파서가 받아들이는 두 값이 그대로 들어 있는지 본다.
: > "$STUB_LOG"; STUB_MODE=clean run --base base --prompt "계획 부합 검토"
grep -q 'REVIEW_STATUS: reviewed' "$STUB_LOG" && grep -q 'REVIEW_STATUS: no-basis' "$STUB_LOG" && ok \
  || bad "프롬프트에 응답 계약(구조 줄 형식)이 안 실렸다: $(head -c 200 "$STUB_LOG")"
grep -q '계획 부합 검토' "$STUB_LOG" && ok || bad "--prompt 본문 미전달"
# 비계약 경로(--prompt 없는 내장 스코프 리뷰)는 계약을 실을 자리가 없다 — 구조 줄을 요구하지
# 않고 main 의 영문 '도구 부재' 휴리스틱(#137)만 유지한다. 여기까지 구조 줄을 요구하면 모든
# correctness 호출이 미산출이 되어 게이트가 통째로 멈춘다.
: > "$STUB_LOG"; STUB_MODE=clean run --base base
grep -q 'REVIEW_STATUS' "$STUB_LOG" && bad "비계약 경로에 계약문이 실렸다" || ok
assert_eq "비계약 경로 CLEAN 유지" "$rc" 0

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
