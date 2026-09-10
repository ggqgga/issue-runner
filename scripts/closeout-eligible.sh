#!/usr/bin/env bash
# 마감 후보 PR을 JSON lines 로 출력. 진입 조건 모두 충족 + harvesting 미부착.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0

# ── 반송(bounce) 마커 집합 — 한 자리 (#171) ──────────────────────────────
# PR 을 워커에게 되돌리는 채널이 둘이고, 각자 자기 어휘로 코멘트를 남긴다:
#   `재디스패치:`   closeout 마감 검증 BLOCKER·완결 유실 반송 (skills/closeout/SKILL.md:124)
#   `재검증 실패:`  verify-runner 재검증 반려          (skills/verify-runner/SKILL.md:227)
# 두 채널의 효과는 같다 — 교체 워커가 새 커밋을 올리기 전까지 head 가 그대로라, 그
# 이전에 찍힌 ✅ 가 살아 남아 "방금 반려된 PR" 을 머지 후보로 만든다. 그래서 **한 집합**
# 으로 다룬다. 새 반송 어휘가 늘면 **이 배열 한 곳만** 고쳐라 — 채널마다 가드를 베끼면
# 하나 빠진 채로 fail-open 이 된다(실제로 verify-runner 채널이 그렇게 빠져 있었다).
# 두 마커 모두 한/영 SKILL 이 같은 한글 문자열을 찍는다(SKILL.en.md 도 동일) — 영문
# 변종이 생기면 여기에 함께 넣는다.
BOUNCE_MARKERS='["재디스패치:","재검증 실패:"]'

# 코멘트 전량을 finish-classify 에 넘기는 통로 (#171 반송 4회차 [P2]).
# 환경변수 하나로 넘기면 페이지네이션으로 상한이 사라진 코멘트가 exec 한계(리눅스
# MAX_ARG_STRLEN 128KB)를 넘는 순간 finish-classify 가 **시작조차 못 하고** verdict 가
# 비어 그 PR 이 매 스윕에서 조용히 빠진다(검증자·마감 코멘트는 건당 수 KB — 반송을 여러
# 번 도는 PR 이면 닿는 크기다). 파일로 넘기면 크기와 무관해진다.
# 파일을 못 만들면 판정 입력을 넘길 방법이 없으므로 후보를 내지 않고 끝낸다(fail-closed).
fc_comments_file=$(mktemp "${TMPDIR:-/tmp}/closeout-eligible-comments.XXXXXX") || exit 0
trap 'rm -f "$fc_comments_file"' EXIT

