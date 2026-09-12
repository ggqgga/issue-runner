# PR 소유권 상태기계 — 누가 이 PR 을 들고 있고, 누가 다음으로 옮기는가

이 표가 SSOT 다(#393, 플랜 `Plans/loop-restructure.md` 0단계). 세 루프의 SKILL 은 "소유 라벨 불가침" ·
"기계 정지/사람 정지" · "전이 실패 시 처리" 를 산문으로 다시 쓰지 않고 이 파일을 가리킨다. 라벨 이동의
기계적 정의는 `scripts/transition.sh` 상단 전이 표, 대시보드 버킷은 `scripts/loop-status.sh` 상단 주석 —
둘 다 이 표와 1:1 이어야 하며, 어긋나면 **이 표를 고치기 전에 그쪽이 틀린 것인지 먼저 본다**(행동 불변).

## 읽는 법

- **상태** = PR 라벨 집합 + 연결 이슈 라벨 집합 + PR 의 마지막 `머지 판정:` 코멘트. 세 축이 함께 상태다.
- **소유** = 이 상태의 PR 을 건드려도 되는 유일한 루프. 소유가 아닌 루프는 읽기만 한다.
- **게이트** = 그 루프가 이 상태를 **집는** 결정론 스크립트. 게이트가 내지 않으면 그 루프도 안 집는다.
- **진입** = 이 상태로 들어오는 전이(`transition.sh` 동사). **출구** = 나가는 전이. 전이는 PR 과 이슈를 한 호출로
  같이 옮긴다 — exit 1(readback 불일치)·2(gh 실패)면 **반쯤 이동**한 상태가 남고, 그때 누가 되돌리는지가 "회수" 열이다.
- **회수** = 소유 루프가 죽었거나 전이가 반쯤 실패했을 때 그 상태를 다시 정상 궤도로 올리는 주체. `—` 는 회수가
  필요 없는 상태(사람이 푼다 또는 종료). **이 표에 미정 칸은 없다** — 넷 다 주체가 배정됐다(#394·#395·#396·#397).
  새 상태를 추가할 때 회수 주체를 못 적겠으면 그 자리에 `미정(#<leaf>)` 를 적고 leaf 이슈를 발행하라(그게 이 넷이
  거쳐 온 절차다).

## 정상 사다리

| # | 상태 (PR / 이슈 / 마지막 판정) | 소유 | 진입 전이 | 게이트 | 정상 출구 | 회수 |
|---|---|---|---|---|---|---|
| S0 | (없음 · 반송 뒤면 `flow:agent-ready`) / `agent-ready` / — | issue-runner ③ Dispatch | (사람·loop-issues·closeout 파생 발행) | `eligible-issues.sh`: open + agent-ready + ¬agent:claimed + ¬needs-human + ¬hold:* + 블로커 전부 CLOSED. 정렬 P0 먼저 · 나머지 생성순(#401) | `claim-issue.sh`(create-only ref 잠금) → S1 | — |
| S1 | `flow:claimed`(+`flow:ci`·`flow:codex`) / `agent:claimed` / (없음 또는 `🔄`) | 워커(issue-runner ① Reconcile 이 감시) | claim-issue | `reconcile.sh`(working/stale) · `timebox-check.sh` → `progress-evidence.sh`(커밋 `STALL_MIN` 이내 · head SHA 의 CI 티켓 살아 있음) | `handoff-verify` → S2 · 워커 사망 → `runner-held`/재디스패치(S0) | issue-runner ① — 진행 증거 없으면 재디스패치. 반쯤 이동한 `verify-redispatch`(PR 단계 라벨 0 + 마지막 판정이 `재검증 실패`)도 여기서 `half_moved_redispatch` 로 회수한다(#394) |
| S2 | `flow:verify` / `flow:verify` / `🔄` | verify-runner | `handoff-verify`(worker-template 최종 단계) | `verify-eligible.sh`: open + head `agent/issue-*` + flow:verify ∪ verifying + ¬harvesting + ¬needs-human + ¬hold:*. `verifying` 고아 먼저, 그다음 FIFO. `ci` 필드(pass·revalidate·fail) | `verify-pick` → S3 | verify-runner 자신(FIFO 로 다시 집는다) |
| S3 | `verifying` / `verifying` / `🔄` | verify-runner ③ Verify(지금 검증 중) | `verify-pick` | `verify-eligible.sh` 가 `orphan:true` 로 **먼저** 낸다 — 틱 시작에 남은 `verifying` 은 정의상 이전 틱의 사망 | `verify-pass` → S4 · `verify-redispatch` → S0(반송 마커 `재검증 실패:`) · `verify-held` → H · `verify-unpick`(flake) → S2 | verify-runner ②(고아 재집) |
| S4 | `flow:ready` / `flow:ready` / `✅`(head 이후·`코멘트 스냅샷 N`) | closeout | `verify-pass` | `closeout-eligible.sh`: `✅` 마지막 인덱스 + `finish-classify.sh`=done_verdict(✅ 가 head 커밋 이후임을 증명) + `bounce-state.sh`=ok + 스냅샷 경계 이후 무마커 코멘트 0 + `closeout-ci-pass.sh` + MERGEABLE + ¬harvesting·¬verifying·¬flow:verify·¬needs-human·¬hold:* | `closeout-pick` → S5 | closeout ①-b 스윕(아래 계급 표) |
| S5 | `harvesting` / `harvesting` / `✅` | closeout ③ 파이프라인 | `closeout-pick` | `closeout-reconcile.sh`: 크래시 재개(resume) / `human_hold`(needs-human 붙었거나 라벨 미상) · 1단계 재개 지점은 `closeout-step1-marker.sh` | 머지(Closes → 이슈 닫힘) → E · `closeout-dup` → E · `closeout-blocked` → H · `closeout-redispatch` → S0(반송 마커 `재디스패치:`) | closeout ①(크래시 재개) |
| E | 종료 — 머지됨 / CLOSED, 또는 `dup` / CLOSED | — | 머지 · `closeout-dup`(`release-labels.sh` 가 닫힌 이슈의 agent-ready 회수) | — | 배포 대기 이슈(`deploy-wait`) → deploy-cycle 레인(루프 밖) → 배포 뒤 검증 항목이 남으면 `테스트` 이슈(e2e-test 레인, 사용자 호출) | — |

`agent-ready` 는 사다리 전체에서 유지되는 **자격** 라벨이다 — 위 표의 어느 remove 칸에도 없고, 반송 두 전이만
다시 add 한다. `flow:ci`·`flow:codex` 는 PR 에만 있는 워커 내부 단계라 이슈 미러가 없다. 반대로 `flow:claimed`·
`flow:agent-ready` 는 이슈 칸(`agent:claimed`·`agent-ready`)의 **PR 쪽 미러**다(#281) — 열린 agent PR 이 어느 칸에도
안 보이는 창을 없앤다. `claim-issue.sh` 가 열린 PR 에 `flow:claimed` 를, 반송 두 전이가 `flow:agent-ready` 를 붙이고,
`handoff-verify`·`verify-pick`·`closeout-pick`·`closeout-dup` 이 둘을 뗀다(`transition.sh` `WORKER_MIRROR`).
`resume-sweep.sh` 의 자동 재개(H:ladder → S0)도 `hold:ladder` 를 떼는 그 편집에서 이슈 칸에 맞는 미러
(`agent:claimed` 면 `flow:claimed`, 아니면 `flow:agent-ready`)를 되붙이고(PR 에 칸 라벨이 이미 있으면 겹치지
않는다), issue-runner ② Maintain 규칙0 은 두 미러가 붙은 PR 을 건너뛴다(#420) — 둘 다 워커 레인 소유 칸이라
`🔄` 만 보고 `flow:verify` 로 올리지 않는다. 대시보드(`loop-status.sh` `pr_stage_labels`)는 두 미러를 단계로
세지 않는다(#281 결정 5 유지 — PR 의 단계는 이슈 칸이 말하고, 미러 없는 PR 은 무소속 warn 으로 드러난다).

## 정지와 반송

| # | 상태 | 소유 | 진입 | 풀리는 길 | 회수 |
|---|---|---|---|---|---|
| H:ladder | `hold:ladder` (PR·이슈 양쪽) | 기계 정지 — resume-sweep | `verify-held --reason ladder` · `closeout-blocked --reason ladder` | 창(`RESUME_AFTER_MIN`) 뒤 `resume-sweep.sh` 가 자동 재개(`LADDER_RESUME_LIMIT` 회) | resume-sweep |
| H:policy | `hold:policy` + `<!-- hold-note: policy -->` 질문 코멘트 | 기계 정지 — 재심 1회는 issue-runner ①(#155) | `*-held/blocked --reason policy` · `runner-held` | 재심이 풀면 반송(S0) · "사람 몫 유지" 면 `policy-kept` → H:human | resume-sweep 이 `policy_review_due` 를 **두 축**으로 낸다(#395): 이슈 축(`pr:null`) · 열린 연결 이슈가 없는 PR 은 PR 축(`number:null`, 전이 인자는 `<repo> - <pr>`). **PR 축은 재개가 없다** — 반송해도 그 상태를 집는 레인이 없어 언제나 `policy-kept` → H:human 으로만 끝난다(#421) |
| H:conflict | `hold:conflict` + `<!-- hold-note: conflict -->` 워커 재개 범위 코멘트(#344) | 기계 정지 — resume-sweep(#345) | `*-held/blocked --reason conflict`(보안 경계·대범위는 #344 가 `policy` 로 보낸다) | 창(`RESUME_AFTER_MIN`) 뒤 `resume-sweep.sh` 가 자동 재개(`CONFLICT_RESUME_LIMIT`=1 회 — ⓐ 워커 한 회차 더: 재개 워커가 홀드 노트를 받아 rebase) · 사람이 `full-cycle` 로 인수(ⓑ)했으면 재개하지 않는다 · 상한 초과면 `hold:policy` 승격 → H:policy | resume-sweep |
| H:human | `needs-human` | 사람 | `policy-kept` 만 루프가 붙인다 — 그 외는 사람이 직접 | 사람이 뗀다 | — (세 게이트 전부 제외) |
| B | 반송 마커(`재검증 실패:` · `재디스패치:`)가 마지막 판정보다 뒤 · PR `flow:agent-ready` / 이슈 `agent-ready` | 워커 레인 (S0 과 같다) | `verify-redispatch` · `closeout-redispatch` — 둘 다 `needs-human`·`hold:*` 를 뗀다(반송 = 사람 대기 해제) | 새 워커가 같은 브랜치에서 고쳐 `handoff-verify` → 새 `✅` | `bounce-state.sh`(마커 인덱스가 판정 뒤면 `bounced` — closeout-eligible 이 옛 ✅ 로 집지 않는다) |

## closeout ①-b 스윕이 회수하는 계급 (`finish-classify.sh` × `bounce-state.sh`)

| 계급 | 형상 | 처리 |
|---|---|---|
| `done_verdict` | 최신 `✅` 가 head 커밋 이후임이 증명됨 | S4 정상 경로(closeout-eligible)가 처리 — 스윕 skip |
| `stale_inline` | `🔄` + 검증자 CLEAN + `STALE_FINISH_MIN` 초과 + 진행 증거 없음 | 입양(② Pick 후보) — 1단계 독립 재검증 후 마감 |
| `stale_reverify` | `🔄` + 검증자 부재/미해결 BLOCKER + 초과 + 진행 증거 없음 | `closeout-redispatch` → S0 |
| `no_verdict` | `머지 판정:` 코멘트 **0건** + CI 초록(실패 0 **이고 미완료 0** — #421) + 초과(기준 시각 = claim·head 중 최신) + 진행 증거 없음 — 워커가 판정 전에 죽었다(#396) | `closeout-redispatch` → S0(`stale_reverify` 와 같은 조치 · 연결 이슈 없으면 무접촉) |
| `held` | 최신 판정 `⚠ 보류` | `closeout-blocked --reason policy` → H:policy |
| `active` | 진행 중 · 버퍼 미도달 · ✅ 신선도 미증명 · 진행 증거 있음 | 무접촉 |
| `bounced`(bounce-state) | 반송 마커 뒤 판정 없음/`🔄` | 재디스패치 재시도 지점에서 재개(교체 워커 사망 판정은 finish-classify) |

## 한때 주체가 없던 칸 — 배정된 회수 주체 (#392)

넷 다 "어느 게이트에도 안 걸려 사람이 눈으로 찾아야 하던" 칸이었다. 지금은 각자 주체가 있고, 그 주체는
**형상을 판별하는 결정론 스크립트 + 전이를 거는 SKILL** 한 쌍이다(스크립트는 판정하지 않고 이벤트/계급만 낸다).

| 형상 | 회수 주체 | 배선 |
|---|---|---|
| `verify-redispatch` exit 1·2 — PR 은 `flow:verify`/`verifying` 상실, 이슈는 `agent:claimed` 유지 | **issue-runner ① Reconcile**(#394) | `reconcile.sh` 가 세 술어(단계 라벨 0 · 마지막 판정성 코멘트가 `재검증 실패` · 진행 증거 없음)로 판별해 `half_moved_redispatch` 를 내고, SKILL ① 이 같은 전이를 **멱등 재실행**한다(증명 실패는 종전 `pr_open`) |
| 열린 연결 이슈가 없는 PR 의 `hold:policy` | **issue-runner ① 재심 → 사람**(#395·#421) | `resume-sweep.sh` ③-b 가 열린 PR 축에서 같은 판정(창·hold-note 마커·needs-human)을 돌려 `policy_review_due`(`pr` 필드)를 낸다. 처분은 `policy-kept` 하나 — 재개(`verify-redispatch <repo> - <pr>`)는 소비자가 없다(이슈 디스패치는 `eligible-issues.sh`, 검증은 `flow:verify`·`verifying`). 연결 이슈가 **열려 있는** PR 은 이슈 축만(중복 금지) · 참조가 전부 닫힌 PR 은 이슈 축이 못 보므로 PR 축이 본다 |
| `머지 판정` 코멘트가 0건인 초록 PR(handoff 전 사망) | **closeout ①-b 스윕**(#396) | `finish-classify.sh` 의 계급 `no_verdict` → 위 계급 표의 재디스패치 행. 코멘트 조회 실패도, **아직 도는 체크**(CI 큐 대기)도 이 계급이 아니다(`active`) |
| resume-sweep 미러 정리 "양성 증거 못 얻음" warn | **resume-sweep 재시도 + 사람**(#397) | 증거 부재 세 갈래가 `<!-- mirror-retry: <사유> pr=<n> -->` 마커로 회차를 센다(그 PR 의 것만 · 마지막 `policy-review`·`hold-note` 경계 이후만 · `MIRROR_RETRY_LIMIT` 기본 3) — warn 에 `N/3` 을 싣는다. 상한에 닿으면 `mirror_retry_exhausted` → SKILL 이 `runner-held --reason policy` 로 사람 몫(H:policy) |

알고 두는 정체(사용자 선택, closeout SKILL ①-b 참조): ⑴ 반송 마커 최신 + 단계 라벨 0 + CONFLICTING + 교체 워커
사망 — ①-b CONFLICTING 예외 갈래가 부분 회수 ⑵ `held` 해제 창(사람이 라벨 뗀 뒤 교체 워커가 🔄 찍기 전)
⑶ 코멘트 게시 + 라벨 전이 이중 실패 뒤 옛 `마감 검증: ✅` 생존 — 2단계 게이트가 재판정.

## 전이 실패의 공통 규칙 (세 SKILL 이 각자 14회 재진술하던 것)

`transition.sh` 가 exit 1(readback 불일치)·2(gh 실패)·64(usage)로 끝나면 **이 PR 의 종료 상태를 바꾸지 말고**
④ Report 에 `BLOCKED: 전이 실패 <전이> PR #<pr>(<repo_short>) — <stderr 한 줄>` 로 올린다. 라벨이 반쯤 이동한 상태를
다음 틱이 잡게 하는 것이 목적이다(조용히 넘어가지 않는다). 그 "다음 틱" 의 주체는 위 표의 회수 열이다 — 그 열이
비어 있으면 "다음 틱" 은 사람이라는 뜻이니, 새 상태를 만들 때 회수 주체를 함께 적어라(#392 가 그 넷을 메웠다).

`--note` 가 붙는 정지 전이(`verify-held`·`closeout-blocked`·`runner-held`)는 질문 코멘트 → 라벨 편집 → readback
순이라(#157) 코멘트 단계 실패는 exit 2 로 끝나고 상태는 전이 이전 그대로다 — 다음 틱에 같은 전이를 다시 걸면 그게
재시도다.

## 게이트 세 개가 공유하는 제외 집합

| 라벨 | eligible-issues(S0) | verify-eligible(S2·S3) | closeout-eligible(S4) |
|---|---|---|---|
| `needs-human` | 제외 | 제외 | 제외 |
| `hold:*`(접두) | 제외 | 제외 | 제외 |
| `harvesting` | 제외(진행 라벨) | 제외 | 제외(이미 집음) |
| `verifying` | 제외(진행 라벨) | **고아로 먼저 집음** | 제외 |
| `flow:verify` | 제외 | 집음(FIFO) | 제외 |
| `flow:ready` | 제외 | — | 집음(✅ 등 위 조건) |
| `agent:claimed` | 제외 | — | — |

이 집합은 `scripts/tests/hold-gate.test.sh` 가 네 SUT(eligible-issues·claim-issue·closeout-eligible·verify-eligible)를
전수 대조해 고정한다. 새 정지 라벨은 `hold:` 접두를 쓰면 세 게이트에 자동으로 걸린다.
