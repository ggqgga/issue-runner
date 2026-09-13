#!/usr/bin/env bash
# hooks/ci-gate-before-pr-merge.sh 픽스처 테스트 — 네트워크 무접속(gh 는 PATH 스텁).
#
# 게이트는 `gh pr merge` PreToolUse 훅이라 **틀리는 방향이 한쪽으로 치명적**이다: 못 판정한
# 것을 통과시키면 CI 미통과 PR 이 머지로 샌다. 무는 것 셋:
#   ⑴ 대상 파싱 fail-closed — `<번호>`·`<URL>`·`<브랜치>` 어느 형태든 PR 번호를 확인
#      못 하면 exit 2. (gh 가 전부 실패하는 환경으로 고정 재현한다.)
#   ⑵ `--repo o/r` 분기(#47) — 계정 전체 머저는 cwd 밖 레포를 머지한다. 캐시 pass 는
#      통과(0), 캐시 부재는 차단(2). ROOT 는 repo-dir.sh, 결과는 ci-queue.sh 가 준다.
#   ⑶ rollup 폴백의 **SUCCESS-only allowlist**(#60) — 통과 모양을 정의하고 그 외를 전부
#      negate 한다. denylist 면 미열거 종결값(STARTUP_FAILURE·오타 conclusion)이 새어
#      비통과 PR 이 머지로 흘러간다.
#
# 거짓 초록 주의 — 게이트에는 **문서 전용 면제**(변경 파일이 전부 Plans/·Docs/·*.md)가
# 있고 그 경로도 exit 0 이다. 그래서 통과를 기대하는 픽스처의 스텁은 `--json files` 에
# **코드 파일**을 돌려주고, 면제 문구가 stderr 에 없음을 함께 단언한다.
#
# bats 미도입 레포라 다른 scripts/tests/*.test.sh 와 같은 순수 bash assert 관행을 따른다.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$(cd "$DIR/.." && pwd)/hooks/ci-gate-before-pr-merge.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub" "$tmp/home" "$tmp/proj/r" "$tmp/cwd"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }

# 게이트는 scripts/ 를 ISSUE_RUNNER_SCRIPTS → 훅의 ../scripts → 설치 경로 순으로 찾는다.
# 테스트는 첫째를 명시해 훅의 상대경로 추적에 기대지 않는다(HOME 을 갈아끼우므로 셋째도 죽는다).
run_gate() {  # run_gate <cmd 문자열> — RC/ERR 를 채운다
  RC=0
  printf '{"tool_input":{"command":"%s"}}' "$1" \
    | (cd "$tmp/cwd" && HOME="$tmp/home" ISSUE_RUNNER_SCRIPTS="$DIR" \
        ISSUE_RUNNER_PROJECTS_ROOT="$tmp/proj" PATH="$tmp/stub:$PATH" \
        bash "$GATE") >/dev/null 2>"$tmp/err" || RC=$?
  ERR=$(cat "$tmp/err")
}

echo "── ⑴ 대상 파싱 fail-closed (gh 전부 실패) ─────────────────────────"

# gh 가 전부 실패 → 어느 형태든 PR 번호를 못 얻는다. cwd 는 git 레포가 아니라(=$tmp/cwd)
# 로컬 CI 분기도 타지 않는다 — 남는 경로는 "식별 불가 → 차단" 하나뿐이다.
printf '#!/bin/sh\nexit 1\n' > "$tmp/stub/gh"
chmod +x "$tmp/stub/gh"
for form in "123" "https://github.com/o/r/pull/123" "feature-branch"; do
  run_gate "gh pr merge $form --squash"
  [ "$RC" = 2 ] && ok || bad "⑴ gh pr merge $form → exit $RC (기대 2 — 게이트 우회)"
done

echo "── ⑵ --repo 분기: 로컬 CI 캐시 판정 (#47) ────────────────────────"

