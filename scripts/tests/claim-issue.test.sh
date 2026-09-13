#!/usr/bin/env bash
# claim-issue.sh 픽스처 테스트 — 네트워크 무접속(gh 를 PATH 스텁으로 가로챈다).
# #281: claim 이 이슈에 `agent:claimed` 를 붙이는 그 자리에서 같은 레포의 열린
# `agent/issue-<N>` PR 에 issue-runner 칸을 미러(`flow:claimed` 부착·`flow:agent-ready` 제거)한다.
# 미러는 best-effort — PR 이 없으면 무동작, PR 편집 실패는 claim 을 되돌리지 않고 stderr 한 줄.
# 두 절로 나뉜다: 앞은 PR 미러(#281), 뒤는 원자적 잠금·경합·스테일 인수(#108).
# 두 절의 gh 스텁은 계약이 달라(서브커맨드 디스패치 대 글로브 + 파일 sentinel) 따로 둔다.
# bats 미도입 레포라 transition.test.sh 와 같은 순수 bash assert + 상태 있는 스텁 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$DIR/claim-issue.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# SUT 는 sibling 경로로 gh-login.sh 를 부른다 — SUT 사본과 가짜를 tmp 에 나란히 둔다.
cp "$SUT" "$tmp/claim-issue.sh"
cp -R "$DIR/lib" "$tmp/lib"   # SUT 사본이 include 하는 라이브러리 (#426)
SUT="$tmp/claim-issue.sh"
printf '#!/usr/bin/env bash\necho tester\n' > "$tmp/gh-login.sh"
chmod +x "$tmp/gh-login.sh"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 상태: $STUB_DIR/claimed(이슈 edit 이 만든다) · $STUB_DIR/prs.json(pr list 응답)
# 스위치: STUB_PRLIST_FAIL=1(pr list 실패) · STUB_PRLIST_NOISE=1(pr list 성공인데 stderr 에 한 줄)
#         · STUB_PREDIT_FAIL=1(pr edit 실패)
# $STUB_DIR/calls.log 에 **쓰기 호출만** 남긴다: issue-edit N <args> / pr-edit N <args>
set -uo pipefail
sub="${1:-} ${2:-}"
shift 2 || true
case "$sub" in
  "issue view")
    if [ -f "$STUB_DIR/claimed" ]; then echo '{"state":"OPEN","labels":[{"name":"agent:claimed"}]}'
    else echo '{"state":"OPEN","labels":[]}'; fi ;;
  "issue edit")
    num=$1; shift
    printf 'issue-edit %s %s\n' "$num" "$*" >> "$STUB_DIR/calls.log"
    : > "$STUB_DIR/claimed" ;;
  "pr list")
    # (#420) 인자를 **단언**한다 — head 브랜치 정확 일치(`agent/issue-5` 가 `agent/issue-50` 을 안 문다)
    # 와 열린 PR 한정은 SUT 의 계약인데, 인자를 무시하는 스텁은 그 계약이 사라져도 초록이다.
    case " $* " in
      *" --head agent/issue-5 "*) ;; *) echo "gh: stub — --head agent/issue-5 없음: $*" >&2; exit 1 ;;
    esac
    case " $* " in
      *" --state open "*) ;; *) echo "gh: stub — --state open 없음: $*" >&2; exit 1 ;;
    esac
    [ "${STUB_PRLIST_FAIL:-0}" = "1" ] && { echo "gh: connection refused" >&2; exit 1; }
    # 성공인데 stderr 에 뭔가 찍는 gh(업데이트 알림 등) — stdout JSON 과 섞이면 안 된다.
    [ "${STUB_PRLIST_NOISE:-0}" = "1" ] && echo "! A new release of gh is available" >&2
    cat "$STUB_DIR/prs.json" ;;
  "pr edit")
    num=$1; shift
    printf 'pr-edit %s %s\n' "$num" "$*" >> "$STUB_DIR/calls.log"
    [ "${STUB_PREDIT_FAIL:-0}" = "1" ] && { echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; }
    exit 0 ;;
  "api repos/o/r/git/ref/heads/agent/issue-5")
    # 원격 브랜치 있음(재디스패치) — 잠금 앵커는 이 sha. PR 존재 여부와는 별개다.
    echo "cafebabecafebabecafebabecafebabecafebabe" ;;
  "api repos/o/r/git/refs") echo '{"ref":"refs/issue-runner/claim/5/x"}' ;;
  *) echo "gh: unexpected call: $sub $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

