PR #<PR> (<REPO>)의 변경이 <PLAN_REF> 를 실제로 구현했는지 검토하라.
**아래에 diff 와 이슈 본문을 그대로 동봉했으니 gh·git 등 네트워크 명령을 새로
실행하지 말고 이 텍스트만으로 판정하라** (sandbox 에서 원문 fetch 가 막혀도
판정이 가능해야 한다). (1) 계획/수용 기준 대비 미구현·일탈 (2) 범위 초과(요청
안 한 변경) (3) 과잉 설계. read-only(코드 변경 금지), 한국어, 발견마다
BLOCKER/WARN/NIT 분류. 부합하면 'CLEAN'. <PLAN_REF> 가 비면(단일 이슈) 아래
이슈 본문의 수용 기준 + Test plan 을 대조 기준으로 쓰라.

--- diff (`git diff <BASE>...HEAD`) ---
<DIFF>

--- 이슈 본문 ---
<ISSUE_BODY>
