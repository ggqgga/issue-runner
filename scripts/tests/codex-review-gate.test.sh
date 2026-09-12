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
# 위치 = 꼬리에서 빈 줄·**짝이 맞는** 닫는 코드펜스만 벗기고 남은 **마지막 한 줄**(아래 위치
# 격자가 전수 단언). 맨몸 펜스는 여닫이가 문자열만으로 안 갈리므로 본문 처음부터 센 짝으로
# 가른다(#279) — 짝 없는 꼬리 펜스는 여는 펜스이므로 안 벗기고, 그 응답은 계약 위반이다.
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
    NIT)     assert_eq "격자: $name" "$rc" 0; case "$last" in "verdict=NIT "*)     ok ;; *) bad "격자[$name] want=NIT 실제: $last" ;; esac ;;
    # want 오타/미지원 값이 조용한 no-op 이 되지 않게 — 안 무는 격자 행은 초록을 무죄로 둔갑시킨다
    *) bad "격자[$name] 지원하지 않는 want=$want" ;;
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
srow "리뷰 전체를 펜스로 감싼 정상 응답(여는 펜스 → 본문 → 계약 줄 → 닫는 펜스, 짝 맞음 — 과잉 차단 0)" CLEAN \
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
# 꼬리 펜스는 **짝**으로 가른다(#279): 맨몸 펜스는 여닫이가 문자열만으로 구분되지 않으므로
# 본문 처음부터 CommonMark 규칙으로 센 결과 "앞에서 열린 블록을 닫는 줄" 인 것만 벗긴다.
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
# (#339 재분류) 이 행은 #279 까지 CLEAN 이었다 — 짝만 보면 꼬리 펜스는 정상 닫는 펜스다. 그런데
# 이 형상은 이슈 #339 의 fail-open 원문("판정 근거를 얻지 못했습니다. 계약 형식은 다음과 같습니다:
# / ``` / <계약 줄> / ```")과 **구조가 같다**: 산문 뒤에 열린 블록 안의 계약 줄. 둘을 가르는 것은
# 산문의 뜻뿐이고 산문은 판정 입력이 아니다(#207 재심 (c)) — 그래서 둘 다 미산출이다. 벗겨도
# 되는 닫는 펜스는 **구역 첫 줄에서 연 블록**(리뷰 전체를 감싼 형태)의 짝뿐이다(4b-2e 참조).
srow "산문 뒤 여는 펜스 + 계약 줄 + 닫는 펜스(짝은 맞지만 리뷰 전체를 감싼 게 아님 — 미산출, #339)" NONE \
  '요약 문단.
```
결함 없음.
REVIEW_STATUS: reviewed
```'
srow "여는 펜스 + 계약 줄 + 빈 줄 + 닫는 코드펜스(짝 맞는 꼬리 artifact — 판정 유지)" CLEAN \
  '```
결함 없음.
REVIEW_STATUS: reviewed

```
'
srow "계약 줄이 유일한 줄(판정 유지)" CLEAN 'REVIEW_STATUS: reviewed'

# attempt8(#207): 꼬리 펜스 정규식이 **언어 태그 달린 여는 펜스**(예: "```python")도 "닫는
# 코드펜스"로 오인해 벗겼다 — 벗기면 그 위 줄이 계약 줄로 잘못 채택돼, 계약 줄 뒤에 실제로는
# 정체불명의 꼬리 내용(여는 펜스 = 잘린/미종결 블록의 흔적)이 남아 있는데도 CLEAN 으로 샜다.
# 닫는 펜스는 관례상 언어 태그가 없다 — 그래서 벗길 것은 **맨몸 펜스뿐**이어야 한다.
srow "계약 줄 뒤 언어 태그 달린 여는 펜스(여는 펜스를 닫는 펜스로 오벗김 — 형식 위반, 미산출)" NONE \
  'REVIEW_STATUS: reviewed
```python'

# ── #279: 맨몸 펜스의 **짝** 격자 ───────────────────────────────────────────
# attempt8 은 정보 문자열이 붙은 펜스만 여는 펜스로 가렸다. 남은 구멍은 **맨몸** 펜스다
# (``` · ~~~) — 문자열만으로는 여닫이가 안 갈린다. 그래서 본문 처음부터 CommonMark 규칙으로
# 펜스를 세어 꼬리 펜스가 짝(앞에서 열린 블록을 닫는 줄)인지 판정하고, 짝이 맞는 것만 벗긴다.
# 규칙(코드 주석과 같은 문장): 펜스는 들여쓰기 ≤3칸에서만 열고 닫는다 · 닫는 펜스는 정보
# 문자열을 가질 수 없다 · 닫는 펜스는 여는 펜스와 같은 문자이고 길이가 같거나 길어야 한다.
# 아래 격자는 그 규칙을 **양방향으로** 전수 단언한다 — 위쪽 CLEAN 칸들이 과잉 차단 0(정상
# 응답이 미산출로 접히면 게이트가 통째로 멈춘다 — 원 결함보다 나쁘다), 아래쪽 NONE 칸들이
# 짝 없는 꼬리 펜스의 fail-closed. 한 칸만 닫는 접근을 쓰지 않는다(PR#202 교훈).
echo "[gate] 4b-2i) 꼬리 맨몸 펜스의 짝 격자 — 짝이 맞는 닫는 펜스만 벗긴다 (#279)"
# (1) 짝이 맞는 정상 응답 = 종전 판정 유지(과잉 차단 0)
srow "물결 펜스로 감싼 정상 응답(백틱과 같은 규칙)" CLEAN \
  '~~~
결함 없음.
REVIEW_STATUS: reviewed
~~~'
srow "정보 문자열(markdown 태그) 여는 펜스로 감싼 정상 응답 — 맨몸 닫는 펜스와 짝 맞음" CLEAN \
  '```markdown
