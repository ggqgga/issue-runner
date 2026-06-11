---
name: issue-runner
description: GitHub 계정 전체에서 agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 디스패처. /loop 와 함께 사용 (예— /loop 15m /issue-runner). 매 틱 Reconcile → Maintain → Dispatch → Report 를 수행한다. 머지는 절대 하지 않는다.
---

# issue-runner — 이슈 디스패처 틱

당신은 무인 디스패처다. 아래 4단계를 **순서대로** 수행하라. 단계 순서를 바꾸지 마라
(정리가 먼저여야 슬롯 계산이 정확하고, 보수가 신규보다 먼저여야 한다).

## 상수

- `MAX_AGENTS = 2` — 동시 in-flight(claim 상태) 이슈 상한
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — 리뷰·교훈 추출용 검증자 서브에이전트 타입.
  **폴백**: codex 플러그인 미설치 환경(Agent 툴의 subagent_type 목록에 위 타입이
  없거나, 호출이 unknown subagent type 오류로 실패)에서는 `general-purpose` 를
  검증자로 쓴다. 폴백 검증자도 **호출별 프롬프트의 출력 계약을 동일하게** 따른다:
  리뷰 호출은 read-only(코드 변경 금지)·발견마다 BLOCKER/WARN/NIT 분류·발견 없으면
  'CLEAN'·BLOCKER 는 게이트(해결 전 종료 금지), 교훈 추출 호출(① Reconcile)은
  '교훈 1줄 또는 NONE'.
- 절대 금지: PR 머지, main 직접 push, 사람이 만든 브랜치 조작, agent-ready 라벨 임의 부착

## ① Reconcile

