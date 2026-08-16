#!/usr/bin/env bash
# 머지 뒤 이슈 라벨 해제 — reconcile.sh 의 두 경로(추적 MERGED 분기 · 보강 스윕)가
# 공유하는 단일 규칙. 두 벌이 되면 그 둘이 갈린다(#117 이 정확히 그 상태였다:
# 스윕만 agent-ready 를 떼고 MERGED 분기는 안 뗐다).
#
# ★핵심 규칙★ — **이슈가 아직 OPEN 이면 agent-ready 를 남긴다.**
#   closeout 규약상 일부만 착지한 PR 은 `Closes` 대신 `Refs` 를 써서 트래커를 살려 둔다
#   ("머지 순간 트래커가 닫혀 남은 절반이 유실되는 걸 막는다"). 그런데 스윕은 브랜치명
#   (agent/issue-<N>)만 보고 머지=종료로 간주해 agent-ready 를 떼었다. 이슈는 OPEN 인데
#   디스패치 자격만 사라져 **조용히 좌초**한다 — 로그도 라벨도 코멘트도 안 남는다.
#   실측(ggqgga/BodaT): #2600 이 42시간 좌초해 사람이 라벨 없는 이슈를 손으로 훑다 발견,
#   #3447·#3444 도 각각 1분·3분 39초 만에 같은 방식으로 떨어졌다.
#
# 실행 흔적 라벨(agent:claimed·flow:verify·flow:ready·harvesting)은 **언제나** 뗀다 —
# 머지는 그 실행이 끝났다는 영구 사실이고, 남겨 두면 다음 틱이 진행 중으로 오판한다.
#
# 이슈가 CLOSED 면 종전대로 전부 뗀다(무해 — 어차피 eligible-issues.sh 가 `is:open` 이라
# 닫힌 이슈는 후보에 안 든다).
#
# ★조회 실패 시 방향★ — agent-ready 를 **남긴다**(fail-open 아님, fail-safe 다).
#   잘못 남기는 쪽의 최악은 "닫힌 이슈에 라벨이 붙어 있음" 인데 위 `is:open` 게이트가
#   삼킨다. 잘못 떼는 쪽의 최악은 이 이슈가 고치는 그 조용한 좌초다. 비대칭이라 남긴다.
#
# 사용: release-labels.sh <owner/repo> <issue#>
# 출력 없음. best-effort(라벨 부재·권한 오류는 무시) — 호출부의 흐름을 막지 않는다.
set -uo pipefail

repo=${1:?repo}
num=${2:?issue number}

# 실행 흔적 — 머지됐으면 무조건 정리
args=(--remove-label "agent:claimed"
      --remove-label "flow:verify"
      --remove-label "flow:ready"
      --remove-label "harvesting")

# 디스패치 자격 — 이슈가 실제로 닫혔을 때만 회수
state=$(gh issue view "$num" --repo "$repo" --json state -q '.state' 2>/dev/null || true)
if [ "$state" = "CLOSED" ]; then
  args+=(--remove-label "agent-ready")
fi

gh issue edit "$num" --repo "$repo" "${args[@]}" >/dev/null 2>&1 || true
