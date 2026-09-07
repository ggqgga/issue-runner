#!/usr/bin/env bash
# ci-queue.sh · hooks/local-ci.sh 픽스처 테스트 — 네트워크 무접속(gh·osascript 스텁, HOME=tmp).
# 박스 전역 티켓 락(FIFO)의 계약을 결정적으로 검증한다(Plans/ci-queue.md, #127):
#   단독 pass/fail · 두 잡 직렬(무겹침·순서) · HEAD 이동 폐기 · ROOT 부재 · 죽은 티켓 회수 ·
#   result dedup · 같은 SHA 중복 발급 없음 · status 출력 · 훅의 cwd + `cd X &&` ROOT 파싱.
# bats 미도입 레포 — finish-classify.test.sh 와 같은 순수 bash assert 관행.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/ci-queue.sh"
HOOK="$DIR/../hooks/local-ci.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${longlived:-}" ] && kill "$longlived" 2>/dev/null' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/stub"
# gh 스텁 — 호출 인자를 기록만 한다(commit status 게시 경로 검증용).
cat > "$TMP/stub/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_LOG:?}"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$TMP/stub/osascript"
chmod +x "$TMP/stub/gh" "$TMP/stub/osascript"
export PATH="$TMP/stub:$PATH"
export GH_LOG="$TMP/gh.log"
export CI_LOG="$TMP/ci.log"
export CI_QUEUE_POLL=1          # 테스트는 1초 폴링(기본 10초)

QDIR="$HOME/.claude/.local-ci/.queue"
pass=0; fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "  ✗ $*"; }
assert_eq() { [ "$2" = "$3" ] && ok || bad "$1 — 기대=$3 실제=$2"; }
assert_file() { [ -f "$2" ] && ok || bad "$1 — 파일 없음: $2"; }
assert_nofile() { [ ! -e "$2" ] && ok || bad "$1 — 없어야 할 파일: $2"; }

# make_repo <name> — git 레포 + 가짜 bin/ci(시작/종료를 CI_LOG 에 기록, CI_SLEEP 만큼 점유, CI_RC 로 종료)
make_repo() {
  local r="$TMP/$1"
  mkdir -p "$r/bin"
  git -C "$r" init -q
  # 레포마다 내용이 달라야 SHA 가 갈린다(빈 커밋은 같은 초에 만들면 SHA 가 같다)
  printf '%s\n' "$1" > "$r/name"
  git -C "$r" add name
  git -C "$r" -c user.name=t -c user.email=t@t commit -q -m "init $1"
  cat > "$r/bin/ci" <<'CI'
#!/bin/sh
name=$(basename "$(pwd)")
echo "start $name $(date +%s)" >> "$CI_LOG"
sleep "${CI_SLEEP:-0}"
echo "end $name $(date +%s)" >> "$CI_LOG"
exit "${CI_RC:-0}"
CI
  chmod +x "$r/bin/ci"
  printf '%s' "$r"
}
slug_of() { printf '%s' "$(cd "$1" && pwd -P)" | sed 's#[/ ]#_#g; s#^_##'; }
head_of() { git -C "$1" rev-parse HEAD; }
fake_sha() { printf "$1%.0s" $(seq 1 40); }   # 존재하지 않는 40자 SHA
# wait_file <path> [초] — 백그라운드 잡의 결과를 기다린다
wait_file() { local i=0; while [ ! -f "$1" ] && [ $i -lt "${2:-30}" ]; do sleep 1; i=$((i + 1)); done; [ -f "$1" ]; }
# wait_status <sha> <running|queued N> — 큐 상태 전이를 조건으로 기다린다(고정 sleep 대신, 0.2초 폴·최대 10초)
wait_status() { local i=0; while [ "$("$SUT" status "$1")" != "$2" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done; }

echo "[ci-queue] 1) 단독 실행 pass → result·status(pending→success)"
R1=$(make_repo r1); S1=$(head_of "$R1"); SL1=$(slug_of "$R1")
rc=0; "$SUT" run "$R1" "$S1" >/dev/null 2>&1 || rc=$?
assert_eq "pass exit" "$rc" 0
assert_file "pass result" "$HOME/.claude/.local-ci/$SL1/$S1.result"
assert_eq "pass verdict" "$(cat "$HOME/.claude/.local-ci/$SL1/$S1.result")" pass
assert_file "pass log" "$HOME/.claude/.local-ci/$SL1/$S1.log"
assert_eq "status pending 게시" "$(grep -c "statuses/$S1 .*state=pending" "$GH_LOG")" 2   # 대기열 + 실행 중
assert_eq "status success 게시" "$(grep -c "statuses/$S1 .*state=success" "$GH_LOG")" 1
assert_eq "큐 비움" "$(ls -A "$QDIR" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "[ci-queue] 2) result dedup — 이미 검사된 SHA 는 bin/ci 를 다시 돌리지 않는다"
: > "$CI_LOG"
rc=0; "$SUT" run "$R1" "$S1" >/dev/null 2>&1 || rc=$?
assert_eq "dedup exit(pass)" "$rc" 0
assert_eq "dedup 무실행" "$(wc -l < "$CI_LOG" | tr -d ' ')" 0

