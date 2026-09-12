#!/usr/bin/env bash
# codex-review-gate.sh 픽스처 테스트 — 네트워크 무접속(codex 스텁). Plans/codex-native-review-gate.md (#134)
#   P1 → exit 1/BLOCKER · P2 만 → 0/WARN · P3 만 → 0/NIT · 항목 없음 → 0/CLEAN · 모델 오류 → 2 ·
#   타임아웃 → 2(손자 프로세스까지 종료) · codex 부재 → 2 · usage 64 · 스코프/프롬프트 인자 전달 ·
#   구조 신호 판정(항목 · no-basis 줄 · events.jsonl 명령 기록) — 4b-2 격자.
# bats 미도입 레포 — 순수 bash assert 관행.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/codex-review-gate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stub"
export STUB_LOG="$TMP/calls.log"
# codex 스텁 — 인자를 기록하고, STUB_MODE 에 따라 review.md(-o 경로)를 쓰거나 오류/행(hang)을 흉내낸다.
# STUB_EVENTS 는 `--json` 이벤트 스트림(게이트가 events.jsonl 로 받는 stdout)을 고른다 —
# git(기본) = 실 스키마 command_execution 1건 · none = 0줄 · absent = 스트림 파일 자체 없음.
# 실 스키마는 2026-09-13 실호출 4건에서 뜬 그대로다(항목 8~15개, command 전부 `/bin/zsh -lc "git …"`):
#   {"type":"item.completed","item":{"id":"item_2","type":"command_execution",
#    "command":"/bin/zsh -lc \"git diff --stat base...HEAD\"","aggregated_output":"…",
#    "exit_code":0,"status":"completed"}}
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG:?}"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
emit_events() {
  case "${STUB_EVENTS:-git}" in
    git)    printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"git diff --stat base...HEAD\"","aggregated_output":"f | 2 +-","exit_code":0,"status":"completed"}}' ;;
    none)   : ;;
    absent) rm -f "$(dirname "$out")/events.jsonl" ;;
  esac
}
case "${STUB_MODE:-p1}" in
  p1)    printf 'Summary.\n\nReview comment:\n\n- [P1] fail-open — scripts/x.sh:10\n  body\n- [P2] minor — scripts/y.sh:3\n' > "$out"; emit_events ;;
  p2)    printf 'Summary.\n\n- [P2] minor — a.sh:1\n- [P2] minor2 — b.sh:2\n' > "$out"; emit_events ;;
  p3)    printf 'Summary.\n\n- [P3] nit — a.sh:1\n' > "$out"; emit_events ;;
  p0)    printf 'Summary.\n\n- [P0] critical — a.sh:1\n' > "$out"; emit_events ;;
  selfref) printf 'Summary.\n\n- [P2] minor — a.sh:1\n' > "$out"
           # 리뷰어가 읽은 파일 내용이 --json 스트림(=events.jsonl)에 실리는 상황을 흉내낸다 —
           # 모델/인증 오류 문자열은 codex 자신의 stderr 에서만 읽어야 한다(#137). 실 스키마라
           # 오류 문자열은 `aggregated_output`(grep 이 출력한 남의 텍스트) 자리에 온다.
           printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"grep -rn model scripts/\"","aggregated_output":"does not exist or you do not have access / not supported when using Codex / requires a newer version of Codex","exit_code":0,"status":"completed"}}' ;;
  clean) printf 'No issues found in the reviewed changes.\n' > "$out"; emit_events ;;
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
# 프롬프트 뒤에 no-basis 힌트 한 문단이 덧붙으므로 지시문은 argv 첫 줄로 끝난다(4b-3 이 힌트를 문다)
grep -q '^exec review 계획 부합 검토$' "$STUB_LOG" && ok || bad "--prompt 미전달: $(head -1 "$STUB_LOG")"
STUB_MODE=clean run --base base --prompt "계획 부합"
grep -q 'exec review Review ONLY the committed changes `git diff base...HEAD`' "$STUB_LOG" && ok || bad "--prompt+--base 범위 머리말 없음: $(tail -1 "$STUB_LOG" | cut -c1-120)"
grep -q -- 'code_mode_host' "$STUB_LOG" && bad "code_mode_host 를 끄면 리뷰어가 도구를 못 쓴다 — 넘기지 말 것" || ok
rc=0; "$SUT" >/dev/null 2>&1 || rc=$?; assert_eq "인자 없음 usage" "$rc" 64

