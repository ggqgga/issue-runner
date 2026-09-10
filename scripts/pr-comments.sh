#!/usr/bin/env bash
# pr-comments.sh <repo> <pr>
#
# PR 의 이슈 코멘트 **전량**을 `[{body,createdAt},...]` JSON 배열로 stdout 에 낸다.
# 성공하면 exit 0(코멘트 0건이면 `[]`), 조회·파싱이 실패하면 **아무것도 안 내고 exit 1**.
#
# 왜 헬퍼가 따로 있나 (#171 반송 3회차 [P1-2]):
#   `gh pr view --json comments` 는 **페이지네이션 없이 첫 100건만** 준다. 이 상한은 이
#   레포가 이미 아는 함정이다 — loop-status.sh 는 홀드 마커 조회에서 `length >= 100` 을
#   `capped`(모른다)로 따로 가른다(scripts/loop-status.sh:738, 픽스처는
#   scripts/tests/loop-status.test.sh:267). 머지 게이트(finish-classify·closeout-eligible)는
#   `모른다`로 끝낼 수 없다 — 두 방향 모두 조용히 틀린다:
#     · 새 커밋 + 새 `머지 판정: ✅` 가 101번째 이후 → 첫 100건의 **낡은 ✅** 만 보여
#       계속 active → 머지 가능한 PR 이 영영 후보에 안 뜬다(조용한 큐 사망).
#     · 반송 마커(`재디스패치:`·`재검증 실패:`)가 101번째 이후 → 안전망에서 누락돼
#       반송된 PR 이 통과한다.
#   반송을 여러 번 도는 PR 은 워커·verify·closeout 코멘트가 겹겹이 쌓여 100건이 먼
#   숫자가 아니다. 그래서 상한 대신 **페이지네이션**으로 전량을 읽는다.
#
# 두 소비자(finish-classify.sh · closeout-eligible.sh)가 **이 한 자리**를 쓴다 — 조회
# 로직을 두 벌 만들면 한쪽만 고쳐질 때 다시 갈린다(#171 개발계획 2항).
#
# 순서 계약: REST `issues/{n}/comments` 는 기본이 created 오름차순이고 여기서 명시로
# 고정한다. 하류(closeout-eligible 의 반송 마커 안전망)가 **배열 인덱스**로 ✅/마커의
# 선후를 재기 때문에 순서가 곧 의미다(코멘트 시각은 초 단위라 동초 선후를 못 가린다).
#
# 실패를 빈 결과로 둔갑시키지 않는다: `--paginate` 중간 페이지가 실패하면 gh 는 부분
# 출력을 낸 채 비정상 종료한다. 그 부분 출력을 정상값으로 채택하면 "뒤쪽 코멘트가
# 없다" 로 읽혀 가드가 통째로 우회된다(PR#139 교훈). 그래서 비정상 종료면 출력을
# 통째로 버리고 exit 1 로 알린다 — 호출자가 fail-closed 로 처리한다.
set -uo pipefail

repo=${1:?repo}
pr=${2:?pr_num}

raw=$(gh api "repos/$repo/issues/$pr/comments?per_page=100&sort=created&direction=asc" \
  --paginate --jq '.[] | {body: (.body // ""), createdAt: (.created_at // "")}' 2>/dev/null) \
  || exit 1

# 페이지마다 적용된 --jq 결과는 줄줄이 오브젝트다 → 하나의 배열로 슬러프.
# 코멘트 0건이면 raw 가 빈 문자열이고 jq -s 는 `[]` 를 낸다(정상 — 실패와 구분된다).
printf '%s\n' "$raw" | jq -s -c '.' 2>/dev/null || exit 1
