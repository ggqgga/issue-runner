#!/usr/bin/env bash
# bounce-state.sh <repo> <pr>
#
# 질문 하나에만 답한다: **이 PR 은 지금 반송(bounce) 회차 안인가.**
#
#   stdout `ok`      exit 0  반송 마커가 없거나, 그 뒤에 새 `머지 판정: ✅` 가 찍혔다
#                            → 마감 레인(closeout)이 만져도 된다
#   stdout `bounced` exit 0  최신 반송 마커가 최신 ✅ 보다 뒤고, 그 마커보다 뒤에 새
#                            `머지 판정: ⚠ 보류` 도 없다 → **워커 레인 소유**. closeout
#                            은 무접촉이어야 한다
#   stdout `held`    exit 0  최신 반송 마커보다 **뒤에** 새 `머지 판정: ⚠ 보류` 가
#                            찍혔다(#218 attempt 2 — codex BLOCKER: 반송을 무조건 조기
#                            종료하면 반송 뒤 워커가 명시적으로 올린 보류 신호가 묻힌다)
#                            → closeout 이 needs-human 으로 승격해야 한다(finish-classify
#                            의 `held` 행과 같은 조치). `stale_reverify`/`stale_inline` 은
#                            이 값으로 승격하지 않는다 — 살아있는 교체 워커와 충돌하는
#                            건 재디스패치 쪽이라 그 갈래는 계속 막는 게 안전하다.
#   무출력           exit 1  판정 못 함(코멘트 조회·파싱 실패·인자 누락)
#
# 호출자 계약은 두 줄이다 — **출력이 정확히 `ok` 일 때만 정상 진행**하고, `held` 은
# needs-human 으로 갈라라. 판정 실패(exit 1)와 `bounced` 를 같은 방향(무접촉)으로 받는
# 것이 fail-closed 다: 반송되지 않았음을 *증명하지 못한* 상태를 통과로 처리하면 그게
# fail-open 이다(PR#139 교훈 — 빈 결과와 실패를 구분하고, 실패는 가드 분기로 보내라).
#
# ── 왜 스크립트로 뽑았나 (#196) ──────────────────────────────────────────
# 소비자가 둘이고 실행 주체가 다르다:
#   1. `closeout-eligible.sh` — ✅ 정상 후보 필터의 마지막 관문(셸에서 호출)
#   2. `skills/closeout/SKILL.md` ①-b 의 **CONFLICTING 입양** 경로 — 프로즈가 이 스크립트를
#      직접 부른다. ①-b 는 `finish-classify.sh` 를 일부러 건너뛰므로(다른 갈래가 적용
#      안 됨) 반송 판정만 따로 빌릴 자리가 필요했다.
# `finish-classify.sh` 에 출력 하나를 더 얹는 길도 있었지만 택하지 않았다 — 거기 다섯
# 출력은 "완결 유실 상태" 라는 한 축의 값이고, 반송 여부는 **직교하는 다른 축**이다.
# 한 stdout 에 두 축을 섞으면 소비자가 문자열로 축을 다시 갈라야 한다(PR#168 교훈:
# 사유가 여럿인데 공유 센티널 하나만 보면 조용히 오분류된다). 그래서 축마다 한 자리다.
#
# 반대로 **마커 집합과 선후 판정은 절대 두 벌로 두지 않는다** — 예전에 채널마다 가드를
# 베껴 한쪽(verify-runner 채널)이 빠진 채 fail-open 이었다(#171). 그 한 자리가 여기다.
#
# ── env 오버라이드 ──────────────────────────────────────────────────────
#   BOUNCE_COMMENTS_FILE  코멘트 배열 JSON(`[{body,createdAt},...]`)이 담긴 **파일 경로**.
#                         이미 코멘트를 읽은 호출자가 중복 gh 조회를 피하는 통로
#                         (finish-classify 의 FC_COMMENTS_FILE 과 같은 계약: 파일인 이유는
#                         전량 코멘트가 exec 인자 한계 128KB 를 넘을 수 있어서다).
#                         읽기 실패·빈 파일은 **실조회로 새지 않고** exit 1 이다 — 호출자가
#                         "이 파일이 곧 판정 입력" 이라 계약한 이상 다른 출처로 조용히
#                         갈아타면 무엇으로 판정했는지 알 수 없다. 코멘트 0건은 `[]` 로
#                         오며, 그건 정상 판정(`ok`)이라 빈 문자열과 구분한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

repo=${1:-}
pr=${2:-}
[ -n "$repo" ] && [ -n "$pr" ] || exit 1

# ── 반송(bounce) 마커 집합 — 한 자리 (#171 · #196) ──────────────────────
# PR 을 워커에게 되돌리는 채널이 둘이고, 각자 자기 어휘로 코멘트를 남긴다:
#   `재디스패치:`   closeout 마감 검증 BLOCKER·완결 유실 반송 (skills/closeout/SKILL.md)
#   `재검증 실패:`  verify-runner 재검증 반려          (skills/verify-runner/SKILL.md)
# 두 채널의 효과는 같다 — 교체 워커가 새 커밋을 올리기 전까지 head 가 그대로라, 그
# 이전에 찍힌 ✅ 가 살아 남아 "방금 반려된 PR" 을 머지·입양 후보로 만든다. 그래서
# **한 집합**으로 다룬다. 새 반송 어휘가 늘면 **이 배열 한 곳만** 고쳐라 — 채널마다
# 가드를 베끼면 하나 빠진 채로 fail-open 이 된다(실제로 verify-runner 채널이 그렇게
# 빠져 있었다). 두 마커 모두 한/영 SKILL 이 같은 한글 문자열을 찍는다(SKILL.en.md 도
# 동일) — 영문 변종이 생기면 여기에 함께 넣는다.
BOUNCE_MARKERS='["재디스패치:","재검증 실패:"]'