echo "[ci-queue] 3) 단독 실행 fail → result=fail · exit 1 · status failure"
R2=$(make_repo r2); S2=$(head_of "$R2"); SL2=$(slug_of "$R2")
rc=0; CI_RC=1 "$SUT" run "$R2" "$S2" >/dev/null 2>&1 || rc=$?
assert_eq "fail exit" "$rc" 1
assert_eq "fail verdict" "$(cat "$HOME/.claude/.local-ci/$SL2/$S2.result")" fail
assert_eq "status failure 게시" "$(grep -c "statuses/$S2 .*state=failure" "$GH_LOG")" 1
rc=0; "$SUT" run "$R2" "$S2" >/dev/null 2>&1 || rc=$?
assert_eq "dedup exit(fail 은 1 유지)" "$rc" 1

echo "[ci-queue] 4) 두 잡 직렬 — 먼저 발급된 티켓이 먼저, 실행 구간 무겹침"
R3=$(make_repo r3); S3=$(head_of "$R3"); SL3=$(slug_of "$R3")
R4=$(make_repo r4); S4=$(head_of "$R4"); SL4=$(slug_of "$R4")
: > "$CI_LOG"
CI_SLEEP=1 "$SUT" run "$R3" "$S3" >/dev/null 2>&1 &
p3=$!
wait_status "$S3" running
CI_SLEEP=1 "$SUT" run "$R4" "$S4" >/dev/null 2>&1 &
p4=$!
wait $p3 $p4
assert_file "잡3 result" "$HOME/.claude/.local-ci/$SL3/$S3.result"
assert_file "잡4 result" "$HOME/.claude/.local-ci/$SL4/$S4.result"
assert_eq "실행 순서" "$(awk '{print $1, $2}' "$CI_LOG" | tr '\n' ' ' | sed 's/ $//')" "start r3 end r3 start r4 end r4"
end3=$(awk '$1=="end" && $2=="r3"{print $3}' "$CI_LOG"); start4=$(awk '$1=="start" && $2=="r4"{print $3}' "$CI_LOG")
[ "${start4:-0}" -ge "${end3:-1}" ] && ok || bad "무겹침 — r4 시작($start4) < r3 종료($end3)"
assert_eq "큐 비움(직렬 후)" "$(ls -A "$QDIR" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "[ci-queue] 5) HEAD 이동 폐기 — 티켓 SHA ≠ 실행 시점 HEAD 면 exit 2, result 없음"
R5=$(make_repo r5); S5old=$(head_of "$R5"); SL5=$(slug_of "$R5")
git -C "$R5" -c user.name=t -c user.email=t@t commit -q --allow-empty -m next
rc=0; "$SUT" run "$R5" "$S5old" >/dev/null 2>&1 || rc=$?
assert_eq "폐기 exit" "$rc" 2
assert_nofile "폐기 result 없음" "$HOME/.claude/.local-ci/$SL5/$S5old.result"
assert_eq "큐 비움(폐기 후)" "$(ls -A "$QDIR" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "[ci-queue] 6) ROOT 부재 → exit 3"
rc=0; "$SUT" run "$TMP/nope" "$S1" >/dev/null 2>&1 || rc=$?
assert_eq "ROOT 부재 exit" "$rc" 3