pass=0
fail=0
check() {
  if [ "$2" = "ok" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "  ✗ $1"; fi
}
ck() { check "$1" "$([ "$2" = "$3" ] && echo ok || echo no)"; }

# run <prs.json> — 스텁으로 SUT 를 돌리고 exit code 를 RC 에.
run() {
  rm -rf "$tmp/state"; mkdir -p "$tmp/state"
  printf '%s\n' "$1" > "$tmp/state/prs.json"
  : > "$tmp/state/calls.log"
  STUB_DIR="$tmp/state" STUB_PRLIST_FAIL="${STUB_PRLIST_FAIL:-0}" STUB_PRLIST_NOISE="${STUB_PRLIST_NOISE:-0}" \
  STUB_PREDIT_FAIL="${STUB_PREDIT_FAIL:-0}" \
  CLAIM_STALE_WAIT=0 PATH="$tmp/bin:$PATH" bash "$SUT" o/r 5 >"$tmp/out" 2>"$tmp/err"
  RC=$?
}
pr_edits() { grep -c '^pr-edit ' "$tmp/state/calls.log"; }

# ── ① 열린 agent/issue-5 PR 이 있다 → PR 에 flow:claimed 부착·flow:agent-ready 제거 ──
run '[{"number":42}]'
ck "PR 있음: exit 0" "$RC" 0
check "PR 있음: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 있음: PR edit 1회" "$(pr_edits)" 1
check "PR 있음: PR #42 에 --add-label flow:claimed" \
  "$(grep -q '^pr-edit 42 .*--add-label flow:claimed' "$tmp/state/calls.log" && echo ok || echo no)"
check "PR 있음: PR #42 에 --remove-label flow:agent-ready" \
  "$(grep -q '^pr-edit 42 .*--remove-label flow:agent-ready' "$tmp/state/calls.log" && echo ok || echo no)"
check "PR 있음: --repo 전달" \
  "$(grep -q '^pr-edit 42 .*--repo o/r' "$tmp/state/calls.log" && echo ok || echo no)"
# 이슈 쪽 claim 은 PR 미러와 무관하게 그대로 — 이슈에 PR 전용 라벨을 붙이지 않는다.
check "PR 있음: 이슈 edit 은 agent:claimed 만" \
  "$(grep -q '^issue-edit 5 .*--add-label agent:claimed' "$tmp/state/calls.log" \
     && ! grep -q '^issue-edit 5 .*flow:' "$tmp/state/calls.log" && echo ok || echo no)"

# ── ② 열린 PR 이 없다 → PR 편집 없음, claim 은 그대로 ─────────────────────────
run '[]'
ck "PR 없음: exit 0" "$RC" 0
check "PR 없음: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 없음: PR edit 0회" "$(pr_edits)" 0
check "PR 없음: stderr 에 미러 경고 없음" "$(grep -q '미러' "$tmp/err" && echo no || echo ok)"

# ── ③ PR 편집 실패 → claim 성공 유지(exit 0·claimed 출력) + stderr 한 줄 ────────
STUB_PREDIT_FAIL=1 run '[{"number":42}]'
ck "PR 편집 실패: exit 0(claim 유지)" "$RC" 0
check "PR 편집 실패: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 편집 실패: PR edit 시도 1회" "$(pr_edits)" 1
check "PR 편집 실패: stderr 한 줄(PR 번호·best-effort)" \
  "$(grep -q 'PR #42 미러 실패(best-effort' "$tmp/err" && echo ok || echo no)"
ck "PR 편집 실패: stderr 정확히 1줄" "$(wc -l < "$tmp/err" | tr -d ' ')" 1

# ── ③-b (#420) PR 조회 **성공**인데 gh 가 stderr 에 한 줄 찍는다 → 미러는 그대로 간다 ──
# `2>&1` 로 받으면 그 줄이 JSON 을 오염시켜 jq 가 비고 미러가 **조용히** 생략된다(fail-open).
# stderr 는 따로 받고, 실패했을 때만 note 문구에 합친다.
STUB_PRLIST_NOISE=1 run '[{"number":42}]'
ck "조회 stderr 잡음: exit 0" "$RC" 0
ck "조회 stderr 잡음: PR edit 1회(미러 생략 안 됨)" "$(pr_edits)" 1
check "조회 stderr 잡음: 미러 경고 없음(성공 경로)" "$(grep -q '미러 안 됨\|미러 실패' "$tmp/err" && echo no || echo ok)"

# ── ④ PR 조회 자체 실패 → "PR 없음" 이 아니라 조회 실패다: claim 은 유지, 편집 시도 없이 stderr ──
STUB_PRLIST_FAIL=1 run '[{"number":42}]'
ck "PR 조회 실패: exit 0(claim 유지)" "$RC" 0
check "PR 조회 실패: claimed 출력" "$(grep -q '^claimed: o/r#5$' "$tmp/out" && echo ok || echo no)"
ck "PR 조회 실패: PR edit 0회" "$(pr_edits)" 0
check "PR 조회 실패: stderr 한 줄" \
  "$(grep -q 'PR 조회 실패(best-effort' "$tmp/err" && echo ok || echo no)"
# 실패 사유(gh 의 stderr 마지막 줄)는 note 에 실려야 한다 — 갈라 받은 stderr 가 버려지면 안 된다.
check "PR 조회 실패: gh stderr 사유가 note 에 실린다" \
  "$(grep -q 'PR 조회 실패(best-effort.*connection refused' "$tmp/err" && echo ok || echo no)"

# ── 원자적 잠금 (#108) ────────────────────────────────────────────────────────
# 라벨 부착은 멱등이라 잠금이 못 된다 — 두 세션이 사전 재확인을 함께 통과하면 둘 다
# "성공" 한다. 진짜 원자적인 프리미티브는 create-only ref(POST /git/refs → 이미 있으면 422)뿐이고,
# 스테일 잠금 인수는 **형제** takeover ref 가 한 번 더 중재한다. 여기서 무는 것:
#   ⓐ 경합 — 사전 재확인을 둘 다 통과해도 claim 은 정확히 하나
#   ⓑ 스테일 잠금(커밋 0 으로 죽은 attempt) → 재디스패치가 막히지 않는다
#   ⓒ 스테일 잠금에 신규 세션 **둘 동시** → takeover 가 중재해 여전히 하나
#   ⓓ takeover 까지 스테일 → fail-closed(인수의 인수를 허용하면 무한 후퇴 끝에 이중 claim)
#   ⓔ~ⓗ fail-closed 넷 — 잠금 생성이 422 아닌 이유로 실패 · 기본 브랜치 조회 실패 ·
#      앵커 sha 조회 실패 · 잠금 후 재조회 실패
#   ⓘ live-holder 지연 — 라벨이 늦게 뜨는 살아있는 소유자를 덮치지 않는다
#
# 이 절의 스텁은 위 미러 절과 다른 계약이다(글로브 매칭 + 파일 sentinel 상태)이라
# 따로 둔다. **D/F 충돌은 반드시 재현한다**: git ref 네임스페이스는 파일시스템처럼 동작해
# 앵커 ref 가 있으면 그 하위 자식 ref 는 거부된다(실측 422 `Reference update failed` —
# `already exists` 가 아니다). takeover 는 정의상 1차 잠금이 있을 때만 시도되므로 자식
# 경로를 쓰면 인수가 **항상** 실패한다. 이 규칙이 없으면 스텁이 불가능한 동작을 성공으로
# 흉내내 그 회귀를 통째로 놓친다. 패턴은 **앵커 무관**이어야 한다 — 자식형만
# 슬래시-takeover 를 포함하고 형제형(하이픈)은 포함하지 않으므로, 앵커가 `base` 든 40자
# sha 든 규칙이 그대로 성립한다.
LST="$tmp/lockstate"
mkdir -p "$tmp/lockbin" "$LST"

# 잠금 절 전용 gh 스텁 — 상태는 $LST 의 파일 sentinel(lock·takeover·claimed), 변주는 env 스위치.
#   STUB_LOCK_401=1     잠금 ref 생성이 422 아닌 이유(401)로 실패
#   STUB_LOCK_EXISTS=1  잠금 ref 는 늘 이미 존재(남이 만든 스테일 잠금 — sentinel 무시)
#   STUB_NO_DEFAULT=1   기본 브랜치 조회 실패
#   STUB_NO_ANCHOR=1    기본 브랜치는 알아냈지만 그 head sha 조회 실패
#   STUB_RECHECK_FAIL=1 잠금 후 재조회 실패(단, edit sentinel 이 있으면 post-check 는 통과시킨다)
#   STUB_COUNTER=<파일> 재조회를 호출별로 세어 앞 STUB_EMPTY_UNTIL 회만 "라벨 없음" 을 낸다
cat > "$tmp/lockbin/gh" <<STUB
#!/bin/sh
case "\$*" in
  *"--json labels,state"*) echo '{"state":"OPEN","labels":[]}' ;;
  *"--json labels"*)
    if [ -n "\${STUB_COUNTER:-}" ]; then
      n=0; [ -f "\$STUB_COUNTER" ] && n=\$(cat "\$STUB_COUNTER")
      n=\$((n + 1)); echo "\$n" > "\$STUB_COUNTER"
      if [ "\$n" -le "\${STUB_EMPTY_UNTIL:-0}" ]; then echo '{"labels":[]}'
      else echo '{"labels":[{"name":"agent:claimed"}]}'; fi
    elif [ -f "$LST/claimed" ]; then echo '{"labels":[{"name":"agent:claimed"}]}'
    elif [ "\${STUB_RECHECK_FAIL:-0}" = 1 ]; then exit 1
    else echo '{"labels":[]}'; fi ;;
  *"git/ref/heads/agent/issue-5"*) exit 1 ;;      # 원격 브랜치 없음 → 앵커 base
  *".default_branch"*)
    [ "\${STUB_NO_DEFAULT:-0}" = 1 ] && exit 1
    echo "main" ;;
  *"git/ref/heads/main"*)
    [ "\${STUB_NO_ANCHOR:-0}" = 1 ] && exit 1
    # 40자 hex — claim-issue.sh 가 앵커 sha 형태를 검증한다
    echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
  *"git/refs"*"/takeover"*)   # 자식 경로 = D/F 충돌이라 항상 거부된다
    echo '{"message":"Reference update failed","status":"422"}'; exit 1 ;;
  *"git/refs"*takeover*)
    if [ -f "$LST/takeover" ]; then
      echo '{"message":"Reference already exists","status":"422"}'; exit 1
    fi
    : > "$LST/takeover"; echo '{"ref":"refs/issue-runner/claim/5/base-takeover"}' ;;
  *"git/refs"*)
    if [ "\${STUB_LOCK_401:-0}" = 1 ]; then
      echo '{"message":"Bad credentials","status":"401"}'; exit 1
    fi
    if [ "\${STUB_LOCK_EXISTS:-0}" = 1 ] || [ -f "$LST/lock" ]; then
      echo '{"message":"Reference already exists","status":"422"}'; exit 1
    fi
    : > "$LST/lock"; echo '{"ref":"refs/issue-runner/claim/5/base"}' ;;
  *"issue edit"*) : > "$LST/claimed" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$tmp/lockbin/gh"

