---
name: closeout
description: issue-runner 가 연 초록불 PR을 머지·문서반영·배포준비·후속발행까지 자동 마감하는 루프. /loop 와 함께 (예 /loop 20m /closeout). 매 틱 Reconcile → Pick → 파이프라인 → Report.
---

# closeout — 마감 도크 틱

당신은 무인 마감 워커다. 아래 단계를 **순서대로** 수행하라. issue-runner 가 벌린
초록불 PR을 머지·문서반영·배포준비·후속발행까지 끝까지 마감한다 — issue-runner 는
절대 머지하지 않으므로, 머지는 이 루프의 독점이다. 두 루프의 충돌은 `harvesting`
라벨 점유로 막는다 (issue-runner ② Maintain 은 `harvesting` PR 을 건드리지 않는다).

## 상수

- `MAX_CLOSEOUT = 1` — 틱당 1 PR 을 끝까지 마감(직렬화 스로틀, 적체 상한이 아니다).
  페이스는 `/loop` 주기로 조절한다 — 한 틱이 한 PR 의 1~6단계를 다 돈다.
- `REPAIR_RECUR_LIMIT = 2` — 같은 배포 후 실패가 N회 재발하면 agent-ready 재발행
  대신 `needs:human` 으로 승격한다 (5단계 서킷 브레이커).
- `QUIET_TICKS = 3` — N틱 연속 후보·이벤트가 없으면 stagnated 로 보고하고 다음
  틱부터 reconcile 만 한다.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — 1단계 계획 부합 검증자 서브에이전트 타입.
  **출력 계약 (SSOT — 다른 모든 곳은 이 항목을 참조한다)**: 호출은 read-only(코드
  변경 금지)·발견마다 BLOCKER/WARN/NIT 분류·발견 없으면 'CLEAN'·BLOCKER 는
  하드게이트(해결 전 종료 금지). 검증자는 이 SKILL.md 를 읽지 않으므로 호출
  프롬프트 문자열에 이 계약이 그대로 담겨야 한다 — 프롬프트가 유일한 전달 경로다.
  **폴백**: 아래 둘 중 하나면 `general-purpose` 를 검증자로 쓴다 (같은 프롬프트로
  호출하므로 계약도 동일하게 적용된다) — (a) codex 플러그인 미설치(Agent 툴의
  subagent_type 목록에 위 타입이 없거나, 호출이 unknown subagent type 오류로 실패),
  (b) codex 가 stall/실패해 verdict(BLOCKER/WARN/NIT/CLEAN)를 못 냄 — 네트워크
  차단·타임아웃·verdict 없는 응답 포함(실증 2026-06-24 #54: codex 가 sandbox 에서
  gh 네트워크 차단으로 verdict 미산출). 폴백 호출도 verdict 를 못 내면 BLOCKER 로
  간주해 보류 종료한다 (게이트 fail-closed).
- 절대 금지: production 무인 배포(4단계는 사람 게이트 — 실 배포 안 함) · main 직접
  push(문서 reconcile 도 PR 브랜치 경유) · `harvesting` 점유 없이 머지 · issue-runner
  가 만든 워크트리/브랜치 조작 · issue-runner 의 "절대 머지 안 함" 불변 훼손.

## ① Reconcile

`$SCRIPTS/closeout-reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged_cleanup` — 머지·라벨·worktree 정리가 끝났다(`closeout-reconcile.sh` 가
  머지 확정 시 PR head `agent/issue-N` 을 파싱해 `cleanup-worktree.sh ... --merged`
  로 worktree 까지 거둔다 — 크래시 재개 경로의 적체 방지). 단 아래 마커표에서
  4·6단계 미완 마커가 발견되면 그 단계부터 이어간다 (멱등 재개).
- `resume` — PR 이 OPEN 이고 `harvesting` 유지 중. 마커표로 끝난 단계를 건너뛰고
  중단 지점부터 파이프라인을 이어간다.
- `stale` — 보고만 한다.

멱등 마커표 (끝난 단계 재판정용 — 재개 시 중복 작업 방지):

| 단계 | 마커 | 재개 판정 |
|---|---|---|
| 1 검증 | PR 코멘트 `마감 검증:` | 있으면 1단계 건너뜀 |
| 2 머지 | PR `MERGED` | MERGED 면 머지 끝 (머지 직후 worktree 정리 포함) |
| 3 reconcile | 계획문서 diff(머지 커밋) + epic 코멘트 | 머지에 포함이면 끝 |
| 4 배포 | `배포 대기:` 코멘트 / `deployed:<sha>` | 있으면 재요청 안 함 |
| 5 후처리 | 발행 이슈 번호 코멘트 | 있으면 재발행 안 함 |
| 6 파생 | 생성 이슈 번호 코멘트 | 있으면 재발행 안 함 |