echo "[ci-queue] 7) 죽은 티켓·죽은 .running 회수 — 앞에 유령이 있어도 실행된다"
R6=$(make_repo r6); S6=$(head_of "$R6"); SL6=$(slug_of "$R6")
mkdir -p "$QDIR/.running"
ghost="$QDIR/0000000001.99999999.$(fake_sha d)"
printf 'slug=x\n' > "$ghost"
echo 99999999 > "$QDIR/.running/pid"
rc=0; "$SUT" run "$R6" "$S6" >/dev/null 2>&1 || rc=$?
assert_eq "유령 뒤 실행 exit" "$rc" 0
assert_file "유령 뒤 result" "$HOME/.claude/.local-ci/$SL6/$S6.result"
assert_nofile "유령 티켓 회수" "$ghost"
assert_eq "큐 비움(회수 후)" "$(ls -A "$QDIR" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "[ci-queue] 8) status — 실행 중/대기열 위치, 같은 SHA 는 중복 발급 없이 기존 티켓을 기다린다"
R7=$(make_repo r7); S7=$(head_of "$R7"); SL7=$(slug_of "$R7")
R8=$(make_repo r8); S8=$(head_of "$R8")
: > "$CI_LOG"
CI_SLEEP=3 "$SUT" run "$R7" "$S7" >/dev/null 2>&1 &
p7=$!
wait_status "$S7" running
"$SUT" run "$R8" "$S8" >/dev/null 2>&1 &
p8=$!
wait_status "$S8" "queued 1"
assert_eq "status running" "$("$SUT" status "$S7")" running
assert_eq "status queued 1" "$("$SUT" status "$S8")" "queued 1"
assert_eq "status none" "$("$SUT" status "$(fake_sha a)")" none
assert_eq "status 전체 줄 수" "$("$SUT" status | wc -l | tr -d ' ')" 2
# 같은 SHA 를 다시 run — 티켓을 새로 내지 않고(bin/ci 1회) 기존 결과를 받아 exit 0
rc=0; "$SUT" run "$R7" "$S7" >/dev/null 2>&1 || rc=$?
assert_eq "중복 발급 없음 exit" "$rc" 0
wait $p7 $p8
assert_eq "중복 발급 없음 — r7 은 1회 실행" "$(grep -c 'start r7' "$CI_LOG")" 1
assert_file "r8 result" "$HOME/.claude/.local-ci/$(slug_of "$R8")/$S8.result"

echo "[ci-queue] 9) --slug/--repo — 결과 위치를 호출자가 지정(run-local-ci 의 메인 슬러그 계약)"
R9=$(make_repo r9); S9=$(head_of "$R9")
rc=0; "$SUT" run "$R9" "$S9" --slug custom_slug --repo o/r >/dev/null 2>&1 || rc=$?
assert_eq "--slug exit" "$rc" 0
assert_file "--slug result" "$HOME/.claude/.local-ci/custom_slug/$S9.result"
assert_eq "--repo 로 status 게시" "$(grep -c "repos/o/r/statuses/$S9 .*state=success" "$GH_LOG")" 1

