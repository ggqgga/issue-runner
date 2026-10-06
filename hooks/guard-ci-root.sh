#!/usr/bin/env bash
# guard-ci-root.sh — 로컬 CI(bin/ci)가 도는 워크트리에서 그 CI 를 깨는 세션 동작을 막는다 (#586).
#
# 왜: push 훅(local-ci.sh)은 CI 를 백그라운드로 큐에 넣고 즉시 돌아온다 — 세션은 같은 워크트리에서
# 계속 일한다. 2026-10-05 맥북 CI 실패 151건 중 환경 원인 46건이 전부 이 겹침이었다:
#   - 같은 워크트리에서 `bin/rails test` → 병렬 테스트가 시작 시 test DB 를 비워 CI 의 픽스처 소실·잠금
#   - CI 도중 커밋·HEAD 이동 → 실시간 HEAD 를 읽는 테스트 불일치, 테스트 중인 파일이 바뀜
#   - CI 도중 `git worktree remove --force` → 실행 중 ROOT 삭제
# 큐(scripts/ci-queue.sh)는 bin/ci 끼리만 줄 세운다. 이 훅이 그 밖의 세션 동작을 같은 ROOT 에서 막는다.
#
# 막는 것(대상 디렉터리가 실행 중 CI 의 ROOT 안일 때만 — `ci-queue.sh busy`):
#   ⑴ 테스트 실행: `rails test…`(bin/rails·bundle exec 포함) · `bin/ci`
#   ⑵ HEAD·워킹트리를 움직이는 git: commit·reset·checkout·switch·rebase·merge·pull·cherry-pick·revert·am
#   ⑶ `git worktree remove <경로>` — 대상은 cwd 가 아니라 경로 인자
# 대상 디렉터리 = 입력 cwd → 선두 `cd X &&|;`(scripts/lib/hook-cmd.sh, local-ci.sh 와 같은 해석) →
# `git -C X`. 해석은 좁다: 서브셸·두 번째 cd 는 따라가지 않는다.
# 못 막는 것: CI 보다 **먼저** 시작된 테스트(실행 중 프로세스는 훅 밖), 사람 터미널(훅은 세션 안에서만).
#
# 차단은 exit 2 + stderr(ci-gate-before-pr-merge.sh 와 같은 관례) — 세션이 사유와 wait 명령을 바로 본다.
# 기다리지 않고 거부하는 이유: bin/ci 는 수 분이고 훅에는 타임아웃이 있다.
# 그 밖의 모든 실패(jq 부재·ci-queue.sh 못 찾음·경로 해석 실패)는 통과(fail-open) — 이 훅은 보조 가드다.
# PreToolUse(Bash). macOS bash 3.2 대상.
set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
base=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# 빠른 거름 — 관심 명령이 없으면 프로세스를 더 띄우지 않는다
G='git([[:space:]]+-[Cc][[:space:]]+[^[:space:];|&]+)*[[:space:]]+'
TEST_RE='(^|[[:space:];|&(/])rails[[:space:]]+test([:[:space:];|&)]|$)|(^|[[:space:];|&(])(\./)?bin/ci([[:space:];|&)]|$)'
HEAD_RE="${G}(commit|reset|checkout|switch|rebase|merge|pull|cherry-pick|revert|am)([[:space:];|&)]|\$)"
RM_RE="${G}worktree[[:space:]]+remove([[:space:]]|\$)"
printf '%s' "$cmd" | grep -qE "$TEST_RE|$HEAD_RE|$RM_RE" || exit 0

[ -n "$base" ] && [ -d "$base" ] || base=$PWD

# scripts/ 위치 — local-ci.sh 와 같은 규칙(환경변수 → 이 파일 실제 위치의 ../scripts → 설치 경로)
src="$0"
while [ -L "$src" ]; do
  d=$(cd "$(dirname "$src")" && pwd); src=$(readlink "$src")
  case "$src" in /*) ;; *) src="$d/$src" ;; esac
done
S=""
for cand in "${ISSUE_RUNNER_SCRIPTS:-}" "$(cd "$(dirname "$src")/.." && pwd)/scripts" "$HOME/.claude/skills/issue-runner/scripts"; do
  [ -n "$cand" ] && [ -x "$cand/ci-queue.sh" ] && [ -f "$cand/lib/hook-cmd.sh" ] && { S="$cand"; break; }
done
[ -n "$S" ] || exit 0
# shellcheck source=scripts/lib/hook-cmd.sh
. "$S/lib/hook-cmd.sh"

dir=$base
lead=$(lead_cd_path "$cmd")
[ -n "$lead" ] && dir=$(resolve_path "$lead" "$base")
gitc=$(printf '%s' "$cmd" | sed -n -E 's/.*git[[:space:]]+-C[[:space:]]+("([^"]*)"|([^[:space:];|&]+)).*/\2\3/p' | head -1)
gdir=$dir
[ -n "$gitc" ] && gdir=$(resolve_path "$gitc" "$dir")

block() {  # <대상> <무엇>
  local sha
  sha=$("$S/ci-queue.sh" busy "$1" 2>/dev/null) || return 0
  printf '⛔ 로컬 CI 실행 중 — %s 에서 bin/ci(%s)가 돌고 있습니다. 같은 워크트리에서 %s 을(를) 하면 CI 가 코드와 무관한 환경 원인으로 깨집니다(#586).\n끝난 뒤 다시 실행하세요. 기다리기: 이 명령을 Bash run_in_background=true 로 → %s wait %s\n' \
    "$1" "${sha:0:8}" "$2" "$S/ci-queue.sh" "$sha" >&2
  exit 2
}

printf '%s' "$cmd" | grep -qE "$TEST_RE" && block "$dir" "테스트 실행"
printf '%s' "$cmd" | grep -qE "$HEAD_RE" && block "$gdir" "커밋·HEAD 이동"
if printf '%s' "$cmd" | grep -qE "$RM_RE"; then
  wt=$(printf '%s' "$cmd" | sed -n -E 's/.*worktree[[:space:]]+remove([[:space:]]+-[^[:space:]]+)*[[:space:]]+("([^"]*)"|([^-[:space:];|&][^[:space:];|&]*)).*/\3\4/p' | head -1)
  [ -n "$wt" ] && block "$(resolve_path "$wt" "$gdir")" "워크트리 삭제"
fi
exit 0