reset_lock() { rm -f "$LST/lock" "$LST/takeover" "$LST/claimed" "$LST/c1" "$LST/c2"; }
run_lock() {  # run_lock — LOUT/RC 를 채운다 (env 스위치는 호출자가 앞에 붙인다)
  RC=0
  LOUT=$(PATH="$tmp/lockbin:$PATH" CLAIM_STALE_WAIT=0 bash "$SUT" o/r 5 2>"$tmp/lerr") || RC=$?
}
claimed_out() { case "$LOUT" in *"claimed: o/r#5"*) echo ok ;; *) echo no ;; esac; }
# fail-closed 판정은 exit code·"claimed:" 부재만으로는 약하다 — claim 을 진행했는데 그
# 뒤(post-check)에서 죽어도 같은 관측이 나온다. "라벨 부착(gh issue edit)이 **아예
# 일어나지 않았다**" 를 sentinel 로 직접 단정한다.
no_edit() {  # no_edit <케이스명>
  ck "$1: exit 1" "$RC" 1
  check "$1: claim 안 됨" "$([ "$(claimed_out)" = no ] && echo ok || echo no)"
  check "$1: 라벨 부착까지 가지 않았다(fail-open 아님)" \
    "$([ ! -f "$LST/claimed" ] && echo ok || echo no)"
}

