#!/usr/bin/env bash
# usage: setup-labels.sh <owner/repo>
# issue-runner 라벨 세트를 레포에 생성(존재 시 갱신). 이 라벨이 곧 옵트인 신호.
set -euo pipefail
repo="${1:?usage: setup-labels.sh <owner/repo>}"

# ── 색 팔레트 3단 축 (#256) — 값을 바꾸기 전에 이 원칙을 먼저 읽어라 ──────────────
# 원칙: 사람이 **지금 봐야 하는 것**은 난색 고채도 · 루프가 도는 중이라 **안 봐도 되는 것**은
# 한색 · 분류/메타는 저채도 회색조. 티어별 소속:
#   A 사람 차례 = needs-human · hold:conflict · hold:policy
#   B 루프 진행 = agent-ready · agent:claimed · flow:ci · flow:verify · flow:ready
#                · harvesting · hold:ladder · deploy-wait(#243 — "사람 정지 아님" 으로
#                재정의된 뒤 A 에서 이리로 옮겼다. 사람이 볼 일이 없다는 점에서 hold:ladder
#                와 같은 처지: 루프(deploy-cycle)가 스스로 집어가는 레인이라 목록을 훑는
#                사람이 "내 차례" 로 읽으면 안 된다)
#   C 분류/메타 = flow:codex · spinoff · epic · dup · loop-dashboard (+ block-issue.sh 의 blocked-by:*)
# 색은 어떤 스크립트도 읽지 않는 **순수 표시값**이지만, 목록을 훑는 사람이 "지금 내 차례인가"
# 를 색만으로 가르는 축이라 임의로 바꾸면 축이 무너진다 — 옛 팔레트가 정확히 거꾸로였다
# (사람이 봐야 할 유일한 라벨 needs-human 이 가장 조용한 연라벤더, 루프가 알아서 집어가
# 사람이 볼 일 없는 agent-ready 가 가장 시끄러운 핫핑크).
# P0/P1/P2 는 이 축 **밖**이다 — "차례" 가 아니라 "중요도" 라 빨강-노랑-연두 관습을 유지한다.
gh label create "agent-ready"   --repo "$repo" --color 1F6FEB --force \
  --description "에이전트가 집어가도 되는 이슈 (스펙 완결 후 마지막에 부착)"
gh label create "agent:claimed" --repo "$repo" --color 054A91 --force \
  --description "디스패처가 점유 중 — 수동 부착/제거 금지"
gh label create "needs-human" --repo "$repo" --color D73A49 --force \
  --description "루프가 한계 도달 — 사람 판단 필요"
gh label create "P0" --repo "$repo" --color B60205 --force --description "최우선"
gh label create "P1" --repo "$repo" --color FBCA04 --force --description "보통"
gh label create "P2" --repo "$repo" --color C2E0C6 --force --description "낮음"

# closeout 마감 루프 (#41) — harvesting(점유)·epic(부모 탐지)
gh label create harvesting --repo "$repo" --color 1A7F37 \
  --description "closeout 마감 진행 중 (issue-runner Maintain 제외)" --force
gh label create epic --repo "$repo" --color 8C959F \
  --description "부모 에픽 이슈 (sub-issue 롤업 대상)" --force

# PR 생애주기 표시 라벨(flow:*) — PR 리스트만으로 "기계가 물고 있음 vs 사람이 봐야 함"이
# 갈리게 한다. 워커가 각 단계에서 직접 부착(worker-template 의 flow:* 예외) + 틱 루프가
# PR 스캔 시 마지막 판정 코멘트로 best-effort 보정. 이후 harvesting→needs-human 으로 이어짐.
gh label create "flow:ci" --repo "$repo" --color ADD8FF \
  --description "워커가 이 PR 의 로컬 CI 를 (재)실행 중" --force
gh label create "flow:verify" --repo "$repo" --color 79C0FF \
  --description "결정적 CI 통과 — verify-runner 검증(E2E·codex) 대기·진행 중" --force
gh label create "flow:codex" --repo "$repo" --color D8DEE4 \
  --description "(레거시) 워커 인라인 검증 단계 — verify-runner 도입 후 flow:verify 로 대체" --force
gh label create "flow:ready" --repo "$repo" --color 2DA44E \
  --description "그린라이트(머지 판정 ✅) — closeout 마감 대기" --force

