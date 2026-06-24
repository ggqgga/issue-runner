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
    | jq -e '[.comments[].body] | map(select(startswith("머지 판정: ✅") or startswith("Merge verdict: ✅"))) | length > 0' \
    >/dev/null || continue

  # 미해결(사람 리뷰) 코멘트 판정 — 머신 코멘트는 sentinel 마커 <!-- bodat:worker -->
  # (마지막 줄)로 식별한다(#72). 워커/closeout 이 남기는 모든 자기-문서화 코멘트엔
  # 이 마커가 박힌다(worker-template 한/영·closeout SKILL 한/영). 마커가 있으면 머신
  # → unresolved 제외. 접두사 어휘가 늘어도(예 "추가 보정") 안 깨진다 = allowlist 탈피.
  #
  # 레거시 3접두사(머지 판정/검증자 리뷰/마감 검증)는 **동결 폴백**으로 남긴다 — 마커
  # 도입 이전에 열린 PR 의 옛 머신 코멘트가 "미해결 사람 리뷰"로 오인돼 탈락하지 않게.
  # 이 폴백은 더 키우지 않는다(새 어휘는 마커가 받는다) → whack-a-mole 종결.
  # (긍정 게이트는 위 "머지 판정: ✅"/"Merge verdict: ✅" 시작 매칭이라 위험은 좁다.)
  #
  # contains 는 **의도적**이다(위치 무관) — 워커가 마커를 정확히 마지막 줄에 못 둬도
  # 머신으로 인식해 robust 하다. 템플릿의 "마지막 줄" 규칙은 *긍정 게이트* 작성
  # 제약일 뿐(마커가 "머지 판정: ✅" 앞에 오면 startswith 가 깨진다) 이 필터의
  # 요구사항이 아니다. 마지막-줄을 jq 로 강제하면 마커 오배치가 사람 코멘트로
  # 오인돼 #72 false-positive 가 재발하므로 그렇게 바꾸지 마라.
  unresolved=$(printf '%s' "$meta" | jq '[.comments[].body
    | select((contains("<!-- bodat:worker -->")
              or startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증")) | not)]
    | length')
  [ "${unresolved:-0}" -gt 0 ] && continue

  # ci-pass exit code 분기 (#70): 0=캐시 pass(revalidate:false)·2=로컬 CI HEAD 미실행
  # (rebase 등 — revalidate:true 로 머지 도크가 재검증)·그 외=종전대로 탈락(fail/조회불가).
  "$SCRIPT_DIR/closeout-ci-pass.sh" "$repo" "$pr"; cp=$?
  case "$cp" in
    0) reval=false ;;
    2) reval=true ;;
    *) continue ;;
  esac

  issue=$(printf '%s' "$meta" | jq -r '.closingIssuesReferences[0].number // empty')
  printf '{"repo":"%s","pr":%s,"issue":"%s","head":"%s","revalidate":%s}\n' "$repo" "$pr" "$issue" "$head" "$reval"
done