결함 없음.
REVIEW_STATUS: reviewed
```'
srow "네 겹으로 열고 다섯 겹으로 닫은 응답(닫는 펜스가 더 길어도 짝 — 길이 '이상')" CLEAN \
  '````
결함 없음.
REVIEW_STATUS: reviewed
`````'
srow "닫는 펜스가 2칸 들여쓰임(CommonMark 는 ≤3칸 허용 — 짝 맞음)" CLEAN \
  '```
결함 없음.
REVIEW_STATUS: reviewed
  ```'
srow "본문 중간에 완결된 코드블록 + 계약 줄이 마지막(벗길 꼬리 자체가 없음)" CLEAN \
  '아래 조각을 확인했습니다.
```json
{"a": 1}
```
결함 없음.
REVIEW_STATUS: reviewed'
# (2) 짝이 없는 꼬리 펜스 = 여는 펜스 → 안 벗긴다 → 계약 위반(미산출, fail-closed)
srow "계약 줄 뒤 짝 없는 맨몸 펜스(군더더기 블록을 열고 잘린 응답 — 이슈 실패 시나리오 원문)" NONE \
  '- [P2] 사소한 편차 — a.sh:1
REVIEW_STATUS: reviewed
```'
srow "계약 줄 뒤 짝 없는 물결 펜스(백틱과 같은 판정)" NONE \
  '결함 없음.
REVIEW_STATUS: reviewed
~~~'
srow "백틱 펜스로 열고 물결 펜스로 닫으려는 응답(문자 불일치 — 짝 아님)" NONE \
  '```
결함 없음.
REVIEW_STATUS: reviewed
~~~'
srow "물결 펜스로 열고 백틱 펜스로 닫으려는 응답(문자 불일치 — 대칭 확인)" NONE \
  '~~~
결함 없음.
REVIEW_STATUS: reviewed
```'
srow "네 겹으로 열고 세 겹으로 닫으려는 응답(길이 부족 — 짝 아님)" NONE \
  '````
결함 없음.
REVIEW_STATUS: reviewed
```'
srow "완결된 코드블록 뒤 계약 줄 + 짝 없는 맨몸 펜스(앞 블록이 이미 닫혀 꼬리는 여는 펜스)" NONE \
  '```json
{"a": 1}
```
REVIEW_STATUS: reviewed
```'
srow "꼬리 펜스가 4칸 들여쓰임(코드 블록 본문이라 펜스가 아님 — 블록 미닫힘, 벗기지 않는다)" NONE \
  '```
