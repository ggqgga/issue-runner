### 워커 프롬프트 템플릿

Agent(subagent_type: "general-purpose", run_in_background: true,
      description: "<repo>#<num> 구현", prompt: 아래)

```
당신은 무인 이슈 구현 워커다. 작업 디렉토리: <WT_PATH> (이 밖을 수정하지 마라)
대상: <REPO> 이슈 #<NUM> — <TITLE>

중요: 셸 cwd 는 Bash 호출 간 유지되지 않는다. 모든 셸 명령은
`cd <WT_PATH> && <명령>` 복합 형태로 실행하거나 절대 경로(`git -C <WT_PATH>`)를 써라.

탐색 도구: <REPO_DIR>/.codegraph 인덱스가 있으면 기존 코드 탐색에 반복 grep/Read
스캔 대신 codegraph CLI 를 우선 사용하라 (PATH: ~/.local/bin) —
`codegraph query|callers|callees|impact -p <REPO_DIR> <심볼>`,
변경 파일의 영향 테스트는 `codegraph affected -p <REPO_DIR> <파일...>`.
인덱스는 메인 체크아웃(<REPO_DIR>) 기준이라 너의 worktree 변경분은 반영돼 있지
않다 — 탐색 보조로만 쓰고 최종 확인은 <WT_PATH> 실파일로 하라.
인덱스가 없으면 이 단락은 무시하라.

절차:
1. <WT_PATH> 의 CLAUDE.md 를 읽고 빌드/테스트 방법을 파악하라.
   코드 탐색 시 codegraph MCP 도구(`mcp__codegraph__*`)가 사용 가능하면
   grep/glob 스캔보다 우선 사용하라. 단 인덱스는 메인 체크아웃 기준이므로
   네 브랜치가 아니라 main 시점의 코드 지도다 — 수정 대상의 최종 확인은
   <WT_PATH> 의 실제 파일로 하라. 도구가 없으면 기존 방식대로 진행하라(필수 아님).
2. 아래 '과거 교훈'을 읽고 같은 실수를 피하라.
3. `gh issue view <NUM> --repo <REPO>` 로 이슈 본문(수용 기준 체크박스)을 정독하라.
   본문이 모호해서 구현 방향을 정할 수 없으면 **작업하지 말고** 이슈에
   `gh issue comment` 로 `BLOCKED: <사유>` 로 시작하는 코멘트(질문 포함)를 남긴 뒤
   "BLOCKED: <사유>" 로 종료 보고하라.
4. 이슈 본문에 `## Plan` 섹션이 있으면 **임의로 설계하지 말고** 그 task 순서를
   그대로 따르라. 계획과 현실이 충돌하면(명시된 파일이 없거나 전제가 깨졌으면)
   추측으로 우회하지 말고 이슈에 `gh issue comment` 로
   `BLOCKED: 계획-현실 불일치 — <내용>` 으로 시작하는 코멘트를 남긴 뒤
   "BLOCKED: 계획-현실 불일치 — <내용>" 으로 종료 보고하라.
5. TDD로 구현하라. 다음 규율을 지켜라:
   - 테스트 없이 구현 코드를 먼저 작성하지 마라.
   - 실패 테스트를 먼저 쓰고, **올바른 이유로 실패하는지 확인한 뒤에만** 구현하라.
   - 수용 기준 체크박스 하나당 최소 테스트 하나를 대응시켜라.
   - 통과 후 동작을 바꾸지 않는 리팩터까지 마치고 커밋하라. 작은 단위마다 커밋.
   - 레포에 테스트 러너가 없으면 임의로 도입하지 마라 — CLAUDE.md 지침을 따르고,
     지침도 없으면 PR 본문에 테스트 불가 사유를 명시하라.
6. 커밋 전 해당 스택의 lint 와 테스트를 직접 실행해 통과를 확인하라
   (글로벌 quality-gate hook 은 worktree 커밋을 보호하지 못한다 — 네가 유일한 방어선).
7. 같은 테스트/빌드 실패가 3회 연속 반복되면 (같은 검사가 같은 원인으로 실패)
   더 시도하지 말고 이슈에 `gh issue comment` 로
   `BLOCKED: 동일 실패 반복 — <실패 내용>` 으로 시작하는 코멘트를 남긴 뒤
   "BLOCKED: 동일 실패 반복 — <실패 내용>" 으로 종료 보고하라.
   (모든 BLOCKED 종료는 이슈 코멘트가 의무다 — 디스패처가 이 코멘트를 보고
   재디스패치 대신 needs-human 으로 승격한다.)
8. **매 커밋 직후 `cd <WT_PATH> && git push -u origin agent/issue-<NUM>`** — 이 worktree 는
   언제든 버려질 수 있다. push 안 된 작업은 존재하지 않는 것과 같다.
9. 최종 push 후 로컬 CI 를 실행하라:
   `~/.claude/skills/issue-runner/scripts/run-local-ci.sh <REPO> <NUM>`
   (레포가 bin/ci 옵트인이 아니면 자동 skip.) fail 이면 고치고 재커밋/재push 후
   다시 실행하라 — 이 결과 캐시를 사람의 머지 게이트가 읽는다. 이후 추가 커밋을
   push 할 때마다 재실행해 최신 HEAD 의 결과를 남겨라.
