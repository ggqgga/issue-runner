#!/usr/bin/env bash
# 계정 전체에서 디스패치 가능한 이슈를 우선순위 정렬 JSON 배열로 출력.
# 자격: open + agent-ready + ¬agent:claimed + ¬needs-human + ¬hold:*(접두, #242) +
#       모든 블로커가 CLOSED (블로커 = 본문 "Blocked by #N" 라인의 N ∪ blocked-by:<N> 라벨의 N, OR·dedupe)
# 정렬: **P0 먼저, 나머지는 생성순(created asc = FIFO)** — 키는 `(priority, createdAt)` 둘뿐이다.
#       우선순위 축은 `P0`(장애·차단) 과 그 밖(P1·라벨 없음·과도기의 잔여 P2) 둘뿐이다 (#401).
#       폐지된 것: `P2` 등급 · 시작한 에픽의 leaf 를 같은 P 안에서 먼저 집던 finish-first 정렬
#       (#257) 과 그 입력이던 **에픽 시작 집합**(진행 중 leaf 스캔 + 최근 닫힌 leaf 검색 한 번).
#       근거(사용자 결정 2026-09-13): P 등급이 실제로는 뒤죽박죽이라 정렬 신호가 못 되고,
#       "우선순위가 같으면 FIFO" 면 순서가 재현 가능해진다. 에픽은 **라벨 부착 규약**이지
#       정렬 키가 아니다 — leaf 는 에픽과 같은 P 를 달 뿐 순서에서 따로 앞서지 않는다.
# `Epic #N` 줄: 이슈 본문 **줄 시작**(앞 공백 허용)의 `epic\s+#N`(대소문자 무시)의 첫 매치 하나
#       (이슈당 에픽 하나). 산문 속 `… epic #N …` 은 줄 시작이 아니라 안 잡힌다.
#       이 줄은 **loop-issues 생성 모드·closeout 파생 발행이 쓴다**(그쪽이 붙이고 여기가 읽는다).
#       같은 판정을 `scripts/loop-status.sh` 의 `epic_of`(#260)와 `scripts/epic-sweep.sh`(#313)가
#       jq `capture` 로 갖고 있다 — **계산기가 셋**이다. 하나만 고치면 후보 `epic` 필드·대시보드
#       에픽 절·에픽 종결 스윕이 조용히 갈린다(셋 다 고쳐라. 갈리면 테스트 Ⓔ⑧ 가 전수로 빨개진다).
#       여기서 이 줄은 **출력 필드 `epic` 를 채울 뿐 정렬에 쓰이지 않는다** (#401 로 에픽 축 폐지).
# 주의: search API는 인덱스 지연이 있다 — 최종 재확인은 claim-issue.sh가 직접 API로 한다.
#
# 출력 갈래 (#247) — 두 스트림이 섞이지 않는다:
#   · **stdout = 후보 JSON 배열 하나뿐.** 디스패처 파이프라인이 이걸 SSOT 로 읽으므로
#     어떤 진단도 stdout 으로 새면 안 된다(한 바이트도 더하지 않는다).
#   · stderr = 진단. 게이트에 탈락한 이슈마다 `blocked: <owner/repo>#<num> ← #<b>(<상태>)`,
#     스캔 끝에 `blocked-summary: 막힘 N건 (사람 게이트 블로커 M건)`, 검색 창 경고는 `warn: `.
#     본문 조회가 실패한 후보는 `막힘`(= OPEN 블로커 탈락) 이 아니라 `warn: ` 한 줄로
#     말하고 그 후보만 이번 틱에서 빠진다(스캔 끝에 `warn: 본문 조회 실패 N건`) —
#     한 건의 조회 실패가 목록 전체를 버리지 않는다.
#     ④ Report 가 이 셋을 그대로 옮긴다(SKILL.md ③-2 · ④) — 게이트 탈락이 조용히
#     `continue` 로 빠지면 "15개 놀고 있는데 루프가 멍때린다" 로만 보인다.
set -euo pipefail

# 사용자 확인은 공유 헬퍼(gh-login.sh) (#131) — REST /user 503 폴백·형식 검증·재시도는
# 그 안. 빈/오염된 me 로 빈 큐를 위장하지 않는다(fail-loud).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$("$SCRIPT_DIR/gh-login.sh") || me=""
if [ -z "$me" ]; then
  echo "eligible-issues: GitHub 사용자 확인 실패 (REST /user·GraphQL viewer 모두 응답 없음)" >&2
  exit 1
fi

# 세션 레포 스코프 (#40): 실행 cwd 의 .loop/repos 가 있으면 그 목록(owner/repo,
# 줄당 하나, # 주석·빈 줄 허용)의 레포만 처리한다. 없으면 계정 전체(기존 동작).
# shellcheck source=scripts/lib/scope.sh
. "$SCRIPT_DIR/lib/scope.sh"   # in_scope · scope_file 기본값 — 판정은 한 자리 (#427)