결함 없음.
REVIEW_STATUS: reviewed
    ```'

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
# ── #207 반송 코멘트의 합성 코퍼스 f1~f5 — 옛 산문 정규식(`codex-review-gate.sh` 옛
# 131행대, attempt6 에서 이미 걷어냄) 이 남긴 구멍을 이 구조 신호 설계가 실제로 메웠는지
# 명시적으로 못박는다. 반송 코멘트의 옛 want(정오표): f1=차단되면 안 됨(정당한 [P1] 이므로
# BLOCKER 로 살아야) · f2·f3=차단되면 안 됨(부정 서술·부분 서술일 뿐 CLEAN 이어야) ·
# f4=통과되면 안 됨(판정 불가이므로 NONE 이어야) · f5=차단(NONE)이 맞음.
# 이 설계는 산문을 **전혀 읽지 않는다**(재심 (c)) — 그래서 위 want 는 오직 **계약 줄
# 유무**로만 갈린다: 계약 줄이 있으면(현재 프롬프트가 실제로 항상 요구하는 형태) 항목
# 집계가 옛 want 와 정확히 일치하고, 계약 줄이 없으면(형식 위반) 내용이 f1 이든 f4 든
# 무관하게 전부 미산출이다 — 그 자체가 안전한 방향이다: "못 봤다"를 CLEAN 으로 잘못
# 읽거나 정당한 발견을 산문 패턴 우연 매치로 지우는 옛 실패 모드가 구조적으로 불가능해졌다.
echo "[gate] 4b-2b) #207 반송 합성 코퍼스 f1~f5 — 옛 산문 정규식의 구멍을 구조 신호로 재확인"
srow "f1 — 정당한 [P1] 설명문(옛 want=BLOCKER, 계약 줄 있음)" BLOCKER \
  '- [P1] 필수 변경이 diff에서 누락 — scripts/foo.sh:12
REVIEW_STATUS: reviewed'
srow "f2 — '누락은 없습니다' 부정 서술(옛 want=CLEAN, 계약 줄 있음)" CLEAN \
  'CLEAN. diff에 테스트 누락은 없습니다. 수용 기준을 모두 충족합니다.
REVIEW_STATUS: reviewed'
srow "f3 — 일부만 정적 검증 불가하다는 부분 서술(옛 want=CLEAN, 계약 줄 있음)" CLEAN \
  'CLEAN. 나머지는 런타임 동작이라 정적으로는 검증할 수 없지만, 변경분 자체는 결함이 없습니다.
REVIEW_STATUS: reviewed'
srow "f4 — 판정 불가 서술, 계약 줄 없음(옛 want=NONE — 형식 위반이라 내용 무관 미산출)" NONE \
  '제공된 정보만으로 변경 내용을 검토할 수 없습니다.'
srow "f5 — #207 원 fail-open 응답, 계약 줄 없음(want=NONE)" NONE \
  '판정 근거로 지정된 diff가 메시지에 포함되어 있지 않아 변경 내용과 수용 기준 충족 여부를 검증할 수 없습니다. 따라서 CLEAN으로 판정할 근거도 없습니다.'

# ── real-corpus 스타일 보강 — 다양한 실제 리뷰 어투에서 과잉 차단 0 을 단언 ──────
# 부정·부분·범위축소 서술이 섞인 실제 리뷰 문체를 폭넓게 모사한다(각 행이 계약 줄을
# 갖췄다는 전제 — 현재 프롬프트가 실제로 항상 그 줄을 요구하므로 이게 현실적 입력이다).
# 산문을 안 읽으므로 항목([Pn]) 수만 verdict 를 정하고, 아래 전부 항목 0 → CLEAN 이어야
# 한다 — 하나라도 NONE/BLOCKER 로 새면 구조 신호 뒤에 숨은 프로그램 어딘가가 다시 산문을
# 읽고 있다는 뜻이다(회귀 앵커).
echo "[gate] 4b-2c) real-corpus 스타일 보강 — 부정·부분 서술 CLEAN 과잉 차단 0"
srow "실코퍼스1 — 범위 전체 확인 + 수용 기준 충족" CLEAN \
  '변경분은 모두 확인했고 이슈 수용 기준을 충족합니다.
REVIEW_STATUS: reviewed'
srow "실코퍼스2 — 런타임 전용 동작은 범위 밖으로 명시" CLEAN \
  '런타임에서만 확인 가능한 동작은 이 리뷰 범위 밖으로 판단했습니다. 나머지는 문제 없습니다.
REVIEW_STATUS: reviewed'
srow "실코퍼스3 — 실행 필요 항목 캐비엇 + 정적 범위 충족" CLEAN \
  '일부 로그 출력 형식은 실제로 실행해봐야 확정되지만, 정적으로 보이는 범위에서는 요구사항을 만족합니다.
REVIEW_STATUS: reviewed'
srow "실코퍼스4 — '추가하지 않았지만' 부정 패턴(테스트 누락 오탐 유발형)" CLEAN \
  '이 PR 은 새 테스트를 추가하지 않았지만 기존 스위트로 충분히 커버됩니다.
REVIEW_STATUS: reviewed'
srow "실코퍼스5 — '부족하다는 지적은 있었으나' 부정 패턴" CLEAN \
  '문서화가 부족하다는 지적은 있었으나 이번 변경 범위에서는 요구되지 않습니다.
REVIEW_STATUS: reviewed'
srow "실코퍼스6 — 번호 매긴 체크리스트 전부 없음 서술" CLEAN \
  '1) 계획 대비 누락 없음 2) 범위 초과 없음 3) 과잉 설계 없음. CLEAN.
REVIEW_STATUS: reviewed'
srow "실코퍼스7 — 저장소 접근 불가(진짜 no-basis, f5 형만 차단됨을 대조)" NONE \
  '저장소 접근 권한이 없어 diff 를 확인하지 못했습니다.
REVIEW_STATUS: no-basis'

# ── #283: codex 가 렌더하는 발견 섹션은 **모델 통제 밖**이다 ────────────────────
# 위 4b-2 격자는 전부 "리뷰 본문 = 모델이 쓴 글" 을 가정한 스텁이라, 실제 CLI 가 문서를
# 어떻게 조립하는지를 한 번도 묻지 않았다. 2026-09-11 실호출(codex-cli 0.153.4, gpt-5.6-sol)로
# 측정한 `codex exec review --prompt` 의 산출 구조는 다음과 같다:
#
#   <모델이 쓴 총평>            ← 모델이 통제하는 유일한 구역(계약 줄이 닿는 곳)
#   (빈 줄)
#   Review comment:             ← 발견 1건일 때 codex 가 붙이는 헤더
#   또는 Full review comments:  ← 발견 2건 이상일 때
#   (빈 줄)
#   - [Pn] 제목 — 파일:줄       ← codex 가 렌더하는 항목들
#     본문                       ← **문서의 마지막 줄은 늘 여기다**
#
# 두 헤더 문자열은 codex 바이너리 안에 인접 리터럴로 박혀 있다(strings 실측). 즉 발견이
# 하나라도 있으면 문서의 마지막 줄은 항상 항목 본문이고, "마지막 줄 = 계약 줄" 요구는
# **구조적으로 충족 불가**다. 이슈 #283 의 3/3 NONE 이 정확히 이것이다 — 그리고 방향이
# 고약하다: 발견 0 인 리뷰만 계약을 지킬 수 있어 **CLEAN 은 통과하고 BLOCKER·WARN 은
# 전부 폴백으로 버려진다**(게이트가 발견을 낸 리뷰만 골라 버린다).
# 해소: 판정 창을 "문서의 마지막 줄" 이 아니라 **"모델 통제 구역(발견 섹션 헤더 앞)의
# 마지막 줄"** 로 옮긴다. 산문은 여전히 읽지 않는다(#207 재심 (c) 유지) — 새 판별 입력은
# codex 자신의 렌더 헤더라는 **구조** 신호다.
echo "[gate] 4b-2d) codex 실렌더 구조 — 발견 섹션 헤더 뒤는 모델 통제 밖 (#283)"
srow "실렌더 단수 헤더 + [P1] 1건(probe2 실측 구조) = BLOCKER" BLOCKER \
  'The new report runner permits command injection through untrusted input, so the patch is unsafe.
REVIEW_STATUS: reviewed

Review comment:

- [P1] Stop executing report input through a shell — auth.py:8-8
  When user_input contains shell metacharacters, shell=True executes them as arbitrary commands.'
srow "실렌더 복수 헤더 + [P1] 3건(probe3 실측 구조) = BLOCKER" BLOCKER \
  '변경분은 명령 주입·SQL 주입·비밀 파일 권한 문제를 함께 들여옵니다.
REVIEW_STATUS: reviewed

Full review comments:

- [P1] Pass report arguments without invoking a shell — app.py:4-4
  shell=True 로 셸을 거치면 메타문자가 명령으로 실행된다.

- [P1] Parameterize the user lookup query — app.py:8-8
  문자열 연결 SQL 은 술어를 바꿔치기당한다.

- [P1] Restrict permissions on the saved secret — app.py:11-12
  0777 은 로컬 사용자 전원에게 토큰을 노출한다.'
srow "실렌더 헤더 + [P2] 만 = WARN" WARN \
  '작은 편차가 하나 있습니다.
REVIEW_STATUS: reviewed

Review comment:

- [P2] 로그 문구가 계획과 미세하게 다름 — scripts/foo.sh:12
  본문.'
srow "실렌더 헤더 + [P3] 만 = NIT" NIT \
  '사소한 제안 하나.
REVIEW_STATUS: reviewed

Review comment:

- [P3] 주석 오타 — scripts/foo.sh:3
  본문.'
# probe3 실측 어투(총평 문장 끝에 계약 줄을 이어 붙임)는 **이제 미산출**이다 — #283 재심 ①
# 이후 계약 줄은 줄 전체일 때만 판정이다. 같은 형태를 어형으로 갈라 살리려던 두 회차가
# *"못 봤다. <키>: <값>"* 을 CLEAN 으로 통과시켰다(아래 4b-2f A·A2). 방향은 fail-closed(폴백)이고,
# 이 형태 자체는 프롬프트 계약문("줄을 바꿔 그 줄만 적어라")으로 막는다.
srow "계약 줄이 총평 문장 끝에 인라인(probe3 실측 어투) + 헤더 + 항목 = 미산출(#283 재심 ①)" NONE \
  '이 변경은 새 기능에서 악용 가능한 보안 결함을 들여옵니다. REVIEW_STATUS: reviewed

Full review comments:

- [P1] 셸 경유 실행 제거 — app.py:4-4
  본문.'
srow "같은 형태를 줄바꿈만 해서 적으면 판정 유지(이 PR 의 본 축 — 발견이 살아야 한다)" BLOCKER \
  '이 변경은 새 기능에서 악용 가능한 보안 결함을 들여옵니다.
REVIEW_STATUS: reviewed

Full review comments:

- [P1] 셸 경유 실행 제거 — app.py:4-4
  본문.'
srow "계약 줄이 총평 문장 끝에 인라인 + 발견 0(헤더 없음) = 미산출(#283 재심 ①)" NONE \
  '변경 전체를 읽었고 수용 기준을 충족합니다. REVIEW_STATUS: reviewed'

# fail-open 0 — 구역을 옮겨도 "계약 줄 뒤 산문" 은 여전히 미산출이다(#207 attempt4 봉인 유지).
srow "총평 안에서 계약 줄 뒤 산문 + 헤더 + 항목 = 미산출(attempt4 봉인 유지)" NONE \
  'REVIEW_STATUS: reviewed
I could not inspect the diff because the execution tool was unavailable.

Review comment:

- [P1] 무언가 — a.sh:1
  본문.'
srow "헤더는 있는데 총평에 계약 줄이 없음 = 미산출" NONE \
  '변경을 살펴봤습니다.

Review comment:

- [P1] 무언가 — a.sh:1
  본문.'
srow "헤더 + no-basis = 미산출(항목이 있어도 리뷰어가 근거 없음을 밝혔다)" NONE \
  '지정된 범위를 열지 못했습니다.
REVIEW_STATUS: no-basis

Review comment:

- [P1] 무언가 — a.sh:1
  본문.'
srow "총평이 비어 있고 헤더부터 시작 = 미산출(모델 통제 구역이 없다)" NONE \
  'Review comment:

- [P1] 무언가 — a.sh:1
  본문.'
srow "헤더 유사 문자열(Review comments:)은 헤더가 아니다 — 구역이 안 잘려 미산출" NONE \
  'REVIEW_STATUS: reviewed

Review comments:

- [P1] 무언가 — a.sh:1
  본문.'
# (가) 를 "문서 어디든" 으로 풀었다면 생겼을 오탐 — 리뷰어가 계약문 자체를 인용하며 끝내는
# 응답. 구역의 **마지막 줄** 만 보므로 인용의 꼬리(no-basis)가 채택돼 미산출로 접힌다.
srow "리뷰어가 계약문을 인용하며 끝냄(두 값 나열) = 미산출(인용 오탐 방지)" NONE \
  '계약에 따라 마지막 줄은 다음 둘 중 하나여야 합니다:
REVIEW_STATUS: reviewed
REVIEW_STATUS: no-basis'
srow "헤더 앞 총평 꼬리의 빈 줄은 벗긴다(계약 줄 + 빈 줄 + 헤더 + 항목) = BLOCKER" BLOCKER \
  '총평.
REVIEW_STATUS: reviewed


Review comment:

- [P1] 무언가 — a.sh:1
  본문.'

# ── 값 **앞** 같은 줄 텍스트는 어형 불문 미산출이다 (#283 재심 ①) ────────────────
# 두 회차가 이 자리를 조건부로 열었다가 둘 다 fail-open 을 냈다: ⑴ "표식만 아니면 통과"
# → *"이것을 <키>: <값> 으로 읽지 마라"* 는 부정문이 CLEAN, ⑵ "끝난 문장 하나까지 통과"
# → *"diff 를 못 봤다. <키>: <값>"* 이 CLEAN(⑴ 반송 문자열의 세미콜론을 마침표로 바꾼 것뿐).
# 어형으로는 "판정을 주장하는 문장"과 "판정을 부정하는 문장"이 갈리지 않는다 — 그래서 묻지
# 않는다: 계약 줄은 **줄 전체**가 계약 형식일 때만 판정이다(옛 `^` 앵커와 같은 자리).
echo "[gate] 4b-2e) 계약 줄 앞 텍스트 — 무엇이 오든 미산출(줄 전체 규칙, #283 재심 ①)"
srow "인용 블록으로 계약문을 옮겨 적음(> 표식뿐) = 미산출" NONE \
  '계약상 마지막 줄은 다음과 같아야 합니다:
> REVIEW_STATUS: reviewed'
srow "목록 항목으로 계약문을 옮겨 적음(- 표식뿐) = 미산출" NONE \
  '형식 예시:
- REVIEW_STATUS: reviewed'
srow "번호 목록으로 계약문을 옮겨 적음(1. 표식뿐) = 미산출" NONE \
  '형식 예시:
1. REVIEW_STATUS: reviewed'
srow "헤딩 표식뿐 = 미산출" NONE \
  '형식 예시:
## REVIEW_STATUS: reviewed'
srow "인용 표식 + 끝난 문장 + 계약 줄 = 미산출(줄 전체가 아니다)" NONE \
  '> 검토를 마쳤습니다. REVIEW_STATUS: reviewed'
srow "맨몸 계약 줄은 접두가 아예 없다 — 판정 유지(회귀 앵커)" CLEAN \
  '결함 없음.
REVIEW_STATUS: reviewed'

# ── #339: 펜스 인용 · 들여쓴 인용 — 짝 세기(#279)만으로는 안 닫히는 두 변종 ─────────
# closeout 폴백 검증자 실측(PR #295 마감, P1·P2): 리뷰어가 diff 를 못 열고 계약문을 **되읊는**
# 응답이 CLEAN 으로 통과했다. 두 형태다 —
#   ⑴ 산문 뒤에 펜스를 열고 그 안에 계약 줄을 적은 뒤 닫음: 짝이 맞으니 #279 가 닫는 펜스를
#      정상 벗기고 계약 줄이 마지막 줄로 채택된다.
#   ⑵ 계약 줄을 4칸(또는 탭)으로 들여씀: 옛 trim() 이 선행 공백을 지워 맨몸 계약 줄과 같아진다.
# 둘 다 markdown 의 **인용/코드 표식**이고, 4b-2e 위쪽 행들(> · - · 1. · ##)과 같은 가족이다 —
# 표식이 문자열이 아니라 위치·펜스라는 점만 다르다. 규칙:
#   · 꼬리에서 벗기는 닫는 펜스는 **구역 첫 비공백 줄에서 연 블록의 짝**뿐이다(= 리뷰 전체를
#     감싼 형태, #279 가 정상으로 둔 그것). 산문 뒤에 열린 블록의 닫는 펜스는 벗기지 않는다
#     → 마지막 줄이 펜스 자신 → 계약 위반 → 미산출.
#   · 판정 줄의 **선행 공백은 지우지 않는다**(끝 공백만) — 들여쓴 계약 줄은 줄 전체가
#     `<키>: <값>` 이 아니므로 미산출. 리뷰 전체 펜스 안 정상 형태는 들여쓰기 0 이라 회귀 없음.
# 산문 정규식으로는 되돌아가지 않는다(#207·#283) — 새 입력은 여전히 구조(펜스 위치·열)뿐이다.
echo "[gate] 4b-2e-2) 펜스 인용 · 들여쓴 인용 = 미산출 (#339)"
srow "산문 뒤 펜스 블록 안의 계약 줄(이슈 #339 실패 시나리오 원문) = 미산출" NONE \
  '판정 근거를 얻지 못했습니다. 계약 형식은 다음과 같습니다:
```
REVIEW_STATUS: reviewed
```'
srow "산문 뒤 물결 펜스 블록 안의 계약 줄(백틱과 같은 규칙) = 미산출" NONE \
  '계약 형식:
~~~
REVIEW_STATUS: reviewed
~~~'
srow "산문 뒤 정보 문자열(text 태그) 달린 펜스 블록 안의 계약 줄 = 미산출" NONE \
  '계약 형식:
```text
REVIEW_STATUS: reviewed
```'
srow "산문 뒤 펜스 블록 — 블록 안에 산문이 더 있어도 같다(산문 뜻은 안 읽는다) = 미산출" NONE \
  '검토했습니다.
```
결함 없음.
REVIEW_STATUS: reviewed
```'
srow "4칸 들여쓴 계약 줄(코드 블록 인용, closeout 실측 P2) = 미산출" NONE \
  '계약 형식은 다음과 같습니다:

    REVIEW_STATUS: reviewed'
srow "탭으로 들여쓴 계약 줄 = 미산출" NONE \
  "$(printf '계약 형식:\n\tREVIEW_STATUS: reviewed')"
srow "1칸 들여쓴 계약 줄(≤3칸도 줄 전체가 아니다) = 미산출" NONE \
  '결함 없음.
 REVIEW_STATUS: reviewed'
srow "리뷰 전체 펜스 안에서 계약 줄만 들여쓴 응답 = 미산출(들여쓰기 규칙은 펜스 안에서도 같다)" NONE \
  '```
