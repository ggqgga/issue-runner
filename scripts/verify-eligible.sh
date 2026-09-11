#!/usr/bin/env bash
# verify-eligible.sh — verify-runner 후보 PR을 JSON lines 로 출력.
#
# 후보 조건: 열린 PR + head 가 agent/issue-* + `flow:verify` 라벨 부착 +
#            `harvesting` 미부착(closeout 이 이미 물었으면 제외) +
#            `needs-human`·`hold:*`(접두) 미부착(사람 대기·기계 정지는 손대지 않는다, #242).
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
  # 사람 대기(needs-human) · 기계 정지(hold:*) 제외 (#242) — closeout-eligible.sh 의 같은
  # 자리와 **같은 정의**다(두 번째 계산기를 만들지 않는다. 격자 단언: tests/hold-gate.test.sh).
  #
  # 이 파일엔 지금까지 이 필터가 **없었다**. 평상시엔 transition.sh 의 `verify-held` 가
  # PR 에서 `flow:verify` 를 떼므로 위 서버 쿼리(label:flow:verify)에 애초에 안 잡혀서
  # 가려져 있었을 뿐이고, `runner-held`(#151)는 **flow:verify 를 떼지 않는다** — 디스패처가
  # 방금 정지시킨 PR 이 그대로 검증 후보로 떠서 정지가 무시된다. 순수 추가로 그 구멍을 막는다.
  # → 그래서 **이 한 자리는 오늘 동작이 바뀐다**(나머지 세 자리와 달리 무동작 안전망이 아니다):
  #   runner-held 로 정지된 PR 이 이 틱부터 verify 후보에서 빠진다.
  #
  # `hold:` 는 **접두사** 판별이라 사유가 늘어도 안 깨지고, `hold:` 로 시작하지 않는 라벨
  # (`holding`·`on-hold`·`area:hold`)은 걸리지 않는다 — 과잉 제외는 검증 대기 PR 을 조용히
  # 큐에서 지우는 방향이라 원래 결함보다 나쁘다.
  #
  # 해제는 **두 라벨 다** 떼는 것이다 — `needs-human` 만 떼면 `hold:*` 가 남아 후보로
  # 돌아오지 않는다(기계 해제 경로는 이미 둘 다 뗀다: transition.sh `⊘hold`·resume-sweep 재개).
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("needs-human")' >/dev/null && continue
  printf '%s' "$meta" | jq -e '[.labels[].name]|any(startswith("hold:"))' >/dev/null && continue

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
