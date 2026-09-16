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
# 실행 흔적 라벨(agent:claimed·flow:verify·verifying·flow:ready·harvesting·verify:반송)은
# **언제나** 뗀다 — 머지는 그 실행이 끝났다는 영구 사실이고, 남겨 두면 다음 틱이 진행 중으로 오판한다.
# `verify:반송`(#577)이 여기 든 이유: 이 스크립트가 `transition.sh closeout-dup` 의 ④ 이슈 정리
# 경로다(그 전이는 이슈 라벨을 직접 안 만진다). 반송 표식은 "워커가 다시 집어야 한다" 는 뜻이라
# 머지·중복 종료로 끝난 이슈에 남으면 대시보드의 `반송대기` 줄이 끝난 건을 센다.
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
      --remove-label "verifying"
      --remove-label "flow:ready"
      --remove-label "harvesting"
      --remove-label "verify:반송")

# 디스패치 자격 — 이슈가 실제로 닫혔을 때만 회수
state=$(gh issue view "$num" --repo "$repo" --json state -q '.state' 2>/dev/null || true)
if [ "$state" = "CLOSED" ]; then
  args+=(--remove-label "agent-ready")
fi

# 한 번에 보낸다(호출 1회). 다만 `verify:반송`(#577)은 **레포에 정의가 없으면** 제거조차 편집을
# 통째로 실패시키는 라벨이라(옵트인만 하고 setup-labels.sh 를 다시 안 돌린 레포), 실패하면 그것만
# 빼고 **한 번** 다시 보낸다 — 그러지 않으면 표식 하나 때문에 실행 흔적 정리가 전부 조용히 유실되고,
# 그게 바로 이 스크립트가 막으려는 조용한 좌초다. 정상 경로는 종전대로 edit 1회다.
# 재시도 인자는 **다시 조립한다** — `--remove-label` 과 값은 쌍이라 값만 빼면 다음 플래그가
# 값으로 먹힌다(가운데에서 빠지면 `agent-ready` 회수가 통째로 어긋난다).
if ! gh issue edit "$num" --repo "$repo" "${args[@]}" >/dev/null 2>&1; then
  retry=()
  i=0
  while [ "$i" -lt "${#args[@]}" ]; do
    if [ "${args[$i]}" = "--remove-label" ] && [ "${args[$((i + 1))]:-}" = "verify:반송" ]; then
      i=$((i + 2)); continue
    fi
    retry+=("${args[$i]}"); i=$((i + 1))
  done
  gh issue edit "$num" --repo "$repo" "${retry[@]}" >/dev/null 2>&1 || true
fi
