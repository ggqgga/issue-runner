#!/usr/bin/env bash
# harvesting 라벨 항목 점검 — 크래시 재개·정리. 이벤트 JSON lines.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0
scope_file="$PWD/.loop/repos"
in_scope() { [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"; }

items=$(gh api -X GET search/issues \
  -f q="user:$me label:harvesting is:pull-request" -f per_page=50 \
  -q '[.items[] | {repo:(.repository_url|sub(".*/repos/";"")), num:.number}]' 2>/dev/null)
[ -n "$items" ] || exit 0

printf '%s' "$items" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repo'); num=$(printf '%s' "$row" | jq -r '.num')
  in_scope "$repo" || continue
  state=$(gh pr view "$num" --repo "$repo" --json state -q '.state' 2>/dev/null)
  case "$state" in
    MERGED)
      gh issue edit "$num" --repo "$repo" --remove-label harvesting >/dev/null 2>&1 || true
      # 머지 확정 — worktree 도 정리한다 (#62, issue-runner reconcile 의존 제거).
      # 여기서 num 은 PR 번호이므로 worktree 키(이슈번호)는 PR head 에서 파싱한다.
      # best-effort: 더티 등으로 헬퍼가 보류해도 merged_cleanup 이벤트는 낸다.
      branch=$(gh pr view "$num" --repo "$repo" --json headRefName -q .headRefName 2>/dev/null)
      inum="${branch#agent/issue-}"
      [ -n "$branch" ] && [ "$inum" != "$branch" ] \
        && "$SCRIPT_DIR/cleanup-worktree.sh" "$repo" "$inum" --merged || true
      printf '{"event":"merged_cleanup","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
    OPEN)
      printf '{"event":"resume","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
    *)
      gh issue edit "$num" --repo "$repo" --remove-label harvesting >/dev/null 2>&1 || true
      printf '{"event":"stale","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
  esac
done
