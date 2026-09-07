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
