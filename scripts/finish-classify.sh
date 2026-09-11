#!/usr/bin/env bash
# finish-classify.sh <repo> <pr> [<issue>]
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
#                  검증 안 됨, #171) → 무접촉(새 판정을 기다림)
#                  또는 **진행 증거가 있음**(#206 — 아래 참조)
#
# **진행 증거 게이트 (#206).** 🔄 계열 두 갈래(stale_inline·stale_reverify)는 "워커가 죽었다"
# 는 주장이다. 그 주장을 내기 전에 `progress-evidence.sh` 에 워커가 살아 있다는 증거가
# 있는지 묻고, 있으면 `active` 로 떨어뜨린다. 증거는 세 가지다 —
#   ① 최신 커밋이 STALL_MIN 이내   ② 그 head SHA 의 CI 티켓이 큐에 살아 있음
#   ③ **현재 회차의 `agent:claimed` 가 ISSUE_TIMEBOX_HOURS 안에 붙어 아직 붙어 있음**
# ②가 특히 중요하다: 박스 전역 직렬 CI 큐(#127) 대기는 워커가 통제할 수 없는 시간이라
# 커밋이 한 시간 넘게 멈춰 있어도 워커는 살아 있다(#200 실측 72분·64분). 술어는
# `progress-evidence.sh` **한 자리**에 있다 — `timebox-check.sh`(#200)가 부르는 그 자리다.
# 두 벌로 복제하면 사람 눈에 안 보이는 두 번째 계산기가 다른 수를 센다.
#
# ③은 **첫 푸시 전 창** 전용이다(#206 attempt 2 codex BLOCKER). ①②는 워커가 이미 뭔가
# 남긴 뒤에만 존재하는 증거라, 반송 직후 교체 워커가 디스패치됐지만 아직 아무것도 push
# 하지 않은 구간에서는 둘 다 없다 — 그때 이 파일이 보는 값(판정 시각·head 시각)은 전부
# **이전 attempt** 의 것이고 `STALE_FINISH_MIN` 을 넘겨 `stale_reverify` 가 난다. 그러면
# `closeout-redispatch` 가 **지금 일하고 있는 워커의 `agent:claimed` 를 떼어낸다.**
# 그 창을 덮는 유일한 신호가 "이번 회차가 언제 시작됐나" = `agent:claimed` 부착 시각이고,
# 조회는 `claim-at.sh` **한 자리**다(존재가 아니라 시각을 쓰는 이유는 그 파일 주석 참조).
#
# 판정 실패(헬퍼가 `unknown` 이거나 아예 못 돔)는 "증거 없음" 이 **아니다** — 그 방향으로
# 접으면 조회 실패 한 번에 살아 있는 워커의 브랜치를 채간다(되돌릴 수 없는 손해). 그래서
# 여기선 증명 실패를 `active`(무접촉) 로 받는다. ✅ 갈래의 fail-closed 와 방향이 반대로
# 보이지만 **같은 원리**다: 되돌릴 수 없는 쪽(머지·재디스패치)을 증명 없이 열지 않는다.
#
# 그 규율은 **판정 입력을 얻는 자리**에서 시작한다(#206 회차2). head 조회는 세 결말을
# 갖는다 — `ok`(값을 얻음) · `unknown`(조회 실패) · `none`(조회는 됐는데 커밋 증거 없음).
# 셋을 `head_sha=none` 하나에 실으면 하류가 실패를 부재로 읽어 살아 있는 워커를
# 재디스패치한다. 그래서 조회의 **종료코드를 보존**해 `head_lookup` 플래그로 기억하고,
# 진행 증거 헬퍼에도 같은 3값 어휘(`--commit-at unknown`)로 넘긴다.
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
#   FC_HEAD_SHA       head 커밋 SHA — pr-head-at.sh --with-sha 실조회 대체(#206 진행 증거 ②).
#                      미지정이면 `none`(큐 증거 없음)으로 본다.
#   FC_QUEUE_LOG      queue.log 경로 — progress-evidence.sh 의 PE_QUEUE_LOG 로 전달(픽스처용).
#   FC_HEAD_AT        head 커밋 시각(ISO8601) — pr-head-at.sh 실조회 대체(주입 = `ok`).
#                      주입 경로는 호출자가 값을 준 것이므로 `unknown`(조회 실패)이 아니다 —
#                      조회 실패 축은 실호출 경로에서만 나고, 테스트도 **실호출 자리를
#                      스텁으로 물려** 문다(주입만 무는 테스트는 그 자리의 회귀에 눈먼다).
#                      빈 값/파싱 불가 = **못 얻음**. 🔄 계열 갈래(#110 스테일 클록)에선
#                      종전대로 epoch 0 으로 degrade 하지만, `✅` 갈래(#171 머지 게이트)
#                      에선 증명 실패이므로 done_verdict 를 내지 않고 active 다.
#   FC_ISSUE          연결 이슈 번호 — 세 번째 위치 인자의 env 판(진행 증거 ③).
#                      둘 다 없으면 `gh pr view --json headRefName,closingIssuesReferences` 로
#                      한 번 묻고, **head 의 `agent/issue-N` 을 1순위**로 브랜치 이슈를 고른다
#                      (`closingIssuesReferences` 는 폴백 — `[0]` 은 닫는 이슈가 둘 이상일 때
#                      남의 이슈를 가리킨다, #206 회차3). 조회 실패·무출력은 `unknown`.
#   FC_CLAIMED_AT     `agent:claimed` 부착 시각(ISO8601) 또는 `none`/`unknown` —
#                      claim-at.sh 실조회 대체. **설정돼 있으면 실조회로 새지 않는다**
#                      (픽스처 테스트의 네트워크 무접속을 이 변수 하나가 지킨다).
#   FC_NOW            현재 epoch(초) — date 대체
#   STALE_FINISH_MIN  시간버퍼(분, 기본 30)
#   ISSUE_TIMEBOX_HOURS  claim 신선도 상한(시간, 기본 1) — progress-evidence.sh 가 읽는다
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 픽스처용 큐 로그 경로는 **있을 때만** 넘긴다 — 기본 경로는 progress-evidence.sh 가
# 이미 갖고 있고, 여기 한 벌 더 적으면 이 PR 이 세운 SSOT 규율과 반대 방향이다.
[ -n "${FC_QUEUE_LOG:-}" ] && export PE_QUEUE_LOG="$FC_QUEUE_LOG"