# needs-human 은 서버 쿼리에서도 제외 — 클라이언트 필터만 쓰면 needs-human 이슈가
# per_page=50 창을 채워 실제 eligible 이슈가 밀려날 수 있다
# 주의: gh search CLI 사용 금지 — 쿼리 문자열 내 부정 라벨(`label:X -label:Y`)을
# 라벨명 하나("X -label:Y")로 오파싱해 항상 0건이 된다 (이슈 #21, GH_DEBUG=api 실측).
# REST search/issues 직접 호출만 정상 동작. 출력은 기존 gh search --json 형태와
# 동일하게 변환해 이후 파이프라인(repository.nameWithOwner/labels[].name/createdAt) 무수정.
# sort=created·order=asc — 최종 정렬(sort_by)은 아래서 하지만, 후보가 한 페이지를 넘으면
# "어떤 것이 어느 페이지에 담기는지"가 정렬 없인 best-match(관련도) 순 = 임의가 되어
# 페이지를 이어 받아도 같은 이슈가 두 장에 겹치거나 어느 장에도 안 담길 수 있다.
# 페이지 경계 자체를 오래된 순으로 고정한다.
#
# 창 상한은 여기 한 자리에만 둔다 (#247·#277). 막힌 이슈도 `agent-ready` 를 달고 창을
# 차지하므로(파생 이슈는 블로커가 있어도 agent-ready 한 벌로 발행한다) 후보가 한 페이지를
# 넘는 일이 상시다 — 넘으면 `sort=created asc` 라 **가장 새 이슈부터** 조용히 안 보인다.
# 그래서 한 장으로 끝내지 않고 `page=2,3,…` 을 **이어 받아 합친다** (#277 실측: 후보 53건 >
# 창 50 에서 가장 새 3건이 사라졌다 — PR #273 검증 틱 stderr).
#
#   SEARCH_WINDOW      한 페이지(`per_page`)
#   SEARCH_MAX_PAGES   이어 받을 최대 페이지 수
#   SEARCH_CAP         그 곱 = **실질 상한**. 손실이 시작되는 선은 이제 여기다.
#   SEARCH_CAP_SOFT    상한의 80% — 임박 경고선.
#
# 상한까지 와도 total_count 가 더 크면 **조용히 자르지 않는다** — 기존 절단 warn 을 그대로
# 낸다(이 레포의 `assert_list_page!`·`each_remote_page` 와 같은 자세). 임박 warn 도 이제
# 페이지 하나가 아니라 이 실질 상한을 기준으로 말한다: `47/50` 은 더 이상 손실이 아니고
# (2페이지째가 받아 온다) 그 수를 경고로 계속 찍으면 진짜 상한 신호가 묻힌다.
#
# 두 상수는 env 로 덮을 수 있다 — 테스트 격자가 250건 픽스처 없이 경계 산술을 물기 위한
# 이음매다(`CLAIM_STALE_WAIT`·`HOLD_NOTE_MAX` 와 같은 관행). 숫자가 아니면 기본값으로
# 되돌리고, 선행 0 은 8진수로 읽히지 않게 10진수로 정규화한다.
SEARCH_WINDOW=${ELIGIBLE_SEARCH_WINDOW:-50}
SEARCH_MAX_PAGES=${ELIGIBLE_SEARCH_MAX_PAGES:-5}
case "$SEARCH_WINDOW" in ''|*[!0-9]*) SEARCH_WINDOW=50 ;; *) SEARCH_WINDOW=$((10#$SEARCH_WINDOW)) ;; esac
case "$SEARCH_MAX_PAGES" in ''|*[!0-9]*) SEARCH_MAX_PAGES=5 ;; *) SEARCH_MAX_PAGES=$((10#$SEARCH_MAX_PAGES)) ;; esac
[ "$SEARCH_WINDOW" -ge 1 ] || SEARCH_WINDOW=50
# search API 의 per_page 상한은 100 이다 — 넘기면 1페이지부터 422 로 틱이 죽으므로 여기서 깎는다.
[ "$SEARCH_WINDOW" -le 100 ] || SEARCH_WINDOW=100
[ "$SEARCH_MAX_PAGES" -ge 1 ] || SEARCH_MAX_PAGES=5
SEARCH_CAP=$((SEARCH_WINDOW * SEARCH_MAX_PAGES))
SEARCH_CAP_SOFT=$((SEARCH_CAP * 4 / 5))
# 상한이 아주 작으면 80% 가 0 으로 깎여 후보 1건에도 임박 warn 이 상시 뜬다 — 그 자리에선
# 임박선을 상한과 같게 둬 절단 갈래에만 맡긴다(경고가 늘 켜져 있으면 신호가 아니다).
[ "$SEARCH_CAP_SOFT" -ge 1 ] || SEARCH_CAP_SOFT="$SEARCH_CAP"

# 페이지 하나를 받는다. `--paginate` 는 쓰지 않는다 — `--jq` 없이 쓰면 페이지 배열을
# **병합**해 형상이 달라지고(이 레포 실측 교훈), total_count 기준으로 몇 장을 받을지도
# 우리가 정해야 한다. 페이지 번호만 바꿔 같은 쿼리를 명시적으로 이어 받는다.
# `body` 는 **투영에 싣지 않는다**. #257 이 에픽 시작 집합 (a) 의 입력으로 실었다가 #401 로
# 그 집합이 통째로 사라졌다 — 본문이 필요한 자리는 후보 루프의 블로커 파싱뿐이고 거기선
# 이미 `gh issue view --json body` 로 건별 조회한다(호출 수 변화 0). 되살리면 페이로드가
# 21배로 뛰어 아래 페이지 병합이 ARG_MAX 근처로 돌아간다(그 자리 주석 참조).
search_page() {  # search_page <페이지> → {total_count, items}
  gh api -X GET search/issues \
    -f q="user:$me is:open is:issue label:agent-ready -label:needs-human" \
    -f per_page="$SEARCH_WINDOW" -f sort=created -f order=asc -f page="$1" \
    -q '{total_count: .total_count, items: [.items[] | {repository: {nameWithOwner: (.repository_url | sub(".*/repos/"; ""))}, number, title, labels: [.labels[] | {name}], createdAt: .created_at}]}'
}

# 1페이지 실패도 아래 2페이지 이후와 **같은 자세**로 말한다 — 어느 페이지에서 끊겼는지가
# 로그에 남아야 "큐가 조용한" 틱과 "조회가 죽은" 틱이 구분된다.
if ! resp=$(search_page 1 2>&1); then
  echo "eligible-issues: 검색 page=1 조회 실패 — 후보 목록 없이 진행하지 않는다(이번 틱 중단): $resp" >&2
  exit 1
fi
cands=$(printf '%s' "$resp" | jq -c '.items')
total=$(printf '%s' "$resp" | jq -r '.total_count')

case "$total" in
  ''|*[!0-9]*)
    # total_count 를 못 읽었다 — 창 상태 **미상**이다. 빈 결과·실패를 정상으로 둔갑시키지
    # 않는다(PR#139): 침묵은 "창에 여유가 있다"는 주장이라 여기선 거짓말이 된다.
    # 읽은 값은 한 줄로 접어 싣는다 — ④ Report 가 옮기는 warn 은 **한 줄**이어야 한다.
    # 몇 장을 더 받아야 하는지도 미상이므로 1페이지로 끝낸다(근거 없는 추가 호출 금지).
    echo "warn: 검색 창 크기 미상 — total_count 를 못 읽었다(창 절단 여부 판정 불가): [$(printf '%s' "$total" | tr '\n' ' ')]" >&2 ;;
  *)
    # 다음 페이지를 이어 받는다 — 상한까지, 그리고 받은 페이지 수가 total 을 덮을 때까지.
    # 후보가 창 안이면 이 루프는 **한 바퀴도 안 돈다** = 호출 1회 그대로(틱 비용 회귀).
    page=1
    while [ "$page" -lt "$SEARCH_MAX_PAGES" ] && [ $((page * SEARCH_WINDOW)) -lt "$total" ]; do
      page=$((page + 1))
      # 조회 실패를 부분 목록으로 둔갑시키지 않는다(PR#139: 빈 결과 ≠ 실패). 조용히
      # 1페이지만 들고 가면 이 스크립트가 고치려던 드롭이 그대로 재현되므로, 1페이지
      # 실패와 같은 자세로 이번 틱을 접는다(다음 틱 재시도).
      if ! presp=$(search_page "$page" 2>&1); then
        echo "eligible-issues: 검색 page=$page 조회 실패 — 부분 후보 목록을 정상으로 쓰지 않는다(이번 틱 중단): $presp" >&2
        exit 1
      fi
      pitems=$(printf '%s' "$presp" | jq -c '.items' 2>/dev/null) || pitems=""
      case "$pitems" in
        '['*) ;;
        *)
          echo "eligible-issues: 검색 page=$page 응답 형식 미상 — 부분 후보 목록을 정상으로 쓰지 않는다(이번 틱 중단): $presp" >&2
          exit 1 ;;
      esac
      # 빈 페이지 = 서버가 더 줄 게 없다는 뜻(total_count 와 실제 페이지가 어긋나는 search
      # 인덱스 지연에서 난다). 무한 루프 대신 멈추되 **조용히 멈추지는 않는다** — 여기서
      # 침묵하면 total 이 상한 이하라 절단 warn 도 안 나고, 이 스크립트가 없애려던 바로 그
      # "조용한 드롭"(받은 만큼만 들고 가기)이 그대로 재현된다.
      if [ "$(printf '%s' "$pitems" | jq 'length')" -eq 0 ]; then
        echo "warn: 검색 page=$page 가 비었다 — total_count ${total}건 중 $(printf '%s' "$cands" | jq 'length')건만 받았다(search 인덱스 지연 · 다음 틱 재시도)" >&2
        break
      fi
      # 페이지 간 겹침·누락은 손대지 않는다 — `created asc` 라 페이지 경계에서 목록이 바뀌면
      # 같은 후보가 두 장에 실리거나(겹침) 경계 앞 이슈가 어느 장에도 안 실린다(누락).
      # 겹침의 중복 디스패치는 claim-issue.sh 의 원자적 잠금(#108)이 막고, 누락은 다음 틱에
      # 회복된다(검색은 매 틱 새로 돈다). 여기서 dedupe 로 지우면 total 대조가 흔들려 경고가
      # 거짓말을 하므로, 받은 그대로 합친다.
      # 합치는 경로는 **argv 를 안 탄다**. `--argjson` 은 누적 배열을 통째로 커맨드라인
      # 인자로 실어 ARG_MAX(macOS 1048576 — 인자+환경 합산)에 걸린다. #257 이 투영에 `body` 를
      # 실었을 때 페이로드가 **21배**였다(실측: 한 페이지 50건이 body 없이 6941 bytes →
      # body 포함 152441 bytes). 기본 상수(50 × 5 = 250)의 마지막 병합이 상한의
      # **78%**(820452/1042968)를 쓰고, 건당 본문 평균이 **4020 bytes** 를 넘으면 그 자리에서
      # `Argument list too long` 으로 **디스패치가 통째로 멈췄다**. #401 이 `body` 를 투영에서
      # 빼 그 여유는 돌아왔지만 **경로는 그대로 둔다** — 제목이 길거나
      # `ELIGIBLE_SEARCH_MAX_PAGES`(#315) 를 크게 덮으면 같은 벽에 닿는다. 이 레포는 같은 실패를 `scripts/loop-status.sh:601-604`
      # 에서 이미 겪고 파일 경유(`--slurpfile`)로 막아 뒀다 — 여기선 stdin 으로 막는다.
      # stdin 엔 그 상한이 없다: 두 JSON 값을 이어 흘려 `-s` 로 슬러프해 잇는다(형상 동일).
      cands=$(printf '%s\n%s\n' "$cands" "$pitems" | jq -c -s 'add')
    done

    if [ "$total" -gt "$SEARCH_CAP" ]; then
      echo "warn: 검색 창 절단 — agent-ready 후보 ${total}건 > 창 $SEARCH_CAP(페이지 $SEARCH_MAX_PAGES × $SEARCH_WINDOW), 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)" >&2
    elif [ "$total" -gt "$SEARCH_CAP_SOFT" ]; then
      echo "warn: 검색 창 임박 $total/$SEARCH_CAP" >&2
    fi ;;