echo "[gate] 4) 모델 오류 → 2 · NONE · 안내 문구 · codex 비정상 종료 → 2 · review.md 없음 → 2"
STUB_MODE=model run --base base; assert_eq "모델 오류 exit" "$rc" 2; case "$last" in "verdict=NONE "*) ok ;; *) bad "모델 오류 verdict: $last" ;; esac
grep -q "codex debug models" "$TMP/err" && grep -q "does not exist" "$TMP/err" && ok || bad "모델 오류 안내 없음: $(cat "$TMP/err")"
STUB_MODE=fail run --base base; assert_eq "codex exit 3 → 2" "$rc" 2
echo "[gate] 4b) 범위에 변경 없음 → 2(리뷰 미실행) · 볼드 [P1] 도 항목"
: > "$STUB_LOG"; STUB_MODE=clean run --base HEAD; assert_eq "변경 없음 exit" "$rc" 2; [ ! -s "$STUB_LOG" ] && ok || bad "변경 없음인데 codex 호출됨"
STUB_MODE=clean run --commit 0000000000000000000000000000000000000000; assert_eq "없는 커밋 exit" "$rc" 2
git -C "$R" stash -q; STUB_MODE=clean run --uncommitted; assert_eq "미커밋 없음 exit" "$rc" 2; git -C "$R" stash pop -q
# srow 격자용 보조 스텁 — review.md 본문만 픽스처(UNABLE)로 갈아 끼우고, 이벤트 스트림은
# STUB_EVENTS 로 고른다(git = 실 스키마 명령 1건 · none = 0줄 · absent = 파일 자체 없음).
# 기본값을 none 으로 둔다: CLEAN 을 기대하는 행이 events 인자를 **말하게** 해서, 편한 기본값
# 때문에 행이 조용히 안 무는 일을 막는다.
cat > "$TMP/stub/codex2" <<'S2'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
cp "${UNABLE:?}" "${out:?}"
case "${STUB_EVENTS:-none}" in
  git)    printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"git diff --stat base...HEAD\"","aggregated_output":"f | 2 +-","exit_code":0,"status":"completed"}}' ;;
  none)   : ;;
  # 실패한 git 명령(잘못된 리비전) — command 에 `git ` 이 있어도 exit_code≠0 이면 읽은 증거가 아니다
  gitfail) printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"git diff --stat nope...HEAD\"","aggregated_output":"fatal: bad revision","exit_code":128,"status":"completed"}}' ;;
  absent) rm -f "$(dirname "$out")/events.jsonl" ;;   # 게이트가 리다이렉션으로 만들어 둔 파일을 지운다
  # 보조 경로 — `git ` 이 없고 `--cd` 로 준 경로만 담은 명령(codex 가 cwd 를 안 옮긴 런)
  cdpath) printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"rg --files '"$STUB_CD"'\"","aggregated_output":"f","exit_code":0,"status":"completed"}}' ;;
esac
S2
chmod +x "$TMP/stub/codex2"; cp "$TMP/stub/codex2" "$TMP/stub/codex.bak"; rm -f "$TMP/stub/codex2"
printf -- '- **[P1]** bold — a.sh:1\n\n(참고: [P1] 표기는 항목이 아님)\n' > "$TMP/unable.md"
printf -- '- **[P1]** bold — a.sh:1\n\n(참고: [P1] 표기는 항목이 아님)\n' > "$TMP/unable.md"
mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
UNABLE="$TMP/unable.md" run --base base; assert_eq "볼드 [P1] BLOCKER" "$rc" 1; case "$last" in "verdict=BLOCKER p1=1 "*) ok ;; *) bad "볼드 P1 집계: $last" ;; esac
mv "$TMP/stub/codex.real" "$TMP/stub/codex"