# ── ⓐ 경합: 사전 재확인은 둘 다 통과하지만 잠금은 하나만 잡는다 ───────────────
#     패배자의 재조회는 승자가 붙인 agent:claimed 를 본다 → 정확히 1회만 "claimed:".
reset_lock
wins=0
run_lock; [ "$(claimed_out)" = ok ] && wins=$((wins + 1))
run_lock; [ "$(claimed_out)" = ok ] && wins=$((wins + 1))
ck "ⓐ 경합: 통과 1회(이중 claim 아님)" "$wins" 1
ck "ⓐ 경합: 패배자 exit 1" "$RC" 1

# ── ⓑ 스테일 잠금(잠금만 남고 라벨 없음) → 재디스패치가 막히지 않는다 ─────────
reset_lock; : > "$LST/lock"      # 커밋 0 으로 죽은 attempt 의 잔여 잠금
run_lock
check "ⓑ 스테일 잠금: 인수해 진행(재디스패치 안 막힘)" "$(claimed_out)"

# ── ⓒ 스테일 잠금에 신규 세션 둘 동시 → takeover 만이 중재자 ─────────────────
# 1차 잠금은 이미 남이 만든 것이라 이들 사이의 중재력이 없다. takeover ref 가 중재하지
# 않으면 둘 다 라벨 없음을 보고 둘 다 claim 한다(원자성 재파괴).
# 두 호출을 순차로 돌리므로, 승자가 붙인 라벨을 패배자의 **1차 재조회**가 보면 takeover 에
# 닿기 전에 "경합 패배" 로 닫혀 이 경로를 검증하지 못한다(동시 실행이 아닌 데서 오는 인공물).
# 그래서 재조회를 호출별 카운터로 제어해 "둘 다 대기창 내내 라벨 없음" 을 고정한다.
# 둘 다 같은 EMPTY_UNTIL=1 을 쓴다 — 중재가 없으면 B 도 edit 까지 가고 그때의 post-check
# (2회차)는 부착을 보게 되므로, 이중 claim 이 wins=2 로 그대로 드러난다(실환경 등가).
reset_lock
wins=0
STUB_LOCK_EXISTS=1 STUB_COUNTER="$LST/c1" STUB_EMPTY_UNTIL=1 run_lock
[ "$(claimed_out)" = ok ] && wins=$((wins + 1))
STUB_LOCK_EXISTS=1 STUB_COUNTER="$LST/c2" STUB_EMPTY_UNTIL=1 run_lock
[ "$(claimed_out)" = ok ] && wins=$((wins + 1))
ck "ⓒ 스테일 동시 2회: 통과 1회(인수 중재 성립)" "$wins" 1
check "ⓒ 스테일 동시 2회: 패배 사유가 인수 경합" \
  "$(grep -q '인수 경합 패배' "$tmp/lerr" && echo ok || echo no)"