esac

# 블로커 조회는 상태와 라벨을 **한 호출**로 받는다 (#247) — 라벨은 탈락 사유(`<상태>`)를
# stderr 에 적기 위한 것이라, 이것 때문에 gh 호출 수가 늘면 안 된다(틱 비용). 구분자는
# 탭이다(GitHub 라벨명에는 탭이 없다).
TAB=$(printf '\t')
BLOCKER_Q='.state + "\t" + ([.labels[].name] | join(","))'

# 블로커의 라벨 → 사람이 읽는 한 낱말 — **`loop-status.sh` 의 버킷 표시 이름과 같은 낱말**이다
# (#276: "누가 들고 있나" — `X대기` 는 그 루프가 집기 전, 루프 이름은 그 루프가 들고 있음.
# 두 스크립트가 같은 라벨을 다른 이름으로 부르면 `막힘: #N ← #M(<상태>)` 이 대시보드의 줄
# 이름과 안 맞는다). 사다리 뒤 단계가 이긴다(사람 몫 게이트가 최우선 —
# 사람이 답해야 풀리는 게이트라 하위가 영원히 대기한다). 그다음이 기계 정지(`hold:*`)인
# `보류` (#244) — 기계 정지가 `needs-human` 을 떼고 사유 라벨만 남기게 된 뒤로, 이 줄이
# 없으면 홀드된 블로커가 `대기`(= 곧 집힐 것)로 읽혀 하위가 왜 안 풀리는지 안 보인다.
# `hold:conflict` 는 **누가 들고 있느냐로 갈린다**(#345/#346): 단독이면 창 뒤 재개 스윕이
# `CONFLICT_RESUME_LIMIT` 회 되돌리는 기계 정지라 `보류`(루프가 푼다), `needs-human` 이 겹쳐
# 있거나 사람이 `full-cycle` 로 인수했으면 `needs-human`(사람이 푼다). 옛 정의(#244 — "충돌은
# 그 자체가 사람 몫") 는 #344/#345 로 사유가 갈리기 전의 것이다. `loop-status.sh` 의 needs-human
# 버킷(`needs-human` ∪ (`hold:conflict` ∧ `full-cycle`))과 같은 집합이어야 한다 — 갈리면 같은
# 라벨을 두 스크립트가 다르게 읽고, 막힌 하위가 아래 `blocked_human` 카운트에서 빠지거나
# (거꾸로) 루프가 곧 풀 건이 사람 게이트 경보로 울린다. 그래서 `full-cycle` 판별을 **일반
# `hold:*` 보다 앞**에 둔다 — `case` 는 첫 일치가 이기므로 순서가 판정의 전부다.
# `테스트`(배포 뒤 검증, e2e-test 가 비운다)·`deploy-wait`(배포대기)도 사람 게이트다(#431) —
# `loop-status.sh` 가 이 둘을 needs-human 바로 뒤·`hold:*` 앞 버킷으로 두고, 블로커 warn
# `블로커 배포대기 …` 도 `human_wait ∪ test_wait ∪ deploy_wait` 로 묶는다. 갈래가 없으면
# `대기`(= 곧 집힐 것)로 찍혀 대시보드의 `배포대기` 줄과 어긋나고, 아래 `blocked_human`
# 카운트(같은 집합)에서도 빠진다.
# 순서는 loop-status 의 버킷 우선순위와 같다:
#   needs-human > 테스트 > 배포대기 > 보류 > 단계 라벨(뒤가 이김) > 대기.
blocker_state_of() {  # blocker_state_of <콤마로 이은 라벨 목록>
  case ",$1," in
    *",needs-human,"*)   printf 'needs-human' ;;
    # 사람이 `full-cycle` 로 인수한 충돌만 사람 몫이다(#345). 단독 `hold:conflict` 는 창 뒤 재개
    # 스윕이 1회 되돌리는 **기계 정지**라 아래 일반 `hold:*` 갈래(보류)로 떨어진다 —
    # `loop-status.sh` 의 needs-human 버킷 정의와 같은 집합이어야 한다.
    *",hold:conflict,"*) case ",$1," in *",full-cycle,"*) printf 'needs-human' ;; *) printf '보류' ;; esac ;;
    *",테스트,"*)         printf '테스트' ;;
    *",deploy-wait,"*)   printf '배포대기' ;;
    *",hold:"*)          printf '보류' ;;
    *",harvesting,"*)    printf 'closeout' ;;
    *",flow:ready,"*)    printf '마감대기' ;;
    *",verifying,"*)     printf 'verify-runner' ;;
    *",flow:verify,"*)   printf '검증대기' ;;
    *",agent:claimed,"*) printf 'issue-runner' ;;
    *)                   printf '대기' ;;
  esac
}

