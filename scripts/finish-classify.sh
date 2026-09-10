#!/usr/bin/env bash
# finish-classify.sh <repo> <pr>
#
# 완결 유실 갭 판별자 (#88). PR 의 코멘트·타임스탬프·CI 를 읽어 종료 상태를 아래
# 다섯 중 하나로 stdout 에 분류한다 (SKILL ② Maintain 규칙4 가 이 결과로 4a/4b/4c
# 를 분기한다 — SKILL prose 를 얇게 유지하고 결정적으로 테스트 가능하게).
#
#   done_verdict   최신 `머지 판정:` 이 ✅ 이고, **두 시각(판정·head 커밋)을 모두 얻어**
#                  그 판정이 head 커밋보다 늦음(또는 같음)을 증명함
#                  → 4a 무접촉(closeout 픽업 대기)
#   held           최신 `머지 판정:` 이 ⚠            → 4a 무접촉(워커 명시 보류·needs-human)
#   stale_inline   🔄(최종 판정 없음) + 최신 검증자 CLEAN + 그 코멘트가 STALE_FINISH_MIN
#                  초과            → 4b 인라인 최종 판정 대리 append(에이전트 없음)
#   stale_reverify 🔄 + 검증자 부재 또는 미해결 BLOCKER + STALE_FINISH_MIN 초과
#                  → 4c 완결 에이전트 재디스패치(검증자 재실행)
#   active         위 어디에도 안 걸림(진행 중·시간버퍼 미도달·우리 형상 아님) 또는
#                  최신 `머지 판정: ✅` 의 신선도를 **증명하지 못함**(head 커밋보다 이르거나,
#                  두 시각 중 하나라도 못 얻음 — 반송 뒤 재디스패치된 새 커밋이 아직
#                  검증 안 됨, #171) 또는 그 ✅ 를 **더 뒤에 달린 `마감 검증: ⚠ 보류`** 가
#                  가리고 있고 사람이 그 뒤에 보류를 풀었음을 증명 못 함(#174)
#                  → 무접촉(새 판정을 기다림)
#
# 판별 근거: 살아있는 워커는 `검증자 리뷰:` 코멘트 직후 수초 내 최종 판정을 찍는다.
# 최신 검증자가 CLEAN 인데 STALE_FINISH_MIN 넘게 최종 판정이 없으면 워커 사망 확실.
# 진행 중 fix 루프는 최신 검증자 코멘트가 recent 이거나 non-CLEAN 이라 자동 제외된다.
#
# 워커 활동 = 코멘트 **또는 커밋**. bounce 후 attempt N+1 워커는 같은 브랜치에서
# 이어가며 커밋은 하되 종료 직전에만 판정 코멘트를 찍는다 — 코멘트 시각만 보면
# 낡은 🔄 만 남아 살아있는 워커를 사망(stale_reverify)으로 오판한다(#110, 실증
# BodaT PR #2237). head 커밋 시각(FC_HEAD_AT)을 스테일 클록의 max 에 합류시켜 방어한다.
#
# 최신 `머지 판정:`/`검증자 리뷰:` 판정은 코멘트 배열의 **마지막 매칭**을 쓴다
# (재리뷰·재판정 대비). 한/영 병행 워커라 영문 접두(Merge verdict/Verifier review)도 본다.
#
# 테스트/재현용 env 오버라이드 (없으면 gh/date 로 실측):
#   FC_COMMENTS_FILE  코멘트 배열 JSON 이 담긴 **파일 경로** — 대용량 안전 경로(#171
#                      반송 4회차 [P2]). 코멘트 전량을 환경변수 하나로 넘기면 exec 한계
#                      (리눅스 MAX_ARG_STRLEN 128KB)를 넘는 순간 이 스크립트가 **시작조차
#                      못 하고** 호출자의 판정이 비어 그 PR 이 매 스윕에서 조용히 빠진다.
#                      FC_COMMENTS_JSON 보다 우선하며, 읽기 실패는 실조회로 **새지 않고**
#                      빈 코멘트(=active, fail-closed)로 떨어진다.
#   FC_COMMENTS_JSON  코멘트 배열 JSON([{body,createdAt},...]) — 실조회 대체(소용량 픽스처용).
#                      둘 다 미지정 시 pr-comments.sh 로 **페이지네이션 전량** 조회한다
#                      (`gh pr view --json comments` 의 첫 100건 상한 회피, #171).
#   FC_FAILING        실패 체크 수(정수) — statusCheckRollup 대체
#   FC_HEAD_AT        head 커밋 시각(ISO8601) — pr-head-at.sh 실조회 대체.
#                      빈 값/파싱 불가 = **못 얻음**. 🔄 계열 갈래(#110 스테일 클록)에선
#                      종전대로 epoch 0 으로 degrade 하지만, `✅` 갈래(#171 머지 게이트)
#                      에선 증명 실패이므로 done_verdict 를 내지 않고 active 다.
#   FC_HOLD_RELEASED_AT  사람이 사람 몫 사유 라벨(`hold:policy`·`hold:conflict`)을 뗀
#                      최근 시각(ISO8601) —
#                      pr-hold-released-at.sh 실조회 대체. 빈 값/파싱 불가 = **못 얻음**
#                      → 보류가 해소됐음을 증명 못 한 것이므로 held(fail-closed, #174).
#                      미지정 시엔 `마감 검증: ⚠` 가 최신 ✅ 를 가릴 때에만 실조회한다
#                      (흔한 경로에 페이지네이션 호출을 얹지 않는다).
#   FC_NOW            현재 epoch(초) — date 대체
#   STALE_FINISH_MIN  시간버퍼(분, 기본 30)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

