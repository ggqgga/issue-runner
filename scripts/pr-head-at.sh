#!/usr/bin/env bash
# pr-head-at.sh [--with-sha] <repo> <pr>
#
# PR **head 커밋**의 시각을 ISO8601(`...Z`) 로 stdout 에 낸다.
# `--with-sha` 를 주면 `<head SHA> <ISO8601>` 두 필드로 낸다(#206) — 진행 증거 ②(그 SHA 의
# CI 티켓이 큐에 살아 있는가, `progress-evidence.sh`)를 물으려면 시각만으로는 부족하고,
# SHA 를 따로 한 번 더 조회하면 이 파일이 없애려던 "두 자리" 가 다시 생긴다. 이미 여기서
# headRefOid 를 받아 쓰고 있으므로 같은 조회의 값을 함께 낼 뿐, 조회 횟수는 그대로다.
# 성공하면 exit 0, 얻지 못하면 **아무것도 안 내고 exit 1**.
#
# 왜 헬퍼가 따로 있나 (#171 반송 4회차 [P1-1]):
#   `gh pr view --json commits` 는 GraphQL `commits(first: 100)` 이라 **첫 100건만** 준다.
#   커밋이 101건 이상인 PR 에서 `.commits | last` 는 head 가 아니라 **100번째 커밋**이고,
#   그 시각은 head 보다 이르다. 그 이른 시각으로 비교하면 낡은 `머지 판정: ✅` 가
#   `head <= verdict` 를 만족해 done_verdict 가 나온다 — 머지 게이트가 증명 없이 열린다.
#   코멘트 100건 상한(pr-comments.sh 주석)과 **완전히 같은 함정**이 커밋 쪽에 있었다.
#
#   그래서 **커밋 목록을 세지 않는다.** head SHA 를 직접 묻고(`--json headRefOid` —
#   closeout-ci-pass.sh:22-23 이 이미 쓰는 관용구) 그 커밋 하나만 조회하면 목록 상한과
#   무관해진다. 페이지 수·커밋 수가 늘어도 답이 안 변한다.
#
# 두 소비자(finish-classify.sh · closeout-eligible.sh)가 **이 한 자리**를 쓴다 — 조회
# 로직을 두 벌 만들면 한쪽만 고쳐질 때 다시 갈린다(#171 개발계획 2항 · pr-comments.sh
# 와 같은 규율).
#
# 실패를 빈 결과로 둔갑시키지 않는다: 단계마다 종료코드와 빈 값을 **따로** 검사하고,
# 하나라도 못 얻으면 exit 1 로 알린다. 호출자는 fail-closed(머지 게이트를 열지 않음)로
# 처리한다(PR#139 교훈: 빈 결과와 실패를 구분하고, 실패는 가드 분기로 보내라).
#
# 범위 메모: 여기서 하는 것은 "head **시각**을 상한 없는 출처에서 얻어라" 까지다.
# 판정 코멘트에 head OID 를 실어 "이 판정이 바로 이 OID 에 대한 것" 을 증명하는 축은
# #175 의 몫이다 — 이 파일이 SHA 를 다룬다고 해서 그 축을 여기로 끌어오지 마라.
set -uo pipefail

with_sha=0
if [ "${1:-}" = "--with-sha" ]; then
  with_sha=1
  shift
fi
repo=${1:?repo}
pr=${2:?pr_num}

raw=$(gh pr view "$pr" --repo "$repo" --json headRefOid 2>/dev/null) || exit 1
[ -n "$raw" ] || exit 1
sha=$(printf '%s' "$raw" | jq -r '.headRefOid // empty' 2>/dev/null) || exit 1
[ -n "$sha" ] || exit 1
# SHA 형태 검사 — 조회 실패·형상 변경이 그럴듯한 문자열로 새어 엉뚱한 API 경로를
# 만들지 않게 한다(iso_to_epoch 의 형식 검사와 같은 취지: 입구에서 막는다).
case "$sha" in
  *[!0-9a-fA-F]*|'') exit 1 ;;
esac

raw=$(gh api "repos/$repo/commits/$sha" 2>/dev/null) || exit 1
[ -n "$raw" ] || exit 1
at=$(printf '%s' "$raw" | jq -r '.commit.committer.date // empty' 2>/dev/null) || exit 1
[ -n "$at" ] || exit 1

if [ "$with_sha" = 1 ]; then
  printf '%s %s\n' "$sha" "$at"
else
  printf '%s\n' "$at"
fi