# ── `Epic #N` 파싱 ────────────────────────────────────────────────────────
# 후보 row 의 출력 필드 `epic` 를 채운다. **정렬에는 쓰이지 않는다** — #257 의 finish-first
# (시작한 에픽의 leaf 를 같은 P 안에서 먼저 집어 주제를 끝내던 정렬)와 그 입력이던 에픽 시작
# 집합(진행 중 leaf 스캔 · 최근 닫힌 leaf 검색 한 번 · `epic_started` 필드)은 #401 로 통째로
# 폐지됐다 — 우선순위가 같으면 FIFO 로 족하다는 사용자 결정 2026-09-13. 필드를 남기는 이유는
# 대시보드·테스트가 읽을 수 있고 여기서 계산 비용이 0 이기 때문이다.
#
# ★파싱 규칙은 `scripts/loop-status.sh` 의 `epic_of`(#260)·`scripts/epic-sweep.sh`(#313)와
#   **같은 판정**이어야 한다(셋 다):
#   줄 시작(앞 공백 허용)의 `epic\s+#N`, 대소문자 무시, 이슈당 **첫 매치 하나만**.
#   저쪽은 jq `capture("^[[:space:]]*epic[[:space:]]+#(?<n>[0-9]+)"; "i")` 를 줄 단위로 걸고,
#   여기는 같은 문자열을 `grep -oiE` 로 건다(문자 클래스·앵커·대소문자 무시가 동일).
#   **끝 앵커(`$`)는 양쪽 다 없다** — `Epic #12 (읽기 모델)` 같은 꼬리표를 허용하는 현행
#   판정이고, 채택 여부는 #259 범위라 여기서 바꾸지 않는다.
#   블로커 파싱(`^…blocked[- ]by…`)과 같은 자리·같은 방식이다(둘 다 `-o` 로 매치 구간만).
#   마지막 `sed` 는 **선행 0 제거**다(`Epic #007` → `7`). 두 이유가 겹친다: ⑴ 아래
#   `--argjson epic` 이 `007` 을 유효 JSON 으로 못 읽어 jq 가 죽고, 그 대입은 `set -e` 아래라
#   **이슈 한 건의 오타가 디스패치 큐 전체를 멈춘다** ⑵ `loop-status.sh` 는 `tonumber` 로
#   받아 이미 `7` 이라, 안 벗기면 같은 본문에서 두 파일의 **값**이 갈린다(Ⓔ⑧ 의 취지).
epic_of() {  # epic_of <본문> → 에픽 번호(선행 0 없음) 또는 빈 문자열
  printf '%s' "$1" \
    | grep -oiE '^[[:space:]]*epic[[:space:]]+#[0-9]+' \
    | head -n 1 \
    | grep -oE '[0-9]+$' \
    | sed 's/^0*\([0-9]\)/\1/' || true
}