repo=${1:?repo}
pr=${2:?pr_num}

stale_min=${STALE_FINISH_MIN:-30}
stale_sec=$((stale_min * 60))
now=${FC_NOW:-$(date -u +%s)}

# ── 입력 수집 (env 오버라이드 우선) ──
if [ -n "${FC_COMMENTS_FILE:-}" ]; then
  # 파일 경로 주입(#171 반송 4회차 [P2]) — 페이지네이션으로 상한이 사라진 코멘트 전량은
  # 환경변수 하나에 담기엔 크다(exec 한계 128KB). 읽기 실패는 **실조회로 새지 않는다**:
  # 호출자가 "이 파일이 곧 판정 입력" 이라고 계약한 이상, 그걸 못 읽었는데 다른 출처로
  # 조용히 갈아타면 어떤 입력으로 판정했는지 알 수 없다 → 빈 코멘트(=active) 로 떨어뜨려
  # 게이트를 닫는다.
  comments=$(cat "$FC_COMMENTS_FILE" 2>/dev/null) || comments=''
elif [ -n "${FC_COMMENTS_JSON:-}" ]; then
  comments="$FC_COMMENTS_JSON"
else
  # 코멘트는 **페이지네이션**해서 전량 읽는다(#171 반송 3회차 [P1-2]).
  # `gh pr view --json comments` 는 첫 100건만 준다 — 반송을 여러 번 도는 PR 은
  # 코멘트가 쉽게 그 상한을 넘고, 그러면 101번째 이후의 새 ✅ 를 못 봐 머지 가능한
  # PR 이 영영 후보에 안 뜨거나(조용한 큐 사망) 101번째 이후의 반송 마커를 놓쳐
  # 반송된 PR 이 통과한다. 조회 로직은 pr-comments.sh **한 자리**에 있다(사유·순서
  # 계약은 그 파일 주석 참조).
  #
  # 조회 실패는 `[]` 로 떨어뜨린다 — 빈 코멘트에는 판정 코멘트가 없으므로 아래 모든
  # 갈래가 active(게이트 닫힘)로 수렴한다. 부분 출력을 정상값으로 채택하지 않는 것이
  # 핵심이다(PR#139 교훈: 빈 결과와 실패를 구분하고, 실패는 가드 분기로 보내라).
  comments=$("$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" 2>/dev/null) || comments=''
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