repo=${1:?repo}
pr=${2:?pr_num}
issue=${3:-${FC_ISSUE:-}}

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

# head_lookup — **조회의 결말을 담는 별도 플래그**(#206 회차2). 값 셋:
#   ok       조회(또는 주입)에 성공 — head_at·head_sha 가 그 PR 의 값이다
#   unknown  조회 **실패** — 값이 있는지조차 모른다(pr-head-at.sh 비0 종료 등)
#   none     조회는 됐는데 커밋 증거가 없음 — 아래 has_progress 의 정규화가 만든다
# 회차1 은 이 셋을 `head_sha=none` 이라는 **공유 센티널 하나**에 실었다. 그러면 하류가
# 실패를 부재로 읽어 살아 있는 워커를 재디스패치한다(PR#168 교훈: 탈출 사유를 별도
# 플래그로 기억하고 하류가 그걸 읽게 하라 · PR#139: 빈 결과와 실패를 구분하라).
# `timebox-check.sh` 가 같은 자리에서 이미 이 형상이다(`branch_lookup_failed` → unknown).
head_lookup=ok
if [ -n "${FC_HEAD_AT+x}" ]; then
  head_at="$FC_HEAD_AT"
  head_sha="${FC_HEAD_SHA:-none}"
else
  # head 시각은 **커밋 목록을 세지 않고** 얻는다(#171 반송 4회차 [P1-1]).
  # `gh pr view --json commits` 는 GraphQL commits(first:100) 이라 101번째부터 안 온다 —
  # 그때 `last` 는 head 가 아니라 100번째 커밋이고, 그 이른 시각으로 비교하면 낡은 ✅ 가
  # `head <= verdict` 를 만족해 done_verdict 가 난다(코멘트 100건 상한과 같은 함정).
  # 조회 로직은 pr-head-at.sh **한 자리**에 있다(사유·계약은 그 파일 주석 참조).
  # 조회 실패는 빈 값으로 떨어뜨린다 — 아래 ✅ 갈래가 "증명 실패 = active" 로 받는다.
  # `--with-sha` 로 **한 번의 조회에서** 시각과 SHA 를 함께 받는다(#206) — SHA 는 진행 증거
  # ②(그 SHA 의 CI 티켓이 큐에 살아 있는가)에 쓴다. 따로 한 번 더 물으면 pr-head-at.sh 가
  # 없애려던 "head 를 묻는 두 자리" 가 되살아난다.
  #
  # **종료코드를 버리지 않는다**(#206 회차2, 회차1 BLOCKER). `|| head_raw=''` 로 rc 를
  # 삼키면 일시적 gh 실패가 "이 PR 엔 커밋이 없다"로 둔갑하고, 아래 진행 증거 게이트가
  # 그 결론으로 **살아 있는 워커의 반송 회차를 재디스패치**한다. pr-head-at.sh 는 단계마다
  # 종료코드를 검사해 하나라도 못 얻으면 exit 1 로 알리도록 이미 설계돼 있다 — 그 신호를
  # 여기서 흘리면 그 설계가 무의미해진다.
  head_rc=0
  head_raw=$("$SCRIPT_DIR/pr-head-at.sh" --with-sha "$repo" "$pr" 2>/dev/null) || head_rc=$?
  if [ "$head_rc" != 0 ]; then
    head_lookup=unknown; head_sha=unknown; head_at=''
  elif [ -n "$head_raw" ]; then
    head_sha="${head_raw%% *}"
    head_at="${head_raw##* }"
  else
    # exit 0 인데 빈 출력 = 헬퍼 계약 위반(열린 PR 에는 반드시 head 커밋이 있다).
    # "커밋이 없다" 로 읽을 수 없으므로 조회 실패와 같게 받는다.
    head_lookup=unknown; head_sha=unknown; head_at=''
  fi
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

