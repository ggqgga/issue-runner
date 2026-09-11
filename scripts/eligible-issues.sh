#!/usr/bin/env bash
# 계정 전체에서 디스패치 가능한 이슈를 우선순위 정렬 JSON 배열로 출력.
# 자격: open + agent-ready + ¬agent:claimed + ¬needs-human + ¬hold:*(접두, #242) +
#       모든 블로커가 CLOSED (블로커 = 본문 "Blocked by #N" 라인의 N ∪ blocked-by:<N> 라벨의 N, OR·dedupe)
# 정렬: P0 > P1 > P2 > 없음 → **같은 P 안에서** 시작한 에픽의 leaf 를 먼저(finish-first, #257)
#       → 같은 칸 안에서는 오래된 순. 에픽 축은 **P 경계를 넘지 않는다** — P1 단발 이슈가
#       P2 에픽 leaf 보다 뒤로 가지 않는다(우선순위 상속은 문서 규약 #259 몫이지 여기가 아니다).
# `Epic #N` 줄: 이슈 본문 **줄 시작**(앞 공백 허용)의 `epic\s+#N`(대소문자 무시)의 첫 매치 하나
#       (이슈당 에픽 하나). 산문 속 `… epic #N …` 은 줄 시작이 아니라 안 잡힌다.
#       이 줄은 **loop-issues 생성 모드·closeout 파생 발행이 쓴다**(그쪽이 붙이고 여기가 읽는다).
#       같은 판정을 `scripts/loop-status.sh` 의 `epic_of`(#260)가 jq `capture` 로 갖고 있다 —
#       한쪽만 고치면 디스패치 순서와 대시보드 에픽 절이 조용히 갈린다(둘 다 고쳐라).
# 주의: search API는 인덱스 지연이 있다 — 최종 재확인은 claim-issue.sh가 직접 API로 한다.
#
# 출력 갈래 (#247) — 두 스트림이 섞이지 않는다:
#   · **stdout = 후보 JSON 배열 하나뿐.** 디스패처 파이프라인이 이걸 SSOT 로 읽으므로
#     어떤 진단도 stdout 으로 새면 안 된다(한 바이트도 더하지 않는다).
#   · stderr = 진단. 게이트에 탈락한 이슈마다 `blocked: <owner/repo>#<num> ← #<b>(<상태>)`,
#     스캔 끝에 `blocked-summary: 막힘 N건 (사람대기 블로커 M건)`, 검색 창 경고는 `warn: `.
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
scope_file="$PWD/.loop/repos"
in_scope() {
  [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"
}

# needs-human 은 서버 쿼리에서도 제외 — 클라이언트 필터만 쓰면 needs-human 이슈가
# per_page=50 창을 채워 실제 eligible 이슈가 밀려날 수 있다
# 주의: gh search CLI 사용 금지 — 쿼리 문자열 내 부정 라벨(`label:X -label:Y`)을
# 라벨명 하나("X -label:Y")로 오파싱해 항상 0건이 된다 (이슈 #21, GH_DEBUG=api 실측).
# REST search/issues 직접 호출만 정상 동작. 출력은 기존 gh search --json 형태와
# 동일하게 변환해 이후 파이프라인(repository.nameWithOwner/labels[].name/createdAt) 무수정.
# sort=created·order=asc — 최종 정렬(sort_by)은 아래서 하지만, 후보가 창(SEARCH_WINDOW)을
# 넘으면 "어떤 50개가 창에 담기는지"가 정렬 없인 best-match(관련도) 순 = 임의가 되어
# 오래된 이슈가 창 밖으로 밀릴 수 있다. 창 자체를 오래된 순으로 고정한다.
#
# 창 상한 두 개는 여기 한 자리에만 둔다 (#247). 막힌 이슈도 `agent-ready` 를 달고 창을
# 차지하므로(파생 이슈는 블로커가 있어도 agent-ready 한 벌로 발행한다) 후보가 창을 넘으면
# **가장 새 이슈부터** 조용히 안 보인다 — 그래서 total_count 를 함께 받아 창에 닿기 전
# (SOFT)부터 말한다.
SEARCH_WINDOW=50
SEARCH_WINDOW_SOFT=40

resp=$(gh api -X GET search/issues \
  -f q="user:$me is:open is:issue label:agent-ready -label:needs-human" \
  -f per_page="$SEARCH_WINDOW" -f sort=created -f order=asc \
  -q '{total_count: .total_count, items: [.items[] | {repository: {nameWithOwner: (.repository_url | sub(".*/repos/"; ""))}, number, title, labels: [.labels[] | {name}], createdAt: .created_at, body: (.body // "")}]}')
cands=$(printf '%s' "$resp" | jq -c '.items')
total=$(printf '%s' "$resp" | jq -r '.total_count')

case "$total" in
  ''|*[!0-9]*)
    # total_count 를 못 읽었다 — 창 상태 **미상**이다. 빈 결과·실패를 정상으로 둔갑시키지
    # 않는다(PR#139): 침묵은 "창에 여유가 있다"는 주장이라 여기선 거짓말이 된다.
    # 읽은 값은 한 줄로 접어 싣는다 — ④ Report 가 옮기는 warn 은 **한 줄**이어야 한다.
    echo "warn: 검색 창 크기 미상 — total_count 를 못 읽었다(창 절단 여부 판정 불가): [$(printf '%s' "$total" | tr '\n' ' ')]" >&2 ;;
  *)
    if [ "$total" -gt "$SEARCH_WINDOW" ]; then
      echo "warn: 검색 창 절단 — agent-ready 후보 ${total}건 > 창 $SEARCH_WINDOW, 가장 새 이슈부터 안 보인다(막힌 이슈가 창을 채운다)" >&2
    elif [ "$total" -gt "$SEARCH_WINDOW_SOFT" ]; then
      echo "warn: 검색 창 임박 $total/$SEARCH_WINDOW" >&2
    fi ;;