blocked_n=0
blocked_human=0
body_fail_n=0

# 본문 조회의 stderr 는 **따로 받는다**. 아래 블로커 조회는 `2>&1` 로 합치지만 그쪽은
# 성공 출력에 TAB 구분자가 있어 오염을 검사해 걸러낸다(`:284` 부근) — 자유 문자열인
# 본문엔 그런 이음매가 없어서, 합치면 gh 가 성공 경로에서 stderr 로 쓴 한 줄이 본문에
# 섞인 채 아래 `Blocked by #N` 파싱을 타고 **유령 블로커**가 될 수 있다(사전 리뷰 실측:
# 정상 후보가 소리 없이 큐에서 빠졌다 — 이 PR 이 막으려는 결함과 같은 모양). #316(#257)
# 이 합류하면 같은 문자열을 `Epic #N` 파싱이 한 번 더 훑어 표면이 는다.
# mktemp 실패는 틱을 죽이지 않는다 — 싱크만 /dev/null 로 내려가고(오류문 없는 warn)
# 판정 동작은 같다. 다만 그 사실은 `warn:` 한 줄로 말한다 — mktemp 자체의 오류문은
# `warn:` 접두어가 없어 ④ Report 에 안 실리고, 그 뒤 후보별 warn 의 사유가 전부 빈 채로
# 나오는 이유를 리포트만 봐서는 알 수 없다(보조 리뷰 실측). trap 은 mktemp **앞에** 건다(#232 h2 관행).
gh_err=/dev/null
trap '[ "$gh_err" = /dev/null ] || rm -f "$gh_err"' EXIT
if ! gh_err=$(mktemp "${TMPDIR:-/tmp}/eligible-issues-gh-err.XXXXXX" 2>/dev/null); then
  gh_err=/dev/null
  echo "warn: 임시파일 생성 실패(TMPDIR=${TMPDIR:-/tmp}) — 이 틱의 본문 조회 오류문을 못 싣는다(사유 빈 warn 으로 나간다)" >&2
fi

