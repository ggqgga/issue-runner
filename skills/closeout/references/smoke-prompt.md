production 배포 후 UI 회귀를 Chrome 스모크로 대조하라. 배포 이슈 본문의 검증 항목을
한 건씩 chrome-devtools MCP 로 production 을 직접 구동해 통과·실패를 판정한다.

**구동 절차** — chrome-devtools MCP 도구를 ToolSearch 로 로드한 뒤:
1. `navigate_page` 로 베이스 URL `<VERIFY_URL>` 에 진입한다.
2. 아래 검증 항목 각각에 대해 `take_snapshot`/`evaluate_script` 로 화면을 대조해
   항목별 pass/fail 을 산출한다. 항목이 산문("상단 인프라 탭 → /infra 렌더")이면
   LLM 해석으로 대상 경로/요소를 정하고 실제 렌더를 확인한다.
3. 데이터 0 화면은 빈 상태까지만 실증 가능 — 결과에 "구조/빈 상태 확인"과
   "실 데이터 렌더 확인"을 구분 표기한다.

**저하(degrade) — 조용한 skip 금지.** chrome-devtools MCP 도구가 세션에 없거나
(헤드리스/크론 환경) `<VERIFY_URL>` 이 도달 불가면, 스모크를 건너뛰고
`스모크 skip: <사유>` 로 보고한다 (누락 은폐 금지 — 사람-보고 폴백 경로로 넘긴다).

**출력 계약.** 검증 항목별로 한 줄씩 `pass`/`fail`/`skip` 과 근거를 적고, 끝에
요약 `스모크: <통과수>/<전체수> 통과`(또는 `스모크 skip: <사유>`)를 낸다.
read-only — 직접 수정하지 않는다.

--- 검증 URL ---
<VERIFY_URL>

--- 검증 항목 (배포 이슈 `## 라이브/하드웨어 검증 항목`) ---
<LIVE_CHECKS>
