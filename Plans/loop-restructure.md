# 루프 세 스킬 재구조화 — 상태기계 SSOT · 술어 라이브러리 · 프로즈→스크립트 · 문서 분리 · CI 정리

사람 결정 2026-09-13 (방향 동의 · rationale 한글만 · 0단계부터) · 시각화: `loop-restructure.html` · 진단 원본: 탐색 에이전트 2건(스킬 문서 축 · 스크립트/CI 축)

## 왜

issue-runner · verify-runner · closeout 세 루프가 매 틱 읽는 SKILL 이 합계 2,042줄(196KB)이고, 그 중
closeout 하나가 1,185줄이다. #379(사람 코멘트 필터가 ✅ 이전 코멘트까지 세서 5 PR 이 6시간 정체)는
개별 버그가 아니라 구조의 증상이다: 같은 판정(`머지 판정: ✅` 탐지, 마지막 매칭 인덱스, 센티널 마커,
레포 스코프)이 스크립트 3~7벌로 흩어져 있고, 그 드리프트를 코드가 아니라 `bin/ci` 의 문자열 가드
(216회 `grep -q`, 2,969줄의 39%)가 막고 있으며, 소유권 교대는 라벨·코멘트 마커·전이 exit 코드의 3중
암묵 계약이라 어느 루프도 소유하지 않는 칸이 최소 4개 남아 있다.

진단 수치(2026-09-13 실측):

| 축 | 수치 |
|---|---|
| SKILL 분량 | issue-runner 495 · verify-runner 362 · closeout 1,185 (①-b+③ = 882줄이 매 틱 필독) |
| 사고 이력·근거 서사 비중(통독 추정) | issue-runner ~28% · verify ~18% · closeout ~34% (closeout:286–421 의 135줄엔 실행 지시가 거의 없음) |
| 2개 이상 파일에 중복된 규칙 | 13종 (fail-closed 15회 변주 · 전이 exit 처리 14회 · loop-status 블록 3벌 축자 · 사다리 규율 4벌이 서로 다른 칸 지정) |
| 프로즈에 사는 결정론 로직 | 12건 (repair-count/verify-attempt 카운터 2벌 · worktree→PR head 동기화 3자리 · 배포 대기/파생 이슈 발행 · 전이 exit→조치 매핑 20+회) |
| 상수 | 프로즈 전용 9개 · 다중 정의 6개(ISSUE_TIMEBOX_HOURS 4벌) · VERIFIER 계약은 3파일이 각각 SSOT 자칭 · `CODEX_GATE_TIMEOUT=900s = 10분` 오기 2곳 |
| 스크립트 중복 술어 | ✅ 탐지 jq 3벌(drifting) · 마지막 매칭 인덱스 3벌 · head 신선도 createdAt vs 인덱스 **상충** · `.loop/repos` 7벌 · 센티널 생산 6곳/소비 1곳 |
| bin/ci | 2,969줄 · 109블록 중 93개가 `#NNN` 가드 · 문서 문구 단언만 46블록 1,164줄(39%) · retire 정책 없음 |
| 주석/코드 | bounce-state 4.28 · finish-classify 1.58 · loop-status 헤더 330줄 |
| 전용 테스트 없는 판정 스크립트 | progress-evidence · claim-at · pr-head-at · closeout-ci-pass · closeout-reconcile |
| 소유 주체 없는 상태 | verify-redispatch 반쯤 이동 · 이슈 없는 PR 의 hold:policy · `머지 판정` 무코멘트 초록 PR · 미러 정리 warn 재시도 |

## 원칙 (재구조화 전체에 적용)

1. **행동 불변 리팩터링이 기본.** 루프의 판정·전이가 바뀌는 곳은 "소유 주체 없는 상태 4개" 의 leaf 뿐이고,
   그것도 각각 별도 이슈로 낸다. 나머지 단계는 기존 테스트 20개 + bin/ci 가 초록인 채로 옮긴다.
2. **서사는 지우지 않고 옮긴다.** 이 레포는 주석·문단이 설계 근거다. 사고 이력·근거는 `references/<루프>-rationale.md`
   로 가고, 운영 지시 자리에는 `(근거: rationale §N, #NNN)` 한 줄 포인터만 남는다.
3. **한 판정은 한 자리.** 술어는 jq 모듈 하나, 상수는 셸 파일 하나, 상태기계는 표 하나. SKILL 은 그것을
   **참조**하지 재진술하지 않는다.
