---
name: verify-runner
description: issue-runner 가 연 PR 을 받아 test plan(E2E)·codex 리뷰를 머신 전체 직렬로 돌려 그린라이트(머지 판정 ✅)를 찍고 closeout 에 인계하는 검증 루프. /loop 와 함께 (예 /loop 10m /verify-runner). 매 틱 Reconcile → Pick(1) → Verify → Classify → (후보 남으면 Drain 반복) → Report. 머지는 절대 하지 않는다.
---

# verify-runner — 검증 레인 틱

당신은 무인 검증 워커다. issue-runner 와 closeout **사이**에서, 워커가 구현·결정적
CID·PR 까지 마치고 `flow:verify` 로 넘긴 PR 을 받아 **느린 외부툴 검증(E2E test:system
+ codex 리뷰)을 한 번에 하나씩 직렬로** 돌린다. 통과하면 `머지 판정: ✅`+`flow:ready`
로 closeout 에 넘기고, 실패하면 issue-runner 로 재디스패치한다. **머지는 절대 하지
않는다**(closeout 독점).

**존재 이유.** 예전에는 이 검증을 issue-runner 가 디스패치한 **타임박스된 일회성
워커** 안에서 인라인으로 시켰다. E2E 는 헤드리스 크롬 10개를 띄우고 codex 는 외부
CLI 라 느린데, 워커가 그 느린 일을 끝내기 전 죽거나 시간초과되면 PR 이 드롭됐다
(동시 5워커면 5배로 샜다). 검증을 **버리지 않고 매 틱 재집는 전용 루프**가 소유하면
드롭이 원천 불가하고, 직렬(MAX_VERIFY=1)이라 크롬 부하 피크가 한 세트로 고정돼 박스가
안 터진다. 이것이 issue-runner(생산)→verify-runner(검증)→closeout(마감) 3루프 분리다.

## 상수

- `MAX_VERIFY = 1` — **동시성 1**(한 번에 1 PR 만 끝까지 직렬 검증). 틱당 상한이
  아니다 — 한 PR 이 종료 상태(passed·redispatched·held·flake_retry)에 닿으면 **다음
  틱을 기다리지 말고** ①② 로 되돌아 다음 후보를 이어간다(아래 ⑤ Drain). 이 노브가
  E2E 크롬 부하 상한이다 — 절대 올리지 마라(동시 실행 = 크롬 자기포화 = 타임아웃).
- `VERIFY_ATTEMPTS_LIMIT = 3` — 같은 PR 검증이 N회 실패(재디스패치)하면 그 다음엔
  재디스패치 대신 `needs-human` 으로 승격한다(무한 반송 서킷 브레이커). 카운트는 PR
  본문 `<!-- verify-attempt: N -->` 주석에 누적(issue-runner repair-count 동형).
- `STALE_FINISH_MIN = 30` — `finish-classify.sh` 시간버퍼(분). 재사용.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — diff correctness 검증자 서브에이전트 타입.
  **출력 계약 (SSOT)**: read-only(코드 변경 금지)·발견마다 BLOCKER/WARN/NIT 분류·
  발견 없으면 'CLEAN'·BLOCKER 는 게이트(미해결 시 통과 판정 금지). 검증자는 이
  SKILL.md 를 안 읽으므로 호출 프롬프트(`references/verify-prompt.md`)에 계약이
  담겨 있다. **폴백**: (a) codex 미설치(Agent 툴 subagent_type 목록에 없거나 unknown
  타입 오류) 또는 (b) codex stall/실패로 verdict 미산출이면 `general-purpose` 로 같은
  프롬프트 재시도. 폴백도 verdict 를 못 내면 BLOCKER 로 간주(fail-closed).
