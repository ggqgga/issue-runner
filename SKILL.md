---
name: issue-runner
description: GitHub 계정 전체에서 agent-ready 이슈를 자동으로 집어 worktree에서 구현하고 PR을 여는 자율 디스패처. /loop 와 함께 사용 (예— /loop 15m /issue-runner). 매 틱 Reconcile → Maintain → Dispatch → Report 를 수행한다. 머지는 절대 하지 않는다.
---

# issue-runner — 이슈 디스패처 틱

당신은 무인 디스패처다. 아래 4단계를 **순서대로** 수행하라. 단계 순서를 바꾸지 마라
(정리가 먼저여야 슬롯 계산이 정확하고, 보수가 신규보다 먼저여야 한다).

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
- `MAX_OPEN_PRS = 14` — 열린 PR 총수 적체 상한. 도달 시 신규 디스패치만 멈춘다
  (보수는 계속) — 사람 머지가 밀릴 때 PR 끼리 rebase conflict 가 폭증하는 것을 막는
  배압(backpressure).
  **2026-08-14 에 10→14 로 상향** — 사람 대기(needs-human·사람 게이트) PR 이 상시
  2~3건 캡을 영구 점유해 실효 캡이 7 로 떨어져 있었다(2026-08-13 실측: 10칸 중 3칸).
  14 는 그 상시 점유분을 흡수한 값이다. 사람 대기 PR 이 정리되면 다시 낮춰도 된다.