결함 없음.
    REVIEW_STATUS: reviewed
```'
# 과잉 차단 반증 — 리뷰 전체를 감싼 형태(#279 정상)는 그대로 산다: 여는 펜스 앞 빈 줄은 산문이
# 아니고, 겉 펜스를 네 겹으로 하면 안쪽 완결 코드블록도 품는다. 끝 공백은 여전히 벗긴다.
srow "빈 줄 뒤 리뷰 전체를 감싼 펜스(첫 비공백 줄이 여는 펜스) = 판정 유지" CLEAN \
  '
```
결함 없음.
REVIEW_STATUS: reviewed
```'
srow "네 겹 펜스로 리뷰 전체를 감싸고 안에 완결 코드블록이 있는 응답 = 판정 유지" CLEAN \
  '````
아래 조각을 확인했습니다.
```json
{"a": 1}
```
결함 없음.
REVIEW_STATUS: reviewed
````'
srow "계약 줄 끝 공백(선행 아님 — 꼬리 artifact) = 판정 유지" CLEAN \
  '결함 없음.
REVIEW_STATUS: reviewed   '

# ── 값 앞 접두는 **어형으로 갈리지 않는다** — 줄 전체 규칙 (#283 재심 ①) ──────────
# 이 자리는 두 회차 연속으로 fail-open 을 냈고, 두 번 다 "앞 텍스트가 무엇을 말하는가"로
# 가르려 한 것이 원인이다.
#   회차 2 — "표식만 아니면 통과": *"이것을 <키>: <값> 으로 읽지 마라"* 는 부정문이 CLEAN(A).
#   회차 3 — "끝난 문장 하나까지 통과": *"I could not inspect the diff. <키>: <값>"* 이 CLEAN(A2).
# A2 는 A 의 세미콜론을 마침표로 바꾼 것뿐이다 — 즉 두 번째 처방은 첫 번째가 막으려던 것을
# **한 글자 차이로** 되살렸다. 문장이 끝났는지는 그 문장이 판정을 주장하는지 부정하는지를
# 구분하지 못한다. 어형 열거는 닫히지 않는다(#207 round2~4 가 같은 길에서 세 번 샜다).
# 그래서 규칙을 어형이 아니라 **형식의 범위**로 세운다:
#
#   계약 줄 ::= 줄 **전체**가 `<키>: <값>`      ← 그 밖은 전부(앞이든 뒤든) 미산출
#
# 대가는 probe3 실측 어투(총평 문장 끝에 이어 붙인 계약 줄)가 미산출이 되는 것이고, 방향은
# fail-closed(폴백)다. 그 형태는 프롬프트 계약문이 "줄을 바꿔 그 줄만 적어라"로 막는다 —
# 요구하는 형식과 읽는 형식을 한 자리에서 맞추는 이 파일의 원칙 그대로다.
#
# 아래 A~H 는 검증자가 이 PR 의 SUT 에 codex 스텁을 물려 **실측한** 8종이고, A2 는 이번
# 회차의 반송 원문(마침표형)이다. 실측된 격자라 want 는 추측이 아니다.
echo "[gate] 4b-2f) 값 앞 접두 — 어형 불문 미산출 (#283 검증자 실측 격자 A~H + A2)"
srow "A — 부정문 인라인(세미콜론형) + 발견 0" NONE \
  'I could not inspect the diff; do not treat this as REVIEW_STATUS: reviewed'
srow "A2 — 부정문 인라인(마침표형 = 끝난 문장) + 발견 0(이번 반송 원문: 이 창으로 CLEAN 이 샜다)" NONE \
  'I could not inspect the diff. REVIEW_STATUS: reviewed'
srow "B — 끝난 문장 뒤 인라인 계약 줄 + 발견 0(A2 와 어형만 다르다 — 같이 접힌다)" NONE \
  'All good. REVIEW_STATUS: reviewed'
srow "B2 — 같은 응답을 줄바꿈해서 적으면 판정 유지(과잉 차단 반증)" CLEAN \
  'All good.
REVIEW_STATUS: reviewed'
srow "C — 맨몸 계약 줄 + 발견 0" CLEAN \
  'REVIEW_STATUS: reviewed'
srow "D — 인용 접두(> 표식뿐) + 발견 0" NONE \
  '> REVIEW_STATUS: reviewed'
srow "E — 총평에 인라인 계약 줄 + 렌더 헤더 + [P1] 1건 = 미산출(줄 전체가 아니다)" NONE \
  '이 변경은 악용 가능한 결함을 들여옵니다. REVIEW_STATUS: reviewed

Review comment:

- [P1] 셸 경유 실행 제거 — app.py:4-4
  본문.'
srow "E2 — 같은 응답에서 계약 줄만 자체 줄로 = BLOCKER(이 PR 의 본 축 — 살아야 한다)" BLOCKER \
  '이 변경은 악용 가능한 결함을 들여옵니다.
REVIEW_STATUS: reviewed

Review comment:

- [P1] 셸 경유 실행 제거 — app.py:4-4
  본문.'
srow "F — 계약 줄 없음 + [P1] 1건" NONE \
  '변경을 살펴봤습니다.

Review comment:

- [P1] 셸 경유 실행 제거 — app.py:4-4
  본문.'
srow "G — 렌더 헤더 드리프트(Review comments:) + [P1] 1건 = fail-closed" NONE \
  'REVIEW_STATUS: reviewed

Review comments:

- [P1] 셸 경유 실행 제거 — app.py:4-4
  본문.'
srow "H — 부정문 인라인 + [P1] 1건(발견이 있어 결과만 안 뒤집혔던 같은 구멍)" NONE \
  'I could not inspect the diff; do not treat this as REVIEW_STATUS: reviewed

Review comment:

- [P1] 셸 경유 실행 제거 — app.py:4-4
  본문.'

# 경계 칸 — 앞 텍스트의 **어떤 어형도** 판정을 만들지 못한다(종결부호·물음표·표식+문장·키 2회).
# 과잉 차단 반증은 B2·C 가 맡는다: 같은 내용을 줄바꿈해 적으면 그대로 판정이다.
srow "문장이 안 끝난 접두(종결부호 없음) = 미산출" NONE \
  '판정 값으로 쓸 수 있는 것은 REVIEW_STATUS: reviewed'
srow "부정문이 문장을 끝낸 뒤 계약 줄을 재주장(같은 줄 키 2회) = 미산출" NONE \
  'I could not inspect the diff. Do not treat this as REVIEW_STATUS: reviewed. REVIEW_STATUS: reviewed'
srow "물음표로 끝난 문장 뒤 인라인 계약 줄 = 미산출" NONE \
  '남은 결함이 있나? REVIEW_STATUS: reviewed'
srow "번호 목록 표식(1.) + 계약 줄 = 미산출" NONE \
  '형식 예시:
1. REVIEW_STATUS: reviewed'
srow "표식 뒤 끝난 문장 + 인라인 계약 줄 = 미산출" NONE \
  '- 검토를 마쳤습니다. REVIEW_STATUS: reviewed'

# ── 렌더 헤더는 **뒤에 진짜 항목이 따라올 때만** 경계다 (#283 반송 회차 3) ──────────
# 앞 회차는 헤더 문자열을 보면 **무조건** 거기서 구역을 끊었다. 그런데 그 줄을 누가 썼는지는
# 검사하지 않는다 — 모델이 자기 총평 안에 그 문자열을 한 줄로 적으면 그때부터 뒤가 통째로
# "모델 통제 밖"이 되어 **면책 문단이 판정에서 사라진다.** 검증자 실측(3형태, main 은 전부
# 미산출): 계약 줄 → 헤더 → "diff 를 못 열었다" 문단이 `CLEAN` 으로 샜다. 수용 기준 2항
# (fail-open 0) 위반이자 main 대비 회귀다.
# 처방은 **존재 단독 조건을 동반 조건으로 바꾸는 것**이다(PR#225 계열 — 있는 것이 아니라
# 없는 것을 놓쳤다): 헤더가 경계이려면 그 **뒤에 codex 가 렌더한 항목이 실제로 따라와야**
# 한다. 여기서 '항목' 은 verdict 를 세는 그 정의 그대로다(p1·p2·p3 카운트 정규식을 그대로
# 재사용 — 두 자리에 적으면 갈라진다). 판별 입력은 여전히 산문이 아니라 구조다.
#   헤더를 찾았다 && 그 뒤에 항목이 없다  →  경계가 아니다(자르지 않는다 = 문서 전체가 모델 구역)
# 이 술어는 검증자가 못박은 조건(`헤더 발견 && p1+p2+p3 == 0 → 경계 아님`)을 **포함한다**:
# 문서 전체 항목이 0이면 어떤 헤더도 뒤에 항목을 못 갖는다. 더해서 "가짜 헤더 뒤에 진짜
# 렌더가 이어지는" 끼임 형태(항목 ≥1 이라 그 조건만으로는 안 걸린다)까지 같은 술어로 닫힌다.
# 잘리는 경우는 정의상 항목이 ≥1 이므로 **잘린 판정이 CLEAN 으로 나오는 경로는 구조적으로
# 없다** — 창이 틀리면 미산출(폴백)로 접힌다.
echo "[gate] 4b-2g) 렌더 헤더는 뒤에 항목이 따라올 때만 경계 (#283 검증자 실측 3형태 + W3 비대칭)"
srow "①(검증자 실측) 계약 줄 + 모델이 적은 단수 헤더 + 면책 문단 = 미산출" NONE \
  'REVIEW_STATUS: reviewed
Review comment:
I could not inspect the diff.'
srow "②(검증자 실측) 같은 형태 + 빈 줄(렌더 모양을 흉내 내도 항목이 없다) = 미산출" NONE \
  'REVIEW_STATUS: reviewed

Review comment:

I could not inspect the diff.
'
srow "③(검증자 실측) 복수 헤더 + 면책 문단 = 미산출" NONE \
  '총평.
REVIEW_STATUS: reviewed

Full review comments:

I could not inspect the diff because the execution tool was unavailable.'
srow "④(검증자 실측) 진짜 렌더 — 헤더 + 불릿 [P1] 항목 = BLOCKER(무회귀, 본 축)" BLOCKER \
  '총평.
REVIEW_STATUS: reviewed

Review comment:

- [P1] 무언가 — a.sh:1
  본문.'
# W3(검증자 WARN, 같은 술어로 함께 닫힌다) — codex 가 항목을 번호 목록으로 렌더하면 카운트
# 정규식(`^- [Pn]`)이 0을 세는데, 헤더를 무조건 믿으면 구역이 잘려 총평의 계약 줄이 채택되고
# **진짜 [P1] 이 은폐된 CLEAN** 이 난다. 항목이 안 따라오면 경계가 아니므로 미산출로 접힌다.
srow "W3 — 헤더 + 번호 목록 항목(카운트 0) = 미산출(진짜 [P1] 은폐 방지)" NONE \
  '총평.
REVIEW_STATUS: reviewed

Full review comments:

1. [P1] 진짜 결함 — g.sh:1
   본문'
# 끼임형 — 모델이 총평에 헤더를 적고 면책을 쓴 **뒤에** 진짜 렌더가 이어진다. 문서 전체
# 항목 수는 1이라 "항목 0" 조건만으로는 안 걸리는 자리다(그 조건만 쓰면 첫 헤더에서 잘려
# 면책이 사라진다). 헤더별로 뒤를 보므로 진짜 렌더 헤더에서만 잘리고, 그 앞 구역의 마지막
# 줄은 면책 문단이라 미산출이다.
srow "끼임형 — 가짜 헤더 + 면책 + 진짜 헤더 + [P1] 항목 = 미산출" NONE \
  '총평.
REVIEW_STATUS: reviewed

Review comment:

I could not inspect the diff.

Full review comments:

- [P1] 무언가 — a.sh:1
  본문.'
# 과잉 차단 반증 — 헤더 문자열이 모델 산문 안에 있어도 항목이 안 따라오면 구역이 안 잘린다.
# 그때 문서 전체가 모델 구역이므로 **문서 마지막 줄의 계약 줄이 그대로 판정**이다.
srow "헤더 문자열이 총평 인용이고 계약 줄이 문서 끝 = 판정 유지(구역 미절단)" CLEAN \
  '게이트가 보는 헤더 문자열은 다음과 같습니다.
Review comment:
이 줄은 codex 렌더가 아니라 모델 산문입니다.
REVIEW_STATUS: reviewed'
srow "헤더 직후 빈 줄 없이 바로 항목 = 경계 유지(BLOCKER 무회귀)" BLOCKER \
  '총평.
REVIEW_STATUS: reviewed
Review comment:
- [P1] 무언가 — a.sh:1
  본문.'
srow "헤더 뒤 항목이 [P2] 뿐 = 경계 유지(WARN 무회귀)" WARN \
  '총평.
REVIEW_STATUS: reviewed

Full review comments:

- [P2] 사소한 편차 — a.sh:1
  본문.'
# CRLF(검증 보강이 짚은 격자 공백) — 값 뒤의 `\r` 는 형식 위반이라 미산출이다. 방향은
# fail-closed(폴백행)이고 main 과 같다 — 조용한 통과로는 새지 않는다.
srow "CRLF 줄바꿈 — 값 뒤 \\r 는 형식 위반(미산출, fail-closed)" NONE \
  "$(printf '총평.\r\nREVIEW_STATUS: reviewed\r\n')"

# ── 경계는 **CLI 가 쓴 것**일 때만 (#283 재심 ②) ────────────────────────────────
# 앞 회차는 "헤더 + 그 뒤 첫 비공백 줄이 항목"이면 경계로 봤다. 그런데 헤더도 항목도 같은
# 무제약 텍스트에서 나온다 — 모델이 헤더를 적고 그 아래 `- [P2] …` 를 지어내면 인접 조건이
# 충족돼 **그 뒤 면책 문단이 판정에서 사라지고** WARN/NIT(exit 0 = 게이트 통과)가 났다.
# 즉 앞 회차가 "헤더를 누가 썼는가"를 안 물어 샜던 자리에서, 이번엔 "항목을 누가 썼는가"를
# 안 물어 같은 방식으로 샜다. 인접은 CLI 저작의 증거가 아니다.
# 처방은 형식에 **위치·중복**을 더해 codex 렌더의 불변식을 전수로 묻는 것이다(cli_rendered()):
#   ⓐ 헤더 뒤 첫 비공백 줄이 항목이고 · ⓑ 거기부터 **문서 끝까지** 전부 항목/항목 본문이며
#   · ⓒ 그런 자격 헤더가 문서에 **정확히 하나**.
# 근거는 구조다 — codex 는 모델 메시지를 다 받은 뒤 자기 섹션을 덧붙이므로 렌더 섹션은
# 문서의 **접미**이고, 섹션은 하나만 렌더된다. 어긋나면 자르지 않는다 = 미산출(폴백).
# 남는 한 형태는 구조적으로 판별 불가다(모델이 면책 문단까지 항목 본문처럼 들여쓰면 진짜
# 렌더와 바이트 단위로 같아진다) — 닫으려면 CLI 의 구조화 출력이 필요하고 0.153.4 엔 없다.
echo "[gate] 4b-2h) 렌더 뒤에 모델 산문이 오면 경계가 아니다 (#283 검증자 실측 ②)"
srow "②(검증자 실측) 모델이 쓴 헤더 + [P2] 불릿 + 면책 문단 = 미산출(이 창으로 WARN 이 샜다)" NONE \
  'REVIEW_STATUS: reviewed
Review comment:
- [P2] fabricated finding — a.sh:1
I could not inspect the diff at all.'
srow "②-P3 변종(같은 창으로 NIT 가 샜다) = 미산출" NONE \
  'REVIEW_STATUS: reviewed
Review comment:
- [P3] fabricated nit — a.sh:1
I could not inspect the diff at all.'
srow "②-P1 변종(같은 창으로 BLOCKER 가 났다 — 방향은 달라도 같은 구멍) = 미산출" NONE \
  'REVIEW_STATUS: reviewed
Review comment:
- [P1] fabricated finding — a.sh:1
I could not inspect the diff at all.'
srow "②-복수 헤더 변종 + 항목 2건 + 면책 문단 = 미산출" NONE \
  'REVIEW_STATUS: reviewed
Full review comments:
- [P2] fabricated — a.sh:1
- [P2] fabricated2 — b.sh:2
말미: 사실 diff 를 열지 못했습니다.'
srow "렌더 뒤 모델 산문이 빈 줄 뒤에 와도 접미가 아니다 = 미산출" NONE \
  'REVIEW_STATUS: reviewed

Review comment:

- [P2] fabricated — a.sh:1
  본문.

덧붙임: 실제로는 저장소를 열지 못했습니다.'
# ⓒ 중복 — codex 는 섹션을 하나만 렌더한다. 자격 헤더가 둘이면 어느 쪽이 CLI 인지 알 수
# 없으므로 자르지 않는다(모호 = 막는 쪽). 자르면 두 번째 헤더 앞의 면책 문단이 사라진다.
# (ⓑ 만으로는 안 걸리는 자리 — 뒤쪽 헤더가 항목 본문처럼 들여써 있어 앞 헤더의 접미 검사는
#  통과한다. ⓒ 가 없으면 첫 헤더에서 잘려 총평 한 줄만 구역이 되고 WARN p2=2 로 샌다.)
srow "자격 헤더 2개(들여쓴 헤더가 뒤에 끼어 둘 다 자격) = 모호 → 미산출" NONE \
  'REVIEW_STATUS: reviewed

Review comment:

- [P2] 하나 — a.sh:1
  Full review comments:
  - [P2] 둘 — b.sh:2'
# 과잉 차단 반증 — 진짜 렌더 구조(항목 + 들여쓴 본문 + 꼬리 빈 줄)는 그대로 경계다.
srow "진짜 렌더: 항목 본문 여러 줄 + 꼬리 빈 줄 = BLOCKER(무회귀)" BLOCKER \
  '총평.
REVIEW_STATUS: reviewed

Full review comments:

- [P1] 하나 — a.sh:1
  본문 첫 줄.
  본문 둘째 줄.

- [P2] 둘 — b.sh:2
  본문.

'
srow "진짜 렌더: 항목만 있고 본문이 없다 = WARN(무회귀)" WARN \
  '총평.
REVIEW_STATUS: reviewed

Review comment:

- [P2] 하나 — a.sh:1'
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
