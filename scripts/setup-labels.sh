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

# closeout 마감 루프 (#41) — harvesting(점유)·epic(부모 탐지)
gh label create harvesting --repo "$repo" --color 5319e7 \
  --description "closeout 마감 진행 중 (issue-runner Maintain 제외)" --force
gh label create epic --repo "$repo" --color 0e8a16 \
  --description "부모 에픽 이슈 (sub-issue 롤업 대상)" --force

# PR 생애주기 표시 라벨(flow:*) — PR 리스트만으로 "기계가 물고 있음 vs 사람이 봐야 함"이
# 갈리게 한다. 워커가 각 단계에서 직접 부착(worker-template 의 flow:* 예외) + 틱 루프가
# PR 스캔 시 마지막 판정 코멘트로 best-effort 보정. 이후 harvesting→needs-human 으로 이어짐.
gh label create "flow:ci" --repo "$repo" --color FEF2C0 \
  --description "워커가 이 PR 의 로컬 CI 를 (재)실행 중" --force
gh label create "flow:verify" --repo "$repo" --color D4A5FF \
  --description "결정적 CI 통과 — verify-runner 검증(E2E·codex) 대기·진행 중" --force
gh label create "flow:codex" --repo "$repo" --color C5DEF5 \
  --description "(레거시) 워커 인라인 검증 단계 — verify-runner 도입 후 flow:verify 로 대체" --force
gh label create "flow:ready" --repo "$repo" --color 0E8A16 \
  --description "그린라이트(머지 판정 ✅) — closeout 마감 대기" --force

# 머지된 head 브랜치 자동 삭제 — reconcile 이 로컬만 정리하므로 원격은 GitHub 가 맡는다
gh repo edit "$repo" --delete-branch-on-merge

echo "labels ready: $repo"
