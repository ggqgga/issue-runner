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

> **소유권·정지·전이 실패 규칙의 SSOT 는 `references/state-machine.md` 다**(#393). 어느 상태를 어느 루프가 들고
> 있고(소유 라벨 `flow:verify`·`verifying`·`flow:ready`·`harvesting`), 기계 정지(`hold:*`)와 사람 정지(`needs-human`)가
> 어떻게 풀리며, `transition.sh` 가 exit 1·2 로 끝난 반쯤 이동 상태를 누가 회수하는지는 그 표를 본다 — 아래 산문에
> 같은 규칙이 남아 있으면 표가 이긴다(산문 정리는 플랜 3단계).

## 상수

- `MAX_VERIFY = 1` — **동시성 1**(한 번에 1 PR 만 끝까지 직렬 검증). 틱당 상한이
  아니다 — 한 PR 이 종료 상태(passed·redispatched·held·flake_retry)에 닿으면 **다음
  틱을 기다리지 말고** ①② 로 되돌아 다음 후보를 이어간다(아래 ⑤ Drain). 이 노브가
  E2E 크롬 부하 상한이다 — 절대 올리지 마라(동시 실행 = 크롬 자기포화 = 타임아웃).
- `CODEX_REVIEW_LIMIT = 2` — **같은 PR 에 codex 를 부르는 횟수 상한**(사용자 결정 2026-09-13,
  #375 · Plans/review-round-cap-and-gate-signals.md). 카운트는 PR 본문 `<!-- verify-attempt: N -->`
  주석(N = 지금까지의 codex BLOCKER 반송 수, issue-runner repair-count 동형). N < 2 면 ③-3 이
  codex 를 부르고, **N = 2 면 codex 없이 ③-3′ 자체 리뷰로 판정해 완료**한다 — 리뷰어(codex)는
  같은 diff 에 회차마다 다른 답을 내므로(같은 head 세 번 → P1 → P2 → CLEAN 실측) 세 번째부터는
  게이트가 아니라 발산이다. 옛 상한(3회 초과 → `hold:policy`)은 폐기 —
  **리뷰 반송은 사람 결정 사유가 아니다.** 사람 호출(`needs-human`)은 여전히 재심이 "사람 몫
  유지" 로 끝났을 때만 붙는다(#244 — issue-runner ① 의 `policy-kept` 가 유일한 생산자다).
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
- `AUX_REVIEWERS = pr-review-toolkit:silent-failure-hunter, pr-review-toolkit:pr-test-analyzer`
  — **보조 리뷰어**(비게이트). Codex 와 같은 동봉 diff 를 받아 조용한 실패(삼킨 예외·근거 없는
  폴백)와 테스트 갭을 찾는다. 판정에 **들어가지 않는다**(BLOCKER 는 `VERIFIER` 만) — Codex 와
  겹치는지 대조 기록을 쌓는 단계이고 게이트 승격은 사람이 정한다(사용자 결정 2026-09-05).
  타입이 없으면(플러그인 미설치) 건너뛰고 코멘트에 `보조 리뷰: 미설치` 를 적는다. 데드라인은
  `VERIFIER_TIMEOUT_MIN` 과 같다 — 넘기면 `TaskStop` 하고 `보조 리뷰: 타임아웃` 으로 적는다.
- 절대 금지: PR 머지(closeout 독점) · main/release 직접 push · `harvesting` PR 접촉
  (closeout 소유) · issue-runner 워크트리/브랜치를 검증 목적 밖으로 조작 · `flow:verify`·
  `verifying` 가 아닌 PR 에 손대기. **허용**: 검증 대상 PR 의 `flow:*`·`verifying` 라벨
  이동(전부 `transition.sh` 전이로 — verify-pick: flow:verify→verifying · verify-pass:
  verifying→flow:ready · verify-unpick: verifying→flow:verify), 재디스패치 시 연결 이슈
  `agent-ready` 재부착·`agent:claimed` 제거(검증 실패 반송 — worker-template 이 이 반송을
  받아 고친다), 아래 **표면 교정 직접 수정**.
- `verifying`(#275) = **이 루프의 점유 라벨**(closeout 의 `harvesting` 과 같은 자리 — PR 과
  연결 이슈 양쪽). ② Pick 이 집는 순간 `flow:verify` 를 이것으로 바꾸고, ④ 의 모든 종료
  상태가 뗀다(passed·redispatched·held 는 출구 전이가, flake_retry 는 `verify-unpick` 이).
  그래서 "`verifying` = 지금 이 순간 검증이 돌고 있다" 가 항상 참이고, 재시도 대기는
  검증대기(`flow:verify`)다. 이슈 사다리: `agent:claimed` → `flow:verify` → `verifying` →
  `flow:ready` → `harvesting`.

## ⓪ 표면 교정 직접 수정 (WARN/NIT 중 표면만)

검증에서 **주석·문서 문자열이 사실과 다르다**고 실측된 건은 반송하지 말고 이 루프가
**직접 고친다**. 반송 한 바퀴(이슈→디스패치→구현→검증→마감)를 한 줄 고치자고 돌리는 게
낭비이고, 이 레포에선 틀린 주석이 실제 결함의 진원이기 때문이다(오서술 하나 고치려고 PR
하나가 따로 돈 전례가 있다).

**판정 기준 한 줄: 이 변경으로 통과/실패가 바뀌는 테스트가 하나도 없는가.**
없으면 여기서 고치고, 하나라도 있으면 이슈 발행(또는 재디스패치) 대상이다.
이 기준이 받는 것 — 주석 문장, 용어·표기 통일, 주석 안의 수치·좌표, 죽은 참조 제거,
**테스트 이름**(`test "…"` 의 설명 문자열은 실행되지만 통과/실패를 안 바꾼다),
**이 PR 이 도입한 가드·테스트의 토큰 보강·앵커 동기·이름 정정**(무는 동작이 그대로인 것, #411).
이 기준이 막는 것 — 다른 동작을 새로 무는 단언·가드, 커버리지 추가·상수값·실행 분기.
"주석만 고치는 김에 단언 하나" 는 이슈다.

기준을 "주석·문서 문자열"이 아니라 **테스트 결과 불변**으로 잡는 이유: 앞 기준은
테스트 이름·죽은 참조처럼 명백히 표면인 것을 코드로 분류해 이슈로 새게 했다(실측:
`테스트 이름 정리` 가 단독 이슈로 한 바퀴 돌았다). closeout 3단계 "표면 교정 흡수"와
**같은 한 줄**을 쓴다 — 두 루프가 다른 경계를 쓰면 같은 발견이 어느 루프에 걸리느냐로
갈린다.

절차 (통과 판정 PR 한정 — 재디스패치·보류 건은 손대지 않는다):
1. 대상 worktree 에서 주석만 수정 → `git commit` → PR head 브랜치로 push.
2. **재게이트**: 새 SHA 로 `$SCRIPTS/run-local-ci.sh <repo> <issue>` 를 돌려 캐시를
   채운다(커밋을 얹으면 로컬 CI 캐시가 SHA 기준이라 `ci=revalidate` 가 되고, 안 채우면
   closeout 이 막힌다). 비0이면 그 커밋을 되돌리고 WARN 으로만 보고하라(exit 2 는 CI 실패가
   아니라 폐기 — 실행 직전 worktree HEAD 가 움직인 것, 현재 HEAD 로 재호출).
3. **공개**: `검증자 리뷰:` 코멘트에 `verify-runner 직접 수정: <파일> — <무엇을>` 을
   명시한다. 자기가 고친 것을 자기가 그린라이트하는 구조라, 그 사실이 closeout·사람에게
   보여야 한다.
4. E2E 는 재실행하지 않는다(주석은 실행되지 않는다 — 결정적 CI 재통과로 충분).

## ① Reconcile

`$SCRIPTS/verify-eligible.sh` 를 실행한다(세션 cwd 의 `.loop/repos` 스코프를 자동
적용). 출력은 (`verifying` 또는 `flow:verify`) + `agent/issue-*` + `¬full-cycle`(#246) + `¬harvesting` PR 을
**`verifying` 먼저, 그 다음 `flow:verify` FIFO(오래된 순)** 로, 각 줄
`{repo,pr,issue,head,ci,orphan}` (ci=pass|revalidate|fail · orphan=true|false). 이게 이 루프의 큐다.

- **드롭 회수는 구조로 자동**이다 — 두 갈래:
  - `flow:verify`(검증대기) 는 아직 안 집은 것이거나 flake_retry 가 `verify-unpick` 으로
    되돌린 것 — 다음 틱 verify-eligible 에 FIFO 로 다시 잡힌다.
  - `verifying`(점유) 이 틱 시작에 남아 있으면 **무조건 이전 틱이 죽은 것**이다(이 루프는
    단일·직렬이고 모든 정상 종료가 이 라벨을 뗀다). verify-eligible 이 그걸 **먼저**
    내보내 그대로 다시 집되(재개), 그 줄의 `orphan:true` 를 읽어 ④ Report 에
    `고아 재집 #<pr>` 한 줄을 남긴다(사망 증거 — 다음 사람이 왜 두 번 돌았는지 안다).
  별도 스윕이 필요 없다(closeout ①-b 가 하던 완결 유실 회수 중 **검증 단계** 몫을 이
  재집이 흡수).
- 이 스캔은 `gh api` 조회뿐이라 비용 0 — 조용한 틱에도 매 틱 돈다.

## ② Pick — 한 번에 1 PR (MAX_VERIFY=1)

verify-eligible 출력의 **첫 후보 1개만** 집는다(고아 우선·그 뒤 FIFO·직렬). 집은 **직후**
점유를 선언한다(closeout ② 의 `closeout-pick` 과 같은 꼴):
`$SCRIPTS/transition.sh verify-pick <repo> <issue|-> <pr>` — PR 과 연결 이슈 양쪽에서
`flow:verify` 를 떼고 `verifying` 을 붙인다(멱등 — 고아 재집은 이미 `verifying` 이라
no-op 로 통과한다). 이 라벨이 루프 현황(`loop-status.sh`)에서 "검증대기" 와 "검증 중
(수십 분)" 을 가르는 근거가 된다(대시보드 렌더는 후속 이슈 — 현행 대시보드는 아직 이
라벨을 모른다). 단일 루프·동시성 1 이라 레이스는 없다 — 점유 라벨은 경합 방지가 아니라
**가시성과 사망 증거**(① 의 고아 판정) 용이다.
- **exit 1(readback 불일치)·2(gh 실패)면 이 PR 을 집지 마라** — ④ Report 에
  `BLOCKED: 전이 실패 verify-pick PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올리고
  다음 후보로 간다(라벨이 반쯤 이동한 상태를 다음 틱이 잡게 — ① 이 `verifying` 이든
  `flow:verify` 든 다시 낸다).
후보가 0이면 ③ 을 건너뛰고 ④ Report 에 clean no-op.

## ③ Verify — 집은 PR 을 검증한다

**0. CI 상태 분기 (verify-eligible 의 `ci` 필드).**
- `fail` → 결정적 CI 가 실패다. **단, 코드 회귀인지 먼저 확인한다** — 아래 `fail` 원인
  분류를 거쳐 코드 회귀면 검증하지 말고 **④ 재디스패치**(코드 반송), 사유 = `결정적 CI
  실패`. 인프라 자가체크면 재디스패치하지 말고 **flake_retry**(`verify-unpick` 으로 `flow:verify` 복귀 → 다음 틱 FIFO 재집 — ④ 와 같은 전이).
- `revalidate` → rebase 등으로 현재 HEAD 의 로컬 CI 캐시가 비었다. worktree 를 PR
  head 로 동기화하고(아래 1단계 worktree 확보에 이어) `$SCRIPTS/run-local-ci.sh
  <repo> <issue>` 로 캐시를 채운다. 비0(통합 깨짐)이면 ④ 재디스패치(`결정적 CI 실패
  — rebase 통합`); 단 exit 2 는 폐기(HEAD 이동)라 현재 HEAD 로 한 번 재호출. 0이면 E2E 로 진행.
- `pass` → 바로 E2E 로.

**`fail` 원인 분류 — 코드 회귀 vs 인프라 자가체크.** `fail` 을 본 즉시 캐시 로그
(`~/.claude/.local-ci/<slug>/<sha>.log`, slug=`repo-dir.sh` 경로의 `/`·공백→`_`)를
읽어 **어느 step 이 죽었는지** 확인한다. 판별 기준은 한 가지다 — **그 실패가 PR diff
와 인과로 닿는가.** 닿지 않는 실패는 반송해도 워커가 고칠 수 없어 반송 자체가 낭비다
(무한 반송 → 이슈만 오염).

인과로 안 닿는 대표 부류(**재디스패치 금지**):
- **툴 자가체크** — 툴이 "내 버전이 최신인가"를 자기 자신에게 묻고 실패하는 것.
  전례: brakeman `--ensure-latest` 는 상류가 패치 릴리스를 내는 순간 **스캔을 시작도
  안 하고** exit 5 로 죽어(출력이 버전 한 줄뿐, 경고 리포트 없음) 코드와 무관하게
  전 브랜치를 동시에 빨갛게 만들었다. PR 7건이 12틱 묶였고 재실행은 영원히 무의미했다
  (`bin/brakeman` 에서 그 플래그를 제거해 해소 — #2768).
- **환경·네트워크** — 젬/npm advisory DB fetch 실패, 레지스트리 타임아웃, 디스크·포트.
- **base 자체가 빨강** — 같은 실패가 `origin/<base>` 에서도 재현되면 PR 무죄다
  (`git -C <wt> checkout origin/<base>` 후 그 step 만 단독 재현).

**전 브랜치 동시 빨강은 이 부류의 지문이다.** 이번 틱 verify-eligible 이 전부 `fail`
이고 실패 step·메시지가 같으면 코드 회귀가 아니다 — 그 PR 들이 서로 다른 파일을 건드리는데
같은 지점에서 죽을 확률은 없다.

처리: 사유를 **한 번만** PR 코멘트로 남기고(같은 마커가 이미 있으면 재발행 금지 —
/loop 스팸 방지) flake_retry 로 ④ Report 에 올린다(④ 의 flake_retry 가 `verify-unpick`
으로 `verifying` 을 떼고 `flow:verify` 로 되돌린다). 해소가 이 루프 권한 밖이면(젬
범프·툴 설정 변경 등) 그 사실과 해소 방법을 사람이 읽을 코멘트에 명시하라 — `flow:verify`
가 남아 있으므로 해소 즉시 다음 틱이 자동으로 재집는다.

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
- **`해당 없음` 은 "스위트가 없다" 일 때만이다.** PR 이 실장비·라이브 동작을 건드려
  스위트로 덮이지 않는 항목이 있으면 `해당 없음` 으로 뭉개지 말고
  `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  의 칸 ②③ 을 시도한 뒤 그 결과(시도한 칸·명령·실패 출력 마지막 20줄)를 코멘트에
  인용한다.
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

**3. codex correctness 리뷰 — 내장 리뷰어. 먼저 `<!-- verify-attempt: N -->` 을 읽는다(없으면 0).**
**N ≥ `CODEX_REVIEW_LIMIT`(=2) 면 이 절을 건너뛰고 아래 3′ 로 간다 — codex 를 부르지 않는다.**
N < 2 면 `$SCRIPTS/codex-review-gate.sh --base origin/<default>
--cd <worktree> --out <스크래치>` 를 **동기 호출**한다(#134, Plans/codex-native-review-gate.md). 이 헬퍼가
`codex exec review` 를 sol/medium 으로 돌려 stdout 마지막 줄에 `verdict=<BLOCKER|WARN|NIT|CLEAN|NONE> p1= p2= p3= model= secs=`
를 내고 본문을 `<out>/review.md` 에 남긴다. 자체 타임아웃(`CODEX_GATE_TIMEOUT`, 기본 900s = `VERIFIER_TIMEOUT_MIN`
과 동조)이 있어 스폰·폴링·`TaskStop` 배선이 필요 없다 — 서브에이전트 없이 명령 하나. `[P0]`·`[P1]` 이 BLOCKER, `[P2]` 가 WARN, `[P3+]` 가 NIT(비차단).
- **exit 2(`verdict=NONE`) = 리뷰 미산출**(codex 부재·모델 오류·타임아웃·본문 없음). 그때만 ## 상수의 `VERIFIER`
  폴백(general-purpose, `references/verify-prompt.md` 에 `gh pr diff`·이슈 본문·`.loop/lessons-verifier.md` 동봉,
  `run_in_background` + `VERIFIER_TIMEOUT_MIN` 데드라인 + 초과 시 `TaskStop`)을 쓴다. 헬퍼의 stderr 가 모델 오류(404·
  not supported·requires a newer version)를 원문으로 보여주니 "스톨"로 오진하지 말고 그대로 코멘트에 남긴다.
- **lessons 파일**은 폴백 프롬프트에만 주입한다(`.loop/lessons-verifier.md` → 없으면 `.loop/lessons.md` → `없음`).
  내장 리뷰어는 레포의 `AGENTS.md`·`.codex/` 를 읽으므로 반복 오판 패턴은 거기(`## Code Review Rules`)에 적는 게 맞다.
- 동봉·diff 크기 fail-closed 는 헬퍼가 대신한다 — base 를 못 풀거나 diff 가 비면 `NONE`.
- 검증자 BLOCKER(데드라인 초과 포함) → E2E 결과와 무관하게 **④ 재디스패치**
  (`codex BLOCKER: <review.md 의 P1 제목들>` 또는 미산출이면 `codex BLOCKER: 검증자 미산출
  (<헬퍼 stderr 사유 — 타임아웃 >VERIFIER_TIMEOUT_MIN분 / 모델 오류 원문>)`).
- 검증자 CLEAN/NIT/WARN → 통과(`[P3+]` = NIT 는 비차단). 결과를 PR 코멘트로 남긴다(closeout 2단계가 이 코멘트의
  BLOCKER 0 을 머지 게이트로 읽는다 — 마커·접두 정확히):
  `gh pr comment <pr> --repo <repo> --body "검증자 리뷰: <CLEAN 또는 'BLOCKER 0 / WARN n건'> · <model>/<secs>s
<review.md 본문>
<!-- bodat:worker -->"`

**3′. 3회차 자체 리뷰 — codex 없이 (N = 2).** codex 는 이 PR 에 이미 두 번 답했고 워커가 두 번 고쳤다.
세 번째 판정은 `general-purpose` 서브에이전트(read-only)가 낸다 — 입력은 **직전 `재검증 실패:` 코멘트**
(2회차 codex 의 P1 제목들)와 `git diff origin/<default>...HEAD`, 출력은 **지적별 `해소`/`미해소` + 한 줄 근거**.
이 리뷰는 게이트가 아니다 — E2E(③-2)·결정적 CI(③-1)만 게이트다. 결과를 PR 코멘트로 남긴다 —
**closeout 2단계 머지 게이트가 읽는 형식 그대로**(`검증자 리뷰:` 접두 + `BLOCKER 0`; 미해소는 WARN 으로 센다):
`gh pr comment <pr> --repo <repo> --body "검증자 리뷰: BLOCKER 0 / WARN <m> · 자체 리뷰(codex 2회 소진 · 3회차) · 해소 <n> / 미해소 <m>
<지적별 해소/미해소 + 근거>
<!-- bodat:worker -->"`
미해소가 남아도 ④ **passed** 로 간다. 남은 지적은 **PR 본문에 `follow-up:` 줄로 적는다**(한 지적 한 줄,
`follow-up: <지적 제목> — 3회차 자체 리뷰 미해소`, `gh pr edit --body` 로 본문 끝에 추가) — closeout 6단계는
PR 본문의 `follow-up:` 항목만 파생 이슈 입력으로 읽으므로 이 줄이 없으면 지적이 조용히 버려진다.

**3-b. 보조 리뷰 (`AUX_REVIEWERS`, 비게이트).** ③-3 의 Codex 스폰과 **같은 시점**에, 같은 동봉
diff·이슈 본문으로 `AUX_REVIEWERS` 두 타입을 각각 `run_in_background: true` 로 스폰한다(직렬 레인의
벽시계를 늘리지 않게 Codex 와 병렬). 프롬프트 계약은 `references/verify-prompt.md` 와 같은 뼈대
— 동봉 텍스트만 근거·gh/git 실행 금지·read-only·한국어 — 에 역할만 바꾼다: silent-failure-hunter
는 "이 diff 가 예외를 삼키거나·조용히 폴백하거나·실패를 로그 없이 넘기는 지점", pr-test-analyzer
는 "이 diff 의 동작 중 테스트가 안 덮는 것" **과** "과잉인 테스트"(소스·문서 문구 단언·구조 되적기·지적
1건에 회귀 여럿 — 레포 CLAUDE.md 테스트 규율). 발견마다 한 줄(파일:줄 — 무엇). 발견 없으면 'CLEAN'.
결과는 판정에 쓰지 않고 ③-3 의 `검증자 리뷰:` 코멘트 **끝에** 덧붙인다:
`보조 리뷰(pr-review-toolkit): 조용한 실패 n건 · 테스트 갭 n건` + 발견 한 줄씩(CLEAN 이면 0건).
Codex 가 BLOCKER 로 재디스패치할 때도 이 줄은 붙인다 — 워커가 함께 읽고 고친다.

**3-c. 보안 경계 표식 (`claude-security` 는 사람 전용).** 동봉 diff 의 파일 목록이 대상 레포
CLAUDE.md "보안 경계 경로" 절과 겹치면 같은 코멘트에 한 줄을 더 붙인다:
`🔒 보안 경계 변경: <파일들> — 배포 전 사람 세션에서 /claude-security scan changes 권고`.
게이트 아님. `claude-security` 스킬은 `disable-model-invocation` 이라 이 루프가 대신 돌릴 수
없다 — deploy-* 스킬 2절이 이 표식을 읽어 사용자에게 제안한다. CLAUDE.md 에 그 절이 없는
레포는 표식을 생략한다.

## ④ Classify — 판정과 인계

**passed** — E2E pass(또는 해당 없음) + (codex BLOCKER 0 **또는** ③-3′ 자체 리뷰 완료):
1. (③-3 / 3′ 에서 `검증자 리뷰:` 코멘트 이미 남김)
2. **사람 코멘트 확인(✅ 를 찍기 전 필수, #379).** `$SCRIPTS/pr-comments.sh <repo> <pr>` 로
   코멘트 전량을 읽고 **그 자리에서 배열 길이(= 전체 코멘트 수)를 적어 둔다** — 다음
   단계 ✅ 본문의 `코멘트 스냅샷 <전체 코멘트 수>` 가 된다. 아래에서 세는 **사람 코멘트
   수와는 다른 수**다(전체 ≥ 사람): 사람 코멘트 수를 스냅샷 자리에 적으면, 그게 0 일 때
   경계가 0 으로 내려앉아 closeout-eligible 이 PR 의 무마커 코멘트를 **전부** 다시 센다
   (#379 가 없앤 바로 그 역방향). 이어서
   `<!-- bodat:worker -->` 마커도 없고 레거시 3접두(`머지 판정`·
   `검증자 리뷰`·`마감 검증`)로도 시작하지 않는 코멘트(=사람 코멘트)를 **전부** 훑는다 —
   검증 중(verifying 동안)에 달린 것도 포함한다. **이 확인이 다음 단계의 `미해결 없음`
   을 사실로 만드는 유일한 자리다**: closeout-eligible 은 최신 ✅ **이전**의 무마커
   코멘트를 "검증자가 이미 확인한 것"으로 치고 세지 않는다(#379) — 그 전제를 참으로
   만드는 게 바로 이 단계다. 그 중 답을 기다리는 것(질문·수정 요구·BLOCKER 지적)이
   하나라도 있으면 ✅ 를 찍지 말고 아래 **held** 경로로 간다: `검증 보류: <코멘트 번호
   인용> — 사람 확인 필요` + `--reason policy`. 결정·보고·인수 메모(예 "사용자 결정 —
   …", "리베이스 해소: …")는 답을 기다리는 것이 아니다 — 확인한 것으로 친다.
3. 최종 그린라이트:
   `gh pr comment <pr> --repo <repo> --body "머지 판정: ✅ 머지 가능 — 결정적 CI pass · E2E <pass 또는 '해당 없음'> · 검증자 <CLEAN 또는 'BLOCKER 0 / WARN n'> · <사람 코멘트 0건이면 '미해결 없음', 아니면 '사람 코멘트 N건 확인'> · 코멘트 스냅샷 <2번의 전체 코멘트 수>
<!-- bodat:worker -->"`
   (마커 문구 `머지 판정: ✅ 머지 가능` 과 마지막 줄 마커는 바꾸지 않는다 — closeout-eligible
   이 그 접두로 집는다.)
   3′ 경로면 검증자 칸을 `BLOCKER 0 / WARN <m> · 자체 리뷰(codex 2회 소진 · 3회차)` 로, 미해소가 있으면
   `미해결 없음` 대신 `잔여: <지적 제목들>` 로 쓴다(사람용 요약 — 기계 입력은 3′ 가 PR 본문에 적은 `follow-up:` 줄이다).
   ` · 코멘트 스냅샷 <수>` 는 **2번에서 코멘트를 읽은 시점**을 박아 두는 스냅샷 토큰이다(#384):
   읽기와 이 게시 사이(수 초)에 끼어든 사람 코멘트는 ✅ 보다 앞 인덱스에 앉아 "확인된 것"
   으로 새는데, closeout-eligible 이 그 수를 경계로 쓰면 그 구간을 다시 집어 경합 창이
   닫힌다. 그러니 이 수는 **2번에서 실제로 읽은 배열 길이**여야 한다 — 게시 직전에 다시
   세지 말고, 바로 앞 `사람 코멘트 N건 확인` 의 N(사람 코멘트 수)과 헷갈리지 마라.
4. 라벨 인계: `$SCRIPTS/transition.sh verify-pass <repo> <issue|-> <pr>` — PR 과 원 이슈를
   한 호출로 옮긴다(전이 표 SSOT = `transition.sh` 상단 주석). **closeout 계약 무변경**
   (기존 `머지 판정: ✅` 마커 재사용 — `closeout-eligible.sh` 가 그걸로 집는다) + 이슈
   리스트만 봐도 단계(검증→마감)가 보인다. **success 종료.**
   - **exit 1(readback 불일치)·2(gh 실패)면 이 PR 의 종료 상태를 바꾸지 마라** — ④ Report 에
     `BLOCKED: 전이 실패 verify-pass PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.
     라벨이 반쯤 이동한 상태를 다음 틱이 잡게 하는 게 목적이다(조용히 넘어가지 않는다).

**redispatched** — E2E 진짜 실패 / codex BLOCKER(검증자 데드라인 초과 포함) / 결정적 CI 실패:
1. `<!-- verify-attempt: N -->` 를 PR 본문에서 읽는다(없으면 0). **N 은 codex BLOCKER 반송 수만 센다.**
   codex BLOCKER 반송은 N+1 ≤ `CODEX_REVIEW_LIMIT` 에서만 일어난다(N = 2 면 ③-3′ 가 codex 를 부르지
   않았으니 codex BLOCKER 자체가 없다). E2E·결정적 CI 실패는 회차와 무관하게 반송한다 — 그건 게이트다 —
   **그리고 N 을 올리지 않는다**(카운터를 같이 올리면 E2E 실패 두 번에 codex 를 한 번도 못 받고 3′ 로 간다).
2. 재디스패치: 실패 사유 코멘트(멱등 마커) —
   codex BLOCKER 면 `$SCRIPTS/bounce-comment.sh reverify-fail <repo> <pr> <issue> <N+1> "<사유>"`,
   E2E·CI 실패면 같은 명령에 `<N>`(현재 값 그대로 — 마커의 attempt 번호는 codex 회차다).
   **N+1 = 2(마지막 codex 반송)면 `<사유>` 끝에 `최종 회차: 다음 검증은 codex 없이 자체 리뷰로
   완료된다` 를 붙인다** — 워커가 이 문구를 보면 9-b 사전 리뷰를 건너뛰지 않는다(worker-template).
   문구는 인자로만 간다(스크립트·마커 형식 무변경).
   (문구를 손으로 옮겨 적지 않는다 — 콜론·어순이 변형되면 `bounce-state.sh` 반송
   안전망이 놓친다, #212. 생성되는 본문은
   `재검증 실패: #<issue> — <사유> (attempt N+1)\n<!-- bodat:worker -->`).
   **이 마커가 이미 있고 그 이후 새 커밋·검증자 코멘트가 없으면 재발행하지 않는다**
   (/loop 스팸 방지). **codex BLOCKER 반송일 때만** PR 본문 주석을 `<!-- verify-attempt: N+1 -->` 로 갱신
   (`gh pr edit <pr> --repo <repo> --body ...` — 나머지 본문 보존).
3. 라벨·반송: `$SCRIPTS/transition.sh verify-redispatch <repo> <issue> <pr>` — PR 의
   `flow:verify` 를 떼고 원 이슈를 `agent-ready`(+`flow:verify`·`agent:claimed` 제거)로 되돌린다.
   **exit 1·2 면 종료 상태를 바꾸지 말고** ④ Report 에
   `BLOCKED: 전이 실패 verify-redispatch PR #<pr>(<repo_short>) — <stderr 한 줄>`.
   → issue-runner Dispatch 가 기존 `agent/issue-<issue>` worktree/브랜치를 재사용해
   같은 PR 브랜치에서 워커를 다시 붙인다(새 PR 안 생김). 워커는 위 `재검증 실패:`
   코멘트를 읽고 고친 뒤 다시 `flow:verify` 로 넘긴다(worker-template 절차). **redispatched 종료.**
   (연결 이슈가 없으면 재디스패치 불가 → held 로 폴백.)

**held** — 연결 이슈 부재 · 또는 E2E 가 실장비를 요구해 못 돈 경우(**리뷰 반송 상한은 더 이상
held 사유가 아니다** — N = 2 는 ③-3′ 가 완료로 흡수한다):
`gh pr comment <pr> --repo <repo> --body "검증 보류: <사유> — 사람 확인 필요
<!-- bodat:worker -->"` + `$SCRIPTS/transition.sh verify-held <repo> <issue|-> <pr> --reason <conflict|policy|ladder> [--note "<질문 한 줄>" — policy·conflict 필수]`
(PR 의 `flow:verify` 제거 + PR 과 — 있으면 — 연결 이슈 **양쪽**에 `hold:<reason>` 부착.
`needs-human` 은 **안 붙는다**(#244 — 기계 정지는 사유 라벨 하나뿐이고, 게이트는 `hold:`
접두를 직접 본다). 연결 이슈가 없어도 PR 에 정지 신호가 남는다). **held 종료.**
**`--reason` 은 필수다** — 빠지면 전이가 usage exit 64 로 거절한다(사유 없는
정지를 만들 수 없게 하는 게이트). 이 문단의 사유 배정:
- **연결 이슈 부재** → `policy`. 어느 이슈에 붙일지가 사람 결정이다.
- **E2E 가 실장비를 요구해 못 돈 경우** → 곧바로 held 로 가지 마라. 먼저
  `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  의 **칸 ②(`bin/dry-run`·AdsPower 릴레이)와
  칸 ③(미니 `ssh test '<cmd>'` 직결 · `test_claim`/`bin/dry-run` · 프로필 #18)** 을
  시도한다. 어느 칸에서든 판정이 서면 그 결과로 ④ Classify 를 진행하고(held 아님),
  **전부 실패했을 때만** `--reason ladder` 로 held 한다. 이때 위 `검증 보류:` 코멘트에
  **시도한 칸과 실패 출력(명령 한 줄 + 마지막 20줄)을 인용**한다 — 인용이 없으면
  `ladder` 가 아니라 `policy` 다.
**exit 1·2 면 종료 상태를 바꾸지 말고** ④ Report 에
`BLOCKED: 전이 실패 verify-held PR #<pr>(<repo_short>) — <stderr 한 줄>`.

**flake_retry** — 검증을 아예 못 돌린 일시 장애(worktree fetch 실패·make-worktree 오류·
E2E 인프라 흔들림 등, 판정 아님): 점유를 풀고 검증대기로 되돌린다 —
`$SCRIPTS/transition.sh verify-unpick <repo> <issue|-> <pr>` (verify-pick 의 정확한 역:
PR·이슈 양쪽 `verifying` 제거 + `flow:verify` 재부착, 멱등). 그러고 ④ Report 에 warn 으로
올린다 → 다음 틱이 `flow:verify` FIFO 로 재집는다(드롭 없음). **exit 1·2 면** ④ Report 에
`BLOCKED: 전이 실패 verify-unpick PR #<pr>(<repo_short>) — <stderr 한 줄>` — `verifying`
이 남아도 ① 이 고아로 먼저 재집으니 드롭은 아니고, 대신 `고아 재집` 이 "사망" 이 아니라
"unpick 실패" 였음을 이 줄이 말해 준다. 판정(pass/fail)이 선 경우엔 이 상태로 빠지지 마라.

## ⑤ Drain — 다음 후보로 즉시 이어가기

③④ 가 집은 PR 을 종료 상태(passed·redispatched·held·flake_retry)에 닿게 한 **직후**,
결과를 ④ Report 용으로 누적하고 **다음 틱을 기다리지 말고 ①② 로 되돌아간다**:
- ② Pick 이 **새 후보를 집으면**(이번 PR 은 passed→flow:ready 로, redispatched/held→
  `verifying` 제거로 이미 큐에서 빠졌다. flake_retry 만 flow:verify 가 남는데(unpick
  결과) — 같은 PR 재선정 방지 위해 이 틱 드레인에서는 **이번 틱에 이미 처리한 PR 번호를
  건너뛴다**) 그 PR 로 ③ 을 이어간다.
- ② Pick 후보가 **0이면**(또는 남은 게 이번 틱 처리분뿐이면) 드레인을 멈추고 ④ Report.

무한루프 방지: 각 반복은 큐를 최소 1 줄인다(passed→flow:ready 소멸·redispatched/held→
`verifying` 소멸 — 출구 전이가 뗀다). 같은 PR 이 두 번 집히면(flake_retry 반복 등) 그 PR 을 skip 하고
④ Report 에 `BLOCKED: 재선정 루프 — #<pr>` 로 보고해 드레인을 끊는다. 한 틱 드레인은
최대 verify-eligible 스냅샷 길이만큼만 돈다.

## ④ Report

드레인이 끝나면 이 틱 처리분을 합산해 한 줄: `검증통과 N · 재디스패치 N · 보류 N · 재시도 N · warn N`.

그 아래 **항목마다 번호를 적는다** — 숫자만으론 어느 PR 이 어디로 갔는지 다음 틱이 못 읽는다:
`검증통과: PR #4790(bodat)←#4780 · 재디스패치: PR #4792(bodat)←#4783 (사유 8자 이내)`.
`←` 뒤는 연결 이슈(없으면 생략). 레포 짧은 이름 규칙은 `loop-status.sh` 와 같다
(`owner/repo` 의 repo 를 소문자로 — bodat·bodac, `issue-runner` 만 `runner` 특례).
① 에서 `orphan:true` 로 집은 PR 마다 `고아 재집 #<pr>(<repo_short>)` 한 줄을 남긴다 —
이전 틱이 `verifying` 을 떼지 못하고 죽었다는 증거다(정상 틱엔 이 줄이 없다).
warn(flake_retry·동봉 실패·전이 실패 등)이 있으면 경로·사유를 아래 나열. 모든 카운트 0이면
"조용함" 한 줄. 조용해도 ①② 는 다음 틱에도 그대로 수행한다(새 flow:verify PR 을 놓치지 않게).

**파이프라인 스냅샷 (매 틱 필수).** 위 줄들 뒤에 `$SCRIPTS/loop-status.sh --post verify-runner --delta "<이 틱 한 줄 요약>"`(레포마다 고정 이슈 `루프 현황`(라벨 `loop-dashboard`) 본문도 덮어쓴다 — 깃헙만 보고 누가 들고 있고 루프가 마지막으로 언제 돌았는지 알게, #163) 를 실행해
출력을 **그대로** 붙인다 — 카운터는 "이 틱에 한 일"만 말하고 무엇이 쌓여 있는지는
이 블록만 본다. `cd` 없이 부른다(스코프는 루프 세션 cwd 의 `.loop/repos` 를 자동 적용).
**카운트가 전부 0인 조용한 틱에도 붙인다** — 스냅샷은 "놀고 있는 것"을 보는 유일한 창이다.
- exit 1(부분 실패 — 일부 레포 조회 실패)이면 그 출력을 그대로 붙이고 warn 에
  `loop-status 부분 실패` 한 줄을 더한다.
- exit 64(스코프 없음 — 계정 전체 세션이라 `.loop/repos` 가 없음)면 이 틱에 만진
  레포들을 `--repo <owner/repo>` 로 명시해 한 번 더 부르고, 그래도 없으면 warn 에
  `loop-status: 스코프 없음(.loop/repos 부재)` 한 줄.

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 역할 분담: issue-runner = 생산(구현+결정적CI+PR, `flow:verify` 로 넘김·검증 안 함),
  verify-runner = 검증(E2E+codex 직렬, `머지 판정: ✅` 로 넘김·머지 안 함), closeout =
  마감(머지 독점). 세 루프는 라벨 소유로 충돌을 막는다 — `flow:verify`·`verifying`=
  verify-runner, `harvesting`=closeout(closeout-eligible 은 앞 둘을 제외한다). issue-runner
  는 셋 다 안 건드리고 in-flight 로도 안 센다.
- 컷오버 불변식: verify-runner 가 살아있어야(이 루프가 돌아야) 워커의 `flow:verify`
  PR 이 검증돼 `머지 판정: ✅` 로 흐른다. 이 루프가 죽으면 flow:verify PR 이 검증 없이
  적체하지만(closeout 이 안 집음·issue-runner 도 안 집음) **드롭·오분류는 없다** —
  라벨(`flow:verify` 또는 검증 도중 죽었으면 `verifying`)이 남아 루프 재기동 시 그대로
  재집힌다.
- 운용: issue-runner·closeout 와 별도의 `/loop` 세션(예 `/loop 10m /verify-runner`).
- 의존: 결정적 헬퍼는 `$SCRIPTS`(=`~/.claude/skills/issue-runner/scripts`)의
  `verify-eligible.sh`·`closeout-ci-pass.sh`·`run-local-ci.sh`·`make-worktree.sh`·
  `repo-dir.sh`·`transition.sh`(라벨 이동)·`loop-status.sh`(④ Report 스냅샷), 검증자 프롬프트는 `skills/verify-runner/references/verify-prompt.md`.
  보조 리뷰어는 `pr-review-toolkit@claude-plugins-official` 플러그인(미설치면 3-b 는 자동 skip).
- 실측이 필요한 항목의 시도 순서·통로·인용 규칙은
  `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  (칸 ①dev → ②워커 런타임 → ③TEST 워커 → ④사람. `--reason ladder` 의 전제).
