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
- 라이브: issue-runner 자신의 머지 커밋 하나로 `--commit` 실행 → verdict 줄 + review.md 생성(#131 과 같은 P1 재현).

## 설치

랩탑은 완료(config 2벌·CLI 0.153.4). 미니: codex 0.142.5(mise) + config 에 model 없음 → 업그레이드 + `model = "gpt-5.6-sol"` 추가 필요
(루프 검증자가 지금 모델 404 로 폴백 중일 가능성).
