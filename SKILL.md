---
name: issue-runner
description: GitHub 계정 전체에서 agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 디스패처. /loop 와 함께 사용 (예— /loop 15m /issue-runner). 매 틱 Reconcile → Maintain → Dispatch → Report 를 수행한다. 머지는 절대 하지 않는다.
---

# issue-runner — 이슈 디스패처 틱

당신은 무인 디스패처다. 아래 4단계를 **순서대로** 수행하라. 단계 순서를 바꾸지 마라
(정리가 먼저여야 슬롯 계산이 정확하고, 보수가 신규보다 먼저여야 한다).

> **소유권·정지·전이 실패 규칙의 SSOT 는 `references/state-machine.md` 다**(#393). 어느 상태를 어느 루프가 들고
> 있고(소유 라벨 `flow:verify`·`verifying`·`flow:ready`·`harvesting`), 기계 정지(`hold:*`)와 사람 정지(`needs-human`)가
> 어떻게 풀리며, `transition.sh` 가 exit 1·2 로 끝난 반쯤 이동 상태를 누가 회수하는지는 그 표를 본다 — 아래 산문에
> 같은 규칙이 남아 있으면 표가 이긴다(산문 정리는 플랜 3단계).

## 상수

- `MAX_AGENTS = 4` — 동시 in-flight 이슈 상한 (in-flight 정의는 ③-1 —
  사람 리뷰 대기 PR 은 점유하지 않는다). **2026-07 경합 실험으로 5→3 축소**: 워커는
  전부 한 프로세스에서 도는 백그라운드 subagent 라 동시 N 개면 API·CPU 를 나눠 써
  각자 ~1/N 로 throttle 된다(실측: 동시 0 워커 ~10분 vs 동시 1~4 ~30분). 처리량은
  거의 보존되며 박스 부하·고아 위험이 준다. 여전히 느리면 2 로 더 낮춘다.
  **2026-08-14 에 3→4 로 상향** — 대기 이슈 적체 해소 요청. 단, 이 값만 올리면
  `MAX_OPEN_PRS` 에 더 빨리 닿을 뿐이라 그것도 함께 올렸다(둘은 짝이다).
  ⚠️ 상향의 실제 상한은 API 가 아니라 **머신 부하**다: 이 루프의 워커 N 개 +
  verify-runner(헤드리스 크롬 E2E) + closeout(재-CI) 이 같은 10코어를 나눠 쓰고,
  각 `bin/ci` 가 병렬 테스트 프로세스를 또 띄운다. 4 를 넘기면 동시 `bin/ci` 경합
  플레이크(`lessons.md` 의 #2672·#2685·#3077, `poll_health_timeout_test` 부하
  타이밍)가 늘어 워커가 무죄 입증에 시간을 쓰게 된다 — 5 이상은 실측 없이 올리지 마라.
- `MAX_OPEN_PRS = 14` — **레포별** 열린 PR 수 적체 상한. 캡에 닿은 레포의 신규
  디스패치만 멈춘다(보수는 계속, 다른 레포는 정상 디스패치) — 사람 머지가 밀릴 때
  PR 끼리 rebase conflict 가 폭증하는 것을 막는 배압(backpressure).
  **2026-08-14 에 10→14 로 상향** — 사람 대기(needs-human·사람 게이트) PR 이 상시
  2~3건 캡을 영구 점유해 실효 캡이 7 로 떨어져 있었다(2026-08-13 실측: 10칸 중 3칸).
  14 는 그 상시 점유분을 흡수한 값이다. 사람 대기 PR 이 정리되면 다시 낮춰도 된다.
  **2026-09-13 에 스코프 합산→레포별로 변경(#362)** — 2026-09-12 실측: 합산 캡은 runner 10 + bodat 5 = 15
  로 캡을 채워 bodat 대기 15건이 20틱 넘게 한 번도 안 집혔다. conflict 는 **같은 레포의
  PR 사이**에서만 나므로 합산은 근거보다 넓게 막고 한 레포의 적체가 다른 레포를 굶긴다.
- `MAX_REPAIRS_PER_PR = 3` — PR 1개당 보수 디스패치 상한 (② Maintain 서킷 브레이커)
- **스크립트가 읽는 상수 — 값은 `scripts/lib/constants.sh` 한 자리다** (#427). 이 절은 값을
  다시 적지 않는다: 산문과 코드가 값을 두 벌로 들면 갈린다(`ISSUE_TIMEBOX_HOURS` 는 실제로
  4벌이었다). 환경변수로 덮어쓰면 그 값이 이기고, 값의 **근거·이력은 그 파일 주석**에 있다.
  아래는 이름과 뜻만이다 — 값이 궁금하면 `grep '<이름>' $SCRIPTS/lib/constants.sh`.
  - `ISSUE_TIMEBOX_HOURS` — PR 없는 `working` 이슈에서 **진행 증거를 묻기 시작하는** claim
    경과 시간(① Reconcile timebox). 경과 초과 **자체는 중단 사유가 아니다** — 넘긴 뒤에도
    진행 증거가 있으면 유예한다(#200).
  - `STALL_MIN` — "무진전" 의 기준(분). 원격 브랜치 `agent/issue-<num>` 의 최신 커밋이
    이보다 오래됐을 때만 커밋 쪽 진행 증거가 죽는다(판정은 `timebox-check.sh`).
  - `MAX_TIMEBOX_GRACE` — 같은 claim 에서 허용하는 **누적 유예 횟수**. 횟수는 상태 파일이
    아니라 이슈 코멘트 마커(`<!-- timebox-grace: N -->`)를 **현재 claim 시각 이후 것만**
    세어 재파생한다.
  - `RESUME_AFTER_MIN` — 재개 스윕이 멈춘 이슈를 다시 흘려보내기까지 기다리는 창(분).
    `hold:ladder` 이슈의 마지막 갱신이 이만큼 지나면 ① 의 재개 스윕이 집는다.
  - `LADDER_RESUME_LIMIT` — 이슈 1건당 자동 재개 상한. 초과하면 재개 대신 `hold:policy`
    승격 — 그때만 사람이다(무한 재시도 금지).
  - `CONFLICT_RESUME_LIMIT` — `hold:conflict` 의 자동 재개 상한(#345). 실측(BoDAT #5103 ·
    #185)에서 첫 충돌의 사람 답은 매번 ⓐ(워커 한 회차 더)였고 두 번째는 ⓑ(사람 인수)였다.
    창은 `RESUME_AFTER_MIN` 공용(그 창이 곧 사람이 `full-cycle` 로 인수할 시간이다).
    초과하면 `hold:policy` 승격 → 재심(③)의 질문은 "ⓑ 인수인가, 재발행인가".
  - `MIRROR_RETRY_LIMIT` — ① 재개 스윕의 **정지 미러 정리**가 양성 증거를 못 얻었을 때
    같은 건을 다시 시도하는 상한(#397). 회차는 짝 이슈 코멘트의
    `<!-- mirror-retry: <사유> pr=<n> -->` 마커 개수이고 — **그 PR 의 것만**, **사람이 개입한
    경계**(마지막 `policy-review`·`hold-note` 코멘트) **이후**의 것만 센다(옛 에피소드를
    물려받지 않는다) — 상한에 닿으면 스크립트가 `mirror_retry_exhausted` 를 낸다(전이는
    아래 이벤트 처리 참조).
  - `STALE_FINISH_MIN` — 완결 유실 판별 시간버퍼(분). `finish-classify.sh` 의 버퍼이며,
    이제 이 헬퍼는 **closeout ①-b 정체 스윕**이 소비한다(issue-runner 는 규칙4 원복 후
    직접 쓰지 않음). 살아있는 워커는 `검증자 리뷰:` 직후 수초 내 최종 판정을 찍으므로,
    최신 검증자가 CLEAN 인데 이 버퍼를 넘도록 최종 판정이 없으면 워커 사망으로 간주.
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
- 절대 금지: PR 머지, main 직접 push, 사람이 만든 브랜치 조작, agent-ready 라벨 임의 부착,
  완결 유실 PR 에 최종 `머지 판정: ✅` 대리 append(그 회수는 closeout ①-b 스윕 소유).
  **허용**: ② Maintain 규칙0 의 단계 라벨 `flow:*` 보정(워커가 각 단계에서 직접 다는
  자가설명 라벨이라 스캔 안전망으로 실제 상태에 맞추는 것은 조작이 아니다).

## ① Reconcile

`$SCRIPTS/reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged` — PR 머지. ★**이슈가 닫혔다는 뜻은 아니다**★ — 일부만 착지시킨 PR 은 `Closes`
  대신 `Refs` 를 쓰므로 이슈가 OPEN 으로 남고, `release-labels.sh` 가 그 경우 `agent-ready`
  를 유지해 다음 틱이 남은 절반을 다시 집는다(#117 — 종전엔 무조건 떼어 조용히 좌초했다).
  **고아 워커 정리(선행)**: 이 이슈의 워커가 아직 살아있으면
  (TaskList 로 `<repo>#<num> 구현` 백그라운드 에이전트 확인) `TaskStop` 으로 중단하라 —
  PR 이 머지됐으니 워커 작업은 무의미하고, 방치하면 이미 종료된 PR 을 붙들고 무한
  스핀한다(관측된 고아 유령의 회수 경로). 그다음 **lessons 단계**: 아래 실패 신호가 하나라도 잡히면 (전부
  `gh pr view <pr> --repo <repo>` 로 확인) `VERIFIER` 서브에이전트(## 상수의 VERIFIER
  계약·폴백을 따른다)를 동기 호출하라. 신호가 하나도 안 잡히면 호출하지 말고 NONE 으로
  둔다(lessons 미기록): (1) CHANGES_REQUESTED 리뷰(`--json reviews`) · (2) `gh run list`
  CI 실패(GitHub Actions 레포) · (3) **local-ci commit status 실패 이력** — PR 의 커밋
  중 하나라도 local-ci 컨텍스트가 FAILURE 였으면(`--json commits` 로 커밋 SHA 를 열거하고
  각 SHA 를 `gh api repos/<repo>/commits/<sha>/statuses` 로 조회한다 — HEAD 의 `--json
  statusCheckRollup` 은 컨텍스트당 최신 1개만 남아 실패 이력을 못 본다. 도중 실패 후 새
  SHA 로 고쳐 최종 SUCCESS 라도 실패 이력이면 교훈 후보. local-ci 체제 레포는 gh run
  list 가 항상 빈값이라 이 신호가 실질 트리거다) · (4) **검증자 리뷰 코멘트의 BLOCKER**
  — PR 의 `마감 검증:`·`검증자 리뷰:` 코멘트에 BLOCKER 가 있었던 경우(`--json comments`).

  ⚠️ **리베이스는 (3) 을 무력화한다 — "실패 이력 없음"을 판정으로 믿지 마라.**
  closeout 이 conflict 를 rebase 하면 커밋 SHA 가 바뀌고 **리베이스 이전 SHA 는 PR 에서
  사라진다**. 커밋 열거로도 타임라인으로도 못 찾는다 — `head_ref_force_pushed` 이벤트의
  `commit_id` 는 push **이후** SHA 만 담고, 이전 `committed` 이벤트는 남지 않는다
  (2026-08-11 PR#2290·#2276 실측). 커밋 상태는 SHA 에 붙으므로 SHA 를 모르면 조회 자체가
  불가능하고, `run-local-ci.sh` 는 코멘트를 남기지 않아 GitHub 어디에도 흔적이 없다.
  그래서 **리베이스된 PR 에서 (3) 이 비면 그건 "없음"이 아니라 "미상"이다.**
  판별: `gh api repos/<repo>/issues/<pr>/timeline --jq '[.[]|select(.event=="head_ref_force_pushed")]|length'`
  가 0 보다 크면 커밋 열거가 불완전하다. 그때는 —
  ⓐ 컨텍스트(워커 완료 보고·이전 틱 Report 의 `run-local-ci` 결과)에 리베이스 **이전 SHA**
  가 있으면 그 SHA 로 `gh api repos/<repo>/commits/<sha>/statuses` 를 직접 조회해 판정하라.
  ⓑ 이전 SHA 를 모르면 (3) 을 미상으로 두고 나머지 신호(1·2·4)로만 판단한 뒤,
  ④ Report 에 **"리베이스로 실패 이력 판별 불가"** 한 줄을 남겨라. 조용히 '없음'으로
  넘기지 마라 — 유실이 안 보이는 것이 이 사각지대의 성질이고, 그러면 리베이스를 거친
  PR 의 교훈은 영구히 학습 경로에서 빠진다.
  (교훈이 이미 `lessons.md` 에 같은 내용으로 있으면 중복 append 하지 마라 — 20줄 캡이
  막으려는 희석이 그것이다. 그 경우 Report 에 "기존 교훈과 동일 — 미기록"으로 적는다.)

  > "PR #<pr> (<repo>)의 리뷰 코멘트와 CI 실패 로그를 읽고, 객관적 실패 사실에서
  > 재발 방지 교훈을 딱 1줄로: '<상황>일 때 <구체 행동>하라' 형식. 추측·일반론 금지.
  > 실패 사실이 없으면 'NONE' 출력."

  결과가 NONE이 아니면 `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`
  (= `<repo-dir>/.loop/lessons.md` — repos.conf 매핑 머신에서도 기록·읽기가 같은 파일을
  가리키게 하는 유일한 해석)에 `- [YYYY-MM-DD PR#<pr>] <교훈>` 형식으로 append 하고 캡까지
  정리한다 — **`$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"` 한 자리로 부른다**
  (파일이 없으면 새로 만든다). **append 를 이 호출 밖에서 손으로 하지 마라** — 다른 틱이
  같은 파일을 동시에 정리 중일 수 있고, 잠금 밖에서 한 append 는 그 정리의 read→write 창에
  겹치면 유실된다(#208 재검증 BLOCKER② — closeout 1·6단계가 같은 호출을 쓰는 이유다).
  **캡: 항목 20개** — 초과 시 **항목 수가 캡 이하가 될 때까지** 가장 오래된 항목부터 지운다
  (context rot 방어. 옛 산문의 "가장 오래된 줄 하나 삭제" 는 append(+1)·삭제(-1) 순증이 0
  이라 한 번 캡을 넘으면 안 줄었다 — 그 결함을 스크립트가 수렴 규칙으로 고친다).
  lessons를 CLAUDE.md로 옮기는 것은 사람만 한다.
  **라우팅 — `lessons.md` 는 구현 교훈 전용이다.** 이 파일은 ③-4d 에서 **워커 프롬프트에
  그대로 실린다. 그래서 담기는 것은 "다음 구현자가 같은 코드를 다시 짤 때 쓸 지식"뿐이다.
  교훈이 **검증 판정 계열**(검증자가 무엇을 오판했나 · false BLOCKER 를 어떻게 뒤집었나 ·
  BLOCKER vs WARN 경계)이면 여기 쓰지 말고 같은 디렉토리의 **`.loop/lessons-verifier.md`**
  에 append 하라 — 그 파일은 verify-runner ③-3 과 closeout 1단계가 검증자 프롬프트에
  주입한다. **이 파일도 같은 호출로 쓴다** — `$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"`
  (closeout 1·6단계와 같은 자리·같은 캡. 손 append 는 #208 의 유실 창에 걸린다).
  두 파일을 섞으면 양쪽 프롬프트가 서로 무관한 지식으로 희석된다.
- `rejected` — 사람이 PR을 거부함. **살아있는 워커가 있으면 `merged` 와 동일하게
  `TaskStop` 으로 먼저 중단**(고아 방지). lessons 단계 동일하게 수행. 이슈는 재디스패치하지
  않는다 (agent-ready가 이미 제거됨).
- `stale` — 죽은 claim 해제됨. 보고만.
- `warn` — dirty/unpushed worktree. **건드리지 말고** Report에 그대로 올려 사람이 보게 하라.
- `half_moved_redispatch` — `verify-redispatch` 가 **반쯤 실패한** PR 이다(#394): PR 은 단계
  라벨(`flow:*`·`verifying`)을 잃었는데 이슈는 `agent:claimed` 를 유지해 세 게이트
  (`verify-eligible`·`closeout-eligible`·`eligible-issues`) **전부에서 빠진다** — verify-runner 가
  "다음 틱이 잡게" 라고 넘긴 그 상태의 주체가 여기다(`references/state-machine.md` 회수 열).
  **같은 전이를 멱등 재실행하라**: `$SCRIPTS/transition.sh verify-redispatch <repo> <이슈> <pr>`
  (PR 쪽은 이미 이동해 있어 no-op 이고 이슈만 `agent-ready` 로 돌아온다 → 이번 틱 ③ 후보).
  성사되면 ④ Report 의 `보수` 에 `#<num>(반쯤 이동 회수)` 한 줄. 전이가 exit 1·2 면 ④ Report 에
  `BLOCKED: 전이 실패 verify-redispatch PR #<pr>(<repo_short>) — <stderr 한 줄>` 만 남기고 다음
  이벤트로 간다(공통 규칙 — 조용히 넘어가지 않는다. 다음 틱이 같은 이벤트를 다시 낸다).
  이 이벤트가 난 PR 은 **② Maintain 입력이 아니다**(`pr_open` 이 안 나온다 — `harvesting` 과
  같은 모양). 살아 있는 워커(`progress-evidence.sh` 진행 증거 있음)와 증명 실패는 스크립트가
  이미 걸러 이 이벤트를 내지 않으니, 여기서 신선도를 다시 재지 마라.
- `pr_open` — ② Maintain 의 입력.
- `working` — 워커 진행 중. TaskList 로 해당 백그라운드 에이전트가 실제 살아있는지
  확인. **"죽어 보임"(TaskList 상 종료)을 바로 사망으로 단정하지 마라** — 그 태스크의
  `TaskOutput(task_id)` 로 마지막 메시지를 먼저 읽어라. 마지막 줄이
  `CI 대기 중 — <SHA 40자> <queued N|running|none>, 다음 할 일: <한 줄>`
  형식이면 `run-local-ci.sh` 큐 대기 중 턴만 끝낸 것이지
  사망이 아니다(#185) — **worktree 제거·claim 해제를 하지 말고** `SendMessage` 로
  그 태스크에 재개 메시지를 보내 워커를 깨워라(보고에 적힌 "다음 할 일"을 이어가게
  하라는 한 줄이면 된다). 재개했으면 ④ Report 의 `보수` 에 `#<num>(CI 대기 재개)`
  로 적어라 — 그리고 **재개에 성공했으면 이 이슈는 이번 틱에서 여기까지다. 아래 진짜
  사망 경로도, 그 끝의 timebox 청소도 실행하지 말고 다음 이벤트로 넘어가라**(코드로
  치면 여기서 `continue`). 방금 깨운 워커는 정의상 **살아있으므로** 그냥 아래로 읽어
  내려가면 timebox 문단에 그대로 걸린다. 이 박스 CI 큐는 인큐→완료가 550~750초라
  반송 회차가 겹치면 claim 경과가 쉽게 `ISSUE_TIMEBOX_HOURS` 를 넘고, 그러면
  ⓐ `TaskStop` ⓑ worktree 제거 ⓒ claim 해제가 **막 재개한 워커를 즉시 죽인다.**
  **상태 토큰은 `queued N`·`running`·`none` 셋이고 — 세 상태 다 재개 신호다.** 어느
  값이 왔든 위와 똑같이 재개하라(worktree 제거·claim 해제는 **세 경우 모두** 하지
  않는다). `queued N` 은 그 워커의 SHA 가 큐에서 N번째로 줄 서 있는 것, `running` 은
  이미 그 잡이 돌고 있는 것(이 상태엔 대기열 번호가 아예 없다 — 옛 고정 문형
  `대기열 N번째` 로는 쓸 말이 없어 워커가 조용히 끝냈고, 그게 이 갈래가 막으려던 바로
  그 사망 오독이었다), `none` 은 티켓이 회수돼 큐에도 결과도 없는 것이다.
  **`none` 이어도 워커는 살아 있다** — 회수된 것은 티켓이지 워커가 아니고, 깨우면 같은 SHA 로
  1회 재큐해 이어간다. 세 값은 워커가 지어낸 말이 아니라 `ci-queue.sh status <SHA>` 의
  출력 그대로다(`running` / `queued <n>` / `none`).
  이 형식이 아니면(진짜 사망) 아래로 이어간다.
  **근거 — 턴이 끝난 백그라운드 서브에이전트도 `SendMessage` 로 깨어난다.** ⑴ Agent 툴
  계약문이 `SendMessage` 를
  "continue a previously spawned agent with its context intact"
  로 규정한다(스폰이 끝난 뒤를 전제한 문장이다). ⑵ 백그라운드 태스크의 완료
  알림(task-notification) note 도 "The user can send it another message and resume it,
  so the same task-id may notify more than once" 라고 못박는다 — **완료 알림은 "턴이
  끝났다"이지 "태스크가 소멸했다"가 아니다.** ⑶ 운영 실측: 2026-09-10~11 하루에 5건
  (bodat #4959·#4927·#4957·#4971 · runner #188)을 이 경로로 깨워 **전부 재개돼 작업을
  마쳤다**(같은 task-id 로 완료 알림이 두 번 왔다).
  **폴백 — 재개 메시지에도 응답이 없으면**(태스크가 정말 회수된 드문 경우) claim 을 풀지
  말고 **기존 worktree·브랜치를 그대로 재사용해 대체 워커를 디스패치**하라 —
  `make-worktree.sh` 가 기존 트리를 `exists:` 로 재사용하고, push 된 커밋이 자산이다.
  **새 claim 도, 새 PR 도 만들지 않는다**(열린 PR 이 있으면 그걸 이어 쓰게 하라). 이
  폴백까지 실패하면 그때 아래 진짜 사망 경로로 내려간다.
  죽었고 push 된 커밋이 있으면 ② 의 보수 대상으로. 커밋이 전혀 없으면
  claim 해제 **전에** 이슈 최신 코멘트를 확인하라 —
  `gh issue view <num> --repo <repo> --json comments --jq '[.comments[] | select((.body | test("<!--\\s*timebox-grace:")) | not)] | last.body'`
  (timebox 유예 마커 코멘트는 건너뛴다 — 마커가 최신 코멘트 자리를 차지하면 워커가 남긴
  `BLOCKED:` 가 가려져 needs-human 승격 대신 조용한 claim 해제로 샌다, #200)
  가 `BLOCKED:` 로 시작하면 워커가 사람 개입이 필요해서 멈춘 것이다 (모호 스펙 /
  계획-현실 불일치 / 동일 실패 반복): 재디스패치 복귀 대신
  `$SCRIPTS/transition.sh runner-held <repo> <num> <pr|-> --reason policy --note "<사람이 답해야 할 질문 한 줄>"` 로
  `hold:policy` 를 부착하고(claim 해제 포함 — 기계 정지는 사유 라벨 하나만 붙인다, #244),
  worktree 제거 후 warn 으로 ④ Report 에 BLOCKED 사유를
  올려라 (사람이 원인을 해소하고 `hold:*` 를 떼면 다시 흐른다 — 게이트가 `hold:` 접두를
  보므로 사유 라벨이 남아 있으면 후보로 안 돌아온다, #242. 재심이 "사람 몫 유지" 로
  끝나 `needs-human` 까지 붙은 건은 그것도 함께 떼야 한다. README
  '가드레일' 규약). BLOCKED 코멘트가 아니면 worktree 제거 후 claim 해제
  (재디스패치 가능 상태로 복귀).
  **timebox (무진전 감지)** — **이번 틱에 `SendMessage` 로 재개한 이슈는 면제다**
  (위 재개 갈래에서 이 이슈 처리는 이미 끝났다: 그 워커는 무진전이 아니라 CI 큐를
  기다린 것이라, 여기서 청소하면 방금 깨운 워커를 죽인다). 재개하지 않은 건이면
  살아있어도 **진행이 있는지** 확인하라 — 판정 입력은 경과 시간이 아니라 진행
  증거다(#200: 경과에는 워커가 통제할 수 없는 박스 전역 직렬 CI 큐 대기가 통째로
  들어가, 실측 2건에서 진행 중인 워커를 죽일 뻔했다).
  `gh api repos/<repo>/issues/<num>/timeline --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed")] | last.created_at'`
  로 claim 시각을 구하고 (빈 응답이면 worktree 디렉토리 생성 시각으로 대체),
  `$SCRIPTS/timebox-check.sh <repo> <num> --claim-at <ISO8601>` 에 넘겨라 (`working` 은
  정의상 PR 없음). 판정은 한 줄로 나온다 —
  `<verdict> <reason> elapsed=..m commit=..m queue=.. grace=n/max`:
  - `ok` (exit 0) — 경과가 아직 `ISSUE_TIMEBOX_HOURS` 이내. 손대지 마라.
  - `grace` (exit 0) — 경과는 넘었지만 진행 증거가 있다: 최신 커밋이 `STALL_MIN` 이내
    이거나(`recent_commit`), 그 head SHA 의 CI 티켓이 박스 전역 큐에 살아 있다
    (`ci_queued`). 이번 틱은 **중단하지 마라**. 헬퍼가 유예 마커를 이슈에 append 하므로
    다음 틱이 그 개수를 세어 `MAX_TIMEBOX_GRACE` 를 건다. ④ Report 에는 **warn 이 아니라
    정보 줄**로 판정 줄을 그대로(경과·마지막 커밋·큐 상태·유예 n/max) 옮겨 무한 유예가
    눈에 보이게 하라.
  - `stop` (exit 1) — 무진전(`no_progress`)이거나 유예 상한 소진(`grace_exhausted`).
    아래 ⓐ~ⓓ 를 그대로 하라.
  - `unknown` (exit 2) — 판정 입력을 못 얻었다(claim 시각·브랜치 조회·코멘트 조회·유예
    마커 append 실패). **중단하지 말고** ④ Report 에 warn 으로 올려라 — 조회 실패로
    살아있는 워커를 죽이면 미push 잔여물이 되돌릴 수 없이 폐기되지만, 유예는 다음 틱이
    되돌릴 수 있다.
  `stop` 일 때만:
  ⓐ TaskStop 으로 워커를 중단하고 (push 된 커밋은 원격 브랜치에 보존된다),
  ⓑ worktree 를 제거하라 — `git -C <repo-dir> worktree remove --force <wt>` 후
  `git -C <repo-dir> branch -D agent/issue-<num>`. 미push 잔여물은 `stop` 판정의
  대가로 **의도적으로 폐기**한다 — 남겨두면 다음 디스패치의 make-worktree 가 중단된
  워커의 중간 상태를 그대로 물려줘 worktree 격리가 깨진다 (dirty-warn 보류 규율은
  원인 불명의 잔여물용이므로 이 의도적 중단에는 적용하지 않는다).
  ⓒ `gh issue edit <num> --repo <repo> --remove-label "agent:claimed"` 로 claim 을
  해제한 뒤, ⓓ warn 으로 ④ Report 에 올려라 (agent-ready 가 남아 있으므로 다음 틱이
  원격 브랜치 위 새 worktree 에서 재디스패치한다).

**재개 스윕 — 멈춘 건은 틱이 다시 시도한다.** 위 이벤트를 전부 처리한 뒤
`$SCRIPTS/resume-sweep.sh` 를 인자 없이 실행하라(스코프는 세션 cwd 의 `.loop/repos` 를
스크립트가 알아서 적용한다). 기계 정지(`hold:*`) 중 **`hold:ladder`**
(실측 사다리 ①~③ 칸이 전부 실패해 멈춘 건)와 **`hold:conflict`**(closeout ③ 이 머지 충돌로
멈춘 건 — #344 가 보안 경계·대범위 충돌은 `policy` 로 보내므로 이 라벨은 "루프가 1회 재개해도
되는 건" 이다, #345)를 창(`RESUME_AFTER_MIN`)이 지나면 자동으로 되돌린다 — `hold:policy` 만
사람 결정으로 남고 재심(③) 1회를 거친다. 사람이 직접 세운 정지(`needs-human`)가 함께 붙어
있으면 자동 재개 대상이 아니다(#244). **`full-cycle` 이 붙은 `hold:conflict` 는 사람이
인수(ⓑ)한 것이라 절대 재개하지 않는다**(BoDAT #5103 2차 형상 — `note` 로만 남는다). ③ Dispatch
**앞**에서 돌려야 이번 틱이 그 이슈를 바로 집는다.
재개 횟수는 이슈 **코멘트**에 붙은 마커(`<!-- ladder-resume: N -->` · `<!-- conflict-resume: N -->`
— 갈래마다 자기 마커만 센다)의 개수다 — 본문은
읽지도 쓰지도 않는다(append-only 라 남의 편집을 덮어쓸 일이 없다). 정지 라벨은 이슈와
**연결된 열린 PR 양쪽**에 미러돼 있으므로 재개·승격은 PR 라벨까지 함께 되돌린다 — 안 그러면
PR 이 영구 needs-human 으로 남고 뒤 전이(handoff-verify·verify-pass·closeout-pick)가 그걸 안 뗀다.
재개는 PR 의 홀드(`hold:ladder`·`hold:conflict`)를 떼는 그 편집에서 이슈 칸에 맞는 미러(`flow:agent-ready`, 이슈가
`agent:claimed` 면 `flow:claimed`)도 되붙인다(#420, PR 에 칸 라벨이 이미 있으면 겹치지 않는다) — 정지
전이가 PR 의 단계 라벨을 이미 뗀 뒤라, 안 붙이면 그 PR 은 다음 claim 까지 무라벨이다(#281 불변식 위반).
그 되돌림은 스윕이 **스스로 재개·승격할 때**뿐이라, 사람이 `hold:policy`(또는 상한을 넘긴
홀드)를 푸는 경로엔 PR 사본을 지우는 자리가 없었다 — 그래서 같은 실행이 **정지 미러 정리**(#265)도
한다: 이슈에 정지 라벨이 하나도 없는데 짝이 되는 열린 PR 에 남아 있으면 **PR 쪽만** 뗀다
(짝은 head 가 `agent/issue-*` 이고 `Closes` 링크가 증명된 PR 뿐 — 사람이 연 PR 의 표식과
`Refs` 전용 PR 의 정상 홀드는 건드리지 않는다).
**떼는 조건은 부재가 아니라 양성 증거다** — 부재("이슈에 정지 라벨이 없다")는 ⓐ 사람이 뗐다
ⓑ 기계가 뗐다 ⓒ **전이가 부분 실패해 애초에 못 붙었다** 를 구분하지 못하고, ⓒ 는 실재한다
(`transition.sh` 는 PR 을 먼저·이슈를 나중에 편집한다). 그래서 라벨 **이벤트 이력**으로
이슈의 마지막 해제가 PR 의 마지막 부착보다 **늦은** 것을 확인하고, 못 하면 떼지 않고 warn 을
낸다. 그리고 PR 정지가 맨몸 `needs-human`(= `hold:` 접두 0개)뿐이면 **절대 떼지 않는다** —
기계는 그 모양을 못 만들므로(세 홀드 전이는 `--reason` 필수) 사람이 손으로 세운 브레이크다.
이벤트별 처리:

- `mirror_cleared` — 사람이 이슈에서만 푼 홀드의 **PR 사본**을 스크립트가 뗐다(#265).
  이슈는 원래 깨끗하니 건드리지 않는다. **추가 조치 없다** — 그 PR 은 이번 틱부터
  `verify-eligible.sh`·`closeout-eligible.sh` 후보로 자연히 돌아온다. ④ Report 에
  `미러 정리 N` 으로 한 줄(번호는 `pr`, 연결 이슈는 `number`, 뗀 라벨은 `removed`).
- `mirror_retry_exhausted` — 정지 미러 정리가 **양성 증거를 못 얻은 채** `MIRROR_RETRY_LIMIT`
  회를 채웠다(#397 — `attempts`/`limit` 를 `3/3` 으로 읽는다). 스크립트는 라벨을 한 번도
  건드리지 않았다(증거 없이 사람 게이트를 벗기지 않는 게 그 갈래의 규율). 여기서 **사람 몫으로
  올려라**: `$SCRIPTS/transition.sh runner-held <repo> <number> <pr> --reason policy --note "미러 불일치 증거 부재 <attempts>회 — PR 과 이슈의 정지 라벨이 어긋난다"`
  (이슈와 PR 양쪽에 `hold:policy` + 질문 코멘트). 전이가 exit 1·2 면 ④ Report 에
  `BLOCKED: 전이 실패 runner-held #<number>(exit N)` 한 줄 — 다음 틱이 같은 이벤트를 다시 낸다
  (마커를 더 쌓지 않으므로 회차가 부풀지 않는다). 성사되면 이슈에 정지 라벨이 생겨 그 PR 은
  다음 틱부터 미러 정리 대상에서 빠진다(자연 종료). ④ Report 의 warn 에 `미러 상한 #<pr>` 한 줄.
- `resumed` — 홀드(`reason` 필드: `ladder` 면 `hold:ladder`, `conflict` 면 `hold:conflict`,
  #345)가 떨어졌고 `agent-ready` 는 그대로다(자격은
  건드리지 않는다). **디스패처가 따로 할 일은 없다** — 이번 틱 ③ 의 `eligible-issues.sh`
  후보로 자연히 다시 나타난다(conflict 재개 건은 ③ 이 프롬프트에 홀드 노트와 rebase 지시를
  인라인한다 — ③ 의 "재개된 이슈면" 항목). ④ Report 의 `재개` 에 번호와 `reason`·`attempt` 를
  `재개 #N(conflict 1/1)` 꼴로 적는다. 배포 대기
  라벨(`deploy-wait`)이 붙은 이슈는 창이 지나도 이 이벤트가 나오지 않는다(#217) — 대신
  아래 `note` 로 간다.
- `escalated` — 재개 상한(`reason` 이 `ladder` 면 `LADDER_RESUME_LIMIT`, `conflict` 면
  `CONFLICT_RESUME_LIMIT`) 초과라 `hold:policy` 로 승격됐다
  (`attempt`/`limit` 은 마커 코멘트가 기록한 소진 횟수 대 상한 — `2/2`·`1/1` 로 읽는다). 라벨은
  스크립트가 이미 붙였으니 **추가 조치 없이** ④ Report 의 `승격` 에 사유를 병기해
  (`승격 #N(conflict, hold:policy)`) 사람이 보게 하라.
  **PR 축**(`number` 가 `null` 이고 `pr` 이 채워진 건, #345 반송): 연결된 열린 이슈가 없는 PR 의
  `hold:conflict`(`closeout-blocked - <pr>` · 홀드 뒤 참조 이슈 닫힘)다 — 재개할 워커를 태울
  이슈가 없어(#421 과 같은 사실) 스윕이 창 뒤 곧장 `hold:policy` 로 승격했고 `attempt`/`limit`
  는 `0/0` 이다(재개 0회·상한 0). 이것도 **추가 조치 없다** — 다음 창이 지나면 같은 스윕의
  PR 단독 재심이 `policy_review_due`(`pr` 축)로 내고 그 처분은 아래 불릿대로 `policy-kept`
  하나다. ④ Report 에는 `승격 PR #N(conflict, hold:policy)` 로 적는다.
- `warn` — 다른 `hold:*`·`needs-human` 동존(자동 재개 대상이 아니다 — conflict 갈래의
  `needs-human` 동존은 `note`) · 사람 조작과의
  경합 · 첫 쓰기 **전** 실패 ·
  **목록/탐색 상한 도달**(`--limit 200` 에 닿아 잘린 이슈가 이번 틱엔 안 보인다는 뜻 — 반복되면
  `.loop/repos` 로 스코프를 좁히라는 신호다. `repo` 가 `*` 면 계정 전체 탐색 쪽이다).
  스크립트가 **손대지 않은** 건이다 — **건드리지 말고** ④ Report 의 warn 에 그대로 옮겨라.
- `note` — 스크립트가 **손대지 않은** 정보 줄이다(사유 라벨 없는 `needs-human` — 사람이
  직접 세운 정지라 **정상**이다(#244) · 배포 대기 이슈의 사유 없는 `needs-human` ·
  배포 대기 이슈의 `hold:ladder`(#217, 창이 지나도 재개·승격 대상이 아니다) · 사람이
  인수한(`full-cycle`) 또는 `needs-human` 을 세운 `hold:conflict`(#345)처럼
  **정상 상태**라 조치할 것이 없는 건). warn 이 아니므로 ④ Report warn 에 올리지 않는다 —
  보고가 필요하면 정보 줄로만 남긴다. warn 을 "루프가 교정 가능한 불변식 위반" 으로 좁히고
  나머지를 note 로 내리는 것이 #188/#190 이 정한 규약이다.
- `warn_after_edit` — 쓰기가 **이미 반영된 뒤**의 부수 실패(라벨 해제 실패 · 승격/재개 readback
  조회 실패·불일치 · **연결 PR 미러 라벨 해제 실패**(문구에 `PR #<번호>`)). 재개/승격 자체는 일어났을 수 있으니 되돌리지 말고, ④ Report 의
  warn 에 `(편집 반영됨)` 표기로 옮겨라 — 다음 틱의 loop-status 가 실제 라벨 상태를 보여 준다.
- `policy_review_due` — `hold:policy` 로 멈춘 지 `RESUME_AFTER_MIN` 이 지났는데 아직 재심을 안 한
  건(#155). **디스패처가 1회 판정한다**: 이슈의 `<!-- hold-note: policy -->` 코멘트에 적힌 "사람이 답해야
  할 질문 한 줄" 을 다시 읽고, 그 답이 플랜(`Plans/*.md`)·이슈 본문·검증 사다리에서 나오면 **루프가
  답한다** — 답을 코멘트로 남기고(`재심: <답> <!-- policy-review: resumed --><!-- bodat:worker -->`)
  `$SCRIPTS/transition.sh verify-redispatch <repo> <issue> <pr|->` 로 재개(needs-human·hold:* 해제,
  agent-ready 유지 → 이번 틱 ③ 후보). 답이 정말 사람 결정이면 **전이가 먼저다** —
  `$SCRIPTS/transition.sh policy-kept <repo> <issue> <pr|->` 로 `needs-human` 을 PR·이슈
  양쪽에 붙이고(#244 — 루프가 `needs-human` 을 붙이는 유일한 자리다. `hold:policy` 는
  사유로 남는다), 그 전이가 **exit 0 `ok` 로 끝난 뒤에만** `재심: 사람 몫 유지 — <이유 한 줄>
  <!-- policy-review: kept --><!-- bodat:worker -->` 코멘트를 남긴다.
  **순서가 계약이다**(#244): 마커가 곧 "재심 끝" 이라, 마커를 먼저 올리면 전이가 죽어도
  다음 틱부터 `reviewed` 로 접혀 `needs-human` 은 영영 안 붙고 그 건은 `hold:policy` 만 남은
  채 **아무도 다시 묻지 않는다**(사람 결정이 needs-human 칸에 영영 안 뜨는 봉인).
  전이가 **비0이면 마커 코멘트를 올리지 말고** ④ Report 에
  `BLOCKED: 전이 실패 policy-kept #<이슈>(exit N)` 한 줄만 남겨라 — 마커가 없으니 다음 스윕이
  같은 건을 `policy_review_due` 로 **다시 낸다**. `policy-kept` 는 붙이기만 하는 멱등 전이라
  재호출이 곧 복구다. 전이 exit → 마커 처분:
  `0`=붙었다→마커 남긴다 · `1`(readback 불일치)·`2`(gh 실패)·`64`(호출 형태 오류)=마커
  남기지 않는다(다음 스윕이 재심을 다시 낸다). **마커가 남은 건만**
  **두 번 묻지 않는다**(사람이 라벨을 뗄 때까지). ④ Report 에 `재심 N(재개 n·유지 m)`.
  **PR 단독 홀드는 언제나 "사람 몫 유지" 로 끝난다**(#395 → #421). 이벤트의 `pr` 필드가 축을
  가른다 — `pr` 이 채워져 있고 `number` 가 `null` 이면 **열린 연결 이슈가 없는 PR** 의
  `hold:policy` 다(`verify-held`·`closeout-blocked` 를 `<issue>` 자리 `-` 로 부른 경우, 또는
  참조 이슈가 전부 닫힌 경우). 질문(`<!-- hold-note: policy -->`)은 그 PR 에 있으니 거기서 읽되,
  **답이 플랜에서 나오더라도 재개하지 마라** — verify-runner ④ 가 "연결 이슈 부재" 를 **사람 칸**
  으로 못박았고(어느 이슈에 붙일지가 사람 결정이다), 이 축에는 재개가 **소비자 없는 상태**다:
  `verify-redispatch` 를 `<issue>` 자리 `-` 로 부르면 PR 에 `flow:agent-ready` 만 남는데
  `eligible-issues.sh` 는 **이슈**만 디스패치하고 `verify-eligible.sh` 는 `flow:verify`·`verifying`
  를 요구한다 — 아무 레인도 그 PR 을 집지 않아 영구 미아가 된다. 그래서 이 축의 처분은 하나다:
  `$SCRIPTS/transition.sh policy-kept <repo> - <pr>`(전이의 이슈 인자는 `-`)가 exit 0 `ok` 로
  끝난 뒤에만 `재심: 사람 몫 유지 — 연결 이슈 없음 — 사람이 이슈를 연결하거나 PR 을 닫는다
  <!-- policy-review: kept --><!-- bodat:worker -->` 를 `gh pr comment <pr>` 로 **그 PR 에**
  남긴다(순서·마커·비0 처분은 위와 글자 그대로 같다 — 비0이면 마커를 올리지 말고
  `BLOCKED: 전이 실패 policy-kept #<PR>(exit N)` 한 줄). ④ Report 의 `유지 m` 에 함께 센다.
  연결 이슈가 **열려 있는** PR 은 이 이벤트가 **안 난다** — 그 건은 이슈 축이 이미 냈다
  (중복 금지).
- `waiting` — 아직 창 안이다. 조용히 넘긴다(보고 불필요).
- exit 2 — 일부 레포의 목록 조회 실패(나머지 레포는 정상 처리됐다) 또는 계정 전체 탐색 실패.
  ④ Report warn 에 `resume-sweep 부분 실패(레포 조회)` 한 줄을 남긴다.
- exit 64 — `RESUME_AFTER_MIN`·`LADDER_RESUME_LIMIT`·`CONFLICT_RESUME_LIMIT` 값이 정수가 아니다(쓰기 전에 멈춘다).
  상수를 고치기 전엔 스윕이 통째로 안 도니 ④ Report warn 에 올려라.

## ② Maintain — 벌린 일 먼저 끝낸다

`pr_open` 이벤트 각각에 대해:

**0. 단계 라벨 보정 (best-effort, 스캔할 때 붙인다).** `$SCRIPTS/pr-state.sh <repo> <pr>` 한 줄이
판정한다(#449) — PR 라벨·이슈 라벨·마지막 판정 세 축을 `references/state-machine.md` 의 행 이름
(`{state, owner, mismatch}`)으로 낸다. 이 산문은 그 표를 다시 적지 않는다.
**`mismatch` 가 비어 있지 않으면 표의 소유 루프가 전이로 맞춘다** — 그중 **이 루프 몫은
`verdict:` 축 하나**다(미러 라벨 없이 열린 옛 PR 의 안전망). 그 항목은 `verdict: pr=<행> target=<라벨>`
꼴로 **붙일 라벨을 그대로 준다**(판정 기호 → 라벨 매핑은 스크립트 한 자리다 — 여기서 다시 외우지 마라):
`gh issue edit <pr> --repo <repo> --add-label <항목의 target> --remove-label <나머지 flow:*>`
한 번(멱등 — 같으면 skip, `--remove-label` 은 없는 라벨에 무해). 나머지 축(`rung`·`stage`·`stop`)은
**건드리지 말고** ④ Report warn 에 `mismatch PR #<pr>(<repo_short>) — <항목>` 한 줄로 올려라:
그 칸의 소유는 `owner` 필드가 말한다(verify-runner·closeout·resume-sweep·사람).
스크립트가 `verdict:` 축을 **안 내는** 자리가 곧 종전 산문의 건너뛰기 목록이다 —
`flow:verify`·`verifying`·`harvesting`·`flow:claimed`·`flow:agent-ready` 가 붙은 PR(#275·#420 —
각각 verify-runner·closeout·워커 레인 소유라 `🔄` 만 보고 올리면 살아있는 워커의 PR 을 뺏는다)과
정지(H:*)·종료(E) 행. **exit 2(조회 실패)면 이 PR 의 보정을 건너뛴다** — 상태를 추측하지 않는다.
최초 CI·구현 단계는 PR 이 아직 없어 이슈 `agent:claimed` 로만 보인다(`flow:ci` 는 재-CI 도는 PR 에만 뜬다).

**서킷 브레이커 — 아래 1~3 의 모든 보수 디스패치 전 공통**:
`N=$($SCRIPTS/attempt-counter.sh <repo> <pr> repair-count)` 로 회차를 읽는다(마커 없으면 `0`,
**exit 2 = 조회 실패 → 이번 틱엔 이 PR 의 보수를 건너뛴다**. 0 으로 읽으면 상한이 리셋된다, #444).
N ≥ `MAX_REPAIRS_PER_PR` 이면 **보수를 디스패치하지 않는다** — 이슈에
`$SCRIPTS/transition.sh runner-held <repo> <num> <pr> --reason policy --note "<질문 한 줄>"` 로 `hold:policy`
를 PR·이슈 양쪽에 부착하고 warn 으로 ④ Report 에 올려라(기계 정지는 사유 라벨 하나만, #244). N 이 상한 미만이면 보수 에이전트를
디스패치하면서 `$SCRIPTS/attempt-counter.sh <repo> <pr> repair-count --bump` 로 회차를 올린다
(마커 갱신·부재 시 본문 끝 추가·나머지 본문 무손상은 스크립트가 한다. **exit 2 면 회차가
안 올라갔다** — 그 디스패치는 하지 말고 ④ Report warn 에 한 줄). 같은 PR 에 1~3 의 사유가 여러 개 겹쳐도 **틱당 같은 PR
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
3. base 와 conflict → **더 이상 여기서 rebase 하지 않는다** — conflict-rebase 소유는
   closeout 으로 이관됐다(closeout ③ 2단계가 `harvesting` 점유 후 직접 rebase·머지).
   issue-runner 는 conflict PR 을 건드리지 않고 다음 closeout 틱에 맡긴다. 미완이므로
   in-flight 로는 계속 계수한다(③ 배압 유지).
4. CI green + 미해결 리뷰 코멘트 없음 → **손대지 않는다.** 사람 리뷰 대기이거나,
   워커가 최종 `머지 판정: ✅` 를 못 찍고 죽은 **완결 유실** 상태다. 완결 유실 회수
   (검증까지 도달한 PR 마감 / 검증 전 죽은 PR 재디스패치)는 **closeout ①-b 정체 스윕**이
   소유한다(`finish-classify.sh` 로 결정적 분류). issue-runner 는 완결 유실 PR 에
   최종 판정을 대리 append 하거나 완결 에이전트를 재디스패치하지 **않는다** — 완결
   로직을 이 루프에 얹지 않고 마감 담당(closeout)에 일원화한다(역할 분리). 단계 라벨
   `flow:*` 보정(규칙0)만 유지해 PR 리스트 자가설명·closeout 스윕 보조신호를 남긴다.

`harvesting` 이벤트 = closeout 마감 진행 중 → **건드리지 않는다**(보수·rebase·리뷰 코멘트 해결 제외). closeout 가 머지/정리한다.

`flow:verify` PR = verify-runner 검증 대기(워커가 구현+결정적CI+PR 까지 마치고 넘김),
`verifying` PR = verify-runner 가 집어 **검증 진행 중**(#275 — 집는 순간 `verify-pick` 이 `flow:verify`
를 이것으로 바꾼다. 원 이슈에도 미러돼 `eligible-issues.sh`·`claim-issue.sh` 가 그 이슈를 제외한다)
→ 둘 다 **건드리지 않는다**(위 1~4 보수·규칙0 보정 모두 제외 — harvesting 과 동형). verify-runner
가 E2E·codex 검증 후 통과면 `머지 판정: ✅`+`flow:ready` 로 closeout 에 넘기고, 실패면
연결 이슈에 `agent-ready` 를 재부착해 반송한다(그때 이 루프의 Dispatch 가 같은 브랜치서
워커를 다시 붙인다 — 정상 재디스패치). 결정적 CI 실패조차 verify-runner 가 반송으로
처리하므로 issue-runner 는 flow:verify PR 의 CI 도 손대지 않는다(사각지대 방지).

## ③ Dispatch — 남는 슬롯만큼만

1. in-flight 계산: ①의 `working` + 이번 틱에 ②로 투입한 보수 + **빨간 PR**
   (`pr_open` 중 CI 실패·미해결 리뷰 코멘트 = ② 1~2 의 보수 대상, 그리고 conflict =
   closeout 이관분이나 미완이라 배압으로 함께 계수)의 수.
   **CI green + 코멘트 없음 PR(② 4, 사람 리뷰 대기)은 슬롯을 점유하지 않는다** —
   에이전트가 손댈 일이 없는 휴면 상태이므로 새 일을 막지 않는다.
   **`flow:verify`·`verifying` PR 도 슬롯을 점유하지 않는다** — verify-runner 소유(이 루프 워커의
   일이 아님)이므로 in-flight 에서 제외한다. 이것이 검증을 별도 레인으로 뺀 throughput
   이득의 실체다: 워커가 PR 을 열고 `flow:verify` 로 넘기는 즉시 슬롯이 반납돼, 느린
   E2E·codex 대기가 더 이상 이 루프의 5슬롯을 붙잡지 않는다.
   `slots = MAX_AGENTS - in-flight`. slots ≤ 0 이면 건너뛴다.
   **적체 배압 — 레포별 판정** (#362): 스코프 레포마다 상태 무관 열린 PR 수를 센다 —
   `for r in <스코프 레포>: gh pr list --repo $r --state open --limit 100 --json number --jq length`.
   `MAX_OPEN_PRS` 이상인 레포는 ③-2 후보에서 **그 레포 이슈만** 건너뛰고, 캡 미만
   레포의 후보는 정상 디스패치한다(합산 캡은 한 레포의 적체가 다른 레포 대기열을 굶겼다).
   캡에 닿은 레포마다 ④ Report 에 `머지 대기 적체 <repo> N개` warn 을 한 줄씩 올린다
   (`<repo>` 는 ④ 의 레포 짧은 이름 — runner·bodat; 캡 미만 레포는 적지 않는다.
   보수는 ② 에서 계속 돈다).
2. `$SCRIPTS/eligible-issues.sh` 실행 → 우선순위 정렬된 후보(**stdout**).
   **stderr 의 `blocked:`·`blocked-summary:`·`warn:` 줄은 ④ Report 로 옮긴다** (#247) —
   `blocked: <repo>#<num> ← #<b>(<상태>)` 는 `막힘` 항목으로, `blocked-summary:` 의 N 은
   `막힘 N` 카운트로, 검색 창 `warn:` 은 Report 의 `warn` 에 그대로. 게이트 탈락은
   조용한 `continue` 라, 안 옮기면 "대기 N건이 왜 안 도는가"가 어디에도 안 남는다.
3. **LLM 판단 (덜 집는 쪽으로만)**: 후보 중 같은 레포·같은 모듈을 건드릴 것으로
   보이는 이슈가 둘 이상이면 이번 틱에는 하나만 집는다. 판단이 서지 않으면 집는다
   (충돌은 다음 틱 rebase 가 풀어준다).
4. 위에서부터 slots 개에 대해:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — 실패(이미 claim·잠금 경합 패배 등)하면
      다음 후보로. 이 헬퍼가 라벨을 붙이기 전에 create-only 잠금 ref
      (`refs/issue-runner/claim/<num>/<앵커>`)를 먼저 잡는다 — 라벨 부착은 멱등이라
      그 자체로는 잠금이 못 되기 때문(#108). 두 루프 세션이 같은 이슈를 동시에
      노려도 정확히 하나만 통과한다. 이전 attempt 가 커밋 없이 죽어 잠금만 남은
      경우는 `<앵커>-takeover` 를 다시 create-only 로 잡아 인수한다(자식 경로는 git ref D/F 충돌로 불가 — 형제 이름이어야 한다) — 그 경합도
      하나만 통과하므로 스테일 인수 경로에서 원자성이 깨지지 않는다. 인수한 워커까지
      커밋 없이 죽으면 그 앵커는 막힌다 — 그때만 사람이 두 ref 를 지워 푼다:
      `gh api repos/<repo>/git/matching-refs/issue-runner/claim/<num> -q '.[].ref'` 로
      확인하고 `gh api -X DELETE repos/<repo>/git/refs/<ref에서 refs/ 뗀 나머지>`.
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — 마지막 줄이 worktree 경로.
      시크릿(`.env`·`config/master.key`) 심링크는 기본 off 다 — repos.conf 에
      `link-secrets` 를 켠 레포에서만 깔린다(#109). 안 켠 레포의 credential 의존
      테스트는 실패가 아니라 **skip** 으로 보고한다.
   c. `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`
      (= `<repo-dir>/.loop/lessons.md`, 기록 경로와 동일 해석)가 있으면 내용을 읽어 둔다.
      **`.loop/lessons-verifier.md` 는 읽지 마라** — 검증자용 사례집이라 구현 워커에겐
      무관하고 프롬프트만 부풀린다(① 의 라우팅 항목 참조).
   d. 디스패치 직전 `~/.claude/skills/issue-runner/references/worker-template.md` 를
      읽고 placeholder(`<WT_PATH>` `<REPO>` `<NUM>` `<TITLE>` `<DEFAULT_BRANCH>`
      `<REPO_DIR>` `<LESSONS_OR_"없음">`)를 채워 투입하라 (Agent 툴 백그라운드 디스패치
      — 호출 시그니처는 템플릿 파일 상단에 있다).
      `<DEFAULT_BRANCH>` 는
      `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name` 으로 채운다.
      `<REPO_DIR>` 는 `$SCRIPTS/repo-dir.sh <repo>` 출력(메인 체크아웃 절대경로)으로
      채운다 — 워커의 codegraph 탐색(`-p`)이 이 경로의 인덱스를 읽는다.
      (워커는 더 이상 codex 검증자를 스폰하지 않는다 — 검증은 verify-runner 소유라
      `<VERIFIER>` placeholder 가 필요 없다. VERIFIER 상수는 ① Reconcile 의 교훈 추출에만 쓰인다.)
      워커는 대신 PR 을 열기 전에 **자기 검토용 사전 리뷰어(general-purpose) 1회를 중첩 스폰**한다
      (템플릿 9-b — 비게이트·fail-open·1라운드, 결과는 PR 본문 `## 사전 리뷰`). 디스패처가 할 일은
      없다 — 워커가 `TaskOutput` 블로킹으로 리뷰어를 기다리므로 스트림은 그 동안만 +1 이고 `MAX_AGENTS`
      는 그대로다. 워커 종료 보고의 `사전 리뷰: <값>` 줄을 ④ Report 에 옮겨 적어라(값 부재도 한 줄로) —
      효과는 verify-runner 반송(`재검증 실패:`) 건수 / 실제 리뷰가 돈(CLEAN·발견) 비율로 잰다.
      **재개된 이슈면 프롬프트에 두 가지를 더 인라인하라.** 마커(`<!-- ladder-resume: N -->`)를
      품은 **코멘트**가 하나라도 있으면 ① 의 재개 스윕이 되살린 건이고, 그 개수가 몇 번째
      재개인지다(본문에는 마커가 없다 — 스윕은 본문을 건드리지 않는다):
      (인용은 세지 않는다 — 백틱 인라인 코드·코드펜스 안의 마커는 신호가 아니라 신호를
      *설명하는 글*이라, `resume-sweep.sh` 의 `JQ_UNQUOTE` 와 **같은 정의**로 먼저 걷어낸다.
      두 곳이 갈라지면 사람 눈에 안 보이는 두 번째 계산기가 다른 수를 센다 — #197.
      **조회도 같은 자리다**(#397): `gh issue view --json comments` 는 첫 100건만 줘서 코멘트가
      많은 이슈에선 스윕(페이지네이션)과 이 자리가 다른 수를 센다 — `pr-comments.sh` 로 전량을
      읽는다. 출력이 `{comments:[…]}` 가 아니라 **배열**이라 `.[]` 다.)

      ````sh
      $SCRIPTS/pr-comments.sh <repo> <num> | jq 'def unquoted: gsub("\\r\\n"; "\n") | gsub("(^|\\n) {0,3}(?<f>```+)[^`\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<f>`*[ \\t]*(?=\\n|$)|$)|(^|\\n) {0,3}(?<t>~~~+)[^\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<t>~*[ \\t]*(?=\\n|$)|$)"; " ") | gsub("(?<!`)(?<r>`+)(?!`)([^\\n]*?)(?<!`)\\k<r>(?!`)"; " "); [.[] | select(.body|unquoted|test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))] | length'
      ````

      채운 템플릿 뒤에 ⓐ 사다리 문서 경로
      `~/.claude/skills/issue-runner/references/live-verification-ladder.md` (어느 칸을 어떤
      명령으로 올라가는지 워커가 읽을 곳) 와 ⓑ **직전 시도의 실패 출력** — 이슈의 마지막
      사다리 관련 코멘트 본문 — 을 덧붙인다:
      `$SCRIPTS/pr-comments.sh <repo> <num> | jq -r '[.[] | select((.body|test("사다리|ladder")) and ((.body|test("^재개 "))|not))] | last.body // ""'`
      (스윕이 남긴 `재개 N/…` 코멘트는 제외한다 — 그게 시간상 마지막이라 안 거르면 실패
      출력 대신 그 줄을 물려준다). 그리고 한 줄로 지시하라: **"같은 칸에서 같은 실패를
      반복하지 말고 다음 칸부터 시도하라(N번째 재개다). 그래도 못 오르면 시도한 칸과 실패
      출력을 인용해 `BLOCKED:` 로 멈춰라"** — 인용 없는 미룸은 허용되지 않는다.

      **충돌 재개 갈래(#345).** 마커가 `<!-- conflict-resume: N -->` 이면(위 jq 의 `ladder-resume`
      자리를 `conflict-resume` 으로 바꿔 센다 — 같은 `unquoted` 정의) ① 이 `hold:conflict` 를
      되돌린 건이다. 이 워커에는 사다리 문서 대신 두 가지를 인라인하라:
      ⓐ 이슈의 **마지막 `사람 확인(conflict):` 코멘트 본문** — closeout ③ 이 `--reason conflict
      --note` 로 남긴 "워커 재개 범위" 한 줄(#344)이다:
      `$SCRIPTS/pr-comments.sh <repo> <num> | jq -r '[.[] | select(.body|test("^사람 확인\\(conflict\\):"))] | last.body // ""'`
      ⓑ 한 줄 지시: **"이 브랜치에 열린 PR 이 있다. `git fetch origin && git rebase origin/<DEFAULT_BRANCH>`
      로 올려 충돌을 원안 의도대로 해소하고 노트의 추가 작업을 구현한 뒤 `--force-with-lease` 로
      push, 기존 PR 을 이어 써라(새 PR 금지 · merge 커밋 금지). 못 합치면 충돌 파일과 이유를
      인용해 `BLOCKED:` 로 멈춰라"**. 워커 템플릿 10단계의 재디스패치 감지가 이 회차를
      "이슈의 `사람 확인(conflict):` 가 PR 의 마지막 `재검증 실패:` 보다 **나중**(없음 포함)"
      으로 알아보고, 인라인된 이 지시를 반송 갈래보다 우선한다.

## ④ Report

한 줄 요약: `정리 N · 보수 N · 신규 N · 재개 N · 승격 N · 막힘 N · 대기(사람 리뷰) N · warn N`
(`재개`·`승격` 은 ① 재개 스윕의 `resumed`·`escalated` 수 — 항목에는 이벤트의 `reason`
(`ladder`|`conflict`, #345)을 병기한다. `막힘` 은 ③-2 eligible 스캔의
`blocked-summary:` 수 — 후보였는데 OPEN 블로커로 탈락한 건이다. 0 이어도 적는다).
그 아래 **항목마다 번호를 적는다** — 숫자만으론 어느 이슈·PR 이 어디로 갔는지 다음 틱이 못 읽는다:
`정리: #4801(bodat, PR #4810 머지) · 보수: PR #4812(bodat, rebase) · 신규: #4818(bodat) · 재개: #4772(bodat, ladder 2/2) #5103(bodat, conflict 1/1) · 승격: #4803(bodat, ladder, hold:policy) · 막힘: #4986(bodat ← #4985 needs-human) · warn: #4799(bodat) dirty worktree`.
검색 창 `warn:`(`검색 창 절단`·`검색 창 임박`)은 warn 줄에 그대로 옮긴다 — 창이 차면
**가장 새 이슈부터** 후보 목록에서 조용히 사라지므로, 그 신호가 사라지면 큐가 죽어도 안 보인다.
레포 짧은 이름 규칙은 `loop-status.sh` 와 같다(`owner/repo` 의 repo 를 소문자로 — bodat·bodac,
`issue-runner` 만 `runner` 특례).
warn 이 있으면 경로와 사유를 그 아래 나열.
**토큰 관측 (소프트 예산)**: 완료 보고를 낸 워커가 있으면 이슈별 한 줄
`토큰: <repo>#<num> <이번 보고치> (누적 <합>)` 을 추가하라. 같은 워커 보고의 `사전 리뷰: <값>` 도
`사전 리뷰: <repo>#<num> <값>` 한 줄로 옮겨 적어라(줄이 없으면 `없음` — 9-b 가 조용히 빠진 신호다). 이번 보고치는 완료
알림의 subagent_tokens (없으면 `?` — 누적에선 0 취급), 누적은 컨텍스트에 보이는
이전 틱 Report 의 같은 이슈 `토큰:` 수치 + 이번 보고치 (안 보이면 이번 보고치 그대로).
누적이 `SOFT_TOKEN_BUDGET_PER_ISSUE` 초과면 그 줄에 **"소프트 예산 초과 —
needs-human 승격 권고"** 를 명시하라 (보고만 — 라벨 부착·워커 중단 등 자동 조치 금지).
모든 카운트가 0이면 "조용함" 한 줄만 — `막힘 N` 도 카운트다. 막힌 건이 있으면 조용한 틱이
아니다(그 침묵이 이 항목을 만든 이유다).

**파이프라인 스냅샷 (매 틱 필수).** 위 줄들 뒤에 `$SCRIPTS/loop-status.sh --post issue-runner --delta "<이 틱 한 줄 요약>"`(레포마다 고정 이슈 `루프 현황`(라벨 `loop-dashboard`) 본문도 덮어쓴다 — 깃헙만 보고 누가 들고 있고 루프가 마지막으로 언제 돌았는지 알게, #163) 를 실행해
출력을 **그대로** 붙인다 — 카운터는 "이 틱에 한 일"만 말하고 무엇이 쌓여 있는지는
이 블록만 본다. `cd` 없이 부른다(스코프는 루프 세션 cwd 의 `.loop/repos` 를 자동 적용).
**카운트가 전부 0인 조용한 틱에도 붙인다** — 스냅샷은 "놀고 있는 것"을 보는 유일한 창이다.
- exit 1(부분 실패 — 일부 레포 조회 실패)이면 그 출력을 그대로 붙이고 warn 에
  `loop-status 부분 실패` 한 줄을 더한다.
- exit 64(스코프 없음 — 계정 전체 세션이라 `.loop/repos` 가 없음)면 이 틱에 만진 레포들을
  `--repo <owner/repo>` 로 명시해 한 번 더 부르고, 그래도 없으면 warn 에
  `loop-status: 스코프 없음(.loop/repos 부재)` 한 줄.
조용한 틱이라도 **③ Dispatch 의 eligible 스캔(eligible-issues.sh)은 매 틱 실행하라** —
새 agent-ready 이슈는 reconcile 이벤트를 만들지 않으므로 eligible 스캔을 거르면 절전
모드가 신규 후보에 영구히 맹목이 된다(빈 큐에서는 search/issues 1콜이라 비용 무시 가능).
eligible 이 비고 reconcile 도 조용하면 "조용함" 한 줄만 보고하고 끝내라.

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