# 가짜 레포 체크아웃 — 실행 가능한 bin/ci 가 있으면 게이트가 로컬 CI 분기를 탄다.
mkdir -p "$tmp/proj/r/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/proj/r/bin/ci"
chmod +x "$tmp/proj/r/bin/ci"
# 결과 캐시는 ci-queue.sh 가 slug 무관하게 $HOME/.claude/.local-ci/*/<sha>.result 로 찾는다 —
# 테스트가 slug 를 계산해 맞출 필요가 없다(옛 인라인 스모크의 pwd -P + sed 춤은 불필요).
cache="$tmp/home/.claude/.local-ci/r"
mkdir -p "$cache"
cat > "$tmp/stub/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *"pr view"*headRefOid*) echo '{"headRefOid":"deadbeef00"}' ;;
  # 코드 파일을 낸다 — 문서 전용 면제(그쪽도 exit 0)로 초록이 나면 안 된다.
  *"pr view"*files*)      echo '{"files":[{"path":"bin/ci"}]}' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$tmp/stub/gh"

echo pass > "$cache/deadbeef00.result"
run_gate "gh pr merge 5 --repo o/r --squash"
[ "$RC" = 0 ] && ok || bad "⑵ 캐시 pass → exit $RC (기대 0 — 게이트가 o/r 를 안 봤다) err=[$ERR]"
case "$ERR" in *"문서 전용"*) bad "⑵ 통과가 캐시가 아니라 문서 전용 면제에서 났다" ;; *) ok ;; esac

rm -f "$cache/deadbeef00.result"
run_gate "gh pr merge 5 --repo o/r --squash"
[ "$RC" = 2 ] && ok || bad "⑵ 캐시 부재 → exit $RC (기대 2 — fail-closed)"

echo "── ⑶ rollup 폴백 SUCCESS-only allowlist (#60) ────────────────────"

# 로컬 bin/ci 를 치워 폴백을 강제한다.
rm -rf "$tmp/proj/r/bin"
gate_rollup() {  # gate_rollup <rollup JSON 배열>
  cat > "$tmp/stub/gh" <<STUB
#!/bin/sh
case "\$*" in
  *"pr view"*statusCheckRollup*) echo '{"statusCheckRollup":$1}' ;;
  *"pr view"*files*)             echo '{"files":[{"path":"bin/ci"}]}' ;;
  *"pr view"*number*)            echo '{"number":5}' ;;
  *) echo '' ;;
esac
STUB
  chmod +x "$tmp/stub/gh"
  run_gate "gh pr merge 5 --repo o/r --squash"
}

# ① 전부 SUCCESS (check-run conclusion + 레거시 commit-status state 혼합) → 통과 보존
gate_rollup '[{"status":"COMPLETED","conclusion":"SUCCESS"},{"state":"SUCCESS"}]'
[ "$RC" = 0 ] && ok || bad "⑶① 전부 SUCCESS → exit $RC (기대 0) err=[$ERR]"
case "$ERR" in *"문서 전용"*) bad "⑶① 통과가 문서 전용 면제에서 났다" ;; *) ok ;; esac

# ② denylist 시절에도 잡던 종결값은 여전히 차단
for c in FAILURE CANCELLED TIMED_OUT; do
  gate_rollup "[{\"status\":\"COMPLETED\",\"conclusion\":\"$c\"}]"
  [ "$RC" = 2 ] && ok || bad "⑶② $c → exit $RC (기대 2)"
done

# ③ 미완료(pending) 포함 → 차단
gate_rollup '[{"status":"IN_PROGRESS"}]'
[ "$RC" = 2 ] && ok || bad "⑶③ 미완료 → exit $RC (기대 2)"

# ④ allowlist 핵심: 열거되지 않은 종결값(STARTUP_FAILURE)이 SUCCESS 와 섞여도 차단
gate_rollup '[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"STARTUP_FAILURE"}]'
[ "$RC" = 2 ] && ok || bad "⑶④ STARTUP_FAILURE → exit $RC (기대 2 — denylist 회귀)"

# ⑤ 미래/오타 conclusion → 차단
gate_rollup '[{"status":"COMPLETED","conclusion":"UNKNOWN_STATE"}]'
[ "$RC" = 2 ] && ok || bad "⑶⑤ 알 수 없는 conclusion → exit $RC (기대 2)"

# ⑥ 체크가 하나도 없으면 통과가 아니라 차단
gate_rollup '[]'
[ "$RC" = 2 ] && ok || bad "⑶⑥ 빈 rollup → exit $RC (기대 2)"

echo "ci-gate.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
