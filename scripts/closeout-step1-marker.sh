#!/usr/bin/env bash
# closeout-step1-marker.sh <repo> <pr>
#
# 질문 하나에만 답한다: **이 PR 의 ③-1(1단계 마감 검증)을 건너뛰어도 되는가.**
#
#   stdout `skip`   exit 0  건너뛴다 — `마감 검증: ✅` 코멘트가 있고, 그것이 ⑴ **현재 head
#                           커밋보다 늦고** ⑵ 원장의 **최신 반송 마커보다 뒤**다
#   stdout `verify` exit 0  1단계를 **수행한다** — 마커가 없거나, `✅` 가 아니거나(예
#                           `마감 검증: ⚠ 보류`), 현재 head 보다 이르거나, 반송보다 앞이다
#   무출력          exit 1  판정 못 함(코멘트·head 조회 실패, 시각 파싱 실패, 인자 누락)
#
# 호출자 계약: **출력이 정확히 `skip` 일 때만 1단계를 건너뛴다.** `verify` 와 exit 1 은
# 같은 방향(수행)이다 — 건너뛰어도 된다는 것을 *증명하지 못한* 상태를 건너뜀으로 처리하면
# 그게 fail-open 이다(PR#139 교훈). 1단계 재수행의 대가는 검증자 호출 한 번이고, 건너뜀의
# 대가는 **검증 안 된 head 가 2단계 머지 게이트를 통과하는 것**이라 비대칭이다.
#
# ── 왜 이 판정이 따로 필요한가 (#271) ────────────────────────────────────
# 옛 마커표는 1단계를 "`마감 검증:` 코멘트가 있으면 건너뜀" 한 줄로 적었다. 그 전제는
# **세 방향으로 거짓일 수 있다** — 셋 다 결말이 같다(방금 BLOCKER 를 낸 head 가 2단계
# 머지 게이트로 간다. 그 게이트 조건 — CI 캐시 pass · `검증자 리뷰:` BLOCKER 0 ·
# MERGEABLE — 은 반송 직전 상태 그대로 전부 참이다):
#
#   (A) **가장 늦은** `마감 검증:` 이 `⚠ 보류` 다. ③-1 ⓑ 가 남긴 보류 코멘트도 접두가
#       같아 마커표에 걸린다. 사람이 보류를 풀어 돌아온 PR 이 이번 틱에 BLOCKER 를 받고
#       ⓐ 로 갔는데 **반송 코멘트 게시가 실패하면**(SKILL.md ③-1 ⓐ 의 "코멘트가 비0이면
#       전이를 하지 마라" 갈래) 원장에 이번 회차 흔적이 0 이라 다음 틱 `bounce-state.sh`
#       는 `ok` 를 낸다. 그러면 옛 `⚠ 보류` 가 1단계 마커 노릇을 해 ③-1 을 건너뛴다.
#       `⚠ 보류` 는 1단계를 **통과하지 못했다**는 기록이므로 애초에 완료 마커가 아니다.
#       그리고 ✅ 의 *존재*가 아니라 **가장 늦은 것**을 봐야 한다 — `✅ → ⚠` 순서면 ✅ 가
#       살아 있는 게 아니라 더 늦은 ⚠ 이 그것을 덮은 것이다(#218 attempt 3 과 같은 함정).
#   (B) 마커가 현재 head 보다 이르다. rebase·사람 푸시로 head 가 바뀌면 그 마커는 옛
#       코드에 대한 판정이다(✅ 에 적용하던 #171 규칙을 1단계 마커에도 그대로).
#   (C) 마커가 최신 반송 마커보다 앞이다. 반송 뒤 교체 워커가 **새 커밋 없이** ✅ 만
#       찍으면 head 시각이 그대로라 (B) 로는 안 걸린다 — 반송 선후가 따로 필요하다.
#
# (B) 하나만으로는 (A)·(C) 가 안 닫힌다(실측: (A) 는 head T0 < 마커 T1 이라 (B) 기준으로
# **신선**하고, (C) 도 새 커밋이 없어 head 시각이 그대로다). 그래서 세 조건은 AND 다.
#
# ── env 오버라이드(테스트·호출자 재사용) ────────────────────────────────
#   STEP1_COMMENTS_FILE   코멘트 배열 JSON(`[{body,createdAt},...]`)이 담긴 **파일 경로**
#                         (`pr-comments.sh` 출력 형상). 읽기 실패·빈 파일은 실조회로 새지
#                         않고 exit 1 이다 — 코멘트 0건은 `[]` 라 빈 파일과 구분된다.
#   STEP1_HEAD_AT         head 커밋 시각(ISO8601 `...Z`) — `pr-head-at.sh` 실조회 대체.
#   STEP1_BOUNCE_INDEX    최신 반송 마커 인덱스(정수) 또는 `none`
#                         — `bounce-state.sh --marker-index` 실조회 대체.
#
# 조회 순서는 **코멘트 → head** 다(#171). head 를 먼저 뜨면 그 사이의 push 가 `head_at`
# 에 안 잡혀 검증 안 된 head 가 `skip` 으로 나간다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

