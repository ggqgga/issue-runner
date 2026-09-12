# Codex 게이트를 내장 리뷰어(`codex exec review`)로 — 모델·설정 정비 포함

## 배경 (2026-09-07 실측)

- 루프(verify-runner ③-3 · closeout 1단계)와 사람 세션(full-cycle 6절)의 Codex 게이트는 전부
  `codex:codex-rescue` 서브에이전트 → 플러그인 `task` → **프롬프트 리뷰** 경로다.
- 같은 커밋(issue-runner #130, 4파일 ~100줄)으로 비교하니 프롬프트 리뷰(spark)는 실 결함 0, 내장 리뷰어는
  terra 88s/P1 1건 · sol 170s/P1+P2 · luna 355s/P1×2+P2 를 잡았다(→ #131). 내장 리뷰어는 P1/P2 우선순위와
  파일:줄을 정형으로 돌려준다.
- 계정(ChatGPT Pro)에서 쓸 수 있는 모델은 `gpt-6-astra`(0.153+) · `gpt-5.6-sol/terra/luna` · `gpt-5.3-codex-spark` 뿐.
  `gpt-5.5` 는 은퇴(404), `gpt-5.4(-mini)` 는 2026-08-31 은퇴. config 의 `model = "gpt-5.5"` 가 모델 미지정 호출
  전부(플러그인 review/task 포함)를 깨뜨리고 있었다 — 랩탑 두 config(`~/.codex` + Orca `CODEX_HOME`)는 09-07 에
  `gpt-5.6-sol`/`medium` 으로 교체, CLI 0.147.0 → 0.153.4.

## 설계

### 1. `scripts/codex-review-gate.sh` — 게이트 단일 진입점

```
codex-review-gate.sh --base <ref> | --commit <sha> | --uncommitted  [--model M] [--effort E] [--out <dir>]
```

- 실행: `codex exec review <스코프> -m ${MODEL:-gpt-5.6-sol} -c model_reasoning_effort='"${EFFORT:-medium}"' --ephemeral --json -o <out>/review.md`
  + 절감 오버라이드 `-c web_search='"disabled"' -c memories.generate_memories=false -c hide_agent_reasoning=true`
  + `-c 'mcp_servers.<id>.enabled=false'` 는 레포 `.codex/config.toml` 에 MCP 가 있을 때만(BoDAT 의 adspower).
- 판정 매핑: 리뷰 본문의 `[P1]` → **BLOCKER**, `[P2]` → **WARN**, `[P3]`/기타 → **NIT**, 항목 0 → **CLEAN**.
  stdout 마지막 줄에 `verdict=<BLOCKER|WARN|NIT|CLEAN> p1=<n> p2=<n> p3=<n>` 한 줄(호출자가 파싱), 본문은 `<out>/review.md`.
- 종료 코드: 0=CLEAN/NIT/WARN(비차단) · 1=BLOCKER · 2=리뷰 미산출(모델 오류·타임아웃·verdict 없음 → fail-closed) · 64 usage.
- 타임아웃: `CODEX_GATE_TIMEOUT`(기본 900s, `VERIFIER_TIMEOUT_MIN` 과 동조) — 초과면 2.
- 모델 오류(404·"not supported"·"requires a newer version")는 stderr 에 원문 + "`codex debug models` 로 가용 모델 확인" 안내, 2.
- **bash 3.2 · 결정론 · 네트워크는 codex 호출뿐.** `codex` 미설치면 2 + 안내(루프의 general-purpose 폴백 유지).

### 2. 배선

- `skills/verify-runner/SKILL.md` ③-3: `VERIFIER` 스폰 대신 `$SCRIPTS/codex-review-gate.sh --base origin/<default>` 를
  **동기 호출**(백그라운드 스폰·`TaskStop` 데드라인 절차 삭제 — 스크립트가 자체 타임아웃). verdict 줄로 분류,
  `review.md` 를 `검증자 리뷰:` 코멘트 본문에.
  폴백: exit 2 면 기존 `general-purpose` 검증자 경로(유지).
- `skills/closeout/SKILL.md` 1단계(계획 부합 검증): 같은 스크립트를 `--base` 로 + 계획 부합 여부는 커스텀 프롬프트 스코프
  (`codex exec review "<계획 부합 지시>"`)로 한 번 더 — 이건 별 옵션 `--prompt <text>`.
- BoDAT `.claude/skills/full-cycle/SKILL.md` 6절: Codex 절을 스크립트 호출로(별도 BoDAT PR).
- README(영/한) 설치 절: 게이트 스크립트 한 줄 + "`~/.codex/config.toml` 의 `model` 은 반드시 유효 모델로(0.153 은 미설정 시 Astra 기본)".

### 3. 모델 분담(기본값)

| 용도 | 모델 · effort |
|---|---|
| 머지 게이트(BLOCKER 판정) | `gpt-5.6-sol` · medium |
| 보조·커스텀 각도 리뷰 | `gpt-5.6-terra` · medium |
| 구조화 추출(`--output-schema`)·분류 | `gpt-5.6-luna` |
| 대화형 기본(config) | `gpt-5.6-sol` · medium |

### 4. 범위 밖

- Astra 를 게이트에 쓰는 것(비용·usage 실측 없음), `service_tier=fast`(Pro 노출 여부 미확인), `review_model` 키(CLI 적용 여부 미확인).
- 플러그인 `codex-rescue` 문서의 `gpt-5.4-mini` 예시(외부 마켓플레이스 파일).

## 검증

- `scripts/tests/codex-review-gate.test.sh`: `codex` 스텁으로 (a) P1 포함 → exit 1·verdict BLOCKER, (b) P2 만 → 0·WARN,
  (c) 항목 없음 → 0·CLEAN, (d) 모델 오류 문구 → 2, (e) 타임아웃 → 2, (f) codex 부재 → 2. `bin/ci` 등록.

진행 — **응답 계약(구조 줄) 착지 (#207 / PR #216)**. 위 (a)~(f) 는 그대로 두고 판정 입력이 하나
바뀌었다: `--prompt` 호출은 리뷰 본문의 **마지막 줄에 오는 고정 형식 줄**(`<키>: reviewed|no-basis`)
로만 가른다(`reviewed` → 항목 집계대로 · `no-basis`/줄 없음/형식 깨짐 → `verdict=NONE` 미산출 →
SKILL 의 폴백). 형식 문자열의 유일한 정의 자리는 `codex-review-gate.sh` 의 `STATUS_*` 상수이고
프롬프트 계약문과 파서가 **둘 다 그 상수로** 만들어진다(`bin/ci` 가 단일 정의를 검사).

**한국어 산문 정규식은 판정 입력에서 뺐다** — 어형 열거는 닫히지 않아 세 라운드 연속 fail-open 을
냈고(#207 round2~4), 반대 방향으로는 **인용된 문구가 진짜 발견을 지웠다**(실측 2026-09-11: 리뷰
본문이 예시로 적은 `Unable to inspect the repository` 한 줄에 `[P1]` 둘이 통째로 지워졌다).
비계약 경로(`--prompt` 없는 내장 스코프 리뷰 — closeout ① correctness · verify-runner ③)는
프롬프트를 실을 자리가 없어 계약을 요구할 수 없으므로 영문 '도구 부재' 휴리스틱(#137)을 남기되,
같은 오탐을 막으려 **항목이 0일 때만** 본다(항목이 있는 리뷰는 정의상 미산출이 아니다).

**폴백 프롬프트는 별도 파일이다** — `skills/closeout/references/verifier-prompt-fallback.md`.
네이티브 템플릿은 "이 워크트리에서 직접 읽어라" 를 전제하는데 `general-purpose` 폴백은 `--cd` 로
스코프되지 않아 그 전제가 거짓이 된다(엉뚱한 체크아웃을 '최신' 이라 단언한 채 판정). 폴백 쪽은
diff 를 실제로 동봉한다. `bin/ci` 가 SKILL 문서의 지목을 강제한다.

진행 — **판정 창 이동 (#283 / PR #295)**. 위 계약 줄을 읽는 자리가 "파일의 마지막 줄" 에서
**모델 통제 구역의 마지막 줄** 로 옮겨졌다. 발견이 있는 리뷰에서는 `codex exec review` 가 모델 총평 뒤에
자기 렌더 헤더(`RENDER_HEADER_ONE`/`_MANY`, 상수 한 자리 — `bin/ci` 가 문다)와 항목 목록을 덧붙여 파일의
마지막 줄이 늘 codex 의 것이었고, 그래서 BLOCKER·WARN 만 골라 미산출로 떨어졌다(실측 3/3 NONE). 이제 그
헤더가 **CLI 가 쓴 것**(뒤에 항목이 따라오고 · 문서 끝까지 항목/들여쓴 줄뿐이고 · 정확히 하나)일 때만 경계로
잘라 그 앞 구역의 마지막 줄에서 계약 줄을 읽는다. 계약 줄은 **줄 전체**가 그 형식이어야 한다(값 앞뒤 텍스트
불문 미산출 — 어형 허용 목록은 두 회차 만에 fail-open 이 실측돼 버렸다). 실호출 회귀 장치는
`scripts/codex-review-gate-smoke.sh`(네트워크 의존 · `bin/ci` 밖, README 런북). 잔여(비차단, 파생): 펜스·들여쓴
인용 계약 줄이 CLEAN 으로 읽힘(main 과 동일) · 스모크의 헤더 부분 일치/모델 미준수 분류 · 렌더 변형(항목 사이
`---`, 본문 속 펜스)에 ⓑ 가 0 이 돼 NONE.

잔여(비차단): 꼬리 artifact 판정이 **맨몸** 펜스를 여닫이 구분 없이 벗긴다 — 짝 세기로 가르는
축은 파생 이슈.
- 라이브: issue-runner 자신의 머지 커밋 하나로 `--commit` 실행 → verdict 줄 + review.md 생성(#131 과 같은 P1 재현).

## 설치

랩탑은 완료(config 2벌·CLI 0.153.4). 미니: codex 0.142.5(mise) + config 에 model 없음 → 업그레이드 + `model = "gpt-5.6-sol"` 추가 필요
(루프 검증자가 지금 모델 404 로 폴백 중일 가능성).