out="[]"
count=$(printf '%s' "$cands" | jq 'length')
i=0
while [ "$i" -lt "$count" ]; do
  row=$(printf '%s' "$cands" | jq -c ".[$i]")
  i=$((i + 1))
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner')
  num=$(printf '%s' "$row" | jq -r '.number')
  # 이어 붙인 라벨 문자열은 **정지 판정에는 쓰지 않는다** (#266 — 위 needs-human·hold:
  # 두 줄은 라벨 배열로 본다). 아래 `agent:claimed`·`flow:*`·`P0` 판정은 이번 범위
  # 밖이라 표현을 그대로 둔다(#277 이 손대지 않기로 한 자리).
  labels=$(printf '%s' "$row" | jq -r '[.labels[].name] | join(",")')

  # 세션 레포 스코프 밖이면 제외 (#40)
  in_scope "$repo" || continue

  # 이미 claim 된 것 제외
  case ",$labels," in *",agent:claimed,"*) continue ;; esac

  # 사람 개입 대기(needs-human) 제외 — 사람이 라벨을 떼기 전에는 재디스패치 금지.
  # 판정은 **라벨 배열**로 한다 (#266) — 다른 세 게이트(claim-issue.sh·verify-eligible.sh·
  # closeout-eligible.sh)와 같은 표현이다. 라벨 목록을 쉼표로 이어 붙인 뒤 `,needs-human,`
  # 를 찾으면, 쉼표를 품은 **한** 라벨(GitHub 은 라벨명에 쉼표를 허용한다 — 예 `a,needs-human`)
  # 이 두 라벨로 쪼개져 정상 후보가 소리 없이 사라진다. 과잉 제외는 원래 결함보다 나쁘다.
  printf '%s' "$row" | jq -L "$SCRIPT_DIR/lib" -e \
    'include "loop"; [.labels[].name] | any(is_human_stop_label)' >/dev/null && continue

  # 기계 정지(hold:*) 제외 (#242) — verify-held·closeout-blocked·runner-held 가 붙이는
  # 정지 사유. #244 로 기계 정지는 이 라벨 **하나만** 달고 오므로 이 필터가 곧 정지의
  # 유일한 방어선이다(1단계 #242 에 적힌 "지금은 쌍이라 무동작" 전제는 이제 깨졌다). held 이슈는
  # `agent-ready` 를 사다리 내내 달고 있어서 `needs-human` 부착이 사유별로 걷히는 순간
  # 이 필터가 없으면 정지된 이슈가 곧바로 재디스패치된다(플랜 Plans/label-taxonomy-cleanup.md 1단계).
  #
  # 판별은 **접두사** `hold:` — 사유가 늘어도(`hold:<새사유>`) 안 깨지고, `hold:` 로
  # **시작하지 않는** 라벨(`holding`·`on-hold`·`area:hold`·`hold-ladder`·`holder:x`)은
  # 걸리지 않는다 — 과잉 제외는 정상 후보를 소리 없이 없애는 방향이라 원래 결함보다 나쁘다.
  # 라벨 경계는 **배열**이지 쉼표가 아니다 (#266): 이어 붙인 문자열에서 `,hold:` 를 찾으면
  # 쉼표를 품은 한 라벨(`x,hold:y`)이 두 라벨로 쪼개져 그 과잉 제외가 실제로 일어난다.
  # 그래서 위 `$labels` join 이 아니라 `$row` 의 라벨 배열에 물어 다른 세 게이트와 같은
  # 표현(`any(startswith("hold:"))`)을 쓴다 — 새 조회는 없다(배열은 이미 받아 뒀다).
  #
  # 서버 쿼리(위 search/issues)는 **일부러 안 건드린다**: `gh` 검색은 부정 라벨을
  # 오파싱하고(#21) `-label:hold:policy` 는 콜론이 둘이라 더 위험하다 — 필터는
  # 클라이언트 쪽에만 둔다(needs-human 의 서버측 제외는 기존 그대로 유지).
  #
  # 해제는 **붙어 있는 정지 라벨을 다** 떼는 것이다 — `hold:*` 만 남아도 후보로
  # 돌아오지 않는다(기계 해제 경로는 이미 둘 다 뗀다: transition.sh `⊘hold`·resume-sweep 재개).
  printf '%s' "$row" | jq -L "$SCRIPT_DIR/lib" -e \
    'include "loop"; [.labels[].name] | any(is_hold_label)' >/dev/null && continue   # 술어는 lib/loop.jq (#426)

  # 검증/마감 레인 이슈 제외 (진행 라벨 미러) — 원 이슈에 flow:verify/verifying/flow:ready/
  # harvesting 이 미러링돼 있으면 구현이 끝나 다운스트림(verify-runner·closeout) 소유다.
  # agent:claimed 가 스윕에 스트립돼도 이 플로우 라벨이 재디스패치를 막는다(중복 워커 방지 +
  # 이슈 리스트 진행 가시화). 반송은 verify-runner 가 flow:verify·verifying 을 떼고
  # agent-ready 만 남기므로 이 필터에 안 걸려 정상 재디스패치된다.
  # `verifying`(#275) = verify-runner 가 **지금 검증 중**(집는 순간 flow:verify 를 이것으로
  # 바꾼다 — harvesting 동형, 이슈에도 미러). 빠지면 검증이 도는 이슈가 여기서 후보로 나가
  # 워커가 다시 붙는다(verify-runner 와 같은 브랜치를 물어뜯음). 이 네 라벨의 집합은
  # `claim-issue.sh` 의 직전 재확인·`release-labels.sh` 의 머지 후 해제와 같아야 한다.
  # 판별은 쉼표 join 이 아니라 라벨 배열이다 — 쉼표를 품은 한 라벨(`x,verifying`)을 두 라벨로
  # 쪼개 과잉 제외하지 않는다(#266, 위 hold:* 게이트와 같은 표현).
  printf '%s' "$row" | jq -L "$SCRIPT_DIR/lib" -e 'include "loop";
    [.labels[].name] | any(is_downstream_label)' \
    >/dev/null && continue

  # 블로커 = 본문 "Blocked by #N" 라인의 N ∪ blocked-by:<N> 라벨의 N (OR·dedupe).
  # ★이 파싱 규칙의 SSOT 는 여기다 — `scripts/loop-status.sh` 의 `막힘` 버킷(#248)이
  #   같은 규칙을 jq 로 옮겨 갖고 있다(그 파일 `blockers_of` 위 주석이 이쪽을 가리킨다).
  #   여기를 고치면 저쪽도 같이 고쳐라 — 안 그러면 디스패치 자격과 대시보드의 `막힘`
  #   표시가 조용히 갈린다(한쪽은 집어가는데 다른 쪽은 막혔다고 그린다).
  # 라벨 방식은 이슈 목록에서 블로킹이 한눈에 보이는 게 요점(#85). 새 search 쿼리를
  # 추가하지 않고 이미 받은 labels 배열에서만 파싱한다(gh search 부정라벨 오파싱 #21).
  # 조회 실패는 **그 후보만** 접는다 — 아래 블로커 조회와 같은 가드 자세다
  # (`if out=$(…); then … else warn fi`). 가드 없이 두면 `set -euo pipefail`(:15)
  # 아래서 단 한 건의 502/403(2차 레이트리밋)이 스크립트를 비0 종료시켜 **앞서 정상
  # 판정한 후보까지 stdout 째로** 버려지고, 디스패처는 그 틱을 "후보 0" 으로 읽는다
  # (창이 250 으로 커진 뒤 호출 수가 5배라 같은 단건 실패 확률에서 틱 사망 확률도 5배).
  # 빈 본문으로 이어 가지 않는다(PR#139: 빈 결과 ≠ 실패) — 본문을 못 읽으면
  # "Blocked by #N" 유무가 **미상**이라, 통과시키면 블로커 0건으로 읽혀 게이트가 증명
  # 없이 열린다. 이번 틱만 후보에서 빼고 다음 틱에 재시도한다(새 종결 상태를 만들지 않는다).
  # 다른 갈래는 두지 않는다 — 블로커 조회의 "미존재 → 게이트 무시(통과)" 는 **블로커**가
  # 사라진 경우라 통과가 안전하지만, 여기서 못 읽은 것은 **후보 자신의 본문**이라 통과는
  # 곧 "블로커 0건" 주장이 된다(증명 없이 게이트를 여는 쪽).
  # 오류문은 여러 줄로 오므로 한 줄로 접는다 — ④ Report 가 옮기는 warn 은 한 줄이다.
  if ! body=$(gh issue view "$num" --repo "$repo" --json body -q '.body // ""' 2>"$gh_err"); then
    # 후행 개행은 `$( )` 가 잘라내고, 남은 줄바꿈은 공백으로 접는다(기존 total_count warn 과 같은 관행).
    gh_msg=$(cat "$gh_err")
    echo "warn: $repo#$num 본문 조회 실패 — 블로커 미상이라 이번 틱 후보에서 제외(다음 틱 재시도): $(printf '%s' "$gh_msg" | tr '\n' ' ')" >&2
    body_fail_n=$((body_fail_n + 1))
    continue
  fi
  # -o 로 "blocked by #N" 매치 구간 자체만 뽑는다(매칭 라인 전체가 아니라) — 매칭
  # 라인 전체를 넘겨서 grep -oE로 다시 훑으면 같은 줄 뒤쪽에 문맥상 언급된 무관한
  # #M(예: 참조 PR)까지 블로커로 오인한다(#1457 실측: "Blocked by #1454 — ... #1446(...)"
  # 한 줄에서 #1446까지 집힘). -o 매치 자체는 "Blocked by #1454"로 끊겨 뒤쪽 무관
  # 언급을 애초에 안 본다.
  body_blockers=$(printf '%s' "$body" \
    | grep -oiE '^[[:space:]]*blocked[- ]by[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+$' || true)
  label_blockers=$(printf '%s' "$row" \
    | jq -r '[.labels[].name | select(startswith("blocked-by:")) | ltrimstr("blocked-by:")] | .[]' \
    2>/dev/null || true)
  blockers=$(printf '%s\n%s\n' "$body_blockers" "$label_blockers" \
    | grep -E '^[0-9]+$' | sort -un || true)

  # 하나라도 OPEN 이면 제외. 모두 CLOSED 면 통과(자동 해제 — 라벨을 사람이 뗄 필요 없음).
  # 블로커 조회 실패는 "진짜 미존재"와 "일시 오류(rate-limit·네트워크·auth)"를 구분한다:
  #   - 미존재(GraphQL "Could not resolve to an issue"): 영구 정체 방지 위해 게이트 무시(통과).
  #   - 그 외 오류: 아직 OPEN 인 블로커를 뚫지 않도록 이번 틱은 blocked 유지(다음 틱 재시도).
  # (2>&1 병합: 성공 시 gh_out=상태+탭+라벨, 실패 시 gh_out=에러문. if 조건이라 set -e 안전.)
  # 첫 OPEN 블로커에서 멈추는 break 는 유지한다 — 막혔다는 사실은 블로커 하나면 족하고,
  # 둘째를 조회하면 호출 수가 는다.
  blocked=false
  blocker_num=""
  blocker_state=""
  for b in $blockers; do
    if gh_out=$(gh issue view "$b" --repo "$repo" --json state,labels -q "$BLOCKER_Q" 2>&1); then
      # 종료코드는 0인데 구분자가 없으면 **값 미상**이다 — 빈/깨진 출력을 유효값으로 받으면
      # (예: 상태를 못 읽었는데 CLOSED 로 읽힘) 게이트가 증명 없이 열린다(PR#139).
      case "$gh_out" in
        *"$TAB"*) ;;
        *)
          echo "warn: $repo#$num blocked-by #$b 조회 형식 미상 — 이번 틱 blocked 유지(재시도): $gh_out" >&2
          blocked=true; blocker_num="$b"; blocker_state="조회오류"; break ;;
      esac
      b_state=${gh_out%%"$TAB"*}
      b_labels=${gh_out#*"$TAB"}
      # 블로커가 PR이면 gh issue view도 조회는 되지만 종료 상태가 CLOSED가 아니라
      # MERGED로 나온다(#1457 실측: #1446은 PR, state=MERGED) — MERGED도 종료로 인정.
      case "$b_state" in
        CLOSED|MERGED) ;;
        *) blocked=true; blocker_num="$b"; blocker_state=$(blocker_state_of "$b_labels"); break ;;
      esac
    elif printf '%s' "$gh_out" | grep -qi 'could not resolve to an issue'; then
      echo "warn: $repo#$num blocked-by #$b 미존재 — 영구 정체 방지 위해 게이트 무시(통과)" >&2
    else
      echo "warn: $repo#$num blocked-by #$b 조회 일시 오류 — 이번 틱 blocked 유지(재시도): $gh_out" >&2
      blocked=true; blocker_num="$b"; blocker_state="조회오류"; break
    fi
  done
  if [ "$blocked" = "true" ]; then
    # 탈락을 말한다 — 조용한 continue 는 ④ Report 를 "신규 0" 한 줄로 만든다(#247).
    echo "blocked: $repo#$num ← #$blocker_num($blocker_state)" >&2
    blocked_n=$((blocked_n + 1))
    # 사람 게이트 = `blocker_state_of` 의 needs-human·테스트·배포대기 — loop-status 의
    # `blocker_human_wait` warn(`human_wait ∪ test_wait ∪ deploy_wait`)과 같은 집합 (#431).
    case "$blocker_state" in
      needs-human|테스트|배포대기) blocked_human=$((blocked_human + 1)) ;;
    esac
    continue
  fi

  # 우선순위는 두 칸뿐이다 (#401): `P0`(장애·차단) → 0, 그 밖은 전부 1.
  # "그 밖" 에는 `P1`·P 라벨 없음과 **재라벨 전 과도기에 남아 있는 `P2`** 가 함께 든다 —
  # P2 를 따로 3번째 칸으로 두면 재라벨이 끝날 때까지 그 이슈들만 큐 꼬리에 눌러앉는다.
  prio=1
  case ",$labels," in
    *",P0,"*) prio=0 ;;
  esac

  # 에픽은 이미 받아 둔 `$body` 에서 읽는다 — `gh issue view` 호출 수 변화 0.
  # 출력 필드일 뿐 정렬 키가 아니다 (#401).
  epic=$(epic_of "$body")

  title=$(printf '%s' "$row" | jq -r '.title')
  created=$(printf '%s' "$row" | jq -r '.createdAt')
  out=$(printf '%s' "$out" | jq -c \
    --arg repo "$repo" --argjson num "$num" --arg title "$title" \
    --argjson prio "$prio" --arg created "$created" \
    --argjson epic "${epic:-null}" \
    '. + [{repo:$repo, number:$num, title:$title, priority:$prio, createdAt:$created,
           epic:$epic}]')
