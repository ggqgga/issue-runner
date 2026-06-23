#!/usr/bin/env bash
# harvesting 라벨 항목 점검 — 크래시 재개·정리. 이벤트 JSON lines.
set -uo pipefail
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0
scope_file="$PWD/.loop/repos"
in_scope() { [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"; }

items=$(gh api -X GET search/issues \
  -f q="user:$me label:harvesting" -f per_page=50 \
  -q '[.items[] | {repo:(.repository_url|sub(".*/repos/";"")), num:.number}]' 2>/dev/null)
[ -n "$items" ] || exit 0

printf '%s' "$items" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repo'); num=$(printf '%s' "$row" | jq -r '.num')
  in_scope "$repo" || continue
  state=$(gh pr view "$num" --repo "$repo" --json state -q '.state' 2>/dev/null)
  case "$state" in
    MERGED)
      gh issue edit "$num" --repo "$repo" --remove-label harvesting >/dev/null 2>&1 || true
      printf '{"event":"merged_cleanup","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
    OPEN)
      printf '{"event":"resume","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
    *)
      gh issue edit "$num" --repo "$repo" --remove-label harvesting >/dev/null 2>&1 || true
      printf '{"event":"stale","repo":"%s","pr":%s}\n' "$repo" "$num" ;;
  esac
done