verdict_body=$(last_matching "머지 판정" "Merge verdict" body)
verdict_at=$(last_matching "머지 판정" "Merge verdict" createdAt)
head_epoch=$(iso_to_epoch "${head_at:-}")
verdict_epoch=$(iso_to_epoch "$verdict_at")

# ── 최종 판정이 이미 있는 경우(4a) ──
case "$verdict_body" in
  *✅*)
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

# ── 진행 증거 게이트 (#206) ─────────────────────────────────────────────
# `progress-evidence.sh` **한 자리**에 묻는다(#200 이 세운 술어 — timebox-check.sh 가
# 부르는 그 자리). 여기 두 번째 계산기를 만들지 않는다.
#
# 아래 스테일 클록(max_epoch)과 역할이 다르다 — 스테일 클록은 *마지막 워커 활동 이후
# 얼마나 지났나*(#110) 이고, 이 게이트는 *워커가 지금도 진행 중이라는 증거가 있나*(#200)
# 다. 후자만 두 소비자를 갖는 술어라 한 자리로 묶었다.
#
# 반환: 0 = 진행 증거 있음(또는 **판정 불가**) → 살아 있다고 본다. 1 = 증거 없음.
# 판정 불가를 "증거 없음" 으로 접지 않는 이유는 파일 머리 주석 참조(되돌릴 수 없는 쪽을
# 증명 없이 열지 않는다).
# 진행 증거 ③ 의 입력 — 현재 회차의 `agent:claimed` 부착 시각을 헬퍼 어휘로 낸다.
# 세 값 그대로: `<ISO8601>` / `none`(붙어 있지 않음·연결 이슈 없음) / `unknown`(조회 실패).
# **여기서도 실패를 `none` 으로 접지 않는다** — 접으면 조회 실패 한 번이 "이번 회차는 시작된
# 적 없다" 로 둔갑해 살아 있는 워커의 claim 을 떼어낸다(회차1·회차2 BLOCKER 와 같은 가족).
#
# 이 조회는 **🔄 계열 갈래를 내기 직전에만** 돈다(has_progress 안에서 불린다) — 정상 PR 은
# ✅ 갈래에서 이미 빠져나가므로 스윕 한 틱의 gh 호출이 PR 수만큼 늘지 않는다.
claimed_arg() {
  # 주입이 있으면 실조회로 **새지 않는다**. 빈 문자열 주입은 `none` 으로 본다
  # (호출자가 "claim 증거 없음" 을 뜻한 것 — 실패는 `unknown` 이라는 단어로 말한다).
  if [ -n "${FC_CLAIMED_AT+x}" ]; then
    printf '%s' "${FC_CLAIMED_AT:-none}"
    return 0
  fi
  local iss="$issue" meta out rc=0
  if [ -z "$iss" ]; then
    # 연결 이슈를 모르면 한 번 묻는다. **조회 실패와 "연결 이슈 없음" 을 가른다**:
    # 실패는 unknown(판정 불가), 빈 결과는 none(재디스패치할 이슈 자체가 없는 PR).
    #
    # 브랜치 이슈 추정은 **head 의 `agent/issue-N` 이 1순위**이고
    # `closingIssuesReferences` 는 폴백이다(#206 회차3 BLOCKER). 여기서 필요한 것은
    # "이 PR 이 닫는 이슈" 가 아니라 **"이 브랜치의 워커가 집어간 이슈"** 인데, 그 둘은
    # 다른 축이다 — `[0]` 은 GitHub 이 본문의 `Closes` 를 만난 순서일 뿐이라 닫는 이슈가
    # 둘 이상이면 **남의 이슈**를 가리킨다. 이 레포 실데이터:
    #   PR #113  head=agent/issue-109  refs=[108, 109]   ← [0] 은 #108
    #   PR #112  head=session/issues-110-109-108  refs=[108, 109]
    # `[0]` 을 쓰면 그 PR 의 claim 조회가 #108 로 가 `none` 이 나오고, 증거 ③ 이 조용히
    # 꺼져 **지금 일하고 있는 워커**가 `stale_reverify` → 재디스패치된다(워크트리 경합).
    # 레포의 다른 자리가 전부 head 파싱으로 "이 브랜치의 이슈" 를 얻는 것과도 여기서만
    # 어긋나 있었다(closeout SKILL ③단계·`closeout-reconcile.sh:25`·`loop-status.sh:504`).
    # 술어 형태는 `resume-sweep` 쪽(PR #293)과 같은 것을 쓴다 — 두 자리가 어긋나지 않게.
    #
    # 조회는 여전히 **한 번**이다(head 를 같은 응답에서 받는다 — 라운드트립을 늘리지 않는다).
    # `-q` 대신 별도 `jq` 를 쓰는 것은 `claim-at.sh` 와 같은 규율이다: 스텁이 실제 응답
    # JSON 을 내고 술어 자체가 테스트에 물린다(가공된 번호를 주면 어느 술어든 초록이다).
    meta=$(gh pr view "$pr" --repo "$repo" --json headRefName,closingIssuesReferences 2>/dev/null) \
      || { printf 'unknown'; return 0; }
    # exit 0 + 무출력도 조회 실패다 — 빈 응답을 "연결 이슈 없음"(none)으로 접으면 헛돈
    # 조회 한 번이 살아있는 워커의 claim 을 떼는 근거가 된다(PR#139 — 빈 결과와 실패를 가른다).
    [ -n "$meta" ] || { printf 'unknown'; return 0; }
    iss=$(printf '%s' "$meta" | jq -r '
      if ((.headRefName // "") | test("^agent/issue-[0-9]+"))
      then (.headRefName | capture("^agent/issue-(?<n>[0-9]+)").n)
      else ((.closingIssuesReferences // [])
            | if length > 0 then (.[0].number | tostring) else "" end)
      end' 2>/dev/null) || { printf 'unknown'; return 0; }
  fi
  [ -n "$iss" ] || { printf 'none'; return 0; }
  out=$("$SCRIPT_DIR/claim-at.sh" "$repo" "$iss" 2>/dev/null) || rc=$?
  # 비0 종료·무출력(실행 비트 누락 exit 126 포함) = 조회 실패. 빈 값을 `none` 으로
  # 정규화하면 헬퍼가 조용히 degrade 한 것이 증거 부재로 둔갑한다(PR#173 교훈).
  if [ "$rc" != 0 ] || [ -z "$out" ]; then printf 'unknown'; return 0; fi
  printf '%s' "$out"
}

has_progress() {
  local out rc=0
  # 커밋 시각은 **이미 파싱에 성공한 것만** 넘기고, 아니면 헬퍼의 입력 계약대로 문자열
  # `none`(= 커밋 증거 없음)을 **명시**한다. head_epoch 가 비었다는 것은 시각을 못 얻었거나
  # (빈 값) 형식이 아니라는(쓰레기 값) 뜻이고, 이 파일의 🔄 계열 갈래는 그걸 종전부터
  # "커밋 증거 없음(epoch 0 degrade)" 으로 다룬다 — 그대로 넘겨 `unknown` 으로 만들면
  # 쓰레기 값 하나가 모든 갈래를 active 로 덮어 완결 유실 회수가 통째로 멈춘다.
  # 판정 술어는 그대로 헬퍼 한 자리이고, 여기서 하는 것은 그 입력 계약으로의 정규화다.
  # (빈 문자열을 그냥 넘기지 않는 이유: 헬퍼는 빈 값을 `none` 으로 접지 않고 판정 실패로
  #  본다 — 호출자가 "증거 없음" 을 뜻했는지 "못 얻었다" 를 뜻했는지 헬퍼는 모르기 때문.)
  #
  # **조회 실패는 그 셋 중 어느 것도 아니다**(#206 회차2). 헬퍼의 입력 어휘 3값
  # (`<값>`/`none`/`unknown`)에서 `unknown` 으로 넘겨, 판정 불가가 하류까지 그대로
  # 전달되게 한다 — 여기서 `none` 으로 접으면 조회 실패가 "커밋 증거 없음" 이 되어
  # 살아 있는 워커의 반송 회차가 재디스패치된다(회차1 BLOCKER).
  local commit_arg=none sha_arg="${head_sha:-none}"
  if [ "$head_lookup" = unknown ]; then
    commit_arg=unknown; sha_arg=unknown
  elif [ -n "$head_epoch" ]; then
    commit_arg="$head_at"
  fi
  out=$("$SCRIPT_DIR/progress-evidence.sh" --now "$now" \
    --commit-at "$commit_arg" --head-sha "$sha_arg" \
    --claimed-at "$(claimed_arg)" 2>/dev/null) || rc=$?
  case "${out%% *}" in
    progress) return 0 ;;
    none)     [ "$rc" = 0 ] && return 1; return 0 ;;
    *)        return 0 ;;   # unknown·무출력·exec 실패(126/127) = 판정 불가
  esac
}

# 시간버퍼를 넘긴 갈래를 낼 때 진행 증거를 한 번 더 묻는다 — 증거가 있으면 워커는
# 살아 있으므로 `active`.
emit_stale() {  # emit_stale <stale_inline|stale_reverify>
  if has_progress; then echo active; else echo "$1"; fi
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
  if [ "$age" -gt "$stale_sec" ]; then emit_stale stale_reverify; else echo active; fi
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
  if [ "$age" -gt "$stale_sec" ]; then emit_stale stale_inline; else echo active; fi
else
  # 검증자 미해결 BLOCKER — 코드품질 검증 미완. 시간버퍼 초과면 완결 에이전트 재디스패치.
  if [ "$age" -gt "$stale_sec" ]; then emit_stale stale_reverify; else echo active; fi
fi