repo=${1:-}
pr=${2:-}
[ -n "$repo" ] && [ -n "$pr" ] || exit 1

tmpf=$(mktemp) || exit 1
trap 'rm -f "$tmpf"' EXIT

# ── ① 코멘트 전량 ───────────────────────────────────────────────────────
# 조회 로직은 `pr-comments.sh` 한 자리다(`gh pr view --json comments` 의 첫 100건 상한을
# 피하는 이유·계약은 그 파일 주석 참조). 마커가 101번째 이후면 이 판정이 통째로 눈이 먼다.
if [ -n "${STEP1_COMMENTS_FILE:-}" ]; then
  cat "$STEP1_COMMENTS_FILE" > "$tmpf" 2>/dev/null || exit 1
else
  "$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" > "$tmpf" 2>/dev/null || exit 1
fi
[ -s "$tmpf" ] || exit 1

# ── ② head 커밋 시각 ───────────────────────────────────────────────────
if [ -n "${STEP1_HEAD_AT:-}" ]; then
  head_at="$STEP1_HEAD_AT"
else
  head_at=$("$SCRIPT_DIR/pr-head-at.sh" "$repo" "$pr" 2>/dev/null) || exit 1
fi
[ -n "$head_at" ] || exit 1

# ── ③ 최신 반송 마커 인덱스 ────────────────────────────────────────────
# 마커 집합·매칭 규칙은 `bounce-state.sh` **한 자리**다 — 여기 베끼면 새 반송 어휘가
# 늘 때 한쪽만 고쳐져 fail-open 이 된다(#171). 이미 읽은 코멘트를 그대로 먹여 gh 중복
# 조회를 피한다.
if [ -n "${STEP1_BOUNCE_INDEX:-}" ]; then
  bi="$STEP1_BOUNCE_INDEX"
else
  bi=$(BOUNCE_COMMENTS_FILE="$tmpf" "$SCRIPT_DIR/bounce-state.sh" --marker-index "$repo" "$pr" 2>/dev/null) || exit 1
fi
case "$bi" in
  none) ;;
  ''|*[!0-9]*) exit 1 ;;
esac

# ── ④ 판정 ─────────────────────────────────────────────────────────────
# 시각 비교는 `date` 가 아니라 jq 의 `fromdateiso8601` 로 한다 — BSD/GNU `date` 는 **잘못된
# 입력에서 갈린다**(GNU 는 빈 문자열을 "오늘 자정" 으로 받아 실패조차 안 한다, finish-classify.sh
# 의 iso_to_epoch 주석). 형식 검사를 앞에 두어 두 구현의 차이 자체를 없앤다: 형상이 어긋나면
# null → `fail` → exit 1(증명 실패)이지, 그럴듯한 값으로 새지 않는다.
out=$(jq -r --arg head_at "$head_at" --arg bi "$bi" '
  def iso:
    if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    then fromdateiso8601 else null end;
  ($head_at | iso) as $h
  # 1단계 **완료** 마커는 `마감 검증: ✅` 뿐이다 — `⚠ 보류`(③-1 ⓑ)는 1단계를 통과하지
  # 못했다는 기록이라 완료 마커가 아니다(위 (A)).
  # **가장 늦은 `마감 검증:` 이 이긴다** — ✅ 의 *존재*만 보면 그 뒤에 더 늦은 `⚠ 보류`
  # 가 있어도 못 본다(#218 attempt 3 이 `bounce-state.sh` 에서 밟은 바로 그 함정: 존재
  # 검사가 먼저 참이 되어 뒤의 분기에 도달하지 못한다). 그래서 접두 `마감 검증` 전체에서
  # 마지막 인덱스를 잡고, **그것이 `✅` 일 때만** 완료 마커로 인정한다.
  | ([ to_entries[] | select(.value.body | startswith("마감 검증")) | .key ] | last) as $si
  | if $si == null then "verify"
    elif ((.[$si].body | startswith("마감 검증: ✅")) | not) then "verify"   # MUT-A: (A) ⚠ 보류
    elif ($bi != "none" and $si < ($bi | tonumber)) then "verify"   # MUT-C: (C) 반송보다 앞
    else ((.[$si].createdAt) | iso) as $m
      | if $h == null or $m == null then "fail"
        elif $h <= $m then "skip"                                   # MUT-B: (B) head 신선도
        else "verify"
        end
    end' "$tmpf" 2>/dev/null) || exit 1

case "$out" in
  skip|verify) printf '%s\n' "$out" ;;
  *) exit 1 ;;
esac
