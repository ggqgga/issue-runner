#!/usr/bin/env bash
# finish-classify.sh <repo> <pr>
#
# 완결 유실 갭 판별자 (#88). PR 의 코멘트·타임스탬프·CI 를 읽어 종료 상태를 아래
# 다섯 중 하나로 stdout 에 분류한다 (SKILL ② Maintain 규칙4 가 이 결과로 4a/4b/4c
# 를 분기한다 — SKILL prose 를 얇게 유지하고 결정적으로 테스트 가능하게).
#
#   done_verdict   최신 `머지 판정:` 이 ✅            → 4a 무접촉(closeout 픽업 대기)
#   held           최신 `머지 판정:` 이 ⚠            → 4a 무접촉(워커 명시 보류·needs-human)
#   stale_inline   🔄(최종 판정 없음) + 최신 검증자 CLEAN + 그 코멘트가 STALE_FINISH_MIN
#                  초과            → 4b 인라인 최종 판정 대리 append(에이전트 없음)
#   stale_reverify 🔄 + 검증자 부재 또는 미해결 BLOCKER + STALE_FINISH_MIN 초과
#                  → 4c 완결 에이전트 재디스패치(검증자 재실행)
#   active         위 어디에도 안 걸림(진행 중·시간버퍼 미도달·우리 형상 아님) → 무접촉
#
# 판별 근거: 살아있는 워커는 `검증자 리뷰:` 코멘트 직후 수초 내 최종 판정을 찍는다.
# 최신 검증자가 CLEAN 인데 STALE_FINISH_MIN 넘게 최종 판정이 없으면 워커 사망 확실.
# 진행 중 fix 루프는 최신 검증자 코멘트가 recent 이거나 non-CLEAN 이라 자동 제외된다.
#
# 최신 `머지 판정:`/`검증자 리뷰:` 판정은 코멘트 배열의 **마지막 매칭**을 쓴다
# (재리뷰·재판정 대비). 한/영 병행 워커라 영문 접두(Merge verdict/Verifier review)도 본다.
#
# 테스트/재현용 env 오버라이드 (없으면 gh/date 로 실측):
#   FC_COMMENTS_JSON  코멘트 배열 JSON([{body,createdAt},...]) — gh 대체
#   FC_FAILING        실패 체크 수(정수) — statusCheckRollup 대체
#   FC_NOW            현재 epoch(초) — date 대체
#   STALE_FINISH_MIN  시간버퍼(분, 기본 30)
set -uo pipefail

repo=${1:?repo}
pr=${2:?pr_num}

stale_min=${STALE_FINISH_MIN:-30}
stale_sec=$((stale_min * 60))
now=${FC_NOW:-$(date -u +%s)}

# ── 입력 수집 (env 오버라이드 우선) ──
if [ -n "${FC_COMMENTS_JSON:-}" ]; then
  comments="$FC_COMMENTS_JSON"
else
  comments=$(gh pr view "$pr" --repo "$repo" --json comments -q '.comments' 2>/dev/null)
fi
[ -n "$comments" ] || comments='[]'

if [ -n "${FC_FAILING:-}" ]; then
  failing="$FC_FAILING"
else
  failing=$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup \
    -q '[.statusCheckRollup[]? | select((.conclusion // .state // "")
        | test("FAILURE|ERROR|CANCELLED|TIMED_OUT"))] | length' 2>/dev/null || echo 0)
fi
[ -n "$failing" ] || failing=0

# ISO8601(...Z) → epoch. BSD(date -j -f) 우선, GNU(date -d) 폴백.
iso_to_epoch() {
  local iso="$1"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  date -u -d "$iso" +%s 2>/dev/null
}

# 접두 매칭 코멘트의 마지막 것에서 필드 추출. $2=body|createdAt.
last_matching() {
  local prefix_ko="$1" prefix_en="$2" field="$3"
  printf '%s' "$comments" | jq -r \
    --arg pk "$prefix_ko" --arg pe "$prefix_en" --arg f "$field" '
    [ .[] | select((.body|startswith($pk)) or (.body|startswith($pe))) ]
    | last | if . == null then "" else .[$f] end'
}

