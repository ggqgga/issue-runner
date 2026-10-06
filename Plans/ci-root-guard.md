# CI 실행 중 같은 워크트리 동작 가드 (#586)

## 문제

push 훅(`hooks/local-ci.sh`)은 `bin/ci` 를 박스 전역 큐에 백그라운드로 넣고 즉시 돌아온다. 세션은 같은
워크트리에서 계속 일한다. 큐(`scripts/ci-queue.sh`)는 `bin/ci` 끼리만 줄 세우므로, 그 밖의 세션 동작이 실행
중인 CI 와 같은 워크트리에서 겹친다. 2026-10-05 맥북 CI 실패 151건 중 환경 원인 46건(30%)이 전부 사람 세션
워크트리의 이 겹침이었다.

| 겹친 동작 | 기전 |
|---|---|
| 같은 워크트리 `bin/rails test` | 병렬 테스트가 시작 시 test DB 를 비움 → CI 픽스처 소실·잠금 |
| CI 도중 커밋 | 실시간 HEAD 를 읽는 테스트(SelfPaceTest) 불일치 |
| CI 도중 `git worktree remove --force` | 실행 중 ROOT 삭제 → LoadError·getcwd 대량 |

## 결정 (사용자, 2026-10-06)

- **막는 위치: ⓑ 세션 쪽 가드 + ROOT 소실 마커** — issue-runner 만 고친다. ⓐ 안내만(강제력 없음)·ⓒ CI 격리
  (레포별 준비물을 큐가 알아야 하고 루프 경로도 바뀜)는 택하지 않았다.
- **SelfPaceTest** 는 독립 문제라 BoDAT 루프 이슈로 분리 — BoDAT #6171.
- 플랜은 구현 PR 에 함께 싣는다(docs 선행 PR 생략).

## 설계

1. `ci-queue.sh` — 실행권을 쥘 때 `.running/root` 에 `pwd -P` 로 푼 ROOT 를 원자 기록(슬러그는 `/`·공백을
   둘 다 `_` 로 접어 되돌릴 수 없다). 새 하위 명령 `busy <DIR>`: DIR 이 실행 중 CI 의 ROOT 안이면 0 + SHA.
2. `hooks/guard-ci-root.sh`(PreToolUse·Bash) — 테스트(`rails test`·`bin/ci`)·HEAD 를 움직이는 git·
   `git worktree remove` 의 대상 디렉터리가 busy 면 exit 2 + `wait` 명령 안내. 대상 디렉터리는 cwd → 선두
   `cd X` → `git -C X`(삭제는 경로 인자). 그 밖의 실패는 통과(fail-open).
3. 선두 `cd` 해석을 `scripts/lib/hook-cmd.sh` 로 빼서 `local-ci.sh` 와 가드가 같은 읽기를 쓴다.
4. ROOT 소실 마커 — `bin/ci` 가 fail 로 끝났는데 ROOT 가 없으면 로그 끝에 `인프라: ROOT 소실`, status error,
   **result 미기록**·exit 3(캐시하면 같은 SHA 재실행이 가짜 fail 을 dedup 으로 물려받는다). status 는 ROOT
   대신 살아남는 공용 git 디렉터리에서 게시한다.

## 한계

- CI 보다 **먼저** 시작된 테스트(예: 백그라운드 `bin/rails test`)는 막지 못한다 — 실행 중 프로세스는 훅 밖이다.
- 사람 터미널의 명령은 막지 못한다 — 훅은 Claude Code 세션 안에서만 뜬다.
- Edit/Write 로 CI 도중 파일을 고치는 것은 막지 않는다(관측된 실패 패턴이 아니다).

## Task 1: ci-queue busy · ROOT 기록 · ROOT 소실 마커

- 파일: `scripts/ci-queue.sh`, `scripts/tests/ci-queue.test.sh`(13·15절)
- 검증: `bash scripts/tests/ci-queue.test.sh`

## Task 2: 가드 훅 · 공용 해석 라이브러리

- 파일: `hooks/guard-ci-root.sh`, `scripts/lib/hook-cmd.sh`, `hooks/local-ci.sh`, `scripts/tests/ci-queue.test.sh`(14절)
- 검증: `bash scripts/tests/ci-queue.test.sh` · `bin/ci`

## Task 3: 문서 · 설치

- 파일: `README.md`, `README.ko.md`(훅 표·설치 스니펫·busy·ROOT 소실)
- 설치(레포 밖, 머지 후): `~/.claude/hooks/guard-ci-root.sh` 심링크 + `~/.claude/settings.json` PreToolUse(Bash) 등록
- 검증: 서브에이전트 Bash 에도 PreToolUse 차단이 걸리는지 실측
