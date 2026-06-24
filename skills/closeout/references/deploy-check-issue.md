## 배경
PR #<PR> 머지됨 (HEAD <SHA>). production 배포·검증이 필요하다 (closeout 4단계 — 사람 게이트).

## 변경 요약
<SUMMARY>

## 배포 절차
`<DEPLOY_CMD>` (이 레포의 배포 엔트리포인트)

## 검증 URL
<VERIFY_URL> (production 베이스 URL — 예 `http://bodat.local:3000`. closeout 5단계가 이 URL 로 Chrome 스모크를 몰아 아래 검증 항목을 대조한다.)

## 라이브/하드웨어 검증 항목
<LIVE_CHECKS>

## 완료 처리
배포·검증 후 문제가 있으면 closeout 5단계가 후속 이슈를 발행한다. 이상 없으면 이 이슈를 닫는다.
