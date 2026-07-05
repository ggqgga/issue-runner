---
name: issue-runner
description: GitHub 계정 전체에서 agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 디스패처. /loop 와 함께 사용 (예— /loop 15m /issue-runner). 매 틱 Reconcile → Maintain → Dispatch → Report 를 수행한다. 머지는 절대 하지 않는다.
---

# issue-runner — 이슈 디스패처 틱

당신은 무인 디스패처다. 아래 4단계를 **순서대로** 수행하라. 단계 순서를 바꾸지 마라
(정리가 먼저여야 슬롯 계산이 정확하고, 보수가 신규보다 먼저여야 한다).

## 상수

- `MAX_AGENTS = 2` — 동시 in-flight 이슈 상한 (in-flight 정의는 ③-1 —
  사람 리뷰 대기 PR 은 점유하지 않는다)
- `MAX_OPEN_PRS = 10` — 열린 PR 총수 적체 상한. 도달 시 신규 디스패치만 멈춘다
  (보수는 계속) — 사람 머지가 밀릴 때 PR 끼리 rebase conflict 가 폭증하는 것을 막는
  배압(backpressure)
- `MAX_REPAIRS_PER_PR = 3` — PR 1개당 보수 디스패치 상한 (② Maintain 서킷 브레이커)
- `ISSUE_TIMEBOX_HOURS = 1` — PR 없는 `working` 이슈에 허용하는 claim 경과 시간
  (① Reconcile timebox)
- `SOFT_TOKEN_BUDGET_PER_ISSUE = 300000` — 이슈당 소프트 토큰 예산. 하드 캡이
  아니라 ④ Report 의 관측 기준 (Agent 호출에 예산 API 가 없어 강제는 불가).
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — 리뷰·교훈 추출용 검증자 서브에이전트 타입.
  **출력 계약 (SSOT — 다른 모든 곳은 이 항목을 참조한다)**: 리뷰 호출은
  read-only(코드 변경 금지)·발견마다 BLOCKER/WARN/NIT 분류·발견 없으면 'CLEAN'·
  BLOCKER 는 게이트(해결 전 종료 금지), 교훈 추출 호출(① Reconcile)은
  '교훈 1줄 또는 NONE'. 검증자는 SKILL.md 를 읽지 않으므로 호출 프롬프트
  문자열에는 이 계약이 그대로 담겨야 한다 — 프롬프트가 유일한 전달 경로다.
  **폴백**: codex 플러그인 미설치 환경(Agent 툴의 subagent_type 목록에 위 타입이
  없거나, 호출이 unknown subagent type 오류로 실패)에서는 `general-purpose` 를
  검증자로 쓴다 — 같은 프롬프트로 호출하므로 계약도 동일하게 적용된다.
- 절대 금지: PR 머지, main 직접 push, 사람이 만든 브랜치 조작, agent-ready 라벨 임의 부착

## ① Reconcile

`$SCRIPTS/reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged` — 성공 종료. **lessons 단계**: 아래 실패 신호가 하나라도 잡히면 (전부
  `gh pr view <pr> --repo <repo>` 로 확인) `VERIFIER` 서브에이전트(## 상수의 VERIFIER
  계약·폴백을 따른다)를 동기 호출하라. 신호가 하나도 안 잡히면 호출하지 말고 NONE 으로
  둔다(lessons 미기록): (1) CHANGES_REQUESTED 리뷰(`--json reviews`) · (2) `gh run list`
  CI 실패(GitHub Actions 레포) · (3) **local-ci commit status 실패 이력** — `--json
  statusCheckRollup` 에 local-ci 컨텍스트가 한 번이라도 FAILURE 로 기록됐으면(최종
  SUCCESS 라도 실패 이력이면 교훈 후보. local-ci 체제 레포는 gh run list 가 항상 빈값이라
  이 신호가 실질 트리거다) · (4) **검증자 리뷰 코멘트의 BLOCKER** — PR 의 `마감 검증:`·
  `검증자 리뷰:` 코멘트에 BLOCKER 가 있었던 경우(`--json comments`).

  > "PR #<pr> (<repo>)의 리뷰 코멘트와 CI 실패 로그를 읽고, 객관적 실패 사실에서
  > 재발 방지 교훈을 딱 1줄로: '<상황>일 때 <구체 행동>하라' 형식. 추측·일반론 금지.
  > 실패 사실이 없으면 'NONE' 출력."

  결과가 NONE이 아니면 `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`
  (= `<repo-dir>/.loop/lessons.md` — repos.conf 매핑 머신에서도 기록·읽기가 같은 파일을
  가리키게 하는 유일한 해석)에 `- [YYYY-MM-DD PR#<pr>] <교훈>` 형식으로 append.
  **20줄 초과 시 가장 오래된 줄 삭제** (context rot 방어). lessons를 CLAUDE.md로 옮기는
  것은 사람만 한다.
