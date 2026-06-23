PR #<PR> (<REPO>)의 `git diff <BASE>...HEAD` 가 <PLAN_REF> 를 실제로 구현했는지
검토하라. (1) 계획/수용 기준 대비 미구현·일탈 (2) 범위 초과(요청 안 한 변경)
(3) 과잉 설계. read-only(코드 변경 금지), 한국어, 발견마다 BLOCKER/WARN/NIT 분류.
부합하면 'CLEAN'. <PLAN_REF> 가 비면(단일 이슈) 이슈 수용 기준 + Test plan 을
대조 기준으로 쓰라.