esac

# 블로커 조회는 상태와 라벨을 **한 호출**로 받는다 (#247) — 라벨은 탈락 사유(`<상태>`)를
# stderr 에 적기 위한 것이라, 이것 때문에 gh 호출 수가 늘면 안 된다(틱 비용). 구분자는
# 탭이다(GitHub 라벨명에는 탭이 없다).
TAB=$(printf '\t')
BLOCKER_Q='.state + "\t" + ([.labels[].name] | join(","))'

# 블로커의 라벨 → 사람이 읽는 한 낱말. 사다리 뒤 단계가 이긴다(needs-human 이 최우선 —
# 사람이 답해야 풀리는 게이트라 하위가 영원히 대기한다).
blocker_state_of() {  # blocker_state_of <콤마로 이은 라벨 목록>
  case ",$1," in
    *",needs-human,"*)   printf '사람대기' ;;
    *",agent:claimed,"*) printf '구현중' ;;
    *",flow:verify,"*)   printf '검증대기' ;;
    *",flow:ready,"*)    printf '마감대기' ;;
    *",harvesting,"*)    printf '마감중' ;;
    *)                   printf '대기' ;;
  esac
}

# ── 에픽 시작 집합 (#257) ──────────────────────────────────────────────────
# finish-first 정렬의 입력. "이미 시작한 에픽"의 leaf 를 같은 P 안에서 먼저 집어
# 주제가 끝나게 한다 — 새 이슈가 진행 중인 주제의 꼬리를 계속 밀어내지 않도록.
#
# ★파싱 규칙은 `scripts/loop-status.sh` 의 `epic_of`(#260)와 **같은 판정**이어야 한다:
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

# 집합 원소는 **same-repo 키** `owner/repo#<에픽번호>` — 레포가 다르면 같은 번호라도 다른 에픽이다.
started_epics=""

