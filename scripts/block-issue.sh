#!/usr/bin/env bash
# usage: block-issue.sh <owner/repo> <issue#> <blocker#> [<blocker#>...]
# 대상 이슈에 blocked-by:<N> 라벨을 부착해 블로커 관계를 이슈 목록에서 가시화한다(#85).
# <N> 은 **이슈 번호**다 — 블로커 PR 이 머지되면 Closes #N 으로 그 이슈가 닫히므로,
# 이슈 #N 이 CLOSED 되면 eligible 게이트가 자동으로 해제해 후보로 복귀한다.
# 번호 라벨은 setup-labels 로 미리 못 만드므로 on-demand 로 생성한다 — gh 는 없는
# 라벨을 --add-label 하면 실패하기 때문(--force 생성이 필수).
set -euo pipefail
repo="${1:?usage: block-issue.sh <owner/repo> <issue#> <blocker#> [<blocker#>...]}"
issue="${2:?usage: block-issue.sh <owner/repo> <issue#> <blocker#> [<blocker#>...]}"
shift 2
[ "$#" -ge 1 ] || {
  echo "usage: block-issue.sh <owner/repo> <issue#> <blocker#> [<blocker#>...]" >&2
  exit 1
}

# 중립 회색조 — needs-human(D4C5F9)·claimed(D93F0B) 과 시각적으로 구분한다.
BLOCKED_COLOR="BFDADC"

for blocker in "$@"; do
  case "$blocker" in
    ''|*[!0-9]*)
      echo "skip: 블로커는 이슈 번호(숫자)여야 한다 — PR 이 아니라 이슈 #N: '$blocker'" >&2
      continue ;;
  esac
  label="blocked-by:$blocker"
  # 없으면 생성 / 있으면 색·설명 갱신(--force) → 대상 이슈에 부착
  gh label create "$label" --repo "$repo" --color "$BLOCKED_COLOR" --force \
    --description "블로커 이슈 #$blocker 이 닫히면 자동 해제 (issue-runner eligible 게이트)" >/dev/null
  gh issue edit "$issue" --repo "$repo" --add-label "$label" >/dev/null
  echo "blocked: $repo#$issue ← #$blocker ($label)"
done