# ── 입력 수집 ───────────────────────────────────────────────────────────
if [ -n "${BOUNCE_COMMENTS_FILE:-}" ]; then
  comments=$(cat "$BOUNCE_COMMENTS_FILE" 2>/dev/null) || exit 1
else
  # 코멘트는 **페이지네이션 전량**으로 읽는다(#171 [P1-2] · #173).
  # `gh pr view --json comments` 는 첫 100건만 준다 — 반송을 여러 번 도는 PR 은
  # 워커·verify·closeout 코멘트가 겹겹이 쌓여 100건이 먼 숫자가 아니고, 마커가
  # 101번째 이후면 안전망이 통째로 눈이 먼다. 조회 로직은 pr-comments.sh 한 자리다.
  # 조회 실패(exit 1)는 그대로 전파한다 — 부분 출력을 정상값으로 채택하지 않는다.
  comments=$("$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" 2>/dev/null) || exit 1
fi
# 빈 문자열 = 입력을 못 받음(≠ 코멘트 0건 `[]`). 판정하지 않는다.
[ -n "$comments" ] || exit 1

# ── 선후 판정 ───────────────────────────────────────────────────────────
# 선후는 **코멘트 배열의 마지막 매칭 인덱스**로 잰다 — createdAt 이 아니라.
# GitHub 코멘트 시각은 초 단위라 ✅ 직후 같은 초에 반송 마커가 달리면 두 값이 같아져
# 시각 비교(`>`)가 거짓이 되고 반송된 PR 이 통과한다. 반대로 같은 초에 마커 뒤 새 ✅ 가
# 달린 정상 재완결은 통과해야 하므로, 단순 시각 비교로는 양방향을 못 가린다. 코멘트
# 배열은 GitHub 이 생성 순으로 주므로(pr-comments.sh 의 순서 계약) 인덱스가 그 순서를
# 그대로 담는다 — 초 단위로 뭉개지지 않는 유일한 값(PR#168 교훈: 정보를 담을 수 있는
# 값으로 바꿔라).
#
# 대조 대상을 `머지 판정: ✅` 로 **좁게** 잡는 것은 의도다. 이슈 #196 이 적은 판별식은
# "판정성 코멘트(머지 판정·검증자 리뷰·재검증 실패·재디스패치) 중 마지막이 반송
# 마커면 워커 레인 소유" 인데, 그 넓은 집합으로 재면 반송 **뒤에 달린 🔄·검증자 리뷰**
# (= 교체 워커가 지금 일하는 중이라는 가장 강한 증거)가 반송을 덮어 `ok` 가 된다.
# ✅ 하나만 반송을 해제하게 두면 두 형상 모두 안전한 쪽으로 떨어진다 — 사고 재현
# 픽스처(✅ 0건)도 종전 규약(반송 뒤 새 ✅ 면 복귀)도 같은 식으로 맞는다.
#
# ── held(#218 attempt 2) ──────────────────────────────────────────────
# attempt 1 은 `bi > vi`(✅ 없음 포함)를 전부 `bounced` 하나로 묶어 무조건 조기
# 종료했다 — codex BLOCKER: 반송 뒤 교체 워커가 명시적으로 올린 `머지 판정: ⚠ 보류`
# 조차 영원히 안 보여 needs-human 승격이 묻힌다("Moving the bounce gate ahead of all
# classification permanently excludes... a later ⚠ verdict never becomes held").
# ✅ 와 대칭으로 ⚠ 도 **같은 인덱스 규칙**(마지막 매칭, createdAt 아님)으로 잰다 —
# `bi < hi`(반송 마커보다 ⚠ 가 뒤)면 "반송 직후" 가 아니라 "반송 뒤 활동이 쌓인
# 상태" 다. 단, `held` 은 `ok` 가 아니다 — 마감 레인이 `stale_reverify` 재디스패치로
# 새지 않도록 호출자가 별도로 갈라야 한다(살아있는 교체 워커와 충돌하는 건
# 재디스패치 쪽이지 needs-human 쪽이 아니다). `bi`·`vi`·`hi` 모두 같은 배열에서 나온
# 인덱스라 새 술어를 만드는 게 아니라 bounce-state 자신의 판정 규칙을 ⚠ 에도 그대로
# 적용하는 것뿐이다.
state=$(printf '%s' "$comments" | jq -r --argjson bm "$BOUNCE_MARKERS" '
  [.[].body] as $bodies
  | ([ $bodies | to_entries[]
       | select(.value as $x | ($bm | any(. as $m | $x | startswith($m))))
       | .key ] | last) as $bi
  | ([ $bodies | to_entries[]
       | select(.value | startswith("머지 판정: ✅") or startswith("Merge verdict: ✅"))
       | .key ] | last) as $vi
  | ([ $bodies | to_entries[]
       | select(.value | startswith("머지 판정: ⚠") or startswith("Merge verdict: ⚠"))
       | .key ] | last) as $hi
  | if   $bi == null then "ok"
    elif $vi != null and $bi <= $vi then "ok"
    elif $hi != null and $hi > $bi then "held"
    else "bounced" end' 2>/dev/null) || exit 1

# jq 가 성공해도 형상이 어긋나면(빈 출력·예상 밖 값) 판정으로 인정하지 않는다.
case "$state" in
  ok|bounced|held) printf '%s\n' "$state" ;;
  *) exit 1 ;;
esac
