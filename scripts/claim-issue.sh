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
# needs-human 재확인 — eligible-issues.sh 이후 사람이 붙였거나 인덱스 지연으로
# 후보에 남아 있어도, 사람이 라벨을 떼기 전에는 claim 금지
if printf '%s' "$pre" | jq -e '.labels | map(.name) | index("needs-human")' >/dev/null; then
  echo "skip: $repo#$num needs-human" >&2; exit 1
fi

gh issue edit "$num" --repo "$repo" --add-label "agent:claimed" --add-assignee "$me" >/dev/null

# 사후 확인
post=$(gh issue view "$num" --repo "$repo" --json labels)
printf '%s' "$post" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null \
  || { echo "claim 실패: 라벨 미부착 $repo#$num" >&2; exit 1; }

# stale blocked-by 라벨 청소(#85 should): 이 이슈가 eligible 게이트를 통과해 claim 됐다는
# 것은 남아 있는 blocked-by:<N> 중 CLOSED 인 블로커의 라벨이 이제 무의미하다는 뜻이다.
# 목록 청소용으로만 제거한다 — 게이트는 N=CLOSED 면 라벨 제거 없이도 이미 통과한다.
# (eligible-issues.sh 는 순수 조회라 부수효과를 claim 시점으로 옮긴 최소 침습 위치.)
printf '%s' "$post" | jq -r '.labels[].name | select(startswith("blocked-by:"))' \
  | while IFS= read -r lbl; do
      bn=${lbl#blocked-by:}
      bstate=$(gh issue view "$bn" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
      if [ "$bstate" = "CLOSED" ]; then
        gh issue edit "$num" --repo "$repo" --remove-label "$lbl" >/dev/null 2>&1 || true
      fi
    done

echo "claimed: $repo#$num"