# ── ⓓ takeover 까지 스테일(인수한 워커도 커밋 0 으로 사망) → fail-closed ──────
#     인수의 인수를 허용하면 무한 후퇴 끝에 이중 claim 이 되므로 의도된 절충이다.
reset_lock; : > "$LST/lock"; : > "$LST/takeover"
run_lock
no_edit "ⓓ takeover 스테일"

# ── ⓔ 잠금 생성이 422 아닌 이유로 실패 → 중재 결과를 모른다 → claim 금지 ──────
reset_lock
STUB_LOCK_401=1 run_lock
no_edit "ⓔ 잠금 401"

# ── ⓕ 기본 브랜치 조회 실패 → 잠금 앵커를 못 정하므로 claim 금지 ──────────────
reset_lock
STUB_NO_DEFAULT=1 run_lock
no_edit "ⓕ 기본 브랜치 조회 실패"

# ── ⓖ 기본 브랜치는 알아냈지만 그 head sha 를 못 읽는다 ───────────────────────
#     (ⓕ 는 기본 브랜치 가드에서 먼저 걸려 이 앵커 sha 가드를 지나가지 않는다.)
reset_lock
STUB_NO_ANCHOR=1 run_lock
no_edit "ⓖ 앵커 sha 조회 실패"

# ── ⓗ 잠금 후 재조회 자체가 실패 → 소유자 확인 불가 → claim 금지 ─────────────
#     ("라벨 없음" 으로 대체하면 스테일 잠금으로 오인해 살아있는 소유자를 덮친다.)
#     재조회는 edit **전**이라 sentinel 이 없을 때만 실패시킨다 — post-check(edit 후)는
#     통과시켜야, 이 케이스가 "재조회에서 닫혔는지" 를 post-check 사망과 구분해 잡는다.
reset_lock
STUB_LOCK_EXISTS=1 STUB_RECHECK_FAIL=1 run_lock
no_edit "ⓗ 잠금 후 재조회 실패"

