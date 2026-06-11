#!/usr/bin/env bash
# usage: make-worktree.sh <owner/repo> <issue-number>
# 레포가 ~/Projects/<name>에 없으면 clone, 있으면 fetch 후
# .claude/worktrees/issue-<N> 에 agent/issue-<N> 브랜치로 worktree 생성.
# 성공 시 worktree 절대경로를 stdout 마지막 줄에 출력.
set -euo pipefail
repo="${1:?usage: make-worktree.sh <owner/repo> <num>}"
num="${2:?usage: make-worktree.sh <owner/repo> <num>}"
dir="$("$(cd "$(dirname "$0")" && pwd)/repo-dir.sh" "$repo")"
branch="agent/issue-$num"
wt="$dir/.claude/worktrees/issue-$num"

[ -d "$dir/.git" ] || gh repo clone "$repo" "$dir"
git -C "$dir" fetch origin --prune

default=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name')

# .claude/ 를 레포 오염 없이 로컬에서만 무시
mkdir -p "$dir/.git/info"
grep -qx '.claude/' "$dir/.git/info/exclude" 2>/dev/null \
  || echo '.claude/' >> "$dir/.git/info/exclude"

if [ -d "$wt" ]; then
  echo "exists: $wt" >&2
  echo "$wt"
  exit 0
fi

mkdir -p "$dir/.claude/worktrees"
if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  # 원격에 브랜치가 이미 있음(보수 재투입 케이스) — 그 위에 worktree
  git -C "$dir" worktree add "$wt" -B "$branch" "origin/$branch" >/dev/null
else
  git -C "$dir" worktree add "$wt" -b "$branch" "origin/$default" >/dev/null
fi
echo "$wt"
