# 리뷰 회차 상한 + 게이트 구조 신호 — codex 는 PR 당 2회, 3회차는 자체 리뷰로 완료 · 계약 줄 폐기

에픽 #372 · 사람 결정 2026-09-13 · 시각화: `review-round-cap-and-gate-signals.html`

## 왜

PR 하나가 머지되기까지 codex 호출이 **회차당 3회**다 — verify-runner 정확성 1회 + closeout 1단계
정확성·계획 부합 2회. 양쪽 게이트가 각각 3회차 반송 상한(`VERIFY_ATTEMPTS_LIMIT`·`MAX_REPAIRS_PER_PR`)을
가져 최악 9회, 그 사이 워커 재구현 5회다. 리뷰어(codex)는 같은 diff 에 회차마다 다른 답을 낸다
(2026-09-13 실측: 같은 head 세 번 → P1 → P2 → CLEAN). 그래서 루프는 수렴하지 않고, 상한에 닿으면
`hold:policy` 로 사람을 부른다. 오늘 사람 결정 대기 4건 중 2건은 이미 풀린 건이었다. 결과 =
프로젝트 진도 정지 + 토큰 비용 폭증.

곁들여, 게이트가 리뷰어에게 요구하는 응답 계약 줄(`REVIEW_STATUS: reviewed`)은 프로덕션 크기
프롬프트(10~30KB)에서 모델이 내지 않는다 — 2026-09-13 실호출 0/4(정본 · 메모 제거 · 계약문 머리 배치
전부 NONE), 2026-09-11 0/4. 짧은 스모크 프롬프트에서만 낸다(1/1). 리뷰어는 매번 판정을 냈고 **버린 쪽은
게이트**다. #207 → #283 → #279 → #280 이 같은 조건을 세 번 옮겨 앉혔다 — 못 맞출 시험 조건이다.

## 결정 (사용자, 2026-09-13)

1. **codex 리뷰는 PR 당 최대 2회.** 1회차 BLOCKER → 워커가 고침 → 2회차 codex(마지막 codex) →
   BLOCKER 면 워커가 고침 → **3회차는 codex 없이 자체 리뷰(general-purpose 서브에이전트)로 최대한
   고쳐 `머지 판정: ✅` 로 완료**. 남는 지적은 ✅ 코멘트에 이름 붙여 남기고 closeout 6단계 파생으로.
2. **closeout 1단계는 codex 를 부르지 않는다.** verify-runner 가 이미 codex 를 마쳤다 — 1단계는
   general-purpose 계획 부합 확인(기존 폴백 템플릿 `verifier-prompt-fallback.md` 가 그 프롬프트)만.
3. **리뷰 반송은 `hold:policy` 사유가 아니다.** 사람 호출은 스펙·정책 선택, 연결 이슈 부재, 실장비
   요구, 인프라 실패에만 남긴다. "리뷰어가 또 다른 걸 찾았다" 는 1번 규칙이 자동 처리한다.
4. **게이트 판정 입력을 모델 문장에서 codex 구조 신호로 바꾼다.** 계약 줄 요구를 없앤다.

## 규칙 ① — 회차 상한 (스킬 문서)

`verify-attempt` 카운터(PR 본문 주석)는 그대로 쓴다. 값 N = 지금까지의 codex BLOCKER 반송 수.

| 검증 pass | N | codex | BLOCKER 면 | 통과면 |
|---|---|---|---|---|
| 1 | 0 | 호출 | 반송(`재검증 실패 … (attempt 1)`), N=1 | ✅ |
| 2 | 1 | 호출(마지막) | 반송(`… (attempt 2)` — 사유 끝에 `최종 회차: 다음 검증은 codex 없이 자체 리뷰로 완료된다`), N=2 | ✅ |
| 3 | 2 | **호출 안 함** | 없음 — 자체 리뷰가 2회차 지적 대비 해소 여부를 읽기 전용으로 판정, 미해소분은 ✅ 코멘트에 `잔여:` 로 열거 | ✅ (`codex 2회 소진 · 3회차 자체 리뷰`) |