- `rejected` — 사람이 PR을 거부함. lessons 단계 동일하게 수행. 이슈는 재디스패치하지
  않는다 (agent-ready가 이미 제거됨).
- `stale` — 죽은 claim 해제됨. 보고만.
- `warn` — dirty/unpushed worktree. **건드리지 말고** Report에 그대로 올려 사람이 보게 하라.
- `pr_open` — ② Maintain 의 입력.
- `working` — 워커 진행 중. TaskList 로 해당 백그라운드 에이전트가 실제 살아있는지
  확인. 죽었고 push 된 커밋이 있으면 ② 의 보수 대상으로. 커밋이 전혀 없으면
  claim 해제 **전에** 이슈 최신 코멘트를 확인하라 —
  `gh issue view <num> --repo <repo> --json comments --jq '.comments | last.body'`
  가 `BLOCKED:` 로 시작하면 워커가 사람 개입이 필요해서 멈춘 것이다 (모호 스펙 /
  계획-현실 불일치 / 동일 실패 반복): 재디스패치 복귀 대신
  `gh issue edit <num> --repo <repo> --add-label needs-human` 으로 `needs-human`
  을 부착하고, worktree 제거 + claim 해제 후 warn 으로 ④ Report 에 BLOCKED 사유를
  올려라 (사람이 원인을 해소하고 needs-human 을 떼면 다시 흐른다 — README
  '가드레일' 규약). BLOCKED 코멘트가 아니면 worktree 제거 후 claim 해제
  (재디스패치 가능 상태로 복귀).
  **timebox (무진전 감지)**: 살아있어도 claim 경과 시간을 확인하라 —
  `gh api repos/<repo>/issues/<num>/timeline --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed")] | last.created_at'`
  로 claim 시각을 구하고 (빈 응답이면 worktree 디렉토리 생성 시각으로 대체),
  현재 시각과의 차가 `ISSUE_TIMEBOX_HOURS` 를 초과하면 (`working` 은 정의상 PR 없음):
  ⓐ TaskStop 으로 워커를 중단하고 (push 된 커밋은 원격 브랜치에 보존된다),
  ⓑ worktree 를 제거하라 — `git -C <repo-dir> worktree remove --force <wt>` 후
  `git -C <repo-dir> branch -D agent/issue-<num>`. 미push 잔여물은 timebox 초과의
  대가로 **의도적으로 폐기**한다 — 남겨두면 다음 디스패치의 make-worktree 가 중단된
  워커의 중간 상태를 그대로 물려줘 worktree 격리가 깨진다 (dirty-warn 보류 규율은
  원인 불명의 잔여물용이므로 이 의도적 중단에는 적용하지 않는다).
  ⓒ `gh issue edit <num> --repo <repo> --remove-label "agent:claimed"` 로 claim 을
  해제한 뒤, ⓓ warn 으로 ④ Report 에 올려라 (agent-ready 가 남아 있으므로 다음 틱이
  원격 브랜치 위 새 worktree 에서 재디스패치한다).

## ② Maintain — 벌린 일 먼저 끝낸다

`pr_open` 이벤트 각각에 대해:

