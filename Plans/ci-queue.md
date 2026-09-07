# 로컬 CI 큐 — 박스 전역 티켓 락(FIFO) + 훅 ROOT 결함

## 문제

`bin/ci` 를 돌리는 진입점이 셋인데 서로를 모른다.

| 진입점 | 락 | 못 잡으면 |
|---|---|---|
| `hooks/local-ci.sh` (push 훅) | `~/.claude/.local-ci/<슬러그>/.lock` — **워크트리별** | "건너뜀" 후 `exit 0` — 재push 를 사람이 기억해야 한다 |
| `scripts/run-local-ci.sh` (루프) | 없음 | — |
| 세션이 직접 치는 `bin/ci` | 없음 | — |

결과: 워크트리 두 개의 CI 가 겹쳐 박스가 포화되고(importmap 감사 60초 타임아웃 플레이크, SQLite 잠금),
같은 워크트리의 두 번째 push 는 조용히 버려지며, GitHub 의 `pending` 이 "대기 중"인지 "status 없음"인지
구분되지 않는다. BoDAT 풀사이클이 매번 이 함정을 손으로 우회했다(메모리 4건).

부수 결함: push 훅이 ROOT 를 **세션 cwd** 로 잡아 `cd <워크트리> && git push` 나 서브에이전트 push 에서
엉뚱한 SHA(메인 체크아웃 HEAD)를 검사하거나 아무것도 남기지 않는다.

## 설계

### 단일 진입점 `scripts/ci-queue.sh`

```
ci-queue.sh run <ROOT> <SHA> [--slug <slug>] [--repo <owner/repo>]
ci-queue.sh status [<SHA>]
```

- **티켓 락, 데몬 없음.** 큐 = `~/.claude/.local-ci/.queue/` 디렉터리. 티켓 = `<epoch>.<pid>.<sha>` 파일
  (내용: root·slug·repo). 각 잡은 자기 프로세스 안에서 기다리다 실행한다 — 런너가 따로 없어
  "런너가 죽으면 큐가 멈춤"이 없다.
- **실행권 = 가장 오래된 티켓 + `mkdir .queue/.running` 성공.** 10초 폴링. 지나가는 대기자가 죽은
  pid 의 티켓·`.running` 을 치운다(자기치유).
- **박스 전역.** 슬러그·레포 무관하게 한 번에 하나 — 워크트리 간 동시 실행이 사라진다.
- **실행 직전 HEAD 검사.** `git -C ROOT rev-parse HEAD` ≠ 티켓 SHA 면 폐기(exit 2). 큐가 push↔실행
  간격을 늘리므로 "워킹트리 ≠ SHA" 오판(BoDAT #4481)을 여기서 닫는다. ROOT 가 사라졌으면 exit 3.
- **dedup.** 결과 파일이 이미 있으면 즉시 exit 0. 같은 SHA 의 살아 있는 티켓이 있으면 중복 발급 안 함.
- **status 게시 3단.** 발급 시 `pending "로컬 CI 대기열 N번째"`, 시작 시 `pending "bin/ci 실행 중"`,
  종료 시 `success`/`failure`. `pending` 이 이제 진짜 "대기·실행 중"이다.
- 결과 파일 형식(`<슬러그>/<SHA>.{log,result}`)은 **그대로** — 게이트·closeout-ci-pass 호환.

### 배선

- `hooks/local-ci.sh`: 락 로직 삭제 → `nohup ci-queue.sh run ROOT SHA &`. ROOT 는 훅 입력의 `cwd` 를
  기준으로 잡고, 명령 앞머리의 `cd <경로> &&`/`;` 를 파싱해 그 경로로 옮긴 뒤 `git rev-parse --show-toplevel`.
- `scripts/run-local-ci.sh`: 직접 `bin/ci` 대신 `ci-queue.sh run "$wt" "$sha" --slug <메인슬러그> --repo <repo>`
  (동기 — 기존 계약 그대로 기다린다).
- `hooks/ci-gate-before-pr-merge.sh`: "결과 없음" 분기에서 `.lock` 대신 `ci-queue.sh status <sha>` —
  "실행 중" / "대기열 N번째(앞: …)" / "결과 없음" 을 구분해 안내. 판정(exit 2)은 그대로.
- 스크립트 위치 해석: 훅은 개별 심링크라 `$(dirname "$(readlink "$0")")/../scripts/ci-queue.sh` →
  `~/.claude/skills/issue-runner/scripts/ci-queue.sh` 순으로 찾는다(게이트의 repo-dir.sh 관행).

### 범위 밖

- settings 의 `if: Bash(git push*)` 접두 매칭 — 복합 명령에서 훅이 아예 안 뜨는 경로는 하네스 몫.
  훅이 **뜨기만 하면** ROOT 는 이제 맞는다.
- 병렬 2개 + 워커 수 절반 같은 스로틀링 — 결정성이 떨어져 채택하지 않음. 직렬의 값은 앞에 N개면 N×~4분.

## 검증

- `scripts/tests/ci-queue.test.sh`(네트워크 무접속, gh 스텁, HOME=tmp): 단독 pass · 두 잡 직렬(시작/종료
  타임스탬프 무겹침·순서) · HEAD 이동 폐기 · 죽은 티켓 회수 · result dedup · status 출력 ·
  훅의 `cd X &&` ROOT 파싱.
- `bin/ci` 에 등록. README/README.ko 설치 절에 `ci-queue.sh` 와 큐 디렉터리 설명 추가.

## 설치(배포)

머지 후 `~/.claude/hooks/local-ci.sh` 가 **복사본**(심링크 아님)이라 README 대로 심링크로 교체해야 발효된다.
`~/.claude/skills/issue-runner` 는 심링크라 `scripts/` 는 pull 즉시 발효.