# closeout 파생·배포 대기 표식 (#144) — 지금까지 산문으로만 구분하던 두 종류의 이슈를
# 목록에서 바로 가른다. `deploy-wait` 는 **단독으로** 붙는다(#243) — needs-human 과 병행하던
# 것을 멈췄다. 그 라벨을 배포 대기 이슈에서 읽는 소비자가 하나도 없었기 때문이다(디스패치
# 게이트는 agent-ready 를 요구 · loop-status 버킷은 deploy-wait 가 이김 · deploy-bodat 수집은
# 제목 정규식). 배포 대기는 `deploy-wait` 하나로 사람대기와 갈린다.
# 색은 B 티어(한색)로 옮겼다(#243 2회차) — 옛 색 BF3989 는 난색 고채도라 위 A/B 축 주석과
# 모순이었다(설명은 "사람 정지 아님" 인데 색은 "사람 차례" 티어). 새 색 17A2B8 은 팔레트
# 안에서 아직 안 쓴 청록 계열 — flow:verify(79C0FF)·hold:ladder(B6E3FF) 같은 파랑 계열과도
# 구별돼, 목록에서 "루프가 도는 중" 을 한눈에 다른 파랑들과 헷갈리지 않게 읽을 수 있다.
gh label create "spinoff" --repo "$repo" --color D0D7DE \
  --description "closeout 6단계 파생 이슈 (부모 PR/이슈에서 갈라짐)" --force
gh label create "deploy-wait" --repo "$repo" --color 17A2B8 \
  --description "closeout 4단계·full-cycle §7 배포 대기 이슈 — deploy-cycle 레인 (사람 정지 아님)" --force
# 루프 현황 고정 이슈(#163) — loop-status.sh --post 가 이 라벨로 찾아 본문을 덮어쓴다(레포당 1개).
gh label create "loop-dashboard" --repo "$repo" --color 656D76 --force \
  --description "루프 현황 고정 이슈 — 세 루프가 매 틱 본문을 덮어쓴다(직접 편집 금지)"

# 사람 대기 사유 (#147) — `needs-human` 은 사유 없는 쓰레기통이었다. 전이(verify-held·
# closeout-blocked)가 `needs-human` 과 함께 `hold:<사유>` 를 붙여 목록 조회 한 번에
# 분류가 보이게 한다(코멘트 마커가 아니라 라벨 — 상태 = 라벨의 존재).
# `hold:dup`·`hold:hardware` 는 일부러 만들지 않는다 — dup 은 closeout-dup 이 닫고
# hardware 는 사다리를 오른다(#147). 라벨 부재로 금지를 강제한다.
gh label create "hold:conflict" --repo "$repo" --color D93F0B \
  --description "사람 대기 사유 — rebase/semantic conflict, 사람 판단" --force
gh label create "hold:policy" --repo "$repo" --color E4A11B \
  --description "사람 대기 사유 — 스펙·정책 결정 필요" --force
# `hold:ladder` 만 B 티어(한색·조용한 쪽)인 이유: 이건 루프가 창이 지나면 **스스로 푸는**
# 정지(재개 스윕 대상)라 사람이 볼 일이 없다. 반대로 `hold:conflict`·`hold:policy` 는
# 사람이 손대야만 풀리므로 A 티어(난색 고채도)다.
gh label create "hold:ladder" --repo "$repo" --color B6E3FF \
  --description "사람 대기 사유 — 검증 사다리 ①~③ 전부 실패(출력 인용 필수), 재개 스윕 대상" --force

# closeout-dup(#147) — 이슈가 요구한 수정이 이미 main 에 있어 머지 없이 닫은 PR.
# loop-status 의 `실패` 줄이 이 라벨로 "중복 종료" 를 가른다(코멘트 마커 대신 라벨).
gh label create "dup" --repo "$repo" --color CFD3D7 \
  --description "closeout-dup 으로 머지 없이 닫힌 PR(중복/이미 반영)" --force

# 머지된 head 브랜치 자동 삭제 — reconcile 이 로컬만 정리하므로 원격은 GitHub 가 맡는다
gh repo edit "$repo" --delete-branch-on-merge

echo "labels ready: $repo"