**서킷 브레이커 — 아래 1~3 의 모든 보수 디스패치 전 공통**:
PR 본문에서 `<!-- repair-count: N -->` HTML 주석을 읽어라
(`gh pr view <pr> --repo <repo> --json body`; 주석이 없으면 N = 0).
N ≥ `MAX_REPAIRS_PER_PR` 이면 **보수를 디스패치하지 않는다** — 이슈에
`gh issue edit <num> --repo <repo> --add-label needs-human` 으로 `needs-human`
라벨을 부착하고 warn 으로 ④ Report 에 올려라. N 이 상한 미만이면 보수 에이전트를
디스패치하면서 PR 본문의 주석을 `<!-- repair-count: N+1 -->` 로 갱신하라
(`gh pr edit <pr> --repo <repo> --body ...` — 주석이 없었으면 본문 끝에 새로 추가,
나머지 본문은 그대로 유지). 같은 PR 에 1~3 의 사유가 여러 개 겹쳐도 **틱당 같은 PR
의 보수 에이전트는 1개** — 모든 수리 지시를 그 한 에이전트의 프롬프트에 합치고,
N 도 디스패치당 1만 올린다.

1. `failing > 0` → 실패 로그를 확인하고 (gh run view --log-failed), 플레이크로 보이면
   re-run (gh run rerun), 진짜 실패면 워커 템플릿 파일
   `~/.claude/skills/issue-runner/references/worker-template.md` (③-4d 와 같은
   방식으로 읽어 채운다)로 **보수 에이전트**를 백그라운드 디스패치 (worktree 가
   없으면 `$SCRIPTS/make-worktree.sh` 가 원격 브랜치 위에 재생성해 준다). 보수
   지시는 템플릿의 "절차" 대신 구체적 수리 내용으로 교체하되 나머지(복합 명령,
   push 규율, 금지 사항)는 유지.
2. 미해결 리뷰 코멘트 → 같은 방식으로 보수 에이전트에 코멘트 해결을 지시.
   단, 워커 자신이 남긴 상태 코멘트(`머지 판정:`·`검증자 리뷰:` 로 시작)는
   리뷰 코멘트가 아니다 — 보수 사유로 세지 마라.
3. base 와 conflict → 보수 에이전트에 rebase (merge 금지) 를 지시.
4. CI green + 리뷰 코멘트 없음 → 손대지 않는다. 사람 리뷰 대기 상태.

`harvesting` 이벤트 = closeout 마감 진행 중 → **건드리지 않는다**(보수·rebase·리뷰 코멘트 해결 제외). closeout 가 머지/정리한다.

## ③ Dispatch — 남는 슬롯만큼만

1. in-flight 계산: ①의 `working` + 이번 틱에 ②로 투입한 보수 + **빨간 PR**
   (`pr_open` 중 CI 실패·미해결 리뷰 코멘트·conflict — ② 1~3 의 대상)의 수.
   **CI green + 코멘트 없음 PR(② 4, 사람 리뷰 대기)은 슬롯을 점유하지 않는다** —
   에이전트가 손댈 일이 없는 휴면 상태이므로 새 일을 막지 않는다.
   `slots = MAX_AGENTS - in-flight`. slots ≤ 0 이면 건너뛴다.
   **적체 배압**: 상태 무관 열린 PR 총수가 `MAX_OPEN_PRS` 이상이면 신규 디스패치를
   건너뛰고 ④ Report 에 "머지 대기 적체 N개" warn 을 올린다 (보수는 ② 에서 계속 돈다).
2. `$SCRIPTS/eligible-issues.sh` 실행 → 우선순위 정렬된 후보.
3. **LLM 판단 (덜 집는 쪽으로만)**: 후보 중 같은 레포·같은 모듈을 건드릴 것으로
   보이는 이슈가 둘 이상이면 이번 틱에는 하나만 집는다. 판단이 서지 않으면 집는다
   (충돌은 다음 틱 rebase 가 풀어준다).
