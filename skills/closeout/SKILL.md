---
name: closeout
description: issue-runner 가 연 초록불 PR을 머지·문서반영·배포준비·후속발행까지 자동 마감하는 루프. /loop 와 함께 (예 /loop 20m /closeout). 매 틱 Reconcile → Pick → 파이프라인 → (후보 남으면 Drain 반복) → Report. 한 틱이 eligible 큐를 다 비운다.
---

# closeout — 마감 도크 틱

당신은 무인 마감 워커다. 아래 단계를 **순서대로** 수행하라. issue-runner 가 벌린
초록불 PR을 머지·문서반영·배포준비·후속발행까지 끝까지 마감한다 — issue-runner 는
절대 머지하지 않으므로, 머지는 이 루프의 독점이다. 두 루프의 충돌은 `harvesting`
라벨 점유로 막는다 (issue-runner ② Maintain 은 `harvesting` PR 을 건드리지 않는다).

> **소유권·정지·전이 실패 규칙의 SSOT 는 `references/state-machine.md` 다**(#393). 어느 상태를 어느 루프가 들고
> 있고(소유 라벨 `flow:verify`·`verifying`·`flow:ready`·`harvesting`), 기계 정지(`hold:*`)와 사람 정지(`needs-human`)가
> 어떻게 풀리며, `transition.sh` 가 exit 1·2 로 끝난 반쯤 이동 상태를 누가 회수하는지는 그 표를 본다 — 아래 산문에
> 같은 규칙이 남아 있으면 표가 이긴다(산문 정리는 플랜 3단계).

## 상수

- `MAX_CLOSEOUT = 1` — **동시성 1**(한 번에 1 PR 만 끝까지 직렬 마감). 틱당 상한이
  아니다 — 한 PR 이 종료 상태(success·approval-required·blocked·dup·exhausted)에 닿으면
  **다음 틱을 기다리지 말고** ①①-b② 로 되돌아 다음 후보를 집어 이어간다(아래 ⑤ Drain).
  큐가 빌 때(② Pick 후보 0)만 틱을 끝내고 `/loop` 주기로 쉰다. 드레인은 유한하다 —
  처리된 PR 은 eligible 에서 빠진다(머지→OPEN 목록서 소멸 · blocked→`needs-human` ·
  dup→PR 이 머지 없이 **닫혀** OPEN 목록서 소멸(머지와 같은 효과) ·
  approval-required→`배포 대기:` 마커 · 재디스패치→PR `재디스패치:` 마커+fresh updatedAt).
  `/loop` 주기는 **빈 큐일 때의 재스캔 간격**만 조절한다(적체 소진 속도가 아니라). 한
  틱이 하나씩만 처리해 적체가 쌓이던 문제를 이 드레인이 해소한다.
- `REPAIR_RECUR_LIMIT = 2` — 같은 배포 후 실패가 N회 재발하면 agent-ready 재발행
  대신 `needs-human` 으로 승격한다 (5단계 서킷 브레이커).
- `QUIET_TICKS = 3` — N틱 연속 후보·이벤트가 없으면 stagnated 로 보고한다. **①
  Reconcile·② Pick 은 이후에도 매 틱 그대로 수행**한다 — 둘 다 `gh api` 조회뿐이라
  비용이 사실상 0 이고(실제 비용은 ③ 파이프라인에서만 발생), 새 PR 은 이미 진행
  중인 것과 무관하게 아무 때나 열리므로 스캔을 끄면 절약 없이 후보만 놓친다
  (실증 #805 — stagnated 이후 Pick 을 건너뛴 틱이 새로 eligible 해진 PR 을 놓침).
  stagnated 는 순수 보고 라벨이다 — 어떤 단계도 건너뛰지 않는다.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = general-purpose` — 1단계 계획 부합 검증자 서브에이전트 타입. **codex 가 아니다**
  (#375, 사용자 결정 2026-09-13 — codex 는 PR 당 2회이고 그 두 번은 verify-runner 몫이다. closeout 이
  세 번째로 부르던 정확성·계획 부합 호출 두 번을 없앴다). **출력 계약은 issue-runner `SKILL.md` 의 `## 상수` 절
  `VERIFIER` 항목이 SSOT 다**(#427 — 세 SKILL 이 각자 SSOT 를 자칭하던 것을 한 곳으로). 여기선 다시
  적지 않는다: read-only·BLOCKER/WARN/NIT·CLEAN·BLOCKER 는 하드게이트, 그대로 적용된다. 검증자는 이
  SKILL.md 를 읽지 않으므로 호출 프롬프트 문자열에 그 계약 문안이 그대로 담겨야 한다 — 프롬프트가
  유일한 전달 경로이고, 그 프롬프트는
  `references/verifier-prompt-fallback.md`(diff·이슈 본문·lessons 를 **동봉**하는 판 — `general-purpose`
  는 Agent 툴에 `--cd` 대응 인자가 없어 워크트리에 스코프되지 않으므로 "이 워크트리는 최신이다" 전제를
  줄 수 없다, #207)다. `references/verifier-prompt.md` 는 내장 리뷰어(codex) 전용이라 여기선 안 쓴다.
- `VERIFIER_TIMEOUT_MIN` — `VERIFIER`(및 폴백) 스폰 1회당 벽시계 상한(분). 스폰
  시각 + 이 값을 데드라인으로 폴링하고, 데드라인을 넘기면 `TaskStop` 으로 끊어 verdict
  미산출로 간주한다 — 외부 CLI 스톨이 틱을 무한정 묶는 것을 막는 방어선(#96).
  **값은 `scripts/lib/constants.sh` 의 `CODEX_GATE_TIMEOUT`(초)을 분으로 환산한 것**이다
  (#427 — 종전 산문의 "900s = 10분" 은 오기였다).
- 절대 금지: production 무인 배포(4단계는 **배포 레인(deploy-cycle) 인계** —
  closeout 자신은 실 배포를 하지 않는다) · 프로덕션 포인터 브랜치(release 등) 무인
  승격(검증된 SHA 를 프로덕션/워커가 당기는 브랜치로 미는 것도 배포와 동급으로
  **배포 레인(deploy-cycle)의 몫**이다) · main 직접
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
- `lookup_failed` — PR **상태를 못 읽었다**(gh 실패·빈 응답, #433). CLOSED 가 아니다 — 라벨을 떼지
  않고 **무접촉**, 다음 틱이 재조회한다. ④ Report 에 `보류: PR #<pr>(<repo_short>) — 상태 조회 실패` 한 줄.
- `human_hold` — PR 이 OPEN 인데 `needs-human` 이 붙어 있거나(사람이 조사 중) 그 라벨을
  못 읽었다(`why` 로 갈린다). **무접촉** — ④ Report 에
  `보류: PR #<pr>(<repo_short>) — 사람 보류(<why>)` 한 줄만 남기고 이 틱엔 더 건드리지
  않는다. `resume` 를 그대로 태우면 아래 `bounced` 재개 절차가 `closeout-redispatch` 를
  걸고, 그 전이가 사람이 방금 붙인 `needs-human`·`hold:*` 를 **뗀다**(①-b 가 대상
  필터로 명시 배제하는 바로 그 위험, #151). 라벨을 못 읽은 경우도 같은 방향이다 —
  보류가 없음을 증명하지 못한 상태를 통과로 처리하면 그게 fail-open 이다.
  **해제 경로**: 사람이 `needs-human` 을 떼면 다음 틱에 `resume` 로 돌아온다
  (`harvesting` 은 그대로라 이 PR 이 레인 밖으로 새지 않는다).
- `stale` — 보고만 한다.

멱등 마커표 (끝난 단계 재판정용 — 재개 시 중복 작업 방지):

| 단계 | 마커 | 재개 판정 |
|---|---|---|
| 1 검증 | PR 코멘트 `마감 검증: ✅` | `$SCRIPTS/closeout-step1-marker.sh <repo> <pr>` 가 `skip` 일 때만 1단계 건너뜀 (바로 아래 절 — `verify`·비0은 전부 **수행**) |
| 2 머지 | PR `MERGED` | MERGED 면 머지 끝 (머지 직후 worktree 정리 포함) |
| 3 reconcile | 계획문서 diff(머지 커밋) + epic 코멘트 | 머지에 포함이면 끝 |
| 4 배포 | `배포 대기:` 코멘트 / `deployed:<sha>` | 있으면 재요청 안 함 |
| 5 후처리 | `✅ 스모크` 코멘트 / 배포 이슈 CLOSED + 검증·배포 완료 코멘트 | 있으면 재스모크 안 함 (배포 레인(deploy-cycle)이 검증까지 마치고 닫은 경우 포함) |
| 6 파생 | 생성 이슈 번호 코멘트 | 있으면 재발행 안 함 |

**1단계 마커는 "있으면 끝" 이 아니다 — 현재 head 에 대한 통과 판정일 때만 센다 (#271).**
옛 표는 1단계를 "`마감 검증:` 코멘트가 있으면 건너뜀" 한 줄로 적었는데, 그 전제는 **세
방향으로 거짓일 수 있다**. 셋 다 결말이 같다 — 검증 안 된 head 가 2단계 머지 게이트로
가고, 그 게이트 조건(CI 캐시 pass · `검증자 리뷰:` BLOCKER 0 · MERGEABLE)은 그대로 전부
참이라 **머지된다**:

- (A) **가장 늦은 `마감 검증:` 이 `⚠ 보류`** 다. ③-1 ⓑ 의 보류 코멘트도 접두가 같아 표에
  걸리는데, `⚠ 보류` 는 1단계를 **통과하지 못했다**는 기록이다. ✅ 의 *존재*가 아니라
  **가장 늦은 것**을 봐야 한다(`✅ → ⚠` 면 더 늦은 ⚠ 이 그 ✅ 를 덮은 것이다 — #218
  attempt 3 이 `bounce-state.sh` 에서 밟은 함정과 같은 형태).
- (B) **마커가 현재 head 커밋보다 이르다.** rebase·사람 푸시로 head 가 바뀌면 그 판정은
  옛 코드에 대한 것이다(✅ 에 적용하던 #171 규칙을 1단계 마커에도 그대로).
- (C) **마커가 최신 반송 마커보다 앞이다.** 반송 뒤 교체 워커가 **새 커밋 없이** ✅ 만
  찍으면 head 시각이 그대로라 (B) 로는 안 걸린다.

셋은 **AND** 이고 판정은 `$SCRIPTS/closeout-step1-marker.sh <repo> <pr>` **한 자리**다
(반송 마커 집합·선후는 그 안에서 `bounce-state.sh --marker-index` 로 받는다 — 마커
매칭을 두 벌로 두지 않는다, #171). 출력이 **정확히 `skip` 일 때만** 1단계를 건너뛴다 —
`verify` 와 비0(조회·파싱 실패)은 같은 방향(**수행**)이다. 재수행의 대가는 검증자 호출
한 번이고 건너뜀의 대가는 검증 안 된 머지라 비대칭이다.

**`resume` 의 재개 지점은 마커표보다 반송 상태가 먼저다 (#271).** 마커표 1단계 행의
"`마감 검증:` 코멘트가 있으면 건너뜀" 은 **전제가 거짓일 수 있다** — 이전 회차가 남긴
`마감 검증:` 코멘트(예 ③-1 ⓑ 의 `⚠ 보류` 를 사람이 풀어 다음 회차가 돌아온 PR)가 이미
있으면 마커표는 1단계를 건너뛰고 **2단계 머지 게이트**로 보낸다. 그 게이트 조건(CI 캐시
pass · `검증자 리뷰:` BLOCKER 0 · MERGEABLE)은 반송 직전 상태 그대로 전부 참이라 **방금
BLOCKER 를 낸 head 가 머지된다.** 그래서 `resume` 은 마커표를 보기 **전에**
`$SCRIPTS/bounce-state.sh <repo> <pr>` 를 한 번 돌리고 그 값으로 재개 지점을 정한다(①-b 가
쓰는 것과 **같은 한 자리** — 판정 로직을 두 벌로 두지 않는다). 그 스크립트가 낼 수 있는
값은 넷이고 **넷 다 행선지가 있다**:

| `bounce-state.sh` | 뜻 | `resume` 재개 지점 |
|---|---|---|
| `ok` | 반송 마커가 없거나, 최신 반송 마커 뒤 마지막 판정이 `머지 판정: ✅` | **마커표 그대로** — 끝난 단계를 건너뛰고 중단 지점부터. 1단계 행의 판정은 위 절 대로 `closeout-step1-marker.sh` 한 자리다(반송 선후 (C)·head 신선도 (B)·`⚠ 보류` (A) 가 그 안에 함께 들어 있다 — 여기서 따로 따지지 마라) |
| `bounced` | 최신 반송 마커 뒤에 판정 코멘트가 없거나 그중 마지막이 `머지 판정: 🔄` | 마커표를 **보지 말고** ③-1 ⓐ 의 `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` **재시도 지점**에서 이어간다(바로 아래 재개 절차) — 1단계 재검증·2단계 머지로 가지 않는다 |
| `held` | 최신 반송 마커 뒤 마지막 판정이 `머지 판정: ⚠ 보류` | **`active` 취급 무접촉** — 워커가 명시적으로 올린 보류다. ④ Report 에 `보류: PR #<pr>(<repo_short>) — 반송 뒤 워커 ⚠` 한 줄만 남기고 이 틱엔 더 건드리지 않는다(①-b 와 같은 방향 — 스윕도 이 값을 승격에 쓰지 않는다, #218 두 번째 회차) |
| 무출력(exit 1 — 판정 실패) | 코멘트 조회·파싱 실패 | **`active` 취급 무접촉** + ④ Report 에 `BLOCKED: 반송 판정 실패 PR #<pr>(<repo_short>)` — 반송되지 않았음을 *증명하지 못한* 상태를 통과로 처리하면 그게 fail-open 이다(①-b 와 같은 방향) |

**`bounced` 재개 절차 — 전이를 다시 걸기 전에 점유부터 맞춘다.** 여기까지 왔다는 것은
③-1 ⓐ 의 회수(`closeout-pick`)가 PR·이슈 양쪽에 `harvesting` 을 되살렸다는 뜻이지만,
그 회수가 반쪽만 들었을 수 있다. `gh issue view <issue> --repo <repo> --json labels` 로
이슈 쪽을 먼저 보고 갈라라(PR 쪽은 `harvesting` 이 있어야 애초에 `resume` 이 난다):

- 이슈에 `agent:claimed` 가 있다 = **교체 워커가 살아 있다**(회수 창에서 디스패처가 먼저
  집었다). 전이를 걸지 마라 — 재시도가 그 워커의 `agent:claimed` 를 뗀다. `active` 취급
  무접촉으로 두고 ④ Report 에 `보류: PR #<pr>(<repo_short>) — 교체 워커 점유(agent:claimed)`
  한 줄만 남긴다. 워커가 완결해 `머지 판정: ✅` 를 찍으면 다음 틱 판정이 `ok` 로 바뀌어
  마커표 경로로 저절로 돌아온다.
- 이슈에 `harvesting` 도 `agent:claimed` 도 없다 = **반쪽 회수**(이슈 쪽 점유가 빈 채로
  남았다 — 그대로 전이를 걸면 그 사이 디스패처가 이슈를 집는다). 먼저
  `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` 를 한 번 더 걸어 양쪽을 맞추고
  (멱등이라 PR 쪽은 no-op) 아래로 간다. 비0이면 ④ Report 에
  `BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올리고 이 틱엔 끝이다.
- 양쪽에 `harvesting` 이 있다 = 온전한 회수. 그대로 아래로 간다.

그런 다음 ③-1 ⓐ 의 **전이 호출만** 다시 건다 — **반송 코멘트는 다시 남기지 마라.** 이미
원장에 있고(그래서 판정이 `bounced` 다), 한 번 더 남기면 일어나지도 않은 회차가 원장에
늘어 다음 틱의 판정 입력이 거짓이 된다. 그 재시도가 **또** 실패하면 ③-1 ⓐ 의 실패 갈래
그대로(회수 호출 한 번 + `BLOCKED: 전이 실패 closeout-redispatch …`)이고, ④ Report 의
`BLOCKED:` 줄로만 남긴 뒤 **그 틱은 그 PR 을 더 건드리지 않는다**(같은 틱 안에서 다시
돌리지 마라 — 무한 재시도 금지). 다음 틱의 `resume` 이 같은 자리를 다시 집는다.

**에픽 스윕 (① 끝, 매 틱)** — leaf 를 다 닫고도 열린 채 남은 에픽은 **아무 루프도 닫지
않는다**(에픽은 워커가 집어가는 대상이 아니라 sub-issue 롤업 대상이다). `cd` 없이
`"$SCRIPTS/epic-sweep.sh"` 를 실행한다(스코프는 루프 세션 cwd 의 `.loop/repos` 가 자동 적용).
`Epic #N` 전용 줄로 leaf 를 찾아 **leaf 가 1건 이상이고 전부 CLOSED** 인 에픽만 닫는 결정론
스윕이고, 이벤트별 처리는:

- `closed` — 에픽을 닫았다(근거 코멘트 + `--reason completed`). ④ Report 에
  `에픽 종료: #N(<레포 짧은 이름>, leaf K)` 로 적는다(K = `leaves` 배열의 개수).
- `note` — **아무것도 안 건드린** 정상 상태(`Epic #N` 줄이 없는 옛 에픽 · `deploy-wait`
  라벨이 붙은 에픽 · 스윕이 닫은 뒤 **사람이 되돌린** 에픽 — 마커가 있는데 열려 있으면 다시
  닫지 않는다, #377). **보고하지 않는다** — 매 틱 같은 줄이 쌓여 진짜 신호를 묻는다.
- `warn` — 판정을 **보류**했거나(leaf 검색이 상한에 닿음) 조회·쓰기가 실패했다. ④ Report 의
  warn 줄에 `why` 를 그대로 옮긴다. 보류는 실패가 아니므로 exit 0 일 수 있다.

exit 1 은 이 틱에 조회·쓰기 **실패**가 있었다는 뜻이다 — 다음 틱이 재시도하므로 손대지
마라(종료 근거 코멘트의 `<!-- epic-sweep -->` 마커가 멱등을 보장해 코멘트가 겹치지 않는다).
예외 하나: `에픽 close 실패(N회 시도)` warn 은 다음 틱이 **재시도하지 않는다**(마커가 남아
되돌림으로 읽힌다) — why 그대로 Report 에 옮겨 사람이 닫게 한다.
exit 64 는 스코프 없음(`.loop/repos` 부재)이니 이 틱에 만진 레포를 `--repo <owner/repo>` 로
명시해 한 번 더 부르고, 그래도 없으면 `epic-sweep: 스코프 없음` 한 줄을 warn 으로 남긴다.

## ①-b 정체 PR 스윕 — 완결 유실 회수 (매 틱)

`closeout-eligible.sh` 는 **`머지 판정: ✅` 마커가 있는 PR만** 후보로 올린다. 이 ✅ 는
워커가 **종료 직전**에 찍어서(worker-template 최종단계), 워커가 `🔄 진행 중`→검증자
리뷰→`✅` 사이에서 죽거나 timebox 로 끊기면 ✅ 가 유실되고, 그 PR 은 eligible.sh(✅
없음)·issue-runner Maintain(CI green·리뷰없음=사람 리뷰 대기로 방치) **양쪽 사각지대**
에서 무한 적체한다(실증 #970: 검증자 `BLOCKER 없음`까지 갔는데 ✅ 유실; #971: `🔄 진행
중`에서 사망). **완결 유실 회수는 마감 담당인 이 루프가 소유한다** — issue-runner 에
완결 로직(대리 append·재디스패치)을 얹지 않고 closeout 에 일원화하는 역할 분리다
(사용자 결정 2026-07-06). QUIET_TICKS 원칙과 같은 이유(gh 조회뿐·비용 0)로 stagnated
여도 매 틱 돈다.

**✅ 는 "어느 SHA 에 대한 판정인가" 까지 봐야 한다 (#171).** 반송된 PR 은 그 반송 사유가
된 코드에 대해 이미 ✅ 를 갖고 있다 — 그대로 두면 closeout 이 BLOCKER 를 낸 코드를
closeout 이 머지한다. 그래서 `closeout-eligible.sh` 는 ✅ 존재만으로 후보를 만들지 않고
두 겹으로 막는다(둘 다 **증명되지 않으면 열지 않는다** 방향):

1. `finish-classify.sh` 재사용(로직 두 벌 금지) — ✅ 판정 시각과 head 커밋 시각을 **둘 다
   얻어** 판정이 head 이후임을 확인했을 때만 `done_verdict`. 조회·파싱 실패는 통과가 아니라
   `active` 다(머지 게이트에서 증명 실패를 통과로 처리하면 그게 fail-open).
2. **반송 마커 안전망** — 반송 직후 아직 새 커밋이 없어 head 시각이 그대로인 창을 덮는다.
   마커 집합은 반송 채널 둘을 **한 자리**(`bounce-state.sh` 의 `BOUNCE_MARKERS`)에
   묶는다: `재디스패치`(이 스킬 ①-b) · `재검증 실패`(verify-runner ④). 매칭은 **첫 줄 맨 앞
   + 마커 뒤 형태** — 콜론을 리터럴로 요구하지 않고(#212), 마커 뒤가 반송 관용 구분자
   (**앞 공백류 몇 칸이든** + `:`·`#N`·`(`·`[`·대시·숫자, 또는 줄 끝 — #299)면 반송,
   **산문이 이어지면**(조사·어미 또는 공백+낱말)
   반송 표식(`#N`·`attempt`·대시·`반송`)이 있을 때만 반송이다(#221 · #251). 해소·완료
   **어휘는 판정에 안 섞는다** — 어휘에 표식 거부권을 주면 `해소가 필요합니다`·`해소되지
   않았습니다` 같은 진짜 반송이 `ok` 로 샌다(#251 attempt 2 실측). 워커의 반송 해소
   보고가 마커로 시작해 정체하던 축(#251 ②)은 판정기가 아니라 **문안**으로 닫혔다 —
   보고는 `반송 반영 …` 접두로 쓴다(`references/worker-template.md` 10절 · `bin/ci` 가드).
   새 반송 어휘가
   생기면 그 배열만 고친다. 선후는 `createdAt` 이 아니라 **코멘트 배열의 마지막 매칭
   인덱스**로 잰다 — GitHub 코멘트 시각은 초 단위라 동초에 달린 ✅ 와 마커의 순서를
   시각만으로는 가릴 수 없다.

두 겹 모두 **코멘트를 전부 봤다**는 전제 위에 선다. `gh pr view --json comments` 는
페이지네이션 없이 **첫 100건**만 주므로 두 헬퍼는 그 경로를 쓰지 않고 `pr-comments.sh`
(= `gh api .../issues/N/comments --paginate`) **한 자리**로 읽는다. 반송을 여러 번 도는
PR 은 워커·verify·closeout 코멘트가 겹겹이 쌓여 100건이 먼 숫자가 아니고, 상한에 갇히면
양방향으로 조용히 틀린다 — 새 ✅ 가 101번째 이후면 머지 가능한 PR 이 영영 후보에 안 뜨고
(조용한 큐 사망), 반송 마커가 101번째 이후면 반송된 PR 이 안전망을 통과한다.

같은 상한이 **커밋 쪽에도** 있었다. `gh pr view --json commits` 는 GraphQL
`commits(first: 100)` 이라 101번째부터 안 오고, 그때 `last` 는 head 가 아니라 100번째
커밋이다 — 그 이른 시각으로 비교하면 낡은 ✅ 가 `head <= verdict` 를 만족해 통과한다.
그래서 head 시각은 커밋 목록을 세지 않고 `pr-head-at.sh`(= `--json headRefOid` 로 head SHA
를 받아 `gh api repos/<repo>/commits/<sha>` 하나만 조회) **한 자리**로 읽는다. 그리고 그
조회는 **코멘트를 읽은 뒤**에 한다 — 먼저 뜨면 그 사이의 push 가 `head_at` 에 안 잡혀
검증 안 된 head 가 후보로 나간다.

**대상**: `me=$(gh api user -q .login)` 후 `gh api -X GET search/issues -f q="user:$me
is:open is:pr" -f per_page=100 -f sort=created -f order=asc`(FIFO)로 열린 PR 을 모으고,
head 가 `agent/issue-*` 이고 **`full-cycle` 미부착**(사람 세션 레인 소유 표시 — head 이름은 관례라
라벨이 명시적 제외 축이다, #246)이며 **`harvesting` 미부착**이며 **`flow:verify` 미부착**·**`verifying` 미부착**이고
**`needs-human` 미부착**이며 **`hold:` 접두 미부착**인 PR 마다 판정한다. 두 라벨은 **다른 정지**다(#244) —
`needs-human` 은 사람이 직접 세운 정지고, `hold:<사유>` 는 기계 정지(verify-held·closeout-blocked·
디스패처 runner-held 보수 상한) 그 자체다. 전이는 기계 정지에 사유 라벨 **하나만** 붙이므로
`needs-human` 만 보면 홀드된 PR(셋 다 없고 `hold:*` 만 남은 PR)이 **매 틱 다시 대상이 되어**
hold-note 를 되붙이고, `stale_reverify` 갈래에선 `closeout-redispatch` 가 verify-runner 가 방금
세운 홀드를 통째로 벗긴다(#151 재현). 어느 쪽이든 스윕이 입양·재디스패치하면 방금 선 정지를
되돌리는 것이라, 그 라벨이 떨어지기 전엔 절대 집지 않는다 — 해제는 사람이(`hold:conflict`·
`needs-human`) 또는 재개 스윕이(`hold:ladder`·재심을 통과한 `hold:policy`) 한다. 판별은
**접두**라 사유가 늘어도(`hold:<새사유>`) 안 깨지고 `holding`·`on-hold`·`area:hold` 는 걸리지
않는다 — `closeout-eligible.sh` 의 같은 필터와 같은 규칙이다(과잉 제외는 머지 가능한 PR 을
조용히 큐에서 지우는 방향이라 원래 결함보다 나쁘다). **`flow:verify`(검증대기)·`verifying`(검증 중 —
verify-runner 가 집는 순간 `verify-pick` 으로 `flow:verify` 를 떼고 붙이는 점유 라벨, `harvesting`
동형, #275) PR 은 verify-runner 소유라 여기서 절대 집지 않는다** — 이걸 빠뜨리면 finish-classify 가
`🔄`(verify-runner 가 아직 ✅ 안 찍음)를 `stale_reverify` 로 오분류해 재디스패치하고, verify-runner
의 검증과 충돌한다(양쪽이 같은 PR 을 물어뜯음). `verifying` 은 특히 **지금 E2E·codex 가 도는 중**이라
입양·재디스패치 어느 쪽도 그 검증을 통째로 무효화한다. 이 배제는 1) CONFLICTING 갈래에도 그대로
적용된다 — 대상 필터가 먼저다(#206). 검증 단계의 완결 유실 회수는 verify-runner 의 매 틱 재집
(`verifying` 고아 우선 → `flow:verify` FIFO)이 소유한다 — closeout ①-b 는 **검증 이후**(✅+flow:ready
인데 closeout 머지가 죽은 경우)와 CONFLICTING 입양만 맡는다. 같은 네 라벨 필터가
`closeout-eligible.sh` 에도 있다 — 한쪽만 고치면 스윕과 후보 게이트가 갈린다.

**1) 반송 마커 게이트 먼저 — 갈래를 가르기 전에, CONFLICTING·MERGEABLE 공통**(#218):
mergeable 값을 보기 **전에** `$SCRIPTS/bounce-state.sh <repo> <pr>` 를 한 번 돌려라.
출력은 `ok`/`bounced`/`held` 세 값이다(#218 attempt 2 — `held` 신설). 판정 규칙은 한 줄이다:
**최신 반송 마커 뒤에 오는 판정 코멘트(`머지 판정: ✅`/`⚠ 보류`/`🔄`) 중 가장 늦은 것이
결과를 정한다** — ✅ 면 `ok`, ⚠ 면 `held`, `🔄` 면 `bounced`(교체 워커가 지금 일하는
중이라는 가장 강한 증거라 워커 레인 소유다, #218 attempt 4).

- `held` 이거나 **출력이 없으면(exit 1 — 판정 실패)** → `active` 취급 **무접촉**, 여기서
  멈춘다(mergeable 도 안 보고 2) finish-classify 도 안 부른다). 진행 중인 반송 회차는
  워커 레인 소유다(fail-closed — 반송되지 않았음을 *증명*했을 때만 연다, #171 과 같은
  방향).
  **`held` 도 스윕은 needs-human 으로 승격하지 않는다**(#218 두 번째 회차 — 사람 결정
  (c), 아래 "왜 `held` 를 스윕이 더 이상 승격하지 않는가" 절).
- `bounced` 면 → **원칙은 같은 무접촉**이다(진행 중인 반송 회차는 워커 레인 소유).
  **사람이 `held` 를 풀어 라벨을 뗀 뒤 교체 워커가 `머지 판정: 🔄` 를 찍고 재개한 PR 도
  여기로 온다** — 그게 `bounced` 쪽 해제 경로다(#218 attempt 4). 그 무접촉에
  **예외 갈래 하나**만 연다(#206, 아래 "그 좁힘이 남긴 정체" 절):
  - `gh pr view <pr> --repo <repo> --json mergeable` 이 **CONFLICTING** 일 때만 2) 의
    `$SCRIPTS/finish-classify.sh <repo> <pr> [<이슈>]` 로 분류하고, 출력이
    `stale_reverify` 또는 `stale_inline` 이면 **재디스패치**한다(2) 표의 `stale_reverify`
    행과 같은 조치 — `closeout-redispatch` 전이 + 멱등 마커). 반송 회차 워커가 커밋까지
    하고 ✅ 직전에 죽은 형상이다.
  - **반송 마커 시각도 스테일 클록에 든다(#308)** — 반송 전이가 `agent:claimed` 를 떼므로
    **반송 직후 디스패처가 다시 붙이기 전 라벨 공백 창**에서는 진행 증거 세 축이 전부
    old/none 이다. 그 창에서는 `finish-classify.sh` 가 `active` 를 내므로 이 갈래가 열리지
    않는다(마커 판별은 `bounce-state.sh` 한 자리를 되물어 얻는다 — 마커 집합 두 벌 금지).
  - 그 창이 **무해했던 이유**(그런데도 고친 이유): `closeout-redispatch` 는 readback 기준이라
    이미 `agent-ready` 인 이슈엔 no-op 이고 멱등 마커 규칙이 재발행을 막아 워커는 안 죽었다 —
    남는 손해는 **원장 한 줄**이다. 원장은 다음 틱·사람이 **사인**을 읽는 유일한 자리라,
    살아 있는 반송 회차에 `완결 유실(검증 전 사망)` 이 적히면 사람이 죽은 것으로 오독한다.
  - **`stale_inline` 도 입양(머지)하지 않고 재디스패치로 보낸다.** 반송된 PR 에 남아
    있는 `검증자 리뷰: CLEAN` 은 **반송 이전 회차**의 것일 수 있어, 입양하면 방금 반려된
    코드를 머지한다(#196 이 막은 바로 그 방향). 그렇다고 무접촉으로 두면 이 절이 없애려는
    정체가 옆 칸에 그대로 남는다 — 머지하지 않고 재디스패치하는 것이 두 요구를 동시에
    만족하는 유일한 조치다.
  - **MERGEABLE 인 `bounced` 는 전부 무접촉**이다 — 여기까지 열면 #218 이 막은 오분류
    (방금 반송된 MERGEABLE PR 을 `stale_reverify`= "검증 전 사망" 으로 오진하고 사실과
    다른 멱등 마커를 원장에 남김)가 그대로 되살아난다. 예외는 CONFLICTING 한 갈래뿐이다.
  - CONFLICTING 이어도 그 밖의 출력(`active`·`done_verdict`·`held`)은 **무접촉**이다.
    `done_verdict` 는 ✅ 정상 경로라 `closeout-eligible.sh` 가 자기 반송 안전망과 함께
    소유한다.
- 출력이 정확히 `ok` 일 때만 → `gh pr view <pr> --repo <repo> --json mergeable` 로
  갈라라:
  - CONFLICTING 이면 → **입양(rebase 경로)**: ② Pick 후보로 넘기고 ③ 2단계에서
    closeout 이 직접 rebase 후 머지(2단계 conflict 경로). (finish-classify 는 건너뛴다.)
  - 아니면(MERGEABLE 등) → 2) `finish-classify.sh` 로 계속.

왜 갈래 **안**이 아니라 **앞**인가(#218 실측: bodat PR #5050 / 이슈 #5036): CONFLICTING
갈래 전용 게이트(#196)만으론 **MERGEABLE 인데 방금 반송된** PR 이 안 걸린다 —
`finish-classify.sh` 가 그런 PR 을 `stale_reverify`(검증 전 사망)로 오분류해
재디스패치하고, 사실과 다른 멱등 마커(`재디스패치: #<이슈> — 완결 유실(검증 전
사망)`)를 원장에 남긴다. `finish-classify.sh ggqgga/BodaT 5050` → `stale_reverify`,
`bounce-state.sh ggqgga/BodaT 5050` → `bounced`(verify-runner 가 이미 반송한
회차인데 `stale_reverify` 는 "검증 전 사망"이라 사인이 틀렸다). `held`(워커 `⚠ 보류`)
뒤에 verify 가 반송한 순서도 같은 겹침이라, 게이트를 갈래 앞으로 끌어올리면
CONFLICTING·`stale_reverify`·`held` 세 갈래가 한 자리로 덮인다 — 갈래가 하나 더
생겨도 이 자리 하나로 자동 덮인다.

**attempt 1 에서 attempt 2 로 — ⓐ/ⓑ 를 가른 근거**(#218 attempt 2, codex BLOCKER 재검증
실패 PR #225): attempt 1 은 `bounced` 를 무조건 여기서 조기 종료했다. 그런데 `bounced`
는 "지금 반송 중"과 "반송 뒤 활동이 쌓인 상태" 두 뜻을 겸하고 있었다(PR#168 교훈과
같은 형상 — 공유 센티널 하나가 두 사유를 가린다). 반송 뒤 활동은 갈래가 둘이다:
- **ⓐ 교체 워커 사망(✅ 도 ⚠ 도 없음)**: 다른 레인이 덮는다 — 반송 전이가 연결
  이슈를 `agent-ready` 로 되돌리므로 디스패처가 새 워커를 붙이고, 그 워커가 죽으면
  타임박스 판정(`scripts/timebox-check.sh`, #200)이 claim 을 회수해 다시
  `agent-ready` 로 돌린다. 영구 정체가 아니므로 **여기서 고치지 않는다.**
- **ⓑ 반송 뒤의 `머지 판정: ⚠ 보류`**: 덮는 레인이 없다. 워커가 "사람이 판단해야
  한다" 고 명시적으로 올린 신호인데 게이트가 `bounced`에서 멈춰 `finish-classify`를
  안 부르니 `held`(→needs-human)가 **한 번도 실행되지 않았다.** 사람 신호가 조용히
  묻히는 것 — 이 스윕이 애초에 없애려던 그 형상이라 여기서 고친다.

이 구분을 `bounce-state.sh` **안**에 뒀다(새 신선도 술어를 SKILL 프로즈에 짜 넣지
않는다) — ✅ 축과 정확히 같은 규칙(마지막 매칭 **인덱스**, createdAt 아님)을 ⚠ 축에도
그대로 적용해 세 번째 출력값 `held` 를 냈을 뿐이다(`scripts/bounce-state.sh` 참조).
`stale_reverify`·`stale_inline`·`done_verdict` 는 `bounced` 일 때 여전히 승격하지
않는다 — ⓐ 는 위에서 이미 무회귀가 증명됐고, `bounced` 인 채로 그 값들을 승격하면
#218 attempt 1 이 막았던 사고(반송된 코드를 완결로 오분류)가 되살아난다.

**attempt 4 — `held` 의 해제 경로**(마감 검증 BLOCKER, PR #225): attempt 2·3 이 세운
`held` 는 **진입만 있고 해제가 없었다.** 후보 집합이 ✅·⚠ 둘뿐이라 `머지 판정: 🔄` 가
빠져 있었고, 그래서 ⑴ 반송 마커 ⑵ 워커 `⚠ 보류` → `held` → `hold:policy`
(#244 이전엔 `needs-human` 과 쌍이었다 — 지금은 사유 라벨 하나다) ⑶ **사람이 그 보류를 풀어
라벨을 뗀다** ⑷ 교체 워커가 `🔄` 로 재개한다 ⑸ 다음 틱: 정지 라벨이 떨어졌으니
다시 스윕 대상인데 판정이 **여전히 `held`** → `closeout-blocked`
가 다시 걸려 **사람이 방금 푼 보류가 되살아나고 살아있는 교체 워커가 끊긴다**(`✅` 에
도달해야만 풀리는데 끊기니까 도달할 수 없다). 이 레포가 막아 온 "루프 대 사람
싸움"(#151)이 방향만 바뀐 형태고, 이 게이트는 **매 틱** 도는 자리라 조용히 반복된다.
해소는 규칙을 그대로 두고 후보 집합만 대칭으로 채우는 것 — `🔄` 를 넣되 결과값은 `ok`
가 **아니라** `bounced`(`ok` 로 두면 attempt 1 이 막은 "CONFLICTING 갈래가 살아있는
워커 PR 을 입양·rebase" 가 되돌아온다).

**왜 `held` 를 스윕이 더 이상 승격하지 않는가(#218 두 번째 회차, 사람 결정 (c))**:
attempt 4 의 해제 경로는 **교체 워커가 이미 `🔄` 를 찍은 뒤**만 고친다. ⑶ 사람이
라벨을 떼는 시점과 ⑷ 교체 워커가 `🔄` 를 찍는 시점 사이에는 창이 남는다 — 그 창
안에서는 코멘트 배열이 ⑵ 시점과 한 글자도 다르지 않아 `bounce-state.sh` 가 여전히
`held` 를 낸다. 이 함수는 코멘트 배열의 순수 함수라 "이 `held` 를 스윕이 이미 한
번 소비해 needs-human 을 붙였다가 사람이 방금 뗐다" 와 "이 `held` 를 스윕이 아직
한 번도 못 봤다"(=attempt 2 가 원래 잡으려던 첫 진입)를 **문자열만으로는 구분할
수 없다** — 둘 다 똑같이 `held` 다. 코멘트 밖 신호로 가르는 안(타임라인 이력·해제
마커)도 검토됐으나 채택하지 않았다 — 해제 마커는 사람이 라벨만 떼면 바로 깨지고,
타임라인 이력은 #174 의 에피소드 키가 다루는 더 넓은 축이다(그쪽이 "무엇이
해제인가" 를 정하면, 여기는 "해제 뒤 누가 다시 붙일 수 있나" 를 좁힌다).

그래서 (c): **스윕은 `held` 를 `bounced`·판정 실패와 똑같이 무접촉으로 받는다** —
needs-human 으로 승격하는 갈래를 이 자리에서 없앤다. 되살아나는 것을 알고 고른
선택이다 — attempt 2 가 막았던 원래 사고(반송 뒤 `⚠` 가 영영 needs-human 이 안 되는
것)가 **이 게이트 자리에서는** 되살아난다. 대신 살아남는 경로가 있다: **반송 마커가
전혀 없는** 순수 `⚠`(bounce-state.sh 가 `$bi == null` 로 애초에 `ok` 를 내는 경우)는
이 게이트를 `ok` 로 통과해 아래 2) `finish-classify.sh` 자신의 `held` 행으로 그대로
승격된다. 단 이 경로에도 **사람이 라벨을 뗀 뒤 같은 `⚠` 로 다음 스윕이 홀드를 되붙이는
창**은 남는다 — 그 해제 판정(부착↔해제 에피소드)은 #174(PR #182)가 `finish-classify.sh`
에서 닫는다(해제 뒤면 `held` 대신 `active`).
`bounce-state.sh` 의 `held` 계산 자체는 바뀌지 않는다(값은 여전히 정확하다) — 폐지는
이 호출자(스윕)가 그 값으로 하던 조치뿐이다.

**규율(이 자리에서 세 번 물린 것)**: 새 종결 상태를 만들 때는 진입 경로만 보지 말고
**해제 경로까지 함께** 세워라. 진입만 보면 그 상태가 사람의 해제를 매 틱 되돌린다.

CONFLICTING 갈래에 왜 원래 필요했나(#196 실측: bodat PR #5009 / 이슈 #4973): 반송된
PR 은 `머지 판정: ✅` 가 없어 `closeout-eligible.sh` 목록에 애초에 안 뜨고,
finish-classify 를 건너뛰는 CONFLICTING 갈래는 반송 마커를 볼 자리가 따로 없었다.
반송 직후에는 `transition.sh` 가 단계 라벨을 정리하므로 "단계 라벨 0 + CONFLICTING"
은 좌초의 증거가 아니라 **반송 회차의 정상 형상이기도 하다.** 실제로 closeout 이
살아 있는 워커의 PR 을 입양해 `harvesting` 을 붙이고 그 워크트리에서
`git rebase origin/main` 까지 돌렸다(원격은 push 전이라 무손상).

**그 좁힘이 남긴 정체 (#206).** `bounced` 를 **무조건** 무접촉으로 두면 새 정체 계급이
생긴다 — ⑴ PR 반송 → ⑵ 교체 워커가 붙어 고치고 커밋 → ⑶ 그 워커가 ✅ 직전에 죽어
`handoff-verify` 미호출(단계 라벨 없음) → ⑷ 그 사이 main 이 움직여 CONFLICTING. 이
PR 은 closeout ①-b(반송 마커가 최신)·verify-runner(`flow:verify`·`verifying` 없음)·issue-runner ②
(CI green·미해결 코멘트 없음) **세 레인 모두**에서 빠져 사람이 눈으로 찾을 때까지
영구 정체한다. 정체는 손상보다 낫지만(그래서 `ok` 만 입양하는 판별식은 그대로 둔다),
**감지 가능**하게 만들지 않으면 안전망이 조용한 누락으로 바뀐다. 그래서 `bounced` 를
버리지 않고 finish-classify 에 태워 "죽은 반송 회차" 만 골라 재디스패치로 보낸다.

**살아 있는 워커는 finish-classify 가 막는다.** 반송 마커가 최신이어도 그 뒤 커밋이
최근이면 attempt N+1 워커는 **살아 있다** — 이 레포의 반복 오탐이다. finish-classify 는
🔄 계열 갈래를 내기 전에 `progress-evidence.sh`(#200 이 세운 진행 증거 술어 — ① 최신 커밋이
`STALL_MIN` 이내 ② 그 head SHA 의 CI 티켓이 큐에 살아 있음)에 물어 증거가 있으면 `active`
를 낸다. ②가 특히 중요하다: 박스 전역 직렬 CI 큐(#127) 대기는 워커가 통제할 수 없는
시간이라, 커밋이 한 시간 넘게 멈춰 있어도 워커는 살아 있다(#200 실측 72분·64분).
**술어는 그 파일 한 자리다** — `timebox-check.sh` 가 부르는 바로 그 자리이고, 여기에
두 번째 계산기를 만들지 않는다(`bin/ci` 가 `^STALL_MIN=`·`^queue_alive()` 정의의 중복을
막는다). 진행 증거를 **판정하지 못한 경우**도 `active` 다 — 조회 실패 한 번으로 살아 있는
워커의 브랜치를 채가는 것은 되돌릴 수 없다. 판정 불가에는 queue.log 를 못 읽은 경우와
**head 조회(`pr-head-at.sh`)가 실패한 경우**가 모두 들어간다: 조회 실패(`unknown`)와 커밋
증거의 부재(`none`)는 다른 상태이고, 전자를 후자로 접으면 gh 가 한 번 흔들린 것만으로
살아 있는 반송 회차가 재디스패치된다.

판정은 `bounce-state.sh` **한 자리**다 — 마커 집합(`재디스패치`·`재검증 실패`, 콜론
리터럴을 요구하지 않되 마커 뒤 형태로 가르는 첫 줄 매칭 — #212 · #221 · #251)도, 선후를
`createdAt` 이 아니라 **코멘트 배열의 마지막 매칭 인덱스**로 재는 규칙도 거기 있고
`closeout-eligible.sh` 가 같은 자리를 부른다(로직 두 벌 금지).

**`agent:claimed` 의 *존재*는 보조 게이트로 쓰지 않는다**(#196 3항 결정, 실측 근거):
`reconcile.sh` 는 열린 PR 이 있는 이슈에서 `agent:claimed` 를 **떼지 않는다**(worktree 가
사라지고 열린 PR 도 없을 때만 stale 로 뗀다). 그래서 ①-b 가 집어야 할 *진짜* 좌초
CONFLICTING PR 도 그 라벨을 그대로 달고 있다 — 배제 조건으로 걸면 CONFLICTING 입양 레인이
통째로 닫힌다. 반대 방향으로도 못 쓴다: 반송 직후 `closeout-redispatch`/`verify-redispatch`
가 `agent:claimed` 를 뗀 뒤 디스패처가 새 워커를 붙일 때까지의 창에서는 **워커 레인
소유인데 라벨이 없다**. 두 방향 모두 틀리므로 **입양·배제 판정은** 코멘트 마커 하나로 한다.

**다만 그 라벨의 *부착 시각*은 쓴다 — 그건 다른 신호다**(#206 attempt 3, codex BLOCKER).
존재는 "누군가 언젠가 집었다" 밖에 말하지 않지만, 부착 시각은 **이번 회차가 언제
시작됐나**를 말한다. 반송 직후 디스패처가 붙인 claim 은 몇 분 전이고 좌초한 회차의
claim 은 몇 시간 전이다. 이 신호가 필요한 이유: 진행 증거 ①(커밋 신선도)·②(CI 큐 티켓)는
워커가 **이미 뭔가 남긴 뒤에만** 존재해서, 반송 직후 교체 워커가 디스패치됐지만 **첫 푸시
전**인 창을 못 덮는다 — 그 창에서 `finish-classify.sh` 가 보는 값은 전부 *이전* attempt 의
것이라 `stale_reverify` 가 나고, `closeout-redispatch` 가 **지금 일하고 있는 워커의
`agent:claimed` 를 떼어낸다.** 그래서 진행 증거 ③ 은 `agent:claimed` 가 **지금 붙어 있고**
마지막 부착이 `ISSUE_TIMEBOX_HOURS` 안이면 커밋이 없어도 `active` 다. 조회는
`$SCRIPTS/claim-at.sh <repo> <이슈>` **한 자리**(타임라인의 마지막 매칭 인덱스로 부착 여부
판정 — `bounce-state.sh` 와 같은 규율)이고, 그래서 2) 의 분류 호출이 이슈 번호를 함께 받는다
(`finish-classify.sh <repo> <pr> [<이슈>]` — 안 주면 한 번 묻되, **head 의 `agent/issue-N` 이 1순위**이고
`closingIssuesReferences` 는 폴백이다). 그 순서가 중요한 이유: 여기서 필요한 것은 "이 PR 이 닫는
이슈" 가 아니라 **"이 브랜치의 워커가 집어간 이슈"** 이다 — `[0]` 은 닫는 이슈가 둘
이상일 때 **남의 이슈**를 가리킨다(실측 PR #113 head=`agent/issue-109` refs=`[108,109]` — `[0]` 은
#108). 그 이슈를 물으면 claim 이 `none` 으로 나와 증거 ③ 이 조용히 꺼지고, 지금 일하는
워커가 재디스패치된다.
상한이 `ISSUE_TIMEBOX_HOURS` 인 이유: 그 시간을 넘긴 claim 은 ① Reconcile 의
`timebox-check.sh` 가 이미 회수 대상으로 보는 구간이라 여기서 살릴 이유가 없다 — 두 자리가
같은 상수를 읽어 같은 경계를 쓴다. 조회 실패는 `none` 이 아니라 `unknown` 이다(조회 실패
한 번으로 살아 있는 워커의 claim 을 떼는 것은 되돌릴 수 없다).

**2) 위 1) 의 반송 게이트를 `ok` 로 통과했으면 `$SCRIPTS/finish-classify.sh <repo> <pr>` 로
결정적 분류** — 이 헬퍼가 최신
`머지 판정:`/`검증자 리뷰:` 코멘트와 `STALE_FINISH_MIN` 시간버퍼로 상태를 낸다(손수
코멘트 파싱 대신 테스트된 헬퍼 재사용). **살아있는 워커·시간버퍼 미도달은 `active` 로
걸러져 레이스가 방지된다** — 별도 신선도 게이트가 필요 없다:

| finish-classify 출력 | 뜻 | 조치 |
|---|---|---|
| `done_verdict` | 최신 `머지 판정: ✅` **이고 그 판정이 현재 head 커밋 이후임이 증명됨**(#171) | eligible.sh 정상 경로가 처리 — 스윕은 skip |
| `stale_inline` | 🔄 + 검증자 CLEAN + 버퍼 초과 (검증까지 도달·최종판정만 유실, #970형) | **입양(머지)** — ② Pick 후보로. ③ 1단계가 **독립 재검증** 후 마감. **새 이슈 안 만듦**(완료된 일 재수행 금지). 단 위 1) 의 `bounced` 갈래에서 나온 `stale_inline` 은 **입양하지 않고 재디스패치**한다(그 CLEAN 이 반송 이전 회차의 것일 수 있다). |
| `stale_reverify` | 🔄 + 검증자 부재/미해결 BLOCKER + 버퍼 초과 + **진행 증거 없음**(#206) (검증 전 사망·구현 미완 가능, #971형). CONFLICTING + 반송 마커 최신인 PR 이 여기로 오면 그게 위 1) 의 "반송 뒤 ✅ 직전 사망" 계급이다 | **재디스패치** — 미완 코드를 codex 재검증 하나로 자동 머지하지 않는다(사용자 결정). `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` (연결 이슈를 `agent-ready` 로 되돌리고 `agent:claimed`·단계 라벨을 뗀다) → 새 워커가 같은 브랜치서 검증자 재실행→체크박스→최종판정으로 완결. 멱등 마커(아래). — head 커밋이 신선하면(#110, 스테일 클록에 커밋 시각 합류) 코멘트가 낡았어도 `active` 로 떨어져 살아있는 attempt N+1 워커를 오분류하지 않는다. |
| `no_verdict` | `머지 판정:` 코멘트가 **0건**(🔄·✅·⚠ 어느 것도 없음) + **CI 초록**(실패 0 이고 미완료 0 — 도는 체크가 하나라도 있으면 이 계급이 아니다, #421) + 버퍼 초과 + **진행 증거 없음**(#396). 워커가 10단계(최종 판정) **전에** 죽은 형상 — CI 는 초록인데 판정이 없어 종전엔 세 레인 어디에도 안 들어갔다(issue-runner ② 는 "CI green·리뷰 없음" 무접촉, 이 표는 🔄/✅ 를 전제). 코멘트 **조회 실패**는 이 계급이 아니다(`active`) | **재디스패치** — 바로 위 행과 **같은 조치**다. `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` + 아래 멱등 마커(사인도 같다 — 검증 전 사망이다). 판정이 없는 코드를 codex 재검증 하나로 자동 머지하지 않는다. **연결 이슈가 없으면 무접촉** — 되돌릴 이슈가 없으므로 전이를 부르지 말고 ④ Report 에 한 줄로 올려 사람이 보게 하라. |
| `held` | 최신 `머지 판정: ⚠ 보류` (워커 명시 보류) | **정지(`hold:policy`)** — `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` (PR 과 연결 이슈 **양쪽**에 `hold:policy` 부착 + 단계 라벨 정리 — 연결 이슈가 없어도 PR 에 정지 신호가 남는다. **`needs-human` 은 안 붙는다**(#244) — 기계 정지는 사유 라벨 하나뿐이고, 사람 호출은 재개 스윕 ③ 의 재심이 "사람 몫 유지" 로 끝났을 때만 `transition.sh policy-kept` 가 붙인다), closeout 무접촉(자동 진행 안 함). |
| `active` | 진행 중·버퍼 미도달·우리 형상 아님, 또는 **✅ 의 신선도를 증명 못 함**(✅ 가 head 커밋보다 이르거나 두 시각 중 하나를 못 얻음, #171), 또는 **진행 증거가 있음**(커밋이 `STALL_MIN` 이내 · head SHA 의 CI 티켓이 큐에 살아 있음 · **현재 회차의 `agent:claimed` 가 타임박스 안에 붙었음** — 또는 그 판정 자체가 불가: queue.log 를 못 읽음·head 조회 실패·claim 조회 실패(`unknown`≠`none`), #206 · `progress-evidence.sh`). MERGEABLE 인 반송 회차는 1) 게이트에서 이미 무접촉으로 걸러져 여기까지 오지 않는다(#218) — 여기로 오는 반송 회차는 1) 의 **CONFLICTING 예외 갈래**로 들어온 것뿐이고(#206), 판정 실패도 거기서 이미 걸러졌다(#196) | **무접촉**(다음 틱). |

**flow:\* 보조 신호**: finish-classify 가 코멘트로 판정하지만, `flow:ready` 없이
`flow:codex`/`flow:ci` 만 있고 오래된 PR 은 그 자체로 "검증 중 워커 사망"의 방증이다
(라벨은 이 스킬 밖 워커 런타임이 세팅 — 있으면 보조로 참고, 없으면 finish-classify
결과만으로 판정).

**재디스패치 멱등 마커 (필수)**: `stale_reverify`·`no_verdict` 재디스패치 시 PR 에
`$SCRIPTS/bounce-comment.sh redispatch <repo> <pr> <이슈>` 로 코멘트를 남긴다(문구를
손으로 옮겨 적지 않는다 — 콜론·어순이 변형되면 `bounce-state.sh` 반송 안전망이 놓친다,
#212. 생성되는 본문은 `재디스패치: #<이슈> — 완결 유실(검증 전 사망) <!-- bodat:worker -->`).
**이 마커가 이미 있고 그 이후 새 커밋·검증자 코멘트가 없으면 재발행하지
않는다**(/loop 스팸 방지, 6단계 파생 마커 동형). 재디스패치 자격은 `open + agent-ready +
¬agent:claimed`(eligible-issues.sh)이라 `closeout-redispatch` 전이가 그 둘을 한 번에
맞춘다(손으로 `gh issue edit` 하지 마라). 위 두 전이 모두 **exit 1(readback 불일치)·
2(gh 실패)면 그 PR 의 종료 상태를 바꾸지 말고** ④ Report 에
`BLOCKED: 전이 실패 <전이> PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다(라벨이
반쯤 이동한 상태를 다음 틱이 잡게 하는 게 목적 — 조용히 넘어가지 않는다).
재디스패치가 성사되면 issue-runner Dispatch 가 make-worktree 로 기존 `agent/issue-N` worktree
를 재사용해 **같은 PR 브랜치에서 이어 완결**하므로 새 PR 이 생기지 않는다(중복 아닌 보수).

입양 후보(rebase·`stale_inline`)는 ② Pick 이 소비하고, 재디스패치·needs-human 건수는
④ Report 에 집계한다.

## ② Pick — 한 번에 1 PR (MAX_CLOSEOUT=1, 동시성 1)

`$SCRIPTS/closeout-eligible.sh` 출력(✅ 마킹된 정상 후보)과 **①-b 스윕의 입양
후보**(`stale_inline`·CONFLICTING)를 합쳐 FIFO **첫 후보 1개만** 집는다. 한 번에 1개라
모듈 겹침 판단은 불필요하다 (직렬 마감 — 이 PR 을 끝까지 마감한 뒤에야 ⑤ Drain 이
다음 후보를 집는다). 집으면 즉시
`$SCRIPTS/transition.sh closeout-pick <repo> - <pr>` 로 점유를 선언하라(이슈 번호는 ③-1
에서야 파싱되므로 여기선 `-`). 전이가 `harvesting` 을 붙이고 워커·verify-runner 단계
라벨(`flow:ready`·`flow:codex`·`flow:ci`·`flow:verify`·`verifying`)을 함께 뗀다 — `harvesting` 이 있어야
issue-runner ② Maintain·verify-runner 가 이 PR 을 건드리지 않고(verify-eligible 도
harvesting 을 제외한다), PR 리스트에서 `harvesting` 하나만 남아 "마감 중"이 명확해진다.
후보가 0이면 ③ 파이프라인을 건너뛰고 ④ Report 에 clean no-op 으로 보고한다.

**라벨 부재 자동 보강은 전이가 한다.** 옵트인 레포여도 `setup-labels.sh` 재실행 전에는
`harvesting` 라벨이 없을 수 있는데(기존 레포 공통), `transition.sh` 가 `not found` 류
실패를 보면 `setup-labels.sh` 를 **프로세스당 1회** 돌리고 같은 편집을 **1회만** 재시도한다
(무한루프 금지). 그래도 실패하면 exit 2 로 떨어지니 이 PR 을 skip 하고 ④ Report 에
`BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 보고한다.

**원 이슈 미러(진행 가시화).** ③-1 에서 `<issue>`(PR 본문 `Closes #N`/`Refs #N`)를 파싱한
직후, 연결 이슈가 있으면 `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` 를
**다시** 부른다(멱등 — PR 쪽은 이미 맞아 no-op, 이슈 쪽만 `harvesting` 으로 옮겨진다).
**이 미러 호출이 exit 1(readback 불일치)·2(gh 실패)면 머지로 진행하지 마라** — 이 PR 을
skip 하고 ④ Report 에
`BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다
(PR 만 `harvesting` 이고 이슈는 아닌 반쯤 이동한 상태를 다음 틱이 잡게 한다).
이슈 리스트만 봐도 단계(검증→마감)가 보이게 하는 것이다(머지 성공 시 `Closes #N` 으로
이슈가 닫히므로 잠깐만 보인다). 그리고 ③ 이후 **fail-closed 로 손을 떼는 모든 지점**
(위임 fail·conflict 사람판단·문서 reconcile 미완 등)은 반드시 `closeout-blocked`(사람에게)
또는 `closeout-redispatch`(워커로 반송) **전이를 쓴다 — 손으로 `gh issue edit` 하지 않는다**.
PR·이슈 양쪽의 `harvesting`·`flow:*` 정리를 전이 표가 보장한다(스테일 단계 라벨 잔재 방지).
`closeout-blocked` 는 **`--reason <conflict|policy|ladder> [--note "<질문 한 줄>" — policy·conflict 필수]` 가 필수**다(없으면 usage
exit 64 — 사유 없는 정지를 만들 수 없다). rebase/semantic conflict 는
`conflict`(단 보안 경계·대범위 충돌은 `policy` — 2단계 CONFLICTING 항목의 판정, #344;
`conflict` 의 `--note` 는 질문이 아니라 워커 재개 범위 한 줄이다), 그 외 루프가 못 정하는 스펙·정책·검증 미산출은 `policy`, 사다리
(`~/.claude/skills/issue-runner/references/live-verification-ladder.md`)
의 칸을 실제로 올라가 실패 출력을 인용한 경우만 `ladder` 다.

**`$SCRIPTS/closeout-eligible.sh` 의 stderr `blocked:` 줄은 ④ Report 로 옮긴다**(issue-runner
`eligible-issues.sh` 의 `blocked:` 이관 규칙과 같은 꼴, #379). `✅ 이후 미해결 코멘트 N건` 은
"검증자가 확인한 경계(✅ 의 `코멘트 스냅샷 N`, 없으면 ✅ 자리) **뒤에** 사람 리뷰가 남아 있어
fail-closed 로 안 집었다"는 뜻이고(리터럴의 "✅ 이후" 는 이 경계를 가리킨다), 루프가 스스로 풀지
않는다(사람 코멘트를 기계가 '해결됨'으로 판정하면 fail-open) — 풀리는 길은 verify-runner 가
재검증해 새 ✅ 를 찍는 것(그 ✅ 직전 확인 단계가 사람 코멘트를 소화한다 — verify-runner ④
참조)뿐이다. 사람 답글은 풀지 않는다(그 답글도 무마커 코멘트다). 즉 사람이 할 일은 답을
남기는 게 아니라 PR 을 `flow:verify` 로 되돌리는(또는 `verifying` 재집) 것이다. 그 전엔
매 틱 같은 줄이 반복되는 것이 정상이다(조용한 탈락 금지, #379). 세는 경계는 ✅ 본문의
`코멘트 스냅샷 N`(있으면 그 N — verify-runner 가 코멘트를 읽은 시점이라 읽기~게시 사이에
낀 코멘트도 잡힌다, #384) 또는 스냅샷 토큰 없는 옛 ✅ 면 그 ✅ 의 인덱스다. `warn` 이 아닌 이유: warn 은 루프가 교정
가능한 불변식 위반에만 쓴다(`loop-status.sh` 정의) — 이건 정당한 미집계라 `막힘` 부류다.

## ③ 파이프라인 — 1~6단계

집은 PR 에 대해 아래 6단계를 순서대로 수행한다. 각 단계 끝에 마커 명령을 박아
(① Reconcile 마커표) 다음 틱이 멱등 재개할 수 있게 한다.

**1단계 — 계획 부합 검증 — `general-purpose` 한 번, codex 없음(#375).** `<issue>` 는 PR 본문의
`Closes #N` / `Refs #N` 줄에서 얻는다(`gh pr view <pr> --repo <repo> --json body` 로 파싱). 정확성 리뷰는
verify-runner 가 이미 codex 로 마쳤다(`머지 판정: ✅` 가 이 단계의 전제 — 그 코멘트의 `검증자 리뷰:` 에
BLOCKER 0 또는 `자체 리뷰(codex 2회 소진)`). 여기서는 **계획 부합만** 본다: 이 변경이 이슈 AC/플랜을
충족하는가, 범위 이탈은 없는가. 호출은 ## 상수 `VERIFIER`(general-purpose) 하나, 프롬프트는
`references/verifier-prompt-fallback.md` 의 placeholder 를 채운 것 — `<DIFF>`=`gh pr diff <pr> --repo <repo>`
출력, `<ISSUE_BODY>`=`gh issue view <issue> --repo <repo>` 출력(연결 이슈 없으면 빈 문자열),
`<PLAN_REF>`=이슈 `## Plan` 또는 참조한 `Plans/*.md`(없으면 빈 문자열), `<LESSONS_OR_"없음">`=
`$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑 **`.loop/lessons-verifier.md`**(검증 판정 사례집 — 과거 오판 패턴
주입; 없으면 `.loop/lessons.md` 폴백, 둘 다 없거나 비면 `없음`. `lessons.md` 는 **구현 워커**용이라 섞지
않는다). 지시문은 "계획/이슈 AC 충족 여부만 판정, 미충족·범위 이탈은 `[P1]`, 경미한 편차는 `[P2]`" 를
명시한다. 스폰은 `run_in_background` + `VERIFIER_TIMEOUT_MIN` 데드라인 + 초과 시 `TaskStop`. 데드라인
초과·verdict 없는 응답은 **미산출**이다 — 같은 프롬프트로 **한 번만** 재시도하고, 그래도 미산출이면 아래
ⓑ 로 보류 종료한다(fail-closed — 절대 머지로 진행하지 않는다, #96). 워크트리(`make-worktree.sh`)는 이
단계에 필요 없다 — 3단계가 자기 몫으로 확보한다.
`codex-review-gate.sh` 는 이 단계에서 부르지 않는다(bin/ci 가 이 문서에 그 호출이 0건임을 문다).
- 판정: BLOCKER → BLOCKER. CLEAN/NIT/WARN → 통과(`[P3+]` = NIT 는 비차단).
  머신 코멘트 마커(필수): 아래 `gh pr comment` 로 남기는 마감 검증 코멘트는 **마지막 줄에
  `<!-- bodat:worker -->`** 를 포함한다 — closeout-eligible 이 머신 코멘트를 사람 리뷰와
  구분하는 신호다(#72). 빠지면 그 PR 이 재평가 때, 이 코멘트가 최신 `머지 판정: ✅` 이후에
  있는 경우에만 미해결 사람 코멘트로 오인돼 탈락한다(✅ 이전 코멘트는 verify-runner 가 이미
  본 것으로 친다, #379).
- **중복 — 루프가 직접 닫는다 (사람에게 넘기지 않는다).** 검증자가 "이슈가 요구한 수정이
  **이미 `origin/main` 에 있다**" 또는 "이 PR 은 다른 PR 과 중복" 으로 판정하면 —
  BLOCKER 로도 CLEAN 으로도 취급하지 마라. 근거 커밋을 확인한 뒤(`git log origin/<default>`
  에서 그 수정을 담은 SHA) 한 줄로 닫는다:
  `$SCRIPTS/transition.sh closeout-dup <repo> <issue> <pr> --note "<근거 커밋·사유>"`
  — PR 을 머지 없이 닫고, 이슈에 근거를 남기고 닫으며, 단계 라벨을 정리하고 PR 에 `dup`
  라벨을 남긴다. **`needs-human` 을 붙이지 마라** — 중복은 루프가 결정할 수 있는 것이고,
  사람에게 던지면 사유 없는 `needs-human` 이 쌓인다(#4803 형: closeout 이 중복이라
  판정해 놓고도 닫지 않고 사람에게 넘겼다). → **dup 종료** (머지하지 않는다).
  **exit 1(readback 불일치)·2(gh 실패)면 그 PR 의 종료 상태를 바꾸지 말고** ④ Report 에
  `BLOCKED: 전이 실패 closeout-dup PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.
  판정이 "중복인 것 같다" 수준이면 dup 가 아니다 — 근거 커밋을 못 짚으면 아래 BLOCKER
  경로(`--reason policy`)로 간다.
- BLOCKER(미산출 포함, 사유 예 `검증자 미산출 — 타임아웃(>VERIFIER_TIMEOUT_MIN분)` / 모델 오류 원문)
  → **갈래가 둘이다. 판별 기준 한 줄: 구현으로 닫히는 결함이면 ⓐ 워커 레인 반송,
  스펙·정책 선택이 남아 있으면 ⓑ 사람 보류다.** (연결 이슈가 없으면 — PR 본문에
  `Closes`/`Refs` 가 없어 `<issue>` 를 못 얻으면 — 되돌릴 이슈가 없으니 ⓐ 는 불가, ⓑ 로 간다.)
- ⓐ **구현으로 닫히는 결함 → 워커 레인 반송**(실측 2회 — 이 갈래에 코멘트 채널이 없어
  마커를 손으로 적었다, #271).
  `$SCRIPTS/bounce-comment.sh closeout-blocker <repo> <pr> <issue> "<사유>"` 로 반송
  코멘트를 남긴다 — **문구를 손으로 옮겨 적지 마라**(콜론이 빠지거나 어순이 바뀌면
  `bounce-state.sh` 반송 안전망이 그 PR 을 못 보고, `closeout-eligible` 이 **반송 사유가 된
  코드에 대한 옛 ✅** 로 그 PR 을 다시 머지 후보로 올린다, #212 · #171). `<사유>` 는 워커가
  그대로 읽고 고칠 수 있게 무엇이 왜 막혔는지로 쓴다(`redispatch` 채널의 고정 문구를
  빌려 쓰지 마라 — 이 갈래에서 "완결 유실" 은 거짓이고, 거짓 사유는 다음 틱의 판정
  입력이 된다).
  **코멘트가 0으로 끝났다면 이어서** `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`
  로 연결 이슈를 `agent-ready` 로 되돌린다(`agent:claimed`·단계 라벨·`needs-human`·`hold:*` 를
  뗀다 — 손으로 `gh issue edit` 하지 마라) → **`blocked` 종료**(머지하지 않는다. 새 종료 상태를
  만들지 않는다 — ④ Report 에는 `재디스패치 N` 으로도 함께 집계한다). 재디스패치가
  성사되면 issue-runner Dispatch 가 같은 `agent/issue-N` worktree 를 재사용해 **같은 PR
  브랜치에서 이어 완결**하므로 새 PR 이 생기지 않는다.
  **exit 1(readback 불일치)·2(gh 실패)면 그 PR 의 종료 상태를 바꾸지 말고** ④ Report 에
  `BLOCKED: 전이 실패 closeout-redispatch PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올리고,
  **곧바로 `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` 를 한 번 더 걸어 PR 과
  이슈 양쪽의 점유를 되살려라**(③-1 의 원 이슈 미러와 같은 호출 — 멱등이고, 손으로 라벨을
  옮기지 않는다). 이 갈래엔 연결 이슈가 **항상** 있다(없으면 애초에 ⓑ 로 갔다) — 그러니
  ② Pick 의 `<repo> - <pr>` 형태로 부르지 마라. **PR 만** 되살리면 아래 (b)·(c) 에서 이슈 쪽
  점유가 빈 채로 남아 디스패처가 그 이슈를 집는다. 되살린 이슈에 `agent-ready` 가 남아 있어도
  무해하다 — `eligible-issues.sh` 는 플로우 라벨 미러(`harvesting`)를 **먼저** 배제하므로
  `agent-ready` + `harvesting` 이슈는 디스패치 자격이 없다.
  `transition.sh` 는 **양쪽 편집을 먼저 끝낸 뒤 readback** 한다(`run_edit` PR → `run_edit` 이슈
  → `verify_side` PR → `verify_side` 이슈). 그래서 실패 갈래가 셋이고, 위 한 호출이 셋 다를
  전이 이전으로 되돌린다:
  - **(a) PR 편집 성공 · 이슈 편집 실패(exit 2 — 편집 단계).** PR 엔 `harvesting` 없음 ·
    이슈는 손대지 않아 `harvesting` 유지. 디스패처는 이슈를 안 집지만 PR 을 회수할 레인이
    없다 — ①-b 는 반송 마커 때문에 `bounced` 로 무접촉이고 `closeout-eligible` 도 `bounced`
    를 뺀다. 회수 호출이 PR 에 `harvesting` 을 되붙이고 이슈 쪽은 멱등 no-op 이다.
  - **(b) 양쪽 편집 성공 · PR readback 불일치(exit 1).** 이슈는 **이미** `agent-ready` +
    `harvesting` 없음 + `agent:claimed` 없음 — 곧 디스패치 자격을 갖춘 상태다. 이대로 두면
    다음 틱에 워커가 그 이슈를 집어 closeout 과 같은 브랜치를 동시에 들고, 그다음 틱의
    `closeout-redispatch` 재시도가 **살아 있는 워커의 `agent:claimed` 를 뗀다**. 회수 호출이
    PR·이슈 양쪽에 `harvesting` 을 되붙여 그 자격을 다시 닫는다.
  - **(c) 양쪽 편집 성공 · 이슈 readback 실패(exit 1 불일치 · exit 2 조회 실패).** 라벨은
    (b) 와 같거나(불일치) 미상(조회 실패)이라 (b) 의 경합이 열려 있을 수 있다. `harvesting`
    부착은 멱등이므로 (b) 와 **같은 한 호출**로 닫힌다 — 상태를 먼저 조회해 갈라 부르지 마라.
  셋 다 점유가 전이 이전으로 돌아가면 다음 틱 ① Reconcile 이 그 PR 을 `resume` 으로 다시
  집는다. **그 재개 지점은 마커표가 아니라 반송 마커가 정한다** — 이 갈래는 1단계 마커
  `마감 검증: ✅` 를 스스로 남기지 않지만 **이전 회차가 남긴 마커가 이미 있을 수 있어**,
  마커표로 가면 방금 BLOCKER 를 낸 head 가 2단계 머지 게이트 앞에 서게 된다(그 게이트 조건은
  반송 직전 상태 그대로 전부 참이다. 1단계 마커 판정 (A)·(B)·(C) 가 그 대부분을 다시 ③-1 로
  돌려보내지만, 여기선 **애초에 마커표를 보지 않는 것**이 먼저다 — 반송 회차의 주인은
  워커 레인이지 마감 레인이 아니다). 그래서 ① Reconcile 의
  `resume` 값표대로 간다 — `bounce-state.sh` 가 `bounced` 인 한 마커표를 보지 말고 **바로 위
  전이 호출 자리**에서 이어가, 같은 자리에서 같은 전이를
  다시 건다 — `closeout-redispatch` 는 멱등이라 재실행이 무해하다(#157 이 `--note` 전이에
  세운 "실패는 전이 이전 상태를 남기고 호출부가 다음 틱에 같은 전이를 다시 건다" 를 이
  갈래에서도 성립시키는 것이다 — 되살리기까지 실패하면 ④ Report 의 두 `BLOCKED` 줄이 그대로
  사람 신호다).
  **코멘트가 비0으로 끝나면(gh 실패·인자 오류) `closeout-redispatch` 를 하지 마라** —
  이슈만 `agent-ready` 로 돌아가고 PR 에는 반송 마커가 없는 상태가 되어, 반송 안전망이 그 PR 을
  못 보고 `closeout-eligible` 이 옛 ✅ 로 다시 집어 온다(이 갈래가 막으려던 바로 그 상태).
  **대신 이 회차를 ⓑ 로 접는다.** 반송을 원장에 못 남겼으니 워커 레인에 돌려줄 수 없고,
  그렇다고 이번 틱의 BLOCKER 를 없던 일로 둘 수도 없다:
  `$SCRIPTS/transition.sh closeout-blocked <repo> <issue> <pr> --reason policy --note "반송 코멘트 게시 실패 — <stderr 한 줄>"`
  로 **사람 보류**로 내린다 → **`blocked` 종료**(새 종료 상태를 만들지 않는다. 사유 열거는
  `conflict|policy|ladder` 셋뿐이고 사람이 판단해야 하므로 `policy` 다 — 진짜 사유는 `--note`
  가 나른다). ④ Report 에는 `BLOCKED: 반송 코멘트 실패 PR #<pr>(<repo_short>) — <stderr 한 줄>`
  로 올린다. **왜 코멘트가 아니라 라벨로 남기나**: 코멘트 채널이 방금 실패한 마당에 같은
  채널로 상태를 남기면 같은 이유로 또 실패한다. `transition.sh` 는 라벨 편집이라 독립이고,
  `needs-human` 은 `closeout-eligible`·①-b 대상 필터·① Reconcile(`human_hold`) **세 입구를
  한꺼번에** 닫아 옛 ✅ 로 재상정되는 경로를 없앤다.
  **그 전이까지 비0이면** 그 PR 의 종료 상태를 바꾸지 말고 ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>` 을 한 줄 더
  올린 뒤 **이 틱에서는 그 PR 을 더 건드리지 마라**. `harvesting` 이 그대로 붙어 있으므로
  다음 틱 ① Reconcile 이 `resume` 을 내는데, 원장에 반송 흔적이 없어 `bounce-state.sh` 는
  `ok` 를 내므로 그 `resume` 은 **마커표 경로**로 간다 — 거기서 ③-1 이 다시 도는 것을
  보장하는 것은 반송 마커가 아니라 **1단계 마커 판정**이다(위 "1단계 마커는 '있으면 끝'이
  아니다" 절 — 이전 회차의 `⚠ 보류` 는 (A) 로, 새 커밋 뒤의 옛 마커는 (B) 로, 반송 앞의
  마커는 (C) 로 걸러져 `closeout-step1-marker.sh` 가 `verify` 를 낸다).
  **남는 칸을 숨기지 않는다**: 이 이중 실패(같은 틱에 코멘트 게시와 라벨 전이가 둘 다
  실패) 뒤에도 원장에 **현재 head 에 대한 `마감 검증: ✅`** 가 살아 있으면 1단계 판정은
  `skip` 이고, 그 head 는 2단계 게이트가 다시 판정한다. 그 칸까지 닫으려면 이번 틱의
  BLOCKER 를 적을 **세 번째 채널**이 필요한데 두 채널이 이미 실패한 상황에서 셋째가
  성공한다는 근거가 없다 — 그래서 ④ Report 의 두 `BLOCKED:` 줄이 사람 신호다(위 (a)·(b)·(c)
  회수 절이 "되살리기까지 실패하면 두 `BLOCKED` 줄이 사람 신호" 로 세운 규율과 같다).
- ⓑ **스펙·정책 선택이 남아 있다(검증자 미산출 포함 — 재시도 1회 뒤) → 사람 보류.**
  `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <사유>
  <!-- bodat:worker -->"`
  + `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  (PR 의 `harvesting` 제거 + PR 과 연결 이슈에 `hold:policy` 부착·단계 라벨
  정리 — `needs-human` 은 안 붙는다, #244) → **blocked 종료** (머지하지 않는다). 이 갈래로 온 BLOCKER·미산출은 스펙/정책
  판단이 필요한 것이므로 사유는 `policy` 다(`conflict` 도 `ladder` 도 아니다).
  검증자 미산출은 **언제나 이 갈래다** — 무엇을 고쳐야 하는지 자체가 없으므로 워커에게
  반송할 사유를 적을 수 없다.
  **exit 1(readback 불일치)·2(gh 실패)면 그 PR 의 종료 상태를 바꾸지 말고** ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다
  (라벨이 반쯤 이동한 상태를 다음 틱이 잡게 하는 게 목적 — 조용히 넘어가지 않는다).
- CLEAN/WARN → `gh pr comment <pr> --repo <repo> --body "마감 검증: ✅ <CLEAN 또는 WARN n>
  <!-- bodat:worker -->"`
  (이 코멘트가 1단계 완료 마커다).
- **거짓 BLOCKER 반전 기록 (lessons).** 이 PR 에 이전 틱의 `마감 검증: ⚠ 보류 — …`
  BLOCKER 코멘트가 이미 있는데(직전 BLOCKER) 이번 재검증이 CLEAN/WARN 이거나 사람이
  `needs-human` 을 떼고 원안 그대로 흐른 경우 — 그 BLOCKER 는 거짓 판정으로 뒤집힌
  것이다. `$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑 **`.loop/lessons-verifier.md`** 에
  `- [YYYY-MM-DD PR#<pr>] <거짓 BLOCKER 패턴 → 재발 방지 행동>` 1줄을 append 하고 캡까지
  정리한다 — **`$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"` 한 자리로 부른다**
  (파일이 없으면 새로 만든다 — 이건 검증자용이라 워커용 `lessons.md` 와 섞지 않는다).
  **append 를 이 호출 밖에서 손으로 하지 마라** — 다른 틱이 같은 파일을 동시에 정리 중일
  수 있고, 잠금 밖에서 한 append 는 그 정리의 read→write 창에 겹치면 유실된다(#208
  재검증 BLOCKER②). **캡: 항목 20개** — 초과 시 **항목 수가 캡 이하가 될 때까지** 가장
  오래된 항목부터 통째로 삭제한다(줄 단위가 아니다. 이 파일에는 `##` 로 시작하는 여러
  줄짜리 사례가 섞여 있어 줄을 자르면 산문이 찢어진다. 항목 = `- [` 로 시작하는 한 줄,
  또는 `##` 헤더부터 다음 항목 직전까지). #208: 옛 규칙은 "가장 오래된 항목 **하나만**"
  삭제라 append(+1)·삭제(-1) 순증이 0 이라서 한 번 캡을 넘으면 영원히 안 줄었다.
  이 기록은 위 `<LESSONS_OR_"없음">` 주입으로 다음 검증에 되먹여져 같은 오판(인용
  오판·base 맹점 등)의 재발을 막는다. (반전이 아니면 — 정상 CLEAN — 기록하지 않는다.)

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
  판정하기 **전에** 현재 HEAD 를 재검증한다: `$SCRIPTS/make-worktree.sh --sync <repo> <N>`
  한 호출로 worktree 를 확보하고 **rebase된 원격 head 로 강제 동기화**한다
  (`<N>`=PR head `agent/issue-N` 파싱, 3단계와 동일. `fetch` + `reset --hard origin/<branch>`
  절차와 "기존 worktree 는 그대로 반환되어 rebase 전 SHA 가 체크아웃된 채일 수 있다" 는
  함정은 그 스크립트 머리 주석이 SSOT 다 — #445). 3단계와 달리 이 경로는 새 커밋을 안 만들어
  **동기화가 freshness 의 유일한 보장**이다: 맞추는 SHA 가 `closeout-ci-pass.sh` 가
  `gh pr view headRefOid` 로 조회하는 바로 그 SHA 이고, 안 맞추면 run-local-ci 가 옛 SHA 를
  캐시해 영구 exit 2 로 남는다. `--sync` 가 **exit 3(worktree 에 미커밋 변경 — 덮지 않았다)**·
  **exit 4(원격에 그 head 브랜치 없음)** 면 머지하지 말고 이 PR 을 skip 해 ④ Report 에
  `BLOCKED: worktree 동기화 실패 PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.
  이어 `$SCRIPTS/run-local-ci.sh <repo> <N>` 로 **현재 HEAD** 캐시를 채운다. `run-local-ci.sh`
  가 비0(새 base 와의 통합이 깨짐)이면 머지하지 말고 fail-closed 로 보류 종료한다
  (`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` +
  `blocked` 종료, 새 종료 상태 안 만듦 — 이 전이가 exit 1·2 면 ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다).
  0이면 캐시가 pass 로
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
경로 — `closeout-blocked … --reason policy` 전이 + `blocked` 종료, 새 종료 상태를
만들지 않는다).
**`gh pr merge` 성공 직후** `$SCRIPTS/cleanup-worktree.sh <repo> <N> --merged` 를
호출해 이 PR 의 worktree(`agent/issue-<N>`)를 직접 정리한다 (`<N>`=PR head
`agent/issue-N` 파싱, 3단계와 동일). 머지를 독점하는 closeout 이 머지 시점에 스스로
거두므로 issue-runner reconcile 에 의존하지 않는다 — closeout-only 세션서도 적체가
없다. `--merged` 는 squash 머지로 원격 head 가 자동삭제돼 `@{u}` 가 사라지는
함정에서 미push 가드를 완화한다(더티 가드는 유지 — 더티면 warn 후 보류, best-effort).

- **CONFLICTING → closeout 이 직접 rebase 해서 진행한다** (conflict-rebase 소유는
  issue-runner Maintain 에서 closeout 으로 이관됨). skip 하지 않는다 — conflict 는
  **머지 단계에서 잡아야** 하고 그 책임이 이 루프에 있다. `harvesting` 점유를 유지한 채:
  `$SCRIPTS/make-worktree.sh <repo> <N>` 로 worktree 확보(`<N>`=head `agent/issue-N`) →
  `git -C <wt> fetch origin` → `git -C <wt> rebase origin/<BASE>`(`<BASE>`=default
  branch). **conflict 가 나면 rebase 보수 에이전트를 동기 스폰**한다(worker-template
  `~/.claude/skills/issue-runner/references/worker-template.md` 를 읽어 placeholder 를
  채우되 "절차" 지시를 "이 worktree(`<WT_PATH>`)에서 `origin/<BASE>` 위로 rebase,
  conflict 를 원안 의도대로 해소, `git push --force-with-lease`, **merge 커밋 금지**.
  **못 풀면 `git rebase --abort` 후 종료 보고에 ⑴ 충돌 파일 목록(경로 전부) ⑵ 왜 rebase
  범위를 넘는지 — 필요한 추가 작업(예: 새 분기에 가드 + 무는 테스트 1건)을 적어라**" 로
  교체하고 push 규율·금지는 유지. 에이전트의 범위는 종전대로 "리베이스와 그 결과로
  깨지는 테스트 정합만" — 기능 추가는 워커 회차의 일이고, 그 종료 보고 두 항목이 아래
  홀드 사유 판정의 입력이다) → 에이전트 종료 후 `$SCRIPTS/run-local-ci.sh <repo>
  <N>` 로 rebased HEAD 캐시를 재생성한다. 비0(새 base 통합 깨짐)이면 머지하지 말고
  **위임 fail-closed**: `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`
  로 연결 이슈를 `agent-ready` 로 되돌려(또는 spinoff) 넘기고 blocked 종료.
  0이면 위 exit 0 머지 게이트로 합류해 정상 squash 머지한다. 에이전트가 conflict 를 **못 풀면**(rebase abort·반복 실패) semantic
  conflict 는 closeout 이 직접 풀지 않는다(무인 강제 해소 금지) — 대신 **홀드 사유를
  가른다**(#344, 사람 결정 2026-09-12: 소규모·보안 경계 밖 충돌의 기본 답은 ⓐ 워커 한
  회차 — BoDAT #5103 2건·#185 셋 다 그 답이었다). 판정은 LLM 몫이라 여기 두고, 재개
  자체는 후속 resume-sweep(`hold:conflict` 1회 자동 재개)이 한다:
  - **`--reason policy`** (사람 몫 — 자동 재개 대상 아님) — 둘 중 하나면:
    ⓐ **보안 경계** — 충돌 파일이 인증·권한·세션·비밀(credential/secret)·외부 입력
    검증·트러스트 바운더리 경로에 걸친다. 레포 `CLAUDE.md` 가 보안 경계 경로를 지정하면
    그것을 쓰고, 없으면 파일 경로·이름에 `auth`·`session`·`secret`·`credential`·
    `permission`·`policy` 가 들어가거나 에이전트가 해소 중 그런 코드를 건드려야 한다고
    보고한 경우. ⓑ **대범위** — 충돌 파일이 **4개 이상**이거나 PR 고유 커밋이
    **6개 이상**(`git rev-list --count origin/<BASE>..HEAD`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
    — `--note` 는 종전대로 사람이 답해야 할 질문 한 줄이되 어느 기준(보안 경계 / 범위)에
    걸렸는지 명시한다(예: `보안 경계 — lib/auth/session.rb 충돌, 세션 만료 분기 어느 쪽?`).
  - **`--reason conflict`** (루프가 1회 자동 재개할 건) — 그 외 전부. `--note` 는 질문이
    아니라 **재개 워커가 받을 범위 한 줄**(워커 재개 범위 문형)로 쓴다 — 후속 디스패처가
    이 노트를 재개 워커 프롬프트에 그대로 인라인하므로 워커가 무엇을 해야 하는지는 이
    한 줄이 유일한 지시다. 문형:
    `충돌 <상대 PR #M>·<파일 목록> — 워커 재개 범위: origin/<BASE> 위로 rebase 해 원안 의도대로 해소 + <에이전트가 보고한 추가 작업>`
    (예: `충돌 #5114·client.rb, client_test.rb — 워커 재개 범위: origin/main 위로 rebase 해 원안 의도대로 해소 + proxy_push 분기 before_send: guard + 무는 테스트 1건`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason conflict --note "<워커 재개 범위 한 줄>"`
    에이전트 종료 보고에 충돌 파일 목록이 없으면(판정 입력 부재 — 노트를 채울 수 없다)
    "그 외" 가 아니라 **`policy` 로 fail-closed** 한다(노트: `판정 입력 부재 — 에이전트가
    충돌 파일 목록을 보고하지 않음, 워커 재개인가 사람인가?`).
  어느 갈래든 blocked 종료한다(이 경로만 사유가 `conflict` 다). 두 전이(redispatch·blocked) 모두 **exit 1(readback
  불일치)·2(gh 실패)면 그 PR 의 종료 상태를 바꾸지 말고** ④ Report 에
  `BLOCKED: 전이 실패 <전이> PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.

**3단계 — 문서 reconcile (머지 전, PR 브랜치 커밋).** 1단계가 구현을 확인한
계획문서 절의 `- [ ]` 를 `- [x]` 로 바꾼다. PR 브랜치 worktree
(`$SCRIPTS/make-worktree.sh <repo> <N>` 로 확보 — `<N>`=PR head 브랜치
`agent/issue-<N>` 에서 파싱(`gh pr view <pr> --repo <repo> --json headRefName`), 멱등)
에서 커밋·push 하여 squash 머지에 포함시킨다 (main 직접 push 금지). epic 이 있으면
진행 롤업 코멘트를 남긴다.
- **표면 교정 흡수 (같은 커밋에 얹는다).** 1단계 검증자의 WARN/NIT 중 **표면 교정**
  부류는 6단계 파생 이슈로 넘기지 말고 **여기서 직접 고쳐** 이 커밋에 같이 싣는다.
  이미 PR 브랜치 worktree 를 잡았고 아래 캐시 보강이 새 SHA 로 로컬 CI 를 다시 돌리므로
  **추가 사이클이 0**이다 — 반면 이슈로 내보내면 디스패치→구현→검증→마감 한 바퀴가
  한 줄 고치자고 통째로 돈다.
  **판정 기준 한 줄: 이 변경으로 통과/실패가 바뀌는 테스트가 하나도 없는가.**
  없으면 여기서 고치고, 하나라도 있으면 6단계 이슈다. 이 기준이 받는 것 — 주석 문장,
  용어·표기 통일, 주석 안의 수치·좌표, 죽은 참조 제거, **테스트 이름**(`test "…"` 의
  설명 문자열은 실행되지만 통과/실패를 안 바꾼다). 이 기준이 막는 것 — 새 단언·새
  가드·커버리지 추가·상수값·실행 분기. "주석만 고치는 김에 단언 하나" 는 이슈다.
  - 고친 것을 **원본 PR 코멘트에 명시**한다: `표면 교정(closeout 3단계): <파일> — <무엇을>`.
    자기가 고친 것을 자기가 머지하는 구조라 그 사실이 사람에게 보여야 한다.
  - 아래 캐시 보강이 비0(로컬 CI 실패)이면 **그 교정 커밋을 되돌리고** 원래 fail-closed
    경로로 간다 — 표면 교정이 머지를 막는 사유가 되어선 안 된다.
  - 검증자가 BLOCKER 를 냈거나 이 PR 이 보류·재디스패치로 가는 중이면 손대지 않는다
    (통과 판정 PR 한정 — verify-runner ⓪ 과 같은 규율).
- **캐시 보강 (push 직후, 옵션1).** doc 커밋을 push 했으면 **그 직후**
  `$SCRIPTS/run-local-ci.sh <repo> <N>` 를 1회 호출한다 (`<N>`=위에서 파싱한 이슈
  번호 — worktree 경로 `issue-<N>` 식별용; `closeout-ci-pass.sh` 의 `<pr>` 와 다름).
  이 헬퍼가 worktree HEAD SHA 를 읽어 `repo-dir.sh` 로 **메인 레포 slug** 의 로컬 CI
  캐시(`<메인slug>/<SHA>.result`)를 채운다 — 2단계 머지 게이트(`ci-gate`·
  `closeout-ci-pass.sh`)가 읽는 바로 그 위치라, 워크트리 slug 에만 남아 영구
  cache-miss 로 fail-closed 되는 갭을 메운다. **호출 전 멱등 가드**:
  `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` 가 이미 pass(exit 0)면(이전 틱이 같은
  HEAD 를 이미 캐시함) `run-local-ci.sh` 를 재실행하지 않는다(헬퍼도 큐 dedup 으로
  같은 SHA 는 재실행하지 않지만, 호출 자체를 아끼려 호출측도 가드한다). `run-local-ci.sh` 가 비0(=bin/ci 실패)이면 캐시가 pass 로
  안 채워진 것이므로 머지하지 말고 fail-closed 로 보류 종료한다
  (`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` +
  `blocked` 종료, 기존 BLOCKER 경로 준용 — 새 종료 상태를 만들지 않는다. 이 전이가 exit 1·2 면 ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다).
- **단일 이슈 degrade**: `Plans/*.md`·`## Plan` 이 없으면 문서 편집을 skip 한다.
  epic 이 없으면 롤업을 skip 한다. 이슈 자체 체크박스만 reconcile 한다. 둘 다
  없으면 이 단계는 no-op — **새 doc 커밋·push 가 없으므로 위 캐시 보강도 건너뛴다**
  (채울 새 HEAD SHA 가 없다).

**4단계 — 배포 레인 인계 (dry-run).** **closeout 은 실 배포를 하지 않고 배포 대기
이슈를 deploy-cycle 루프에 넘긴다.** 이유는 사람 승인이 아니라 **레인 분리**다 —
배포·승격·실테스트·종료는 deploy-cycle 의 무인 사이클이 소유한다.
`references/deploy-check-issue.md` 를 채워(`<DEPLOY_CMD>`=레포 배포 엔트리포인트,
모르면 "레포 배포 절차"; `<VERIFY_URL>`=production 베이스 URL — 5단계 스모크가 몰
주소, 모르면 빈 줄로 둬 5단계가 URL 도달불가로 폴백; `<LIVE_CHECKS>`=PR test plan·
이슈 본문에서 "배포 후 라이브 검증"·하드웨어/실장비 검증 등 **머지 후에만 수행
가능하다고 표기된 항목** — 1단계 검증자가 머지 게이트에서 제외한 범위 밖 검증 항목의
유일한 이관 목적지다).

**`<LIVE_CHECKS>` 는 두 형태 중 하나여야 한다 — 산문 금지.**
- 배포 후 밟을 게 **하나도 없으면** 정확히 `없음` 한 단어. 뒤에 설명을 붙이지 마라.
- 있으면 **`- [ ]` 체크박스 목록**. 한 줄 = 배포 뒤 `e2e-test` 가 한 번 밟는 동작(deploy-cycle ⑤ 가
  배포를 끝내고 이 줄들을 `테스트` 이슈로 옮긴다 — BoDAT #5197).
  배경·근거·주의는 `## 변경 요약` 에 쓰고 여기엔 밟을 것만 남긴다.
- **실장비 줄은 접두 표식 `[칸 ③]` 필수** — `- [ ] [칸 ③] <동작>` 형태로 적는다.
  실장비 = 사다리 칸 ③(TEST 워커 프로필 #18 드라이런)으로만 밟히는 동작이라는 **성격
  규정은 표식을 대신하지 못한다**: 표식은 `없음`·`- [ ]` 와 **같은 등급의 형태 강제**다.
  5단계가 이 표식 하나로 실장비 항목을 판별하므로, 표식이 빠진 줄은 크롬이 밟는 일반
  항목으로 세어져 통과 처리되고 티켓이 TEST 워커를 한 번도 안 거친 채 닫힌다(#309).
  칸 ①② 를 시도했다 실패해 옮겨진 줄에 "TEST 워커" 라는 말이 없더라도 **밟는 칸이 ③ 이면 표식을
  붙인다** — 판별의 근거는 문장 뜻이 아니라 표식이다.
- **표식 없는 줄은 크롬이 밟을 수 있어야 한다.** 5단계는 표식 없는 줄을 크롬으로 밟아 보고,
  브라우저 밖 수단(워커 박스·`ssh`·서버 셸)이 필요해 시도조차 못 하면 pass 로 찍지 않고
  **보류로 센다**(아래 5단계 fail-closed 갈래) — 그러면 이 티켓은 닫히지 않는다. 칸 ③ 이
  아닌데 브라우저 밖 수단이 필요한 줄이면 그 수단을 줄에 적어 ⑦ 이 바로 밟게 하라.

형태를 강제하는 이유: 아래 분기가 이 절을 읽어 이슈 발행 여부를 가르는데, 자유 산문이면
그 판정이 매 틱 해석에 맡겨져 흔들린다(실측 2026-08-12~13: 배포검증 이슈 186건 중
**체크박스를 쓴 건 0건**, 전부 산문이었다). "없음. 주석 13줄이 전부다 — 관찰 가능한
변화가 없다" 같은 서술은 사람에겐 명확해도 기계 분기엔 `없음` 이 아니다.

**옮기기 전에 closeout 이 사다리를 한 번 올라간다 (시도 없는 `[ ]` 는 그대로 옮기지 않는다).**
워커가 남긴 미완 항목 중 **사다리 시도·인용 없이 `[ ]` 로만 남은 것**(PR test plan 에
시도한 칸도 실패 출력도 없는 항목)은 그대로 이 절에 옮기지 마라 — 그렇게 옮기면 아무도
시도하지 않은 일이 그대로 배포 레인으로 떠넘겨진다. closeout 이
`~/.claude/skills/issue-runner/references/live-verification-ladder.md`
의 **칸 ①(dev 서버 — `bin/rails runner`·localhost)와 칸 ②(`bin/dry-run`·AdsPower 릴레이)**
를 **한 번씩** 시도한 뒤에 옮긴다. **칸 ③(TEST 워커)은 배포 뒤 `e2e-test` 의 몫이다** —
그래서 `<LIVE_CHECKS>` 로 옮기는 것이지 사람 몫으로 승격하는 게 아니다. ①② 시도 결과를
함께 남겨 ⑦ 이 같은 칸을 반복하지 않게 한다.
- 칸 ①② 에서 **판정이 서면** 그 항목은 `<LIVE_CHECKS>` 에서 **뺀다**(배포 레인이 밟을
  게 아니다). 판정 근거는 PR 코멘트에 남긴다.
- **실패하면** 항목을 `- [ ]` 로 옮기되, **시도한 칸과 실패 출력(명령 한 줄 + 마지막
  20줄)을 인용**한다. 인용은 `## 변경 요약` 절에 적는다 — `<LIVE_CHECKS>` 는 위 형태
  규율대로 **밟을 동작만** 남는 자리라 산문·출력이 들어가면 안 된다.
- 시도가 불가능한 환경이면(레포에 해당 진입점 없음 등) 그 사실을 `## 변경 요약` 에 한 줄로
  적는다. "실장비 필요" 라는 서술만으로 시도를 건너뛰지 마라.

**분기 — 머지했으면 무조건 승격 티켓을 만든다 (사용자 결정, 2026-08-16).**

**머지된 PR 은 예외 없이 배포 대기 이슈를 하나 발행한다.** 판정하지 마라 — 테스트
전용이든 주석 한 줄이든, 머지됐다는 것은 승격 범위에 들어갔다는 뜻이고 그 사실이
사람에게 보여야 한다.

- **발행 명령 (필수 형태 — 산문으로 대체하지 마라).** 발행 절차 전체 — 제목 형태 · 본문 절 ·
  라벨 · 라벨 부재 3단 사다리 · 발행 직후 라벨 readback · PR 마커 — 는
  **`$SCRIPTS/deploy-wait-issue.sh` 한 호출**이다(#446). 여기서 `gh issue create` 를 손으로
  조립하지 마라 — 이번 사고의 8/8 누락은 발행 명령이 산문 한가운데 있었기 때문이다:

  ```
  $SCRIPTS/deploy-wait-issue.sh <repo> <pr> --sha <머지 SHA> \
    --title "<요약 한 줄>" --summary-file <변경요약 파일> --items-file <항목 파일|없음> \
    [--verify-url <production 베이스 URL>] [--deploy-cmd <배포 엔트리포인트>] \
    [--parent-issue <부모 이슈#>] [--hardware]
  ```

  **제목 정규식(`배포 대기: PR #<M>`) · 절 이름(`## 검증 URL`·`## 라이브/하드웨어 검증 항목`) ·
  `없음` · `(승격만)` 은 deploy-cycle·deploy-bodat 이 읽는 파싱 계약**이고, 그 SSOT 는 이제 그
  스크립트의 머리 주석이다(여기 산문이 아니다 — 리터럴을 바꾸려면 그 소비자부터 고쳐라).
  하는 일: 항목 형태를 강제하고(체크박스 0인데 `없음` 도 아니면 **발행 전** exit 65) → 체크박스
  0이면 제목에 ` (승격만)` 을 붙이고 → `--label deploy-wait` (+ `--parent-issue` 로 상속한 P,
  `--hardware` 이고 **레포에 정의가 있을 때만** `needs:hardware`)로 발행하고 → 라벨 부재면
  `setup-labels.sh` 1회 + 재시도 1회 → 그래도 안 되면 **`--label` 을 하나도 주지 않고 발행**해
  티켓 유실을 막고(`loop-status.sh` 는 제목 `배포 대기:` 폴백으로 여전히 배포대기로 센다) →
  라벨을 readback 해 보강하고 → PR 에 `배포 대기: #<번호>` 마커를 남긴다. stdout 은 이슈 번호
  한 줄이다. `<VERIFY_URL>` 을 모르면 `--verify-url` 을 생략한다(5단계가 URL 도달불가로 폴백).
  - **exit 0** → 마커까지 남았으므로 **approval-required 로 종료**한다.
  - **exit 65 (발행 전 형태 위반 — 이슈는 아직 없다)** — `<LIVE_CHECKS>` 가 산문이라는 뜻이다.
    배경·근거는 `## 변경 요약` 으로 옮기고 항목 자리엔 `없음` 이나 `- [ ]` 만 남겨 **다시 부른다**.
  - **exit 1 (이슈 미생성)** — ④ Report 에 `BLOCKED: 배포 대기 이슈 발행 실패 — PR #<pr>` 로
    올린다. 머지된 PR 이 티켓 없이 끝나면 승격 범위가 사람 눈에서 사라진다.
  - **exit 2 (이슈는 생성됨 — 번호는 stdout)** — 라벨·마커가 어긋났다. 그 상태는 정상이 아니다
    (deploy-cycle 이 레인 표식으로 못 찾는다). ④ Report 에
    `BLOCKED: 배포 대기 이슈 deploy-wait 라벨 부착 실패 — #<번호>` 로 올리고 사람에게 **3단 복구**를
    요구한다(둘째 단을 빠뜨리면 첫째 단만으로는 그 티켓이 계속 무라벨이다 — `setup-labels.sh` 는
    라벨 *정의* 만 만들 뿐 기존 이슈에 부착하지 않는다): ⑴ **`$SCRIPTS/setup-labels.sh <repo>`
    재실행** ⑵ `gh issue edit <번호> --repo <repo> --add-label deploy-wait` 로 **그 이슈에** 부착
    ⑶ `gh issue view <번호> --repo <repo> --json labels` 로 확인. 여기서 같은 라벨 편집을 겹쳐
    시도하지 마라(#223) — 또 실패하면 그 실패에 걸려 마커·보고가 끊긴다(티켓은 만들어졌는데
    아무도 모르는 상태 = 폴백이 막으려던 바로 그 유실). 조용히 넘어가지 마라.

  `deploy-wait` 는 `loop-status.sh` 가 배포대기와 needs-human 을 갈라 세는 버킷 라벨이자
  **deploy-cycle 루프가 이 티켓을 집는 레인 표식**이다 — 이 라벨 하나가 필수다.
  **closeout 은 `needs-human` 을 붙이지 않는다 (#243, 플랜 2단계) — 되돌리지 마라.** 발행 시점엔
  사람 몫이 없다: ⑴ 디스패치 게이트는 `label:agent-ready` 를 **요구**하는데
  (`scripts/eligible-issues.sh`) 배포 대기 이슈엔 그게 없어 애초에 후보가 아니고, ⑵ deploy-bodat
  수집은 라벨이 아니라 **제목 정규식**(`배포 대기: PR #<M>`)이다. 붙이면 `needs-human` 의 뜻(=사람
  몫이 남음)을 흐리는 중복 표식이 된다(#190). 그 라벨을 **붙이는 주체는 deploy-cycle** 이다 —
  승격·배포·스모크 실패에 사유 코멘트와 함께(BoDAT #5197, 숨은 정지 파일 폐지). 그래서 loop-status
  버킷은 needs-human 이 배포대기보다 **앞**이다(2026-09-13) — 그 실패 표식이 배포대기 칸에 숨지 않게.

이 규칙이 뒤집힌 이유: 직전 규칙은 `<LIVE_CHECKS>` 가 `없음` 이면 이슈를 안 만들고
"미승격 현황은 ④ Report 의 `승격 대기 N커밋` 이 갖는다" 로 정당화했다. 그런데 그
Report 줄이 실제로는 누락되기 쉬워서(실증 2026-08-16: 3건 연속 마감에 이슈도 없고
숫자도 없어 마감분이 증발한 것처럼 보였다) **승격할 게 있는지조차 모르는** 상태가
됐다. 원장을 보고에만 맡기지 않고 이슈로도 남긴다.

**단, `<LIVE_CHECKS>` 의 형태 규율은 그대로다** — 이슈 발행 여부를 가르지 않을 뿐,
5단계 스모크 여부는 여전히 이 절이 가른다:

- **체크박스가 하나라도 있으면** 그 목록이 이슈가 닫히는 조건이고, 5단계가 그것을
  Chrome 스모크로 대조한다.
- **`없음` 이면** 이슈 제목에 `(승격만)` 을 붙이고 본문 `## 라이브/하드웨어 검증 항목`
  에 `없음` 을 그대로 둔다. **5단계 스모크는 건너뛴다** — 대조할 항목이 0인 스모크는
  통과시킨 게 아니라 아무것도 안 본 것인데 `✅ 스모크 0/0 통과` 로 찍히면 검증된
  것처럼 읽힌다(거짓 초록). 이 이슈는 deploy-cycle 레인이 승격을 마치면 닫는다.

**묶지 않는다.** 여러 배포 대기 이슈를 하나로 합치지 마라 — 항목이 계속 붙는 장수 이슈는
닫히는 시점이 사라져 "끝나지 않는 이슈" 가 된다(사용자 결정, 2026-08-13). 개수가 늘어도
**한 PR = 한 티켓 = 닫히는 시점이 명확한 그릇** 을 유지한다.

**5단계 — 배포 후 처리 (Chrome 스모크).** **배포 완료가 보고된** 배포 이슈에 대해
(누가 보고했는지는 묻지 않는다 — 새 모델에서 배포 보고는 deploy-cycle 레인이 남긴다)
새 감지 기구 없이(폴링/타이밍 미도입) 능동적으로 Chrome 스모크를 돌려 판정한다.
배포 이슈 본문에서 `## 검증 URL`(`<VERIFY_URL>`)과 `## 라이브/하드웨어 검증 항목`
(`<LIVE_CHECKS>`)을 파싱해 `references/smoke-prompt.md` 의 placeholder 에 채우고
(**그 절을 손대지 말고 그대로 치환한다 — 표식 줄을 미리 걸러 내지 마라.** 프롬프트가
`[칸 ③]` 표식 줄을 밟지 않고 `보류` 로 적어 내고, **세는 일은 `$SCRIPTS/smoke-tally.sh`
하나가 한다**(#448) — 치환 전에 한 번 더 거르면 실장비를 세는 계산기가 둘이 된다),
chrome-devtools MCP 도구를 ToolSearch 로 로드하고, **진입 정리(멱등 — 크래시 재개 방어):
`list_pages` 로 이전 틱이 정리 전에 죽어 남긴 스모크 페이지가 있으면 `close_page` 로
먼저 닫는다.** 이어 `navigate_page` 로 `<VERIFY_URL>` 에
진입한 뒤 각 항목을 `evaluate_script`/`take_snapshot` 으로 대조해 항목별 pass/fail 을
산출한다 (구조/빈 상태 확인과 실 데이터 렌더 확인을 결과에 구분 표기).
- **집계는 `$SCRIPTS/smoke-tally.sh` 한 자리다 (#448).** 표식 판별·분모 제외·보류 합산의
  산술은 이 SKILL 도 프롬프트도 아니라 그 스크립트의 머리 주석이 SSOT 다 — 종전엔 같은 규칙이
  두 곳에 산문으로 있어 "실장비를 세는 계산기가 둘" 이었다. 여기서 손으로 세지 마라.
  - **스모크 전 — 밟을 게 있는가.** 배포 이슈의 `## 라이브/하드웨어 검증 항목` 절을 파일로
    써서 `$SCRIPTS/smoke-tally.sh --checks <절 파일>` 를 부른다. `steppable` 이 0이면
    **Chrome 을 띄우지 말고** 코멘트 `스모크 생략: 밟을 항목 0` 을 남기고 완료로 넘긴다
    (`없음` 절도, 표식 줄만 남은 절도 여기서 0이다 — 대조할 항목이 0인 스모크는 무엇을
    통과시킨 게 아니라 **아무것도 안 본 것**인데 `✅ 스모크 0/0 통과` 로 찍히면 검증된 것처럼
    읽힌다. 거짓 초록). 그 이슈는 deploy-cycle 레인이 승격을 마치면 닫는 그릇이지 검증
    대상이 아니다.
  - **스모크 후 — 무엇을 봤는가.** 프롬프트가 낸 **판정 줄만**(`<판정> <원본 항목 줄>` —
    어휘는 `pass`·`fail`·`보류` 셋뿐, 문법은 스크립트 머리 주석) 파일로 모아
    `$SCRIPTS/smoke-tally.sh <결과 파일>` 를 부르고 아래 갈래를 그 JSON 으로 가른다:
    `verdict`(`green`|`fail`|`held`|`skip`) · 분모 `denominator` · 보류 `held`(내역
    `held_marked`·`held_unstepped`). **`verdict` 만 보지 마라** — fail 과 보류는 동시에 참일
    수 있어 fail 갈래에서도 `held` 가 남으면 이슈를 닫지 않는다. `unparsed` 가 0이 아니면
    프롬프트가 문법 밖 줄을 낸 것이다(그 줄은 보류로 세어져 그 틱은 green 이 될 수 없다) —
    ④ Report 에 한 줄로 올린다.
- **실장비 항목이 남아 있으면 green 이어도 닫지 않는다 (칸 ③ 은 크롬이 못 밟는다).**
  판별은 접두 표식 `[칸 ③]` **하나로만** 한다 — 4단계가 그 표식을 `없음`·`- [ ]` 와 같은
  등급으로 **형태 강제**하므로 판별 술어를 여기서 새로 만들지 마라. 근거(왜 그 줄이 실장비인가)는
  표식이 가리키는 동작이 사다리 칸 ③(TEST 워커 프로필 #18 드라이런)이라 크롬이 못 밟는다는
  것이다 — 근거는 근거로 남기고 **판별은 표식으로** 한다. 문장 뜻을 해석하면 같은 줄이 틀마다
  실장비로도 일반 항목으로도 읽혀 판정이 흔들린다(#309). `held` 가 0이 아니면 나머지가 전부
  통과해도 배포 이슈를 닫지 말고
  `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다`(`<n>`=`held`)
  코멘트로 끝낸다 — 칸 ③ 은 배포 뒤 `e2e-test` 의 몫이라, 여기서 닫으면 실장비 항목이 든
  티켓이 TEST 워커를 한 번도 안 거치고 종결된다. 그 이슈는 deploy-cycle 레인의 ⑦ 이 칸 ③ 을
  밟고 닫는 그릇이다.
  - **표식 없는 줄의 보류는 관측이지 해석이 아니다.** 표식 없는 줄은 프롬프트가 **일단 밟아
    본다** — 밟았는데 기대와 다른 값이 나왔으면 `fail`(크롬이 화면·값을 실제로 봤으므로 진짜
    결함 → 아래 fail 갈래), 밟을 수단이 브라우저 밖(워커 박스·`ssh`·AdsPower 클라이언트 조작 ·
    서버 셸 `bin/rails runner` · `log/*.out` grep)이라 **시도조차 못 했으면** `보류`
    (=`held_unstepped`). 줄의 뜻을 읽어 실장비로 승격하지 마라 — 그 순간 계산기가 둘이 된다.
    **그 보류에 후속 이슈를 발행하지 마라** — 결함이 아니라 밟는 레인이 다를 뿐인데 fail 로
    떨어뜨리면 `needs-human` 후속 이슈가 나고 사유도 '스모크 실패' 로 잘못 기록된다
    (#309 attempt 1 이 정확히 그렇게 샜다). 이 규율보다 먼저 발행된 재고엔 `[칸 ③]` 이 아예
    없고, 그 재고에서 실장비 줄만 골라내는 **고정 문자열은 존재하지 않는다**(열린 재고 10건의
    `- [ ]` 27줄 전수 실측 2026-09-12: `TEST 워커 프로필 #18` 은 0줄 · `TEST 워커` 는 실장비
    6줄 중 1줄 · `워커` 는 실장비 아닌 줄까지 물면서 `ssh test` 로 밟는 줄은 놓친다 — 어느
    문자열도 **양방향으로** 틀리고, 더 지우는 방향으로 틀린 근사는 원래 버그보다 나쁘다).
    그래서 판별을 문자열이 아니라 **밟아 본 결과**에 건다.
  - **표식을 대신 붙이지 마라.** 보류로 센 줄이 전부 칸 ③ 인 것은 아니다(서버 셸이면 족한
    줄도 섞인다). 마커 문구는 하나로 두되, 내역은 스크립트가 낸 수로 한 줄 남긴다:
    `보류 내역: 표식 <a>건 · 표식 없는 미밟음 <b>건 — 재고 · 4단계 표식 누락 · 또는 4단계가 수단을 적어 보낸 비-칸③ 줄`
    (`<a>`=`held_marked` · `<b>`=`held_unstepped`). **셋째 부류**를 남기는 이유: 4단계가
    칸 ③ 은 아니지만 브라우저 밖 수단이 필요해 그 수단을 줄에 적어 ⑦ 에 보낸 줄은 규율대로
    적힌 정당한 줄인데도 크롬이 못 밟아 여기 오는데, 그걸 '표식 누락' 으로 적으면 규율을 지킨
    4단계가 위반한 것으로 **오기록**된다(판정은 같고 기록만 틀리다). 그 둘을 뺀 나머지가 이
    갈래에 걸리면 그때가 **재고이거나 4단계 형태 규율 위반**이라는 신호다.
- **이미 닫힌 배포 이슈 — 스모크 생략.** 배포 이슈가 이미 CLOSED 이고 검증/배포 완료
  코멘트가 있으면 5단계 완료로 간주한다 — 재스모크하지 않고 다음 단계로 진행한다
  (배포 레인(deploy-cycle)이 배포·스모크를 마치고 닫은 경우 — 승격 모델 레포의 표준 종결.
  남은 검증 항목은 그때 `테스트` 이슈로 옮겨져 있다 — 5단계가 다시 밟지 않는다).
- **저하(degrade) — 조용한 skip 금지.** chrome-devtools MCP 가 세션에 없거나(헤드리스/
  크론 — 대화형 인증 MCP 부재 가능) `<VERIFY_URL>` 이 비었거나 도달 불가면, 스모크를
  건너뛰고 배포 레인(deploy-cycle)의 사람 보고 경로로 폴백하되 배포 이슈에 `스모크 skip: <사유>` 코멘트를
  남긴다(누락 은폐 금지).
  단 **"도달 불가" 는 마지막에만 쓴다** (#153): 크롬만 못 여는 주소가 있으므로,
  `<VERIFY_URL>` 이 안 열리면 skip 을 적기 전에 smoke-prompt 의 재시도 사다리를 먼저
  밟는다 — ① 그 레포의 원격 접근용 주소 ② SSH 터널. **둘 다 실패했을 때만** 도달 불가다. **브라우저를 아예 기동하지 않았으므로 정리 대상도 없다 —
  아래 브라우저 정리는 no-op(누수 아님).**
- **green (`verdict=green` — 전부 통과 + 보류 0)** → 배포 이슈 + 원본 PR 에 `✅ 스모크: <n>/<n> 통과`(`<n>/<n>` = `pass`/`denominator`) 코멘트(이
  코멘트가 5단계 완료 마커 — 재개 틱이 재스모크하지 않는다). 이어 배포 이슈에서
  `needs-human` 라벨을 제거하고 배포 이슈를 close 한다(남은 게이트가 검증뿐이고 그게
  통과했으므로 closeout 이 종결 — 미결 결정의 권장안). **단 위 실장비 예외에 걸리면
  close 하지 않는다** — 칸 ③ 항목(표식 줄 + 위 fail-closed 로 보류한 미밟음 줄)이
  `- [ ]` 로 하나라도 남아 있으면 라벨 정리까지만 하고
  이슈는 열어 둔 채 `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다` 코멘트로 끝낸다
  (남은 게이트가 검증만이 아니다 — 칸 ③ 이 남았다). 4단계 발행분엔 #243 이후
  `needs-human` 이 애초에 없다 — 이 제거는 그 이전에 발행된 옛 이슈용 무해한 잔여
  정리다(`--remove-label` 은 없는 라벨에 무해).
- **fail (`verdict=fail` — `fail` 이 한 건이라도)** — **크롬이 밟은 줄만 여기 온다.** 위 fail-closed 로 보류한
  미밟음 줄은 fail 이 아니므로 아래 발행 대상에서 뺀다(밟지 않은 줄에 '스모크 실패' 사유로
  후속 이슈를 내면 결함이 아닌 것이 결함으로 기록된다 — #309). → 직접 고치지 않고 기존 발행 경로: 자동수정 가능하면
  `references/spinoff-issue.md` 로 agent-ready 이슈(**6단계와 같은 한 호출**
  `$SCRIPTS/spinoff-issue.sh <repo> <부모 이슈#> <부모 PR#> --title "<제목>" --body-file <본문파일>` —
  상속·라벨·readback·마커가 그 안에 있다. 여기도 산문으로 대신하지 마라),
  라이브 검증이 필요하면 `--label needs-human` 이슈. 같은 실패가 `REPAIR_RECUR_LIMIT`
  회 반복되면 `needs-human` 으로 승격한다 (**exhausted 종료**). 배포 이슈는 닫지 않는다.
  라벨명은 `needs-human`(하이픈)이다 — `needs:human` 은 존재하지 않는 라벨이라
  `gh issue create` 가 통째로 실패한다(콜론형은 `needs:hardware` 뿐).
  - **코드무관 스모크 실패 기록 (lessons).** 그 스모크 실패가 코드 무관(인프라 장애·
    플레이크·검증 URL 일시 오류 등)으로 판명되면, 위 발행 경로와 별개로
    `$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑 **`.loop/lessons-verifier.md`** 에
    `- [YYYY-MM-DD PR#<pr>] <스모크 오판 패턴 → 재발 방지 행동>` 1줄을, 위 1단계와 같은
    호출로 append·정리한다 — `$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"`
    (같은 파일·같은 캡 — 판정 오판 계열이라 검증자 사례집에 쌓인다. 여기도 append 를
    이 호출 밖에서 손으로 하지 마라 — 1단계와 같은 유실 위험). 코드 결함으로 판명된
    실패는 여기 기록하지 않는다 — 발행 경로가 담당.
- **브라우저 정리 — 누수 방지 (공통 종료, green·fail·degrade 모두).** 위 스모크 판정
  코멘트를 남긴 **뒤**, 이 틱이 연 chrome-devtools 페이지를 `list_pages`→`close_page` 로
  반드시 닫는다 — 세 종료 경로 어느 쪽으로 빠졌든 예외 없이(정리 전에 return 하지 마라).
  프로덕션 페이지엔 클라이언트 폴러(adspower_pool 30초 자동 새로고침·aging 라이브 폴·
  조립기 라이브싱크 등)가 살아 있어, 좌존 탭이 틱마다 누적되며 `setInterval` 로 CPU 를
  스핀해 며칠이면 미니를 과부하로 넘어뜨린다(2026-07-06 load 66 사고). degrade 로
  브라우저를 안 열었으면 정리 대상이 없어 no-op 이고(단 URL 도달 불가를 판정하느라
  `navigate_page` 를 시도해 에러 탭이 열렸으면 그 탭도 `close_page` 한다), 스모크
  대상이 없는 정상 no-op 틱도 브라우저를 열지 않으므로 여기 정리는 회귀 없이 건너뛴다.

**6단계 — 파생 이슈.** 워커 PR 본문의 `follow-up:` 항목 + 1단계 diff 리뷰가 짚은
인접 작업을 `references/spinoff-issue.md` 로 채워 agent-ready 이슈로 발행한다.
발행 절차 전체 — 상속(#261) · 본문 첫 줄 `Epic #N` · 라벨 · 라벨 부재 fail-closed ·
발행 직후 readback · 부모 PR 마커 — 는 **`$SCRIPTS/spinoff-issue.sh` 한 호출**이다(#447).
여기서 `gh issue create` 를 손으로 조립하지 마라 — 산문뿐인 단계가 샌다(실증 2026-08-13:
6단계가 규약 라벨만 달고 `agent-ready` 를 빠뜨려 열린 이슈 17건이 루프 밖 재고로 남음.
명령이 박혀 있던 4단계는 186건 전건 정상이었다).

- **부모 결정 (상속의 입력 — 이건 스크립트가 아니라 이 단계의 판단이다).** 부모 = 마감 중인
  PR 의 **head 브랜치 `agent/issue-<N>` 의 N** 이 1순위다. `closingIssuesReferences` 는 그 N 이
  그 목록에 있는지 **교차확인**하는 데 쓰거나, head 가 `agent/issue-*` 형태가 아닐 때의
  **폴백**으로만 쓴다 — `[0]` 은 브랜치 이슈라는 보장이 없다(실측: `PR #113` 은
  `head=agent/issue-109` 인데 `closingIssuesReferences=[108, 109]` 라 `[0]` 이 **#108** —
  엉뚱한 이슈였다. 같은 함정이 `finish-classify.sh:317-318` 에서 증거를 조용히 꺼뜨리는
  사고를 냈다). 둘 다 못 구하면 스크립트에 `-` 를 넘기지 말고 **발행하지 않는다** — ④ Report 에
  `BLOCKED: 파생 부모 미상 — PR #<pr>` 로 올린다(상속 없이 발행하지 않는다).
- **발행 명령 (필수 형태 — 산문으로 대체하지 마라).** 본문은 채운 `spinoff-issue.md` 를
  파일로 써서 `--body-file` 로 넘긴다(템플릿은 **본문 전용**이라 라벨을 거기 적으면 이슈
  본문에 렌더된다 — 라벨은 스크립트가 명령줄에서 준다):

  ```
  $SCRIPTS/spinoff-issue.sh <repo> <부모 이슈#> <부모 PR#> \
    --title "<제목>" --body-file <본문파일> [--label <레포 규약 라벨>...]
  ```

  규칙의 SSOT 는 그 스크립트의 머리 주석이다. 하는 일: `spinoff-inherit.sh` 로 부모를 **한 번**
  읽어 `epic=`·`priority=` 를 받고 → 본문의 `<EPIC_LINE>` 전용 줄을 `Epic #N`(에픽 없으면 빈 줄)로
  채워 **첫 줄**을 보장하고(에픽은 sub-issue 링크나 라벨이 아니라 본문 전용 줄로 잇는다 —
  `loop-status.sh` 에픽 절이 그 줄로 leaf 를 센다) → `--label agent-ready --label spinoff --label "$priority"`
  + 넘긴 규약 라벨로 발행하고 → 라벨 부재면 `setup-labels.sh` 1회 + 재시도 1회, 그래도 안 되면
  **무라벨로라도 발행**하고(발행 유실 방지) → 라벨·`Epic #N` 첫 줄을 readback 해 보강하고 →
  부모 PR 에 `파생: #<새번호> (Epic #<N|없음> · <P>)` 마커를 남긴다. stdout 은 새 이슈 번호 한 줄이다.
  - **exit 0** — stderr 의 `marker:` 줄을 ④ Report 의 `파생` 항목에 그대로 옮긴다(에픽 밖으로
    새는 파생을 매 틱 관측하기 위한 것이다).
  - **exit 1 (이슈가 안 만들어졌다·무출력)** — 부모 미상·상속 실패·발행 실패. ④ Report 에
    `BLOCKED: 파생 부모 미상 — PR #<pr>` 또는 `BLOCKED: 파생 발행 실패 — PR #<pr>` 로 올린다.
  - **exit 2 (이슈는 만들어졌다 — 번호는 stdout)** — 라벨·본문·마커 중 하나가 어긋났다.
    ④ Report 에 `BLOCKED: 파생 이슈 라벨 부착 실패 — #<번호>` 로 올린다(복구는 사람 몫:
    `setup-labels.sh` 재실행 → `gh issue edit --add-label`). 여기서 같은 편집을 겹쳐 시도하지 마라.

  `--label` 로 넘길 것은 **레포 규약 축뿐**이다(BoDAT 의 `difficulty:*`·`frontend`(UI 를 건드릴
  때만)·`needs:hardware` — 레포 CLAUDE.md 의 라벨 절이 SSOT). `agent-ready`·`spinoff`·P 는
  스크립트가 붙이므로 다시 주지 마라 — 규약 라벨을 다느라 `agent-ready` 를 대체하던 실패
  형태(위 실측)가 여기서 원천 차단된다. `agent-ready` 가 없으면 `eligible-issues.sh` 의 자격
  (`open + agent-ready + ¬agent:claimed`)에 걸려 이슈는 생성되고도 **영원히 안 집히고**,
  `spinoff` 가 없으면 `loop-status.sh` 의 `파생` 줄이 그 이슈를 재고에서 못 본다.
  `priority` 를 손으로 올리지 마라 — "급해 보여서" 파생을 P1 로 올리는 것이 지금의 남발이고,
  올리려면 사람이 에픽 단위로 올린다(헬퍼가 부모의 P0 만 그대로 잇고 나머지는 `P1` 로 접는다, #401).
- **3단계가 이미 흡수한 표면 교정은 여기서 발행하지 않는다.** 3단계 "표면 교정 흡수"
  기준(통과/실패가 바뀌는 테스트가 하나도 없는가)을 통과해 그 커밋에 실린 건은 남은
  작업이 아니다. 한 발견에 표면과 코드가 섞여 있으면(예: "용어가 갈렸다 + 셈값 가드가
  없다") 표면은 3단계가 먹고 **코드 부분만** 이슈로 낸다 — 이슈 본문에 이미 고쳐진
  부분을 다시 적지 마라(다음 워커가 그걸 또 고치러 간다).
  이 절이 있는 이유: 이슈→PR→검증→마감 한 바퀴가 주석 한 줄을 고치자고 도는 것을
  막으려는 것이고, 그렇게 돈 PR 이 또 새 주석 지적을 낳아 사슬이 길어지는 것을 실측했다.

## ⑤ Drain — 다음 후보로 즉시 이어가기

③ 파이프라인이 집은 PR 을 종료 상태(success·approval-required·blocked·dup·exhausted)에
닿게 한 **직후**, 그 PR 의 결과를 ④ Report 용으로 누적해 두고 **다음 틱을 기다리지
말고 ①①-b② 로 되돌아간다** — 한 번에 하나씩만 처리해 적체가 쌓이던 문제를 이 드레인이
한 틱 안에서 소진한다:

- ① Reconcile + ①-b 정체 스윕 + ② Pick 을 다시 수행한다. ② Pick 이 **새 후보를
  집으면**(이번에 처리한 PR 은 이미 eligible/입양후보에서 빠졌다) 그 PR 로 ③ 파이프라인을
  즉시 이어간다.
- ② Pick 후보가 **0이면** 큐가 빈 것이다 — 드레인을 멈추고 ④ Report 로 이 틱에서
  처리한 **모든 PR 을 한 번에 집계**해 보고한 뒤, `/loop` 주기로 다음 틱을 예약한다.

무한루프 방지: 각 반복은 eligible/입양후보를 최소 1개 줄인다(머지→OPEN 소멸 · blocked→
`needs-human` · dup→머지 없이 PR 이 닫혀 OPEN 소멸 ·
approval-required→`배포 대기:` 마커 · 재디스패치→PR `재디스패치:` 마커로
재선정 배제(마커 후 새 활동 없으면 스윕이 재발행 안 함)). 같은 PR 이 두 번 집히면(마커
누락 등 예상 밖) 그 PR 을 skip 하고 ④ Report 에 `BLOCKED: 재선정 루프 — #<pr>` 로 보고해
드레인을 끊는다. 별도 상한이 필요하면 한 틱 드레인은 최대 eligible 스냅샷 길이만큼만
돈다(스냅샷 이후 새로 열린 PR 은 다음 틱 몫).

## ④ Report

드레인이 끝나면(② Pick 후보 0) 이 틱에서 처리한 **모든 PR 을 합산**해 한 줄 요약(N 은
이 틱 누적치): `마감 N · 검증보류 N · 중복종료 N · 배포대기 N · 파생 N · 회수 N · 재디스패치 N · stale N`.
①-b 스윕이 입양해 마감·rebase 한 건은 `회수 N`(마감까지 갔으면 `마감` 에도 반영),
`stale_reverify` 재디스패치·`held` needs-human 건은 `재디스패치 N` 으로 집계한다.

그 아래 **항목마다 번호를 적는다** — 숫자만으론 어느 PR·이슈가 어디로 갔는지 다음 틱이 못 읽는다:
`마감: PR #4795(bodat)←#4788 · 파생: #4823(bodat)←PR #4788 (Epic #4968 · P1) · 재디스패치: #4770(bodat, stale_reverify)`.
`파생` 항목은 6단계 PR 코멘트 마커와 **같은 꼴**로 `#<새번호> (Epic #<N|없음> · <P>)` 를 적는다 —
에픽을 못 물려받은 파생(`Epic 없음`)이 쌓이는지 매 틱 눈으로 보이게 하려는 것이다.
레포 짧은 이름 규칙은 `loop-status.sh` 와 같다(`owner/repo` 의 repo 를 소문자로 — bodat·bodac,
`issue-runner` 만 `runner` 특례).
① 의 에픽 스윕이 닫은 에픽도 같은 줄에 `에픽 종료: #285(runner, leaf 4)` 로 덧붙인다 —
닫은 게 없으면 이 조각은 **생략한다**(`note` 는 보고하지 않는다).

**`승격 대기 N커밋` 을 매 틱 반드시 함께 보고한다 (누락 금지).** 이 틱에 마감이 0건이어도
빼지 마라 — 사람이 "승격할 게 쌓여 있는지" 를 보는 유일한 숫자다. 승격 포인터 브랜치가
있으면(`release` 등) `git fetch origin <포인터> <기본브랜치>` 후
`git rev-list --count origin/<포인터>..origin/<기본브랜치>` 로 세고, 포인터 브랜치가
없는 레포면 `승격 대기 —` 로 적어 해당 없음을 명시한다. 0이면 `승격 대기 0커밋` 이라고
그대로 적는다(생략하지 마라 — 생략과 0은 다르다).
실증 2026-08-16: 이 줄을 3틱 연속 빠뜨렸더니, 배포 이슈도 없던 시기와 겹쳐 마감분이
증발한 것처럼 보였다. 그 사고가 4단계를 "머지하면 무조건 티켓" 으로 되돌린 계기다.
(아래 `loop-status.sh` 블록도 승격 대기를 찍지만 이 줄은 **그대로 유지한다** — 중복은
누락 사고 이력에 대한 의도된 이중화다.)

**파이프라인 스냅샷 (매 틱 필수).** 위 줄들 뒤에 `$SCRIPTS/loop-status.sh --post closeout --delta "<이 틱 한 줄 요약>"`(레포마다 고정 이슈 `루프 현황`(라벨 `loop-dashboard`) 본문도 덮어쓴다 — 깃헙만 보고 누가 들고 있고 루프가 마지막으로 언제 돌았는지 알게, #163) 를 실행해
출력을 **그대로** 붙인다 — 카운터는 "이 틱에 한 일"만 말하고 무엇이 쌓여 있는지는
이 블록만 본다. `cd` 없이 부른다(스코프는 루프 세션 cwd 의 `.loop/repos` 를 자동 적용).
**카운트가 전부 0인 조용한 틱에도 붙인다** — 스냅샷은 "놀고 있는 것"을 보는 유일한 창이다.
- exit 1(부분 실패 — 일부 레포 조회 실패)이면 그 출력을 그대로 붙이고 `loop-status 부분 실패`
  한 줄을 warn 으로 더한다.
- exit 64(스코프 없음 — 계정 전체 세션이라 `.loop/repos` 가 없음)면 이 틱에 만진 레포들을
  `--repo <owner/repo>` 로 명시해 한 번 더 부르고, 그래도 없으면
  `loop-status: 스코프 없음(.loop/repos 부재)` 한 줄을 warn 으로 남긴다.
- `$SCRIPTS/closeout-eligible.sh` 의 stderr `blocked: PR #<pr>(<repo>) — ✅ 이후 미해결 코멘트
  <n>건(마커 없음 = 사람 리뷰 대기)` (② Pick 참조) 는 한 줄 그대로 `막힘` 항목으로 옮겨 적는다
  (warn 아님) — verify-runner 가 재검증해 새 ✅ 를 찍기 전까진 매 틱 반복되는 것이 정상이다
  (사람 답글은 풀지 않는다 — ② Pick 참조).

종료 상태 7종 — 처리한 PR **각각**에 대해 명시한다(드레인으로 여러 개면 PR 별로):
- **success** — 1~6단계를 다 돌아 PR 을 머지하고 후속까지 발행함(입양·rebase 회수분 포함).
- **clean no-op** — ② Pick 후보가 0이라 마감할 PR 이 없음(①-b 재디스패치만 있었어도 no-op 아님 — `재디스패치 N` 보고).
- **blocked** — 1단계 검증이 BLOCKER 이거나 2단계 rebase 통합 실패라 보류(머지 안 함).
- **dup** — 1단계 검증이 "이미 `origin/main` 에 있다·중복" 으로 판정해 `closeout-dup` 으로
  PR·이슈를 머지 없이 닫음(`needs-human` 없음 — 루프가 끝낸 것이다). `중복종료 N` 으로 집계.
- **approval-required** — 4단계에서 배포 이슈를 발행하고 deploy-cycle 레인에 인계.
- **exhausted** — 5단계 같은 실패가 `REPAIR_RECUR_LIMIT` 회 반복돼 needs-human 승격.
- **stagnated** — `QUIET_TICKS` 연속 조용함(①-b 스윕은 stagnated 여도 매 틱 돈다).

`QUIET_TICKS` 연속으로 조용해도 ①②는 다음 틱에도 그대로 수행한다 — stagnated 는
보고에만 반영되고 어떤 단계도 건너뛰지 않는다.

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 역할 분담: issue-runner = 벌리는 공장 (절대 머지하지 않고 불변을 보존), closeout
  = 마감 도크 (머지를 독점). 두 루프는 `harvesting` 라벨 점유로 충돌을 막는다 —
  closeout 가 집은 PR 은 issue-runner ② Maintain 이 건드리지 않는다.
- 배포 레인(deploy-cycle): production 배포·release 승격은 closeout 이 하지 않는다 —
  4단계가 dry-run 배포 대기 이슈를 발행해 deploy-cycle 루프에 넘기고, 배포·승격·
  실테스트(칸 ③ TEST 워커)·종료는 그 레인의 ⑦ 이 소유한다. 나머지 머지·문서반영·
  후속발행은 closeout 이 무인으로 한다.
- 운용: closeout 은 issue-runner 와 별도의 `/loop` 세션으로 돌린다
  (예 `/loop 20m /closeout`) — 서로의 점유를 라벨로만 조율한다.
- 의존: 결정적 헬퍼(`closeout-reconcile.sh`·`closeout-eligible.sh`·
  `closeout-ci-pass.sh`·`closeout-step1-marker.sh`(① 마커표 1단계 판정)·
  `transition.sh`(라벨 이동)·`loop-status.sh`(④ Report 스냅샷))는 `$SCRIPTS`(=`~/.claude/skills/issue-runner/scripts`)에
  있고, references 3종(`verifier-prompt.md`·`deploy-check-issue.md`·
  `spinoff-issue.md`)은 `skills/closeout/references/` 에 있다.
- 실측이 필요한 항목의 시도 순서·통로·인용 규칙은
  `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  (칸 ①dev → ②워커 런타임 → ③TEST 워커 → ④사람. 4단계 `<LIVE_CHECKS>` 이관 전 ①② 시도의
  근거이자 `--reason ladder` 의 전제).
