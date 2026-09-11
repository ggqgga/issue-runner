---
name: closeout
description: issue-runner 가 연 초록불 PR을 머지·문서반영·배포준비·후속발행까지 자동 마감하는 루프. /loop 와 함께 (예 /loop 20m /closeout). 매 틱 Reconcile → Pick → 파이프라인 → (후보 남으면 Drain 반복) → Report. 한 틱이 eligible 큐를 다 비운다.
---

# closeout — 마감 도크 틱

당신은 무인 마감 워커다. 아래 단계를 **순서대로** 수행하라. issue-runner 가 벌린
초록불 PR을 머지·문서반영·배포준비·후속발행까지 끝까지 마감한다 — issue-runner 는
절대 머지하지 않으므로, 머지는 이 루프의 독점이다. 두 루프의 충돌은 `harvesting`
라벨 점유로 막는다 (issue-runner ② Maintain 은 `harvesting` PR 을 건드리지 않는다).

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
- `VERIFIER_TIMEOUT_MIN = 10` — `VERIFIER`(및 폴백) 스폰 1회당 벽시계 상한(분). 스폰
  시각 + 이 값을 데드라인으로 폴링하고, 데드라인을 넘기면 `TaskStop` 으로 끊어 verdict
  미산출로 간주한다 — codex 외부 CLI 스톨이 틱을 무한정 묶는 것을 막는 방어선(#96).
- 절대 금지: production 무인 배포(4단계는 사람 게이트 — 실 배포 안 함) · 프로덕션
  포인터 브랜치(release 등) 무인 승격(검증된 SHA 를 프로덕션/워커가 당기는 브랜치로
  미는 것도 배포와 동급의 사람 게이트다) · main 직접
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
| 5 후처리 | `✅ 스모크` 코멘트 / 배포 이슈 CLOSED + 검증·배포 완료 코멘트 | 있으면 재스모크 안 함 (사람 게이트가 검증까지 마치고 닫은 경우 포함) |
| 6 파생 | 생성 이슈 번호 코멘트 | 있으면 재발행 안 함 |

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
   묶는다: `재디스패치`(이 스킬 ①-b) · `재검증 실패`(verify-runner ④, 콜론 등 뒤에 무엇이
   오든 접두 매칭 — #212). 새 반송 어휘가
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
head 가 `agent/issue-*` 이고 **`harvesting` 미부착**이며 **`flow:verify` 미부착**이고 **`needs-human`
미부착**인 PR 마다 판정한다. `needs-human` PR 은 사람 대기(`hold:*` 사유 — verify-held·closeout-blocked·
디스패처 runner-held 보수 상한)라 스윕이 입양·재디스패치하면 방금 건 사람 대기를 되돌린다(#151) —
사람이 라벨을 떼기 전엔 절대 집지 않는다. **`flow:verify` PR 은 verify-runner 가 검증 중(소유)이라 여기서 절대 집지
않는다** — 이걸 빠뜨리면 finish-classify 가 `🔄`(verify-runner 가 아직 ✅ 안 찍음)를
`stale_reverify` 로 오분류해 재디스패치하고, verify-runner 의 검증과 충돌한다(양쪽이
같은 PR 을 물어뜯음). 검증 단계의 완결 유실 회수는 verify-runner 의 매 틱 재집(flow:verify
라벨 잔존)이 소유한다 — closeout ①-b 는 **검증 이후**(✅+flow:ready 인데 closeout 머지가
죽은 경우)와 CONFLICTING 입양만 맡는다.

**1) CONFLICTING 먼저 — 단, 반송 마커를 먼저 본다**:
`gh pr view <pr> --repo <repo> --json mergeable` 가 CONFLICTING 이면, 입양하기 **전에**
`$SCRIPTS/bounce-state.sh <repo> <pr>` 를 돌려라.

- 출력이 정확히 `ok` 일 때만 → **입양(rebase 경로)**: ② Pick 후보로 넘기고 ③ 2단계에서
  closeout 이 직접 rebase 후 머지(2단계 conflict 경로). (finish-classify 는 건너뛴다.)
- `bounced` 이거나 **출력이 없으면(exit 1 — 판정 실패)** → `active` 취급 **무접촉**.
  진행 중인 반송 회차는 워커 레인 소유다(fail-closed — 반송되지 않았음을 *증명*했을
  때만 연다, #171 과 같은 방향).

왜 필요한가(#196 실측: bodat PR #5009 / 이슈 #4973): 반송된 PR 은 `머지 판정: ✅` 가
없어 `closeout-eligible.sh` 목록에 애초에 안 뜨고, ①-b 는 finish-classify 를 건너뛴다 —
그래서 **반송 마커를 보는 자리를 둘 다 안 지난다.** 반송 직후에는 `transition.sh` 가 단계
라벨을 정리하므로 "단계 라벨 0 + CONFLICTING" 은 좌초의 증거가 아니라 **반송 회차의 정상
형상이기도 하다.** 실제로 closeout 이 살아 있는 워커의 PR 을 입양해 `harvesting` 을 붙이고
그 워크트리에서 `git rebase origin/main` 까지 돌렸다(원격은 push 전이라 무손상).

판정은 `bounce-state.sh` **한 자리**다 — 마커 집합(`재디스패치`·`재검증 실패`, 콜론
리터럴을 요구하지 않는 접두 매칭 — #212)도, 선후를
`createdAt` 이 아니라 **코멘트 배열의 마지막 매칭 인덱스**로 재는 규칙도 거기 있고
`closeout-eligible.sh` 가 같은 자리를 부른다(로직 두 벌 금지).

**`agent:claimed` 는 보조 게이트로 쓰지 않는다**(#196 3항 결정, 실측 근거):
`reconcile.sh` 는 열린 PR 이 있는 이슈에서 `agent:claimed` 를 **떼지 않는다**(worktree 가
사라지고 열린 PR 도 없을 때만 stale 로 뗀다). 그래서 ①-b 가 집어야 할 *진짜* 좌초
CONFLICTING PR 도 그 라벨을 그대로 달고 있다 — 배제 조건으로 걸면 CONFLICTING 입양 레인이
통째로 닫힌다. 반대 방향으로도 못 쓴다: 반송 직후 `closeout-redispatch`/`verify-redispatch`
가 `agent:claimed` 를 뗀 뒤 디스패처가 새 워커를 붙일 때까지의 창에서는 **워커 레인
소유인데 라벨이 없다**. 두 방향 모두 틀리므로 코멘트 마커 하나로 판정한다.

**2) 아니면 `$SCRIPTS/finish-classify.sh <repo> <pr>` 로 결정적 분류** — 이 헬퍼가 최신
`머지 판정:`/`검증자 리뷰:` 코멘트와 `STALE_FINISH_MIN` 시간버퍼로 상태를 낸다(손수
코멘트 파싱 대신 테스트된 헬퍼 재사용). **살아있는 워커·시간버퍼 미도달은 `active` 로
걸러져 레이스가 방지된다** — 별도 신선도 게이트가 필요 없다:

| finish-classify 출력 | 뜻 | 조치 |
|---|---|---|
| `done_verdict` | 최신 `머지 판정: ✅` **이고 그 판정이 현재 head 커밋 이후임이 증명됨**(#171) | eligible.sh 정상 경로가 처리 — 스윕은 skip |
| `stale_inline` | 🔄 + 검증자 CLEAN + 버퍼 초과 (검증까지 도달·최종판정만 유실, #970형) | **입양(머지)** — ② Pick 후보로. ③ 1단계가 **독립 재검증** 후 마감. **새 이슈 안 만듦**(완료된 일 재수행 금지). |
| `stale_reverify` | 🔄 + 검증자 부재/미해결 BLOCKER + 버퍼 초과 (검증 전 사망·구현 미완 가능, #971형) | **재디스패치** — 미완 코드를 codex 재검증 하나로 자동 머지하지 않는다(사용자 결정). `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` (연결 이슈를 `agent-ready` 로 되돌리고 `agent:claimed`·단계 라벨을 뗀다) → 새 워커가 같은 브랜치서 검증자 재실행→체크박스→최종판정으로 완결. 멱등 마커(아래). — head 커밋이 신선하면(#110, 스테일 클록에 커밋 시각 합류) 코멘트가 낡았어도 `active` 로 떨어져 살아있는 attempt N+1 워커를 오분류하지 않는다. |
| `held` | 최신 `머지 판정: ⚠ 보류` (워커 명시 보류) | **needs-human** — `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` (PR 과 연결 이슈 **양쪽**에 `needs-human` + `hold:policy` 부착 + 단계 라벨 정리 — 연결 이슈가 없어도 PR 에 사람 신호가 남는다), closeout 무접촉(자동 진행 안 함). |
| `active` | 진행 중·버퍼 미도달·우리 형상 아님, 또는 **✅ 의 신선도를 증명 못 함**(✅ 가 head 커밋보다 이르거나 두 시각 중 하나를 못 얻음, #171). **위 1) 의 CONFLICTING PR 도 `bounce-state.sh` 가 `ok` 가 아니면(반송 회차 진행 중이거나 판정 실패) 여기로 떨어진다**(#196) — 단계 라벨이 비어 있어도 그건 좌초가 아니라 워커 레인 소유다 | **무접촉**(다음 틱). |

**flow:\* 보조 신호**: finish-classify 가 코멘트로 판정하지만, `flow:ready` 없이
`flow:codex`/`flow:ci` 만 있고 오래된 PR 은 그 자체로 "검증 중 워커 사망"의 방증이다
(라벨은 이 스킬 밖 워커 런타임이 세팅 — 있으면 보조로 참고, 없으면 finish-classify
결과만으로 판정).

**재디스패치 멱등 마커 (필수)**: `stale_reverify` 재디스패치 시 PR 에
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
라벨(`flow:ready`·`flow:codex`·`flow:ci`·`flow:verify`)을 함께 뗀다 — `harvesting` 이 있어야
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
exit 64 — 사유 없는 `needs-human` 을 만들 수 없다). rebase/semantic conflict 는
`conflict`, 그 외 루프가 못 정하는 스펙·정책·검증 미산출은 `policy`, 사다리
(`~/.claude/skills/issue-runner/references/live-verification-ladder.md`)
의 칸을 실제로 올라가 실패 출력을 인용한 경우만 `ladder` 다.

## ③ 파이프라인 — 1~6단계

집은 PR 에 대해 아래 6단계를 순서대로 수행한다. 각 단계 끝에 마커 명령을 박아
(① Reconcile 마커표) 다음 틱이 멱등 재개할 수 있게 한다.

**1단계 — 계획 부합 검증 — 내장 리뷰어.** `<issue>` 는 PR 본문의 `Closes #N` / `Refs #N` 줄에서
얻는다(`gh pr view <pr> --repo <repo> --json body` 로 파싱). 검증은 `$SCRIPTS/codex-review-gate.sh`(#134,
Plans/codex-native-review-gate.md) **동기 호출 두 번**이다 — 서브에이전트 스폰·폴링·`TaskStop` 배선 없음:
1. correctness: `codex-review-gate.sh --base origin/<default> --cd <worktree> --out <스크래치>/a` →
   stdout 마지막 줄 `verdict=… p1= p2=`, 본문 `a/review.md`. `[P1]` = BLOCKER.
2. 계획 부합: `codex-review-gate.sh --base origin/<default> --prompt "<지시>" --cd <worktree> --out <스크래치>/b`
   (헬퍼가 `--base` 범위를 프롬프트 머리에 명시해 리뷰어가 커밋된 diff 를 실제로 본다 — 없으면 작업 트리만 본다) — 지시문은
   `references/verifier-prompt.md` 의 placeholder 를 채운 것: `<PR>`·`<REPO>`·`<BASE>`=default branch·
   `<PLAN_REF>`=이슈 `## Plan` 또는 참조한 `Plans/*.md`(없으면 빈 문자열)·`<ISSUE_BODY>`=`gh issue view <issue>
   --repo <repo>` 출력(연결 이슈 없으면 빈 문자열)·`<LESSONS_OR_"없음">`=`$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑
   **`.loop/lessons-verifier.md`**(검증 판정 사례집 — 과거 오판 패턴 주입; 없으면 `.loop/lessons.md` 폴백, 둘 다
   없거나 비면 `없음`. `lessons.md` 는 **구현 워커**용이라 섞지 않는다 — 오판 방지 신호 희석). `<DIFF>` 는 동봉하지
   않는다 — 내장 리뷰어가 워크트리에서 직접 읽는다. 지시문은 "이 변경이 계획/이슈 AC 를 충족하는가만 판정,
   미충족·범위 이탈은 `[P1]`, 경미한 편차는 `[P2]` 로" 를 명시한다.
헬퍼는 자체 타임아웃(`CODEX_GATE_TIMEOUT` 기본 900s = `VERIFIER_TIMEOUT_MIN` 과 동조)을 가진다. 두 호출 중 하나라도
**exit 2(`verdict=NONE`) = 미산출**(codex 부재·모델 오류·타임아웃)이면 그때만 ## 상수의 `VERIFIER` 폴백(general-purpose,
diff·이슈 본문·lessons 를 프롬프트에 동봉, `run_in_background` + `VERIFIER_TIMEOUT_MIN` 데드라인 + 초과 시 `TaskStop`)을
쓴다. 폴백도 미산출이면 아래 BLOCKER 경로로 보류 종료한다(fail-closed — 절대 머지로 진행하지 않는다, #96).
헬퍼 stderr 의 모델 오류 원문(404·not supported·requires a newer version)은 "스톨"이 아니다 — 코멘트에 그대로 남긴다.
- 판정 합산: 두 호출 중 하나라도 BLOCKER → BLOCKER. 둘 다 CLEAN/NIT/WARN → 통과(`[P3+]` = NIT 는 비차단, WARN 수는 합산).
  머신 코멘트 마커(필수): 아래 `gh pr comment` 로 남기는 마감 검증 코멘트는 **마지막 줄에
  `<!-- bodat:worker -->`** 를 포함한다 — closeout-eligible 이 머신 코멘트를 사람 리뷰와
  구분하는 신호다(#72). 빠지면 그 PR 이 재평가 때 미해결 사람 코멘트로 오인돼 탈락한다.
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
- BLOCKER(미산출 포함, 사유 예 `검증자 미산출 — 타임아웃(>VERIFIER_TIMEOUT_MIN분)` / 모델 오류 원문) →
  `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <사유>
  <!-- bodat:worker -->"`
  + `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  (PR 의 `harvesting` 제거 + 연결 이슈에 `needs-human` + `hold:policy` 부착·단계 라벨
  정리) → **blocked 종료** (머지하지 않는다). 검증자 BLOCKER·미산출은 스펙/정책 판단이
  필요한 것이므로 사유는 `policy` 다(`conflict` 도 `ladder` 도 아니다).
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
  `- [YYYY-MM-DD PR#<pr>] <거짓 BLOCKER 패턴 → 재발 방지 행동>` 1줄을 append 한다
  (파일이 없으면 새로 만든다 — 이건 검증자용이라 워커용 `lessons.md` 와 섞지 않는다).
  **캡: 항목 20개** — 초과 시 가장 오래된 **항목 하나를 통째로** 삭제한다(줄 단위가
  아니다. 이 파일에는 `##` 로 시작하는 여러 줄짜리 사례가 섞여 있어 줄을 자르면 산문이
  찢어진다. 항목 = `- [` 로 시작하는 한 줄, 또는 `##` 헤더부터 다음 항목 직전까지).
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
  conflict 를 원안 의도대로 해소, `git push --force-with-lease`, **merge 커밋 금지**" 로
  교체하고 push 규율·금지는 유지) → 에이전트 종료 후 `$SCRIPTS/run-local-ci.sh <repo>
  <N>` 로 rebased HEAD 캐시를 재생성한다. 비0(새 base 통합 깨짐)이면 머지하지 말고
  **위임 fail-closed**: `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`
  로 연결 이슈를 `agent-ready` 로 되돌려(또는 spinoff) 넘기고 blocked 종료.
  0이면 위 exit 0 머지 게이트로 합류해 정상 squash 머지한다. 에이전트가 conflict 를 **못 풀면**(rebase abort·반복 실패) semantic
  conflict 는 사람 판단이므로 `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason conflict --note "<질문 한 줄>"`
  로 넘기고 blocked 종료한다(무인 강제 해소 금지 — 이 경로만 사유가 `conflict` 다). 두 전이 모두 **exit 1(readback
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

**4단계 — 배포 (사람 게이트, dry-run).** **실 배포를 하지 않는다.**
`references/deploy-check-issue.md` 를 채워(`<DEPLOY_CMD>`=레포 배포 엔트리포인트,
모르면 "레포 배포 절차"; `<VERIFY_URL>`=production 베이스 URL — 5단계 스모크가 몰
주소, 모르면 빈 줄로 둬 5단계가 URL 도달불가로 폴백; `<LIVE_CHECKS>`=PR test plan·
이슈 본문에서 "배포 후 라이브 검증"·하드웨어/실장비 검증 등 **머지 후에만 수행
가능하다고 표기된 항목** — 1단계 검증자가 머지 게이트에서 제외한 범위 밖 검증 항목의
유일한 이관 목적지다).

**`<LIVE_CHECKS>` 는 두 형태 중 하나여야 한다 — 산문 금지.**
- 사람이 배포 후 밟을 게 **하나도 없으면** 정확히 `없음` 한 단어. 뒤에 설명을 붙이지 마라.
- 있으면 **`- [ ]` 체크박스 목록**. 한 줄 = 사람이 한 번 밟는 동작. 배경·근거·주의는
  `## 변경 요약` 에 쓰고 여기엔 밟을 것만 남긴다.

형태를 강제하는 이유: 아래 분기가 이 절을 읽어 이슈 발행 여부를 가르는데, 자유 산문이면
그 판정이 매 틱 해석에 맡겨져 흔들린다(실측 2026-08-12~13: 배포검증 이슈 186건 중
**체크박스를 쓴 건 0건**, 전부 산문이었다). "없음. 주석 13줄이 전부다 — 관찰 가능한
변화가 없다" 같은 서술은 사람에겐 명확해도 기계 분기엔 `없음` 이 아니다.

**옮기기 전에 closeout 이 사다리를 한 번 올라간다 (시도 없는 `[ ]` 는 그대로 옮기지 않는다).**
워커가 남긴 미완 항목 중 **사다리 시도·인용 없이 `[ ]` 로만 남은 것**(PR test plan 에
시도한 칸도 실패 출력도 없는 항목)은 그대로 이 절에 옮기지 마라 — 그렇게 옮기면 아무도
시도하지 않은 일이 사람 몫으로 승격된다. closeout 이
`~/.claude/skills/issue-runner/references/live-verification-ladder.md`
의 **칸 ①(dev 서버 — `bin/rails runner`·localhost)와 칸 ②(`bin/dry-run`·AdsPower 릴레이)**
를 **한 번씩** 시도한 뒤에 옮긴다(칸 ③ 실장비는 closeout 의 몫이 아니다 — 시도 결과와
함께 남긴다).
- 칸 ①② 에서 **판정이 서면** 그 항목은 `<LIVE_CHECKS>` 에서 **뺀다**(사람이 밟을 게
  아니다). 판정 근거는 PR 코멘트에 남긴다.
- **실패하면** 항목을 `- [ ]` 로 옮기되, **시도한 칸과 실패 출력(명령 한 줄 + 마지막
  20줄)을 인용**한다. 인용은 `## 변경 요약` 절에 적는다 — `<LIVE_CHECKS>` 는 위 형태
  규율대로 **밟을 동작만** 남는 자리라 산문·출력이 들어가면 안 된다.
- 시도가 불가능한 환경이면(레포에 해당 진입점 없음 등) 그 사실을 `## 변경 요약` 에 한 줄로
  적는다. "실장비 필요" 라는 서술만으로 시도를 건너뛰지 마라.

**분기 — 머지했으면 무조건 승격 티켓을 만든다 (사용자 결정, 2026-08-16).**

**머지된 PR 은 예외 없이 배포 대기 이슈를 하나 발행한다.** 판정하지 마라 — 테스트
전용이든 주석 한 줄이든, 머지됐다는 것은 승격 범위에 들어갔다는 뜻이고 그 사실이
사람에게 보여야 한다.

- **발행 명령 (필수 형태 — 산문으로 대체하지 마라).**

  ```
  gh issue create --repo <repo> --title "배포 대기: PR #<pr> — <요약>[ (승격만)]" \
    --body-file <본문파일> --label needs-human --label deploy-wait [--label <P1|P2>]
  ```

  `needs-human` 은 deploy-bodat 등 기존 수집(사람 게이트 쿼리)과의 호환 때문에 유지하고,
  `deploy-wait` 는 `loop-status.sh` 가 배포대기와 사람대기를 갈라 세는 버킷 라벨이다 —
  **둘 다** 필요하다. 발행 뒤 `gh pr comment <pr> --repo <repo> --body "배포 대기: #<생성번호>"`
  마커를 남긴 뒤 → **approval-required 로 종료**한다.
- **라벨 부재 fail-closed — 티켓을 잃지 않는다 (6단계 파생과 동형).** `gh issue create` 는
  `--label` 에 레포에 없는 라벨이 있으면 **이슈 자체를 안 만들고 실패**한다. `setup-labels.sh`
  재실행 전의 기존 옵트인 레포엔 `deploy-wait` 가 없으므로, 이 규칙이 없으면 업그레이드 뒤
  첫 마감이 PR 은 머지된 채 티켓·마커 없이 끝난다. `'deploy-wait' not found` 류로 실패하면
  `$SCRIPTS/setup-labels.sh <repo>` 를 **1회** 호출한 뒤 같은 명령을 **1회만** 재시도한다.
  재시도도 실패하면 더 반복하지 말고 **`--label needs-human` 만으로 발행**하고(티켓 유실 방지 —
  `loop-status.sh` 는 제목 `배포 대기:` 폴백으로 여전히 배포대기로 센다) ④ Report 에
  `BLOCKED: 배포 대기 이슈 deploy-wait 라벨 부착 실패 — #<번호>` 로 올린다.
- **발행 직후 확인 (6단계와 동형).** `gh issue view <번호> --repo <repo> --json labels` 로
  `needs-human` 과 `deploy-wait` 가 **둘 다** 붙었는지 확인하고, 빠진 게 있으면
  `gh issue edit <번호> --repo <repo> --add-label needs-human --add-label deploy-wait` 로
  보강한다(이번 사고의 8/8 누락은 발행 명령이 산문 한가운데 있었던 것뿐 아니라 이 확인
  절 자체가 4단계에 없었기 때문이다 — 6단계는 있어서 안 샜다).

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
  것처럼 읽힌다(거짓 초록). 이 이슈는 사람이 승격을 마치면 닫는다.

**묶지 않는다.** 여러 배포 대기 이슈를 하나로 합치지 마라 — 항목이 계속 붙는 장수 이슈는
닫히는 시점이 사라져 "끝나지 않는 이슈" 가 된다(사용자 결정, 2026-08-13). 개수가 늘어도
**한 PR = 한 티켓 = 닫히는 시점이 명확한 그릇** 을 유지한다.

**5단계 — 배포 후 처리 (Chrome 스모크).** 사람이 배포를 보고한 배포 이슈에 대해
새 감지 기구 없이(폴링/타이밍 미도입) 능동적으로 Chrome 스모크를 돌려 판정한다.
배포 이슈 본문에서 `## 검증 URL`(`<VERIFY_URL>`)과 `## 라이브/하드웨어 검증 항목`
(`<LIVE_CHECKS>`)을 파싱해 `references/smoke-prompt.md` 의 placeholder 에 채우고,
chrome-devtools MCP 도구를 ToolSearch 로 로드하고, **진입 정리(멱등 — 크래시 재개 방어):
`list_pages` 로 이전 틱이 정리 전에 죽어 남긴 스모크 페이지가 있으면 `close_page` 로
먼저 닫는다.** 이어 `navigate_page` 로 `<VERIFY_URL>` 에
진입한 뒤 각 항목을 `evaluate_script`/`take_snapshot` 으로 대조해 항목별 pass/fail 을
산출한다 (구조/빈 상태 확인과 실 데이터 렌더 확인을 결과에 구분 표기).
- **밟을 항목이 없으면 스모크하지 않는다.** 4단계는 머지된 PR 마다 배포 이슈를 발행하므로
  `(승격만)` 이슈도 존재한다 — 그러나 `## 라이브/하드웨어 검증 항목` 에 `- [ ]` 가 하나도
  없으면 Chrome 을 띄우지 말고 완료로 넘긴다. 대조할 항목이 0인 스모크는 무엇을 통과시킨
  게 아니라 **아무것도 안 본 것**인데 `✅ 스모크 0/0 통과` 로 찍히면 검증된 것처럼
  읽힌다(거짓 초록). 이때는 그 사유를 코멘트에 남긴다: `스모크 생략: 밟을 항목 0`.
  그 이슈는 사람이 승격을 마치면 닫는 그릇이지 검증 대상이 아니다.
- **이미 닫힌 배포 이슈 — 스모크 생략.** 배포 이슈가 이미 CLOSED 이고 검증/배포 완료
  코멘트가 있으면 5단계 완료로 간주한다 — 재스모크하지 않고 다음 단계로 진행한다
  (사람 게이트가 검증까지 마치고 닫은 경우 — 승격 모델 레포의 표준 종결).
- **저하(degrade) — 조용한 skip 금지.** chrome-devtools MCP 가 세션에 없거나(헤드리스/
  크론 — 대화형 인증 MCP 부재 가능) `<VERIFY_URL>` 이 비었거나 도달 불가면, 스모크를
  건너뛰고 기존 사람-보고 경로로 폴백하되 배포 이슈에 `스모크 skip: <사유>` 코멘트를
  남긴다(누락 은폐 금지).
  단 **"도달 불가" 는 마지막에만 쓴다** (#153): 크롬만 못 여는 주소가 있으므로,
  `<VERIFY_URL>` 이 안 열리면 skip 을 적기 전에 smoke-prompt 의 재시도 사다리를 먼저
  밟는다 — ① 그 레포의 원격 접근용 주소 ② SSH 터널. **둘 다 실패했을 때만** 도달 불가다. **브라우저를 아예 기동하지 않았으므로 정리 대상도 없다 —
  아래 브라우저 정리는 no-op(누수 아님).**
- **green (전부 통과)** → 배포 이슈 + 원본 PR 에 `✅ 스모크: <n>/<n> 통과` 코멘트(이
  코멘트가 5단계 완료 마커 — 재개 틱이 재스모크하지 않는다). 이어 배포 이슈에서
  `needs-human` 라벨을 제거하고 배포 이슈를 close 한다(남은 게이트가 검증뿐이고 그게
  통과했으므로 closeout 이 종결 — 미결 결정의 권장안).
- **fail (한 건이라도 실패)** → 직접 고치지 않고 기존 발행 경로: 자동수정 가능하면
  `references/spinoff-issue.md` 로 agent-ready 이슈(**6단계의 "발행 명령" 형태를 그대로
  쓴다** — `--label agent-ready --label spinoff --label <P1|P2>`. 여기도 산문으로 대신하지 마라),
  라이브 검증이 필요하면 `--label needs-human` 이슈. 같은 실패가 `REPAIR_RECUR_LIMIT`
  회 반복되면 `needs-human` 으로 승격한다 (**exhausted 종료**). 배포 이슈는 닫지 않는다.
  라벨명은 `needs-human`(하이픈)이다 — `needs:human` 은 존재하지 않는 라벨이라
  `gh issue create` 가 통째로 실패한다(콜론형은 `needs:hardware` 뿐).
  - **코드무관 스모크 실패 기록 (lessons).** 그 스모크 실패가 코드 무관(인프라 장애·
    플레이크·검증 URL 일시 오류 등)으로 판명되면, 위 발행 경로와 별개로
    `$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑 **`.loop/lessons-verifier.md`** 에
    `- [YYYY-MM-DD PR#<pr>] <스모크 오판 패턴 → 재발 방지 행동>` 1줄을 append 한다
    (위 1단계와 같은 파일·같은 캡 — 판정 오판 계열이라 검증자 사례집에 쌓인다). 코드 결함으로 판명된 실패는 여기 기록하지 않는다 — 발행 경로가 담당.
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
epic 이 있으면 sub-issue 로 연결하고, 없으면 독립 이슈로. 생성한 번호를 원본 PR
코멘트에 기록한다 (중복 발행 방지 마커).

- **발행 명령 (필수 형태 — 산문으로 대체하지 마라).** 본문은 채운
  `spinoff-issue.md` 를 파일로 써서 `--body-file` 로 넘긴다(템플릿은 **본문 전용**이라
  라벨을 거기 적으면 이슈 본문에 렌더된다 — 라벨은 반드시 명령줄에서 준다):

  ```
  gh issue create --repo <repo> --title "<제목>" --body-file <본문파일> \
    --label agent-ready --label spinoff --label <P1|P2> [--label <레포 규약 라벨>...]
  ```

  **`--label agent-ready` 는 생략 불가**다 — `eligible-issues.sh` 의 디스패치 자격이
  `open + agent-ready + ¬agent:claimed` 라, 이 라벨이 없으면 이슈는 생성되고도
  issue-runner 가 **영원히 집지 않는다**(실증 2026-08-13 BoDAT: 6단계가 3축 라벨만 달고
  agent-ready 를 빠뜨려 열린 이슈 17건이 루프 밖에 재고로 남음 — 4단계는 명령에
  `--label needs-human` 이 박혀 있어 186건 전건 정상이었다. 명령이 있는 단계는 안 새고,
  산문뿐인 단계가 샜다). 우선순위(`P1`/`P2`)도 함께 단다 — 없으면 정렬에서 최하위로
  밀린다(`P0 > P1 > P2 > 없음`). 그 밖의 축(BoDAT 의 `difficulty:*`·`frontend`/`backend`·
  `area:*`·`needs:hardware`)은 **레포 규약을 따라 추가**하되, 규약 라벨을 다느라
  `agent-ready` 를 대체하지 마라 — 위 실측의 실패 형태가 정확히 그것이다.
  `--label spinoff` 는 출처 표식이다 — `loop-status.sh` 의 `파생` 줄이 이 라벨로만 창 안의
  파생 이슈를 센다(제목 휴리스틱을 쓰지 않는다). 빠지면 그 이슈는 재고에서 안 보인다.
- **라벨 부재 fail-closed (② Pick 의 라벨 보강과 동형).** `gh issue create` 는
  `--label` 이 없는 라벨이면 **이슈 자체를 안 만들고 실패**한다(무해한 `--remove-label`
  과 다르다). `'agent-ready' not found`·`'spinoff' not found` 류로 실패하면 `$SCRIPTS/setup-labels.sh <repo>`
  를 **1회** 호출한 뒤 같은 명령을 **1회만** 재시도한다. 재시도도 실패하면 더 반복하지
  말고 **라벨 없이 이슈만 만들고**(발행 유실 방지) ④ Report 에
  `BLOCKED: 파생 이슈 라벨 부착 실패 — #<번호>` 로 올린다.
- **발행 직후 확인.** `gh issue view <번호> --repo <repo> --json labels` 로
  `agent-ready` 와 `spinoff` 가 **둘 다** 붙었는지 확인하고, 빠진 게 있으면
  `gh issue edit <번호> --repo <repo> --add-label agent-ready --add-label spinoff` 로 보강한다.
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
`마감: PR #4795(bodat)←#4788 · 파생: #4823(bodat)←PR #4788 · 재디스패치: #4770(bodat, stale_reverify)`.
레포 짧은 이름 규칙은 `loop-status.sh` 와 같다(`owner/repo` 의 repo 를 소문자로 — bodat·bodac,
`issue-runner` 만 `runner` 특례).

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

종료 상태 7종 — 처리한 PR **각각**에 대해 명시한다(드레인으로 여러 개면 PR 별로):
- **success** — 1~6단계를 다 돌아 PR 을 머지하고 후속까지 발행함(입양·rebase 회수분 포함).
- **clean no-op** — ② Pick 후보가 0이라 마감할 PR 이 없음(①-b 재디스패치만 있었어도 no-op 아님 — `재디스패치 N` 보고).
- **blocked** — 1단계 검증이 BLOCKER 이거나 2단계 rebase 통합 실패라 보류(머지 안 함).
- **dup** — 1단계 검증이 "이미 `origin/main` 에 있다·중복" 으로 판정해 `closeout-dup` 으로
  PR·이슈를 머지 없이 닫음(`needs-human` 없음 — 루프가 끝낸 것이다). `중복종료 N` 으로 집계.
- **approval-required** — 4단계에서 배포 이슈를 발행하고 사람 게이트 대기.
- **exhausted** — 5단계 같은 실패가 `REPAIR_RECUR_LIMIT` 회 반복돼 needs-human 승격.
- **stagnated** — `QUIET_TICKS` 연속 조용함(①-b 스윕은 stagnated 여도 매 틱 돈다).

`QUIET_TICKS` 연속으로 조용해도 ①②는 다음 틱에도 그대로 수행한다 — stagnated 는
보고에만 반영되고 어떤 단계도 건너뛰지 않는다.

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
  `closeout-ci-pass.sh`·`transition.sh`(라벨 이동)·`loop-status.sh`(④ Report 스냅샷))는 `$SCRIPTS`(=`~/.claude/skills/issue-runner/scripts`)에
  있고, references 3종(`verifier-prompt.md`·`deploy-check-issue.md`·
  `spinoff-issue.md`)은 `skills/closeout/references/` 에 있다.
- 실측이 필요한 항목의 시도 순서·통로·인용 규칙은
  `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  (칸 ①dev → ②워커 런타임 → ③TEST 워커 → ④사람. 4단계 `<LIVE_CHECKS>` 이관 전 ①② 시도의
  근거이자 `--reason ladder` 의 전제).