4. **가드는 대체 후 폐기.** bin/ci 의 문자열 단언은 그 규칙이 행동 테스트나 SSOT 로 강제되는 순간 지운다.
   무조건 삭제도, 영구 보존도 아니다.
5. **매 틱 로드 크기 목표**: closeout ≤ 730줄 · issue-runner ≤ 370줄 · verify-runner ≤ 380줄 — 2026-09-13 3단계 실측(728·369·381)으로 교정. 처음 잡은 400·300·250 은 "운영 지시 실분량 약 1/3" 추정이었는데, 서사를 이슈 전제보다 더 걷어내고도(closeout ①-b −67% · ③ −38%) 남은 것이 전부 exit 분기·필수 형태·호출 줄이라 그 아래는 지시를 깎아야만 닿는다(#453·#454·#455 PR 본문). 지시 손실 0 이 숫자보다 우선이다(사용자 결정 2026-09-13).

## 단계

각 단계가 에픽 하나다(우선순위 규약: 에픽 본체는 `epic` 만, leaf 가 P 를 상속 · 동시 P1 에픽 2개까지).
순서는 의존 관계다 — 0 이 없으면 3 의 문서 분리가 기준 없이 산문을 옮기는 일이 되고, 1·2 가 없으면 3 이
프로즈 로직을 가리킬 스크립트가 없다.

### 0단계 — 상태기계 SSOT (`references/state-machine.md`) + 소유 주체 없는 칸 4개

- 표 하나: 상태(PR 라벨 집합 + 이슈 라벨 집합 + 마지막 판정 코멘트) → 소유 루프 → 진입 전이(`transition.sh` 동사)
  → 게이트 스크립트 → 정상 출구 → 회수 주체. 진단 §4 의 9행 + 반송 순환이 초안이다.
- 세 SKILL 의 "소유 라벨 불가침" · "hold:*/needs-human" · "전이 exit 1·2 → BLOCKED 한 줄" 재진술을 전부
  이 표 참조로 바꾼다(문구 14회·4벌·4벌 → 각 1줄).
- 소유 주체 없는 칸 4개는 **각각 leaf 이슈**(행동 변경이므로): ⑴ `verify-redispatch` exit 1·2 반쯤 이동(PR 은
  `flow:verify` 상실·이슈는 `agent:claimed`)의 회수 주체 지정 ⑵ 연결 이슈 없는 PR 의 `hold:policy` 재심 경로
  ⑶ `머지 판정` 코멘트가 없는 초록 PR 의 소유 ⑷ resume-sweep 미러 정리 "양성 증거 못 얻음" 의 재시도 주체.
- `loop-status.sh` 의 버킷 정의 주석(17–330행)이 이미 반쯤 이 표다 — 표를 파일로 빼고 loop-status 는 참조한다.
- 담당: **사람 세션(full-cycle)** — 상태기계를 쓰는 일은 판단이 든다. 칸 4개 leaf 는 루프.

### 1단계 — 술어 라이브러리 (`scripts/lib/loop.jq` + `scripts/lib/constants.sh`)

- `scripts/lib/loop.jq`(jq `-L scripts/lib` 로 import): `is_verdict_ok`(✅ ko/en) · `is_verdict_pending`(🔄) ·
  `is_machine`(센티널 contains + 레거시 3접두 동결 폴백 ko/en) · `last_index(f)` · `is_bounce`(재디스패치/재검증 실패)
  · `stop_labels`(`needs-human` ∪ `hold:*`) · `owner_labels`(`harvesting`·`verifying`·`flow:*`) · `short_repo`.
  소비처: closeout-eligible · finish-classify · bounce-state · verify-eligible · closeout-step1-marker · loop-status ·
  resume-sweep · epic-sweep · eligible-issues · claim-issue. `.loop/repos` 스코프는 `scripts/lib/scope.sh` 함수 하나.
- **head 신선도 상충 판결**: finish-classify(createdAt epoch) vs bounce-state(인덱스)를 한 규율로. 초안 판결 —
  코멘트끼리는 인덱스, 코멘트 vs 커밋은 시각(둘은 다른 축이라 섞을 수 없다)을 `loop.jq` 주석 한 곳에 명문화.
- `scripts/lib/constants.sh`: 스크립트가 읽는 상수(STALL_MIN · ISSUE_TIMEBOX_HOURS · MAX_TIMEBOX_GRACE ·
  STALE_FINISH_MIN · RESUME_AFTER_MIN · LADDER_RESUME_LIMIT · CODEX_GATE_TIMEOUT)를 한 파일로. 세 SKILL 의 `## 상수`
  절은 LLM 전용 노브(MAX_AGENTS · QUIET_TICKS · CODEX_REVIEW_LIMIT 등)만 남기고 스크립트 상수는 "값은
  `constants.sh`" 로 가리킨다. `VERIFIER_TIMEOUT_MIN=10 ≠ CODEX_GATE_TIMEOUT=900s` 오기는 여기서 바로잡는다.
- 각 소비처 교체는 leaf 하나씩(기존 테스트가 회귀망) — 루프에 태울 수 있는 기계적 작업.
- 전용 테스트 없는 판정 스크립트 5개에 격자 테스트를 붙이는 leaf 를 같은 에픽에 둔다.

### 2단계 — 프로즈 로직을 스크립트로

| 새 스크립트(또는 확장) | 대체하는 프로즈 | 비고 |
|---|---|---|
| `attempt-counter.sh <repo> <pr> <key> [bump]` | `repair-count`/`verify-attempt` 읽기-증가-쓰기 2벌 | 하나로 |
| `transition.sh --or-report` (또는 래퍼 `step.sh`) | exit 0/1/2/64 → 조치 매핑 20+회 | SKILL 은 "실패면 stderr 한 줄을 Report 로" 한 문장 |
| `make-worktree.sh --sync <repo> <pr>` | fetch + reset --hard origin/agent/issue-N 3자리 | |
| `deploy-wait-issue.sh` | closeout 4단계 발행·라벨 확인·3단 복구 (843–886) | full-cycle §7 과 같은 형식 — 공유 |
| `spinoff-issue.sh` | 6단계 발행 + `Epic` 줄 확인 + 라벨 보강 (1037–1084) | `spinoff-inherit.sh` 흡수 |
| `lessons-trim.sh append` 를 issue-runner 도 사용 | SKILL.md:116–119 프로즈 append | 잠금 밖 append 유실 경로 제거 |
| `smoke-tally.sh` | `[칸 ③]` 표식 판별·분모 제외·보류 합산 (926–974) — `smoke-prompt.md` 와 계산기 둘 | |
| `resume-sweep.sh --count-ladder` | SKILL.md:425 의 200자 jq 복붙 | |
| `pr-state.sh <repo> <pr>` | 규칙0 "마지막 판정 코멘트 → flow:* 목표 라벨" (302–314) | 0단계 표를 기계가 읽는 진입점 |
| 탈락 사유 채널 `skip: <repo>#<pr> <사유>` (eligible 3종 공통) | closeout-eligible 의 `continue` 12곳 중 #379 가 소리를 내게 한 1곳만 — 나머지 11곳도 같은 원칙(#206 조용한 큐 사망 금지) | PR #384 simplify 깊이 리뷰 메모 |
| `bounce-state.sh --verdict-index` | closeout-eligible 이 ✅ 마지막 인덱스를 자체 계산(#384) — bounce-state 가 같은 `$vi` 를 이미 계산하지만 출력을 위치로 파싱하는 소비자(`:381-383`)가 있어 필드 추가는 파서까지 손봐야 함 | 1단계 `loop.jq` 로 흡수되면 불필요 |

- 각 행이 leaf 하나. 전부 루프에 태울 수 있다(스펙이 곧 지금의 프로즈).

### 3단계 — SKILL 문서 분리

- 파일 구조(루프마다 동일):
  - `SKILL.md` — 틱 골격만: 상수(LLM 노브) · ①~④ 각 절은 "무엇을 · 어느 스크립트로 · 실패 시 어디로" 만.
  - `references/<루프>-rationale.md` — 사고 이력·설계 근거·실증 날짜. SKILL 의 각 절 끝에 `(근거: rationale §N)`.
  - `references/loop-conventions.md` **공유 1벌** — fail-closed 정의 · warn/note 경계 · warn→Report 릴레이 ·
    센티널 마커 · `Closes #N` 전용 줄 · 레포 짧은 이름 · loop-status `--post` 블록 · setup-labels 재시도 ·
    사다리 칸 규율(누가 어느 칸까지 — 표 하나로 확정).
- 표면 교정 판정(verify:64–94 ↔ closeout:754–769 축자 복붙)은 conventions 로 1벌.
- 한/영 동기 검사(bin/ci)는 유지 — rationale 은 한글만(매 틱 안 읽으므로 번역 부담 제거, 사람 결정 필요).
- 담당: **사람 세션(full-cycle)** — 어느 문장이 지시이고 어느 문장이 서사인지 가르는 일은 판단이다.
  루프별 1 PR(closeout → issue-runner → verify-runner 순, closeout 이 가장 크다).

### 4단계 — bin/ci 정리 + 주석 회고록 이동

- 문서 문구 단언 46블록: 각 블록을 ⓐ 행동 테스트로 치환(scripts/tests) ⓑ 1~3단계 SSOT 가 강제하게 되어 폐기
  ⓒ 남길 이유가 있으면 `ci/guards/<주제>.sh` 로 이동(+ 만료 조건 주석 필수) 셋 중 하나로 분류. 분류표를 이
  에픽의 첫 leaf 로 만들고, 그 뒤 leaf 는 표의 행 단위.
- `bin/ci` 를 `ci/steps/NN-<이름>.sh` 로 쪼개고 `bin/ci` 는 순서대로 실행하는 20줄 러너로.
- retire 정책 명문화: `#NNN` 가드는 만료 조건(어느 테스트/SSOT 가 대신 강제하는가)을 주석에 반드시 적고, 조건이
  충족되면 지운다.
- 헤더 주석 60줄 초과 5개(loop-status 330 · finish-classify 93 · transition 87 · bounce-state 81 · progress-evidence 61):
  사고 이력을 rationale 로 옮기고 헤더는 "무엇을 · 입력/출력 계약 · 근거 포인터" ≤ 40줄.
- dead/수동 스크립트(`block-issue.sh` · `codex-review-gate-smoke.sh`)는 `scripts/manual/` 로 분리.

## 결정 로그 — 사용자 의도를 가정하고 택한 갈림길

| # | 갈림길 | 택한 쪽 | 가정 |
|---|---|---|---|
| 1 | 행동을 함께 손보나, 구조만 옮기나 | 구조만(행동 변경은 사각지대 4 leaf 로 격리) | "정리·구조화" 요청은 동작 불변을 전제한다고 봄 |
| 2 | 서사 삭제 vs 이동 | rationale 문서로 이동 | 이 레포의 "주석이 설계 근거" 규율 존중 |
| 3 | 술어 SSOT 를 bash 함수로 vs jq 모듈로 | jq 모듈(`-L`) | 소비처 대부분이 jq 필터 형태 · bash 3.2 제약 무관 |
| 4 | 단계 순서 | 0→1→2→3→4 (상태기계 먼저, CI 마지막) | 문서 분리는 참조할 SSOT 가 먼저 있어야 함 |
| 5 | 담당 레인 | 0·3 은 full-cycle, 1·2·4 leaf 는 루프 | 판단이 드는 일과 기계적 치환을 가름 |
| 6 | rationale 한/영 | 한글만 | 매 틱 로드되지 않는 문서에 번역 동기 비용을 안 들임 — **사람 결정(2026-09-13): 한글만** |
| 7 | 에픽 수 | 5개(단계 = 에픽), P1 은 0·1 부터 | 동시 P1 에픽 2개 규약 |
| 8 | closeout 목표 크기 | ≤ 400줄 → **≤ 730줄로 교정(2026-09-13)** | 진단상 운영 지시 실분량(약 1/3)에 여유를 둔 값이었으나 실측 728 — 나머지는 전부 지시. ③ 을 별도 참조 파일로 쪼개 헤더 규약을 바꾸는 안은 사용자가 기각 |

## 이 플랜이 하지 않는 것

- 루프 세 개를 하나로 합치기 — 레인 분리는 소유권 모델의 근간이라 유지.
- 워커 템플릿(`references/worker-template.md`) 재작성 — 센티널·`Closes` 규칙을 conventions 로 옮기는 것까지만.
- `transition.sh` 분할 — 단일 관문은 장점이기도 하다(전이 표 한 자리). 0단계 표와 1:1 대응만 확인.

## 다음 행동

1. (완료) 사람 결정 2026-09-13 — 방향 동의 · rationale 한글만 · 0단계부터.
2. (완료 2026-09-13) 0단계 #392/#393 → 1단계 #425 → 2단계 #443 → 3단계 #451 전부 main 머지. 세 rationale · loop-conventions.md · state-machine.md · loop.jq/constants.sh · 스크립트 4개가 SSOT.
3. 4단계(bin/ci 정리 + 주석 회고록 이동)는 별도 에픽으로 — 사용자 결정 2026-09-13 "이 세션에서 이어간다".