done

# 본문 조회 실패는 `막힘`(= OPEN 블로커 탈락) 이 아니라 warn 이다 — 후보별 한 줄만 두면
# 2차 레이트리밋에서 100줄로 풀려 ④ Report 한 줄 요약에 **숫자로는** 안 남는다. 몇 건이
# 이번 틱 후보에서 빠졌는지 집계 한 줄을 함께 낸다(0 건이면 침묵 — warn 은 이상 신호다).
if [ "$body_fail_n" -gt 0 ]; then
  echo "warn: 본문 조회 실패 ${body_fail_n}건 — 그만큼 이번 틱 후보에서 빠졌다(다음 틱 재시도)" >&2
fi

# 요약은 stderr 로 (stdout 은 후보 JSON 전용). 0 건도 말한다 — 침묵과 "막힌 게 없다"는
# 다른 주장이고, ④ Report 의 `막힘 N` 은 매 틱 숫자가 있어야 읽힌다.
if [ "$blocked_n" = 0 ]; then
  echo "blocked-summary: 막힘 0건" >&2
else
  echo "blocked-summary: 막힘 ${blocked_n}건 (사람 게이트 블로커 ${blocked_human}건)" >&2
fi

# 정렬 키 = (우선순위, 오래된 순) 둘뿐. 같은 P 는 **FIFO**(created asc)고, 에픽 축은 없다 (#401).
# 가운데에 있던 `epic_started`(시작한 에픽 먼저, #257) 칸은 폐지됐다 — 되살리려면 정렬만이
# 아니라 그 입력이던 에픽 시작 집합(닫힌 leaf 검색 한 번 포함)을 통째로 되돌려야 한다.
printf '%s' "$out" | jq 'sort_by(.priority, .createdAt)'