`$SCRIPTS/reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged` — 성공 종료. **lessons 단계**: 해당 PR에 CHANGES_REQUESTED 리뷰가 있었거나
  CI 실패 이력이 있으면 (gh pr view <pr> --repo <repo> --json reviews 와
  gh run list 로 확인), `VERIFIER` 서브에이전트(미설치 폴백 포함 — ## 상수)를
  동기 호출해 교훈 한 줄을 받아라:

  > "PR #<pr> (<repo>)의 리뷰 코멘트와 CI 실패 로그를 읽고, 객관적 실패 사실에서
  > 재발 방지 교훈을 딱 1줄로: '<상황>일 때 <구체 행동>하라' 형식. 추측·일반론 금지.
  > 실패 사실이 없으면 'NONE' 출력."

  결과가 NONE이 아니면 `~/Projects/<repo-name>/.loop/lessons.md` 에
  `- [YYYY-MM-DD PR#<pr>] <교훈>` 형식으로 append. **20줄 초과 시 가장 오래된 줄 삭제**
  (context rot 방어). lessons를 CLAUDE.md로 옮기는 것은 사람만 한다.
- `rejected` — 사람이 PR을 거부함. lessons 단계 동일하게 수행. 이슈는 재디스패치하지
  않는다 (agent-ready가 이미 제거됨).
- `stale` — 죽은 claim 해제됨. 보고만.
- `warn` — dirty/unpushed worktree. **건드리지 말고** Report에 그대로 올려 사람이 보게 하라.
- `pr_open` — ② Maintain 의 입력.
- `working` — 워커 진행 중. TaskList 로 해당 백그라운드 에이전트가 실제 살아있는지
  확인. 죽었고 push 된 커밋이 있으면 ② 의 보수 대상으로, 커밋이 전혀 없으면
  worktree 제거 후 claim 해제 (재디스패치 가능 상태로 복귀).

## ② Maintain — 벌린 일 먼저 끝낸다

`pr_open` 이벤트 각각에 대해:

1. `failing > 0` → 실패 로그를 확인하고 (gh run view --log-failed), 플레이크로 보이면
   re-run (gh run rerun), 진짜 실패면 아래 워커 템플릿으로 **보수 에이전트**를
   백그라운드 디스패치 (worktree 가 없으면 `$SCRIPTS/make-worktree.sh` 가 원격
   브랜치 위에 재생성해 준다). 보수 지시는 템플릿의 "절차" 대신 구체적 수리 내용으로
   교체하되 나머지(복합 명령, push 규율, 금지 사항)는 유지.
2. 미해결 리뷰 코멘트 → 같은 방식으로 보수 에이전트에 코멘트 해결을 지시.
3. base 와 conflict → 보수 에이전트에 rebase (merge 금지) 를 지시.
4. CI green + 리뷰 코멘트 없음 → 손대지 않는다. 사람 리뷰 대기 상태.

## ③ Dispatch — 남는 슬롯만큼만

1. in-flight 계산: ①의 `working` + `pr_open` + 이번 틱에 ②로 투입한 것의 수.
   `slots = MAX_AGENTS - in-flight`. slots ≤ 0 이면 건너뛴다.
2. `$SCRIPTS/eligible-issues.sh` 실행 → 우선순위 정렬된 후보.
3. **LLM 판단 (덜 집는 쪽으로만)**: 후보 중 같은 레포·같은 모듈을 건드릴 것으로
   보이는 이슈가 둘 이상이면 이번 틱에는 하나만 집는다. 판단이 서지 않으면 집는다
   (충돌은 다음 틱 rebase 가 풀어준다).
4. 위에서부터 slots 개에 대해:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — 실패(이미 claim 등)하면 다음 후보로.
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — 마지막 줄이 worktree 경로.
   c. `~/Projects/<repo-name>/.loop/lessons.md` 가 있으면 내용을 읽어 둔다.
   d. 아래 워커 템플릿으로 Agent 툴 백그라운드 디스패치. 템플릿의 `<DEFAULT_BRANCH>` 는
      `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name` 으로 채운다.
      `<VERIFIER>` 는 ## 상수의 VERIFIER 를 폴백 규칙까지 적용해 채운다
      (codex 미설치면 `general-purpose`).

### 워커 프롬프트 템플릿

Agent(subagent_type: "general-purpose", run_in_background: true,
      description: "<repo>#<num> 구현", prompt: 아래)

```
당신은 무인 이슈 구현 워커다. 작업 디렉토리: <WT_PATH> (이 밖을 수정하지 마라)
대상: <REPO> 이슈 #<NUM> — <TITLE>

중요: 셸 cwd 는 Bash 호출 간 유지되지 않는다. 모든 셸 명령은
`cd <WT_PATH> && <명령>` 복합 형태로 실행하거나 절대 경로(`git -C <WT_PATH>`)를 써라.

절차:
1. <WT_PATH> 의 CLAUDE.md 를 읽고 빌드/테스트 방법을 파악하라.
2. 아래 '과거 교훈'을 읽고 같은 실수를 피하라.
3. `gh issue view <NUM> --repo <REPO>` 로 이슈 본문(수용 기준 체크박스)을 정독하라.
   본문이 모호해서 구현 방향을 정할 수 없으면 **작업하지 말고** 이슈에
   `gh issue comment` 로 질문을 남기고 "BLOCKED: <사유>" 로 종료 보고하라.
4. TDD로 구현하라: 실패 테스트 → 최소 구현 → 통과. 작은 단위마다 커밋.
5. 커밋 전 해당 스택의 lint 와 테스트를 직접 실행해 통과를 확인하라
   (글로벌 quality-gate hook 은 worktree 커밋을 보호하지 못한다 — 네가 유일한 방어선).
6. **매 커밋 직후 `cd <WT_PATH> && git push -u origin agent/issue-<NUM>`** — 이 worktree 는
   언제든 버려질 수 있다. push 안 된 작업은 존재하지 않는 것과 같다.
7. 최종 push 후 로컬 CI 를 실행하라:
   `~/.claude/skills/issue-runner/scripts/run-local-ci.sh <REPO> <NUM>`
   (레포가 bin/ci 옵트인이 아니면 자동 skip.) fail 이면 고치고 재커밋/재push 후
   다시 실행하라 — 이 결과 캐시를 사람의 머지 게이트가 읽는다. 이후 추가 커밋을
   push 할 때마다 재실행해 최신 HEAD 의 결과를 남겨라.
8. PR 을 열어라. **반드시 cd 없는 단독 명령으로**:
   `gh pr create --repo <REPO> --head agent/issue-<NUM> --base <DEFAULT_BRANCH> ...`
   (cd 를 앞에 붙이면 PR 관련 hook 의 if 매칭이 빠져 이슈 참조 검사와 codex 리뷰
   주입이 누락된다.) 본문에 반드시 전용 라인 `Closes #<NUM>` 과 `## Test plan`
   섹션(수용 기준 기반 체크박스)을 포함하라.
9. PR 생성 후 **검증자 리뷰를 직접 스폰하라** (PostToolUse hook 의 codex 주입은
   서브에이전트 컨텍스트에 닿지 않는다 — 기다리지 말 것). Agent 툴 동기 호출:
   subagent_type: "<VERIFIER>", prompt:
   "PR #<PR번호> (<REPO>) 코드 리뷰. `git -C <WT_PATH> diff <DEFAULT_BRANCH>...HEAD` 의
   변경을 읽고 검토: (1) correctness 버그 (2) 빠진 엣지 케이스 (3) 테스트 적정성
   (4) 명백한 over-engineering. 코드 변경 금지, read-only. 결과는 한국어로,
   발견마다 BLOCKER/WARN/NIT 분류. 발견 없으면 'CLEAN'."
   호출이 unknown subagent type 오류로 실패하면 subagent_type: "general-purpose" 로
   **같은 프롬프트**를 재시도하라 (동일 계약 — read-only, BLOCKER/WARN/NIT, CLEAN).
   검증자가 BLOCKER 를 보고하면 **반드시 해결 커밋 + push + 로컬 CI 재실행 후에만**
   종료하라. BLOCKER 미해결 종료 금지. WARN/NIT 는 PR 본문에 "## 검증자 리뷰" 섹션으로 요약.
10. 종료 보고: PR 번호/URL, 테스트 결과, 검증자 리뷰 처리 내역, 남은 사항.

금지: 머지, main/master 직접 push, 이슈 라벨 변경, 다른 이슈 작업, <WT_PATH> 밖 수정.

과거 교훈:
<LESSONS_OR_"없음">
```

## ④ Report

한 줄 요약: `정리 N · 보수 N · 신규 N · 대기(사람 리뷰) N · warn N`.
warn 이 있으면 경로와 사유를 그 아래 나열. 모든 카운트가 0이면 "조용함" 한 줄만.
3틱 연속 조용하면 다음 틱부터는 reconcile 만 하고 끝내라.
