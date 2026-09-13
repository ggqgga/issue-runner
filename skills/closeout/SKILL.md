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
> 같은 규칙이 남아 있으면 표가 이긴다.
>
> **세 루프가 공유하는 규약의 SSOT 는 `references/loop-conventions.md` 다**(#452). fail-closed 의 뜻(§1) ·
> warn·note·막힘 채널 경계(§2) · 스크립트 stderr → ④ Report 릴레이(§3) · 센티널 마커(§4) · `Closes #N`
> 전용 줄(§5) · 레포 짧은 이름(§6) · 파이프라인 스냅샷 규율(§7) · 라벨 부재 폴백(§8) · 검증 사다리 칸
> 규율(§9) · 표면 교정 판정(§10) — 아래 산문은 그 절들을 가리키지 재진술하지 않는다.
>
> **이 루프의 사고 이력·설계 근거는 `references/closeout-rationale.md` 다**(#453, 한글 전용). 왜 그 규칙인지 ·
> 어떤 사고(`#NNN`)·실측이 그것을 세웠는지 · 어떤 대안을 왜 버렸는지는 거기서 읽는다. 각 절 끝의
> `(근거: closeout-rationale §N)` 이 그 절을 가리킨다 — **틱 수행에는 읽지 않아도 된다.** 아래 본문은
> 규칙과 호출만 담는다: 규칙을 바꾸거나 되돌리려 할 때 그 문서를 먼저 읽어라.

## 상수

- `MAX_CLOSEOUT = 1` — **동시성 1**(한 번에 1 PR 만 끝까지 직렬 마감). 틱당 상한이 아니다 —
  한 PR 이 종료 상태(success·approval-required·blocked·dup·exhausted)에 닿으면 **다음 틱을 기다리지 말고**
  ①①-b② 로 되돌아 다음 후보를 집어 이어간다(⑤ Drain). 큐가 빌 때(② Pick 후보 0)만 틱을 끝내고
  `/loop` 주기로 쉰다. `/loop` 주기는 **빈 큐일 때의 재스캔 간격**만 조절한다.
- `REPAIR_RECUR_LIMIT = 2` — 같은 배포 후 실패가 N회 재발하면 agent-ready 재발행 대신
  `needs-human` 으로 승격한다 (5단계 서킷 브레이커).
- `QUIET_TICKS = 3` — N틱 연속 후보·이벤트가 없으면 stagnated 로 보고한다. **① Reconcile·①-b 스윕·
  ② Pick 은 이후에도 매 틱 그대로 수행**한다 — stagnated 는 순수 보고 라벨이라 어떤 단계도 건너뛰지 않는다.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = general-purpose` — 1단계 계획 부합 검증자 서브에이전트 타입. **codex 가 아니다**(#375).
  **출력 계약은 issue-runner `SKILL.md` 의 `## 상수` 절 `VERIFIER` 항목이 SSOT 다**(#427) — 여기선 다시
  적지 않는다: read-only·BLOCKER/WARN/NIT·CLEAN·BLOCKER 는 하드게이트, 그대로 적용된다. 검증자는 이
  SKILL.md 를 읽지 않으므로 호출 프롬프트 문자열에 그 계약 문안이 그대로 담겨야 한다 — 프롬프트는
  `references/verifier-prompt-fallback.md`(diff·이슈 본문·lessons 를 **동봉**하는 판) 하나이고,
  `references/verifier-prompt.md` 는 내장 리뷰어(codex) 전용이라 여기선 안 쓴다.
- `VERIFIER_TIMEOUT_MIN` — `VERIFIER`(및 폴백) 스폰 1회당 벽시계 상한(분). 스폰 시각 + 이 값을
  데드라인으로 폴링하고, 데드라인을 넘기면 `TaskStop` 으로 끊어 verdict 미산출로 간주한다(#96).
  **값은 `scripts/lib/constants.sh` 의 `CODEX_GATE_TIMEOUT`(초)을 분으로 환산한 것**이다.
- 절대 금지: production 무인 배포(4단계는 **배포 레인(deploy-cycle) 인계** — closeout 자신은 실 배포를
  하지 않는다) · 프로덕션 포인터 브랜치(release 등) 무인 승격(검증된 SHA 를 프로덕션/워커가 당기는
  브랜치로 미는 것도 배포와 동급으로 **배포 레인의 몫**이다) · main 직접 push(문서 reconcile 도 PR 브랜치
  경유) · `harvesting` 점유 없이 머지 · issue-runner 가 만든 워크트리/브랜치 조작 · issue-runner 의
  "절대 머지 안 함" 불변 훼손.

(근거: closeout-rationale §1)

## ① Reconcile

`$SCRIPTS/closeout-reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged_cleanup` — 머지·라벨·worktree 정리가 끝났다(머지 확정 시 PR head `agent/issue-N` 을 파싱해
  `cleanup-worktree.sh ... --merged` 까지 그 스크립트가 한다). 단 아래 마커표에서 4·6단계 미완 마커가
  발견되면 그 단계부터 이어간다 (멱등 재개).
- `resume` — PR 이 OPEN 이고 `harvesting` 유지 중. **마커표를 보기 전에** 아래 반송 상태표를 먼저 본다.
- `lookup_failed` — PR **상태를 못 읽었다**(gh 실패·빈 응답, #433). CLOSED 가 아니다 — 라벨을 떼지 않고
  **무접촉**, 다음 틱이 재조회한다. ④ Report 에 `보류: PR #<pr>(<repo_short>) — 상태 조회 실패` 한 줄.
- `human_hold` — PR 이 OPEN 인데 `needs-human` 이 붙어 있거나(사람이 조사 중) 그 라벨을 못 읽었다
  (`why` 로 갈린다). **무접촉** — ④ Report 에 `보류: PR #<pr>(<repo_short>) — 사람 보류(<why>)` 한 줄만
  남기고 이 틱엔 더 건드리지 않는다. **해제 경로**: 사람이 `needs-human` 을 떼면 다음 틱에 `resume` 로
  돌아온다(`harvesting` 은 그대로라 이 PR 이 레인 밖으로 새지 않는다).
- `stale` — 보고만 한다.

멱등 마커표 (끝난 단계 재판정용 — 재개 시 중복 작업 방지):

| 단계 | 마커 | 재개 판정 |
|---|---|---|
| 1 검증 | PR 코멘트 `마감 검증: ✅` | `$SCRIPTS/closeout-step1-marker.sh <repo> <pr>` 가 **정확히 `skip`** 일 때만 1단계 건너뜀 — `verify` 와 비0(조회·파싱 실패)은 전부 **수행**이다 |
| 2 머지 | PR `MERGED` | MERGED 면 머지 끝 (머지 직후 worktree 정리 포함) |
| 3 reconcile | 계획문서 diff(머지 커밋) + epic 코멘트 | 머지에 포함이면 끝 |
| 4 배포 | `배포 대기:` 코멘트 / `deployed:<sha>` | 있으면 재요청 안 함 |
| 5 후처리 | `✅ 스모크` 코멘트 / 배포 이슈 CLOSED + 검증·배포 완료 코멘트 | 있으면 재스모크 안 함 (배포 레인(deploy-cycle)이 검증까지 마치고 닫은 경우 포함) |
| 6 파생 | `파생 판정:` 코멘트(#411 — 갈래 조치가 전부 끝난 뒤 마지막에 남긴다) · 생성 이슈 번호(`파생:`) 코멘트 | `파생 판정:` 이 있으면 6단계 끝(ⓔ 0건 포함) · `파생:` 만 있으면 그 이슈는 재발행 안 함 |

**1단계 마커 판정은 `closeout-step1-marker.sh` 한 자리다** — ⒜ 가장 늦은 `마감 검증:` 이 `⚠ 보류` 인가
⒝ 마커가 현재 head 커밋보다 이른가 ⒞ 마커가 최신 반송 마커보다 앞인가, 셋을 AND 로 그 안에서 판정한다
(반송 마커 집합·선후는 `bounce-state.sh --marker-index` 로 받는다 — 마커 매칭을 두 벌로 두지 않는다,
#171). 여기서 따로 따지지 마라.

**`resume` 의 재개 지점은 마커표보다 반송 상태가 먼저다 (#271).** `$SCRIPTS/bounce-state.sh <repo> <pr>` 를
한 번 돌리고 그 값으로 재개 지점을 정한다(①-b 가 쓰는 것과 **같은 한 자리**). 값 넷 다 행선지가 있다:

| `bounce-state.sh` | 뜻 | `resume` 재개 지점 |
|---|---|---|
| `ok` | 반송 마커가 없거나, 최신 반송 마커 뒤 마지막 판정이 `머지 판정: ✅` | **마커표 그대로** — 끝난 단계를 건너뛰고 중단 지점부터 |
| `bounced` | 최신 반송 마커 뒤에 판정 코멘트가 없거나 그중 마지막이 `머지 판정: 🔄` | 마커표를 **보지 말고** ③-1 ⓐ 의 `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` **재시도 지점**에서 이어간다(아래 절) — 1단계 재검증·2단계 머지로 가지 않는다 |
| `held` | 최신 반송 마커 뒤 마지막 판정이 `머지 판정: ⚠ 보류` | **`active` 취급 무접촉** — ④ Report 에 `보류: PR #<pr>(<repo_short>) — 반송 뒤 워커 ⚠` 한 줄만 남긴다 |
| 무출력(exit 1 — 판정 실패) | 코멘트 조회·파싱 실패 | **`active` 취급 무접촉** + ④ Report 에 `BLOCKED: 반송 판정 실패 PR #<pr>(<repo_short>)` |

**`bounced` 재개 절차 — 전이를 다시 걸기 전에 점유부터 맞춘다.**
`gh issue view <issue> --repo <repo> --json labels` 로 이슈 쪽을 먼저 보고 갈라라
(PR 쪽은 `harvesting` 이 있어야 애초에 `resume` 이 난다):

- 이슈에 `agent:claimed` 가 있다 = **교체 워커가 살아 있다.** 전이를 걸지 마라 — `active` 취급 무접촉으로
  두고 ④ Report 에 `보류: PR #<pr>(<repo_short>) — 교체 워커 점유(agent:claimed)` 한 줄만 남긴다. 워커가
  `머지 판정: ✅` 를 찍으면 다음 틱 판정이 `ok` 로 바뀌어 마커표 경로로 저절로 돌아온다.
- 이슈에 `harvesting` 도 `agent:claimed` 도 없다 = **반쪽 회수.** 먼저
  `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` 를 한 번 더 걸어 양쪽을 맞추고(멱등이라 PR
  쪽은 no-op) 아래로 간다. 비0이면 ④ Report 에
  `BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올리고 이 틱엔 끝이다.
- 양쪽에 `harvesting` 이 있다 = 온전한 회수. 그대로 아래로 간다.

그런 다음 ③-1 ⓐ 의 **전이 호출만** 다시 건다 — **반송 코멘트는 다시 남기지 마라.** 그 재시도가 **또**
실패하면 ③-1 ⓐ 의 실패 갈래 그대로(회수 호출 한 번 + `BLOCKED: 전이 실패 closeout-redispatch …`)이고,
④ Report 의 `BLOCKED:` 줄로만 남긴 뒤 **그 틱은 그 PR 을 더 건드리지 않는다**(같은 틱 안에서 다시 돌리지
마라 — 무한 재시도 금지). 다음 틱의 `resume` 이 같은 자리를 다시 집는다.

**에픽 스윕 (① 끝, 매 틱)** — `cd` 없이 `"$SCRIPTS/epic-sweep.sh"` 를 실행한다(스코프는 루프 세션 cwd 의
`.loop/repos` 가 자동 적용). `Epic #N` 전용 줄로 leaf 를 찾아 **leaf 가 1건 이상이고 전부 CLOSED** 인
에픽만 닫는 결정론 스윕이고, 이벤트별 처리는:

- `closed` — 에픽을 닫았다(근거 코멘트 + `--reason completed`). ④ Report 에
  `에픽 종료: #N(<레포 짧은 이름>, leaf K)` 로 적는다(K = `leaves` 배열의 개수).
- `note` — **아무것도 안 건드린** 정상 상태. **보고하지 않는다.**
- `warn` — 판정을 **보류**했거나(leaf 검색·열린 이슈 목록이 상한에 닿음) 조회·쓰기가 실패했다(배포 대기
  이슈의 PR 조회 실패 포함). ④ Report 의 warn 줄에 `why` 를 그대로 옮긴다. 보류는 실패가 아니므로
  exit 0 일 수 있다.

exit 1 은 이 틱에 조회·쓰기 **실패**가 있었다는 뜻이다 — 다음 틱이 재시도하므로 손대지 마라(종료 근거
코멘트의 `<!-- epic-sweep -->` 마커가 멱등을 보장해 코멘트가 겹치지 않는다). 예외 둘:
`에픽 close 실패(N회 시도)` warn 과 `종료 근거 코멘트 실패 + 되읽기 실패` warn(#441)은 다음 틱이
**재시도하지 않을 수 있다** — why 그대로 Report 에 옮겨 사람이 닫거나 마커 코멘트를 지우게 한다.
exit 64 는 스코프 없음(`.loop/repos` 부재)이니 이 틱에 만진 레포를 `--repo <owner/repo>` 로 명시해 한 번
더 부르고, 그래도 없으면 `epic-sweep: 스코프 없음` 한 줄을 warn 으로 남긴다.

(근거: closeout-rationale §2 · §3)

## ①-b 정체 PR 스윕 — 완결 유실 회수 (매 틱)

`closeout-eligible.sh` 는 **`머지 판정: ✅` 마커가 있는 PR만** 후보로 올린다. 워커가 그 ✅ 를 찍기 전에
죽으면 그 PR 은 eligible.sh·issue-runner Maintain **양쪽 사각지대**에서 무한 적체한다 — 그 회수를 이
스윕이 소유한다. QUIET_TICKS 여도 매 틱 돈다. ✅ 신선도는 두 겹(`finish-classify.sh` 의 head-이후 증명 +
`bounce-state.sh` 반송 마커 안전망 — 마커 집합은 `재디스패치`(이 스킬 ①-b)·`재검증 실패`(verify-runner ④)
두 채널이고 그 배열·매칭 규칙은 `bounce-state.sh` 의 `BOUNCE_MARKERS` **한 자리**다)으로 막고, 코멘트·head 조회는 각각 `pr-comments.sh`·`pr-head-at.sh`
**한 자리**로 읽는다(`gh pr view --json comments|commits` 의 100건 상한을 피한다 — 그 경로를 쓰지 마라).
head 조회는 **코멘트를 읽은 뒤**에 한다.

**대상**: `me=$(gh api user -q .login)` 후 `gh api -X GET search/issues -f q="user:$me
is:open is:pr" -f per_page=100 -f sort=created -f order=asc`(FIFO)로 열린 PR 을 모으고,
head 가 `agent/issue-*` 이고 **`full-cycle` 미부착**(사람 세션 레인 소유 표시, #246)이며
**`harvesting` 미부착**이며 **`flow:verify` 미부착**·**`verifying` 미부착**이고
**`needs-human` 미부착**이며 **`hold:` 접두 미부착**인 PR 마다 판정한다. 두 라벨은 **다른 정지**다(#244) —
`needs-human` 은 사람이 직접 세운 정지고, `hold:<사유>` 는 기계 정지(verify-held·closeout-blocked·
디스패처 runner-held 보수 상한) 그 자체다. 그 라벨이 떨어지기 전엔 절대 집지 않는다 — 해제는 사람이
(`hold:conflict`·`needs-human`) 또는 재개 스윕이(`hold:ladder`·재심을 통과한 `hold:policy`) 한다. 판별은
**접두**라 사유가 늘어도(`hold:<새사유>`) 안 깨지고 `holding`·`on-hold`·`area:hold` 는 걸리지 않는다.
**`flow:verify`(검증대기)·`verifying`(검증 중 — verify-runner 점유 라벨, `harvesting` 동형, #275) PR 은
verify-runner 소유라 여기서 절대 집지 않는다.** 이 배제는 1) CONFLICTING 갈래에도 그대로 적용된다 —
대상 필터가 먼저다(#206). 같은 네 라벨 필터가 `closeout-eligible.sh` 에도 있다 — 한쪽만 고치면 스윕과
후보 게이트가 갈린다.

**1) 반송 마커 게이트 먼저 — 갈래를 가르기 전에, CONFLICTING·MERGEABLE 공통**(#218):
mergeable 값을 보기 **전에** `$SCRIPTS/bounce-state.sh <repo> <pr>` 를 한 번 돌려라.
출력은 `ok`/`bounced`/`held` 세 값이다. 판정 규칙은 한 줄이다: **최신 반송 마커 뒤에 오는 판정
코멘트(`머지 판정: ✅`/`⚠ 보류`/`🔄`) 중 가장 늦은 것이 결과를 정한다** — ✅ 면 `ok`, ⚠ 면 `held`,
`🔄` 면 `bounced`.

- `held` 이거나 **출력이 없으면(exit 1 — 판정 실패)** → `active` 취급 **무접촉**, 여기서 멈춘다
  (mergeable 도 안 보고 2) finish-classify 도 안 부른다). **`held` 도 스윕은 needs-human 으로 승격하지
  않는다**(#218 두 번째 회차, 사람 결정 (c)).
- `bounced` 면 → **원칙은 같은 무접촉**이다. 그 무접촉에 **예외 갈래 하나**만 연다(#206):
  - `gh pr view <pr> --repo <repo> --json mergeable` 이 **CONFLICTING** 일 때만 2) 의
    `$SCRIPTS/finish-classify.sh <repo> <pr> [<이슈>]` 로 분류하고, 출력이 `stale_reverify` 또는
    `stale_inline` 이면 **재디스패치**한다(2) 표의 `stale_reverify` 행과 같은 조치 —
    `closeout-redispatch` 전이 + 멱등 마커). `stale_inline` 도 입양(머지)하지 않는다.
  - **반송 마커 시각도 스테일 클록에 든다(#308)** — 반송 전이가 `agent:claimed` 를 떼므로 **반송 직후
    디스패처가 다시 붙이기 전 라벨 공백 창**에서는 진행 증거 세 축이 전부 old/none 이다. 그 창에서는
    `finish-classify.sh` 가 `active` 를 내므로 이 갈래가 열리지 않는다(마커 판별은 `bounce-state.sh`
    한 자리를 되물어 얻는다 — 마커 집합 두 벌 금지).
  - **MERGEABLE 인 `bounced` 는 전부 무접촉**이다. CONFLICTING 이어도 그 밖의 출력
    (`active`·`done_verdict`·`held`)은 **무접촉**이다 — `done_verdict` 는 ✅ 정상 경로라
    `closeout-eligible.sh` 가 자기 반송 안전망과 함께 소유한다.
- 출력이 정확히 `ok` 일 때만 → `gh pr view <pr> --repo <repo> --json mergeable` 로 갈라라:
  - CONFLICTING 이면 → **입양(rebase 경로)**: ② Pick 후보로 넘기고 ③ 2단계에서 closeout 이 직접
    rebase 후 머지(2단계 conflict 경로). (finish-classify 는 건너뛴다.)
  - 아니면(MERGEABLE 등) → 2) `finish-classify.sh` 로 계속.

**살아 있는 워커는 finish-classify 가 막는다.** 그 헬퍼는 🔄 계열 갈래를 내기 전에
`progress-evidence.sh`(#200 이 세운 진행 증거 술어 — ① 최신 커밋이 `STALL_MIN` 이내 ② 그 head SHA 의
CI 티켓이 큐에 살아 있음 ③ **현재 회차의 `agent:claimed` 가 `ISSUE_TIMEBOX_HOURS` 안에 붙었음**)에 물어
증거가 있으면 `active` 를 낸다. **술어는 그 파일 한 자리다** — `timebox-check.sh` 가 부르는 바로 그
자리이고, 여기에 두 번째 계산기를 만들지 마라. 진행 증거를 **판정하지 못한 경우**도 `active` 다
(queue.log 를 못 읽음·`pr-head-at.sh` 실패·claim 조회 실패 — `unknown` ≠ `none`).
claim 조회는 `$SCRIPTS/claim-at.sh <repo> <이슈>` **한 자리**(타임라인의 마지막 매칭 인덱스로 부착 여부
판정 — `bounce-state.sh` 와 같은 규율)이고, 그래서 2) 의 분류 호출이 이슈 번호를 함께 받는다
(`finish-classify.sh <repo> <pr> [<이슈>]` — **head 의 `agent/issue-N` 이 1순위**이고
`closingIssuesReferences` 는 폴백이다). **`agent:claimed` 의 *존재* 는 입양·배제 판정에 쓰지 마라**
(#196 3항) — 판정은 코멘트 마커 하나로 한다. 반송 판정도 `bounce-state.sh` 한 자리이고
`closeout-eligible.sh` 가 같은 자리를 부른다(로직 두 벌 금지).

**2) 위 1) 의 반송 게이트를 `ok` 로 통과했으면 `$SCRIPTS/finish-classify.sh <repo> <pr>` 로
결정적 분류** — 이 헬퍼가 최신 `머지 판정:`/`검증자 리뷰:` 코멘트와 `STALE_FINISH_MIN` 시간버퍼로
상태를 낸다(손수 코멘트 파싱 대신 테스트된 헬퍼 재사용). **살아있는 워커·시간버퍼 미도달은 `active` 로
걸러져 레이스가 방지된다** — 별도 신선도 게이트가 필요 없다:

| finish-classify 출력 | 뜻 | 조치 |
|---|---|---|
| `done_verdict` | 최신 `머지 판정: ✅` **이고 그 판정이 현재 head 커밋 이후임이 증명됨**(#171) | eligible.sh 정상 경로가 처리 — 스윕은 skip |
| `stale_inline` | 🔄 + 검증자 CLEAN + 버퍼 초과 (검증까지 도달·최종판정만 유실) | **입양(머지)** — ② Pick 후보로. ③ 1단계가 **독립 재검증** 후 마감. **새 이슈 안 만듦**. 단 위 1) 의 `bounced` 갈래에서 나온 `stale_inline` 은 **입양하지 않고 재디스패치**한다 |
| `stale_reverify` | 🔄 + 검증자 부재/미해결 BLOCKER + 버퍼 초과 + **진행 증거 없음**(#206) (검증 전 사망·구현 미완 가능) | **재디스패치** — `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` (연결 이슈를 `agent-ready` 로 되돌리고 `agent:claimed`·단계 라벨을 뗀다) → 새 워커가 같은 브랜치서 검증자 재실행→체크박스→최종판정으로 완결. 멱등 마커(아래) |
| `no_verdict` | `머지 판정:` 코멘트가 **0건** + **CI 초록**(실패 0 이고 미완료 0 — 도는 체크가 하나라도 있으면 이 계급이 아니다, #421) + 버퍼 초과 + **진행 증거 없음**(#396). 코멘트 **조회 실패**는 이 계급이 아니다(`active`) | **재디스패치** — 바로 위 행과 **같은 조치**다(사인도 같다). **연결 이슈가 없으면 무접촉** — 전이를 부르지 말고 ④ Report 에 한 줄로 올려 사람이 보게 하라 |
| `held` | 최신 `머지 판정: ⚠ 보류` (워커 명시 보류) | **정지(`hold:policy`)** — `$SCRIPTS/transition.sh closeout-blocked <repo> <issue\|-> <pr> --reason policy --note "<질문 한 줄>"` (PR 과 연결 이슈 **양쪽**에 `hold:policy` 부착 + 단계 라벨 정리. **`needs-human` 은 안 붙는다**(#244) — 사람 호출은 재개 스윕 ③ 의 재심이 "사람 몫 유지" 로 끝났을 때만 `transition.sh policy-kept` 가 붙인다), closeout 무접촉 |
| `active` | 진행 중·버퍼 미도달·우리 형상 아님, 또는 **✅ 의 신선도를 증명 못 함**(#171), 또는 **진행 증거가 있음**(또는 그 판정 자체가 불가) | **무접촉**(다음 틱) |

**flow:\* 보조 신호**: `flow:ready` 없이 `flow:codex`/`flow:ci` 만 있고 오래된 PR 은 그 자체로 "검증 중
워커 사망"의 방증이다(라벨은 이 스킬 밖 워커 런타임이 세팅 — 있으면 보조로 참고, 없으면 finish-classify
결과만으로 판정).

**재디스패치 멱등 마커 (필수)**: `stale_reverify`·`no_verdict` 재디스패치 시 PR 에
`$SCRIPTS/bounce-comment.sh redispatch <repo> <pr> <이슈>` 로 코멘트를 남긴다(문구를 손으로 옮겨 적지
않는다 — 콜론·어순이 변형되면 `bounce-state.sh` 반송 안전망이 놓친다, #212. 생성되는 본문은
`재디스패치: #<이슈> — 완결 유실(검증 전 사망) <!-- bodat:worker -->`). **이 마커가 이미 있고 그 이후
새 커밋·검증자 코멘트가 없으면 재발행하지 않는다**(/loop 스팸 방지, 6단계 파생 마커 동형). 재디스패치
자격은 `open + agent-ready + ¬agent:claimed`(`eligible-issues.sh`)이라 `closeout-redispatch` 전이가 그
둘을 한 번에 맞춘다(손으로 `gh issue edit` 하지 마라). 위 두 전이 모두 **비0이면**
`references/state-machine.md` 의 「전이 실패의 공통 규칙」 대로 ④ Report 에
`BLOCKED: 전이 실패 <전이> PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다(규칙은 여기서 다시 적지
않는다). 재디스패치가 성사되면 issue-runner Dispatch 가 make-worktree 로 기존 `agent/issue-N` worktree
를 재사용해 **같은 PR 브랜치에서 이어 완결**하므로 새 PR 이 생기지 않는다.

입양 후보(rebase·`stale_inline`)는 ② Pick 이 소비하고, 재디스패치·needs-human 건수는 ④ Report 에
집계한다.

(근거: closeout-rationale §4 · §5 · §6 · §7 · §8)

## ② Pick — 한 번에 1 PR (MAX_CLOSEOUT=1, 동시성 1)

`$SCRIPTS/closeout-eligible.sh` 출력(✅ 마킹된 정상 후보)과 **①-b 스윕의 입양 후보**
(`stale_inline`·CONFLICTING)를 합쳐 FIFO **첫 후보 1개만** 집는다. 한 번에 1개라 모듈 겹침 판단은
불필요하다 (직렬 마감 — 이 PR 을 끝까지 마감한 뒤에야 ⑤ Drain 이 다음 후보를 집는다). 집으면 즉시
`$SCRIPTS/transition.sh closeout-pick <repo> - <pr>` 로 점유를 선언하라(이슈 번호는 ③-1 에서야
파싱되므로 여기선 `-`). 전이가 `harvesting` 을 붙이고 워커·verify-runner 단계 라벨
(`flow:ready`·`flow:codex`·`flow:ci`·`flow:verify`·`verifying`)을 함께 뗀다 — `harvesting` 이 있어야
issue-runner ② Maintain·verify-runner 가 이 PR 을 건드리지 않고(verify-eligible 도 harvesting 을
제외한다), PR 리스트에서 `harvesting` 하나만 남아 "마감 중"이 명확해진다. 후보가 0이면 ③ 파이프라인을
건너뛰고 ④ Report 에 clean no-op 으로 보고한다.

**라벨 부재 자동 보강은 전이가 한다** — 메커니즘과 자리별 폴백은 `references/loop-conventions.md` §8
「라벨 이동」 행 대로. 보강도 실패하면 exit 2 로 떨어지니 이 PR 을 skip 하고 ④ Report 에
`BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 보고한다
(`setup-labels.sh` 재실행 전에는 `harvesting` 라벨이 없을 수 있다 — 기존 레포 공통).

**원 이슈 미러(진행 가시화).** ③-1 에서 `<issue>`(PR 본문 `Closes #N`/`Refs #N`)를 파싱한 직후, 연결
이슈가 있으면 `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` 를 **다시** 부른다(멱등 — PR
쪽은 이미 맞아 no-op, 이슈 쪽만 `harvesting` 으로 옮겨진다). **이 미러 호출이 비0이면 머지로 진행하지
마라** — `references/state-machine.md` 의 「전이 실패의 공통 규칙」 대로 이 PR 을 skip 하고 ④ Report 에
`BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.

그리고 ③ 이후 **fail-closed 로 손을 떼는 모든 지점**(위임 fail·conflict 사람판단·문서 reconcile 미완 등)은
반드시 `closeout-blocked`(사람에게) 또는 `closeout-redispatch`(워커로 반송) **전이를 쓴다 — 손으로
`gh issue edit` 하지 않는다**. PR·이슈 양쪽의 `harvesting`·`flow:*` 정리를 전이 표가 보장한다.
`closeout-blocked` 는 **`--reason <conflict|policy|ladder> [--note "<질문 한 줄>" — policy·conflict 필수]`
가 필수**다(없으면 usage exit 64 — 사유 없는 정지를 만들 수 없다). rebase/semantic conflict 는
`conflict`(단 보안 경계·대범위 충돌은 `policy` — 2단계 CONFLICTING 항목의 판정, #344; `conflict` 의
`--note` 는 질문이 아니라 워커 재개 범위 한 줄이다), 그 외 루프가 못 정하는 스펙·정책·검증 미산출은
`policy`, 사다리(`~/.claude/skills/issue-runner/references/live-verification-ladder.md`)의 칸을 실제로
올라가 실패 출력을 인용한 경우만 `ladder` 다.

**`$SCRIPTS/closeout-eligible.sh` 의 stderr `blocked:` 줄은 ④ Report 로 옮긴다**(세 루프 공통 —
`references/loop-conventions.md` §3, #379). `✅ 이후 미해결 코멘트 N건` 은 "검증자가 확인한 경계
(✅ 의 `코멘트 스냅샷 N`, 없으면 ✅ 자리) **뒤에** 사람 리뷰가 남아 fail-closed 로 안 집었다"는 뜻이고,
루프가 스스로 풀지 않는다 — 풀리는 길은 verify-runner 가 재검증해 새 ✅ 를 찍는 것뿐이다. 사람 답글은
풀지 않는다. 즉 사람이 할 일은 PR 을 `flow:verify` 로 되돌리는(또는 `verifying` 재집) 것이다. 그 전엔 매
틱 같은 줄이 반복되는 것이 정상이다. `warn` 이 아니라 `막힘` 인 이유는 `references/loop-conventions.md`
§2 의 채널 경계 대로다.

(근거: closeout-rationale §9)

## ③ 파이프라인 — 1~6단계

집은 PR 에 대해 아래 6단계를 순서대로 수행한다. 각 단계 끝에 마커 명령을 박아 (① Reconcile 마커표)
다음 틱이 멱등 재개할 수 있게 한다. (근거: closeout-rationale §10~§15)

**1단계 — 계획 부합 검증 — `general-purpose` 한 번, codex 없음(#375).** `<issue>` 는 PR 본문의
`Closes #N` / `Refs #N` 전용 줄에서 얻는다(`gh pr view <pr> --repo <repo> --json body` 로 파싱 — 그 줄의
생산·소비 규약은 `references/loop-conventions.md` §5). 정확성 리뷰는 verify-runner 가 이미 codex 로
마쳤다(`머지 판정: ✅` 가 이 단계의 전제). 여기서는 **계획 부합만** 본다: 이 변경이 이슈 AC/플랜을
충족하는가, 범위 이탈은 없는가. 호출은 ## 상수 `VERIFIER`(general-purpose) 하나, 프롬프트는
`references/verifier-prompt-fallback.md` 의 placeholder 를 채운 것 — `<DIFF>`=`gh pr diff <pr> --repo <repo>`
출력, `<ISSUE_BODY>`=`gh issue view <issue> --repo <repo>` 출력(연결 이슈 없으면 빈 문자열),
`<PLAN_REF>`=이슈 `## Plan` 또는 참조한 `Plans/*.md`(없으면 빈 문자열), `<LESSONS_OR_"없음">`=
`$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑 **`.loop/lessons-verifier.md`**(검증 판정 사례집 — 과거 오판 패턴
주입; 없으면 `.loop/lessons.md` 폴백, 둘 다 없거나 비면 `없음`. `lessons.md` 는 **구현 워커**용이라 섞지
않는다). 지시문은 "계획/이슈 AC 충족 여부만 판정, 미충족·범위 이탈은 `[P1]`, 경미한 편차는 `[P2]`" 를
명시한다. 스폰은 `run_in_background` + `VERIFIER_TIMEOUT_MIN` 데드라인 + 초과 시 `TaskStop`. 데드라인
초과·verdict 없는 응답은 **미산출**이다 — 같은 프롬프트로 **한 번만** 재시도하고, 그래도 미산출이면 아래
ⓑ 로 보류 종료한다(fail-closed — 절대 머지로 진행하지 않는다, #96). 워크트리(`make-worktree.sh`)는 이 단계에 필요 없다 —
3단계가 자기 몫으로 확보한다. `codex-review-gate.sh` 는 이 단계에서 부르지 않는다.
- 판정: BLOCKER → BLOCKER. CLEAN/NIT/WARN → 통과(`[P3+]` = NIT 는 비차단).
  머신 코멘트 마커(필수): 아래 `gh pr comment` 로 남기는 마감 검증 코멘트는 **마지막 줄에
  `<!-- bodat:worker -->`** 를 포함한다 — 생산/소비 규약과 빠뜨렸을 때의 결말은
  `references/loop-conventions.md` §4 대로.
- **중복 — 루프가 직접 닫는다 (사람에게 넘기지 않는다).** 검증자가 "이슈가 요구한 수정이
  **이미 `origin/main` 에 있다**" 또는 "이 PR 은 다른 PR 과 중복" 으로 판정하면 — BLOCKER 로도 CLEAN 으로도
  취급하지 마라. 근거 커밋을 확인한 뒤(`git log origin/<default>` 에서 그 수정을 담은 SHA) 한 줄로 닫는다:
  `$SCRIPTS/transition.sh closeout-dup <repo> <issue> <pr> --note "<근거 커밋·사유>"`
  — PR 을 머지 없이 닫고, 이슈에 근거를 남기고 닫으며, 단계 라벨을 정리하고 PR 에 `dup` 라벨을 남긴다.
  **`needs-human` 을 붙이지 마라.** → **dup 종료** (머지하지 않는다). **전이가 비0이면**
  `references/state-machine.md` 「전이 실패의 공통 규칙」 대로 ④ Report 에
  `BLOCKED: 전이 실패 closeout-dup PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다. 판정이 "중복인 것
  같다" 수준이면 dup 가 아니다 — 근거 커밋을 못 짚으면 아래 BLOCKER 경로(`--reason policy`)로 간다.
- BLOCKER(미산출 포함, 사유 예 `검증자 미산출 — 타임아웃(>VERIFIER_TIMEOUT_MIN분)` / 모델 오류 원문)
  → **갈래가 둘이다. 판별 기준 한 줄: 구현으로 닫히는 결함이면 ⓐ 워커 레인 반송, 스펙·정책 선택이 남아
  있으면 ⓑ 사람 보류다.** (연결 이슈가 없으면 — PR 본문에 `Closes`/`Refs` 가 없어 `<issue>` 를 못 얻으면 —
  되돌릴 이슈가 없으니 ⓐ 는 불가, ⓑ 로 간다.)
- ⓐ **구현으로 닫히는 결함 → 워커 레인 반송.**
  `$SCRIPTS/bounce-comment.sh closeout-blocker <repo> <pr> <issue> "<사유>"` 로 반송 코멘트를 남긴다 —
  **문구를 손으로 옮겨 적지 마라**(#212 · #171). `<사유>` 는 워커가 그대로 읽고 고칠 수 있게 무엇이 왜
  막혔는지로 쓴다(`redispatch` 채널의 고정 문구를 빌려 쓰지 마라).
  **코멘트가 0으로 끝났다면 이어서** `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`
  로 연결 이슈를 `agent-ready` 로 되돌린다(`agent:claimed`·단계 라벨·`needs-human`·`hold:*` 를 뗀다 —
  손으로 `gh issue edit` 하지 마라) → **`blocked` 종료**(머지하지 않는다. 새 종료 상태를 만들지 않는다 —
  ④ Report 에는 `재디스패치 N` 으로도 함께 집계한다). 재디스패치가 성사되면 issue-runner Dispatch 가
  같은 `agent/issue-N` worktree 를 재사용해 **같은 PR 브랜치에서 이어 완결**한다.
  **전이가 비0이면** `references/state-machine.md` 「전이 실패의 공통 규칙」 대로 ④ Report 에
  `BLOCKED: 전이 실패 closeout-redispatch PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올리고,
  **곧바로 `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` 를 한 번 더 걸어 PR 과 이슈 양쪽의
  점유를 되살려라**(③-1 의 원 이슈 미러와 같은 호출 — 멱등이고, 손으로 라벨을 옮기지 않는다). 이 갈래엔
  연결 이슈가 **항상** 있으니 ② Pick 의 `<repo> - <pr>` 형태로 부르지 마라. 그 한 호출이 `transition.sh`
  의 실패 갈래 셋(㉠ PR 편집 성공·이슈 편집 실패 exit 2 · ㉡ 양쪽 편집 성공·PR readback 불일치 exit 1 ·
  ㉢ 양쪽 편집 성공·이슈 readback 실패 exit 1/2)을 **전부** 전이 이전으로 되돌린다 — 상태를 먼저 조회해
  갈라 부르지 마라(부착은 멱등이다).
  셋 다 점유가 전이 이전으로 돌아가면 다음 틱 ① Reconcile 이 그 PR 을 `resume` 으로 다시 집고, **그 재개
  지점은 마커표가 아니라 반송 마커가 정한다** — ① Reconcile 의 `resume` 값표대로 `bounce-state.sh` 가
  `bounced` 인 한 마커표를 보지 말고 **바로 위 전이 호출 자리**에서 같은 전이를 다시 건다
  (`closeout-redispatch` 는 멱등이라 재실행이 무해하다, #157). 되살리기까지 실패하면 ④ Report 의 두
  `BLOCKED` 줄이 그대로 사람 신호다.
  **코멘트가 비0으로 끝나면(gh 실패·인자 오류) `closeout-redispatch` 를 하지 마라** — 반송 마커 없이
  이슈만 `agent-ready` 로 돌아가면 옛 ✅ 로 다시 집혀 온다. **대신 이 회차를 ⓑ 로 접는다**:
  `$SCRIPTS/transition.sh closeout-blocked <repo> <issue> <pr> --reason policy --note "반송 코멘트 게시 실패 — <stderr 한 줄>"`
  로 **사람 보류**로 내린다 → **`blocked` 종료**(새 종료 상태를 만들지 않는다). ④ Report 에는
  `BLOCKED: 반송 코멘트 실패 PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.
  **그 전이까지 비0이면** 그 PR 의 종료 상태를 바꾸지 말고 ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>` 을 한 줄 더 올린 뒤
  **이 틱에서는 그 PR 을 더 건드리지 마라**. 다음 틱의 `resume` 은 원장에 반송 흔적이 없어 마커표 경로로
  가고, 거기서 ③-1 이 다시 도는 것을 보장하는 것은 `closeout-step1-marker.sh` 의 ⒜⒝⒞ 판정이다.
- ⓑ **스펙·정책 선택이 남아 있다(검증자 미산출 포함 — 재시도 1회 뒤) → 사람 보류.**
  `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <사유>
  <!-- bodat:worker -->"`
  + `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  (PR 의 `harvesting` 제거 + PR 과 연결 이슈에 `hold:policy` 부착·단계 라벨 정리 — `needs-human` 은 안
  붙는다, #244) → **blocked 종료** (머지하지 않는다). 사유는 `policy` 다(`conflict` 도 `ladder` 도 아니다).
  검증자 미산출은 **언제나 이 갈래다.**
  **전이가 비0이면** `references/state-machine.md` 「전이 실패의 공통 규칙」 대로 ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.
- CLEAN/WARN → `gh pr comment <pr> --repo <repo> --body "마감 검증: ✅ <CLEAN 또는 WARN n>
  <!-- bodat:worker -->"` (이 코멘트가 1단계 완료 마커다).
- **거짓 BLOCKER 반전 기록 (lessons).** 이 PR 에 이전 틱의 `마감 검증: ⚠ 보류 — …` BLOCKER 코멘트가
  이미 있는데 이번 재검증이 CLEAN/WARN 이거나 사람이 정지를 풀고 원안 그대로 흐른 경우 — 그 BLOCKER 는
  거짓 판정으로 뒤집힌 것이다. `$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑 **`.loop/lessons-verifier.md`** 에
  `- [YYYY-MM-DD PR#<pr>] <거짓 BLOCKER 패턴 → 재발 방지 행동>` 1줄을 append 하고 캡까지 정리한다 —
  **`$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"` 한 자리로 부른다**(파일이 없으면 새로 만든다).
  **append 를 이 호출 밖에서 손으로 하지 마라**(#208). **캡: 항목 20개** — 초과 시 **항목 수가 캡 이하가
  될 때까지** 가장 오래된 항목부터 통째로 삭제한다(항목 = `- [` 로 시작하는 한 줄, 또는 `##` 헤더부터 다음
  항목 직전까지 — 줄 단위가 아니다). 반전이 아니면(정상 CLEAN) 기록하지 않는다.

**2단계 — 머지 게이트.** 머지 명령은 **반드시 `--repo <repo>` 를 넘긴다** — closeout 은 cwd 밖 레포의
PR 을 머지하므로 ci-gate 훅이 `--repo` 로 그 레포를 조회해야 fail-closed 를 안 맞는다(#47). 게이트 통과
조건: `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` (exit 0) + 워커가 남긴 `검증자 리뷰:` 코멘트가
BLOCKER 0 + `gh pr view <pr> --repo <repo> --json mergeable` ≠ CONFLICTING 재확인.
- **rebase된 HEAD 재검증 (`revalidate:true` 선행 게이트, #70).** ② Pick 이 집은 후보의 `revalidate` 가
  true 면(= `closeout-ci-pass.sh` 가 exit 2 — 현재 HEAD 의 로컬 CI 캐시가 비어 "fail 이 아니라 미실행"),
  위 exit 0 게이트를 판정하기 **전에** 현재 HEAD 를 재검증한다: `$SCRIPTS/make-worktree.sh --sync <repo> <N>`
  한 호출로 worktree 를 확보하고 **rebase된 원격 head 로 강제 동기화**한다(`<N>`=PR head `agent/issue-N`
  파싱, 3단계와 동일. 동기화 절차와 "기존 worktree 는 rebase 전 SHA 가 체크아웃된 채일 수 있다" 는 함정은
  그 스크립트 머리 주석이 SSOT 다 — #445). `--sync` 가 **exit 3(worktree 에 미커밋 변경 — 덮지 않았다)**·
  **exit 4(원격에 그 head 브랜치 없음)** 면 머지하지 말고 이 PR 을 skip 해 ④ Report 에
  `BLOCKED: worktree 동기화 실패 PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.
  이어 `$SCRIPTS/run-local-ci.sh <repo> <N>` 로 **현재 HEAD** 캐시를 채운다. `run-local-ci.sh` 가 비0
  (새 base 와의 통합이 깨짐)이면 머지하지 말고 fail-closed 로 보류 종료한다
  (`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` +
  `blocked` 종료, 새 종료 상태 안 만듦 — 이 전이가 비0이면 「전이 실패의 공통 규칙」 대로 ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>`). 0이면 캐시가 pass 로
  채워졌으니 아래 exit 0 게이트로 합류한다. 이 경로는 **3단계 doc 커밋 유무와 무관**하게 발동한다.
  (`revalidate:false` 면 캐시가 이미 pass 라 이 재검증을 건너뛴다.)

모두 통과면 **여기서 3단계(문서 reconcile)를 먼저 수행**해 PR 브랜치에 문서 커밋을 만들고 push 한 뒤 —
squash 머지가 그 문서 반영을 포함하도록 — `gh pr merge <pr> --repo <repo> --squash` (ci-gate 훅이 한 번
더 판정한다). 즉 단계 번호는 1→2→3 순서지만, 2단계의 머지 직전에 3단계 커밋을 끼워 넣는다 (3단계 헤더의
"머지 전"이 이 끼워넣기 지점이다). **`gh pr merge` 직전, 3단계가 새 doc 커밋을 push 했다면**
`$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` 가 pass(exit 0)인지를 짧은 한도 폴링(예: 2~3초 간격 × 최대
5회, 무한 대기 금지)으로 재확인하고 — 3단계의 `run-local-ci.sh` 가 캐시를 동기로 채우므로 보통 즉시
pass — 한도 내 pass 미도달이면 머지하지 말고 fail-closed 로 보류 종료한다(아래 3단계의 캐시 비0/미도달
처리와 동일 경로 — `closeout-blocked … --reason policy` 전이 + `blocked` 종료).
**`gh pr merge` 성공 직후** `$SCRIPTS/cleanup-worktree.sh <repo> <N> --merged` 를 호출해 이 PR 의
worktree(`agent/issue-<N>`)를 직접 정리한다. `--merged` 는 squash 머지로 원격 head 가 자동삭제돼 `@{u}`
가 사라지는 함정에서 미push 가드를 완화한다(더티 가드는 유지 — 더티면 warn 후 보류, best-effort).

- **CONFLICTING → closeout 이 직접 rebase 해서 진행한다.** skip 하지 않는다. `harvesting` 점유를 유지한 채:
  `$SCRIPTS/make-worktree.sh <repo> <N>` 로 worktree 확보(`<N>`=head `agent/issue-N`) →
  `git -C <wt> fetch origin` → `git -C <wt> rebase origin/<BASE>`(`<BASE>`=default branch).
  **conflict 가 나면 rebase 보수 에이전트를 동기 스폰**한다(worker-template
  `~/.claude/skills/issue-runner/references/worker-template.md` 를 읽어 placeholder 를 채우되 "절차"
  지시를 "이 worktree(`<WT_PATH>`)에서 `origin/<BASE>` 위로 rebase, conflict 를 원안 의도대로 해소,
  `git push --force-with-lease`, **merge 커밋 금지**. **못 풀면 `git rebase --abort` 후 종료 보고에 ⑴ 충돌
  파일 목록(경로 전부) ⑵ 왜 rebase 범위를 넘는지 — 필요한 추가 작업(예: 새 분기에 가드 + 무는 테스트 1건)을
  적어라**" 로 교체하고 push 규율·금지는 유지. 에이전트의 범위는 "리베이스와 그 결과로 깨지는 테스트
  정합만" 이다) → 에이전트 종료 후 `$SCRIPTS/run-local-ci.sh <repo> <N>` 로 rebased HEAD 캐시를
  재생성한다. 비0(새 base 통합 깨짐)이면 머지하지 말고 **위임 fail-closed**:
  `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` 로 연결 이슈를 `agent-ready` 로
  되돌려(또는 spinoff) 넘기고 blocked 종료. 0이면 위 exit 0 머지 게이트로 합류해 정상 squash 머지한다.
  에이전트가 conflict 를 **못 풀면**(rebase abort·반복 실패) semantic conflict 는 closeout 이 직접 풀지
  않는다(무인 강제 해소 금지) — 대신 **홀드 사유를 가른다**(#344). 재개 자체는 후속
  resume-sweep(`hold:conflict` 1회 자동 재개)이 한다:
  - **`--reason policy`** (사람 몫 — 자동 재개 대상 아님) — 둘 중 하나면: ⓐ **보안 경계** — 충돌 파일이
    인증·권한·세션·비밀(credential/secret)·외부 입력 검증·트러스트 바운더리 경로에 걸친다. 레포
    `CLAUDE.md` 가 보안 경계 경로를 지정하면 그것을 쓰고, 없으면 파일 경로·이름에 `auth`·`session`·
    `secret`·`credential`·`permission`·`policy` 가 들어가거나 에이전트가 해소 중 그런 코드를 건드려야
    한다고 보고한 경우. ⓑ **대범위** — 충돌 파일이 **4개 이상**이거나 PR 고유 커밋이 **6개 이상**
    (`git rev-list --count origin/<BASE>..HEAD`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
    — `--note` 는 사람이 답해야 할 질문 한 줄이되 어느 기준(보안 경계 / 범위)에 걸렸는지 명시한다
    (예: `보안 경계 — lib/auth/session.rb 충돌, 세션 만료 분기 어느 쪽?`).
  - **`--reason conflict`** (루프가 1회 자동 재개할 건) — 그 외 전부. `--note` 는 질문이 아니라 **재개
    워커가 받을 범위 한 줄**(워커 재개 범위 문형)로 쓴다. 문형:
    `충돌 <상대 PR #M>·<파일 목록> — 워커 재개 범위: origin/<BASE> 위로 rebase 해 원안 의도대로 해소 + <에이전트가 보고한 추가 작업>`
    (예: `충돌 #5114·client.rb, client_test.rb — 워커 재개 범위: origin/main 위로 rebase 해 원안 의도대로 해소 + proxy_push 분기 before_send: guard + 무는 테스트 1건`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason conflict --note "<워커 재개 범위 한 줄>"`
    에이전트 종료 보고에 충돌 파일 목록이 없으면(판정 입력 부재) "그 외" 가 아니라 **`policy` 로
    fail-closed** 한다(노트: `판정 입력 부재 — 에이전트가 충돌 파일 목록을 보고하지 않음, 워커 재개인가 사람인가?`).
    **연결된 열린 이슈가 없는 PR(`<issue>` 자리가 `-`)도 `conflict` 가 아니라 `policy` 다**(#345).
  어느 갈래든 blocked 종료한다(이 경로만 사유가 `conflict` 다). 두 전이(redispatch·blocked) 모두
  **비0이면** `references/state-machine.md` 「전이 실패의 공통 규칙」 대로 ④ Report 에
  `BLOCKED: 전이 실패 <전이> PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다.

**3단계 — 문서 reconcile (머지 전, PR 브랜치 커밋).** 1단계가 구현을 확인한 계획문서 절의 `- [ ]` 를
`- [x]` 로 바꾼다. PR 브랜치 worktree(`$SCRIPTS/make-worktree.sh <repo> <N>` 로 확보 — `<N>`=PR head
브랜치 `agent/issue-<N>` 에서 파싱(`gh pr view <pr> --repo <repo> --json headRefName`), 멱등)에서
커밋·push 하여 squash 머지에 포함시킨다 (main 직접 push 금지). epic 이 있으면 진행 롤업 코멘트를 남긴다.
- **표면 교정 흡수 (같은 커밋에 얹는다).** 1단계 검증자의 WARN/NIT 중 **표면 교정** 부류는 6단계 파생
  이슈로 넘기지 말고 **여기서 직접 고쳐** 이 커밋에 같이 싣는다. **판정 기준·받는 것·막는 것은
  `references/loop-conventions.md` §10 한 벌이다**(verify-runner ⓪ 과 **같은 한 줄**). 기준을 통과하면
  여기서 고치고, 하나라도 걸리면 6단계 이슈다.
  - 고친 것을 **원본 PR 코멘트에 명시**한다: `표면 교정(closeout 3단계): <파일> — <무엇을>`.
  - 아래 캐시 보강이 비0(로컬 CI 실패)이면 **그 교정 커밋을 되돌리고** 원래 fail-closed 경로로 간다.
  - 검증자가 BLOCKER 를 냈거나 이 PR 이 보류·재디스패치로 가는 중이면 손대지 않는다(통과 판정 PR 한정).
- **캐시 보강 (push 직후, 옵션1).** doc 커밋을 push 했으면 **그 직후** `$SCRIPTS/run-local-ci.sh <repo> <N>`
  를 1회 호출한다 (`<N>`=위에서 파싱한 이슈 번호 — worktree 경로 `issue-<N>` 식별용;
  `closeout-ci-pass.sh` 의 `<pr>` 와 다름). 이 헬퍼가 worktree HEAD SHA 를 읽어 `repo-dir.sh` 로 **메인
  레포 slug** 의 로컬 CI 캐시를 채운다 — 2단계 머지 게이트가 읽는 바로 그 위치다. **호출 전 멱등 가드**:
  `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` 가 이미 pass(exit 0)면 `run-local-ci.sh` 를 재실행하지 않는다.
  `run-local-ci.sh` 가 비0(=bin/ci 실패)이면 캐시가 pass 로 안 채워진 것이므로 머지하지 말고 fail-closed 로
  보류 종료한다(`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  + `blocked` 종료 — 이 전이가 비0이면 「전이 실패의 공통 규칙」 대로 ④ Report 에
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <stderr 한 줄>`).
- **단일 이슈 degrade**: `Plans/*.md`·`## Plan` 이 없으면 문서 편집을 skip 한다. epic 이 없으면 롤업을
  skip 한다. 이슈 자체 체크박스만 reconcile 한다. 둘 다 없으면 이 단계는 no-op — **새 doc 커밋·push 가
  없으므로 위 캐시 보강도 건너뛴다**(채울 새 HEAD SHA 가 없다).

**4단계 — 배포 레인 인계 (dry-run).** **closeout 은 실 배포를 하지 않고 배포 대기 이슈를 deploy-cycle
루프에 넘긴다.** `references/deploy-check-issue.md` 를 채워(`<DEPLOY_CMD>`=레포 배포 엔트리포인트, 모르면
"레포 배포 절차"; `<VERIFY_URL>`=production 베이스 URL — 5단계 스모크가 몰 주소, 모르면 빈 줄로 둬
5단계가 URL 도달불가로 폴백; `<LIVE_CHECKS>`=PR test plan·이슈 본문에서 "배포 후 라이브 검증"·하드웨어/
실장비 검증 등 **머지 후에만 수행 가능하다고 표기된 항목** — 1단계 검증자가 머지 게이트에서 제외한 범위
밖 검증 항목의 유일한 이관 목적지다).

**`<LIVE_CHECKS>` 는 두 형태 중 하나여야 한다 — 산문 금지.**
- 배포 후 밟을 게 **하나도 없으면** 정확히 `없음` 한 단어. 뒤에 설명을 붙이지 마라.
- 있으면 **`- [ ]` 체크박스 목록**. 한 줄 = 배포 뒤 `e2e-test` 가 한 번 밟는 동작. 배경·근거·주의는
  `## 변경 요약` 에 쓰고 여기엔 밟을 것만 남긴다.
- **실장비 줄은 접두 표식 `[칸 ③]` 필수** — `- [ ] [칸 ③] <동작>` 형태로 적는다. 표식은 `없음`·`- [ ]` 와
  **같은 등급의 형태 강제**다(#309). 칸 ①② 를 시도했다 실패해 옮겨진 줄에 "TEST 워커" 라는 말이 없더라도
  **밟는 칸이 ③ 이면 표식을 붙인다** — 판별의 근거는 문장 뜻이 아니라 표식이다.
- **표식 없는 줄은 크롬이 밟을 수 있어야 한다.** 칸 ③ 이 아닌데 브라우저 밖 수단이 필요한 줄이면 그
  수단을 줄에 적어 ⑦ 이 바로 밟게 하라.

**옮기기 전에 closeout 이 사다리를 한 번 올라간다 (시도 없는 `[ ]` 는 그대로 옮기지 않는다).** 워커가
남긴 미완 항목 중 **사다리 시도·인용 없이 `[ ]` 로만 남은 것**은 그대로 옮기지 마라 — closeout 이
`~/.claude/skills/issue-runner/references/live-verification-ladder.md` 의 **칸 ①(dev 서버)와
칸 ②(`bin/dry-run`·AdsPower 릴레이)** 를 **한 번씩** 시도한 뒤에 옮긴다(주체별 상한 표는
`references/loop-conventions.md` §9 — 이 루프의 상한은 칸 ② 다). **칸 ③(TEST 워커)은 배포 뒤
`e2e-test` 의 몫이다.** ①② 시도 결과를 함께 남겨 ⑦ 이 같은 칸을 반복하지 않게 한다.
- 칸 ①② 에서 **판정이 서면** 그 항목은 `<LIVE_CHECKS>` 에서 **뺀다.** 판정 근거는 PR 코멘트에 남긴다.
- **실패하면** 항목을 `- [ ]` 로 옮기되, **시도한 칸과 실패 출력(명령 한 줄 + 마지막 20줄)을 인용**한다.
  인용은 `## 변경 요약` 절에 적는다.
- 시도가 불가능한 환경이면(레포에 해당 진입점 없음 등) 그 사실을 `## 변경 요약` 에 한 줄로 적는다.
  "실장비 필요" 라는 서술만으로 시도를 건너뛰지 마라.

**분기 — 머지했으면 무조건 승격 티켓을 만든다 (사용자 결정, 2026-08-16). 머지된 PR 은 예외 없이 배포
대기 이슈를 하나 발행한다.** 판정하지 마라 — 테스트 전용이든 주석 한 줄이든, 머지됐다는 것은 승격 범위에
들어갔다는 뜻이고 그 사실이 사람에게 보여야 한다.

- **발행 명령 (필수 형태 — 산문으로 대체하지 마라).** 발행 절차 전체 — 제목 형태 · 본문 절 · 라벨 ·
  라벨 부재 3단 사다리 · 발행 직후 라벨 readback · PR 마커 — 는 **`$SCRIPTS/deploy-wait-issue.sh` 한
  호출**이다(#446). 여기서 `gh issue create` 를 손으로 조립하지 마라:

  ```
  $SCRIPTS/deploy-wait-issue.sh <repo> <pr> --sha <머지 SHA> \
    --title "<요약 한 줄>" --summary-file <변경요약 파일> --items-file <항목 파일|없음> \
    [--verify-url <production 베이스 URL>] [--deploy-cmd <배포 엔트리포인트>] \
    [--parent-issue <부모 이슈#>] [--hardware]
  ```

  **제목 정규식(`배포 대기: PR #<M>`) · 절 이름(`## 검증 URL`·`## 라이브/하드웨어 검증 항목`) · `없음` ·
  `(승격만)` 은 deploy-cycle·deploy-bodat 이 읽는 파싱 계약**이고, 그 SSOT 는 그 스크립트의 머리 주석이다
  (여기 산문이 아니다 — 리터럴을 바꾸려면 그 소비자부터 고쳐라). 하는 일: 항목 형태를 강제하고(`없음` 한
  줄이거나 **모든 줄이** `- [ ] ` 체크박스여야 한다 — 한 줄이라도 산문이면 **발행 전** exit 65) → 체크박스
  0이면 제목에 ` (승격만)` 을 붙이고 → `--label deploy-wait` (+ `--parent-issue` 로 상속한 P, `--hardware`
  이고 **레포에 정의가 있을 때만** `needs:hardware`)로 발행하고 → 라벨 부재면 `setup-labels.sh` 1회 +
  재시도 1회 → 그래도 안 되면 **`--label` 을 하나도 주지 않고 발행**해 티켓 유실을 막고 → 라벨을
  readback 해 보강하고 → PR 에 `배포 대기: #<번호>` 마커를 남긴다. stdout 은 이슈 번호 한 줄이다.
  `<VERIFY_URL>` 을 모르면 `--verify-url` 을 생략한다(5단계가 URL 도달불가로 폴백).
  - **exit 0** → 마커까지 남았으므로 **approval-required 로 종료**한다.
  - **exit 65 (발행 전 형태 위반 — 이슈는 아직 없다)** — `<LIVE_CHECKS>` 가 산문이라는 뜻이다. 배경·근거는
    `## 변경 요약` 으로 옮기고 항목 자리엔 `없음` 이나 `- [ ]` 만 남겨 **다시 부른다**. **exit 65 로
    4단계를 끝내지 마라** — 한 번 더 불렀는데도 65면 산문을 `## 변경 요약` 으로 옮기고
    `--items-file 없음` 으로 **발행한다**(`(승격만)` 티켓). 그 경우 ④ Report 에
    `BLOCKED: 배포 대기 항목 형태 위반 — PR #<pr>` 로 함께 올린다.
  - **exit 1 (이슈 미생성)** — ④ Report 에 `BLOCKED: 배포 대기 이슈 발행 실패 — PR #<pr>` 로 올린다.
  - **exit 2 (이슈는 생성됨 — 번호는 stdout)** — 라벨·마커가 어긋났다. ④ Report 에
    `BLOCKED: 배포 대기 이슈 deploy-wait 라벨 부착 실패 — #<번호>` 로 올리고, 사람에게
    **`references/loop-conventions.md` §8 의 3단 복구**를 요구한다. 여기서 같은 라벨 편집을 겹쳐 시도하지
    마라(#223). 조용히 넘어가지 마라.

  `deploy-wait` 는 `loop-status.sh` 가 배포대기와 needs-human 을 갈라 세는 버킷 라벨이자 **deploy-cycle
  루프가 이 티켓을 집는 레인 표식**이다 — 이 라벨 하나가 필수다. **closeout 은 `needs-human` 을 붙이지
  않는다 (#243, 플랜 2단계) — 되돌리지 마라.** 그 라벨을 붙이는 주체는 deploy-cycle 이다.

**단, `<LIVE_CHECKS>` 의 형태 규율은 그대로다** — 이슈 발행 여부를 가르지 않을 뿐, 5단계 스모크 여부는
여전히 이 절이 가른다:

- **체크박스가 하나라도 있으면** 그 목록이 이슈가 닫히는 조건이고, 5단계가 그것을 Chrome 스모크로
  대조한다.
- **`없음` 이면** 이슈 제목에 `(승격만)` 을 붙이고 본문 `## 라이브/하드웨어 검증 항목` 에 `없음` 을 그대로
  둔다. **5단계 스모크는 건너뛴다.** 이 이슈는 deploy-cycle 레인이 승격을 마치면 닫는다.

**묶지 않는다.** 여러 배포 대기 이슈를 하나로 합치지 마라(사용자 결정, 2026-08-13). 개수가 늘어도
**한 PR = 한 티켓 = 닫히는 시점이 명확한 그릇** 을 유지한다.

**5단계 — 배포 후 처리 (Chrome 스모크).** **배포 완료가 보고된** 배포 이슈에 대해(누가 보고했는지는 묻지
않는다 — 배포 보고는 deploy-cycle 레인이 남긴다) 새 감지 기구 없이(폴링/타이밍 미도입) 능동적으로
Chrome 스모크를 돌려 판정한다. 배포 이슈 본문에서 `## 검증 URL`(`<VERIFY_URL>`)과
`## 라이브/하드웨어 검증 항목`(`<LIVE_CHECKS>`)을 파싱해 `references/smoke-prompt.md` 의 placeholder 에
채우고 (**그 절을 손대지 말고 그대로 치환한다 — 표식 줄을 미리 걸러 내지 마라.** 프롬프트가 `[칸 ③]`
표식 줄을 밟지 않고 `보류` 로 적어 내고, **세는 일은 `$SCRIPTS/smoke-tally.sh` 하나가 한다**, #448),
chrome-devtools MCP 도구를 ToolSearch 로 로드하고, **진입 정리(멱등 — 크래시 재개 방어): `list_pages` 로
이전 틱이 정리 전에 죽어 남긴 스모크 페이지가 있으면 `close_page` 로 먼저 닫는다.** 이어 `navigate_page`
로 `<VERIFY_URL>` 에 진입한 뒤 각 항목을 `evaluate_script`/`take_snapshot` 으로 대조해 항목별 pass/fail 을
산출한다 (구조/빈 상태 확인과 실 데이터 렌더 확인을 결과에 구분 표기).
- **집계는 `$SCRIPTS/smoke-tally.sh` 한 자리다 (#448).** 표식 판별·분모 제외·보류 합산의 산술은 그
  스크립트의 머리 주석이 SSOT 다. 여기서 손으로 세지 마라.
  - **스모크 전 — 밟을 게 있는가.** 배포 이슈의 `## 라이브/하드웨어 검증 항목` 절을 파일로 써서
    `$SCRIPTS/smoke-tally.sh --checks <절 파일>` 를 부른다(체크 모드 JSON: `open` · `steppable` ·
    `held_marked` · `skipped`). `steppable` 이 0이면 **Chrome 을 띄우지 마라.** 다만 **끝내는 방식은
    둘로 갈린다**:
    - **`open` 이 0 (`없음` 절)** → 코멘트 `스모크 생략: 밟을 항목 0` 을 남기고 **완료**로 넘긴다.
    - **`steppable` 은 0인데 `held_marked` 가 0이 아니다 (표식 줄만 남았다)** → Chrome 은 띄우지 않되
      **완료가 아니다.** `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다`
      (`<n>`=`held_marked`) + `보류 내역: 표식 <a>건 · 표식 없는 미밟음 0건`(`<a>`=`held_marked`) 코멘트를
      남기고 **이슈를 닫지 않는다** — 칸 ③ 은 배포 뒤 `e2e-test`(deploy-cycle ⑦)의 몫이다.
  - **스모크 후 — 무엇을 봤는가.** 프롬프트가 낸 **판정 줄만**(`<판정> <원본 항목 줄>` — 어휘는
    `pass`·`fail`·`보류` 셋뿐, 문법은 스크립트 머리 주석) 파일로 모아
    `$SCRIPTS/smoke-tally.sh --checks <절 파일> <결과 파일>` 를 부르고(원본 체크리스트가 **분모의
    진실**이다, #467) 아래 갈래를 그 JSON 으로 가른다: `verdict`(`green`|`fail`|`held`|`skip`) · 분모
    `denominator` · 보류 `held`(내역 `held_marked`·`held_unstepped`). **`verdict` 만 보지 마라** — fail 과
    보류는 동시에 참일 수 있어 fail 갈래에서도 `held` 가 남으면 이슈를 닫지 않는다. `unparsed`·`duplicate`
    가 0이 아니면 그 항목이 보류로 세어져 그 틱은 green 이 될 수 없다 — ④ Report 에 한 줄로 올린다.
    **스모크가 아예 못 돈 저하(degrade) 틱에서는 이 호출을 하지 마라** — 저하는 아래 degrade 절이
    소유한다.
- **실장비 항목이 남아 있으면 green 이어도 닫지 않는다 (칸 ③ 은 크롬이 못 밟는다).** 판별은 접두 표식
  `[칸 ③]` **하나로만** 한다 — 판별 술어를 여기서 새로 만들지 마라. `held` 가 0이 아니면 나머지가 전부
  통과해도 배포 이슈를 닫지 말고 `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다`
  (`<n>`=`held`) 코멘트로 끝낸다 — 칸 ③ 은 배포 뒤 `e2e-test` 의 몫이라
  (`references/loop-conventions.md` §9 주체별 상한 표), 여기서 닫으면 실장비 항목이 든 티켓이 TEST 워커를
  한 번도 안 거치고 종결된다.
  - **표식 없는 줄의 보류는 관측이지 해석이 아니다.** 표식 없는 줄은 프롬프트가 **일단 밟아 본다** —
    밟았는데 기대와 다른 값이 나왔으면 `fail`(→ 아래 fail 갈래), 밟을 수단이 브라우저 밖(워커 박스·`ssh`·
    AdsPower 클라이언트 조작 · 서버 셸 `bin/rails runner` · `log/*.out` grep)이라 **시도조차 못 했으면**
    `보류`(=`held_unstepped`). 줄의 뜻을 읽어 실장비로 승격하지 마라. **그 보류에 후속 이슈를 발행하지
    마라**(#309) — 결함이 아니라 밟는 레인이 다를 뿐이다.
  - **표식을 대신 붙이지 마라.** 마커 문구는 하나로 두되, 내역은 스크립트가 낸 수로 한 줄 남긴다:
    `보류 내역: 표식 <a>건 · 표식 없는 미밟음 <b>건 — 재고 · 4단계 표식 누락 · 또는 4단계가 수단을 적어 보낸 비-칸③ 줄`
    (`<a>`=`held_marked` · `<b>`=`held_unstepped`).
- **이미 닫힌 배포 이슈 — 스모크 생략.** 배포 이슈가 이미 CLOSED 이고 검증/배포 완료 코멘트가 있으면
  5단계 완료로 간주한다 — 재스모크하지 않고 다음 단계로 진행한다(남은 검증 항목은 그때 `테스트` 이슈로
  옮겨져 있다).
- **저하(degrade) — 조용한 skip 금지.** chrome-devtools MCP 가 세션에 없거나 `<VERIFY_URL>` 이 비었거나
  도달 불가면, 스모크를 건너뛰고 배포 레인(deploy-cycle)의 사람 보고 경로로 폴백하되 배포 이슈에
  `스모크 skip: <사유>` 코멘트를 남긴다(누락 은폐 금지). 단 **"도달 불가" 는 마지막에만 쓴다** (#153):
  `<VERIFY_URL>` 이 안 열리면 skip 을 적기 전에 smoke-prompt 의 재시도 사다리를 먼저 밟는다 — ① 그 레포의
  원격 접근용 주소 ② SSH 터널. **둘 다 실패했을 때만** 도달 불가다. **브라우저를 아예 기동하지 않았으므로
  정리 대상도 없다 — 아래 브라우저 정리는 no-op(누수 아님).**
- **green (`verdict=green` — 전부 통과 + 보류 0)** → 배포 이슈 + 원본 PR 에
  `✅ 스모크: <n>/<n> 통과`(`<n>/<n>` = `pass`/`denominator`) 코멘트(이 코멘트가 5단계 완료 마커 — 재개
  틱이 재스모크하지 않는다). 이어 배포 이슈에서 `needs-human` 라벨을 제거하고 배포 이슈를 close 한다.
  **`held` 가 0이 아니면 애초에 이 갈래가 아니다** — 그때는 `verdict` 가 `held` 로 나오고, 위 실장비 절이
  소유한다: 라벨 정리까지만 하고 이슈는 열어 둔 채 `종결 보류: …` 코멘트로 끝낸다.
- **fail (`verdict=fail` — `fail` 이 한 건이라도)** — **크롬이 밟은 줄만 여기 온다.** 위 fail-closed 로
  보류한 미밟음 줄은 fail 이 아니므로 아래 발행 대상에서 뺀다(#309). → 직접 고치지 않고 기존 발행 경로:
  자동수정 가능하면 `references/spinoff-issue.md` 로 agent-ready 이슈(**6단계와 같은 한 호출**
  `$SCRIPTS/spinoff-issue.sh <repo> <부모 이슈#> <부모 PR#> --title "<제목>" --body-file <본문파일>` —
  상속·라벨·readback·마커가 그 안에 있다. 여기도 산문으로 대신하지 마라), 라이브 검증이 필요하면
  `--label needs-human` 이슈. 같은 실패가 `REPAIR_RECUR_LIMIT` 회 반복되면 `needs-human` 으로 승격한다
  (**exhausted 종료**). 배포 이슈는 닫지 않는다. 라벨명은 `needs-human`(하이픈)이다 — `needs:human` 은
  존재하지 않는 라벨이라 `gh issue create` 가 통째로 실패한다(콜론형은 `needs:hardware` 뿐).
  - **코드무관 스모크 실패 기록 (lessons).** 그 스모크 실패가 코드 무관(인프라 장애·플레이크·검증 URL
    일시 오류 등)으로 판명되면, 위 발행 경로와 별개로 `$SCRIPTS/repo-dir.sh <repo>` 해석 경로 밑
    **`.loop/lessons-verifier.md`** 에 `- [YYYY-MM-DD PR#<pr>] <스모크 오판 패턴 → 재발 방지 행동>` 1줄을,
    위 1단계와 같은 호출로 append·정리한다 — `$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"`.
    코드 결함으로 판명된 실패는 여기 기록하지 않는다 — 발행 경로가 담당.
- **브라우저 정리 — 누수 방지 (공통 종료, green·fail·degrade 모두).** 위 스모크 판정 코멘트를 남긴 **뒤**,
  이 틱이 연 chrome-devtools 페이지를 `list_pages`→`close_page` 로 반드시 닫는다 — 세 종료 경로 어느
  쪽으로 빠졌든 예외 없이(정리 전에 return 하지 마라). degrade 로 브라우저를 안 열었으면 정리 대상이 없어
  no-op 이고(단 URL 도달 불가를 판정하느라 `navigate_page` 를 시도해 에러 탭이 열렸으면 그 탭도
  `close_page` 한다), 스모크 대상이 없는 정상 no-op 틱도 브라우저를 열지 않는다.

**6단계 — 파생 이슈.** 입력은 워커 PR 본문의 `follow-up:` 항목 + 1단계 diff 리뷰가 짚은 인접 작업이다.
**입력을 이슈로 옮겨 적지 않는다 — 항목마다 먼저 판정하고, 이슈는 다섯 갈래 중 마지막 ⓔ 뿐이다**
(사용자 결정 2026-09-13, #411). 리뷰어는 입력이지 결정권자가 아니다 — "codex 가 P2 로 냈으니 이슈" 는
판정이 아니다 (근거: closeout-rationale §15).

| 항목의 성격 | 처리 |
|---|---|
| ⓐ 이 PR 파일 안에서 끝나고 동작이 안 바뀐다(주석·용어·앵커·가드 토큰·테스트 이름 — `references/loop-conventions.md` §10 이 받는 것) | **흡수** — 3단계 표면 교정 커밋이 먹었어야 할 부류. 머지 뒤라 커밋 자리가 없으면 이슈가 아니라 아래 판정 코멘트에 `흡수 누락:` 으로 적는다 |
| ⓑ 루프 정상 동작 밖 시나리오(사람의 히스토리 재작성 · 문서 밖 설정값 · 상한 초과 설정) | **기각** — 판정 코멘트에 `기각: <사유>` |
| ⓒ 대상 코드를 형제 PR 이 바꾸는 중이거나, 발행 시점에 `origin/<default>` 에 그 줄이 없다(`git grep` 으로 확인) | 이미 머지돼 사라졌으면 **기각**. 형제가 **아직 본문을 읽기 전**이면 — 연결 이슈가 `agent-ready` 대기(`agent:claimed` 없음)거나 PR 이 `flow:verify`(검증자 pick 전 — 워커는 회차 시작 때, 검증자는 pick 때 본문을 읽는다) — **지적을 형제의 연결 이슈 본문에 붙인다** — `gh issue edit <형제 이슈> --repo <repo> --body-file` 로 본문 끝에 `## 인접 지적 (closeout 6단계, PR #<원본>)` 절 + 무엇을 왜 한 줄(같은 원본 PR 번호의 절이 이미 있으면 건너뛴다 — 멱등). 본문이 유일하게 **읽히는 입력**이다(워커는 이슈 본문을, 검증자는 `<ISSUE_BODY>` 를 받는다). PR 코멘트는 전달 채널이 아니다(#379). 다른 레인의 PR 을 closeout 이 반송하지는 않는다(소유권). 형제가 이미 돌고 있거나(`flow:claimed`·`verifying` — 본문은 이미 읽혔다) ✅ 뒤(`flow:ready`·`harvesting`)거나 연결 이슈가 없으면 읽는 이가 없으니 **ⓔ 로 판정**한다 |
| ⓓ 사람이 정해야 하는 갈림길("둘 중 하나로") | **기계 정지 상태로 올린다, 이슈는 만들지 않는다** — 대상은 **열린 이슈**여야 한다(재개 스윕은 `--state open` 만 훑는다 — 닫힌 이슈의 `hold:policy` 는 영영 안 보인다): 부모 에픽(열림) → 없으면 4단계가 만든 배포 대기 이슈(그 사이 닫혔으면 `gh issue reopen <번호> --repo <repo>` 뒤). 그 이슈에 `$SCRIPTS/transition.sh closeout-blocked <repo> <그 이슈> - --reason policy --note "<사람이 답해야 할 질문 한 줄>"` (PR 자리는 `-` — 원본 PR 은 이미 머지됐다). `hold:policy` 가 붙고 질문이 `사람 확인(policy):` 코멘트로 남아 재개 스윕 ③ 재심 → 사람대기로 이어진다. 코멘트만 남기면 `loop-status.sh` 가 라벨로만 세므로 아무 틱에도 안 보인다. ④ Report 에 `사람 결정 요청 #<번호>` 한 줄 |
| ⓔ ⓐ~ⓓ 어디에도 들지 않고 남는, 고쳐야 하는 **실제 결함** — 이 PR 밖 코드든, 3단계가 "동작이 바뀐다" 며 넘긴 이 PR 안의 것이든. 출처(검증자 P2 · 범위 밖이라 WARN 으로 낮춘 P1 · 워커 `follow-up:` 항목)는 판정 조건이 아니다 — follow-up 항목도 ⓐ~ⓓ 를 먼저 거친다 | **이슈** — 아래 발행 명령으로 `references/spinoff-issue.md` 를 채워 agent-ready 이슈로 발행. 본문 둘째 줄 `Spinoff of PR #<pr> (issue #<부모>)` 출처 줄은 스크립트가 채운다 |

판정 결과는 원본 PR 코멘트 한 줄로 남긴다 — `파생 판정: ⓐ N · ⓑ N · ⓒ N · ⓓ N · ⓔ N — <항목별 갈래·한 줄 사유>`
(마지막에 `<!-- bodat:worker -->`). **이 코멘트가 6단계 완료 마커다**(① Reconcile 마커표) — 갈래 조치(ⓒ 본문 편집·
ⓓ 전이·ⓔ 발행)가 **전부 끝난 뒤 마지막에** 남긴다. 중간에 끊기면 다음 틱이 마커 부재로 6단계를 다시 도는데,
ⓒ 는 같은 원본 PR 절이 있으면 건너뛰고 ⓔ 는 `파생:` 마커로 막히니 중복은 ⓓ 의 전이(멱등)뿐이다.
ⓔ 가 0이면 6단계는 이 코멘트로 끝난다 — 발행 0건이 정상이다.
ⓔ 의 발행 절차 전체 — 상속(#261) · 본문 첫 줄 `Epic #N` · 둘째 줄 `Spinoff of PR #<pr> (issue #<부모>)`
출처 줄(#411) · 라벨 · 라벨 부재 fail-closed · 발행 직후 readback · 부모 PR 마커 — 는
**`$SCRIPTS/spinoff-issue.sh` 한 호출**이다(#447). 여기서 `gh issue create` 를 손으로 조립하지 마라.

- **부모 결정 (상속의 입력 — 이건 스크립트가 아니라 이 단계의 판단이다).** 부모 = 마감 중인 PR 의 **head
  브랜치 `agent/issue-<N>` 의 N** 이 1순위다. `closingIssuesReferences` 는 그 N 이 그 목록에 있는지
  **교차확인**하는 데 쓰거나, head 가 `agent/issue-*` 형태가 아닐 때의 **폴백**으로만 쓴다 — `[0]` 은
  브랜치 이슈라는 보장이 없다. 둘 다 못 구하면 스크립트에 `-` 를 넘기지 말고 **발행하지 않는다** —
  ④ Report 에 `BLOCKED: 파생 부모 미상 — PR #<pr>` 로 올린다(상속 없이 발행하지 않는다).
- **발행 명령 (필수 형태 — 산문으로 대체하지 마라).** 본문은 채운 `spinoff-issue.md` 를 파일로 써서
  `--body-file` 로 넘긴다(템플릿은 **본문 전용**이라 라벨을 거기 적으면 이슈 본문에 렌더된다 — 라벨은
  스크립트가 명령줄에서 준다):

  ```
  $SCRIPTS/spinoff-issue.sh <repo> <부모 이슈#> <부모 PR#> \
    --title "<제목>" --body-file <본문파일> [--label <레포 규약 라벨>...]
  ```

  규칙의 SSOT 는 그 스크립트의 머리 주석이다. 하는 일: `spinoff-inherit.sh` 로 부모를 **한 번** 읽어
  `epic=`·`priority=` 를 받고 → 본문의 `<EPIC_LINE>` 전용 줄을 `Epic #N`(에픽 없으면 빈 줄)로 채워
  **첫 줄**을 보장하고 → `<ORIGIN_LINE>` 전용 줄을 `Spinoff of PR #<pr> (issue #<부모>)` 로 채워 **둘째 줄**을
  보장하고(#411) → `--label agent-ready --label spinoff --label "$priority"` + 넘긴 규약 라벨로
  발행하고 → 라벨 부재면 `references/loop-conventions.md` §8 「이슈 발행」 행 대로 → 라벨·`Epic #N` 첫
  줄을 readback 해 보강하고 → 부모 PR 에 `파생: #<새번호> (Epic #<N|없음> · <P>)` 마커를 남긴다. stdout 은
  새 이슈 번호 한 줄이다.
  - **exit 0** — stderr 의 `marker:` 줄을 ④ Report 의 `파생` 항목에 그대로 옮긴다.
  - **exit 1 (이슈가 안 만들어졌다·무출력)** — 부모 미상·상속 실패·발행 실패. ④ Report 에
    `BLOCKED: 파생 부모 미상 — PR #<pr>` 또는 `BLOCKED: 파생 발행 실패 — PR #<pr>` 로 올린다.
  - **exit 2 (이슈는 만들어졌다 — 번호는 stdout)** — 라벨·본문·마커 중 하나가 어긋났다. ④ Report 에
    `BLOCKED: 파생 이슈 라벨 부착 실패 — #<번호>` 로 올린다(복구는 사람 몫: `setup-labels.sh` 재실행 →
    `gh issue edit --add-label`). 여기서 같은 편집을 겹쳐 시도하지 마라.

  `--label` 로 넘길 것은 **레포 규약 축뿐**이다(BoDAT 의 `difficulty:*`·`frontend`(UI 를 건드릴 때만)·
  `needs:hardware` — 레포 CLAUDE.md 의 라벨 절이 SSOT). `agent-ready`·`spinoff`·P 는 스크립트가 붙이므로
  다시 주지 마라. `priority` 를 손으로 올리지 마라 — 올리려면 사람이 에픽 단위로 올린다(#401).
- **3단계가 이미 흡수한 표면 교정은 여기서 발행하지 않는다.** 한 발견에 표면과 코드가 섞여 있으면 표면은
  3단계가 먹고 **코드 부분만** 이슈로 낸다 — 이슈 본문에 이미 고쳐진 부분을 다시 적지 마라.

## ⑤ Drain — 다음 후보로 즉시 이어가기

③ 파이프라인이 집은 PR 을 종료 상태(success·approval-required·blocked·dup·exhausted)에 닿게 한 **직후**,
그 PR 의 결과를 ④ Report 용으로 누적해 두고 **다음 틱을 기다리지 말고 ①①-b② 로 되돌아간다**:

- ① Reconcile + ①-b 정체 스윕 + ② Pick 을 다시 수행한다. ② Pick 이 **새 후보를 집으면** 그 PR 로
  ③ 파이프라인을 즉시 이어간다.
- ② Pick 후보가 **0이면** 큐가 빈 것이다 — 드레인을 멈추고 ④ Report 로 이 틱에서 처리한 **모든 PR 을 한
  번에 집계**해 보고한 뒤, `/loop` 주기로 다음 틱을 예약한다.

무한루프 방지: 각 반복은 eligible/입양후보를 최소 1개 줄인다. 같은 PR 이 두 번 집히면(마커 누락 등 예상
밖) 그 PR 을 skip 하고 ④ Report 에 `BLOCKED: 재선정 루프 — #<pr>` 로 보고해 드레인을 끊는다. 별도 상한이
필요하면 한 틱 드레인은 최대 eligible 스냅샷 길이만큼만 돈다(스냅샷 이후 새로 열린 PR 은 다음 틱 몫).

## ④ Report

드레인이 끝나면(② Pick 후보 0) 이 틱에서 처리한 **모든 PR 을 합산**해 한 줄 요약(N 은 이 틱 누적치):
`마감 N · 검증보류 N · 중복종료 N · 배포대기 N · 파생 N · 회수 N · 재디스패치 N · stale N`.
①-b 스윕이 입양해 마감·rebase 한 건은 `회수 N`(마감까지 갔으면 `마감` 에도 반영),
`stale_reverify` 재디스패치·`held` needs-human 건은 `재디스패치 N` 으로 집계한다.

그 아래 **항목마다 번호를 적는다**:
`마감: PR #4795(bodat)←#4788 · 파생: #4823(bodat)←PR #4788 (Epic #4968 · P1) · 재디스패치: #4770(bodat, stale_reverify)`.
`파생` 항목은 6단계 PR 코멘트 마커와 **같은 꼴**로 `#<새번호> (Epic #<N|없음> · <P>)` 를 적는다.
레포 짧은 이름은 `references/loop-conventions.md` §6 대로.
① 의 에픽 스윕이 닫은 에픽도 같은 줄에 `에픽 종료: #285(runner, leaf 4)` 로 덧붙인다 — 닫은 게 없으면 이
조각은 **생략한다**(`note` 는 보고하지 않는다).

**`승격 대기 N커밋` 을 매 틱 반드시 함께 보고한다 (누락 금지).** 이 틱에 마감이 0건이어도 빼지 마라 —
사람이 "승격할 게 쌓여 있는지" 를 보는 유일한 숫자다. 승격 포인터 브랜치가 있으면(`release` 등)
`git fetch origin <포인터> <기본브랜치>` 후 `git rev-list --count origin/<포인터>..origin/<기본브랜치>` 로
세고, 포인터 브랜치가 없는 레포면 `승격 대기 —` 로 적어 해당 없음을 명시한다. 0이면 `승격 대기 0커밋`
이라고 그대로 적는다(생략하지 마라 — 생략과 0은 다르다). (아래 `loop-status.sh` 블록도 승격 대기를 찍지만
이 줄은 **그대로 유지한다** — 중복은 누락 사고 이력에 대한 의도된 이중화다.)

**파이프라인 스냅샷 (매 틱 필수).** 위 줄들 뒤에 `$SCRIPTS/loop-status.sh --post closeout --delta "<이 틱 한 줄 요약>"` 를 실행해 출력을 그대로 붙인다 —
붙이는 규율(`cd` 없이 · 조용한 틱에도)과 exit 1·64 처리는 `references/loop-conventions.md` §7 대로.
- `$SCRIPTS/closeout-eligible.sh` 의 stderr `blocked: PR #<pr>(<repo>) — ✅ 이후 미해결 코멘트
  <n>건(마커 없음 = 사람 리뷰 대기)` (② Pick 참조) 는 한 줄 그대로 `막힘` 항목으로 옮겨 적는다
  (warn 아님) — verify-runner 가 재검증해 새 ✅ 를 찍기 전까진 매 틱 반복되는 것이 정상이다
  (사람 답글은 풀지 않는다 — ② Pick 참조).

종료 상태 7종 — 처리한 PR **각각**에 대해 명시한다(드레인으로 여러 개면 PR 별로):
- **success** — 1~6단계를 다 돌아 PR 을 머지하고 후속까지 발행함(입양·rebase 회수분 포함).
- **clean no-op** — ② Pick 후보가 0이라 마감할 PR 이 없음(①-b 재디스패치만 있었어도 no-op 아님 — `재디스패치 N` 보고).
- **blocked** — 1단계 검증이 BLOCKER 이거나 2단계 rebase 통합 실패라 보류(머지 안 함).
- **dup** — 1단계 검증이 "이미 `origin/main` 에 있다·중복" 으로 판정해 `closeout-dup` 으로 PR·이슈를 머지
  없이 닫음(`needs-human` 없음 — 루프가 끝낸 것이다). `중복종료 N` 으로 집계.
- **approval-required** — 4단계에서 배포 이슈를 발행하고 deploy-cycle 레인에 인계.
- **exhausted** — 5단계 같은 실패가 `REPAIR_RECUR_LIMIT` 회 반복돼 needs-human 승격.
- **stagnated** — `QUIET_TICKS` 연속 조용함(①-b 스윕은 stagnated 여도 매 틱 돈다).

`QUIET_TICKS` 연속으로 조용해도 ①②는 다음 틱에도 그대로 수행한다 — stagnated 는 보고에만 반영되고 어떤
단계도 건너뛰지 않는다. (근거: closeout-rationale §16)

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 사고 이력·설계 근거: `references/closeout-rationale.md`(§1~§16, 한글 전용). 각 절 끝의
  `(근거: closeout-rationale §N)` 이 그 절을 가리킨다.
- 역할 분담: issue-runner = 벌리는 공장 (절대 머지하지 않고 불변을 보존), closeout = 마감 도크 (머지를
  독점). 두 루프는 `harvesting` 라벨 점유로 충돌을 막는다.
- 배포 레인(deploy-cycle): production 배포·release 승격은 closeout 이 하지 않는다 — 4단계가 dry-run 배포
  대기 이슈를 발행해 deploy-cycle 루프에 넘기고, 배포·승격·실테스트(칸 ③ TEST 워커)·종료는 그 레인의
  ⑦ 이 소유한다. 나머지 머지·문서반영·후속발행은 closeout 이 무인으로 한다.
- 운용: closeout 은 issue-runner 와 별도의 `/loop` 세션으로 돌린다 (예 `/loop 20m /closeout`) — 서로의
  점유를 라벨로만 조율한다.
- 의존: 결정적 헬퍼(`closeout-reconcile.sh`·`closeout-eligible.sh`·`closeout-ci-pass.sh`·
  `closeout-step1-marker.sh`(① 마커표 1단계 판정)·`transition.sh`(라벨 이동)·`loop-status.sh`(④ Report
  스냅샷))는 `$SCRIPTS`(=`~/.claude/skills/issue-runner/scripts`)에 있고, references 3종
  (`verifier-prompt.md`·`deploy-check-issue.md`·`spinoff-issue.md`)은 `skills/closeout/references/` 에 있다.
- 실측이 필요한 항목의 시도 순서·통로·인용 규칙은
  `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  (칸 ①dev → ②워커 런타임 → ③TEST 워커 → ④사람. 4단계 `<LIVE_CHECKS>` 이관 전 ①② 시도의 근거이자
  `--reason ladder` 의 전제).
