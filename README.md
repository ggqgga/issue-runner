# issue-runner

루프 엔지니어링 디스패처 — GitHub 계정 전체에서 `agent-ready` 라벨이 붙은 이슈를
자동으로 집어, git worktree 격리 환경에서 구현하고 PR을 여는 자율 루프.
**머지는 항상 사람이 한다 — 루프는 절대 머지하지 않는다.**

## 개념

단일 디스패처(`/issue-runner` 스킬)를 `/loop`로 주기 실행한다. 매 틱(tick)마다
네 단계를 순서대로 수행한다:

| 단계 | 역할 |
|---|---|
| ① Reconcile | claim된 이슈 전수 점검 — 머지/거부된 PR 정리, 죽은 claim 해제, 교훈(lessons) 기록 |
| ② Maintain | 열린 PR 보수 — CI 실패 수리, 리뷰 코멘트 해결, base conflict rebase |
| ③ Dispatch | 남는 슬롯만큼 신규 이슈 claim → worktree 생성 → 백그라운드 워커 투입 |
| ④ Report | 한 줄 요약 (`정리 N · 보수 N · 신규 N · 대기 N · warn N`) |

설계 원칙:

- **상태의 단일 진실 원천은 GitHub** (라벨·assignee·PR 상태). 로컬 상태 파일을
  두지 않고 매 틱 현실과 대조한다.
- **결정론적 판단은 bash 스크립트** (`scripts/` — 자격 필터·claim·정리),
  **재량 판단은 LLM** (`SKILL.md` — 충돌 회피·수리 방법).
- 워커는 매 커밋마다 push — worktree는 언제 버려져도 되는 상태를 유지한다.
- 동시 in-flight 상한은 `MAX_AGENTS = 2` (SKILL.md 상수).

## 전제 조건

필수:

- **`gh` CLI** — 인증 완료 상태 (`gh auth status`로 확인). 모든 스크립트가
  이슈/PR/라벨을 `gh`로 조작한다.
- **`jq`** — JSON 처리 (`eligible-issues.sh`, `reconcile.sh` 등이 사용).
- **bash 3.2+** — macOS 기본 bash로 충분. 스크립트는 bash 3.2 호환으로 작성됨.
- **Claude Code** — `/loop`, Agent 툴(백그라운드 서브에이전트)을 지원하는 환경.

선택:

- **codex 플러그인** (`codex:codex-rescue` 서브에이전트) — 워커가 PR 생성 후
  코드 리뷰를 스폰하고(BLOCKER 발견 시 해결 전 종료 금지), 디스패처가
  머지/거부된 PR에서 교훈(lessons)을 추출할 때 사용. 주의: SKILL.md의 워커/디스패처
  계약에 이 단계들이 포함되어 있으므로, 플러그인 없이 운용하려면 SKILL.md에서
  해당 단계(워커 9단계 codex 리뷰, Reconcile lessons)를 빼고 써야 한다.
- **local-ci hook 세트** (`~/.claude/hooks/local-ci.sh`,
  `ci-gate-before-pr-merge.sh`) — GitHub Actions 없이 로컬 CI 결과를
  `~/.claude/.local-ci/` 캐시에 남기고, 사람이 `gh pr merge` 할 때 게이트로 읽는
  계약. 옵트인 레포는 실행 가능한 `bin/ci` + `config/ci.rb` 마커 파일을 둔다.
  hook이 없어도 워커의 `run-local-ci.sh`는 결과 캐시를 기록한다.
- **shellcheck** — 이 레포 자체의 `bin/ci`가 설치 시에만 실행 (미설치면 skip).

## 설치

```bash
# 1. clone (위치는 자유 — 예시는 ~/Projects/refs)
git clone https://github.com/ggqgga/issue-runner ~/Projects/refs/issue-runner

# 2. ~/.claude/skills 에 symlink (Claude Code가 스킬을 인식하는 경로)
mkdir -p ~/.claude/skills
ln -s ~/Projects/refs/issue-runner            ~/.claude/skills/issue-runner
ln -s ~/Projects/refs/issue-runner/skills/issue-prep ~/.claude/skills/issue-prep

# 3. 루프에 참여시킬 각 레포에 라벨 세트 생성 (= 옵트인 신호)
~/.claude/skills/issue-runner/scripts/setup-labels.sh <owner/repo>
```

`setup-labels.sh`는 라벨 생성과 함께 `gh repo edit --delete-branch-on-merge`를
설정한다 (머지된 head 브랜치를 GitHub가 자동 삭제 — reconcile은 로컬만 정리한다).

### repos.conf — 레포 경로 매핑 (필요할 때만)

스크립트는 레포의 로컬 체크아웃을 기본적으로 `$HOME/Projects/<레포명>`에서 찾는다
(루트는 `ISSUE_RUNNER_PROJECTS_ROOT` 환경변수로 변경 가능). 거기에 없으면
`make-worktree.sh`가 그 위치로 clone한다. 다른 곳에 이미 체크아웃이 있다면
`repos.conf`로 매핑한다. `repos.conf`는 **이 레포의 루트**(clone한 위치)에
있어야 한다 — `repo-dir.sh`가 자기 위치 기준으로 읽는다:

```bash
cd ~/Projects/refs/issue-runner   # clone 한 위치
cp repos.conf.example repos.conf  # repos.conf 는 gitignore — 머신별 설정
```