scope_file="$PWD/.loop/repos"
in_scope() {
  [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"
}

# sort=created·order=asc — 미지정 시 search API 는 best-match(관련도) 순이라
# ② Pick 의 "첫 후보" 가 사실상 랜덤이 된다. 오래된 PR 먼저 = FIFO 마감.
prs=$(gh api -X GET search/issues \
  -f q="user:$me is:open is:pr" -f per_page=50 \
  -f sort=created -f order=asc \
  -q '[.items[] | {repo:(.repository_url|sub(".*/repos/";"")), pr:.number}]' 2>/dev/null)
[ -n "$prs" ] || exit 0

printf '%s' "$prs" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repo')
  pr=$(printf '%s'  "$row" | jq -r '.pr')
  in_scope "$repo" || continue

  # commits 는 **일부러 안 싣는다**(#171 반송 4회차 [P1-1]) — GraphQL commits(first:100)
  # 이라 101번째부터 안 오고, 그때 `last` 는 head 가 아니라 100번째 커밋이다. head 시각은
  # 아래에서 pr-head-at.sh(headRefOid + 그 커밋 조회)로 상한 없이 받는다.
  meta=$(gh pr view "$pr" --repo "$repo" \
    --json headRefName,mergeable,labels,closingIssuesReferences 2>/dev/null)
  [ -n "$meta" ] || continue

  head=$(printf '%s' "$meta" | jq -r '.headRefName')
  case "$head" in agent/issue-*) : ;; *) continue ;; esac
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("harvesting")' >/dev/null && continue
  # flow:verify = verify-runner 소유(harvesting 동형). 정상 인계에선 verify-runner 가
  # flow:verify 를 떼고 나서 ✅ 를 남기지만, ✅ 코멘트가 라벨 제거보다 먼저 달리면 두
  # 루프(별도 프로세스)가 같은 PR 을 문다 — 라벨이 붙어 있는 한 closeout 은 손대지
  # 않는다(verify-eligible.sh 의 harvesting 제외와 대칭).
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("flow:verify")' >/dev/null && continue
  # needs-human = 사람 대기(hold:* 사유 — verify-held·closeout-blocked·runner-held). 마감이 집으면
  # 방금 건 사람 대기를 자동으로 되돌린다(#151). 사람이 라벨을 뗄 때까지 후보가 아니다.
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("needs-human")' >/dev/null && continue
  # mergeable 은 GitHub 이 지연 계산한다 — UNKNOWN 은 아직 미판정이므로 CONFLICTING 과
  # 함께 skip 하고 다음 틱에 재시도한다(미판정 PR 을 머지 도크로 넘기지 않는다).
  case "$(printf '%s' "$meta" | jq -r '.mergeable')" in
    CONFLICTING|UNKNOWN) continue ;;
  esac

  # 코멘트는 meta 에 안 싣고 pr-comments.sh 로 **페이지네이션 전량** 읽는다(#171 [P1-2]).
  # `gh pr view --json comments` 는 첫 100건만 준다 — 아래 세 판정(✅ 존재 · 반송 마커
  # 안전망 · 미해결 사람 코멘트)이 전부 그 상한 안에 갇혀 조용히 틀린다:
  #   · 101번째 이후의 새 ✅ 를 못 봄 → 머지 가능한 PR 이 영영 후보에 안 뜬다.
  #   · 101번째 이후의 반송 마커를 못 봄 → 반송된 PR 이 안전망을 통과한다.
  # 반송을 여러 번 도는 PR 은 워커·verify·closeout 코멘트가 겹겹이 쌓여 100건이 먼
  # 숫자가 아니다. 조회는 finish-classify 와 **같은 헬퍼 한 자리**를 공유한다.
  #
  # 조회 실패(exit 1)면 후보에서 뺀다 — 코멘트를 못 읽었다는 건 반송되지 않았음을
  # **증명하지 못한** 것이고, 머지 게이트에서 증명 실패는 통과가 아니다(fail-closed).
  comments=$("$SCRIPT_DIR/pr-comments.sh" "$repo" "$pr" 2>/dev/null) || continue
  [ -n "$comments" ] || continue

  printf '%s' "$comments" \
    | jq -e '[.[].body] | map(select(startswith("머지 판정: ✅") or startswith("Merge verdict: ✅"))) | length > 0' \
    >/dev/null || continue

  # 결정론 재사용 — finish-classify.sh 의 head-SHA 대조 판정을 그대로 쓴다(#171 개발계획
  # 2항: 로직 두 벌 금지). ✅ 존재만으로 후보 삼지 않는다 — 반송(재디스패치) 뒤 새
  # 커밋이 올라왔는데 그 커밋 이전에 찍힌 ✅ 가 남아 있으면 finish-classify 가
  # done_verdict 를 내지 않고(active) 여기서도 걸러진다.
  # head 시각은 **코멘트를 읽은 뒤** 뜬다(#171 반송 4회차 [P1-2]). 순서가 반대면 그 사이
  # 워커가 push 했을 때 head_at 이 **이전 커밋**을 가리키고, 기존 ✅ 가 그보다 늦어 보여
  # **검증 안 된 head 가 후보로 나간다**(뒤의 CI 확인은 판정 신선도를 다시 보지 않는다).
  # 나중에 뜬 head 는 그 사이 push 를 포함하므로 ✅ 보다 늦어져 active = 다음 틱 재시도다
  # (창을 완전히 없애는 것 — "이 판정이 바로 이 OID 에 대한 것" — 은 #175 몫이라, 여기서는
  # 읽는 **순서**만 fail-closed 쪽으로 맞춘다. 순서가 곧 계약이다).
  #
  # 조회 로직은 pr-head-at.sh 한 자리(상한 100 회피 — 그 파일 주석 참조). 실패는 빈 값으로
  # 떨어뜨리고 판정은 finish-classify 한 곳에서만 한다(증명 실패 → active → 후보 제외).
  head_at=$("$SCRIPT_DIR/pr-head-at.sh" "$repo" "$pr" 2>/dev/null) || head_at=''

  # 사람(비머신) 코멘트를 **한 번만** 뽑아 두 곳이 함께 쓴다 — 아래 해제 시각 조회
  # 필요 여부 판단과 미해결 판정. 머신 코멘트 식별 규칙은 아래 unresolved 주석 참조.
  # jq 실패(빈 출력)면 사람 코멘트 유무를 **증명 못 한** 것이므로 후보에서 뺀다(fail-closed).
  human_comments=$(printf '%s' "$comments" | jq -c '[.[]
    | select((.body | (contains("<!-- bodat:worker -->")
              or startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증"))) | not)]' \
    2>/dev/null)
  [ -n "$human_comments" ] || continue

  # ── 보류 해제 시각 (#174) ────────────────────────────────────────────────
  # 사람이 `needs-human`·`hold:*` 를 뗀 시각. 두 곳이 쓴다:
  #   · finish-classify 의 `마감 검증: ⚠ 보류` 해소 판정(FC_HOLD_RELEASED_AT)
  #   · 아래 미해결 사람 코멘트 판정 — 해제 **이전**의 사람 코멘트는 그 해제로 답해진 것
  # 타임라인은 페이지네이션이라 비싸므로 **필요할 때만** 조회한다. 트리거는 판정의
  # 상위집합이다(가릴 수 있는 `마감 검증: ⚠` 가 하나라도 있거나 · 사람 코멘트가 있거나) —
  # 트리거가 안 걸리는 PR 은 해제 시각을 써도 답이 안 바뀌므로 조회를 생략해도 안전하다.
  # 판정 자체는 여기서 베끼지 않는다(로직 두 벌 금지) — finish-classify 한 자리다.
  #
  # 조회는 **코멘트·head 를 읽은 뒤**에 한다. 그 사이 사람이 보류를 새로 걸었다면 이
  # 스냅샷엔 안 잡히지만, 그건 라벨 조회(더 앞)와 같은 창이고 다음 틱이 잡는다. 반대로
  # 먼저 뜨면 그 사이의 **해제**를 놓쳐 사람이 푼 건이 또 한 틱을 기다린다.
  hold_released_at=''
  need_hold=$(printf '%s' "$comments" | jq -r '
    if ([.[] | select(.body | startswith("마감 검증") or startswith("Closeout verification"))
              | select(.body | contains("⚠"))] | length) > 0 then "yes" else "no" end' 2>/dev/null)
  if [ "$need_hold" = yes ] || [ "$(printf '%s' "$human_comments" | jq 'length' 2>/dev/null)" != 0 ]; then
    # 조회 실패(exit 1)·해제 이벤트 없음(exit 0·빈 출력) 모두 빈 값으로 떨어진다 —
    # 둘 다 "보류가 해소됐음을 증명 못 함" 이라 하류가 게이트를 닫는다(fail-closed).
    hold_released_at=$("$SCRIPT_DIR/pr-hold-released-at.sh" "$repo" "$pr" 2>/dev/null) || hold_released_at=''
  fi

  # 이미 가져온 comments 를 **파일로** 넘겨 중복 gh 조회를 피한다(사전 리뷰 WARN).
  # 환경변수가 아니라 파일인 이유는 위 fc_comments_file 주석 참조([P2] — exec 한계).
  # 쓰기 실패면 판정 입력을 못 넘긴 것이므로 후보에서 뺀다(fail-closed).
  #
  # FC_FAILING=0 도 넘긴다: finish-classify 의 CI 실패 가드는 `🔄` 갈래에만 걸리는데
  # 여기서 받는 판정은 `✅` 갈래(done_verdict) 하나뿐이라 그 값이 쓰이지 않는다. 안
  # 넘기면 후보마다 statusCheckRollup 을 헛조회한다(실 CI 게이트는 아래
  # closeout-ci-pass.sh 가 로컬 CI 캐시로 따로 본다). 판정 로직을 여기서 베끼는 게
  # 아니라 **쓰이지 않는 입력의 조회만** 생략하는 것이다.
  printf '%s' "$comments" > "$fc_comments_file" || continue
  verdict=$(FC_COMMENTS_FILE="$fc_comments_file" \
    FC_HEAD_AT="$head_at" FC_HOLD_RELEASED_AT="$hold_released_at" FC_FAILING=0 \
    "$SCRIPT_DIR/finish-classify.sh" "$repo" "$pr" 2>/dev/null)
  [ "$verdict" = "done_verdict" ] || continue

  # 반송 마커 안전망(#171 개발계획 3항) — 1·2 의 head 커밋 시각 비교가 못 잡는 창을
  # 막는다: 반송 직후 워커가 아직 새 커밋을 안 올렸으면 head 커밋 시각이 그대로라
  # finish-classify 도 done_verdict 를 낼 수 있다(코멘트 시각과 커밋 시각의 시계가
  # 다를 수 있다는 전제). 최신 반송 마커가 최신 ✅ 보다 **뒤**면(그 사이 새 ✅ 가 안
  # 찍혔으면) 후보에서 뺀다.
  #
  # 선후는 **코멘트 배열의 마지막 매칭 인덱스**로 판정한다 — createdAt 이 아니라.
  # GitHub 코멘트 시각은 초 단위라 ✅ 직후 같은 초에 반송 마커가 달리면 두 값이 같아져
  # 시각 비교(`>`)가 거짓이 되고 반송된 PR 이 통과한다. 반대로 같은 초에 마커 뒤 새 ✅ 가
  # 달린 정상 재완결은 통과해야 하므로, 단순 시각 비교로는 양방향을 못 가린다. 코멘트
  # 배열은 GitHub 이 생성 순으로 주므로 인덱스가 그 순서를 그대로 담는다(초 단위로
  # 뭉개지지 않는 유일한 값 — PR#168 교훈: 정보를 담을 수 있는 값으로 바꿔라).
  bounce_state=$(printf '%s' "$comments" | jq -r --argjson bm "$BOUNCE_MARKERS" '
    [.[].body] as $bodies
    | ([ $bodies | to_entries[]
         | select(.value as $x | ($bm | any(. as $m | $x | startswith($m))))
         | .key ] | last) as $bi
    | ([ $bodies | to_entries[]
         | select(.value | startswith("머지 판정: ✅") or startswith("Merge verdict: ✅"))
         | .key ] | last) as $vi
    | if   $bi == null then "ok"
      elif $vi == null then "bounced"
      elif $bi > $vi   then "bounced"
      else "ok" end' 2>/dev/null)
  # jq 실패·빈 출력도 "ok 아님" 이라 후보에서 빠진다(fail-closed — 위 ✅ 갈래와 같은 방향:
  # 반송되지 않았음을 **증명**했을 때만 통과).
  [ "$bounce_state" = "ok" ] || continue

  # 미해결(사람 리뷰) 코멘트 판정 — 머신 코멘트는 sentinel 마커 <!-- bodat:worker -->
  # (마지막 줄)로 식별한다(#72). 워커/closeout 이 남기는 모든 자기-문서화 코멘트엔
  # 이 마커가 박힌다(worker-template 한/영·closeout SKILL 한/영). 마커가 있으면 머신
  # → unresolved 제외. 접두사 어휘가 늘어도(예 "추가 보정") 안 깨진다 = allowlist 탈피.
  #
  # 레거시 3접두사(머지 판정/검증자 리뷰/마감 검증)는 **동결 폴백**으로 남긴다 — 마커
  # 도입 이전에 열린 PR 의 옛 머신 코멘트가 "미해결 사람 리뷰"로 오인돼 탈락하지 않게.
  # 이 폴백은 더 키우지 않는다(새 어휘는 마커가 받는다) → whack-a-mole 종결.
  # (긍정 게이트는 위 "머지 판정: ✅"/"Merge verdict: ✅" 시작 매칭이라 위험은 좁다.)
  #
  # contains 는 **의도적**이다(위치 무관) — 워커가 마커를 정확히 마지막 줄에 못 둬도
  # 머신으로 인식해 robust 하다. 템플릿의 "마지막 줄" 규칙은 *긍정 게이트* 작성
  # 제약일 뿐(마커가 "머지 판정: ✅" 앞에 오면 startswith 가 깨진다) 이 필터의
  # 요구사항이 아니다. 마지막-줄을 jq 로 강제하면 마커 오배치가 사람 코멘트로
  # 오인돼 #72 false-positive 가 재발하므로 그렇게 바꾸지 마라.
  #
  # **해제 이전의 사람 코멘트는 미해결이 아니다 (#174).** 사람이 `needs-human`·`hold:*`
  # 를 뗀 행위가 곧 "내 몫은 끝났다" 는 신호다 — 운영자는 결정문을 코멘트로 남기고
  # 그 직후 라벨을 뗀다(실측 BodaT #4922: 결정문 08:18:51 → 라벨 제거 08:18:56).
  # 그 결정문을 미해결로 세면 사람이 답을 준 PR 이 영영 후보에 안 뜬다(이 이슈의 실측).
  # 해제 **이후**에 달린 사람 코멘트는 종전대로 미해결이다 — 사람이 새 질문을 던졌는데
  # 자동 머지가 지나가면 안 된다. 해제 시각을 못 얻었으면($rel 빈 값) 아무것도 면제하지
  # 않는다(fail-closed — 종전 동작 그대로).
  # 결정문의 *내용*이 "원안 그대로 머지" 인지, 아니면 게이트를 다시 돌려야 하는지는
  # closeout SKILL ③-1 재진입 규칙이 판정한다(스크립트는 후보에 올리는 데까지만).
  unresolved=$(printf '%s' "$human_comments" | jq --arg rel "$hold_released_at" '[.[]
    | select(($rel == "") or ((.createdAt // "") == "") or ((.createdAt // "") > $rel))]
    | length')
  [ "${unresolved:-0}" -gt 0 ] && continue

  # ci-pass exit code 분기 (#70): 0=캐시 pass(revalidate:false)·2=로컬 CI HEAD 미실행
  # (rebase 등 — revalidate:true 로 머지 도크가 재검증)·그 외=종전대로 탈락(fail/조회불가).
  "$SCRIPT_DIR/closeout-ci-pass.sh" "$repo" "$pr"; cp=$?
  case "$cp" in
    0) reval=false ;;
    2) reval=true ;;
    *) continue ;;
  esac

  issue=$(printf '%s' "$meta" | jq -r '.closingIssuesReferences[0].number // empty')
  printf '{"repo":"%s","pr":%s,"issue":"%s","head":"%s","revalidate":%s}\n' "$repo" "$pr" "$issue" "$head" "$reval"
done