echo "[local-ci.sh] 10) 훅 ROOT — 입력 cwd 기준 · 명령 앞 'cd X &&' · 'cd X;' 파싱"
H1=$(make_repo h1); HS1=$(head_of "$H1"); HSL1=$(slug_of "$H1")
H2=$(make_repo h2); HS2=$(head_of "$H2"); HSL2=$(slug_of "$H2")
H3=$(make_repo h3); HS3=$(head_of "$H3"); HSL3=$(slug_of "$H3")
mkdir -p "$TMP/elsewhere"
# (a) cwd 가 레포, 단독 git push — 세션에 wait 명령을 additionalContext 로 알린다
hook_out=$(printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$H1" | bash "$HOOK" 2>/dev/null)
wait_file "$HOME/.claude/.local-ci/$HSL1/$HS1.result" 20 && ok || bad "훅(a) cwd 레포 — result 없음"
ctx=$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
case "$ctx" in *"ci-queue.sh wait $HS1"*) ok ;; *) bad "훅(a) additionalContext 에 wait 명령 없음: $ctx" ;; esac
case "$ctx" in *run_in_background*) ok ;; *) bad "훅(a) additionalContext 에 백그라운드 안내 없음" ;; esac
# (b) cwd 는 딴 곳, 명령이 'cd <레포> && git push'
printf '{"cwd":"%s","tool_input":{"command":"cd %s && git push -u origin x"}}' "$TMP/elsewhere" "$H2" | bash "$HOOK" >/dev/null 2>&1
wait_file "$HOME/.claude/.local-ci/$HSL2/$HS2.result" 20 && ok || bad "훅(b) cd && — result 없음"
# (c) 상대경로 cd + ';' 구분자 — cwd 기준으로 해석
printf '{"cwd":"%s","tool_input":{"command":"cd h3; git push"}}' "$TMP" | bash "$HOOK" >/dev/null 2>&1
wait_file "$HOME/.claude/.local-ci/$HSL3/$HS3.result" 20 && ok || bad "훅(c) 상대 cd ; — result 없음"
# (d) cwd 가 git 레포가 아니고 cd 도 없음 → no-op(티켓·result 없음)
before=$(ls "$HOME/.claude/.local-ci" | wc -l | tr -d ' ')
printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$TMP/elsewhere" | bash "$HOOK" >/dev/null 2>&1
sleep 1
assert_eq "훅(d) 비레포 no-op" "$(ls "$HOME/.claude/.local-ci" | wc -l | tr -d ' ')" "$before"
# (e) git push 가 아닌 명령 → no-op
printf '{"cwd":"%s","tool_input":{"command":"git status"}}' "$H1" | bash "$HOOK" >/dev/null 2>&1
assert_eq "훅(e) 비-push no-op" "$(ls -A "$QDIR" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "[ci-queue] 11) wait — 결과 있으면 즉시(pass=0·fail=1), 실행 중이면 끝날 때 깨어남, 큐에 없으면 grace 뒤 2, 타임아웃 124"
rc=0; out=$("$SUT" wait "$S1" 2>&1) || rc=$?
assert_eq "wait pass exit" "$rc" 0
case "$out" in *"$(printf '%s' "$S1" | cut -c1-8) pass"*) ok ;; *) bad "wait pass 출력: $out" ;; esac
rc=0; out=$("$SUT" wait "$S2" 2>&1) || rc=$?
assert_eq "wait fail exit" "$rc" 1
case "$out" in *"bin/ci 마지막 출력"*) ok ;; *) bad "wait fail 은 로그 꼬리를 보여야 한다: $out" ;; esac
# 다른 세션이 큐에 넣은 잡을 이 세션이 wait — 진행 중엔 블록, 끝나면 0
R10=$(make_repo r10); S10=$(head_of "$R10")
CI_SLEEP=2 "$SUT" run "$R10" "$S10" >/dev/null 2>&1 &
p10=$!
wait_status "$S10" running
t0=$(date +%s)
rc=0; out=$("$SUT" wait "$S10" 2>&1) || rc=$?
t1=$(date +%s)
assert_eq "wait 실행 중 → 완료 exit" "$rc" 0
[ $((t1 - t0)) -ge 1 ] && ok || bad "wait 가 블록하지 않았다(${t1}-${t0})"
case "$out" in *"실행 중"*) ok ;; *) bad "wait 진행 출력에 '실행 중' 없음: $out" ;; esac
wait $p10
# 큐에 없고 결과도 없음 → grace(1초) 뒤 exit 2
rc=0; out=$(CI_QUEUE_WAIT_GRACE=1 "$SUT" wait "$(fake_sha b)" 2>&1) || rc=$?
assert_eq "wait 큐 부재 exit" "$rc" 2
case "$out" in *"재등록"*) ok ;; *) bad "wait 큐 부재 안내 없음: $out" ;; esac
# 타임아웃 — 실행 중인데 --timeout 이 먼저 → 124
R11=$(make_repo r11); S11=$(head_of "$R11")
CI_SLEEP=3 "$SUT" run "$R11" "$S11" >/dev/null 2>&1 &
p11=$!
wait_status "$S11" running
rc=0; "$SUT" wait "$S11" --timeout 1 >/dev/null 2>&1 || rc=$?
assert_eq "wait 타임아웃 exit" "$rc" 124
wait $p11

echo "[ci-queue] 10z) 같은 초 티켓 정렬 — pid 0패딩이라 9 < 10 (사전순 뒤집힘 없음)"
t9="$QDIR/0000000001.0000000009.$(fake_sha 9)"; t10="$QDIR/0000000001.0000000010.$(fake_sha 1)"
sleep 300 & longlived=$!
printf 'slug=x\n' > "$t9"; printf 'slug=x\n' > "$t10"
# 살아있는 것처럼 보이게 이름의 pid 를 longlived 로 — 정렬만 보므로 pid 필드는 패딩 형식만 맞으면 된다
first=$(for t in "$QDIR"/*; do [ -f "$t" ] && printf '%s\n' "${t##*/}"; done | head -1)
assert_eq "같은 초 정렬 9 먼저" "$first" "${t9##*/}"
rm -f "$t9" "$t10"; kill $longlived 2>/dev/null; wait $longlived 2>/dev/null; longlived=""