if [ -n "${FC_HEAD_AT+x}" ]; then
  head_at="$FC_HEAD_AT"
else
  # head 시각은 **커밋 목록을 세지 않고** 얻는다(#171 반송 4회차 [P1-1]).
  # `gh pr view --json commits` 는 GraphQL commits(first:100) 이라 101번째부터 안 온다 —
  # 그때 `last` 는 head 가 아니라 100번째 커밋이고, 그 이른 시각으로 비교하면 낡은 ✅ 가
  # `head <= verdict` 를 만족해 done_verdict 가 난다(코멘트 100건 상한과 같은 함정).
  # 조회 로직은 pr-head-at.sh **한 자리**에 있다(사유·계약은 그 파일 주석 참조).
  # 조회 실패는 빈 값으로 떨어뜨린다 — 아래 ✅ 갈래가 "증명 실패 = active" 로 받는다.
  head_at=$("$SCRIPT_DIR/pr-head-at.sh" "$repo" "$pr" 2>/dev/null) || head_at=''
fi

# ISO8601(...Z) → epoch. BSD(date -j -f) 우선, GNU(date -d) 폴백.
#
# **파싱 전에 형식을 검사한다**(#171 반송 3회차 [P1-1]). GNU 폴백이 있다는 것 자체가
# GNU 박스를 지원 대상으로 삼았다는 뜻인데, 두 구현은 *잘못된 입력*에서 갈린다:
#   BSD `date -j -f "%Y-%m-%dT%H:%M:%SZ" "" +%s` → `illegal time format`, 실패(빈 값)
#   GNU `date -d "" +%s`                        → **실패하지 않고 "오늘 자정" epoch**
# 그래서 형식 검사가 없으면 GNU 박스에서 head 조회가 비었는데도 head_epoch 가 비지
# 않는다 — 자정 이후 찍힌 정상 ✅ 이면 `head <= verdict` 가 참이 돼 done_verdict 가
# 나온다. 아래 ✅ 갈래가 없애려던 fail-open 이 GNU 에서만 되살아나는 것이다.
# (GNU 는 `yesterday`·`now` 같은 느슨한 표현도 받는다 — 빈 문자열만의 문제가 아니다.)
#
# 게이트가 "빈 입력이 유효값으로 둔갑" 을 입구에서 막아야 한다는 게 PR#139 교훈의 3판:
# 저기선 실패가 부분 출력으로, 여기선 **실패조차 안 하고** 그럴듯한 값으로 새어 든다.
# 형식 검사를 앞에 두면 두 date 구현에서 결과가 같아진다(테스트는 GNU 스텁으로 재현).
iso_to_epoch() {
  local iso="${1:-}"
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
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

# 접두 매칭 코멘트의 **마지막 인덱스**(없으면 -1). 선후는 createdAt 이 아니라 배열
# 인덱스로 잰다 — GitHub 코멘트 시각은 초 단위라 같은 초에 달린 두 코멘트의 순서를
# 시각으로는 못 가린다(closeout-eligible 의 반송 마커 안전망과 같은 규율).
last_index() {
  local prefix_ko="$1" prefix_en="$2"
  printf '%s' "$comments" | jq -r --arg pk "$prefix_ko" --arg pe "$prefix_en" '
    ([ to_entries[] | select((.value.body|startswith($pk)) or (.value.body|startswith($pe))) | .key ]
     | last) // -1' 2>/dev/null
}

verdict_body=$(last_matching "머지 판정" "Merge verdict" body)
verdict_at=$(last_matching "머지 판정" "Merge verdict" createdAt)
head_epoch=$(iso_to_epoch "${head_at:-}")
verdict_epoch=$(iso_to_epoch "$verdict_at")

# ── #174: `마감 검증: ⚠ 보류` 가 최신 판정 형식 코멘트인가 ──────────────────
# closeout ③-1 게이트가 BLOCKER 를 내면 `마감 검증: ⚠ 보류` 를 찍고 `closeout-blocked`
# 전이가 `needs-human`+`hold:*` 를 붙인다. 그 보류가 **그 앞의 `머지 판정: ✅` 보다 뒤**면
# 최신 판정은 ✅ 가 아니라 보류다. 사람이 라벨을 떼도 이 코멘트는 남으므로, 코멘트만
# 읽는 판정은 "풀렸는지" 를 알 방법이 없다 — 그래서 아래 ✅ 갈래가 해제 시각을 본다.
#
# 보류가 최신 ✅ 보다 **앞**이면 이미 지나간 보류다(반송 → 재디스패치 → 새 검증 → 새 ✅
# 형상). 그때는 아무것도 가리지 않는다 — 안 그러면 정상 재완결이 영구 억제된다.
closeout_body=$(last_matching "마감 검증" "Closeout verification" body)
closeout_at=$(last_matching "마감 검증" "Closeout verification" createdAt)
closeout_idx=$(last_index "마감 검증" "Closeout verification")
verdict_idx=$(last_index "머지 판정" "Merge verdict")
closeout_hold=0
case "$closeout_body" in
  *⚠*)
    # ⚠ 보류 코멘트가 **있다**는 것까지는 확인된 상태다. 그게 최신 ✅ 를 가리는지는
    # 인덱스 비교로 가르는데, jq 가 실패하면(빈 출력) 그 비교를 못 한다 — 그때는
    # **가린다**(닫는 쪽)로 떨어뜨린다. 이 갈래에서 "모르니까 안 가린다" 로 열면 보류
    # 코멘트가 있는데도 해제 증명 없이 done_verdict 가 나온다(이 PR 이 없애려는 그것).
    # 닫는 쪽 오차의 대가는 한 틱 지연뿐이다(다음 틱이 다시 잰다).
    if [ -z "$closeout_idx" ] || [ -z "$verdict_idx" ]; then
      closeout_hold=1
    elif [ "$closeout_idx" -gt "$verdict_idx" ] 2>/dev/null; then
      closeout_hold=1
    fi
    ;;