## ② Pick — 틱당 1 PR (MAX_CLOSEOUT=1)

`$SCRIPTS/closeout-eligible.sh` 출력의 **첫 후보 1개만** 집는다. 틱당 1개라
모듈 겹침 판단은 불필요하다 (직렬 마감). 집으면 즉시
`gh issue edit <pr> --repo <repo> --add-label harvesting` 으로 점유를 선언하라 —
이 라벨이 있어야 issue-runner ② Maintain 이 이 PR 을 건드리지 않는다. 후보가 0이면
③ 파이프라인을 건너뛰고 ④ Report 에 clean no-op 으로 보고한다.

**라벨 부재 자동 보강.** 옵트인 레포여도 `setup-labels.sh` 재실행 전에는
`harvesting` 라벨이 없을 수 있다(기존 레포 공통). `--add-label harvesting` 이
`'harvesting' not found` 류로 실패하면 **`$SCRIPTS/setup-labels.sh <repo>` 를 1회
호출**(멱등 — 이미 있는 라벨은 갱신만)한 뒤 `--add-label harvesting` 을 1회만
재시도한다. 재시도도 실패하면 **더 반복하지 말고**(무한루프 금지) 이 PR 을 skip 하고
④ Report 에 `BLOCKED: harvesting 라벨 보강 실패 — <repo>` 로 보고한다.

## ③ 파이프라인 — 1~6단계

집은 PR 에 대해 아래 6단계를 순서대로 수행한다. 각 단계 끝에 마커 명령을 박아
(① Reconcile 마커표) 다음 틱이 멱등 재개할 수 있게 한다.