echo "[ci-queue] 11a) wait 경계 — 비정수 --timeout 은 usage(64) · 큐 부재 + timeout<grace 는 2(124 아님)"
rc=0; "$SUT" wait "$S1" --timeout abc >/dev/null 2>&1 || rc=$?
assert_eq "비정수 timeout" "$rc" 64
rc=0; CI_QUEUE_WAIT_GRACE=100 "$SUT" wait "$(fake_sha c)" --timeout 1 >/dev/null 2>&1 || rc=$?
assert_eq "큐 부재 timeout<grace → 2" "$rc" 2

echo "[ci-queue] 11b) forget — 결과 캐시를 지우면 같은 SHA 가 다시 돈다 · queue.log 에 흔적"
: > "$CI_LOG"
rc=0; "$SUT" forget "$S1" >/dev/null 2>&1 || rc=$?
assert_eq "forget exit" "$rc" 0
assert_nofile "forget result 삭제" "$HOME/.claude/.local-ci/$SL1/$S1.result"
rc=0; "$SUT" run "$R1" "$S1" >/dev/null 2>&1 || rc=$?
assert_eq "forget 뒤 재실행" "$(grep -c 'start r1' "$CI_LOG")" 1
grep -q "forget" "$HOME/.claude/.local-ci/queue.log" && ok || bad "queue.log 에 forget 기록 없음"

echo "[ci-queue] 11c) 나이 백스톱 — pid 가 살아 있어도 MAX_AGE 넘은 티켓은 유령으로 회수"
R12=$(make_repo r12); S12=$(head_of "$R12")
sleep 300 & longlived=$!
old="$QDIR/0000000001.$longlived.$(fake_sha e)"; printf 'slug=x\n' > "$old"
rc=0; CI_QUEUE_TICKET_MAX_AGE=60 "$SUT" run "$R12" "$S12" >/dev/null 2>&1 || rc=$?
assert_eq "나이 백스톱 뒤 실행" "$rc" 0
assert_nofile "늙은 티켓 회수" "$old"
kill $longlived 2>/dev/null; wait $longlived 2>/dev/null

echo "[ci-queue] 11c2) 나이 백스톱은 자기·실행 중 티켓엔 안 걸린다(MAX_AGE=0 이어도 A 실행·B 대기 완주)"
R14=$(make_repo r14); S14=$(head_of "$R14"); R15=$(make_repo r15); S15=$(head_of "$R15")
: > "$CI_LOG"
CI_QUEUE_TICKET_MAX_AGE=0 CI_SLEEP=2 "$SUT" run "$R14" "$S14" >/dev/null 2>&1 & p14=$!
wait_status "$S14" running
CI_QUEUE_TICKET_MAX_AGE=0 "$SUT" run "$R15" "$S15" >/dev/null 2>&1 & p15=$!
wait $p14; rc14=$?; wait $p15; rc15=$?
assert_eq "MAX_AGE=0 A 완주" "$rc14" 0
assert_eq "MAX_AGE=0 B 완주" "$rc15" 0
assert_eq "MAX_AGE=0 실행 순서" "$(awk '{print $1, $2}' "$CI_LOG" | tr '\n' ' ' | sed 's/ $//')" "start r14 end r14 start r15 end r15"

echo "[ci-queue] 11c3) 같은 SHA 동시 run 두 개 → bin/ci 는 1회, 둘 다 pass"
R16=$(make_repo r16); S16=$(head_of "$R16")
: > "$CI_LOG"
CI_SLEEP=1 "$SUT" run "$R16" "$S16" >/dev/null 2>&1 & p16a=$!
CI_SLEEP=1 "$SUT" run "$R16" "$S16" --slug other_slug >/dev/null 2>&1 & p16b=$!
wait $p16a; rca=$?; wait $p16b; rcb=$?
assert_eq "동시 run a" "$rca" 0
assert_eq "동시 run b" "$rcb" 0
assert_eq "동시 run bin/ci 1회" "$(grep -c 'start r16' "$CI_LOG")" 1