esac

# 해제 시각은 **필요할 때만** 조회한다(타임라인은 페이지네이션이라 비싸다).
hold_released_at() {
  if [ -n "${FC_HOLD_RELEASED_AT+x}" ]; then
    printf '%s' "$FC_HOLD_RELEASED_AT"
    return 0
  fi
  "$SCRIPT_DIR/pr-hold-released-at.sh" "$repo" "$pr" 2>/dev/null || return 1
}

# ── 최종 판정이 이미 있는 경우(4a) ──
case "$verdict_body" in
  *✅*)
    # #174 **먼저** — 그 ✅ 를 더 뒤에 달린 `마감 검증: ⚠ 보류` 가 가리고 있으면, 사람이
    # 그 뒤에 보류를 풀었음을 **증명**했을 때만 ✅ 가 살아난다. 두 규칙은 순서대로 걸린다:
    # 여기(보류 해소)를 통과해야 아래(#171 head 대조)로 간다.
    #
    # 게이트 방향은 아래 #171 과 같다 — **증명되지 않으면 열지 않는다.** 해제 시각을 못
    # 얻거나(타임라인 조회 실패·해제 이벤트 없음) 파싱 못 하면 통과시키지 않는다. 조회
    # 실패를 "해제됨" 으로 읽으면 머지 게이트가 사람 판단 없이 열린다.
    #
    # 동초는 "뒤" 가 아니다(`-gt`) — GitHub 시각은 초 단위라 같은 초면 선후를 모른다.
    # 모르는 것은 닫는 쪽으로 떨어뜨린다.
    #
    # **왜 `held` 가 아니라 `active` 인가.** 둘 다 머지 게이트를 닫지만 후속 조치가 다르다:
    # `held` 는 ①-b 스윕에 `closeout-blocked` 전이(= `needs-human`+`hold:*` **부착**)를
    # 시키고, 그 스윕의 대상 필터는 `needs-human` 이 붙은 PR 을 이미 제외한다. 즉 여기서
    # `held` 를 내면 **라벨이 떨어져 있는 PR** 에만 그 전이가 걸린다 — 사람이 방금 뗀
    # 보류를 타임라인 조회 실패 한 번으로 루프가 **다시 붙이는** 경로가 된다(#151 이
    # 금지한 그것, 그리고 이 이슈 「걸러선 안 되는 것」의 거울상).
    # `active` 는 "증명 못 함 → 무접촉, 새 판정을 기다림" 으로 아래 #171 갈래와 뜻이
    # 같고 부작용이 없다. 보류는 그대로 유지되고(머지 안 됨) 다음 틱이 다시 잰다.
    #
    # 루프가 `hold:*` 를 **스스로 떼는 경로는 없다** — 여기서 하는 것은 사람이 뗀 사실을
    # 읽는 것뿐이다. 사람 결정문의 *내용* 판정(재게이트할 것인가)은 closeout SKILL ③-1.
    if [ "$closeout_hold" = 1 ]; then
      released_at=$(hold_released_at) || released_at=''
      released_epoch=$(iso_to_epoch "${released_at:-}")
      closeout_epoch=$(iso_to_epoch "$closeout_at")
      if [ -n "$released_epoch" ] && [ -n "$closeout_epoch" ] \
         && [ "$released_epoch" -gt "$closeout_epoch" ] 2>/dev/null; then
        : # 보류 해소 — 아래 #171 갈래로 이어간다.
      else
        echo active
        exit 0
      fi
    fi

    # #171: ✅ 를 head 커밋과 묶는다. 반송(재디스패치) 뒤 새 커밋이 올라왔는데 그
    # 커밋 **이전**에 찍힌 ✅ 를 근거로 머지 후보 삼지 않는다.
    #
    # 게이트 방향 = **증명되지 않으면 열지 않는다.** 두 시각(판정·head 커밋)을 모두
    # 얻어 `head <= verdict` 를 확인했을 때만 done_verdict 다. 하나라도 못 얻으면
    # (빈 commits·gh 조회 실패·날짜 파싱 실패) 판정이 현재 head 이후임을 *증명하지
    # 못한* 것이므로 active — 워커의 새 판정을 기다린다.
    #
    # 옛 구현은 못 얻은 시각을 `${head_epoch:-0}` 으로 뭉개 done_verdict 로 떨어뜨리고
    # 이를 "degrade, fail-open 아님" 이라 적었다. 그건 틀렸다 — **머지 게이트에서
    # 증명 실패를 통과로 처리하는 것이 곧 fail-open** 이다(PR#139 교훈: 빈 결과와
    # 실패를 구분하라). 🔄 계열 갈래의 epoch-0 degrade 는 그대로 둔다: 거긴 게이트가
    # 아니라 스테일 클록이라 0 이 "더 오래된 활동" 으로 안전하게 흡수된다.
    #
    # 정상 판정은 막지 않는다 — 판정이 head 보다 늦거나 같은 초면 종전대로
    # done_verdict 다(새 보류 상태를 만드는 게 아니다).
    if [ -n "$head_epoch" ] && [ -n "$verdict_epoch" ] \
       && [ "$head_epoch" -le "$verdict_epoch" ] 2>/dev/null; then
      echo done_verdict
    else
      echo active
    fi
    exit 0
    ;;
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

