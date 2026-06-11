---
name: loop-issues
description: 이슈를 issue-runner 루프에 넘기기 전 마감 체크리스트. 사용자가 "루프로 진행해줘", "루프에 넘겨줘", "루프 태워줘", "이슈 마감", "agent-ready 붙여줘" 라고 요청하면 사용. 체크리스트 통과 후에만 agent-ready 라벨을 부착한다.
---

# loop-issues — 이슈 마감 체크리스트

이슈를 루프에 넘기기 전 아래를 **모두** 확인하고, 통과한 이슈에만 `agent-ready` 를 붙인다.
워커는 이 세션의 맥락을 전혀 공유하지 않는다 — 이슈 본문이 유일한 스펙이다.

## 체크리스트

1. **자기완결 스펙**: 이 대화의 맥락 없이 이슈 본문만 읽고 구현할 수 있는가?
   배경·동기·제약을 본문에 다 적었는가?
2. **수용 기준**: `- [ ]` 체크박스로 구체적·검증가능하게. "잘 동작" 같은 모호어 금지.
3. **Test plan**: `## Test plan` 섹션에 실행할 검증 명령/시나리오.
4. **의존성**: 선행 이슈가 있으면 본문에 **전용 라인** `Blocked by #N` (한 줄에 하나,
   라인 시작 위치). 산문 속 언급은 디스패처가 읽지 못한다.
5. **계층**: epic(부모)이면 sub-issue 로 쪼개고 **leaf 에만** agent-ready 를 붙인다.
   epic 본체에는 절대 붙이지 않는다.
6. **우선순위**: P0/P1/P2 라벨 하나 부착 (없으면 최하순위로 처리됨).
7. **레포 준비**: 해당 레포에 (a) 라벨 세트가 있는가 —
   없으면 `~/.claude/skills/issue-runner/scripts/setup-labels.sh <owner/repo>` 실행,
   (b) CLAUDE.md 에 빌드/테스트 명령이 적혀 있는가 — 없으면 워커가 검증을 못 한다.
   먼저 보완하라.
8. **충돌 예상**: 이미 agent-ready/claimed 인 다른 이슈와 같은 모듈을 건드리는가?
   그렇다면 Blocked by 로 직렬화를 고려하라.
9. **난이도 평가**: 여러 파일/모듈을 동시에 건드리거나, 설계 선택지가 둘 이상이거나,
   수용 기준만으로 구현 경로가 유일하게 정해지지 않으면 **high** 다.
   high 이슈는 기획 세션(사람과 대화 가능한 유일한 지점)에서 스펙을 대화로 확정하고
   (superpowers 사용자는 /superpowers:brainstorming 활용 가능 — 의존성은 아니다,
   손으로 쓴 계획도 같은 효력), 이슈 본문에 `## Plan` 섹션을 첨부한다.
   `## Plan` 필수 구성: 단계별 task 목록(각 task에 수정/생성할 파일 경로 명시) +
   task별 검증 명령. task 순서가 곧 실행 순서다. 계획이 task 5개를 넘을 만큼 크면
   첨부 대신 sub-issue 분해를 먼저 검토하라(5번 계층 항목과 연결).

   `## Plan` 형식 예시:

   ```markdown
   ## Plan

   1. scripts/foo.sh 에 --dry-run 플래그 추가 (인자 파싱 + 변경 없이 계획만 출력)
      - 검증: `ISSUE_RUNNER_PROJECTS_ROOT=/tmp scripts/foo.sh --dry-run owner/repo`
        출력에 "would clone" 포함, 파일시스템 변경 없음
   2. SKILL.md 디스패처 Dispatch 단계에 dry-run 사용법 한 줄 추가
      - 검증: `bin/ci` 통과
   3. SKILL.en.md 에 동일 내용을 영어로 반영
      - 검증: `bin/ci` 통과 (한/영 구조 동기화 검사 포함)
   ```

## 마감

전 항목 통과 → `gh issue edit <N> --repo <owner/repo> --add-label agent-ready` +
우선순위 라벨. 하나라도 미통과 → 보완할 내용을 사용자에게 보고하고 라벨을 붙이지 않는다.
