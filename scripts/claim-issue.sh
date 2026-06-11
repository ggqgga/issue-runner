#!/usr/bin/env bash
# usage: claim-issue.sh <owner/repo> <issue-number>
# 검색 인덱스 지연 방어: claim 직전에 직접 API로 라벨 재확인(이중 디스패치 방지),
# claim 직후 재조회로 부착 확인.
set -euo pipefail
repo="${1:?usage: claim-issue.sh <owner/repo> <num>}"
num="${2:?usage: claim-issue.sh <owner/repo> <num>}"
me=$(gh api user -q .login)

# 사전 재확인 — 직접 API (인덱스 지연 없음)
pre=$(gh issue view "$num" --repo "$repo" --json labels,state)
state=$(printf '%s' "$pre" | jq -r '.state')
[ "$state" = "OPEN" ] || { echo "skip: $repo#$num is $state" >&2; exit 1; }
if printf '%s' "$pre" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null; then
  echo "skip: $repo#$num already claimed" >&2; exit 1
fi

gh issue edit "$num" --repo "$repo" --add-label "agent:claimed" --add-assignee "$me" >/dev/null

# 사후 확인
post=$(gh issue view "$num" --repo "$repo" --json labels)
printf '%s' "$post" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null \
  || { echo "claim 실패: 라벨 미부착 $repo#$num" >&2; exit 1; }

echo "claimed: $repo#$num"