verifier_body=$(last_matching "검증자 리뷰" "Verifier review" body)
verifier_at=$(last_matching "검증자 리뷰" "Verifier review" createdAt)

# 검증자 CLEAN/전건해소 판정 (보수적 — 확실히 깨끗할 때만 인라인 자동 판정 허용).
# 안전 게이트라 애매하면 non-clean 으로 떨어뜨린다(→ 재디스패치=안전). 3중 방어:
#   (1) 명시적 부정문("CLEAN 아님","not clean")은 *CLEAN* 부분매칭에 걸리므로 배제.
#   (2) BLOCKER 언급이 있으면(해소 표기 "BLOCKER 0"/"BLOCKER 없음"/전건해소 제외) 무조건
#       non-clean — 혼합대소문자 부정문("not CLEAN yet, BLOCKER remains")도 이 게이트가 잡는다.
#       주의: 워커 실제 표기 "BLOCKER 없음(게이트 통과)" = 블로커 0 = CLEAN 이므로 해소
#       표기에 포함한다(안 하면 "없음"의 BLOCKER 부분매칭으로 검증된 PR 이 오판된다).
#   (3) 그 다음에야 긍정 CLEAN 토큰을 본다.
is_clean() {
  case "$1" in
    *"CLEAN 아님"*|*"not clean"*|*"NOT CLEAN"*|*"미해결 BLOCKER"*) return 1 ;;
  esac
  case "$1" in
    *"BLOCKER 0"*|*"BLOCKER 없음"*|*"BLOCKER: 없음"*|*"no BLOCKER"*|*"no blocker"*|*전건해소*|*"전건 해소"*|*"all resolved"*) : ;;  # 해소 표기 → 긍정 판정으로
    *BLOCKER*) return 1 ;;                                         # 그 외 BLOCKER 언급 = 미해결
  esac
  case "$1" in
    *CLEAN*|*"BLOCKER 0"*|*"BLOCKER 없음"*|*"BLOCKER: 없음"*|*"no BLOCKER"*|*"no blocker"*|*전건해소*|*"전건 해소"*|*"all resolved"*) return 0 ;;
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

