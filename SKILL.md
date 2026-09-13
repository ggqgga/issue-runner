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
> 같은 규칙이 남아 있으면 표가 이긴다.
>
> **세 루프가 공유하는 규약의 SSOT 는 `references/loop-conventions.md` 다**(#452). fail-closed 의 뜻(§1) ·
> warn·note·막힘 채널 경계(§2) · 스크립트 stderr → ④ Report 릴레이(§3) · 센티널 마커(§4) · `Closes #N`
> 전용 줄(§5) · 레포 짧은 이름(§6) · 파이프라인 스냅샷 규율(§7) · 라벨 부재 폴백(§8) · 검증 사다리 칸
> 규율(§9) · 표면 교정 판정(§10) — 아래 산문은 그 절들을 가리키지 재진술하지 않는다.
>
> **왜 그 규칙인가(사고 이력·실측·버린 대안)는 `references/issue-runner-rationale.md` 다**(#454). 아래
> `(근거: issue-runner-rationale §N)` 이 그 절을 가리킨다 — 틱 수행에 그 파일은 읽지 않아도 된다.

## 상수

LLM 이 판단에 쓰는 노브만 적는다. 값의 실측사는 근거 문서 §1·§2.

- `MAX_AGENTS = 4` — 동시 in-flight 이슈 상한 (in-flight 정의는 ③-1 — 사람 리뷰 대기 PR 은 점유하지 않는다).
  여전히 느리면 2 로 더 낮춘다. **5 이상은 실측 없이 올리지 마라** — 상향의 실제 상한은 API 가 아니라 머신
  부하다 (근거: issue-runner-rationale §1).
- `MAX_OPEN_PRS = 14` — **레포별** 열린 PR 수 적체 상한. 캡에 닿은 레포의 신규 디스패치만 멈춘다(보수는 계속,
  다른 레포는 정상 디스패치) — 사람 머지가 밀릴 때 PR 끼리 rebase conflict 가 폭증하는 것을 막는
  배압(backpressure) (근거: issue-runner-rationale §1).
- `MAX_REPAIRS_PER_PR = 3` — PR 1개당 보수 디스패치 상한 (② Maintain 서킷 브레이커)
- **스크립트가 읽는 상수 — 값은 `scripts/lib/constants.sh` 한 자리다** (#427). 이 절은 값을 다시 적지 않는다 —
  이름과 뜻만이다. 값이 궁금하면 `grep '<이름>' $SCRIPTS/lib/constants.sh` (근거: issue-runner-rationale §2).
  - `ISSUE_TIMEBOX_HOURS` — PR 없는 `working` 이슈에서 **진행 증거를 묻기 시작하는** claim 경과 시간
    (① Reconcile timebox). 경과 초과 **자체는 중단 사유가 아니다** — 넘긴 뒤에도 진행 증거가 있으면 유예한다(#200).
  - `STALL_MIN` — "무진전" 의 기준(분). 커밋 쪽 진행 증거의 신선도 판정은 `timebox-check.sh` 가 한다.
  - `MAX_TIMEBOX_GRACE` — 같은 claim 에서 허용하는 **누적 유예 횟수**. 횟수는 상태 파일이 아니라 이슈 코멘트
    마커(`<!-- timebox-grace: N -->`)를 **현재 claim 시각 이후 것만** 세어 재파생한다.
  - `RESUME_AFTER_MIN` — 재개 스윕이 멈춘 이슈를 다시 흘려보내기까지 기다리는 창(분).
  - `LADDER_RESUME_LIMIT` — 이슈 1건당 자동 재개 상한. 초과하면 재개 대신 `hold:policy` 승격(무한 재시도 금지).
  - `CONFLICT_RESUME_LIMIT` — `hold:conflict` 의 자동 재개 상한(#345). 창은 `RESUME_AFTER_MIN` 공용. 초과하면
    `hold:policy` 승격 → 재심(③)의 질문은 "ⓑ 인수인가, 재발행인가".
  - `MIRROR_RETRY_LIMIT` — ① 재개 스윕의 **정지 미러 정리** 재시도 상한(#397). 회차는 짝 이슈 코멘트의
    `<!-- mirror-retry: <사유> pr=<n> -->` 마커 개수(세는 범위는 §2) — 닿으면 `mirror_retry_exhausted`.
  - `STALE_FINISH_MIN` — 완결 유실 판별 시간버퍼(분). **closeout ①-b 정체 스윕**이 소비한다
    (`finish-classify.sh`, issue-runner 는 직접 쓰지 않음).
- `SOFT_TOKEN_BUDGET_PER_ISSUE = 300000` — 이슈당 소프트 토큰 예산. 하드 캡이 아니라 ④ Report 의 관측 기준.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — 리뷰·교훈 추출용 검증자 서브에이전트 타입. **출력 계약 (SSOT — 다른 모든
  곳은 이 항목을 참조한다)**: 리뷰 호출은 read-only(코드 변경 금지)·발견마다 BLOCKER/WARN/NIT 분류·발견 없으면
  'CLEAN'·BLOCKER 는 게이트(해결 전 종료 금지), 교훈 추출 호출(① Reconcile)은 '교훈 1줄 또는 NONE'. 검증자는
  SKILL.md 를 읽지 않으므로 호출 프롬프트 문자열에는 이 계약이 그대로 담겨야 한다 — 프롬프트가 유일한 전달
  경로다. **폴백**: codex 플러그인 미설치 환경(Agent 툴의 subagent_type 목록에 위 타입이 없거나, 호출이
  unknown subagent type 오류로 실패)에서는 `general-purpose` 를 검증자로 쓴다 — 같은 프롬프트로 호출하므로
  계약도 동일하게 적용된다.
- 절대 금지: PR 머지, main 직접 push, 사람이 만든 브랜치 조작, agent-ready 라벨 임의 부착, 완결 유실 PR 에 최종
  `머지 판정: ✅` 대리 append(그 회수는 closeout ①-b 스윕 소유). **허용**: ② Maintain 규칙0 의 단계 라벨
  `flow:*` 보정 (근거: issue-runner-rationale §2).

## ① Reconcile

`$SCRIPTS/reconcile.sh` 를 실행하고 이벤트별로 처리:

- `merged` — PR 머지. ★**이슈가 닫혔다는 뜻은 아니다**★(#117, 근거: issue-runner-rationale §3).
  **고아 워커 정리(선행)**: 이 이슈의 워커가 아직 살아있으면 (TaskList 로 `<repo>#<num> 구현` 백그라운드
  에이전트 확인) `TaskStop` 으로 중단하라. 그다음 **lessons 단계**: 아래 실패 신호가 하나라도 잡히면 (전부
  `gh pr view <pr> --repo <repo>` 로 확인) `VERIFIER` 서브에이전트(## 상수의 VERIFIER 계약·폴백을 따른다)를
  동기 호출하라. 신호가 하나도 안 잡히면 호출하지 말고 NONE 으로 둔다(lessons 미기록):
  (1) CHANGES_REQUESTED 리뷰(`--json reviews`) · (2) `gh run list` CI 실패(GitHub Actions 레포) ·
  (3) **local-ci commit status 실패 이력** — PR 의 커밋 중 하나라도 local-ci 컨텍스트가 FAILURE 였으면
  (`--json commits` 로 커밋 SHA 를 열거하고 각 SHA 를 `gh api repos/<repo>/commits/<sha>/statuses` 로 조회한다
  — HEAD 의 `--json statusCheckRollup` 은 쓰지 마라, 근거: issue-runner-rationale §4) ·
  (4) **검증자 리뷰 코멘트의 BLOCKER** — PR 의 `마감 검증:`·`검증자 리뷰:` 코멘트에 BLOCKER 가 있었던
  경우(`--json comments`).

  ⚠️ **리베이스는 (3) 을 무력화한다 — "실패 이력 없음"을 판정으로 믿지 마라**(근거: issue-runner-rationale §4).
  판별: `gh api repos/<repo>/issues/<pr>/timeline --jq '[.[]|select(.event=="head_ref_force_pushed")]|length'`
  가 0 보다 크면 커밋 열거가 불완전하다. 그때는 — ⓐ 컨텍스트(워커 완료 보고·이전 틱 Report 의 `run-local-ci`
  결과)에 리베이스 **이전 SHA** 가 있으면 그 SHA 로 `gh api repos/<repo>/commits/<sha>/statuses` 를 직접 조회해
  판정하라. ⓑ 이전 SHA 를 모르면 (3) 을 미상으로 두고 나머지 신호(1·2·4)로만 판단한 뒤, ④ Report 에
  **"리베이스로 실패 이력 판별 불가"** 한 줄을 남겨라. 조용히 '없음'으로 넘기지 마라.
  (교훈이 이미 `lessons.md` 에 같은 내용으로 있으면 중복 append 하지 마라. 그 경우 Report 에 "기존 교훈과
  동일 — 미기록"으로 적는다.)

  > "PR #<pr> (<repo>)의 리뷰 코멘트와 CI 실패 로그를 읽고, 객관적 실패 사실에서
  > 재발 방지 교훈을 딱 1줄로: '<상황>일 때 <구체 행동>하라' 형식. 추측·일반론 금지.
  > 실패 사실이 없으면 'NONE' 출력."

  결과가 NONE이 아니면 `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`
  (= `<repo-dir>/.loop/lessons.md`)에 `- [YYYY-MM-DD PR#<pr>] <교훈>` 형식으로 append 하고 캡까지 정리한다 —
  **`$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"` 한 자리로 부른다**(파일이 없으면 새로 만든다).
  **append 를 이 호출 밖에서 손으로 하지 마라**(#208, 근거: issue-runner-rationale §5). **캡: 항목 20개** —
  초과 시 **항목 수가 캡 이하가 될 때까지** 가장 오래된 항목부터 지운다. lessons를 CLAUDE.md로 옮기는 것은
  사람만 한다. **라우팅 — `lessons.md` 는 구현 교훈 전용이다**(③-4d 에서 워커 프롬프트에 그대로 실린다).
  교훈이 **검증 판정 계열**(검증자가 무엇을 오판했나 · false BLOCKER 를 어떻게 뒤집었나 · BLOCKER vs WARN
  경계)이면 여기 쓰지 말고 같은 디렉토리의 **`.loop/lessons-verifier.md`** 에 append 하라 — **이 파일도 같은
  호출로 쓴다**: `$SCRIPTS/lessons-trim.sh append <파일> 20 "<1줄>"` (근거: issue-runner-rationale §5).
- `rejected` — 사람이 PR을 거부함. **살아있는 워커가 있으면 `merged` 와 동일하게 `TaskStop` 으로 먼저 중단**
  (고아 방지). lessons 단계 동일하게 수행. 이슈는 재디스패치하지 않는다 (agent-ready가 이미 제거됨).
- `stale` — 죽은 claim 해제됨. 보고만.
- `warn` — dirty/unpushed worktree. **건드리지 말고** Report에 그대로 올려 사람이 보게 하라.
- `half_moved_redispatch` — `verify-redispatch` 가 **반쯤 실패한** PR 이다(#394, 근거: §6).
  **같은 전이를 멱등 재실행하라**: `$SCRIPTS/transition.sh verify-redispatch <repo> <이슈> <pr>` (PR 쪽은 no-op
  이고 이슈만 `agent-ready` 로 돌아온다 → 이번 틱 ③ 후보). 성사되면 ④ Report 의 `보수` 에
  `#<num>(반쯤 이동 회수)` 한 줄. 전이가 비0이면 `references/state-machine.md` 「전이 실패의 공통 규칙」 대로
  ④ Report 에 `BLOCKED: 전이 실패 verify-redispatch PR #<pr>(<repo_short>) — <stderr 한 줄>` 만 남기고 다음
  이벤트로 간다(규칙은 여기서 다시 적지 않는다). 이 이벤트가 난 PR 은 **② Maintain 입력이 아니다**. 여기서
  신선도를 다시 재지 마라.
- `pr_open` — ② Maintain 의 입력.
- `working` — 워커 진행 중. TaskList 로 해당 백그라운드 에이전트가 실제 살아있는지 확인.
  **"죽어 보임"(TaskList 상 종료)을 바로 사망으로 단정하지 마라** — 그 태스크의 `TaskOutput(task_id)` 로 마지막
  메시지를 먼저 읽어라. 마지막 줄이 `CI 대기 중 — <SHA 40자> <queued N|running|none>, 다음 할 일: <한 줄>`
  형식이면 `run-local-ci.sh` 큐 대기 중 턴만 끝낸 것이지 사망이 아니다(#185) — **worktree 제거·claim 해제를
  하지 말고** `SendMessage` 로 그 태스크에 재개 메시지를 보내 워커를 깨워라(보고에 적힌 "다음 할 일"을
  이어가게 하라는 한 줄이면 된다). 재개했으면 ④ Report 의 `보수` 에 `#<num>(CI 대기 재개)` 로 적어라 —
  그리고 **재개에 성공했으면 이 이슈는 이번 틱에서 여기까지다. 아래 진짜 사망 경로도, 그 끝의 timebox 청소도
  실행하지 말고 다음 이벤트로 넘어가라**(코드로 치면 여기서 `continue`).
  **상태 토큰은 `queued N`·`running`·`none` 셋이고 — 세 상태 다 재개 신호다.** 어느 값이 왔든 위와 똑같이
  재개하라(worktree 제거·claim 해제는 **세 경우 모두** 하지 않는다). 세 토큰의 뜻과 턴이 끝난 서브에이전트가
  `SendMessage` 로 깨어나는 근거는 issue-runner-rationale §7. 이 형식이 아니면(진짜 사망) 아래로 이어간다.
  **폴백 — 재개 메시지에도 응답이 없으면**(태스크가 정말 회수된 드문 경우) claim 을 풀지 말고 **기존
  worktree·브랜치를 그대로 재사용해 대체 워커를 디스패치**하라. **새 claim 도, 새 PR 도 만들지 않는다**(열린
  PR 이 있으면 그걸 이어 쓰게 하라). 이 폴백까지 실패하면 그때 아래 진짜 사망 경로로 내려간다.
  죽었고 push 된 커밋이 있으면 ② 의 보수 대상으로. 커밋이 전혀 없으면 claim 해제 **전에** 이슈 최신 코멘트를
  확인하라 —
  `gh issue view <num> --repo <repo> --json comments --jq '[.comments[] | select((.body | test("<!--\\s*timebox-grace:")) | not)] | last.body'`
  (timebox 유예 마커 코멘트는 건너뛴다 — 근거: issue-runner-rationale §7) 가 `BLOCKED:` 로 시작하면 워커가
  사람 개입이 필요해서 멈춘 것이다 (모호 스펙 / 계획-현실 불일치 / 동일 실패 반복): 재디스패치 복귀 대신
  `$SCRIPTS/transition.sh runner-held <repo> <num> <pr|-> --reason policy --note "<사람이 답해야 할 질문 한 줄>"` 로
  `hold:policy` 를 부착하고(claim 해제 포함 — 기계 정지는 사유 라벨 하나만 붙인다, #244), worktree 제거 후
  warn 으로 ④ Report 에 BLOCKED 사유를 올려라(근거: issue-runner-rationale §7).
  BLOCKED 코멘트가 아니면 worktree 제거 후 claim 해제 (재디스패치 가능 상태로 복귀).
  **timebox (무진전 감지)** — **이번 틱에 `SendMessage` 로 재개한 이슈는 면제다.** 재개하지 않은 건이면
  살아있어도 **진행이 있는지** 확인하라 — 판정 입력은 경과 시간이 아니라 진행 증거다(#200, 근거: §8).
  `gh api repos/<repo>/issues/<num>/timeline --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed")] | last.created_at'`
  로 claim 시각을 구하고 (빈 응답이면 worktree 디렉토리 생성 시각으로 대체),
  `$SCRIPTS/timebox-check.sh <repo> <num> --claim-at <ISO8601>` 에 넘겨라 (`working` 은 정의상 PR 없음).
  판정은 한 줄로 나온다 — `<verdict> <reason> elapsed=..m commit=..m queue=.. grace=n/max`:
  - `ok` (exit 0) — 경과가 아직 `ISSUE_TIMEBOX_HOURS` 이내. 손대지 마라.
  - `grace` (exit 0) — 경과는 넘었지만 진행 증거가 있다(`recent_commit`·`ci_queued`). 이번 틱은 **중단하지
    마라**. 헬퍼가 유예 마커를 이슈에 append 하므로 다음 틱이 그 개수를 세어 `MAX_TIMEBOX_GRACE` 를 건다.
    ④ Report 에는 **warn 이 아니라 정보 줄**로 판정 줄을 그대로 옮겨라.
  - `stop` (exit 1) — 무진전(`no_progress`)이거나 유예 상한 소진(`grace_exhausted`). 아래 ⓐ~ⓓ 를 그대로 하라.
  - `unknown` (exit 2) — 판정 입력을 못 얻었다(claim 시각·브랜치 조회·코멘트 조회·유예 마커 append 실패).
    **중단하지 말고** ④ Report 에 warn 으로 올려라 (근거: issue-runner-rationale §8).

  `stop` 일 때만: ⓐ TaskStop 으로 워커를 중단하고, ⓑ worktree 를 제거하라 —
  `git -C <repo-dir> worktree remove --force <wt>` 후 `git -C <repo-dir> branch -D agent/issue-<num>`
  (미push 잔여물은 `stop` 판정의 대가로 **의도적으로 폐기**한다, 근거: issue-runner-rationale §8),
  ⓒ `gh issue edit <num> --repo <repo> --remove-label "agent:claimed"` 로 claim 을 해제한 뒤, ⓓ warn 으로
  ④ Report 에 올려라.

**재개 스윕 — 멈춘 건은 틱이 다시 시도한다.** 위 이벤트를 전부 처리한 뒤 `$SCRIPTS/resume-sweep.sh` 를 인자 없이
실행하라(스코프는 세션 cwd 의 `.loop/repos` 를 스크립트가 알아서 적용한다). **③ Dispatch 앞**에서 돌려야 이번
틱이 그 이슈를 바로 집는다. 스윕은 기계 정지(`hold:*`) 중 **`hold:ladder`** 와 **`hold:conflict`**(#345)를
창(`RESUME_AFTER_MIN`)이 지나면 되돌리고(재개 횟수는 이슈 **코멘트** 마커 `<!-- ladder-resume: N -->` ·
`<!-- conflict-resume: N -->` 의 개수 — 갈래마다 자기 마커만 센다), 연결된 열린 PR 의 미러 라벨까지 함께
되돌리며(#420), 이슈에서만 정지가 풀린 PR 의 **정지 미러 정리**(#265)도 한다. `hold:policy` 만 사람 결정으로
남고 재심(③) 1회를 거친다. `needs-human` 동존 · `full-cycle` 이 붙은 `hold:conflict` 는 재개 대상이
아니다(#244·#345). 스윕 자체의 판정 규율(양성 증거 · 맨몸 `needs-human` 보존)은 스크립트 소유다
(근거: issue-runner-rationale §9·§10). 이벤트별 처리:

- `mirror_cleared` — 사람이 이슈에서만 푼 홀드의 **PR 사본**을 스크립트가 뗐다(#265). 이슈는 원래 깨끗하니
  건드리지 않는다. **추가 조치 없다** — 그 PR 은 이번 틱부터 `verify-eligible.sh`·`closeout-eligible.sh` 후보로
  자연히 돌아온다. ④ Report 에 `미러 정리 N` 으로 한 줄(번호는 `pr`, 연결 이슈는 `number`, 뗀 라벨은 `removed`).
- `mirror_retry_exhausted` — 정지 미러 정리가 **양성 증거를 못 얻은 채** `MIRROR_RETRY_LIMIT` 회를 채웠다
  (#397 — `attempts`/`limit` 를 `3/3` 으로 읽는다). 여기서 **사람 몫으로 올려라**:
  `$SCRIPTS/transition.sh runner-held <repo> <number> <pr> --reason policy --note "미러 불일치 증거 부재 <attempts>회 — PR 과 이슈의 정지 라벨이 어긋난다"`
  (이슈와 PR 양쪽에 `hold:policy` + 질문 코멘트). 전이가 비0이면 `references/state-machine.md` 「전이 실패의
  공통 규칙」 대로 ④ Report 에 `BLOCKED: 전이 실패 runner-held #<number>(exit N)` 한 줄 — 다음 틱이 같은
  이벤트를 다시 낸다. ④ Report 의 warn 에 `미러 상한 #<pr>` 한 줄 (근거: issue-runner-rationale §10).
- `resumed` — 홀드(`reason` 필드: `ladder` 면 `hold:ladder`, `conflict` 면 `hold:conflict`, #345)가 떨어졌고
  `agent-ready` 는 그대로다. **디스패처가 따로 할 일은 없다** — 이번 틱 ③ 의 `eligible-issues.sh` 후보로
  자연히 다시 나타난다(conflict 재개 건은 ③ 의 "재개된 이슈면" 항목이 홀드 노트와 rebase 지시를 인라인한다).
  ④ Report 의 `재개` 에 번호와 `reason`·`attempt` 를 `재개 #N(conflict 1/1)` 꼴로 적는다. 배포 대기
  라벨(`deploy-wait`)이 붙은 이슈는 이 이벤트가 아니라 아래 `note` 로 간다(#217).
- `escalated` — 재개 상한(`reason` 이 `ladder` 면 `LADDER_RESUME_LIMIT`, `conflict` 면 `CONFLICT_RESUME_LIMIT`)
  초과라 `hold:policy` 로 승격됐다(`attempt`/`limit` 은 소진 횟수 대 상한 — `2/2`·`1/1` 로 읽는다). 라벨은
  스크립트가 이미 붙였으니 **추가 조치 없이** ④ Report 의 `승격` 에 사유를 병기해
  (`승격 #N(conflict, hold:policy)`) 사람이 보게 하라. **PR 축**(`number` 가 `null` 이고 `pr` 이 채워진 건,
  #345 반송)도 **추가 조치 없다**(`attempt`/`limit` 는 `0/0`) — ④ Report 에 `승격 PR #N(conflict, hold:policy)`
  로 적는다 (근거: issue-runner-rationale §10).
- `warn` — 다른 `hold:*`·`needs-human` 동존(conflict 갈래의 `needs-human` 동존은 `note`) · 사람 조작과의 경합 ·
  첫 쓰기 **전** 실패 · **목록/탐색 상한 도달**(`--limit 200`). 스크립트가 **손대지 않은** 건이다 —
  **건드리지 말고** ④ Report 의 warn 에 그대로 옮겨라 (근거: issue-runner-rationale §10).
- `note` — 스크립트가 **손대지 않은** 정보 줄이다(사유 라벨 없는 `needs-human` · 배포 대기 이슈의 사유 없는
  `needs-human` · 배포 대기 이슈의 `hold:ladder`(#217) · 사람이 인수한(`full-cycle`) 또는 `needs-human` 을
  세운 `hold:conflict`(#345)처럼 **정상 상태**라 조치할 것이 없는 건). warn 이 아니므로 ④ Report warn 에
  올리지 않는다 — 보고가 필요하면 정보 줄로만 남긴다. 세 채널의 경계는 `references/loop-conventions.md` §2 대로.
- `warn_after_edit` — 쓰기가 **이미 반영된 뒤**의 부수 실패(라벨 해제 실패 · 승격/재개 readback 조회 실패·불일치
  · **연결 PR 미러 라벨 해제 실패**(문구에 `PR #<번호>`)). 재개/승격 자체는 일어났을 수 있으니 되돌리지 말고,
  ④ Report 의 warn 에 `(편집 반영됨)` 표기로 옮겨라.
- `policy_review_due` — `hold:policy` 로 멈춘 지 `RESUME_AFTER_MIN` 이 지났는데 아직 재심을 안 한 건(#155).
  **디스패처가 1회 판정한다**: 이슈의 `<!-- hold-note: policy -->` 코멘트에 적힌 "사람이 답해야 할 질문 한 줄" 을
  다시 읽고, 그 답이 플랜(`Plans/*.md`)·이슈 본문·검증 사다리에서 나오면 **루프가 답한다** — 답을 코멘트로
  남기고(`재심: <답> <!-- policy-review: resumed --><!-- bodat:worker -->`)
  `$SCRIPTS/transition.sh verify-redispatch <repo> <issue> <pr|->` 로 재개(needs-human·hold:* 해제, agent-ready
  유지 → 이번 틱 ③ 후보). 답이 정말 사람 결정이면 **전이가 먼저다** —
  `$SCRIPTS/transition.sh policy-kept <repo> <issue> <pr|->` 로 `needs-human` 을 PR·이슈 양쪽에 붙이고(#244 —
  루프가 `needs-human` 을 붙이는 유일한 자리다. `hold:policy` 는 사유로 남는다), 그 전이가 **exit 0 `ok` 로
  끝난 뒤에만** `재심: 사람 몫 유지 — <이유 한 줄> <!-- policy-review: kept --><!-- bodat:worker -->` 코멘트를
  남긴다. **순서가 계약이다**(#244, 근거: issue-runner-rationale §11). 전이가 **비0이면 마커 코멘트를 올리지
  말고** ④ Report 에 `BLOCKED: 전이 실패 policy-kept #<이슈>(exit N)` 한 줄만 남겨라. exit 코드별 뜻과 조치는
  `references/state-machine.md` 의 「전이 실패의 공통 규칙」 이 SSOT 다 — 여기서 다시 적지 않는다. 이 자리에서만
  다른 것은 **마커 처분** 하나다: exit 0 이면 마커를 남기고, 비0이면 남기지 않는다. **마커가 남은 건만 두 번
  묻지 않는다**(사람이 라벨을 뗄 때까지). ④ Report 에 `재심 N(재개 n·유지 m)`.
  **PR 단독 홀드는 언제나 "사람 몫 유지" 로 끝난다**(#395 → #421). 이벤트의 `pr` 필드가 축을 가른다 — `pr` 이
  채워져 있고 `number` 가 `null` 이면 **열린 연결 이슈가 없는 PR** 의 `hold:policy` 다.
  질문(`<!-- hold-note: policy -->`)은 그 PR 에 있으니 거기서 읽되, **답이 플랜에서 나오더라도 재개하지 마라**
  (근거: issue-runner-rationale §12). 이 축의 처분은 하나다:
  `$SCRIPTS/transition.sh policy-kept <repo> - <pr>`(전이의 이슈 인자는 `-`)가 exit 0 `ok` 로 끝난 뒤에만
  `재심: 사람 몫 유지 — 연결 이슈 없음 — 사람이 이슈를 연결하거나 PR 을 닫는다
  <!-- policy-review: kept --><!-- bodat:worker -->` 를 `gh pr comment <pr>` 로 **그 PR 에** 남긴다(순서·마커·
  비0 처분은 위와 글자 그대로 같다 — 비0이면 마커를 올리지 말고 `BLOCKED: 전이 실패 policy-kept #<PR>(exit N)`
  한 줄). ④ Report 의 `유지 m` 에 함께 센다.
- `waiting` — 아직 창 안이다. 조용히 넘긴다(보고 불필요).
- exit 2 — 일부 레포의 목록 조회 실패(나머지 레포는 정상 처리됐다) 또는 계정 전체 탐색 실패. ④ Report warn 에
  `resume-sweep 부분 실패(레포 조회)` 한 줄을 남긴다.
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
`flow:verify`·`verifying`·`harvesting`·`flow:claimed`·`flow:agent-ready` 가 붙은 PR(#275·#420)과
정지(H:*)·종료(E) 행. **exit 2(조회 실패)면 이 PR 의 보정을 건너뛴다** — 상태를 추측하지 않는다.
(건너뛰는 레인의 근거는 issue-runner-rationale §13.)

**서킷 브레이커 — 아래 1~3 의 모든 보수 디스패치 전 공통**:
`N=$($SCRIPTS/attempt-counter.sh <repo> <pr> repair-count)` 로 회차를 읽는다(마커 없으면 `0`,
**exit 2 = 조회 실패 → 이번 틱엔 이 PR 의 보수를 건너뛴다**. 0 으로 읽으면 상한이 리셋된다, #444).
N ≥ `MAX_REPAIRS_PER_PR` 이면 **보수를 디스패치하지 않는다** — 이슈에
`$SCRIPTS/transition.sh runner-held <repo> <num> <pr> --reason policy --note "<질문 한 줄>"` 로 `hold:policy`
를 PR·이슈 양쪽에 부착하고 warn 으로 ④ Report 에 올려라(기계 정지는 사유 라벨 하나만, #244). N 이 상한 미만이면
보수 에이전트를 디스패치하면서 `$SCRIPTS/attempt-counter.sh <repo> <pr> repair-count --bump` 로 회차를 올린다
(마커 갱신·부재 시 본문 끝 추가·나머지 본문 무손상은 스크립트가 한다. **exit 2 면 회차가 안 올라갔다** — 그
디스패치는 하지 말고 ④ Report warn 에 한 줄). 같은 PR 에 1~3 의 사유가 여러 개 겹쳐도 **틱당 같은 PR 의 보수
에이전트는 1개** — 모든 수리 지시를 그 한 에이전트의 프롬프트에 합치고, N 도 디스패치당 1만 올린다.

1. `failing > 0` → 실패 로그를 확인하고 (gh run view --log-failed), 플레이크로 보이면 re-run (gh run rerun),
   진짜 실패면 워커 템플릿 파일 `~/.claude/skills/issue-runner/references/worker-template.md` (③-4d 와 같은
   방식으로 읽어 채운다)로 **보수 에이전트**를 백그라운드 디스패치 (worktree 가 없으면
   `$SCRIPTS/make-worktree.sh` 가 원격 브랜치 위에 재생성해 준다). 보수 지시는 템플릿의 "절차" 대신 구체적
   수리 내용으로 교체하되 나머지(복합 명령, push 규율, 금지 사항)는 유지.
2. 미해결 리뷰 코멘트 → 같은 방식으로 보수 에이전트에 코멘트 해결을 지시. 단, 워커 자신이 남긴 상태
   코멘트(`머지 판정:`·`검증자 리뷰:` 로 시작)는 리뷰 코멘트가 아니다 — 보수 사유로 세지 마라.
3. base 와 conflict → **더 이상 여기서 rebase 하지 않는다** — conflict-rebase 소유는 closeout 으로 이관됐다
   (closeout ③ 2단계가 `harvesting` 점유 후 직접 rebase·머지). issue-runner 는 conflict PR 을 건드리지 않고
   다음 closeout 틱에 맡긴다. 미완이므로 in-flight 로는 계속 계수한다(③ 배압 유지).
4. CI green + 미해결 리뷰 코멘트 없음 → **손대지 않는다.** 사람 리뷰 대기이거나, 워커가 최종 `머지 판정: ✅` 를
   못 찍고 죽은 **완결 유실** 상태다. 완결 유실 회수는 **closeout ①-b 정체 스윕**이 소유한다
   (`finish-classify.sh` 로 결정적 분류). issue-runner 는 완결 유실 PR 에 최종 판정을 대리 append 하거나 완결
   에이전트를 재디스패치하지 **않는다**. 단계 라벨 `flow:*` 보정(규칙0)만 유지한다 (근거: §13).

`harvesting` 이벤트 = closeout 마감 진행 중 → **건드리지 않는다**(보수·rebase·리뷰 코멘트 해결 제외). closeout 가 머지/정리한다.

`flow:verify` PR = verify-runner 검증 대기(워커가 구현+결정적CI+PR 까지 마치고 넘김), `verifying` PR =
verify-runner 가 집어 **검증 진행 중**(#275) → 둘 다 **건드리지 않는다**(위 1~4 보수·규칙0 보정 모두 제외 —
harvesting 과 동형). issue-runner 는 `flow:verify` PR 의 CI 도 손대지 않는다 (근거: issue-runner-rationale §13).

## ③ Dispatch — 남는 슬롯만큼만

1. in-flight 계산: ①의 `working` + 이번 틱에 ②로 투입한 보수 + **빨간 PR**(`pr_open` 중 CI 실패·미해결 리뷰
   코멘트 = ② 1~2 의 보수 대상, 그리고 conflict = closeout 이관분이나 미완이라 배압으로 함께 계수)의 수.
   **CI green + 코멘트 없음 PR(② 4, 사람 리뷰 대기)은 슬롯을 점유하지 않는다.**
   **`flow:verify`·`verifying` PR 도 슬롯을 점유하지 않는다** — verify-runner 소유이므로 in-flight 에서
   제외한다 (근거: issue-runner-rationale §14). `slots = MAX_AGENTS - in-flight`. slots ≤ 0 이면 건너뛴다.
   **적체 배압 — 레포별 판정** (#362): 스코프 레포마다 상태 무관 열린 PR 수를 센다 —
   `for r in <스코프 레포>: gh pr list --repo $r --state open --limit 100 --json number --jq length`.
   `MAX_OPEN_PRS` 이상인 레포는 ③-2 후보에서 **그 레포 이슈만** 건너뛰고, 캡 미만 레포의 후보는 정상
   디스패치한다. 캡에 닿은 레포마다 ④ Report 에 `머지 대기 적체 <repo> N개` warn 을 한 줄씩 올린다(`<repo>` 는
   ④ 의 레포 짧은 이름 — runner·bodat; 캡 미만 레포는 적지 않는다. 보수는 ② 에서 계속 돈다).
2. `$SCRIPTS/eligible-issues.sh` 실행 → 우선순위 정렬된 후보(**stdout**). **stderr 의
   `blocked:`·`blocked-summary:`·`warn:` 줄은 ④ Report 로 옮긴다** (#247) — 채널별로 어디에 어떻게 옮기는지는
   `references/loop-conventions.md` §3 대로.
3. **LLM 판단 (덜 집는 쪽으로만)**: 후보 중 같은 레포·같은 모듈을 건드릴 것으로 보이는 이슈가 둘 이상이면
   이번 틱에는 하나만 집는다. 판단이 서지 않으면 집는다 (충돌은 다음 틱 rebase 가 풀어준다).
   이 미룸은 라벨을 만지지 않는다 — 미룬 이슈는
   다음 틱 ③-2 에 그대로 돌아오고, ④ Report 에는 `미룸: #N(<repo>, 같은 모듈 #M)` 으로 적는다.
   **후보를 라벨로 파킹하지 않는다 (#493).** `eligible-issues.sh` stdout 에 오른 후보의 자격은
   스크립트가 이미 판정했다(`open + agent-ready + ¬agent:claimed + ¬needs-human + ¬hold:* +
   블로커 전부 CLOSED`) — 그 밖의 라벨은 게이트가 아니고, 세션이 라벨을 읽어 "보류·스킵" 을
   덧대지 않는다. 특히 **`needs:hardware` 는 파킹 사유가 아니다** — "실장비가 관련된다" 는
   분류이지 자격 게이트가 아니며, 뜻은 "본문의 통로대로 실장비를 밟아라" 다. 그 절차는 워커
   몫이고 이미 워커 프롬프트에 있다: 워커 템플릿 11-a 가 이슈 본문의 통로 절(`ssh <워커>`
   직결 · 측정 명령 · 탈출구)과 `references/live-verification-ladder.md` 의 칸을 오르게 하고,
   통로가 없거나 안 먹으면 시도한 칸·실패 출력을 PR `## Test plan` 에 인용하고 그 항목을 `[ ]`
   로 남긴 채 11-b 로 verify-runner 에 넘긴다(멈추지 않는다 — 워커는 BLOCKED 를 내지 않는다).
   그 뒤는 verify-runner ③-2 가 칸 ②③ 을 다시 시도하고, 전부 실패했을 때만 `verify-held
   --reason ladder` 로 `hold:ladder` 다(`transition.sh` 의 세 사유 중 하나 — 사다리 끝까지 오른
   실패의 사유. `hold:policy` 는 워커의 `BLOCKED:` 종료·연결 이슈 부재 같은 사람 결정 몫이다). 실측: 2026-09-13 틱 #188~#190 이 슬롯을 비워둔 채
   `needs:hardware 관측 의존(스킵)` 으로 3틱 연속 신규 0 이었는데, 그 두 이슈(BoDAT #5100·#5198)는
   본문에 통로가 이미 인라인돼 있었거나 구현 범위에 실장비가 없었다(2026-08-26 BoDAT #3852 도
   같은 모양으로 11시간 놀았다). 라벨 파킹은 `needs:hardware + agent-ready` 를 무기한 대기로
   만들고, 대시보드엔 `대기` 로만 보여 "자격 있음·자리 있음·안 집힘" 이 어디에도 안 남는다.
   **집지 않기로 판단했으면 스킵이 아니라 전이다 (#493).** 위 같은-모듈 미룸 밖의 이유(스펙이
   서지 않음·중복·정책 결정 필요)로 후보를 집지 않기로 했으면 그 판단을 라벨 없이 두지
   않는다 — 그 자리에서
   `$SCRIPTS/transition.sh runner-held <repo> <num> - --reason policy --note "<안 집는 사유 + 사람이 답할 질문 한 줄>"`
   로 `hold:policy` 를 붙인다(미claim·PR 없음 이슈에 그대로 성립한다 — `-` 는 정식 형태이고 없는
   `agent:claimed` 제거는 무해하다. 사유 코멘트는 전이가 남긴다. `needs-human` 을 손으로 붙이지 마라 —
   #244, 재심이 "사람 몫 유지" 로 끝날 때 `policy-kept` 가 붙인다. `hold:hardware` 는 일부러 없다).
   다음 틱부터 게이트(`¬hold:*`)가 후보에서 빼고 재심(① `policy_review_due`)이 1회 답한다 —
   틱마다 같은 판단을 되풀이하지 않는다. **중복도 같다**: 다른 이슈·이미 main 에 있는 수정과
   중복이면 `--note "중복: #<원본> — 닫을지 사람이 판단"` 으로 같은 전이를 건다(닫기는 사람
   몫이다 — `closeout-dup` 은 PR 이 있어야 성립하고 `hold:dup` 라벨은 일부러 없다). 틱마다
   "중복(스킵)" 을 반복하지 않는다(BoDAT #5144 가 그렇게 대기 줄에 남았다). ④ Report 에는
   warn 으로 `#N(<repo>) 안 집음 → hold:policy — <사유>` 한 줄을 올린다.
4. 위에서부터 slots 개에 대해:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — 실패(이미 claim·잠금 경합 패배 등)하면 다음 후보로. 이 헬퍼가
      라벨을 붙이기 전에 create-only 잠금 ref(`refs/issue-runner/claim/<num>/<앵커>`)를 먼저 잡는다(#108).
      이전 attempt 가 커밋 없이 죽어 잠금만 남은 경우는 `<앵커>-takeover` 를 다시 create-only 로 잡아 인수한다.
      인수한 워커까지 커밋 없이 죽으면 그 앵커는 막힌다 — 그때만 사람이 두 ref 를 지워 푼다:
      `gh api repos/<repo>/git/matching-refs/issue-runner/claim/<num> -q '.[].ref'` 로 확인하고
      `gh api -X DELETE repos/<repo>/git/refs/<ref에서 refs/ 뗀 나머지>` (근거: issue-runner-rationale §14).
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — 마지막 줄이 worktree 경로. 시크릿(`.env`·`config/master.key`)
      심링크는 기본 off 다 — repos.conf 에 `link-secrets` 를 켠 레포에서만 깔린다(#109). 안 켠 레포의
      credential 의존 테스트는 실패가 아니라 **skip** 으로 보고한다.
   c. `$SCRIPTS/repo-dir.sh <repo>` 출력 경로의 `.loop/lessons.md`(= `<repo-dir>/.loop/lessons.md`, 기록
      경로와 동일 해석)가 있으면 내용을 읽어 둔다. **`.loop/lessons-verifier.md` 는 읽지 마라** — 검증자용
      사례집이라 구현 워커에겐 무관하고 프롬프트만 부풀린다(① 의 라우팅 항목 참조).
   d. 디스패치 직전 `~/.claude/skills/issue-runner/references/worker-template.md` 를 읽고
      placeholder(`<WT_PATH>` `<REPO>` `<NUM>` `<TITLE>` `<DEFAULT_BRANCH>` `<REPO_DIR>`
      `<LESSONS_OR_"없음">`)를 채워 투입하라 (Agent 툴 백그라운드 디스패치 — 호출 시그니처는 템플릿 파일
      상단에 있다). `<DEFAULT_BRANCH>` 는 `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name`
      으로 채운다. `<REPO_DIR>` 는 `$SCRIPTS/repo-dir.sh <repo>` 출력(메인 체크아웃 절대경로)으로 채운다 —
      워커의 codegraph 탐색(`-p`)이 이 경로의 인덱스를 읽는다. 워커 종료 보고의 `사전 리뷰: <값>` 줄을
      ④ Report 에 옮겨 적어라(값 부재도 한 줄로) — 사전 리뷰(템플릿 9-b)에 디스패처가 따로 할 일은 없다
      (근거: issue-runner-rationale §14).
      **재개된 이슈면 프롬프트에 두 가지를 더 인라인하라.** 마커(`<!-- ladder-resume: N -->`)를 품은
      **코멘트**가 하나라도 있으면 ① 의 재개 스윕이 되살린 건이고, 그 개수가 몇 번째 재개인지다. 인용은 세지
      않고 `pr-comments.sh` 로 전량을 읽는다 (근거: issue-runner-rationale §14):

      ````sh
      $SCRIPTS/pr-comments.sh <repo> <num> | jq 'def unquoted: gsub("\\r\\n"; "\n") | gsub("(^|\\n) {0,3}(?<f>```+)[^`\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<f>`*[ \\t]*(?=\\n|$)|$)|(^|\\n) {0,3}(?<t>~~~+)[^\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<t>~*[ \\t]*(?=\\n|$)|$)"; " ") | gsub("(?<!`)(?<r>`+)(?!`)([^\\n]*?)(?<!`)\\k<r>(?!`)"; " "); [.[] | select(.body|unquoted|test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))] | length'
      ````

      채운 템플릿 뒤에 ⓐ 사다리 문서 경로
      `~/.claude/skills/issue-runner/references/live-verification-ladder.md` (어느 칸을 어떤 명령으로 올라가는지
      워커가 읽을 곳) 와 ⓑ **직전 시도의 실패 출력** — 이슈의 마지막 사다리 관련 코멘트 본문 — 을 덧붙인다:
      `$SCRIPTS/pr-comments.sh <repo> <num> | jq -r '[.[] | select((.body|test("사다리|ladder")) and ((.body|test("^재개 "))|not))] | last.body // ""'`
      (스윕이 남긴 `재개 N/…` 코멘트는 제외한다). 그리고 한 줄로 지시하라: **"같은 칸에서 같은 실패를
      반복하지 말고 다음 칸부터 시도하라(N번째 재개다). 그래도 못 오르면 시도한 칸과 실패 출력을 인용해
      `BLOCKED:` 로 멈춰라"** — 인용 없는 미룸은 허용되지 않는다.

      **충돌 재개 갈래(#345).** 마커가 `<!-- conflict-resume: N -->` 이면(위 jq 의 `ladder-resume` 자리를
      `conflict-resume` 으로 바꿔 센다 — 같은 `unquoted` 정의) ① 이 `hold:conflict` 를 되돌린 건이다. 이
      워커에는 사다리 문서 대신 두 가지를 인라인하라: ⓐ 이슈의 **마지막 `사람 확인(conflict):` 코멘트 본문**:
      `$SCRIPTS/pr-comments.sh <repo> <num> | jq -r '[.[] | select(.body|test("^사람 확인\\(conflict\\):"))] | last.body // ""'`
      ⓑ 한 줄 지시: **"이 브랜치에 열린 PR 이 있다. `git fetch origin && git rebase origin/<DEFAULT_BRANCH>`
      로 올려 충돌을 원안 의도대로 해소하고 노트의 추가 작업을 구현한 뒤 `--force-with-lease` 로 push, 기존
      PR 을 이어 써라(새 PR 금지 · merge 커밋 금지). 못 합치면 충돌 파일과 이유를 인용해 `BLOCKED:` 로
      멈춰라"** (근거: issue-runner-rationale §14).

## ④ Report

한 줄 요약: `정리 N · 보수 N · 신규 N · 재개 N · 승격 N · 막힘 N · 대기(사람 리뷰) N · warn N`
(`재개`·`승격` 은 ① 재개 스윕의 `resumed`·`escalated` 수 — 항목에는 이벤트의 `reason`(`ladder`|`conflict`,
#345)을 병기한다. `막힘` 은 ③-2 eligible 스캔의 `blocked-summary:` 수 — 후보였는데 OPEN 블로커로 탈락한
건이다. 0 이어도 적는다). 그 아래 **항목마다 번호를 적는다**:
`정리: #4801(bodat, PR #4810 머지) · 보수: PR #4812(bodat, rebase) · 신규: #4818(bodat) · 재개: #4772(bodat, ladder 2/2) #5103(bodat, conflict 1/1) · 승격: #4803(bodat, ladder, hold:policy) · 막힘: #4986(bodat ← #4985 needs-human) · warn: #4799(bodat) dirty worktree`.
검색 창 `warn:`(`검색 창 절단`·`검색 창 임박`)은 warn 줄에 그대로 옮긴다. 레포 짧은 이름은
`references/loop-conventions.md` §6 대로. warn 이 있으면 경로와 사유를 그 아래 나열.
**`스킵` 어휘 (#493).** Report 에서 `스킵` 은 **게이트 탈락**에만 쓴다 — 스크립트 게이트
(`막힘`(OPEN 블로커)·`needs-human`·`hold:*` 로 ③-2 stdout 에 오르지 못한 건)와 ③-1 의 수치 캡
(`slots ≤ 0` · 레포별 `MAX_OPEN_PRS` = `머지 대기 적체` warn). 둘 다 결정론이라 판단이 아니다.
stdout 에 오른 후보를 세션 판단으로 안 집은 것은 스킵이 아니다 — ③-3 의 전이
(`hold:policy`)로 기록되므로 warn 항목 `#N(<repo>) 안 집음 → hold:policy — <사유>` 로 적고,
같은-모듈 미룸은 `미룸: #N(<repo>, 같은 모듈 #M)` 으로 적는다(둘 다 카운트가 아니라 항목이다).
후보가 있는데 신규 0 인 틱은 이 두 항목 중 하나(또는 ③-1 캡 스킵 · ③-4a claim 실패의 기록)가
있어야 성립한다 — 아무것도 없이 `신규 없음: … (스킵)` 이면 그것이 곧 라벨 파킹이다(#493 의 실측 모양).
**토큰 관측 (소프트 예산)**: 완료 보고를 낸 워커가 있으면 이슈별 한 줄
`토큰: <repo>#<num> <이번 보고치> (누적 <합>)` 을 추가하라. 같은 워커 보고의 `사전 리뷰: <값>` 도
`사전 리뷰: <repo>#<num> <값>` 한 줄로 옮겨 적어라(줄이 없으면 `없음`). 이번 보고치는 완료 알림의
subagent_tokens (없으면 `?` — 누적에선 0 취급), 누적은 컨텍스트에 보이는 이전 틱 Report 의 같은 이슈 `토큰:`
수치 + 이번 보고치 (안 보이면 이번 보고치 그대로). 누적이 `SOFT_TOKEN_BUDGET_PER_ISSUE` 초과면 그 줄에
**"소프트 예산 초과 — needs-human 승격 권고"** 를 명시하라 (보고만 — 라벨 부착·워커 중단 등 자동 조치 금지).
모든 카운트가 0이면 "조용함" 한 줄만 — `막힘 N` 도 카운트다 (근거: issue-runner-rationale §15).

**파이프라인 스냅샷 (매 틱 필수).** 위 줄들 뒤에 `$SCRIPTS/loop-status.sh --post issue-runner --delta "<이 틱 한 줄 요약>"` 를 실행해 출력을 그대로 붙인다 —
붙이는 규율(`cd` 없이 · 조용한 틱에도)과 exit 1·64 처리는 `references/loop-conventions.md` §7 대로.
조용한 틱이라도 **③ Dispatch 의 eligible 스캔(eligible-issues.sh)은 매 틱 실행하라**(근거: §15).
eligible 이 비고 reconcile 도 조용하면 "조용함" 한 줄만 보고하고 끝내라.

## 참고 자료

비운영 참고 — 틱 수행에는 영향 없다.

- 사고 이력·설계 근거 · 설계에 참고한 문헌: `references/issue-runner-rationale.md`(한글, #454) — 위 각 절의
  `(근거: issue-runner-rationale §N)` 이 가리키는 곳.
- 전제: 이 루프는 **GitHub 위에서만** 동작한다 — 이슈·라벨·assignee·PR이 상태의 단일 진실 원천이며
  GitHub Actions 는 불필요(local-ci 설계). 필요 권한·설치(사용자 레벨 전역 + 라벨 옵트인
  `setup-labels.sh`)·병행 운용(`.loop/repos` 허용목록)·codegraph 병용은 README 와 위 근거 문서 §15.
