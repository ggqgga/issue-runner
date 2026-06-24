#!/usr/bin/env bash
# usage: cleanup-worktree.sh <repo> <issue-num> [--merged]
# issue-runner/closeout 가 만든 worktree(<repo-dir>/.claude/worktrees/issue-<N>,
# 브랜치 agent/issue-<N>)를 안전하게 제거하는 공유 헬퍼.
# reconcile.sh 와 closeout-reconcile.sh(MERGED 분기)가 같은 로직을 공유한다.
#
# 동작:
#   - worktree 가 이미 없으면 no-op(exit 0, 무출력) — 멱등.
#   - 더티(uncommitted 변경)면 warn JSON 출력 + exit 1 (제거 보류). --merged 여도 유지.
#   - 기본(플래그 없음): 미push 가드 — @{u}..HEAD 가 0 아니거나 upstream 없으면
#     warn JSON + exit 1 (기존 reconcile 동작 보존).
#   - --merged: 미push/upstream-삭제 가드 완화 — squash 머지로 원격 head 가 자동삭제돼
#     @{u} 가 사라지는 함정에서, 머지가 확정된 맥락이라 처분이 안전하므로 건너뛴다.
#     (더티 가드는 --merged 여도 유지.)
#   - 제거 성공 시 무출력 exit 0 (이벤트 JSON 은 호출측 reconcile 이 담당).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
repo="${1:?usage: cleanup-worktree.sh <repo> <issue-num> [--merged]}"
num="${2:?usage: cleanup-worktree.sh <repo> <issue-num> [--merged]}"
merged=0
[ "${3:-}" = "--merged" ] && merged=1

dir=$("$SCRIPT_DIR/repo-dir.sh" "$repo")
branch="agent/issue-$num"
wt="$dir/.claude/worktrees/issue-$num"

[ -d "$wt" ] || exit 0  # 멱등 — 이미 없음

if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
  printf '{"event":"warn","repo":"%s","number":%s,"msg":"worktree dirty — 제거 보류"}\n' "$repo" "$num"
  exit 1
fi

if [ "$merged" != 1 ]; then
  ahead=$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "unknown")
  if [ "$ahead" != "0" ]; then
    printf '{"event":"warn","repo":"%s","number":%s,"msg":"미push 커밋(%s) — 제거 보류"}\n' "$repo" "$num" "$ahead"
    exit 1
  fi
fi

git -C "$dir" worktree remove "$wt" >/dev/null 2>&1 || exit 1
git -C "$dir" branch -D "$branch" >/dev/null 2>&1 || true
exit 0