verdict_body=$(last_matching "머지 판정" "Merge verdict" body)

# ── 최종 판정이 이미 있는 경우(4a) ──
case "$verdict_body" in
  *✅*) echo done_verdict; exit 0 ;;
  *⚠*) echo held; exit 0 ;;
esac

# 여기부터: 최종 판정 없음. 🔄 판정 코멘트가 있어야 우리 형상(워커가 10단계 도달).
case "$verdict_body" in
  *🔄*) : ;;
  *) echo active; exit 0 ;;   # 판정 코멘트 자체가 없음 → 너무 이르거나 우리 형상 아님
esac

# CI 실패면 규칙1 대상 → 여기서 완결 판별 안 함(방어적 가드).
if [ "${failing:-0}" -gt 0 ] 2>/dev/null; then
  echo active; exit 0
fi

verdict_at=$(last_matching "머지 판정" "Merge verdict" createdAt)
verifier_body=$(last_matching "검증자 리뷰" "Verifier review" body)
verifier_at=$(last_matching "검증자 리뷰" "Verifier review" createdAt)

# 검증자 CLEAN/전건해소 판정 (보수적 — 확실히 깨끗할 때만 인라인 자동 판정 허용).
# 안전 게이트라 애매하면 non-clean 으로 떨어뜨린다(→ 재디스패치=안전). 부정문
# ("아직 CLEAN 아님", "not clean")은 부분문자열 *CLEAN* 에 걸리므로 먼저 배제한다.
is_clean() {
  case "$1" in
    *"CLEAN 아님"*|*"not clean"*|*"NOT CLEAN"*|*"미해결 BLOCKER"*) return 1 ;;
  esac
  case "$1" in
    *CLEAN*|*"BLOCKER 0"*|*전건해소*|*"전건 해소"*|*"all resolved"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 두 epoch 중 큰 값(가장 최신 워커 활동).
max_epoch() {
  local a="${1:-0}" b="${2:-0}"
  [ -n "$a" ] || a=0
  [ -n "$b" ] || b=0
  if [ "$a" -ge "$b" ]; then echo "$a"; else echo "$b"; fi
}

verdict_epoch=$(iso_to_epoch "$verdict_at")

if [ -z "$verifier_body" ]; then
  # 검증자 부재 → 10단계 후 11단계 전 사망 가능. 🔄 판정 코멘트 기준 경과로 판별.
  age=$((now - ${verdict_epoch:-$now}))
  if [ "$age" -gt "$stale_sec" ]; then echo stale_reverify; else echo active; fi
  exit 0
fi

# 스테일 클록 = 가장 최신 워커 활동(검증자 시각 vs 이후 재-🔄 판정 시각). 검증자
# CLEAN 뒤에 워커가 다시 🔄 를 찍고(재수정 루프) 새 검증자를 아직 안 올린 경우,
# 최신 판정은 여전히 🔄 라 이 분기로 오는데 검증자 시각만 보면 살아있는 워커를
# 사망으로 오판한다 → verdict_epoch 와의 max 로 방어.
verifier_epoch=$(iso_to_epoch "$verifier_at")
ref_epoch=$(max_epoch "$verifier_epoch" "$verdict_epoch")
age=$((now - ${ref_epoch:-$now}))
if is_clean "$verifier_body"; then
  # 검증자 CLEAN — 최종 판정만 유실. 시간버퍼 초과면 인라인 대리 판정.
  if [ "$age" -gt "$stale_sec" ]; then echo stale_inline; else echo active; fi
else
  # 검증자 미해결 BLOCKER — 코드품질 검증 미완. 시간버퍼 초과면 완결 에이전트 재디스패치.
  if [ "$age" -gt "$stale_sec" ]; then echo stale_reverify; else echo active; fi
fi