4. 위에서부터 slots 개에 대해:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — 실패(이미 claim 등)하면 다음 후보로.
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — 마지막 줄이 worktree 경로.
   c. `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`
      (= `<repo-dir>/.loop/lessons.md`, 기록 경로와 동일 해석)가 있으면 내용을 읽어 둔다.
   d. 디스패치 직전 `~/.claude/skills/issue-runner/references/worker-template.md` 를
      읽고 placeholder(`<WT_PATH>` `<REPO>` `<NUM>` `<TITLE>` `<DEFAULT_BRANCH>`
      `<REPO_DIR>` `<VERIFIER>` `<LESSONS_OR_"없음">`)를 채워 투입하라 (Agent 툴
      백그라운드 디스패치 — 호출 시그니처는 템플릿 파일 상단에 있다).
      `<DEFAULT_BRANCH>` 는
      `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name` 으로 채운다.
      `<REPO_DIR>` 는 `$SCRIPTS/repo-dir.sh <repo>` 출력(메인 체크아웃 절대경로)으로
      채운다 — 워커의 codegraph 탐색(`-p`)이 이 경로의 인덱스를 읽는다.
      `<VERIFIER>` 는 ## 상수의 VERIFIER 를 폴백 규칙까지 적용해 채운다
      (codex 미설치면 `general-purpose`).

## ④ Report

한 줄 요약: `정리 N · 보수 N · 신규 N · 대기(사람 리뷰) N · warn N`.
warn 이 있으면 경로와 사유를 그 아래 나열.
**토큰 관측 (소프트 예산)**: 완료 보고를 낸 워커가 있으면 이슈별 한 줄
`토큰: <repo>#<num> <이번 보고치> (누적 <합>)` 을 추가하라. 이번 보고치는 완료
알림의 subagent_tokens (없으면 `?` — 누적에선 0 취급), 누적은 컨텍스트에 보이는
이전 틱 Report 의 같은 이슈 `토큰:` 수치 + 이번 보고치 (안 보이면 이번 보고치 그대로).
누적이 `SOFT_TOKEN_BUDGET_PER_ISSUE` 초과면 그 줄에 **"소프트 예산 초과 —
needs-human 승격 권고"** 를 명시하라 (보고만 — 라벨 부착·워커 중단 등 자동 조치 금지).
모든 카운트가 0이면 "조용함" 한 줄만.
3틱 연속 조용하면 다음 틱부터는 reconcile 만 하고 끝내라.

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 전제: 이 루프는 **GitHub 위에서만** 동작한다 — 이슈·라벨·assignee·PR이 상태의
  단일 진실 원천이며 GitHub Actions 는 불필요(local-ci 설계). 필요 권한 등 상세는
  README §전제 조건.
- 설치 모델: 계정 전체 디스패처이므로 스킬은 사용자 레벨(`~/.claude/skills`)에
  전역 설치하고, 레포별 참여는 라벨 옵트인(`setup-labels.sh`)으로 분리한다 —
  README §설치.
- 병행 운용: 세션 cwd 에 `.loop/repos` 허용목록이 있으면 수집(eligible)·점검
  (reconcile)이 그 레포들로 제한된다 — 프로젝트별 루프 세션 분리용, 없으면 계정
  전체. 스크립트가 자동 적용하므로 틱에서 따로 할 일은 없다 (README §사용법).
- 병용 권장: [codegraph](https://github.com/colbymchenry/codegraph) — 레포에
  `.codegraph/` 인덱스가 있으면 워커가 반복 grep/Read 대신 인덱스 조회로 탐색해
  토큰·툴콜을 줄인다. 레포별 `codegraph init` 옵트인 — 없어도 루프는 동작한다
  (README §전제 조건).
- 설계에 참고한 문헌: [Claude Code goal 공식 문서](https://code.claude.com/docs/en/goal) ·
  [루프 엔지니어링 담론 (YouTube)](https://www.youtube.com/watch?v=EH2MMQTaPEA) ·
  [Reddit 토론](https://www.reddit.com/r/myclaw/comments/1u047p8/so_is_loop_engineering_the_next_ai_dev_buzzword/) ·
  [agent loop internals 분석](https://internals.laxmena.com/p/why-claude-codes-agent-loop-is-over) ·
  [Rails 8.1 release notes — `bin/ci` 원형](https://guides.rubyonrails.org/8_1_release_notes.html)
