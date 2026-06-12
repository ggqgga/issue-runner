#!/usr/bin/env bash
# usage: setup-labels.sh <owner/repo>
# issue-runner 라벨 세트를 레포에 생성(존재 시 갱신). 이 라벨이 곧 옵트인 신호.
set -euo pipefail
repo="${1:?usage: setup-labels.sh <owner/repo>}"

# agent-ready 색은 의도적으로 요란한 딥핑크 — 흔한 초록(0E8A16)은 area/complexity
# 라벨들과 겹쳐 식별 불가 (2026-06-13 Temphra 실사용 피드백)
gh label create "agent-ready"   --repo "$repo" --color FF1493 --force \
  --description "에이전트가 집어가도 되는 이슈 (스펙 완결 후 마지막에 부착)"
gh label create "agent:claimed" --repo "$repo" --color D93F0B --force \
  --description "디스패처가 점유 중 — 수동 부착/제거 금지"
gh label create "needs-human" --repo "$repo" --color D4C5F9 --force \
  --description "루프가 한계 도달 — 사람 판단 필요"
gh label create "P0" --repo "$repo" --color B60205 --force --description "최우선"
gh label create "P1" --repo "$repo" --color FBCA04 --force --description "보통"
gh label create "P2" --repo "$repo" --color C2E0C6 --force --description "낮음"

# 머지된 head 브랜치 자동 삭제 — reconcile 이 로컬만 정리하므로 원격은 GitHub 가 맡는다
gh repo edit "$repo" --delete-branch-on-merge

echo "labels ready: $repo"