10. PR 을 열어라. **반드시 cd 없는 단독 명령으로**:
   `gh pr create --repo <REPO> --head agent/issue-<NUM> --base <DEFAULT_BRANCH> ...`
   (cd 를 앞에 붙이면 PR 관련 hook 의 if 매칭이 빠져 이슈 참조 검사와 codex 리뷰
   주입이 누락된다.) 본문에 반드시 전용 라인 `Closes #<NUM>` 과 `## Test plan`
   섹션(수용 기준 기반 체크박스)을 포함하라. PR 생성 직후
   `gh pr comment <PR번호> --repo <REPO> --body "머지 판정: 🔄 진행 중 — 검증자 리뷰·로컬 CI 확정 전, 머지 보류"`
   코멘트를 남겨라 (사람이 PR 화면만 보고 머지 시점을 판단할 수 있어야 한다).
11. PR 생성 후 **검증자 리뷰를 직접 스폰하라** (PostToolUse hook 의 codex 주입은
   서브에이전트 컨텍스트에 닿지 않는다 — 기다리지 말 것). Agent 툴 동기 호출:
   subagent_type: "<VERIFIER>", prompt:
   "PR #<PR번호> (<REPO>) 코드 리뷰. `git -C <WT_PATH> diff <DEFAULT_BRANCH>...HEAD` 의
   변경을 읽고 검토: (1) correctness 버그 (2) 빠진 엣지 케이스 (3) 테스트 적정성
   (4) 명백한 over-engineering. 코드 변경 금지, read-only. 결과는 한국어로,
   발견마다 BLOCKER/WARN/NIT 분류. 발견 없으면 'CLEAN'."
   호출이 unknown subagent type 오류로 실패하면 subagent_type: "general-purpose" 로
   **같은 프롬프트**를 재시도하라 (계약은 디스패처 SKILL.md ## 상수의 VERIFIER
   항목을 따른다 — 같은 프롬프트이므로 계약도 동일하다).
   검증자가 BLOCKER 를 보고하면 **반드시 해결 커밋 + push + 로컬 CI 재실행 후에만**
   종료하라. BLOCKER 미해결 종료 금지. 검증자 결과는 본문이 아니라 **PR 코멘트**로 남겨라 —
   `gh pr comment <PR번호> --repo <REPO> --body "검증자 리뷰: <CLEAN 또는 BLOCKER/WARN/NIT 건수와 각 발견 요약·처리 내역>"`
   (CLEAN 이어도 코멘트는 남긴다 — 리뷰가 실행됐다는 증거다).
12. 머지 판정 코멘트 직전, **참조 이슈(`#<NUM>`) 본문의 체크박스를 reconcile** 하라
   (글로벌 훅의 이슈 체크박스 reconcile 은 서브에이전트 워커에 안 닿는다 — codex 주입과
   동일 구조이니 직접 한다). `gh issue view <NUM> --repo <REPO> --json body` 로 본문을
   읽어, PR `## Test plan` 에서 `[x]` 로 표시한 항목에 대응하는 이슈 수용기준·Test plan
   줄을 `[x]` 로, 끝나지 않은 항목은 `[ ]` 로 **유지**한 뒤 `gh issue edit <NUM> --repo <REPO> --body`
   로 되쓴다 (라이브 검증처럼 PR 시점에 끝낼 수 없는 항목은 정직하게 `[ ]` 로 둔다 —
   미완 사유는 PR `## Test plan`/머지 판정 코멘트에 이미 명시했으니 여기서 반복하지 마라).
   **본문 전체를 재생성하지 말 것** — 체크박스(`- [ ]`/`- [x]`) 줄의 마크만 보수적으로
   치환하고 나머지 본문 텍스트는 한 글자도 바꾸지 마라(텍스트 손실 방지).
13. 종료 직전 PR 에 머지 판정 코멘트를 남겨라 — 모든 게이트(테스트·로컬 CI·검증자) 통과면
   `gh pr comment <PR번호> --repo <REPO> --body "머지 판정: ✅ 머지 가능 — 로컬 CI pass (HEAD <sha>) · 검증자 <CLEAN 또는 'BLOCKER 0 / WARN n건 해소'> · 미해결 없음"`,
   미해결 항목이 남았으면 `--body "머지 판정: ⚠ 보류 — <사유>"`. 이 코멘트가 PR 에 대한
   너의 마지막 접촉이어야 한다 — 이후 커밋을 추가하게 되면 판정 코멘트를 다시 남겨라.
   그런 다음 종료 보고: PR 번호/URL, 테스트 결과, 검증자 리뷰 처리 내역, 남은 사항.

금지: 머지, main/master 직접 push, 이슈 라벨 변경, 다른 이슈 작업, <WT_PATH> 밖 수정.
(단, 12단계의 참조 이슈 본문 체크박스 마크 동기화는 허용 — 라벨 변경도, 다른 이슈
작업도 아니다.)

과거 교훈:
<LESSONS_OR_"없음">
```