# (a) 진행 중인 leaf — 후보 검색 결과(`cands`, 필터 전) 중 진행 라벨이 붙은 row.
#     이 row 들은 아래 후보 루프에서 `continue` 로 빠져 `gh issue view` 를 **안 부른다** →
#     본문은 검색 item 의 `body` 필드를 쓴다(추가 gh 호출 0).
#
#     ⚠ 진행 라벨 목록은 이 파일에 **두 자리**다 — 여기(시작 판정)와 후보 루프의
#     `agent:claimed` / `flow:verify|flow:ready|harvesting` 제외 `case` 두 줄. 둘은 같은
#     집합이어야 한다: 새 진행 라벨을 **제외 쪽에만** 더하면 그 레인의 leaf 는 후보에서
#     빠지면서 시작 판정도 못 줘, finish-first 가 조용히 한 출처를 잃는다. 갈리면
#     `scripts/tests/eligible-issues.test.sh` 의 Ⓔ⑩ 가 양방향으로 빨개진다.
#
#     한 행씩 `jq -c` 로 흘려 받는다 — 인덱스로 되짚으면 행마다 배열 전체를 다시 파싱해
#     창 상한(#277 이후 실질 250)에서 O(n²) 가 된다.
while IFS= read -r i_row; do
  i_repo=$(printf '%s' "$i_row" | jq -r '.repository.nameWithOwner')
  i_epic=$(epic_of "$(printf '%s' "$i_row" | jq -r '.body')")
  if [ -n "$i_epic" ]; then
    started_epics="${started_epics}${i_repo}#${i_epic}
"
  fi
done < <(printf '%s' "$cands" | jq -c '
  .[]
  | select([.labels[].name]
      | any(. == "agent:claimed" or . == "flow:verify" or . == "flow:ready" or . == "harvesting"))')

# body 는 (a) 에서만 쓴다 — 후보 루프가 도는 `cands` 는 종전 형상으로 되돌린다(행마다
# 본문을 재파싱하면 창 상한(#277 이후 실질 250)에서 스캔이 눈에 띄게 느려진다).
cands=$(printf '%s' "$cands" | jq -c 'map(del(.body))')

# (b) 최근 닫힌 leaf — 추가 검색 **한 번**(이 스크립트가 늘리는 gh 호출은 이것뿐).
#     닫힌 leaf 가 있다는 건 그 에픽이 이미 진행됐다는 뜻이라 시작 집합에 든다.
#     gh 의 stderr 는 **합치지 않는다**(`2>&1` 금지) — 합치면 ⑴ 실패 사유가 변수에 갇혀
#     사라지고 ⑵ 성공했는데 gh 가 stderr 에 한 줄이라도 쓰면 JSON 판정이 깨져 거짓 warn 이 난다.
#     그대로 흘려보내면 사유는 stderr 에 남고 판정은 stdout 만 본다.
EPIC_SCAN_WINDOW=100
epic_scan_ok=false
since=$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%d 2>/dev/null || true)
if [ -n "$since" ]; then
  if scan_out=$(gh api -X GET search/issues \
      -f q="user:$me is:issue is:closed closed:>=$since \"Epic #\" in:body" \
      -f per_page="$EPIC_SCAN_WINDOW" \
      -q '{total_count: .total_count, items: [.items[] | {repo: (.repository_url | sub(".*/repos/"; "")), body: (.body // "")}]}'); then
    # 종료코드 0 이어도 items 가 배열이 아니면 **값 미상**이다 — 빈 결과와 실패를 구분한다(PR#139).
    if printf '%s' "$scan_out" | jq -e '(.items | type) == "array"' >/dev/null 2>&1; then
      epic_scan_ok=true
    fi
  fi
fi
if [ "$epic_scan_ok" = "true" ]; then
  # 창 절단도 말한다 — 이 검색은 한 장(per_page 100)뿐이라, 닫힌 leaf 가 창을 넘으면
  # 시작 집합이 **부분**이 된다(정렬 힌트가 부분적이라는 사실이 침묵하면 안 된다.
  # 후보 검색이 #247·#277 에서 같은 이유로 절단을 말하게 된 것과 같은 자세다).
  closed_total=$(printf '%s' "$scan_out" | jq -r '.total_count')
  case "$closed_total" in
    ''|*[!0-9]*)
      echo "warn: 에픽 시작 집합 창 크기 미상 — total_count 를 못 읽었다(닫힌 leaf 절단 여부 판정 불가)" >&2 ;;
    *)
      if [ "$closed_total" -gt "$EPIC_SCAN_WINDOW" ]; then
        echo "warn: 에픽 시작 집합 부분 조회 — 최근 14일 닫힌 leaf ${closed_total}건 > 창 ${EPIC_SCAN_WINDOW}, finish-first 힌트가 부분적이다" >&2
      fi ;;
  esac
  while IFS= read -r leaf; do
    c_repo=$(printf '%s' "$leaf" | jq -r '.repo')
    c_epic=$(epic_of "$(printf '%s' "$leaf" | jq -r '.body')")
    if [ -n "$c_epic" ]; then
      started_epics="${started_epics}${c_repo}#${c_epic}
