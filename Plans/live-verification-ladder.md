# 검증 사다리 — 루프가 "실측 필요" 앞에서 멈추지 않게

> 상태: 플랜(2026-09-09). 후속 이슈로 분해해 구현한다. 배경 실측은 #144 논의.

## 문제

루프(issue-runner · verify-runner · closeout · deploy-cycle)가 실측·라이브 검증이 필요하면 **시도 없이 멈춘다.**
사람이 멈춘 건을 찾아 "왜 안 해? 진행해" 라고 쳐야 그제야 움직인다. 실측(2026-09-09):

- 오늘 닫힌 배포 대기 이슈 12건 중 실장비 항목이 있던 2건(#4821 · #4819)은 "이월 · 배포 후 검증" 문구만 남기고 닫혔다. TEST 워커 실테스트 흔적 0.
- `needs-human` 은 사유가 기계적으로 남지 않는 쓰레기통이다 — #4772 는 코멘트 0, #4803 은 closeout 이 "이미 main 에 고쳐진 중복" 이라 판정해 놓고도 닫지 않고 사람에게 던졌다.
- 미니의 루프 세션엔 worker-ssh · worker-recipe-test 스킬이 없다. 그런데 미니에서 `ssh test` 는 DESKTOP-O3BOREC 에 바로 닿는다. **통로는 있는데 루프가 모른다.**
- 스킬 문구가 도망갈 길을 연다: worker-template "라이브 항목은 정직하게 `[ ]`", deploy-cycle ④ "실장비 필요 → ⑦ 로 이월하거나 배포 후 검증으로 표기", ⑦ "필요할 때만". **면제 조건은 있고 시도 의무는 없다.**

## 원칙

1. **실측 필요는 멈출 이유가 아니라 다음 할 일이다.** 사다리를 끝까지 올라 실패한 출력을 인용해야만 멈출 수 있다.
2. **`needs-human` 은 사람 결정이 진짜 필요한 것에만.** 사유는 라벨로 남긴다(코멘트가 아니라 — 목록 조회 한 번에 보여야 loop-status 가 추가 호출 없이 센다).
3. **루프가 결정할 수 있는 것은 루프가 끝낸다.** 중복·이미 고쳐짐은 사람에게 넘기지 않는다.
4. **멈춘 건은 틱이 다시 시도한다.** 사람이 "진행해" 를 치던 것을 재개 스윕이 대신 친다.

## 설계

### 1. 사다리 문서 — `references/live-verification-ladder.md`

네 문서(worker-template · verify-runner · closeout · BoDAT deploy-cycle)가 전부 이 한 파일을 가리킨다. 칸마다 "어느 박스에서 · 어떤 명령으로 · 무엇을 판정하나 · 실패 출력은 어떻게 인용하나".

| 칸 | 통로 | 판정 대상 |
|---|---|---|
| ① dev 서버 | `bin/rails runner` · localhost:3000 chrome | 서버 로직·화면 |
| ② 맥북/미니 직접 | `bin/dry-run`(레시피·블록) · AdsPower Local API(미니 릴레이) | 워커 런타임 스텝·AdsPower 호출 |
| ③ TEST 워커 | 미니: `ssh test '…'` · 맥북: `ssh bodat-mini 'ssh test …'` · `test_claim`/`bin/dry-run` · 프로필 #18 | 실 워커 행동·화면(캡처는 schtasks principal 복제) |
| ④ 사람 | 위 셋이 전부 실패한 출력 인용 + `needs:hardware` | 남은 것만 |

규칙: **미루려면 시도한 칸과 실패 출력을 인용한다.** `needs:hardware` 라벨만으로는 미룰 수 없다. 공개 쓰기(댓글·팔로우)는 우리 계정에만.

### 2. `needs-human` 사유 = `hold:*` 라벨

| 라벨 | 뜻 | 누가 푸나 |
|---|---|---|
| `hold:conflict` | rebase/semantic conflict — 사람 판단 | 사람 |
| `hold:policy` | 스펙·정책 결정 필요(플랜 불일치 등) | 사람 |
| `hold:ladder` | 사다리 ①~③ 전부 실패 — 출력 인용 필수 | 재개 스윕(또는 사람) |
| `hold:dup` | **금지** — 중복은 루프가 닫는다(§3) | — |
| `hold:hardware` | **금지** — "실장비 필요" 는 사다리를 올라야 한다 | — |

- `transition.sh verify-held` · `closeout-blocked` 에 `--reason conflict|policy|ladder` 를 **필수 인자**로. 없으면 usage exit 64 — 사유 없는 `needs-human` 을 만들 수 없게 한다. 전이가 `needs-human` + `hold:<reason>` 을 같이 붙인다.
- `loop-status.sh`: 사람대기 줄에 분류 병기(`#4770(구현중, conflict)`), `needs-human` 인데 `hold:*` 가 없으면 warn `needs-human 사유 없음`.
- `setup-labels.sh` 에 `hold:conflict` · `hold:policy` · `hold:ladder` 추가.

### 3. 중복은 루프가 닫는다 — `transition.sh closeout-dup`

closeout 1단계가 "이슈가 요구한 수정이 이미 main 에 있다" 로 판정하면(#4803 형): PR 닫기(머지 없이) + 이슈에 `중복: <근거 커밋>` 코멘트 + 이슈 닫기 + 라벨 정리. `needs-human` 안 붙인다. loop-status 의 `실패` 줄은 이 PR 을 `중복 종료` 로 구분한다(코멘트 마커 대신 PR 라벨 `dup`).

### 4. 재개 스윕 — issue-runner ① Reconcile 에 추가

`needs-human` + `hold:ladder` 이고 마지막 갱신이 `RESUME_AFTER_MIN`(기본 120) 을 넘긴 이슈 → `hold:ladder`·`needs-human` 을 떼고 `agent-ready` 로 되돌린다(재디스패치). 워커 프롬프트에 사다리 문서와 "직전 시도의 실패 출력" 을 인라인해 같은 칸에서 같은 실패를 반복하지 않게 한다. 재개 횟수는 이슈 본문 마커 `<!-- ladder-resume: N -->` 로 세고 `LADDER_RESUME_LIMIT`(기본 2) 초과 시 `hold:policy` 로 승격(그때만 사람).
사유 없는 `needs-human`(`hold:*` 부재)도 같은 스윕이 잡아 — 라벨을 떼지 않고 — warn 으로만 올린다(사람이 붙인 것일 수 있다).

### 5. loop-status 인계 전 창

연결 이슈가 `agent:claimed` 이고 PR 나이가 `HANDOFF_GRACE_MIN`(기본 90) 미만이면 무소속 warn 이 아니라 `구현중 ← PR #n(인계 전)`. 넘기면 warn(워커 사망 의심).

### 6. 미니 설치

worker-ssh · worker-recipe-test 는 `~/.claude/skills/` 의 개인 디렉터리(레포 밖)다. 미니 `~/.claude/skills/` 에 **복사**하고(심볼릭 링크 불가), 이 절차를 README 설치 절에 적는다. 미니 `ssh test` 직결과 맥북 중첩 경로 둘 다 사다리 문서에.

### 7. deploy-cycle(BoDAT 레포 — 별도 이슈)

④ "이월하거나 배포 후 검증으로 표기" 삭제. 실장비 항목이 있으면 ⑦ 은 **필수**. 체크박스가 전부 `[x]` 가 아니면 이슈를 닫지 않고 `needs-human` + `hold:ladder`(출력 인용) 로 남기며 보고에 `미검증 N`. "이월" 이라는 단어를 스킬에서 없앤다.

## 갈림길(가정한 결정)

1. 사유는 코멘트 마커가 아니라 **라벨**(`hold:*`) — loop-status 가 이슈별 조회 없이 세야 하고, 상태=라벨 존재 원칙.
2. `hold:dup`·`hold:hardware` 는 라벨을 아예 **만들지 않는다** — 금지를 문서가 아니라 라벨 부재로 강제.
3. 재개 스윕은 `hold:ladder` 만 자동 재개, `conflict`·`policy` 는 사람 — 사람이 붙인 `needs-human` 을 루프가 떼는 일은 없다.
4. 재개 상한 2회 뒤 `hold:policy` 승격 — 무한 재시도 금지.
5. deploy-cycle 변경은 BoDAT 레포 이슈로 분리(스킬이 그 레포 소속).

## 태스크 분해(이슈용)

- [ ] T1 `references/live-verification-ladder.md` + 네 문서 참조 + bin/ci 가드(참조 존재 · "이월" 부재)
- [ ] T2 `setup-labels.sh` hold 3종 · `transition.sh --reason` 필수 · `closeout-dup` 전이 · 테스트
- [ ] T3 `loop-status.sh` 사람대기 분류 · 사유 없음 warn · 인계 전 창 · 테스트
- [ ] T4 issue-runner ① 재개 스윕(`resume-sweep.sh` + SKILL 한/영) · 테스트
- [ ] T5 closeout 1단계 dup 분기 → `closeout-dup` · verify-runner/closeout held·blocked 에 `--reason`
- [ ] T6 미니 설치 절차(README) + 실제 설치
- [ ] T7 (BoDAT) deploy-cycle ④·⑦ 문구