echo "[ci-queue] 11d) TERM — 실행 중 잡을 죽이면 bin/ci 자식도 죽고 실행권·티켓이 풀린다"
R13=$(make_repo r13); S13=$(head_of "$R13")
CI_SLEEP=20.31 "$SUT" run "$R13" "$S13" >/dev/null 2>&1 &
p13=$!
wait_status "$S13" running
kill -TERM $p13; wait $p13 2>/dev/null
sleep 0.5
assert_eq "TERM 뒤 큐 비움" "$(ls -A "$QDIR" 2>/dev/null | wc -l | tr -d ' ')" 0
[ -z "$(pgrep -f "sleep 20.31" 2>/dev/null)" ] && ok || bad "TERM 뒤 bin/ci 자식(sleep 20.31)이 살아 있다"
assert_nofile "TERM 뒤 result 없음" "$HOME/.claude/.local-ci/$(slug_of "$R13")/$S13.result"

echo "[ci-queue] 11e) ROOT 가 git 이 아니면(HEAD 못 읽음) exit 3, 폐기(2)와 구분"
mkdir -p "$TMP/notgit/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/notgit/bin/ci"; chmod +x "$TMP/notgit/bin/ci"
rc=0; "$SUT" run "$TMP/notgit" "$(fake_sha f)" >/dev/null 2>&1 || rc=$?
assert_eq "HEAD 못 읽음 exit" "$rc" 3
assert_eq "status error 게시(폐기 아님)" "$(grep -c "statuses/$(fake_sha f) .*state=error" "$GH_LOG")" 1

echo "[local-ci.sh] 11f) 훅 — 선두 cd 경로가 디렉터리가 아니면 세션에 경고를 덧붙인다"
hook_out=$(printf '{"cwd":"%s","tool_input":{"command":"cd $WT && git push"}}' "$H1" | bash "$HOOK" 2>/dev/null)
ctx=$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
case "$ctx" in *"해석하지 못해"*) ok ;; *) bad "훅 cd 미해석 경고 없음: $ctx" ;; esac
sleep 1   # 위 훅이 H1 HEAD(이미 result 있음)를 dedup 으로 끝내길 기다림

echo "[local-ci.sh] 11g) 훅 — 멀티라인 명령의 마지막 줄 git push 도 잡고, --dry-run 은 no-op"
H4=$(make_repo h4); HS4=$(head_of "$H4"); HSL4=$(slug_of "$H4")
printf '{"cwd":"%s","tool_input":{"command":"git commit --allow-empty -qm y\\ngit push"}}' "$H4" | bash "$HOOK" >/dev/null 2>&1
wait_file "$HOME/.claude/.local-ci/$HSL4/$HS4.result" 20 && ok || bad "훅 멀티라인 — result 없음"
H5=$(make_repo h5); HS5=$(head_of "$H5"); HSL5=$(slug_of "$H5")
printf '{"cwd":"%s","tool_input":{"command":"git push --dry-run origin x"}}' "$H5" | bash "$HOOK" >/dev/null 2>&1
sleep 1
assert_nofile "훅 --dry-run no-op" "$HOME/.claude/.local-ci/$HSL5/$HS5.result"

echo "[run-local-ci.sh] 11h) 루프 헬퍼 — 큐 경유 pass=0 · 메인 슬러그에 결과 · HEAD 이동=2"
RL="$DIR/run-local-ci.sh"
mkdir -p "$TMP/proj"; M=$(make_repo proj/r); WT="$M/.claude/worktrees/issue-5"; mkdir -p "$M/.claude/worktrees"
git -C "$M" worktree add -q "$WT" -b agent/issue-5 >/dev/null 2>&1
mkdir -p "$WT/bin" && cp "$M/bin/ci" "$WT/bin/ci"        # 가짜 bin/ci 는 미추적이라 워크트리에 따로 둔다
export ISSUE_RUNNER_REPOS_CONF="$TMP/no-such-repos.conf"  # 머신의 repos.conf 에 안 걸리게
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m wt
WSHA=$(head_of "$WT"); MSLUG=$(slug_of "$M")
rc=0; ISSUE_RUNNER_PROJECTS_ROOT="$TMP/proj" bash "$RL" o/r 5 >/dev/null 2>&1 || rc=$?
assert_eq "run-local-ci pass" "$rc" 0
assert_file "run-local-ci 메인 슬러그 result" "$HOME/.claude/.local-ci/$MSLUG/$WSHA.result"
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved
NEW=$(head_of "$WT")
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved2   # NEW 는 이제 옛 HEAD
rc=0; "$SUT" run "$WT" "$NEW" --slug "$MSLUG" >/dev/null 2>&1 || rc=$?
assert_eq "워크트리 HEAD 이동 → 폐기 2" "$rc" 2

