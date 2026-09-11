# 라벨 세 축 정리 — `needs-human` · `hold:*` · `spinoff`/`full-cycle`

2026-09-11 결정. 어젯밤 #190(배포 대기가 매 틱 warn) 을 고치고 나서, 그 warn 이 증상이고
원인은 **`needs-human` 이 뜻을 여럿 겸하는 것** 임이 드러났다. 이 플랜은 그 겸직을 풀어
각 라벨에 **뜻 하나**씩을 주고, 그 축을 코드·문서·기존 이슈에 반영하는 순서를 정한다.

## 무엇이 문제였나 — 실측

`needs-human` 의 생산자가 넷인데 뜻이 셋이다.

| 생산자 | 동반 라벨 | 실제 뜻 |
|---|---|---|
| `transition.sh` (verify-held · closeout-blocked · runner-held) | `hold:<사유>` 항상 | 기계가 멈췄다 |
| closeout 4단계 배포 대기 | `deploy-wait` | deploy-cycle 루프(무인 — dev 최신화·승격·배포·종료) |
| full-cycle §7 배포 대기 | 없음 — `deploy-wait` 미부착(2026-09-11 실측: 그날 발행된 BodaT #5064 도 없다). BodaT #5071 이 고친다 | 배포 게이트 |
| closeout — 라이브 검증 이슈(`SKILL.md:530`) · 라벨 부착 실패 폴백(`:468`) | 없음 | 사람 호출 / 비정상 |

- 열린 이슈 실측(2026-09-11): issue-runner 7건 · BodaT 5건의 `needs-human` 중 **맨
  `needs-human` 은 0건** — 전부 짝이 있다.
- `spinoff`: 읽는 곳이 `loop-status.sh:565`(24시간 창 카운터) **하나뿐**, 게이트 0곳.
  그런데 issue-runner 열린 이슈 17건 중 9건(53%)이 달고 있다.
- `hold:*`: 실제 결함 없음. 다만 `hold:policy` 가 #155 이후 "재심 1회는 루프가 답한다" 로
  바뀌었는데 라벨 설명과 `resume-sweep.sh:24-26` 머리 주석은 옛말("사람이 결정해야 하는 것").
- `needs:hardware`: `setup-labels.sh` 가 만들지 않고 **읽는 스크립트 0곳**, issue-runner 엔
  라벨 자체가 없다(BodaT 누적 200건+). 루프 축이 아니라 레포 규약이다 — 이 플랜의 범위 밖.

## 결정된 축 — 라벨 하나에 뜻 하나

| 축 | 라벨 | 뜻 | 누가 푸나 |
|---|---|---|---|
| **게이트** | `hold:ladder` | 사다리 ①~③ 전부 실패 | 루프 — 창이 지나면 자동 재개 |
| | `hold:conflict` | rebase/semantic 충돌 | 사람 |
| | `hold:policy` | 스펙·정책 결정 필요 | 재심 1회는 루프(#155) → 유지 판정 뒤 사람 |
| **호출** | `needs-human` | **사람이 직접 세웠다** (또는 재심에서 사람 몫으로 확정) | 사람 |
| **배포** | `deploy-wait` | 배포·승격 게이트 | deploy-cycle 루프(무인 — dev 최신화·승격·배포·종료) |
| **소유 레인** | `full-cycle` | 이 산출물은 사람 세션 사이클이 들고 있다 | — |
| **출처** | `spinoff` | 부모 PR/이슈에서 갈라져 나왔다 | — |

핵심 이동 두 개:

1. **기계 정지에는 `hold:*` 하나만 붙인다.** 지금은 `needs-human` 이 함께 붙어 한 정지에
   라벨이 둘이고, 그래서 `needs-human` 이 "사람 호출" 이 아니라 "루프 손대지 마" 로 읽힌다.
   `hold:conflict` 는 그 자체가 이미 사람 몫이라는 뜻이므로 `needs-human` 을 겹치지 않는다.
2. **배포 대기 이슈에서 `needs-human` 을 뗀다.** 그 라벨이 거기서 하는 일이 없다 —
   디스패치 게이트는 `label:agent-ready` 를 요구하는데(`eligible-issues.sh:36`) 배포 대기
   이슈엔 그게 없어 애초에 후보가 아니고, `loop-status.sh:474` 버킷은 `deploy-wait` 가 이미
   이기며, deploy-bodat 수집은 **제목 정규식**이다(라벨을 안 본다).

그 대신 **게이트가 `hold:*` 를 봐야 한다** — held 이슈는 `agent-ready` 를 그대로 달고 있어서
(사다리 내내 유지가 규약) `needs-human` 을 떼는 순간 재디스패치된다.

새 게이트: `open ∧ agent-ready ∧ ¬agent:claimed ∧ ¬needs-human ∧ ¬hold:* ∧ ¬flow:* ∧ 블로커 CLOSED`

### `full-cycle` 은 레인 소유 표시다

한 사이클이 만드는 산출물 **전부**에 붙는다 — 구현 이슈 · **PR** · 배포 대기 이슈 · 사람이
계속 들고 갈 파생. 파생을 루프에 넘기면 그건 루프 레인이므로 `agent-ready`(+`spinoff`)만
달고 `full-cycle` 은 **떼거나 안 붙인다**(레인 라벨 배타 규칙). `spinoff`(출처)와
`full-cycle`(소유)은 직교한다.

빠진 자리 둘: **PR 에 안 붙는다**(full-cycle §4 에 부착이 없다) · **`setup-labels.sh` 가
`full-cycle` 을 만들지 않는다**(두 레포엔 손으로 생겼지만 새 옵트인 레포에선
`--add-label full-cycle` 이 편집 전체를 실패시킨다 — `transition.sh:67` 의 함정과 같은 계열).

### `spinoff` 은 출생증명으로 남긴다

게이트가 아니라 관측용이고, "파생도 루프 이슈로" 라는 사용자 지시가 계속 생산한다. 포화
자체는 해롭지 않다 — 24시간 창이 이미 표시를 거른다. 할 일은 **라벨 설명을 "출처(state 아님)"
로 못박는 것** 뿐이다. 지금 `flow:*`·`hold:*` 사이에 섞여 상태처럼 읽힌다.

## 함정 — 둘 다 이 레포에 실측 기록이 있다

1. **`gh search` 가 부정 라벨(`-label:`)을 오파싱한다**(#21). `-label:hold:policy` 는 콜론이
   둘이라 더 위험하다. → 게이트는 **클라이언트 필터**로 넣고 검색 쿼리는 건드리지 않는다
   (`eligible-issues.sh:57` 이 이미 그 모양이다).
2. **레포에 없는 라벨은 `--remove-label` 도 편집 전체를 실패시킨다**(`transition.sh:67`,
   실측 2026-09-09). `setup-labels.sh` 는 기존 옵트인 레포를 자동 업그레이드하지 않는다.
   → 새 라벨을 하나도 만들지 않는 이 플랜은 이 함정을 안 밟는다. 단 `full-cycle` 을
   `setup-labels.sh` 에 넣는 단계는 **스크립트가 그 라벨을 붙이기 전에** 와야 한다.

레인이 비어 있지 않다(PR #191·#189·#182 + BodaT). 그래서 **이름 변경·삭제는 하지 않는다** —
이 플랜의 작업은 전부 "추가 · 부착 위치 이동 · 문구 정정" 이다.

## 단계 — 각 단계가 독립적으로 초록이고 되돌릴 수 있다

### 1단계 (무동작 안전망) — 게이트에 `hold:*` 추가

`eligible-issues.sh` · `claim-issue.sh` · `closeout-eligible.sh` · `verify-eligible.sh` 의
`needs-human` 필터 옆에 `hold:*` 필터를 **더한다**. 지금은 둘이 항상 쌍이라 **동작이 바뀌지
않는다** — 2·3단계가 `needs-human` 을 떼어도 게이트가 먼저 서 있게 하는 것이 목적이다.

- 검증: 기존 테스트 전건 초록 + 신규(hold:* 단독 이슈가 후보에서 빠진다) + 뮤테이션 방증.

진행 — 1단계 착지 (#242 / PR #262). 네 자리 전부에 `hold:` **접두** 필터가 섰고, 격자 단언을
`scripts/tests/hold-gate.test.sh` 로 세웠다. **단 "동작이 바뀌지 않는다" 는 네 자리 중 셋에만
맞았다** — `verify-eligible.sh` 에는 `needs-human` 필터가 애초에 **없었다**(평상시엔
`transition.sh verify-held` 가 PR 에서 `flow:verify` 를 떼 서버 쿼리에 안 잡혀 가려져 있었다).
`runner-held`(#151)는 단계 라벨을 건드리지 않으므로, 정지된 PR 이 뒤이은 ② Maintain 규칙 0
재라벨로 `flow:verify` 를 얻으면 그대로 검증 후보로 떴다. 그래서 이 자리만 **오늘 동작이
바뀐다**(정지된 PR 이 verify 후보에서 빠진다) — 무동작 안전망이 아니라 구멍 메우기였다.

### 2단계 — 배포 대기 이슈에서 `needs-human` 제거

- `skills/closeout/SKILL.md` · `SKILL.en.md` 4단계 발행 명령에서 `--label needs-human` 제거
  (`--label deploy-wait` 만 남긴다).
- full-cycle §7 은 **BoDAT 레포 파일**이다(`.claude/skills/full-cycle/SKILL.md` — `~/.claude/skills/full-cycle`
  은 그 심링크). 사람 손이 아니라 루프 이슈 BodaT #5071 로 태웠다(`deploy-wait` 부착 · `needs-human`
  제거 · `needs:hardware` 는 라벨 있는 레포에서만).
- 열린 배포 대기 이슈의 라벨 정리(issue-runner 3건 · BodaT 2건 기준, 실행 시점 재확인).
- 이 시점에서 #190 의 note 강등은 **저절로 무의미해진다**(② 는 `--label needs-human` 으로
  목록을 걸기 때문에 배포 대기가 아예 안 잡힌다). 코드는 옛 이슈·타 레포 폴백으로 남긴다.

### 3단계 (본 변경) — 전이표를 사유별로 가른다

- `transition.sh`: `verify-held` · `closeout-blocked` · `runner-held` 가 `needs-human` 을
  무조건 붙이던 것을 멈추고 `hold:<사유>` 만 붙인다. `needs-human` 부착은 **재심 유지 판정
  한 곳**만 남는다(디스패처 ①, `policy-review: kept`).
- `resume-sweep.sh`: ① 쿼리를 `needs-human+hold:ladder` → **`hold:ladder` 단독**으로.
  ③ 쿼리도 `hold:policy` 단독으로. 재개·승격이 떼는 라벨 목록에서 `needs-human` 을 뺀다
  (PR 미러 포함).
- ② 분기("사유 없는 `needs-human`" warn)는 **의미를 잃는다** — 맨 `needs-human` 이 이제
  정상(사람이 붙인 것)이다. warn 을 없애고 대시보드 카운트로 대체하거나 `note` 로 내린다.
  #190 이 세운 정의("warn 은 루프가 교정 가능한 불변식 위반일 때만")를 축 자체에 적용하는 것.
- `loop-status.sh`: 사람대기 칸 = `hold:conflict` ∪ 재심 끝난 `hold:policy` ∪ `needs-human`.
- `loop-status.sh`: **새 칸 `보류`** = `hold:*` ∧ ¬`needs-human`(ladder 재개 대기 · policy 재심 전). 이게 없으면
  `needs-human` 을 뗀 기계 정지가 전부 `대기`(agent-ready 폴백) 칸으로 떨어져 "집을 수 있는 이슈" 로
  읽힌다 — 사람대기 칸이 손댈 게 없는 것으로 찼던 오류의 반대 방향. 우선순위
  `배포대기 > 사람대기 > 보류 > 단계 > 막힘(#248) > 대기`. 부수 효과: 서버 쿼리 `-label:needs-human`
  이 걸러 주던 held 이슈가 50 창 안으로 들어온다(#247 의 창 절단 warn 이 그래서 필요하다).

### 4단계 — 문구·라벨 설명 정정

- `hold:policy` 설명과 `resume-sweep.sh:24-26` 머리 주석이 "사람이 결정해야 하는 것" 이라
  적혀 있다 — #155 재심 1회를 반영한다.
- `spinoff` 라벨 설명을 **출처(state 아님)** 로 못박는다.
- `setup-labels.sh` 에 `full-cycle` 을 추가한다(현재 빠져 있다).
- `needs-human` 라벨 설명을 "루프가 한계 도달 — 사람 판단 필요" → "**사람이 직접 세운
  정지**(기계 정지는 `hold:*`)" 로.

### 5단계 (PR #191 머지 후) — 레인 판별을 라벨로

- full-cycle §4 가 PR 에 `full-cycle` 을 붙인다.
- `verify-eligible.sh:44` · `closeout-eligible.sh:48` · `loop-status.sh:495` 가 head 이름
  (`agent/issue-*`)으로 레인을 가르는 것을 **`full-cycle` 라벨 축으로 보강**한다. 브랜치
  이름은 관례지 강제되는 축이 아니다. PR #191 이 같은 코드를 손대고 있으므로 그 뒤에 온다.

## 범위 밖

- **`needs:hardware`** — 루프가 만들지도 읽지도 않는다(읽는 스크립트 0곳, issue-runner 엔
  라벨 자체가 없음). BodaT 레포 규약이고 기계가 읽는 축은 본문 절
  `## 라이브/하드웨어 검증 항목` 이다. 단, full-cycle §7 이 `[--label needs:hardware]` 를
  제시하는데 그 스킬이 issue-runner 에서도 쓰여 **라벨이 없는 레포에서 `gh issue create` 가
  통째로 실패**한다 — 스킬 문구를 "레포에 그 라벨이 있을 때만" 으로 좁히는 것은 BodaT #5071 에 넣었다.
- 라벨 이름 변경·삭제 — 레인이 비어 있지 않아 2단계 다중 레포 마이그레이션이 된다.

## Test plan

- 단계마다 `bin/ci` 초록 + 해당 스크립트의 테스트 전건 초록.
- 1·3단계는 **뮤테이션 방증 필수** — 게이트 조건을 되돌리면 신규 케이스가 실제로 빨개지는지
  실측 로그를 PR 본문에 붙인다(#190 에서 세운 규율).
- 2단계는 실제 열린 이슈의 라벨 상태를 전후로 기록한다(`gh issue list --label deploy-wait`).
- 3단계 뒤 한 틱을 관측해 `loop-status` 의 사람대기/배포대기 칸 수가 의도대로인지 확인한다.