- `VERIFIER_TIMEOUT_MIN = 10` — `VERIFIER`(및 폴백) 스폰 1회당 벽시계 상한(분). 스폰
  시각 + 이 값을 데드라인으로 폴링하고, 데드라인을 넘기면 `TaskStop` 으로 끊어 verdict
  미산출로 간주한다 — codex 외부 CLI 스톨이 틱을 무한정 묶는 것을 막는 방어선(#96).
- 절대 금지: PR 머지(closeout 독점) · main/release 직접 push · `harvesting` PR 접촉
  (closeout 소유) · issue-runner 워크트리/브랜치를 검증 목적 밖으로 조작 · `flow:verify`
  가 아닌 PR 에 손대기. **허용**: 검증 대상 PR 의 `flow:*` 라벨 교체(flow:verify→
  flow:ready), 재디스패치 시 연결 이슈 `agent-ready` 재부착·`agent:claimed` 제거
  (검증 실패 반송 — worker-template 이 이 반송을 받아 고친다).

## ① Reconcile

`$SCRIPTS/verify-eligible.sh` 를 실행한다(세션 cwd 의 `.loop/repos` 스코프를 자동
적용). 출력은 `flow:verify` + `agent/issue-*` + `¬harvesting` PR 을 FIFO(오래된 순)로,
각 줄 `{repo,pr,issue,head,ci}` (ci=pass|revalidate|fail). 이게 이 루프의 큐다.

- **드롭 회수는 구조로 자동**이다: 이번 틱에 못 끝낸 PR 은 `flow:verify` 라벨이
  남아 다음 틱 verify-eligible 에 다시 잡힌다. 별도 스윕이 필요 없다(closeout ①-b 가
  하던 완결 유실 회수 중 **검증 단계** 몫을 이 재집이 흡수).
- 이 스캔은 `gh api` 조회뿐이라 비용 0 — 조용한 틱에도 매 틱 돈다.

## ② Pick — 한 번에 1 PR (MAX_VERIFY=1)

verify-eligible 출력의 **첫 후보 1개만** 집는다(FIFO·직렬). `flow:verify` 자체가
소유 플래그라(issue-runner·closeout 이 이 라벨 PR 을 안 건드림) 별도 점유 선언은
불필요하다 — 단일 루프·동시성 1 이라 레이스가 없다. 후보가 0이면 ③ 을 건너뛰고
④ Report 에 clean no-op.

## ③ Verify — 집은 PR 을 검증한다

**0. CI 상태 분기 (verify-eligible 의 `ci` 필드).**
- `fail` → 결정적 CI 가 실패다(코드 회귀). 검증하지 말고 **④ 재디스패치**(코드 반송)
  로 바로 간다 — 사유 = `결정적 CI 실패`.
- `revalidate` → rebase 등으로 현재 HEAD 의 로컬 CI 캐시가 비었다. worktree 를 PR
  head 로 동기화하고(아래 1단계 worktree 확보에 이어) `$SCRIPTS/run-local-ci.sh
  <repo> <issue>` 로 캐시를 채운다. 비0(통합 깨짐)이면 ④ 재디스패치(`결정적 CI 실패
  — rebase 통합`). 0이면 E2E 로 진행.
- `pass` → 바로 E2E 로.

**1. worktree 확보·동기화.** `$SCRIPTS/make-worktree.sh <repo> <issue>` 로 worktree
경로를 얻고(마지막 줄), **PR 의 현재 head 로 강제 동기화**한다(기존 worktree 는 옛 SHA
일 수 있다 — closeout revalidate 경로와 동일 함정):
`git -C <wt> fetch origin` → `git -C <wt> reset --hard origin/<head>`(`<head>`=verify-eligible
의 head, 예 `agent/issue-<issue>`). `<issue>` 가 빈 문자열이면(연결 이슈 없음) PR head
`agent/issue-N` 에서 N 을 파싱해 쓴다.

**2. E2E (test:system).** 레포가 시스템 테스트를 가지면(예 Rails: `test/system/`) worktree
에서 실행한다. Rails 기준:
`cd <wt> && bin/rails tailwindcss:build 2>/dev/null; bin/rails test:system`
(에셋 미빌드면 레이아웃 렌더가 깨져 전건 error — tailwind 선빌드 필수. 레포가
tailwind 아니면 이 줄 생략.) 시스템 테스트 디렉토리가 없으면 이 단계는 **skip**하고
E2E=pass 로 간주(코멘트에 `E2E: 해당 없음` 명시).
- **실패 시 플레이크 판별 (자기포화 방어, #981).** `test:system` 스위트는 10코어에
  크롬 10개 병렬이라 한적한 박스에서도 스위트 자기포화로 저장-계열 어서션이 런당
  ~1개 깜빡인다(단독 실행은 통과). 그래서 스위트 실패 시 **곧바로 진짜 실패로
  판정하지 말고**: 실패한 테스트 **파일만 단독 재실행**한다(`bin/rails test
  <실패파일>`). ⓐ 단독 통과 → 자기포화 플레이크로 간주하고 스위트를 **1회 재실행**;
  재실행도 (다른 테스트에서) 실패하면 같은 파일-단독 확인을 반복하되, **스위트를
  최대 3회**까지만 돌린다(무한 금지). 3회 내 모든 실패가 매번 단독-통과면 E2E=pass
  (플레이크 소진)로 코멘트에 `E2E: pass (자기포화 플레이크 n건 단독 재확인)` 명시.
  ⓑ 단독도 실패 → **진짜 E2E 실패** → ④ 재디스패치(`E2E 실패: <파일::테스트>`).
  직렬 레인이라 이 느린 재확인을 감당한다(예전 per-test 재시도 하네스가 게이트에서
  하던 일을 여기서 루프 수준으로, 부하 없이).

**3. codex correctness 리뷰.** 검증자가 sandbox 에서 네트워크에 못 닿아도 판정하도록
**메인 세션이 원문을 프롬프트에 동봉**한다. `gh pr diff <pr> --repo <repo>` 로 diff,
`gh issue view <issue> --repo <repo>` 로 이슈 본문(연결 이슈 없으면 빈 문자열),
`$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑 `.loop/lessons.md`(없거나 비면 `없음`)를
받아, `skills/verify-runner/references/verify-prompt.md` 의 placeholder(`<PR>`·`<REPO>`·
`<BASE>`=default branch·`<DIFF>`·`<ISSUE_BODY>`·`<LESSONS_OR_"없음">`)를 채워 `VERIFIER`
를 **`run_in_background: true` 로 스폰**한다(## 상수의 VERIFIER 계약·폴백 적용). 스폰
시각을 기록하고 TaskList/TaskOutput 으로(예: 30초 간격) 폴링한다 — 스폰 시각 +
`VERIFIER_TIMEOUT_MIN` 데드라인 안에 verdict 가 나오면 그대로 쓴다. **데드라인을
넘기면 `TaskStop` 으로 그 태스크를 중단**하고 verdict 미산출로 간주해 BLOCKER 로
취급한다(fail-closed — codex 스톨이 틱을 무한정 묶지 못하게, #96). 폴백(## 상수
VERIFIER 의 general-purpose 재시도)도 **동일한 배선**(새 스폰 시각 + 같은
`VERIFIER_TIMEOUT_MIN` 데드라인 + 초과 시 `TaskStop`)을 적용한다 — codex 스톨 후
폴백이 또 무한 스핀하지 못하게.
- 동봉 실패 fail-closed: `gh pr diff` 가 실패하거나 diff 가 비면, 또는 diff 가 검증자
  컨텍스트에 다 안 들어갈 만큼 크면(판단이 서면) 통과로 보지 말고 BLOCKER 로 취급한다.
- 검증자 BLOCKER(데드라인 초과 포함) → E2E 결과와 무관하게 **④ 재디스패치**
  (`codex BLOCKER: <요약>` 또는 타임아웃이면 `codex BLOCKER: 검증자 타임아웃
  (>VERIFIER_TIMEOUT_MIN분)`).
- 검증자 CLEAN/WARN → 통과. 결과를 PR 코멘트로 남긴다(closeout 2단계가 이 코멘트의
  BLOCKER 0 을 머지 게이트로 읽는다 — 마커·접두 정확히):
  `gh pr comment <pr> --repo <repo> --body "검증자 리뷰: <CLEAN 또는 'BLOCKER 0 / WARN n건'과 각 발견 요약>
<!-- bodat:worker -->"`

## ④ Classify — 판정과 인계

**passed** — E2E pass(또는 해당 없음) + codex BLOCKER 0:
1. (③-3 에서 `검증자 리뷰:` 코멘트 이미 남김)
2. 최종 그린라이트:
   `gh pr comment <pr> --repo <repo> --body "머지 판정: ✅ 머지 가능 — 결정적 CI pass · E2E <pass 또는 '해당 없음'> · 검증자 <CLEAN 또는 'BLOCKER 0 / WARN n'> · 미해결 없음
<!-- bodat:worker -->"`
3. 라벨 인계: `gh issue edit <pr> --repo <repo> --add-label flow:ready --remove-label flow:verify`
   → closeout `closeout-eligible.sh` 가 `머지 판정: ✅` 로 이 PR 을 집어 마감한다
   (**closeout 계약 무변경** — 기존 ✅ 마커 재사용). **success 종료.**

**redispatched** — E2E 진짜 실패 / codex BLOCKER(검증자 데드라인 초과 포함) / 결정적 CI 실패:
1. `<!-- verify-attempt: N -->` 를 PR 본문에서 읽어(없으면 0) N+1 이 `VERIFY_ATTEMPTS_LIMIT`
   **미만**이면 재디스패치, **이상**이면 아래 held 로.
2. 재디스패치: 실패 사유 코멘트(멱등 마커) —
   `gh pr comment <pr> --repo <repo> --body "재검증 실패: #<issue> — <사유> (attempt N+1)
<!-- bodat:worker -->"`.
   **이 마커가 이미 있고 그 이후 새 커밋·검증자 코멘트가 없으면 재발행하지 않는다**
   (/loop 스팸 방지). PR 본문 주석을 `<!-- verify-attempt: N+1 -->` 로 갱신
   (`gh pr edit <pr> --repo <repo> --body ...` — 나머지 본문 보존).
3. 라벨·반송: `gh issue edit <pr> --repo <repo> --remove-label flow:verify` +
   연결 이슈에 `gh issue edit <issue> --repo <repo> --add-label agent-ready --remove-label agent:claimed`.
   → issue-runner Dispatch 가 기존 `agent/issue-<issue>` worktree/브랜치를 재사용해
   같은 PR 브랜치에서 워커를 다시 붙인다(새 PR 안 생김). 워커는 위 `재검증 실패:`
   코멘트를 읽고 고친 뒤 다시 `flow:verify` 로 넘긴다(worker-template 절차). **redispatched 종료.**
   (연결 이슈가 없으면 재디스패치 불가 → held 로 폴백.)

**held** — 재디스패치 상한 초과(VERIFY_ATTEMPTS_LIMIT) 또는 연결 이슈 부재:
`gh pr comment <pr> --repo <repo> --body "검증 보류: <사유> — 사람 확인 필요
<!-- bodat:worker -->"` + `gh issue edit <pr> --repo <repo> --remove-label flow:verify` +
(연결 이슈 있으면) `gh issue edit <issue> --repo <repo> --add-label needs-human`. **held 종료.**

**flake_retry** — 검증을 아예 못 돌린 일시 장애(worktree fetch 실패·make-worktree 오류
등, 판정 아님): `flow:verify` 를 **그대로 두고** ④ Report 에 warn 으로 올린다 → 다음
틱이 재집는다(드롭 없음). 판정(pass/fail)이 선 경우엔 이 상태로 빠지지 마라.

## ⑤ Drain — 다음 후보로 즉시 이어가기

③④ 가 집은 PR 을 종료 상태(passed·redispatched·held·flake_retry)에 닿게 한 **직후**,
결과를 ④ Report 용으로 누적하고 **다음 틱을 기다리지 말고 ①② 로 되돌아간다**:
- ② Pick 이 **새 후보를 집으면**(이번 PR 은 passed→flow:ready 로, redispatched/held→
  flow:verify 제거로 이미 큐에서 빠졌다. flake_retry 만 flow:verify 가 남는데 —
  같은 PR 재선정 방지 위해 이 틱 드레인에서는 **이번 틱에 이미 처리한 PR 번호를
  건너뛴다**) 그 PR 로 ③ 을 이어간다.
- ② Pick 후보가 **0이면**(또는 남은 게 이번 틱 처리분뿐이면) 드레인을 멈추고 ④ Report.

무한루프 방지: 각 반복은 큐를 최소 1 줄인다(passed→flow:ready 소멸·redispatched/held→
flow:verify 소멸). 같은 PR 이 두 번 집히면(flake_retry 반복 등) 그 PR 을 skip 하고
④ Report 에 `BLOCKED: 재선정 루프 — #<pr>` 로 보고해 드레인을 끊는다. 한 틱 드레인은
최대 verify-eligible 스냅샷 길이만큼만 돈다.

## ④ Report

드레인이 끝나면 이 틱 처리분을 합산해 한 줄: `검증통과 N · 재디스패치 N · 보류 N · 재시도 N · warn N`.
warn(flake_retry·동봉 실패 등)이 있으면 경로·사유를 아래 나열. 모든 카운트 0이면
"조용함" 한 줄. 조용해도 ①② 는 다음 틱에도 그대로 수행한다(새 flow:verify PR 을 놓치지 않게).

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 역할 분담: issue-runner = 생산(구현+결정적CI+PR, `flow:verify` 로 넘김·검증 안 함),
  verify-runner = 검증(E2E+codex 직렬, `머지 판정: ✅` 로 넘김·머지 안 함), closeout =
  마감(머지 독점). 세 루프는 라벨 소유로 충돌을 막는다 — `flow:verify`=verify-runner,
  `harvesting`=closeout. issue-runner 는 둘 다 안 건드리고 in-flight 로도 안 센다.
- 컷오버 불변식: verify-runner 가 살아있어야(이 루프가 돌아야) 워커의 `flow:verify`
  PR 이 검증돼 `머지 판정: ✅` 로 흐른다. 이 루프가 죽으면 flow:verify PR 이 검증 없이
  적체하지만(closeout 이 안 집음·issue-runner 도 안 집음) **드롭·오분류는 없다** —
  라벨이 남아 루프 재기동 시 그대로 재집힌다.
- 운용: issue-runner·closeout 와 별도의 `/loop` 세션(예 `/loop 10m /verify-runner`).
- 의존: 결정적 헬퍼는 `$SCRIPTS`(=`~/.claude/skills/issue-runner/scripts`)의
  `verify-eligible.sh`·`closeout-ci-pass.sh`·`run-local-ci.sh`·`make-worktree.sh`·
  `repo-dir.sh`, 검증자 프롬프트는 `skills/verify-runner/references/verify-prompt.md`.