- `VERIFY_ATTEMPTS_LIMIT = 3` → `CODEX_REVIEW_LIMIT = 2` 로 이름·뜻을 바꾼다. **held `--reason policy`
  의 "재디스패치 상한 초과" 갈래는 삭제**(연결 이슈 부재·실장비 갈래는 유지).
- 3회차 자체 리뷰 = `general-purpose` 서브에이전트, 입력은 직전 `재검증 실패` 코멘트 + `origin/<default>...HEAD`
  diff, 출력은 지적별 `해소/미해소 + 한 줄 근거`. E2E·결정적 CI 는 종전대로 돈다(그건 게이트다).
- 워커: 반송 사유에 `최종 회차` 가 있으면 9-b 사전 리뷰를 **건너뛰지 않는다**(지금은 반송 회차엔 생략).
- closeout 1단계: `VERIFIER = general-purpose`, `codex-review-gate.sh` 호출 0건. ⓐ/ⓑ 분기 앵커
  (`- ⓐ **` · `- ⓑ **` · `closeout-redispatch` · `closeout-pick` · `closeout-blocked` 순서)는 bin/ci 가드가
  보므로 **문자열 그대로 보존**하고 트리거 문장만 바꾼다. ⓑ 사유에서 "검증자 미산출" 을 뺀다(codex 가
  없으니 미산출이 없다).
- 마커 문구(`머지 판정: ✅/🔄/⚠ 보류` · `마감 검증: ✅/⚠ 보류` · `재검증 실패:` · `재디스패치:`)와
  `transition.sh` 전이 표·`--reason` 화이트리스트는 **바꾸지 않는다** — 테스트 6개가 바이트 단위로 문다.
- 불변 가드(bin/ci 에 추가): `skills/closeout/SKILL.md` 에 `codex-review-gate.sh` 호출 0건 ·
  `skills/verify-runner/SKILL.md` 에 `CODEX_REVIEW_LIMIT = 2` 존재.

## 규칙 ② — 게이트 구조 신호 (`scripts/codex-review-gate.sh`)

판정은 아래 순서로, **모델 문장을 읽지 않는다**:

1. 항목 집계(`- [P1]`·`[P2]`·`[P3]`, 기존 `ITEM_P*_RE`) — **1개 이상이면 그대로 판정**(BLOCKER/WARN/NIT).
   codex 가 렌더한 항목은 파일:줄을 달고 나온다 — 그 자체가 "읽었다" 의 증거다. 계약 줄 유무 무관.
2. 항목 0 이고 본문에 **정확히** `REVIEW_STATUS: no-basis` 인 줄이 있으면 NONE(리뷰어가 스스로 못 봤다고
   한 것 — 선택 신호, 요구는 안 한다).
3. 항목 0 이면 `events.jsonl` 을 본다 — `item.completed` 의 `command_execution` 항목 중 `command` 가
   `git ` 을 포함하거나 `--cd` 경로를 포함하는 것이 **1개 이상**이면 CLEAN, 아니면 NONE(읽지 않은
   "문제 없음" 은 판정이 아니다). 실측(2026-09-13, 4호출): 항목마다 8~15개, 전부 `/bin/zsh -lc "git …"`.
4. `STATUS_CONTRACT_TEXT` 는 짧은 힌트로 교체: "diff 를 읽지 못했으면 발견을 지어내지 말고
   `REVIEW_STATUS: no-basis` 한 줄만 써라." `reviewed` 값·"마지막 줄" 요구·모델 통제 구역(`cli_rendered`
   awk, `RENDER_HEADER_*`)·`LEGACY_UNABLE` 산문 휴리스틱은 **삭제**(3번이 두 경로 모두 대체한다).

`STATUS_KEY`·`STATUS_NO_BASIS` 상수는 남긴다(bin/ci "문서에 하드코딩 금지" 검사가 그 값을 본다).
`STATUS_REVIEWED` 와 `contract_re`·`cli_rendered`·`RENDER_HEADER_*` 관련 bin/ci 검사(1039~1083)는 삭제.

