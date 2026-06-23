#!/usr/bin/env bash
# 마감 후보 PR을 JSON lines 로 출력. 진입 조건 모두 충족 + harvesting 미부착.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0

scope_file="$PWD/.loop/repos"
in_scope() {
  [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"
}

prs=$(gh api -X GET search/issues \
  -f q="user:$me is:open is:pr" -f per_page=50 \
  -q '[.items[] | {repo:(.repository_url|sub(".*/repos/";"")), pr:.number}]' 2>/dev/null)
[ -n "$prs" ] || exit 0

printf '%s' "$prs" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repo')
  pr=$(printf '%s'  "$row" | jq -r '.pr')
  in_scope "$repo" || continue

  meta=$(gh pr view "$pr" --repo "$repo" \
    --json headRefName,mergeable,labels,comments,closingIssuesReferences 2>/dev/null)
  [ -n "$meta" ] || continue

  head=$(printf '%s' "$meta" | jq -r '.headRefName')
  case "$head" in agent/issue-*) : ;; *) continue ;; esac
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("harvesting")' >/dev/null && continue
  [ "$(printf '%s' "$meta" | jq -r '.mergeable')" = "CONFLICTING" ] && continue

  printf '%s' "$meta" \
    | jq -e '[.comments[].body] | map(select(startswith("머지 판정: ✅"))) | length > 0' \
    >/dev/null || continue

  # 워커가 남기는 머신 코멘트 접두사는 장식이 붙는다("검증자 리뷰 (codex…):",
  # "검증자 리뷰(보수 후):"). 콜론까지 고정 매칭하면 그 변형들이 미해결 인간
  # 코멘트로 오인돼 초록불 PR이 통째로 후보에서 탈락한다 → stem 매칭으로 관대하게.
  # (긍정 게이트는 위 "머지 판정: ✅" 정확 매칭을 그대로 유지하므로 위험은 좁다.)
  unresolved=$(printf '%s' "$meta" | jq '[.comments[].body
    | select((startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증")) | not)]
    | length')
  [ "${unresolved:-0}" -gt 0 ] && continue

  "$SCRIPT_DIR/closeout-ci-pass.sh" "$repo" "$pr" || continue

  issue=$(printf '%s' "$meta" | jq -r '.closingIssuesReferences[0].number // empty')
  printf '{"repo":"%s","pr":%s,"issue":"%s","head":"%s"}\n' "$repo" "$pr" "$issue" "$head"
done