"
    fi
  done < <(printf '%s' "$scan_out" | jq -c '.items[]')
else
  # 조회 실패를 **빈 큐로 위장하지 않는다** — 말하고 계속 진행한다. 시작 집합은 통째로
  # 비운다((a) 만 남기면 "일부만 finish-first" 라는 미상 상태가 되고, 그 순서는 아무도
  # 재현할 수 없다). 정렬은 종전(P → 생성일)으로 떨어진다.
  started_epics=""
  echo "warn: 에픽 시작 집합 조회 실패 — finish-first 없이 정렬" >&2
fi

epic_started_of() {  # epic_started_of <owner/repo> <에픽 번호 또는 빈 문자열> → true|false
  if [ -z "$2" ]; then printf 'false'; return 0; fi
  if printf '%s' "$started_epics" | grep -qxF "$1#$2"; then printf 'true'; else printf 'false'; fi
}

blocked_n=0
blocked_human=0

out="[]"
count=$(printf '%s' "$cands" | jq 'length')
i=0
while [ "$i" -lt "$count" ]; do
  row=$(printf '%s' "$cands" | jq -c ".[$i]")
  i=$((i + 1))
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner')
  num=$(printf '%s' "$row" | jq -r '.number')
  labels=$(printf '%s' "$row" | jq -r '[.labels[].name] | join(",")')

  # 세션 레포 스코프 밖이면 제외 (#40)
  in_scope "$repo" || continue

  # 이미 claim 된 것 제외
  case ",$labels," in *",agent:claimed,"*) continue ;; esac

  # 사람 개입 대기(needs-human) 제외 — 사람이 라벨을 떼기 전에는 재디스패치 금지
  case ",$labels," in *",needs-human,"*) continue ;; esac

  # 기계 정지(hold:*) 제외 (#242) — verify-held·closeout-blocked·runner-held 가 붙이는
  # 정지 사유. 지금은 `needs-human` 과 항상 쌍이라 **동작이 바뀌지 않지만**, held 이슈는
  # `agent-ready` 를 사다리 내내 달고 있어서 `needs-human` 부착이 사유별로 걷히는 순간
  # 이 필터가 없으면 정지된 이슈가 곧바로 재디스패치된다(플랜 Plans/label-taxonomy-cleanup.md 1단계).
  #
  # 판별은 **접두사** `hold:` — 사유가 늘어도(`hold:<새사유>`) 안 깨진다. 라벨 경계는
  # 위 join 의 콤마이므로 `,hold:` 로 물어야 한다. 그래야 `hold:` 로 **시작하지 않는**
  # 라벨(`holding`·`on-hold`·`area:hold`·`hold-ladder`·`holder:x`)이 걸리지 않는다 —
  # 과잉 제외는 정상 후보를 소리 없이 없애는 방향이라 원래 결함보다 나쁘다.
  #
  # 서버 쿼리(위 search/issues)는 **일부러 안 건드린다**: `gh` 검색은 부정 라벨을
  # 오파싱하고(#21) `-label:hold:policy` 는 콜론이 둘이라 더 위험하다 — 필터는
  # 클라이언트 쪽에만 둔다(needs-human 의 서버측 제외는 기존 그대로 유지).
  #
  # 해제는 **두 라벨 다** 떼는 것이다 — `needs-human` 만 떼면 `hold:*` 가 남아 후보로
  # 돌아오지 않는다(기계 해제 경로는 이미 둘 다 뗀다: transition.sh `⊘hold`·resume-sweep 재개).
  case ",$labels," in *",hold:"*) continue ;; esac

  # 검증/마감 레인 이슈 제외 (진행 라벨 미러) — 원 이슈에 flow:verify/flow:ready/harvesting
  # 가 미러링돼 있으면 구현이 끝나 다운스트림(verify-runner·closeout) 소유다. agent:claimed
  # 가 스윕에 스트립돼도 이 플로우 라벨이 재디스패치를 막는다(중복 워커 방지 + 이슈 리스트
  # 진행 가시화). 반송은 verify-runner 가 flow:verify 를 떼고 agent-ready 만 남기므로 이
  # 필터에 안 걸려 정상 재디스패치된다.
  case ",$labels," in *",flow:verify,"*|*",flow:ready,"*|*",harvesting,"*) continue ;; esac

  # 블로커 = 본문 "Blocked by #N" 라인의 N ∪ blocked-by:<N> 라벨의 N (OR·dedupe).
  # ★이 파싱 규칙의 SSOT 는 여기다 — `scripts/loop-status.sh` 의 `막힘` 버킷(#248)이
  #   같은 규칙을 jq 로 옮겨 갖고 있다(그 파일 `blockers_of` 위 주석이 이쪽을 가리킨다).
  #   여기를 고치면 저쪽도 같이 고쳐라 — 안 그러면 디스패치 자격과 대시보드의 `막힘`
  #   표시가 조용히 갈린다(한쪽은 집어가는데 다른 쪽은 막혔다고 그린다).
  # 라벨 방식은 이슈 목록에서 블로킹이 한눈에 보이는 게 요점(#85). 새 search 쿼리를
  # 추가하지 않고 이미 받은 labels 배열에서만 파싱한다(gh search 부정라벨 오파싱 #21).
  body=$(gh issue view "$num" --repo "$repo" --json body -q '.body // ""')
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
    if [ "$blocker_state" = "사람대기" ]; then
      blocked_human=$((blocked_human + 1))
    fi
    continue
  fi

  prio=3
  case ",$labels," in
    *",P0,"*) prio=0 ;;
    *",P1,"*) prio=1 ;;
    *",P2,"*) prio=2 ;;
  esac

  # 에픽은 이미 받아 둔 `$body` 에서 읽는다 — `gh issue view` 호출 수 변화 0.
  epic=$(epic_of "$body")
  epic_started=$(epic_started_of "$repo" "$epic")

  title=$(printf '%s' "$row" | jq -r '.title')
  created=$(printf '%s' "$row" | jq -r '.createdAt')
  out=$(printf '%s' "$out" | jq -c \
    --arg repo "$repo" --argjson num "$num" --arg title "$title" \
    --argjson prio "$prio" --arg created "$created" \
    --argjson epic "${epic:-null}" --argjson epic_started "$epic_started" \
    '. + [{repo:$repo, number:$num, title:$title, priority:$prio, createdAt:$created,
           epic:$epic, epic_started:$epic_started}]')
done

# 요약은 stderr 로 (stdout 은 후보 JSON 전용). 0 건도 말한다 — 침묵과 "막힌 게 없다"는
# 다른 주장이고, ④ Report 의 `막힘 N` 은 매 틱 숫자가 있어야 읽힌다.
if [ "$blocked_n" = 0 ]; then
  echo "blocked-summary: 막힘 0건" >&2
else
  echo "blocked-summary: 막힘 ${blocked_n}건 (사람대기 블로커 ${blocked_human}건)" >&2
fi

# 정렬 키 = (우선순위, 시작한 에픽 먼저, 오래된 순). 가운데 칸은 `epic_started` 를
# true→0 / false→1 로 접어 **오름차순 그대로** 내림차순 효과를 낸다(jq 에 역순 키가 없다).
# P 가 첫 키라 에픽 축은 같은 P 안에서만 움직인다.
printf '%s' "$out" | jq 'sort_by(.priority, (if .epic_started then 0 else 1 end), .createdAt)'
