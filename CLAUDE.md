# issue-runner

루프 엔지니어링 디스패처 — agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 루프. 본체는 SKILL.md(디스패처 틱)와 scripts/(결정론 셸 스크립트), skills/issue-prep(이슈 마감 체크리스트).

## 명령

- 전체 CI (머지 전 필수, GitHub Actions 미사용): `bin/ci`
  — 모든 .sh 의 bash 문법 검사(bash -n) + shellcheck(설치 시) + repo-dir.sh 스모크 테스트
- 스크립트는 macOS bash 3.2 호환 필수 — mapfile/연관배열 등 bash4 문법 금지

## 규칙

- scripts/*.sh 는 결정론적이어야 한다 — LLM 판단이 필요한 일은 SKILL.md(디스패처/워커 프롬프트)로.
- 상태의 단일 진실 원천은 GitHub(라벨·assignee·PR). 스크립트에 로컬 상태 파일을 두지 않는다
  (예외: ~/.claude/.local-ci 캐시 — local-ci hook 계약).
- repos.conf 는 머신별 설정(gitignore됨) — 코드에 개인 경로를 하드코딩하지 않는다.
- SKILL.md 워커 템플릿 수정 시: 서브에이전트는 cwd가 호출 간 리셋되고, PostToolUse
  주입이 닿지 않으며, PR 생성은 cd 없는 단독 명령이어야 한다는 제약을 유지할 것
  (근거: docs/2026-06-11-issue-runner-loop-plan.md 검증 기록).