# ── ⓘ live-holder 지연: 잠금은 남이 잡았고 라벨은 **늦게** 뜬다 ───────────────
#     재조회가 1회면 "라벨 없음 = 스테일" 로 오판해 살아있는 소유자를 덮친다 → 대기창
#     안에서 반복 조회하다 라벨이 뜨면 패배로 접어야 한다. 첫 조회에만 라벨을 숨긴다.
reset_lock
RC=0
LOUT=$(PATH="$tmp/lockbin:$PATH" CLAIM_STALE_WAIT=2 CLAIM_POLL_STEP=1 \
  STUB_LOCK_EXISTS=1 STUB_COUNTER="$LST/c1" STUB_EMPTY_UNTIL=1 \
  bash "$SUT" o/r 5 2>"$tmp/lerr") || RC=$?
ck "ⓘ live-holder 지연: exit 1(살아있는 소유자를 안 덮쳤다)" "$RC" 1
check "ⓘ live-holder 지연: claim 안 됨" "$([ "$(claimed_out)" = no ] && echo ok || echo no)"
check "ⓘ live-holder 지연: 대기창 안에서 재조회를 반복했다" \
  "$([ "$(cat "$LST/c1")" -ge 2 ] && echo ok || echo no)"
check "ⓘ live-holder 지연: 라벨 부착까지 가지 않았다" \
  "$([ ! -f "$LST/claimed" ] && echo ok || echo no)"

echo "claim-issue: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