echo "[ci-gate] 12) 게이트 — 다른 슬러그의 result 도 SHA 로 찾고, 결과 없음은 실행 중/대기열/없음으로 안내"
GATE="$DIR/../hooks/ci-gate-before-pr-merge.sh"
G=$(make_repo g1); GSHA=$(head_of "$G")
# gh 스텁을 게이트용으로 교체 — PR head SHA 는 GATE_SHA, 파일은 코드(문서 면제 아님)
cat > "$TMP/stub/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$*" in
  *"pr view"*headRefOid*) printf '{"headRefOid":"%s"}\n' "${GATE_SHA:?}" ;;
  *"pr view"*files*) echo '{"files":[{"path":"app/x.rb"}]}' ;;
  *) echo '' ;;
esac
exit 0
STUB
run_gate() {  # <sha> → rc, stderr 를 $TMP/gate.err 에
  printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' \
    | (cd "$G" && GATE_SHA="$1" bash "$GATE") >/dev/null 2>"$TMP/gate.err"
}
# (a) cwd 슬러그엔 없고 딴 슬러그에 pass → 통과(exit 0)
mkdir -p "$HOME/.claude/.local-ci/some_worktree_slug"
echo pass > "$HOME/.claude/.local-ci/some_worktree_slug/$GSHA.result"
rc=0; run_gate "$GSHA" || rc=$?
assert_eq "게이트 교차 슬러그 pass" "$rc" 0
# (b) 딴 슬러그에 fail → 차단 + 로그 꼬리
echo fail > "$HOME/.claude/.local-ci/some_worktree_slug/$GSHA.result"
echo "boom" > "$HOME/.claude/.local-ci/some_worktree_slug/$GSHA.log"
rc=0; run_gate "$GSHA" || rc=$?
assert_eq "게이트 교차 슬러그 fail" "$rc" 2
grep -q boom "$TMP/gate.err" && ok || bad "게이트 fail 로그 꼬리 없음: $(cat "$TMP/gate.err")"
rm -rf "$HOME/.claude/.local-ci/some_worktree_slug"
# (c) 결과 없음 + 큐에 없음 → 차단, '큐에도 없습니다'
rc=0; run_gate "$GSHA" || rc=$?
assert_eq "게이트 결과·큐 부재" "$rc" 2
grep -q "큐에도 없습니다" "$TMP/gate.err" && ok || bad "게이트 부재 안내 없음: $(cat "$TMP/gate.err")"
# (d) 실행 중 → '실행 중' + wait 안내 · (e) 대기열 → '대기열 1번째'
G2=$(make_repo g2); G2SHA=$(head_of "$G2")
CI_SLEEP=3 "$SUT" run "$G2" "$G2SHA" >/dev/null 2>&1 &
pg2=$!
wait_status "$G2SHA" running
rc=0; run_gate "$G2SHA" || rc=$?
assert_eq "게이트 실행 중 차단" "$rc" 2
grep -q "실행 중" "$TMP/gate.err" && grep -q "wait $G2SHA" "$TMP/gate.err" && ok || bad "게이트 실행 중 안내: $(cat "$TMP/gate.err")"
"$SUT" run "$G" "$GSHA" >/dev/null 2>&1 &
pg1=$!
wait_status "$GSHA" "queued 1"
rc=0; run_gate "$GSHA" || rc=$?
assert_eq "게이트 대기열 차단" "$rc" 2
grep -q "대기열 1번째" "$TMP/gate.err" && ok || bad "게이트 대기열 안내: $(cat "$TMP/gate.err")"
wait $pg2 $pg1
# 잡이 끝난 뒤엔 같은 SHA 가 통과
rc=0; run_gate "$GSHA" || rc=$?
assert_eq "게이트 완료 후 통과" "$rc" 0

echo "ci-queue: $pass passed, $fail failed"
[ "$fail" = 0 ]