- `MAX_REPAIRS_PER_PR = 3` — PR 1개당 보수 디스패치 상한 (② Maintain 서킷 브레이커)
- `ISSUE_TIMEBOX_HOURS = 1` — PR 없는 `working` 이슈에서 **진행 증거를 묻기 시작하는**
  claim 경과 시간 (① Reconcile timebox). 경과 초과 **자체는 중단 사유가 아니다** — 이
  시간을 넘긴 뒤에도 진행 증거가 있으면 유예한다(#200).
- `STALL_MIN = 25` — "무진전" 의 기준(분). 원격 브랜치 `agent/issue-<num>` 의 최신 커밋이
  이보다 오래됐을 때만 커밋 쪽 진행 증거가 죽는다. 근거: bodat `bin/ci` 1회 실측 상한
  ~570초(9.5분)에 박스 전역 직렬 CI 큐(#127) 대기 여유를 더한 값 — 워커가 CI 한 판을
  기다리는 동안 새 커밋이 없는 것은 정상이므로, 그 구간을 무진전으로 세면 안 된다.
- `MAX_TIMEBOX_GRACE = 3` — 같은 claim 에서 허용하는 **누적 유예 횟수**(사이에 `unknown`
  틱이 끼어도 리셋되지 않는다 — 세는 창은 claim 시각 이후 전부다). 넘으면 진행
  증거가 있어도 규칙대로 중단한다 — 유예가 무한이면 진짜 좀비를 못 잡아 이 완화 자체가
  새 구멍이 된다. 틱 간격 15분 기준 최대 ~45분의 추가 시간이라 실측(72분·64분) 형상을
  덮으면서도 상한이 남는다. 횟수는 상태 파일이 아니라 이슈 코멘트 마커
  (`<!-- timebox-grace: N -->`)를 **현재 claim 시각 이후 것만** 세어 재파생한다.
- `RESUME_AFTER_MIN = 120` — 재개 스윕이 멈춘 이슈를 다시 흘려보내기까지 기다리는
  시간(분). `needs-human` + `hold:ladder` 이슈의 마지막 갱신이 이만큼 지나면 ① 의 재개
  스윕이 집는다 (`resume-sweep.sh` 에 동명 환경변수로 전달된다).
- `LADDER_RESUME_LIMIT = 2` — 이슈 1건당 자동 재개 상한. 초과하면 재개 대신
  `hold:policy` 승격 — 그때만 사람이다(무한 재시도 금지).
- `STALE_FINISH_MIN = 30` — 완결 유실 판별 시간버퍼(분). `finish-classify.sh` 의
  버퍼이며, 이제 이 헬퍼는 **closeout ①-b 정체 스윕**이 소비한다(issue-runner 는 규칙4
  원복 후 직접 쓰지 않음). 살아있는 워커는 `검증자 리뷰:` 직후 수초 내 최종 판정을
  찍으므로, 최신 검증자가 CLEAN 인데 이 버퍼를 넘도록 최종 판정이 없으면 워커 사망으로
  간주. 진행 중 fix 루프는 최신 검증자 코멘트가 recent 이거나 non-CLEAN 이라 자동 제외.
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
  가리키게 하는 유일한 해석)에 `- [YYYY-MM-DD PR#<pr>] <교훈>` 형식으로 append.
  **20줄 초과 시 가장 오래된 줄 삭제** (context rot 방어). lessons를 CLAUDE.md로 옮기는
  것은 사람만 한다.
  **라우팅 — `lessons.md` 는 구현 교훈 전용이다.** 이 파일은 ③-4d 에서 **워커 프롬프트에
  그대로 실린다. 그래서 담기는 것은 "다음 구현자가 같은 코드를 다시 짤 때 쓸 지식"뿐이다.
  교훈이 **검증 판정 계열**(검증자가 무엇을 오판했나 · false BLOCKER 를 어떻게 뒤집었나 ·
  BLOCKER vs WARN 경계)이면 여기 쓰지 말고 같은 디렉토리의 **`.loop/lessons-verifier.md`**
  에 append 하라 — 그 파일은 verify-runner ③-3 과 closeout 1단계가 검증자 프롬프트에
  주입한다(캡·형식은 closeout 쪽 규칙을 따른다). 두 파일을 섞으면 양쪽 프롬프트가 서로
  무관한 지식으로 희석된다.
- `rejected` — 사람이 PR을 거부함. **살아있는 워커가 있으면 `merged` 와 동일하게
  `TaskStop` 으로 먼저 중단**(고아 방지). lessons 단계 동일하게 수행. 이슈는 재디스패치하지
  않는다 (agent-ready가 이미 제거됨).
- `stale` — 죽은 claim 해제됨. 보고만.
- `warn` — dirty/unpushed worktree. **건드리지 말고** Report에 그대로 올려 사람이 보게 하라.
- `pr_open` — ② Maintain 의 입력.
- `working` — 워커 진행 중. TaskList 로 해당 백그라운드 에이전트가 실제 살아있는지
  확인. 죽었고 push 된 커밋이 있으면 ② 의 보수 대상으로. 커밋이 전혀 없으면
  claim 해제 **전에** 이슈 최신 코멘트를 확인하라 —
  `gh issue view <num> --repo <repo> --json comments --jq '[.comments[] | select((.body | test("<!--\\s*timebox-grace:")) | not)] | last.body'`
  (timebox 유예 마커 코멘트는 건너뛴다 — 마커가 최신 코멘트 자리를 차지하면 워커가 남긴
  `BLOCKED:` 가 가려져 사람대기 승격 대신 조용한 claim 해제로 샌다, #200)
  가 `BLOCKED:` 로 시작하면 워커가 사람 개입이 필요해서 멈춘 것이다 (모호 스펙 /
  계획-현실 불일치 / 동일 실패 반복): 재디스패치 복귀 대신
  `$SCRIPTS/transition.sh runner-held <repo> <num> <pr|-> --reason policy --note "<사람이 답해야 할 질문 한 줄>"` 로 `needs-human`
  + `hold:policy` 를 부착하고(claim 해제 포함 — 사유 없는 `needs-human` 은 만들지 않는다, #151),
  worktree 제거 후 warn 으로 ④ Report 에 BLOCKED 사유를
  올려라 (사람이 원인을 해소하고 `needs-human` **과 `hold:*` 를 둘 다** 떼면 다시 흐른다 —
  게이트가 `hold:` 접두도 보므로 한쪽만 떼면 후보로 안 돌아온다, #242. README
  '가드레일' 규약). BLOCKED 코멘트가 아니면 worktree 제거 후 claim 해제
  (재디스패치 가능 상태로 복귀).
  **timebox (무진전 감지)**: 살아있어도 **진행이 있는지** 확인하라 — 판정 입력은 경과
  시간이 아니라 진행 증거다(#200: 경과에는 워커가 통제할 수 없는 박스 전역 직렬 CI 큐
  대기가 통째로 들어가, 실측 2건에서 진행 중인 워커를 죽일 뻔했다).
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
스크립트가 알아서 적용한다). `needs-human` 이 사유 라벨로 남긴 정지 중 **`hold:ladder`**
(실측 사다리 ①~③ 칸이 전부 실패해 멈춘 건)만 창(`RESUME_AFTER_MIN`)이 지나면 자동으로
되돌린다 — `hold:conflict`·`hold:policy` 는 사람 결정이라 건드리지 않는다. ③ Dispatch
**앞**에서 돌려야 이번 틱이 그 이슈를 바로 집는다.
재개 횟수는 이슈 **코멘트**에 붙은 마커(`<!-- ladder-resume: N -->`)의 개수다 — 본문은
읽지도 쓰지도 않는다(append-only 라 남의 편집을 덮어쓸 일이 없다). 정지 라벨은 이슈와
**연결된 열린 PR 양쪽**에 미러돼 있으므로 재개·승격은 PR 라벨까지 함께 되돌린다 — 안 그러면
PR 이 영구 사람대기로 남고 뒤 전이(handoff-verify·verify-pass·closeout-pick)가 그걸 안 뗀다.
이벤트별 처리:

- `resumed` — `needs-human`·`hold:ladder` 가 떨어졌고 `agent-ready` 는 그대로다(자격은
  건드리지 않는다). **디스패처가 따로 할 일은 없다** — 이번 틱 ③ 의 `eligible-issues.sh`
  후보로 자연히 다시 나타난다. ④ Report 의 `재개` 에 번호와 `attempt` 를 적는다. 배포 대기
  라벨(`deploy-wait`)이 붙은 이슈는 창이 지나도 이 이벤트가 나오지 않는다(#217) — 대신
  아래 `note` 로 간다.
- `escalated` — 재개 상한(`LADDER_RESUME_LIMIT`) 초과라 `hold:policy` 로 승격됐다
  (`attempt`/`limit` 은 마커 코멘트가 기록한 소진 횟수 대 상한 — `2/2` 로 읽는다). 라벨은
  스크립트가 이미 붙였으니 **추가 조치 없이** ④ Report 의 `승격` 에 올려 사람이 보게 하라.
- `warn` — 사유 라벨(`hold:*`) 없는 `needs-human`(사람이 손으로 붙였을 수 있어 자동 재개
  대상이 아니다) · 사람 몫 `hold:*` 동존 · 사람 조작과의 경합 · 첫 쓰기 **전** 실패 ·
  **목록/탐색 상한 도달**(`--limit 200` 에 닿아 잘린 이슈가 이번 틱엔 안 보인다는 뜻 — 반복되면
  `.loop/repos` 로 스코프를 좁히라는 신호다. `repo` 가 `*` 면 계정 전체 탐색 쪽이다).
  스크립트가 **손대지 않은** 건이다 — **건드리지 말고** ④ Report 의 warn 에 그대로 옮겨라.
- `note` — 스크립트가 **손대지 않은** 정보 줄이다(배포 대기 이슈의 사유 없는 `needs-human` ·
  배포 대기 이슈의 `hold:ladder`(#217, 창이 지나도 재개·승격 대상이 아니다)처럼
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
  agent-ready 유지 → 이번 틱 ③ 후보). 답이 정말 사람 결정이면 `재심: 사람 몫 유지 — <이유 한 줄>
  <!-- policy-review: kept --><!-- bodat:worker -->` 코멘트만 남긴다. 어느 쪽이든 마커가 남으므로
  **같은 건은 두 번 묻지 않는다**(사람이 라벨을 뗄 때까지). ④ Report 에 `재심 N(재개 n·유지 m)`.
- `waiting` — 아직 창 안이다. 조용히 넘긴다(보고 불필요).
- exit 2 — 일부 레포의 목록 조회 실패(나머지 레포는 정상 처리됐다) 또는 계정 전체 탐색 실패.
  ④ Report warn 에 `resume-sweep 부분 실패(레포 조회)` 한 줄을 남긴다.
- exit 64 — `RESUME_AFTER_MIN`·`LADDER_RESUME_LIMIT` 값이 정수가 아니다(쓰기 전에 멈춘다).
  상수를 고치기 전엔 스윕이 통째로 안 도니 ④ Report warn 에 올려라.

## ② Maintain — 벌린 일 먼저 끝낸다

`pr_open` 이벤트 각각에 대해:

**0. 단계 라벨 보정 (best-effort, 스캔할 때 붙인다).** 이 PR 의 마지막 판정 코멘트를
읽어(`gh pr view <pr> --repo <repo> --json comments`) 단계 라벨 `flow:*` 를 실제 상태에
맞춘다 — 워커·verify-runner 가 각 단계에서 직접 붙이지만 크래시·놓침이 있을 수 있어
스캔이 안전망이다. **단, `flow:verify` 또는 `harvesting` 라벨이 붙은 PR 은 이 보정을
건너뛴다**(각각 verify-runner·closeout 소유 — 아래 소유 규칙과 동일). 그 외 PR 만 보정:
마지막 코멘트가 `머지 판정: ✅` → `flow:ready`(closeout 이 집는다), `머지 판정: 🔄`(✅ 전)
→ `flow:verify`(verify-runner 에 넘김 — 워커가 라벨을 못 붙이고 죽은 경우 안전망),
`머지 판정: ⚠ 보류` → flow:* 제거(needs-human 경로). 목표 라벨과 현재가 다를 때만
`gh issue edit <pr> --repo <repo> --add-label <목표> --remove-label <나머지 flow:*>` 로
교체한다(멱등 — 같으면 skip, `--remove-label` 은 없는 라벨에 무해). 최초 CI·구현 단계는
PR 이 아직 없어 이슈 `agent:claimed` 로만 보인다(`flow:ci` 는 재-CI 도는 PR 에만 뜬다).

**서킷 브레이커 — 아래 1~3 의 모든 보수 디스패치 전 공통**:
PR 본문에서 `<!-- repair-count: N -->` HTML 주석을 읽어라
(`gh pr view <pr> --repo <repo> --json body`; 주석이 없으면 N = 0).
N ≥ `MAX_REPAIRS_PER_PR` 이면 **보수를 디스패치하지 않는다** — 이슈에
`$SCRIPTS/transition.sh runner-held <repo> <num> <pr> --reason policy --note "<질문 한 줄>"` 로 `needs-human` + `hold:policy`
를 PR·이슈 양쪽에 부착하고 warn 으로 ④ Report 에 올려라(사유 없는 `needs-human` 은 만들지 않는다, #151). N 이 상한 미만이면 보수 에이전트를
디스패치하면서 PR 본문의 주석을 `<!-- repair-count: N+1 -->` 로 갱신하라
(`gh pr edit <pr> --repo <repo> --body ...` — 주석이 없었으면 본문 끝에 새로 추가,
나머지 본문은 그대로 유지). 같은 PR 에 1~3 의 사유가 여러 개 겹쳐도 **틱당 같은 PR
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

`flow:verify` PR = verify-runner 검증 진행 중(워커가 구현+결정적CI+PR 까지 마치고 넘김)
→ **건드리지 않는다**(위 1~4 보수·규칙0 보정 모두 제외 — harvesting 과 동형). verify-runner
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
   **`flow:verify` PR 도 슬롯을 점유하지 않는다** — verify-runner 소유(이 루프 워커의
   일이 아님)이므로 in-flight 에서 제외한다. 이것이 검증을 별도 레인으로 뺀 throughput
   이득의 실체다: 워커가 PR 을 열고 `flow:verify` 로 넘기는 즉시 슬롯이 반납돼, 느린
   E2E·codex 대기가 더 이상 이 루프의 5슬롯을 붙잡지 않는다.
   `slots = MAX_AGENTS - in-flight`. slots ≤ 0 이면 건너뛴다.
   **적체 배압**: 상태 무관 열린 PR 총수가 `MAX_OPEN_PRS` 이상이면 신규 디스패치를
   건너뛰고 ④ Report 에 "머지 대기 적체 N개" warn 을 올린다 (보수는 ② 에서 계속 돈다).
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
      두 곳이 갈라지면 사람 눈에 안 보이는 두 번째 계산기가 다른 수를 센다 — #197)

      ````sh
      gh issue view <num> --repo <repo> --json comments --jq 'def unquoted: gsub("\\r\\n"; "\n") | gsub("(^|\\n) {0,3}(?<f>```+)[^`\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<f>`*[ \\t]*(?=\\n|$)|$)|(^|\\n) {0,3}(?<t>~~~+)[^\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<t>~*[ \\t]*(?=\\n|$)|$)"; " ") | gsub("(?<!`)(?<r>`+)(?!`)([^\\n]*?)(?<!`)\\k<r>(?!`)"; " "); [.comments[] | select(.body|unquoted|test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))] | length'
      ````

      채운 템플릿 뒤에 ⓐ 사다리 문서 경로
      `~/.claude/skills/issue-runner/references/live-verification-ladder.md` (어느 칸을 어떤
      명령으로 올라가는지 워커가 읽을 곳) 와 ⓑ **직전 시도의 실패 출력** — 이슈의 마지막
      사다리 관련 코멘트 본문 — 을 덧붙인다:
      `gh issue view <num> --repo <repo> --json comments --jq '[.comments[] | select((.body|test("사다리|ladder")) and ((.body|test("^재개 "))|not))] | last.body // ""'`
      (스윕이 남긴 `재개 N/…` 코멘트는 제외한다 — 그게 시간상 마지막이라 안 거르면 실패
      출력 대신 그 줄을 물려준다). 그리고 한 줄로 지시하라: **"같은 칸에서 같은 실패를
      반복하지 말고 다음 칸부터 시도하라(N번째 재개다). 그래도 못 오르면 시도한 칸과 실패
      출력을 인용해 `BLOCKED:` 로 멈춰라"** — 인용 없는 미룸은 허용되지 않는다.

## ④ Report

한 줄 요약: `정리 N · 보수 N · 신규 N · 재개 N · 승격 N · 막힘 N · 대기(사람 리뷰) N · warn N`
(`재개`·`승격` 은 ① 재개 스윕의 `resumed`·`escalated` 수. `막힘` 은 ③-2 eligible 스캔의
`blocked-summary:` 수 — 후보였는데 OPEN 블로커로 탈락한 건이다. 0 이어도 적는다).
그 아래 **항목마다 번호를 적는다** — 숫자만으론 어느 이슈·PR 이 어디로 갔는지 다음 틱이 못 읽는다:
`정리: #4801(bodat, PR #4810 머지) · 보수: PR #4812(bodat, rebase) · 신규: #4818(bodat) · 재개: #4772(bodat, 2/2) · 승격: #4803(bodat, hold:policy) · 막힘: #4986(bodat ← #4985 사람대기) · warn: #4799(bodat) dirty worktree`.
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