형식은 한 줄에 `<owner/repo> <절대경로>` (공백 구분 — 경로에 공백 불가,
`#` 시작 줄은 주석, `~/` 시작 경로 허용):

```
# 예:
ggqgga/BodaT /Users/ggq/Projects/BODA/BoDAT
```

## 라벨 규약

| 라벨 | 의미 |
|---|---|
| `agent-ready` | 에이전트가 집어가도 되는 이슈. **스펙 완결 후 마지막에** 사람이(또는 `/issue-prep`로) 부착. 디스패처는 절대 임의로 붙이지 않는다 |
| `agent:claimed` | 디스패처가 점유 중. **수동 부착/제거 금지** — 루프가 라이프사이클을 관리한다 |
| `P0` / `P1` / `P2` | 우선순위 (최우선/보통/낮음). 없으면 최하순위로 처리 |

추가 규약:

- **의존성**: 이슈 본문에 **전용 라인** `Blocked by #N` (한 줄에 하나, 라인 시작
  위치). 모든 블로커 이슈가 CLOSED여야 디스패치 자격이 생긴다. 산문 속 언급은
  디스패처가 읽지 못한다.
- **epic 금지**: 부모(epic) 이슈에는 `agent-ready`를 붙이지 않는다 — sub-issue로
  쪼개고 leaf에만 붙인다.
- **거부 = 재시도 금지**: PR이 머지 없이 닫히면 reconcile이 `agent-ready`까지
  제거한다. 사람이 거부한 일을 루프가 다시 벌이지 않는다.

이슈 자격 조건 정리: open + `agent-ready` + ¬`agent:claimed` + 모든 블로커 CLOSED.
정렬: P0 > P1 > P2 > 라벨 없음, 동순위는 오래된 순 (`eligible-issues.sh`).

## 구동법

Claude Code에서:

```
/loop 15m /issue-runner
```

15분마다 디스패처 틱이 돈다. 단발 실행은 `/issue-runner` 한 번 호출.

이슈를 루프에 넘기는 쪽 워크플로:

1. 기획 세션에서 이슈를 작성한다 — 워커는 세션 맥락을 전혀 공유하지 않으므로
   **이슈 본문이 유일한 스펙**이다 (수용 기준 체크박스 + `## Test plan` 필수).
2. `/issue-prep`로 마감 체크리스트를 통과시키고 `agent-ready` + 우선순위 라벨 부착.
3. 다음 틱에 디스패처가 claim → worktree(`<레포>/.claude/worktrees/issue-<N>`,
   브랜치 `agent/issue-<N>`) → 백그라운드 워커 투입 → 워커가 구현·push·PR 생성.
4. 사람이 PR을 리뷰하고 머지한다. 다음 틱의 reconcile이 worktree와 claim을 정리한다.

## 파일 구조

```
SKILL.md                   # 디스패처 틱 본체 (Reconcile → Maintain → Dispatch → Report)
scripts/
  setup-labels.sh          # 레포에 라벨 세트 생성 (옵트인 부트스트랩)
  eligible-issues.sh       # 자격 필터 → 우선순위 정렬 JSON
  claim-issue.sh           # 직접 API 재확인 후 claim (검색 인덱스 지연 방어)
  make-worktree.sh         # 레포 보장(clone) + worktree 생성
  reconcile.sh             # claim 전수 점검 → 이벤트 JSON + 안전 정리
  repo-dir.sh              # repos.conf / 기본 경로로 레포 로컬 경로 해석
  run-local-ci.sh          # worktree에서 bin/ci 실행 → local-ci 캐시 기록
skills/issue-prep/SKILL.md # 기획 세션용 이슈 마감 체크리스트
repos.conf.example         # 머신별 레포 경로 매핑 예시
bin/ci                     # 이 레포 자체의 로컬 CI (셸 문법 검사 + 스모크 테스트)
```

## 개발

이 레포 자체를 수정할 때는 머지 전 `bin/ci`를 실행한다 — 모든 `.sh`의
`bash -n` 문법 검사 + shellcheck(설치 시) + `repo-dir.sh` 스모크 테스트.
스크립트는 macOS bash 3.2 호환이어야 한다 (mapfile/연관배열 등 bash4 문법 금지).
규칙은 [CLAUDE.md](CLAUDE.md) 참조.

## 새 머신 설치 자가 점검 체크리스트

- [ ] `gh auth status` — 인증 OK
- [ ] `command -v jq` — jq 설치됨
- [ ] clone + symlink 2개 생성 (`ls -l ~/.claude/skills/issue-runner` 로 확인)
- [ ] 대상 레포에 `scripts/setup-labels.sh <owner/repo>` 실행 — "labels ready" 출력
- [ ] 레포가 기본 위치(`~/Projects/<레포명>`) 밖이면 `repos.conf` 매핑 추가 후
      `scripts/repo-dir.sh <owner/repo>` 가 올바른 경로를 출력하는지 확인
- [ ] 테스트 이슈에 수용 기준 + Test plan 작성 → `agent-ready` + `P2` 부착
- [ ] `scripts/eligible-issues.sh` 출력에 해당 이슈가 보이는지 확인
- [ ] Claude Code에서 `/loop 15m /issue-runner` 시작 → 틱 Report 확인