echo "[gate] 4b-2) 게이트 구조 신호 격자 — 판정 입력은 항목·no-basis 줄·events 명령 기록뿐"
# 설계: Plans/review-round-cap-and-gate-signals.md §규칙 ②(사람 결정 2026-09-13). 게이트는
# **모델 문장을 읽지 않는다.** 옛 설계는 "리뷰 본문 마지막 줄이 `REVIEW_STATUS: reviewed` 여야
# 하고 아니면 미산출" 이라는 응답 계약으로 '안 본 CLEAN' 을 걸러 보려 했는데, 프로덕션 크기
# 프롬프트(10~30KB)에서 모델은 그 줄을 내지 않았다(2026-09-13 실호출 0/4 · 2026-09-11 0/4 —
# 짧은 스모크만 1/1). 리뷰어는 매번 판정을 냈고 **버린 쪽이 게이트**였다. 판정 입력은 이제 셋뿐:
#   ① 렌더된 항목([P0~P9]) ≥1  → 그 집계대로 BLOCKER/WARN/NIT (계약 줄·events 무관)
#   ② 항목 0 & 본문에 `REVIEW_STATUS: no-basis` **줄 전체**  → NONE (리뷰어의 선택 신호)
#   ③ 항목 0 → events.jsonl 의 `command_execution` 중 `git `/`--cd` 경로 명령 ≥1 → CLEAN, 없으면 NONE
# `--prompt` 유무 두 경로가 같은 순서로 판정한다.
# 폐기한 격자: 계약 줄 위치·펜스 짝(4b-2·2i) · 값 앞 어형(2f) · 렌더 헤더 경계(2g·2h) ·
# 계약문 실림(4b-3 → 힌트 검사). 그것들이 물던 코드(contract_re · cli_rendered awk ·
# RENDER_HEADER_* · LEGACY_UNABLE)는 삭제됐다 — 코드가 없으면 격자도 없다.
srow() {  # srow <이름> <want> <본문> [events: git|none|absent(기본)] [SUT 인자(공백 분리, 기본 --base base --prompt …)]
  name="$1"; want="$2"; printf '%s' "$3" > "$TMP/unable.md"; ev="${4:-none}"
  args="${5:---base base --prompt 계획부합검토}"
  mv "$TMP/stub/codex" "$TMP/stub/codex.real"; cp "$TMP/stub/codex.bak" "$TMP/stub/codex"
  rm -f "$TMP/out/events.jsonl"   # --out 은 전 행이 공유한다 — 앞 행의 스트림이 남으면 순서 의존 플레이크
  # shellcheck disable=SC2086  # args 는 공백 분리 인자열이다(어느 인자에도 공백을 두지 않는다)
  STUB_EVENTS="$ev" STUB_CD="$R" UNABLE="$TMP/unable.md" run $args
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

# ── 판정 입력 3종의 존재/부재 6행 ────────────────────────────────────────────
srow "① 항목 [P1] 1건 · 계약 줄 없음 · 명령 기록 0 = BLOCKER(항목이 곧 '읽었다'의 증거)" BLOCKER \
  '변경을 살펴봤습니다.

Review comment:

- [P1] 필수 변경이 diff 에서 누락 — scripts/foo.sh:12
  본문.'
# 옛 `LEGACY_UNABLE` 산문 휴리스틱(비프롬프트 경로에서만 돌던 영문 '도구 부재' 문구 열거)이
# 정확히 이 본문을 미산출로 접었다. 이제 산문은 판정 입력이 아니다 — 명령 기록이 있으므로 CLEAN.
srow "② 항목 0 · git 명령 기록 1건 = CLEAN(옛 '볼 수 없음' 산문이 본문에 있어도 — LEGACY_UNABLE 삭제 앵커)" CLEAN \
  'No findings are reported because the workspace execution tool was unavailable, so commit X could not be inspected. This verdict is therefore not a substantive correctness assessment.' \
  git "--base base"
srow "③ 항목 0 · 명령 기록 0 = NONE(읽지 않은 '문제 없음' 은 판정이 아니다)" NONE \
  '변경 전체를 읽고 대조했습니다. 이 변경은 계획에 부합합니다. 결함 없음. CLEAN'
srow "③-b 항목 0 · git 명령은 있으나 exit_code 128 = NONE(실패한 읽기는 증거가 아니다)" NONE \
  "CLEAN. 문제 없음." gitfail
srow "④ 항목 0 · events.jsonl 자체가 없음 = NONE(파일 부재도 기록 0 과 같다)" NONE \
  '결함 없음.' absent
srow "⑤ 항목 0 · no-basis 줄 · git 명령 기록 1건 = NONE(명령을 돌렸어도 리뷰어가 근거 없음을 밝혔다)" NONE \
  '판정 근거로 지정된 diff 가 메시지에 포함되어 있지 않아 검증할 수 없습니다.
REVIEW_STATUS: no-basis' \
  git
srow "⑥ [P1] + 본문이 'Unable to inspect the repository' 인용 = BLOCKER(#280 인용 오탐 앵커, 비프롬프트 경로)" BLOCKER \
  '리뷰어가 남긴 인용: "Unable to inspect the repository". 그래도 발견은 실제로 냈습니다.

Review comment:

- [P1] 실제 결함 — a.sh:1
  본문.' \
  none "--base base"

# ── ③ 의 보조 경로 — `git ` 이 아니라 `--cd` 경로로 명령 기록을 알아본다 ─────────────
# 실측 4호출은 `command` 가 전부 `/bin/zsh -lc "git …"` 였지만(주 경로), codex 가 cwd 를 안 옮기면
# 경로 리터럴이 남는다. 이 행이 없으면 `--cd` 매칭 한 줄을 지워도 격자가 초록이다.
srow "③ 보조 — 항목 0 · command 에 git 없음 · --cd 경로 포함 = CLEAN" CLEAN \
  '결함 없음.' cdpath "--base base --cd $R"

# ── 순서: ① 이 ② 보다 먼저다 ────────────────────────────────────────────────
# 항목이 있으면 no-basis 줄도 판정을 못 뒤집는다 — 파일:줄을 단 발견이 이미 나왔다.
srow "no-basis 줄 + [P1] 항목 병존 = BLOCKER(① 이 ② 보다 먼저)" BLOCKER \
  '- [P1] 무언가 — a.sh:1
REVIEW_STATUS: no-basis' \
  git

# ── 과잉 차단 0 — 산문은 어떤 어형이든 판정을 만들지 못한다 ──────────────────────
# 옛 설계는 한국어/영어 산문을 정규식으로 읽어 "결론이 섰는가"를 가리려다 어형마다 fail-open 을
# 냈다(#207 round2~4). 이제 산문은 판정 입력이 아니다. 옛 어투별 행들(f1~f5 · 실코퍼스 1~7)은
# 전부 이 한 경로를 반복하므로 대표 1행으로 줄였다(동치류당 격자 1행).
srow "부정·캐비엇·범위축소 산문 + 항목 0 + git 명령 기록 = CLEAN(산문 판정 0)" CLEAN \
  '제공된 정보만으로 런타임 동작이 계획에 부합하는지 확인할 수 없습니다. 새 테스트를 추가하지 않았지만 기존 스위트로 충분합니다. 변경분 자체는 결함이 없습니다.' \
  git

# ── codex 실렌더 구조에서 항목 집계가 그대로 산다(2026-09-11 실측 구조) ────────────
# 산출은 "모델 총평" + 헤더(`Review comment:`/`Full review comments:`) + codex 가 렌더한 항목이다.
# 옛 설계는 그 헤더로 '모델 통제 구역'을 잘라 계약 줄을 찾았고(cli_rendered awk), 그 파서는
# 삭제됐다 — 헤더는 이제 판정에 아무 역할이 없고 항목만 센다.
srow "실렌더 구조(복수 헤더 + 항목 3건 + 들여쓴 본문) = BLOCKER" BLOCKER \
  '변경분은 명령 주입·SQL 주입·비밀 파일 권한 문제를 함께 들여옵니다.

Full review comments:

- [P1] Pass report arguments without invoking a shell — app.py:4-4
  shell=True 로 셸을 거치면 메타문자가 명령으로 실행된다.

- [P1] Parameterize the user lookup query — app.py:8-8
  문자열 연결 SQL 은 술어를 바꿔치기당한다.

- [P2] Restrict permissions on the saved secret — app.py:11-12
  0777 은 로컬 사용자 전원에게 토큰을 노출한다.'
unset -f srow

echo "[gate] 4b-3) 프롬프트에 실리는 것은 **힌트 한 문단**이다 — 옛 'reviewed' 요구는 없다"
# 힌트는 요구가 아니다: 리뷰어가 no-basis 줄을 안 내도 판정은 구조 신호로 난다(위 격자 ②③④).
# 그래도 형식은 한 자리(STATUS_KEY·STATUS_NO_BASIS)에서만 정의한다 — 쓰라고 한 형식과 읽는
# 형식이 갈리면 ② 가 조용히 안 걸린다.
: > "$STUB_LOG"; STUB_MODE=clean run --base base --prompt "계획 부합 검토"
grep -q 'REVIEW_STATUS: no-basis' "$STUB_LOG" && ok || bad "프롬프트에 no-basis 힌트가 안 실렸다: $(head -c 200 "$STUB_LOG")"
grep -q 'REVIEW_STATUS: reviewed' "$STUB_LOG" && bad "옛 'reviewed' 응답 계약이 프롬프트에 남아 있다(모델이 못 내는 요구)" || ok
grep -q '계획 부합 검토' "$STUB_LOG" && ok || bad "--prompt 본문 미전달"
# 비프롬프트 경로(내장 스코프 리뷰)는 힌트를 실을 자리가 없다 — 판정 순서는 두 경로가 같다.
: > "$STUB_LOG"; STUB_MODE=clean run --base base
grep -q 'REVIEW_STATUS' "$STUB_LOG" && bad "비프롬프트 경로에 힌트가 실렸다" || ok
assert_eq "비프롬프트 경로 CLEAN 유지(명령 기록 있음)" "$rc" 0

echo "[gate] 4c) [P0] 도 BLOCKER · events 의 오류 문자열은 오탐 안 냄(모델 오류는 codex stderr 만 본다, #137)"
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