if [ -z "$verifier_body" ]; then
  # 검증자 부재 → 10단계 후 11단계 전 사망 가능. 🔄 판정 코멘트 vs head 커밋 중
  # 더 최신 쪽으로 경과를 잰다(#110 — attempt N+1 워커가 커밋만 하고 아직
  # 판정을 안 찍은 창을 살아있음으로 인정).
  ref_epoch_nv=$(max_epoch "$verdict_epoch" "$head_epoch")
  age=$((now - ${ref_epoch_nv:-$now}))
  if [ "$age" -gt "$stale_sec" ]; then echo stale_reverify; else echo active; fi
  exit 0
fi

# 스테일 클록 = 가장 최신 워커 활동(검증자 시각 vs 이후 재-🔄 판정 시각 vs head 커밋
# 시각). 검증자 CLEAN 뒤에 워커가 다시 🔄 를 찍고(재수정 루프) 새 검증자를 아직 안
# 올린 경우, 최신 판정은 여전히 🔄 라 이 분기로 오는데 검증자 시각만 보면 살아있는
# 워커를 사망으로 오판한다 → verdict_epoch 와의 max 로 방어. head 커밋도 같은 이유로
# 합류(#110) — 검증자 CLEAN 뒤 워커가 커밋만 이어가고 아직 재-🔄 를 안 찍은 창도
# 살아있음으로 인정해야 stale_inline 인라인 대리 판정이 덮치지 않는다.
verifier_epoch=$(iso_to_epoch "$verifier_at")
ref_epoch=$(max_epoch "$verifier_epoch" "$verdict_epoch")
ref_epoch=$(max_epoch "$ref_epoch" "$head_epoch")
age=$((now - ${ref_epoch:-$now}))
if is_clean "$verifier_body"; then
  # 검증자 CLEAN — 최종 판정만 유실. 시간버퍼 초과면 인라인 대리 판정.
  if [ "$age" -gt "$stale_sec" ]; then echo stale_inline; else echo active; fi
else
  # 검증자 미해결 BLOCKER — 코드품질 검증 미완. 시간버퍼 초과면 완결 에이전트 재디스패치.
  if [ "$age" -gt "$stale_sec" ]; then echo stale_reverify; else echo active; fi
fi