**1단계 — 계획 부합 검증.** 검증자가 sandbox 에서 gh·git 네트워크에 닿지 못해도
판정하도록, **메인 세션이 먼저 원문을 받아 프롬프트에 동봉**한다. `<issue>` 는 PR
본문의 `Closes #N` / `Refs #N` 줄에서 얻는다(`gh pr view <pr> --repo <repo> --json
body` 로 파싱). 그런 다음 `gh pr diff <pr> --repo <repo>` 로 diff 를,
`gh issue view <issue> --repo <repo>` 로 이슈 본문을 받아둔다(연결 이슈가 없으면
`<ISSUE_BODY>` 는 빈 문자열). 이어 `references/verifier-prompt.md` 의 placeholder 를
채워 `VERIFIER` 를 동기 호출한다: `<PR>`·`<REPO>`·`<BASE>`=default branch·
`<PLAN_REF>`=이슈 `## Plan` 또는 참조한 `Plans/*.md`(없으면 빈 문자열)·`<DIFF>`=위
pr diff 출력·`<ISSUE_BODY>`=위 issue view 출력 (## 상수의 VERIFIER 계약·폴백을
따른다). 검증자 프롬프트는 diff·이슈 본문을 본문으로 담고 있으므로 검증자는 추가
네트워크 명령을 실행하지 않는다.
- 동봉 실패 fail-closed: `gh pr diff` 가 실패하거나 diff 가 비면, 또는 diff 가
  검증자 컨텍스트에 다 안 들어갈 만큼 크면(판단이 서면) 검증을 통과로 보지 말고
  BLOCKER 경로로 보류 종료한다(머지 안 함) — 네트워크 비의존 경로가 조용히 깨진 채
  머지로 새지 않게 한다.
  머신 코멘트 마커(필수): 아래 `gh pr comment` 로 남기는 마감 검증 코멘트는 **마지막 줄에
  `<!-- bodat:worker -->`** 를 포함한다 — closeout-eligible 이 머신 코멘트를 사람 리뷰와
  구분하는 신호다(#72). 빠지면 그 PR 이 재평가 때 미해결 사람 코멘트로 오인돼 탈락한다.
- BLOCKER → `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <사유>
  <!-- bodat:worker -->"`
  + `gh issue edit <issue> --repo <repo> --add-label needs-human`
  + `gh issue edit <pr> --repo <repo> --remove-label harvesting` →
  **blocked 종료** (머지하지 않는다).
- CLEAN/WARN → `gh pr comment <pr> --repo <repo> --body "마감 검증: ✅ <CLEAN 또는 WARN n>
  <!-- bodat:worker -->"`
  (이 코멘트가 1단계 완료 마커다).

**2단계 — 머지 게이트.** 머지 명령은 **반드시 `--repo <repo>` 를 넘긴다** —
closeout 은 cwd 밖 레포의 PR 을 머지하므로 ci-gate 훅이 `--repo` 로 그 레포를
조회해야 fail-closed 를 안 맞는다 (훅 `--repo` 인식은 #47; 실증 2026-06-24: BoDAT
cwd 세션에서 issue-runner PR 머지 시 훅이 cwd 레포를 조회해 차단됨). 게이트 통과
조건: `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` (exit 0) + 워커가 남긴
`검증자 리뷰:` 코멘트가 BLOCKER 0 + `gh pr view <pr> --repo <repo> --json mergeable`
≠ CONFLICTING 재확인.
- **rebase된 HEAD 재검증 (`revalidate:true` 선행 게이트, #70).** ② Pick 이 집은
  후보의 `revalidate` 가 true 면(= `closeout-ci-pass.sh` 가 exit 2 — rebase 등으로
  현재 HEAD 의 로컬 CI 캐시가 비어 "fail 이 아니라 미실행"), 위 exit 0 게이트를
  판정하기 **전에** 현재 HEAD 를 재검증한다: `$SCRIPTS/make-worktree.sh <repo> <N>`
  로 worktree 확보(`<N>`=PR head `agent/issue-N` 파싱, 3단계와 동일) → **그 worktree 를
  rebase된 원격 head 로 동기화**(`make-worktree.sh` 는 기존 worktree 가 있으면 그대로
  반환해 rebase 전 SHA 가 체크아웃된 채일 수 있다 — 3단계와 달리 이 경로는 새 커밋을
  안 만들어 동기화가 freshness 의 유일한 보장이다): `git -C <wt> fetch origin` 후
  `git -C <wt> reset --hard origin/agent/issue-<N>` 으로 worktree HEAD 를 PR 의 현재
  (rebased) head SHA 에 맞춘다(이 SHA 가 `closeout-ci-pass.sh` 가 `gh pr view headRefOid`
  로 조회하는 바로 그 SHA — 안 맞추면 run-local-ci 가 옛 SHA 를 캐시해 영구 exit 2 로
  남는다) → `$SCRIPTS/run-local-ci.sh <repo> <N>` 로 **현재 HEAD** 캐시를 채운다. `run-local-ci.sh`
  가 비0(새 base 와의 통합이 깨짐)이면 머지하지 말고 fail-closed 로 보류 종료한다
  (`harvesting` 제거 + `blocked` 종료, 새 종료 상태 안 만듦). 0이면 캐시가 pass 로
  채워졌으니 아래 exit 0 게이트로 합류한다. 이 경로는 **3단계 doc 커밋 유무와
  무관**하게 발동한다 — 3단계 캐시 보강은 doc push 후에만 돌아 rebase·doc무변경
  케이스(워커 `머지 판정 ✅` 이 새 SHA 에 안 따라온 채)를 못 메우기 때문이다.
  (`revalidate:false` 면 캐시가 이미 pass 라 이 재검증을 건너뛴다.)

모두 통과면 **여기서 3단계(문서 reconcile)를 먼저 수행**해 PR 브랜치에 문서 커밋을
만들고 push 한 뒤 — squash 머지가 그 문서 반영을 포함하도록 — `gh pr merge <pr>
--repo <repo> --squash` (ci-gate 훅이 한 번 더 판정한다). 즉 단계 번호는 1→2→3
순서지만, 2단계의 머지 직전에 3단계 커밋을 끼워 넣는다 (3단계 헤더의 "머지 전"이
이 끼워넣기 지점이다). **`gh pr merge` 직전, 3단계가 새 doc 커밋을 push 했다면**
`$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` 가 pass(exit 0)인지를 짧은 한도 폴링
(예: 2~3초 간격 × 최대 5회, 무한 대기 금지)으로 재확인하고 — 3단계의
`run-local-ci.sh` 가 캐시를 동기로 채우므로 보통 즉시 pass — 한도 내 pass 미도달이면
머지하지 말고 fail-closed 로 보류 종료한다(아래 3단계의 캐시 비0/미도달 처리와 동일
경로 — `harvesting` 제거 + `blocked` 종료, 새 종료 상태를 만들지 않는다).
**`gh pr merge` 성공 직후** `$SCRIPTS/cleanup-worktree.sh <repo> <N> --merged` 를
호출해 이 PR 의 worktree(`agent/issue-<N>`)를 직접 정리한다 (`<N>`=PR head
`agent/issue-N` 파싱, 3단계와 동일). 머지를 독점하는 closeout 이 머지 시점에 스스로
거두므로 issue-runner reconcile 에 의존하지 않는다 — closeout-only 세션서도 적체가
없다. `--merged` 는 squash 머지로 원격 head 가 자동삭제돼 `@{u}` 가 사라지는
함정에서 미push 가드를 완화한다(더티 가드는 유지 — 더티면 warn 후 보류, best-effort).
CONFLICTING 이면 `harvesting` 을 제거하고 skip 한다 (issue-runner Maintain 이 rebase).

**3단계 — 문서 reconcile (머지 전, PR 브랜치 커밋).** 1단계가 구현을 확인한
계획문서 절의 `- [ ]` 를 `- [x]` 로 바꾼다. PR 브랜치 worktree
(`$SCRIPTS/make-worktree.sh <repo> <N>` 로 확보 — `<N>`=PR head 브랜치
`agent/issue-<N>` 에서 파싱(`gh pr view <pr> --repo <repo> --json headRefName`), 멱등)
에서 커밋·push 하여 squash 머지에 포함시킨다 (main 직접 push 금지). epic 이 있으면
진행 롤업 코멘트를 남긴다.
- **캐시 보강 (push 직후, 옵션1).** doc 커밋을 push 했으면 **그 직후**
  `$SCRIPTS/run-local-ci.sh <repo> <N>` 를 1회 호출한다 (`<N>`=위에서 파싱한 이슈
  번호 — worktree 경로 `issue-<N>` 식별용; `closeout-ci-pass.sh` 의 `<pr>` 와 다름).
  이 헬퍼가 worktree HEAD SHA 를 읽어 `repo-dir.sh` 로 **메인 레포 slug** 의 로컬 CI
  캐시(`<메인slug>/<SHA>.result`)를 채운다 — 2단계 머지 게이트(`ci-gate`·
  `closeout-ci-pass.sh`)가 읽는 바로 그 위치라, 워크트리 slug 에만 남아 영구
  cache-miss 로 fail-closed 되는 갭을 메운다. **호출 전 멱등 가드**:
  `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` 가 이미 pass(exit 0)면(이전 틱이 같은
  HEAD 를 이미 캐시함) `run-local-ci.sh` 를 재실행하지 않는다(헬퍼 자체엔 dedup 가
  없어 호출측이 가드한다). `run-local-ci.sh` 가 비0(=bin/ci 실패)이면 캐시가 pass 로
  안 채워진 것이므로 머지하지 말고 fail-closed 로 보류 종료한다(`harvesting` 제거 +
  `blocked` 종료, 기존 BLOCKER 경로 준용 — 새 종료 상태를 만들지 않는다).
- **단일 이슈 degrade**: `Plans/*.md`·`## Plan` 이 없으면 문서 편집을 skip 한다.
  epic 이 없으면 롤업을 skip 한다. 이슈 자체 체크박스만 reconcile 한다. 둘 다
  없으면 이 단계는 no-op — **새 doc 커밋·push 가 없으므로 위 캐시 보강도 건너뛴다**
  (채울 새 HEAD SHA 가 없다).

**4단계 — 배포 (사람 게이트, dry-run).** **실 배포를 하지 않는다.**
`references/deploy-check-issue.md` 를 채워(`<DEPLOY_CMD>`=레포 배포 엔트리포인트,
모르면 "레포 배포 절차"; `<VERIFY_URL>`=production 베이스 URL — 5단계 스모크가 몰
주소, 모르면 빈 줄로 둬 5단계가 URL 도달불가로 폴백) `gh issue create --repo <repo>
--label needs-human` 으로 배포 요청 이슈를 발행하고,
`gh pr comment <pr> --repo <repo> --body "배포 대기: #<생성번호>"` 로 마커를 남긴 뒤
→ **approval-required 로 종료**한다.

**5단계 — 배포 후 처리 (Chrome 스모크).** 사람이 배포를 보고한 배포 이슈에 대해
새 감지 기구 없이(폴링/타이밍 미도입) 능동적으로 Chrome 스모크를 돌려 판정한다.
배포 이슈 본문에서 `## 검증 URL`(`<VERIFY_URL>`)과 `## 라이브/하드웨어 검증 항목`
(`<LIVE_CHECKS>`)을 파싱해 `references/smoke-prompt.md` 의 placeholder 에 채우고,
chrome-devtools MCP 도구를 ToolSearch 로 로드해 `navigate_page` 로 `<VERIFY_URL>` 에
진입한 뒤 각 항목을 `evaluate_script`/`take_snapshot` 으로 대조해 항목별 pass/fail 을
산출한다 (구조/빈 상태 확인과 실 데이터 렌더 확인을 결과에 구분 표기).
- **저하(degrade) — 조용한 skip 금지.** chrome-devtools MCP 가 세션에 없거나(헤드리스/
  크론 — 대화형 인증 MCP 부재 가능) `<VERIFY_URL>` 이 비었거나 도달 불가면, 스모크를
  건너뛰고 기존 사람-보고 경로로 폴백하되 배포 이슈에 `스모크 skip: <사유>` 코멘트를
  남긴다(누락 은폐 금지).
- **green (전부 통과)** → 배포 이슈 + 원본 PR 에 `✅ 스모크: <n>/<n> 통과` 코멘트(이
  코멘트가 5단계 완료 마커 — 재개 틱이 재스모크하지 않는다). 이어 배포 이슈에서
  `needs-human` 라벨을 제거하고 배포 이슈를 close 한다(남은 게이트가 검증뿐이고 그게
  통과했으므로 closeout 이 종결 — 미결 결정의 권장안).
- **fail (한 건이라도 실패)** → 직접 고치지 않고 기존 발행 경로: 자동수정 가능하면
  `references/spinoff-issue.md` 로 agent-ready 이슈, 라이브 검증이 필요하면
  `needs:human` 이슈. 같은 실패가 `REPAIR_RECUR_LIMIT` 회 반복되면 `needs:human` 으로
  승격한다 (**exhausted 종료**). 배포 이슈는 닫지 않는다.

**6단계 — 파생 이슈.** 워커 PR 본문의 `follow-up:` 항목 + 1단계 diff 리뷰가 짚은
인접 작업을 `references/spinoff-issue.md` 로 채워 agent-ready 이슈로 발행한다.
epic 이 있으면 sub-issue 로 연결하고, 없으면 독립 이슈로. 생성한 번호를 원본 PR
코멘트에 기록한다 (중복 발행 방지 마커).

## ④ Report

한 줄 요약: `마감 N · 검증보류 N · 배포대기 N · 파생 N · stale N`.

종료 상태 6종을 명시한다:
- **success** — 1~6단계를 다 돌아 PR 을 머지하고 후속까지 발행함.
- **clean no-op** — ② Pick 후보가 0이라 마감할 PR 이 없음.
- **blocked** — 1단계 검증이 BLOCKER 라 보류(머지 안 함).
- **approval-required** — 4단계에서 배포 이슈를 발행하고 사람 게이트 대기.
- **exhausted** — 5단계 같은 실패가 `REPAIR_RECUR_LIMIT` 회 반복돼 needs:human 승격.
- **stagnated** — `QUIET_TICKS` 연속 조용함.

`QUIET_TICKS` 연속으로 조용하면 다음 틱부터는 reconcile 만 하고 끝낸다.

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 역할 분담: issue-runner = 벌리는 공장 (절대 머지하지 않고 불변을 보존), closeout
  = 마감 도크 (머지를 독점). 두 루프는 `harvesting` 라벨 점유로 충돌을 막는다 —
  closeout 가 집은 PR 은 issue-runner ② Maintain 이 건드리지 않는다.
- 사람 게이트: production 배포만 사람이 승인한다 (4단계 dry-run 이슈 발행 → 승인).
  나머지 머지·문서반영·후속발행은 무인.
- 운용: closeout 은 issue-runner 와 별도의 `/loop` 세션으로 돌린다
  (예 `/loop 20m /closeout`) — 서로의 점유를 라벨로만 조율한다.
- 의존: 결정적 헬퍼(`closeout-reconcile.sh`·`closeout-eligible.sh`·
  `closeout-ci-pass.sh`)는 `$SCRIPTS`(=`~/.claude/skills/issue-runner/scripts`)에
  있고, references 3종(`verifier-prompt.md`·`deploy-check-issue.md`·
  `spinoff-issue.md`)은 `skills/closeout/references/` 에 있다.
