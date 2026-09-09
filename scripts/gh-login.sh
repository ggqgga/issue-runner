#!/usr/bin/env bash
# gh-login.sh — 현재 gh 계정 로그인명을 stdout 으로 낸다. 실패하면 아무것도 안 내고 exit 1.
#
# 왜 공유 헬퍼인가 (#131): reconcile.sh·eligible-issues.sh·claim-issue.sh 가 같은 블록을
# 세 벌 복사해 갖고 있었고, 셋 다 아래 결함을 공유했다.
#   for _cand in "$(gh api user …)" "$(gh api graphql …)"; do …
# `for` 의 단어 목록은 **루프 진입 전에 전부 전개**된다 — REST 가 성공해도 GraphQL 이
# 매번 호출됐다(불필요한 왕복·rate 소모). 순차 폴백으로 바꾼다: REST 결과가 형식 검증을
# 통과하면 GraphQL 은 호출하지 않는다.
#
# 유지되는 계약(폴백 자체는 #130 의 실측 근거로 남긴다):
#   - REST /user 503 부분 장애가 실측된다 → GraphQL viewer 폴백.
#   - gh 는 실패해도 에러 본문을 **stdout** 으로 뱉는다 → 로그인 형식을 반드시 검증한다
#     (안 하면 q=user:{"message":…} 같은 오염된 값이 흘러 422 가 난다).
#   - 3회 재시도(간격 2초). 전부 실패면 fail-loud — 호출자가 자기 문구로 종료한다.
set -uo pipefail

_valid() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'; }

for _try in 1 2 3; do
  cand=$(gh api user -q .login 2>/dev/null)
  if _valid "$cand"; then printf '%s\n' "$cand"; exit 0; fi
  # REST 가 실패했을 때만 GraphQL 로 내려간다.
  cand=$(gh api graphql -f query='{viewer{login}}' --jq .data.viewer.login 2>/dev/null)
  if _valid "$cand"; then printf '%s\n' "$cand"; exit 0; fi
  [ "$_try" = 3 ] || sleep 2
done
exit 1
