#!/usr/bin/env bash
# verify-eligible.sh — verify-runner 후보 PR을 JSON lines 로 출력.
#
# 후보 조건: 열린 PR + head 가 agent/issue-* + `flow:verify` 라벨 부착 +
#            `harvesting` 미부착(closeout 이 이미 물었으면 제외).
# `flow:verify` = 워커가 구현+결정적CI+PR 까지 마치고 검증을 verify-runner 에 넘긴
# 소유 플래그(harvesting 과 동형). issue-runner 는 이 PR 을 건드리지 않고 in-flight
# 로도 안 센다 — **CI 상태 무관 전부 verify-runner 소유**(CI-fail 도 여기서 재디스패치
# 로 처리해 issue-runner 사각지대를 안 만든다). verify-runner 가 검증(E2E·codex) 후
# pass 면 flow:verify 를 떼고 `머지 판정: ✅`+flow:ready 로 closeout 에 넘긴다.
#
# 각 후보에 `ci` 필드(pass|revalidate|fail)를 실어 verify-runner 가 분기한다:
#   pass       결정적 CI 캐시 pass → 바로 E2E·codex 검증
#   revalidate rebase 등으로 HEAD 미실행(closeout-ci-pass exit 2) → worktree 동기화 후 재실행
#   fail       결정적 CI 실패 → 검증 안 하고 재디스패치(코드 회귀 — 워커로 반송)
#
# FIFO(sort=created·order=asc) — 오래된 PR 먼저. closeout-eligible.sh 동형 구조.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0

scope_file="$PWD/.loop/repos"
in_scope() {
  [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"
}

prs=$(gh api -X GET search/issues \
  -f q="user:$me is:open is:pr label:flow:verify" -f per_page=50 \
  -f sort=created -f order=asc \
  -q '[.items[] | {repo:(.repository_url|sub(".*/repos/";"")), pr:.number}]' 2>/dev/null)
[ -n "$prs" ] || exit 0

printf '%s' "$prs" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repo')
  pr=$(printf '%s'  "$row" | jq -r '.pr')
  in_scope "$repo" || continue

  meta=$(gh pr view "$pr" --repo "$repo" \
    --json headRefName,mergeable,labels,closingIssuesReferences 2>/dev/null)
  [ -n "$meta" ] || continue

  head=$(printf '%s' "$meta" | jq -r '.headRefName')
  case "$head" in agent/issue-*) : ;; *) continue ;; esac
  # closeout 이 이미 물었으면(harvesting) verify-runner 는 손대지 않는다.
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("harvesting")' >/dev/null && continue

  # 결정적 CI 상태를 분류해 실어보낸다(탈락 아님 — flow:verify 는 전부 소유).
  "$SCRIPT_DIR/closeout-ci-pass.sh" "$repo" "$pr"; cp=$?
  case "$cp" in
    0) ci=pass ;;
    2) ci=revalidate ;;
    *) ci=fail ;;
  esac

  issue=$(printf '%s' "$meta" | jq -r '.closingIssuesReferences[0].number // empty')
  printf '{"repo":"%s","pr":%s,"issue":"%s","head":"%s","ci":"%s"}\n' "$repo" "$pr" "$issue" "$head" "$ci"
done