## 대상 파일

| 부분 | 파일 | 무엇 |
|---|---|---|
| ② | `scripts/codex-review-gate.sh` | 판정 블록(186~410) 교체 · 계약문 → 힌트 · LEGACY_UNABLE 삭제 · events 판정 함수 |
| ② | `scripts/tests/codex-review-gate.test.sh` | 스텁 codex 가 실 스키마(`command_execution`·`command`·`aggregated_output`) 로 events.jsonl 을 쓰게 · 계약 줄 위치/어형/헤더 경계 격자(4b-2·2i·2f·2g·2h·4b-3) 삭제 · 새 격자: 항목>0 & 계약 줄 없음 → 판정 / 항목 0 & git 명령 있음 → CLEAN / 항목 0 & 명령 없음 → NONE / 항목 0 & events 없음 → NONE / no-basis → NONE |
| ② | `scripts/codex-review-gate-smoke.sh` | 회귀 창 정의를 "항목이 렌더된 응답에서 판정" 으로 — exit 3 = 항목 0(발견이 안 났다) |
| ② | `bin/ci` 1039~1083 | 계약 검사 축소(상수 2개 + 문서 하드코딩 금지만) |
| ② | `skills/closeout/references/verifier-prompt.md` 28~33 | 계약 문단 삭제 |
| ② | `skills/closeout/SKILL.md` 528~546 · `SKILL.en.md` 602~620 | 응답 계약 단락 → 구조 신호 요약 |
| ② | `Plans/codex-native-review-gate.md` `## 검증` | 착지 기록 단락 추가 |
| ① | `skills/verify-runner/SKILL.md` 27~40 · 197~216 · 236~292 | 상수 · ③-3 분기 · ④ passed/redispatched/held |
| ① | `skills/closeout/SKILL.md` 29~46 · 501~546 · 653~656 · `SKILL.en.md` 대응 | 1단계 codex 제거 · ⓑ 사유 |
| ① | `references/worker-template.md` 234~289 · `.en.md` | 최종 회차 9-b 필수 |
| ① | `bin/ci` | 불변 가드 2줄 |

## 하지 않는 것

- `transition.sh` 전이 표·`--reason` 값·`setup-labels.sh` 라벨 — 무접촉.
- 반송 마커·판정 마커 문구 — 무접촉(`bounce-comment.sh` 가 만들고 테스트가 문다).
- `MAX_REPAIRS_PER_PR`(closeout 자체 반송 상한) — 유지. 1단계가 자체 리뷰가 되어도 반송은 그 상한을 따른다.
- 새 hold 사유 도입 — 안 한다. 리뷰 반송은 사유가 없어지는 것이지 이름을 바꾸는 것이 아니다.

## 검증

- `scripts/tests/codex-review-gate.test.sh` 새 격자 초록 + 뮤테이션 3종(항목 판정 제거 · events 판정 제거 ·
  no-basis 판정 제거) 각각 빨강.
- `scripts/codex-review-gate-smoke.sh` 실호출 1회 → exit 0(발견 렌더 + 판정).
- 정본 프롬프트 실호출 1회(머지된 PR head, `--prompt` 정본) → verdict ≠ NONE. 이 두 실호출이 #280 의
  미체크 두 항목을 대체한다(#280 은 이 플랜에 흡수·닫음).
- `bin/ci`(한/영 헤더 수·순서 · 마커 가드 · ⓐ/ⓑ 앵커 · 새 불변 가드).
- 배포 = 미니 `git pull --ff-only` 뒤 다음 verify-runner 틱에서 `CODEX_REVIEW_LIMIT` 로그 확인.

## 관련

#207 · #283 · #279 · #280(흡수) · `Plans/codex-native-review-gate.md` · BoDAT 메모리 "리뷰 루프 상한"(2026-09-08)
