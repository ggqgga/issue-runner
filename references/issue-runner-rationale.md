# issue-runner rationale — 사고 이력·설계 근거

루트 `SKILL.md`(디스패처 틱)에서 **지시가 아닌 문장**을 옮겨 놓은 곳이다. 왜 그 규칙인가 ·
어느 이슈·실측이 그 규칙을 낳았나 · 어떤 대안을 왜 버렸나가 여기 있다. **틱 수행에는 이 파일이
필요 없다** — SKILL 만 읽고도 틱은 돈다. 여기 있는 문장은 규칙을 바꿀 사람이 "왜"를 되짚을 때
읽는다.

SKILL 의 문단 끝 `(근거: issue-runner-rationale §N)` 이 이 파일의 절 번호를 가리킨다.
한글만 있고 영문판은 없다 — `SKILL.en.md` 는 지시만 담는다(#454).

이미 SSOT 가 따로 있는 것은 여기에도 옮기지 않았다: 상태·소유·전이 실패는
`references/state-machine.md`, 세 루프 공용 규약은 `references/loop-conventions.md`,
결정론 상수의 값과 그 이력은 `scripts/lib/constants.sh` 주석이다.

## §1 MAX_AGENTS·MAX_OPEN_PRS — 값의 실측사와 상한의 실체

`MAX_AGENTS`: **2026-07 경합 실험으로 5→3 축소**했다. 워커는 전부 한 프로세스에서 도는
백그라운드 subagent 라 동시 N 개면 API·CPU 를 나눠 써 각자 ~1/N 로 throttle 된다(실측: 동시
0 워커 ~10분 vs 동시 1~4 ~30분). 처리량은 거의 보존되며 박스 부하·고아 위험이 준다. 여전히
느리면 2 로 더 낮춘다. **2026-08-14 에 3→4 로 상향** — 대기 이슈 적체 해소 요청. 단, 이 값만
올리면 `MAX_OPEN_PRS` 에 더 빨리 닿을 뿐이라 그것도 함께 올렸다(둘은 짝이다).

⚠️ 상향의 실제 상한은 API 가 아니라 **머신 부하**다: 이 루프의 워커 N 개 +
verify-runner(헤드리스 크롬 E2E) + closeout(재-CI) 이 같은 10코어를 나눠 쓰고, 각 `bin/ci` 가
병렬 테스트 프로세스를 또 띄운다. 4 를 넘기면 동시 `bin/ci` 경합 플레이크(`lessons.md` 의
#2672·#2685·#3077, `poll_health_timeout_test` 부하 타이밍)가 늘어 워커가 무죄 입증에 시간을
쓰게 된다.

`MAX_OPEN_PRS`: 사람 머지가 밀릴 때 PR 끼리 rebase conflict 가 폭증하는 것을 막는
배압(backpressure)이다. **2026-08-14 에 10→14 로 상향** — 사람 대기(needs-human·사람 게이트)
PR 이 상시 2~3건 캡을 영구 점유해 실효 캡이 7 로 떨어져 있었다(2026-08-13 실측: 10칸 중
3칸). 14 는 그 상시 점유분을 흡수한 값이다. 사람 대기 PR 이 정리되면 다시 낮춰도 된다.
**2026-09-13 에 스코프 합산→레포별로 변경(#362)** — 2026-09-12 실측: 합산 캡은 runner 10 +
bodat 5 = 15 로 캡을 채워 bodat 대기 15건이 20틱 넘게 한 번도 안 집혔다. conflict 는 **같은
레포의 PR 사이**에서만 나므로 합산은 근거보다 넓게 막고 한 레포의 적체가 다른 레포를 굶긴다.

## §2 상수 SSOT 를 constants.sh 한 자리로 모은 경위 · 개별 상수의 근거

스크립트가 읽는 상수의 값은 `scripts/lib/constants.sh` 한 자리다(#427). 이 절이 값을 다시
적지 않는 이유: 산문과 코드가 값을 두 벌로 들면 갈린다(`ISSUE_TIMEBOX_HOURS` 는 실제로
4벌이었다). 환경변수로 덮어쓰면 그 값이 이기고, 값의 **근거·이력은 그 파일 주석**에 있다.

- `ISSUE_TIMEBOX_HOURS` — 경과 초과 자체가 중단 사유가 아닌 근거는 #200 이다(§8).
- `STALL_MIN` — 원격 브랜치 `agent/issue-<num>` 의 최신 커밋 신선도로 커밋 쪽 진행 증거를
  재는 값. 판정은 `timebox-check.sh` 한 자리다.
- `MAX_TIMEBOX_GRACE` — 누적 유예 횟수를 **상태 파일이 아니라** 이슈 코멘트 마커
  (`<!-- timebox-grace: N -->`)에서 재파생하는 이유는 이 루프가 로컬 상태 파일을 두지 않기
  때문이다(상태의 SSOT 는 GitHub). 현재 claim 시각 이후 것만 세는 것은 옛 에피소드의
  유예 횟수를 물려받지 않기 위해서다.
- `CONFLICT_RESUME_LIMIT` — 실측(BoDAT #5103 · #185)에서 첫 충돌의 사람 답은 매번 ⓐ(워커 한
  회차 더)였고 두 번째는 ⓑ(사람 인수)였다. 창을 `RESUME_AFTER_MIN` 과 공용으로 둔 것은 그
  창이 곧 사람이 `full-cycle` 로 인수할 시간이기 때문이다(#345).
- `MIRROR_RETRY_LIMIT` — 회차를 짝 이슈 코멘트의 `<!-- mirror-retry: <사유> pr=<n> -->` 마커
  개수로 세되 **그 PR 의 것만**, **사람이 개입한 경계**(마지막 `policy-review`·`hold-note`
  코멘트) **이후**의 것만 세는 이유도 같다 — 옛 에피소드를 물려받지 않는다(#397).
- `STALE_FINISH_MIN` — `finish-classify.sh` 의 버퍼이며 이제 **closeout ①-b 정체 스윕**이
  소비한다(issue-runner 는 규칙4 원복 후 직접 쓰지 않는다). 버퍼가 필요한 근거: 살아있는
  워커는 `검증자 리뷰:` 직후 수초 내 최종 판정을 찍으므로, 최신 검증자가 CLEAN 인데 이 버퍼를
  넘도록 최종 판정이 없으면 워커 사망으로 간주할 수 있다.
- `SOFT_TOKEN_BUDGET_PER_ISSUE` 가 하드 캡이 아닌 이유: Agent 호출에 예산 API 가 없어 강제가
  불가능하다. 그래서 ④ Report 의 관측 기준으로만 둔다.

단계 라벨 `flow:*` 보정이 "조작 금지" 의 예외인 이유: 워커가 각 단계에서 직접 다는 자가설명
라벨이라, 스캔 안전망으로 실제 상태에 맞추는 것은 조작이 아니다.

## §3 `merged` — 이슈가 닫혔다는 뜻이 아니다 · 고아 워커

일부만 착지시킨 PR 은 `Closes` 대신 `Refs` 를 쓰므로 이슈가 OPEN 으로 남고, `release-labels.sh`
가 그 경우 `agent-ready` 를 유지해 다음 틱이 남은 절반을 다시 집는다(#117 — 종전엔 무조건
떼어 조용히 좌초했다).

고아 워커를 먼저 끊는 이유: PR 이 머지됐으니 워커 작업은 무의미하고, 방치하면 이미 종료된
PR 을 붙들고 무한 스핀한다(관측된 고아 유령의 회수 경로).

## §4 lessons 신호 (3) local-ci commit status · 리베이스 사각지대

신호 (3) 이 HEAD 의 `--json statusCheckRollup` 이 아니라 커밋 열거인 이유: rollup 은 컨텍스트당
최신 1개만 남아 **실패 이력을 못 본다**. 도중 실패 후 새 SHA 로 고쳐 최종 SUCCESS 라도 실패
이력이면 교훈 후보다. local-ci 체제 레포는 `gh run list` 가 항상 빈값이라 이 신호가 실질
트리거다.

⚠️ **리베이스는 (3) 을 무력화한다.** closeout 이 conflict 를 rebase 하면 커밋 SHA 가 바뀌고
**리베이스 이전 SHA 는 PR 에서 사라진다**. 커밋 열거로도 타임라인으로도 못 찾는다 —
`head_ref_force_pushed` 이벤트의 `commit_id` 는 push **이후** SHA 만 담고, 이전 `committed`
이벤트는 남지 않는다(2026-08-11 PR#2290·#2276 실측). 커밋 상태는 SHA 에 붙으므로 SHA 를
모르면 조회 자체가 불가능하고, `run-local-ci.sh` 는 코멘트를 남기지 않아 GitHub 어디에도
흔적이 없다. 그래서 **리베이스된 PR 에서 (3) 이 비면 그건 "없음"이 아니라 "미상"이다.**

조용히 '없음'으로 넘기지 말라는 지시의 근거: 유실이 안 보이는 것이 이 사각지대의 성질이고,
그러면 리베이스를 거친 PR 의 교훈은 영구히 학습 경로에서 빠진다.

## §5 lessons 기록 — 한 자리 append · 20줄 캡 · 두 파일 라우팅

`.loop/lessons.md` 경로를 `repo-dir.sh` 출력으로 해석하는 이유: repos.conf 매핑 머신에서도
기록·읽기가 같은 파일을 가리키게 하는 유일한 해석이다.

**append 를 `lessons-trim.sh` 밖에서 손으로 하지 말라**는 근거: 다른 틱이 같은 파일을 동시에
정리 중일 수 있고, 잠금 밖에서 한 append 는 그 정리의 read→write 창에 겹치면 유실된다
(#208 재검증 BLOCKER② — closeout 1·6단계가 같은 호출을 쓰는 이유다).

캡을 "항목 수가 캡 이하가 될 때까지" 로 적은 이유: context rot 방어이고, 옛 산문의 "가장
오래된 줄 하나 삭제" 는 append(+1)·삭제(-1) 순증이 0 이라 한 번 캡을 넘으면 안 줄었다 — 그
결함을 스크립트가 수렴 규칙으로 고친다. 중복 append 를 막는 것도 20줄 캡이 막으려는 희석이
그것이기 때문이다.

라우팅을 두 파일로 가른 근거: `lessons.md` 는 ③-4d 에서 **워커 프롬프트에 그대로 실린다**.
그래서 담기는 것은 "다음 구현자가 같은 코드를 다시 짤 때 쓸 지식" 뿐이다.
`.loop/lessons-verifier.md` 는 verify-runner ③-3 과 closeout 1단계가 **검증자 프롬프트**에
주입한다. 두 파일을 섞으면 양쪽 프롬프트가 서로 무관한 지식으로 희석된다.

## §6 `half_moved_redispatch` 가 생기는 경위

`verify-redispatch` 가 **반쯤 실패한** PR 이다(#394): PR 은 단계 라벨(`flow:*`·`verifying`)을
잃었는데 이슈는 `agent:claimed` 를 유지해 세 게이트(`verify-eligible`·`closeout-eligible`·
`eligible-issues`) **전부에서 빠진다** — verify-runner 가 "다음 틱이 잡게" 라고 넘긴 그 상태의
주체가 여기다(`references/state-machine.md` 회수 열).

멱등 재실행이 안전한 이유: PR 쪽은 이미 이동해 있어 no-op 이고 이슈만 `agent-ready` 로
돌아온다. 이 이벤트가 난 PR 이 ② Maintain 입력이 아닌 이유: `pr_open` 이 안 나온다
(`harvesting` 과 같은 모양). 살아 있는 워커(`progress-evidence.sh` 진행 증거 있음)와 증명
실패는 스크립트가 이미 걸러 이 이벤트를 내지 않는다.

## §7 CI 대기 재개 — 세 상태 토큰 · SendMessage 가 워커를 깨우는 근거

이 박스 CI 큐는 인큐→완료가 550~750초라 반송 회차가 겹치면 claim 경과가 쉽게
`ISSUE_TIMEBOX_HOURS` 를 넘고, 그러면 ⓐ `TaskStop` ⓑ worktree 제거 ⓒ claim 해제가 **막 재개한
워커를 즉시 죽인다.** 그래서 재개에 성공한 이슈는 그 틱에서 거기까지다.

세 상태 토큰의 뜻: `queued N` 은 그 워커의 SHA 가 큐에서 N번째로 줄 서 있는 것, `running` 은
이미 그 잡이 돌고 있는 것, `none` 은 티켓이 회수돼 큐에도 결과도 없는 것이다. `running` 에는
대기열 번호가 아예 없다 — 옛 고정 문형 `대기열 N번째` 로는 쓸 말이 없어 워커가 조용히
끝냈고, 그게 이 갈래가 막으려던 바로 그 사망 오독이었다. `none` 이어도 워커는 살아 있다 —
회수된 것은 티켓이지 워커가 아니고, 깨우면 같은 SHA 로 1회 재큐해 이어간다. 세 값은 워커가
지어낸 말이 아니라 `ci-queue.sh status <SHA>` 의 출력 그대로다(`running` / `queued <n>` /
`none`).

**근거 — 턴이 끝난 백그라운드 서브에이전트도 `SendMessage` 로 깨어난다.** ⑴ Agent 툴 계약문이
`SendMessage` 를 "continue a previously spawned agent with its context intact" 로 규정한다
(스폰이 끝난 뒤를 전제한 문장이다). ⑵ 백그라운드 태스크의 완료 알림(task-notification) note
도 "The user can send it another message and resume it, so the same task-id may notify more
than once" 라고 못박는다 — **완료 알림은 "턴이 끝났다"이지 "태스크가 소멸했다"가 아니다.**
⑶ 운영 실측: 2026-09-10~11 하루에 5건(bodat #4959·#4927·#4957·#4971 · runner #188)을 이
경로로 깨워 **전부 재개돼 작업을 마쳤다**(같은 task-id 로 완료 알림이 두 번 왔다).

폴백에서 claim 을 풀지 않고 기존 worktree·브랜치를 재사용하는 이유: `make-worktree.sh` 가
기존 트리를 `exists:` 로 재사용하고, push 된 커밋이 자산이다.

timebox 유예 마커 코멘트를 건너뛰고 최신 코멘트를 읽는 이유: 마커가 최신 코멘트 자리를
차지하면 워커가 남긴 `BLOCKED:` 가 가려져 needs-human 승격 대신 조용한 claim 해제로
샌다(#200).

기계 정지가 사유 라벨 하나만 붙이는 것은 #244 다. 게이트가 `hold:` 접두를 보므로 사유 라벨이
남아 있으면 후보로 안 돌아온다(#242) — 재심이 "사람 몫 유지" 로 끝나 `needs-human` 까지 붙은
건은 그것도 함께 떼야 다시 흐른다(README 「가드레일」 규약).

## §8 timebox — 판정 입력이 경과가 아니라 진행 증거인 이유 · 잔여물 폐기의 대가

#200: 경과에는 워커가 통제할 수 없는 박스 전역 직렬 CI 큐 대기가 통째로 들어가, 실측 2건에서
진행 중인 워커를 죽일 뻔했다. 그래서 판정 입력은 경과 시간이 아니라 진행 증거다.

`unknown`(exit 2) 에서 중단하지 않는 이유: 조회 실패로 살아있는 워커를 죽이면 미push 잔여물이
되돌릴 수 없이 폐기되지만, 유예는 다음 틱이 되돌릴 수 있다.

`grace` 판정 줄을 warn 이 아니라 정보 줄로 옮기는 이유: 무한 유예가 눈에 보이게 하기
위해서다.

`stop` 의 ⓑ 에서 미push 잔여물을 폐기하는 것은 판정의 **대가로 의도한 것**이다 — 남겨두면
다음 디스패치의 make-worktree 가 중단된 워커의 중간 상태를 그대로 물려줘 worktree 격리가
깨진다. dirty-warn 보류 규율은 원인 불명의 잔여물용이므로 이 의도적 중단에는 적용하지 않는다.
ⓐ 에서 push 된 커밋은 원격 브랜치에 보존되고, ⓓ 뒤에는 `agent-ready` 가 남아 있으므로 다음
틱이 원격 브랜치 위 새 worktree 에서 재디스패치한다.

## §9 재개 스윕 — `hold:conflict` 가 자동 재개 대상인 이유 · `full-cycle` 예외

`hold:ladder` 는 실측 사다리 ①~③ 칸이 전부 실패해 멈춘 건이다. `hold:conflict` 는 closeout ③
이 머지 충돌로 멈춘 건인데, #344 가 보안 경계·대범위 충돌은 `policy` 로 보내므로 이 라벨은
"루프가 1회 재개해도 되는 건" 이다(#345). `hold:policy` 만 사람 결정으로 남고 재심(③) 1회를
거친다. 사람이 직접 세운 정지(`needs-human`)가 함께 붙어 있으면 자동 재개 대상이 아니다
(#244). `full-cycle` 이 붙은 `hold:conflict` 는 사람이 인수(ⓑ)한 것이라 절대 재개하지 않는다
(BoDAT #5103 2차 형상).

재개 횟수를 이슈 **코멘트** 마커로 세는 이유: 본문은 읽지도 쓰지도 않는다(append-only 라 남의
편집을 덮어쓸 일이 없다).

정지 라벨이 이슈와 연결된 열린 PR **양쪽**에 미러돼 있으므로 재개·승격이 PR 라벨까지 함께
되돌려야 하는 근거: 안 그러면 PR 이 영구 needs-human 으로 남고 뒤 전이(handoff-verify·
verify-pass·closeout-pick)가 그걸 안 뗀다. 재개가 이슈 칸에 맞는 미러를 되붙이는 이유(#420):
정지 전이가 PR 의 단계 라벨을 이미 뗀 뒤라, 안 붙이면 그 PR 은 다음 claim 까지
무라벨이다(#281 불변식 위반).

## §10 정지 미러 정리 — 떼는 조건이 부재가 아니라 양성 증거인 이유

되돌림은 스윕이 **스스로 재개·승격할 때**뿐이라, 사람이 `hold:policy`(또는 상한을 넘긴 홀드)를
푸는 경로엔 PR 사본을 지우는 자리가 없었다 — 그래서 같은 실행이 정지 미러 정리(#265)도 한다.

**떼는 조건은 부재가 아니라 양성 증거다** — 부재("이슈에 정지 라벨이 없다")는 ⓐ 사람이 뗐다
ⓑ 기계가 뗐다 ⓒ **전이가 부분 실패해 애초에 못 붙었다** 를 구분하지 못하고, ⓒ 는 실재한다
(`transition.sh` 는 PR 을 먼저·이슈를 나중에 편집한다). 그래서 라벨 **이벤트 이력**으로 이슈의
마지막 해제가 PR 의 마지막 부착보다 **늦은** 것을 확인하고, 못 하면 떼지 않고 warn 을 낸다.

PR 정지가 맨몸 `needs-human`(= `hold:` 접두 0개)뿐이면 절대 떼지 않는 근거: 기계는 그 모양을
못 만들므로(세 홀드 전이는 `--reason` 필수) 사람이 손으로 세운 브레이크다.

짝의 정의를 좁힌 이유: head 가 `agent/issue-*` 이고 `Closes` 링크가 증명된 PR 만 봐야 사람이
연 PR 의 표식과 `Refs` 전용 PR 의 정상 홀드를 안 건드린다.

`mirror_retry_exhausted` 에서 스크립트가 라벨을 한 번도 건드리지 않은 이유: 증거 없이 사람
게이트를 벗기지 않는 게 그 갈래의 규율이다(#397). 전이가 성사되면 이슈에 정지 라벨이 생겨 그
PR 은 다음 틱부터 미러 정리 대상에서 빠진다(자연 종료). 전이가 비0이어도 마커를 더 쌓지
않으므로 회차가 부풀지 않는다.

`resumed` 에서 디스패처가 따로 할 일이 없는 이유: 이번 틱 ③ 의 `eligible-issues.sh` 후보로
자연히 다시 나타난다. 배포 대기 라벨(`deploy-wait`)이 붙은 이슈에 이 이벤트가 안 나오는 것은
#217 이다.

`escalated` 의 PR 축(`number` 가 `null`, #345 반송)이 `attempt`/`limit` `0/0` 인 이유: 재개할
워커를 태울 이슈가 없어(#421 과 같은 사실) 스윕이 창 뒤 곧장 `hold:policy` 로 승격했다
(재개 0회·상한 0). 다음 창이 지나면 같은 스윕의 PR 단독 재심이 `policy_review_due`(`pr` 축)로
낸다.

`warn` 의 목록/탐색 상한 도달은 `--limit 200` 에 닿아 잘린 이슈가 이번 틱엔 안 보인다는 뜻이며,
반복되면 `.loop/repos` 로 스코프를 좁히라는 신호다(`repo` 가 `*` 면 계정 전체 탐색 쪽).
`note` 채널의 건들이 **정상 상태**인 근거: 사유 라벨 없는 `needs-human` 은 사람이 직접 세운
정지라 정상이고(#244), 배포 대기 이슈의 `hold:ladder` 는 창이 지나도 재개·승격 대상이
아니며(#217), 사람이 인수(`full-cycle`)했거나 `needs-human` 을 세운 `hold:conflict` 도
같다(#345).

`warn_after_edit` 을 되돌리지 않는 이유: 재개/승격 자체는 일어났을 수 있고, 다음 틱의
loop-status 가 실제 라벨 상태를 보여 준다.

## §11 `policy_review_due` — 순서가 계약인 이유

**순서가 계약이다**(#244): 마커가 곧 "재심 끝" 이라, 마커를 먼저 올리면 전이가 죽어도 다음
틱부터 `reviewed` 로 접혀 `needs-human` 은 영영 안 붙고 그 건은 `hold:policy` 만 남은 채
**아무도 다시 묻지 않는다**(사람 결정이 needs-human 칸에 영영 안 뜨는 봉인).

전이가 비0일 때 마커를 올리지 않으면 다음 스윕이 같은 건을 `policy_review_due` 로 다시 낸다.
`policy-kept` 는 붙이기만 하는 멱등 전이라 재호출이 곧 복구다.

루프가 `needs-human` 을 붙이는 유일한 자리가 `policy-kept` 인 것은 #244 다 — 기계 정지에서 그
라벨을 뗀 뒤 남는 유일한 생산자다. `hold:policy` 는 사유로 남는다.

## §12 PR 단독 홀드가 언제나 "사람 몫 유지" 로 끝나는 이유

#395 → #421. 답이 플랜에서 나오더라도 재개하지 않는 근거는 둘이다. ⑴ verify-runner ④ 가
"연결 이슈 부재" 를 **사람 칸**으로 못박았다 — 어느 이슈에 붙일지가 사람 결정이다.
⑵ 이 축에는 재개가 **소비자 없는 상태**다: `verify-redispatch` 를 `<issue>` 자리 `-` 로 부르면
PR 에 `flow:agent-ready` 만 남는데 `eligible-issues.sh` 는 **이슈**만 디스패치하고
`verify-eligible.sh` 는 `flow:verify`·`verifying` 를 요구한다 — 아무 레인도 그 PR 을 집지 않아
영구 미아가 된다.

연결 이슈가 **열려 있는** PR 에서 이 이벤트가 안 나는 것은 그 건을 이슈 축이 이미 냈기
때문이다(중복 금지).

## §13 ② Maintain — 규칙0 위임 · 건너뛰는 레인 · 보수 이관의 역할 분리

규칙0 이 판정→라벨 매핑을 `pr-state.sh` 에 위임한 경위(#449): 산문이 매핑을 다시 들면
`references/state-machine.md` 표와 두 벌이 되고, 그 차이는 라벨이 어긋난 뒤에야 보인다(#281
미러가 갈리는 자리).

`flow:verify`·`verifying`·`harvesting`·`flow:claimed`·`flow:agent-ready` PR 을 건너뛰는
근거(#275·#420): 각각 verify-runner·closeout·워커 레인 소유라 `🔄` 만 보고 올리면 살아있는
워커의 PR 을 뺏는다. 최초 CI·구현 단계가 PR 없이 이슈 `agent:claimed` 로만 보이는 것은
`flow:ci` 가 재-CI 도는 PR 에만 뜨기 때문이다.

서킷 브레이커에서 회차를 `0` 으로 읽으면 안 되는 이유: 상한이 리셋된다(#444).

conflict rebase 소유가 closeout 으로 이관된 것(② 3)과 완결 유실 회수가 closeout ①-b 소유인
것(② 4)은 같은 역할 분리다 — 완결 로직을 이 루프에 얹지 않고 마감 담당(closeout)에
일원화한다. 그래도 conflict PR 을 in-flight 로 계속 세는 것은 미완이라 ③ 배압을 유지하기
위해서다. 규칙4 에서 단계 라벨 `flow:*` 보정만 남긴 것은 PR 리스트 자가설명·closeout 스윕
보조신호를 남기기 위해서다.

verify-runner 가 결정적 CI 실패조차 반송으로 처리하므로 issue-runner 는 `flow:verify` PR 의
CI 도 손대지 않는다(사각지대 방지). 반송되면 이 루프의 Dispatch 가 같은 브랜치서 워커를 다시
붙인다 — 정상 재디스패치다.

## §14 ③ Dispatch — 슬롯 계산 · claim 잠금 · 사전 리뷰 · 마커 계수

**슬롯**: CI green + 코멘트 없음 PR 이 슬롯을 점유하지 않는 이유는 에이전트가 손댈 일이 없는
휴면 상태라 새 일을 막을 까닭이 없어서다. `flow:verify`·`verifying` PR 을 in-flight 에서 뺀
것이 검증을 별도 레인으로 뺀 throughput 이득의 실체다: 워커가 PR 을 열고 `flow:verify` 로
넘기는 즉시 슬롯이 반납돼, 느린 E2E·codex 대기가 더 이상 이 루프의 슬롯을 붙잡지 않는다.
적체 배압을 레포별로 판정하는 근거는 §1 의 #362 다(합산 캡은 한 레포의 적체가 다른 레포
대기열을 굶겼다).

**claim 잠금**: `claim-issue.sh` 가 라벨을 붙이기 전에 create-only 잠금 ref 를 먼저 잡는 이유 —
라벨 부착은 멱등이라 그 자체로는 잠금이 못 된다(#108). 두 루프 세션이 같은 이슈를 동시에
노려도 정확히 하나만 통과한다. 인수 ref 가 자식 경로가 아니라 `<앵커>-takeover` 형제 이름인
것은 자식 경로가 git ref D/F 충돌로 불가능하기 때문이고, 그 경합도 하나만 통과하므로 스테일
인수 경로에서 원자성이 깨지지 않는다.

**시크릿 심링크**가 기본 off 인 것은 #109 다. 안 켠 레포의 credential 의존 테스트를 실패가
아니라 skip 으로 보고하는 이유도 같다.

**워커는 더 이상 codex 검증자를 스폰하지 않는다** — 검증은 verify-runner 소유라
`<VERIFIER>` placeholder 가 필요 없다. VERIFIER 상수는 ① Reconcile 의 교훈 추출에만 쓰인다.
대신 워커가 PR 을 열기 전에 자기 검토용 사전 리뷰어(general-purpose) 1회를 중첩
스폰한다(템플릿 9-b — 비게이트·fail-open·1라운드, 결과는 PR 본문 `## 사전 리뷰`). 디스패처가
할 일이 없는 이유: 워커가 `TaskOutput` 블로킹으로 리뷰어를 기다리므로 스트림은 그 동안만 +1
이고 `MAX_AGENTS` 는 그대로다. 효과는 verify-runner 반송(`재검증 실패:`) 건수 / 실제 리뷰가
돈(CLEAN·발견) 비율로 잰다.

**마커 계수**: 인용을 세지 않는 이유 — 백틱 인라인 코드·코드펜스 안의 마커는 신호가 아니라
신호를 *설명하는 글*이다. `resume-sweep.sh` 의 `JQ_UNQUOTE` 와 같은 정의를 쓰는 이유: 두 곳이
갈라지면 사람 눈에 안 보이는 두 번째 계산기가 다른 수를 센다(#197). 조회도 같은 자리다(#397):
`gh issue view --json comments` 는 첫 100건만 줘서 코멘트가 많은 이슈에선 스윕(페이지네이션)과
이 자리가 다른 수를 센다 — `pr-comments.sh` 로 전량을 읽는다(출력이 `{comments:[…]}` 가
아니라 배열이라 `.[]` 다). 본문에는 마커가 없다 — 스윕은 본문을 건드리지 않는다.

사다리 실패 출력을 물려줄 때 `재개 N/…` 코멘트를 제외하는 이유: 그게 시간상 마지막이라 안
거르면 실패 출력 대신 그 줄을 물려준다.

충돌 재개 갈래(#345)에서 인라인하는 노트는 closeout ③ 이 `--reason conflict --note` 로 남긴
"워커 재개 범위" 한 줄이다(#344). 워커 템플릿 10단계의 재디스패치 감지가 이 회차를 "이슈의
`사람 확인(conflict):` 가 PR 의 마지막 `재검증 실패:` 보다 **나중**(없음 포함)" 으로 알아보고,
인라인된 지시를 반송 갈래보다 우선한다.

## §15 ④ Report · 참고 자료의 배경

항목마다 번호를 적는 이유: 숫자만으론 어느 이슈·PR 이 어디로 갔는지 다음 틱이 못 읽는다.
검색 창 `warn:` 을 그대로 옮기는 이유: 창이 차면 **가장 새 이슈부터** 후보 목록에서 조용히
사라지므로, 그 신호가 사라지면 큐가 죽어도 안 보인다. `막힘 N` 도 카운트로 세는 이유: 막힌
건이 있으면 조용한 틱이 아니다 — 그 침묵이 이 항목을 만든 이유다. 조용한 틱에도 eligible
스캔을 거르지 않는 이유: 새 agent-ready 이슈는 reconcile 이벤트를 만들지 않으므로 스캔을
거르면 절전 모드가 신규 후보에 영구히 맹목이 된다(빈 큐에서는 search/issues 1콜이라 비용
무시 가능).

설치 모델이 사용자 레벨 전역 설치 + 라벨 옵트인인 이유: 계정 전체 디스패처이기 때문이다
(README §설치). 병행 운용의 `.loop/repos` 허용목록은 프로젝트별 루프 세션 분리용이며 스크립트가
자동 적용하므로 틱에서 따로 할 일은 없다(README §사용법). codegraph 병용을 권하는 이유:
레포에 `.codegraph/` 인덱스가 있으면 워커가 반복 grep/Read 대신 인덱스 조회로 탐색해 토큰·
툴콜을 줄인다(레포별 `codegraph init` 옵트인 — 없어도 루프는 동작한다).

**설계에 참고한 문헌**: [Claude Code goal 공식 문서](https://code.claude.com/docs/en/goal) ·
[루프 엔지니어링 담론 (YouTube)](https://www.youtube.com/watch?v=EH2MMQTaPEA) ·
[Reddit 토론](https://www.reddit.com/r/myclaw/comments/1u047p8/so_is_loop_engineering_the_next_ai_dev_buzzword/) ·
[agent loop internals 분석](https://internals.laxmena.com/p/why-claude-codes-agent-loop-is-over) ·
[Rails 8.1 release notes — `bin/ci` 원형](https://guides.rubyonrails.org/8_1_release_notes.html)
