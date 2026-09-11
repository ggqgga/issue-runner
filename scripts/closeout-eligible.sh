#!/usr/bin/env bash
# 마감 후보 PR을 JSON lines 로 출력. 진입 조건 모두 충족 + harvesting 미부착.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0

# 반송(bounce) 마커 집합과 그 선후 판정은 `bounce-state.sh` **한 자리**에 있다
# (#171 에서 여기 인라인으로 태어났고 #196 에서 헬퍼로 옮겼다 — closeout SKILL ①-b 의
# CONFLICTING 입양 경로가 같은 판정을 필요로 하는데, 거긴 finish-classify 를 일부러
# 건너뛰어 이 파일을 통과하지 않기 때문이다). 새 반송 어휘가 늘면 그 파일 하나만 고친다.

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
  # hold:* = 기계 정지 그 자체 (#242). 지금은 위 needs-human 과 항상 쌍이라 동작이 바뀌지
  # 않지만, `needs-human` 부착이 사유별로 걷히면 이 줄만 남아 정지를 지킨다(플랜 1단계).
  # **접두사** 판별이라 사유가 늘어도(`hold:<새사유>`) 안 깨지고, `hold:` 로 시작하지 않는
  # 라벨(`holding`·`on-hold`·`area:hold`)은 걸리지 않는다 — 과잉 제외는 머지 가능한 PR 을
  # 조용히 큐에서 지우는 방향이라 원래 결함보다 나쁘다.
  #
  # 해제는 **두 라벨 다** 떼는 것이다 — `needs-human` 만 떼면 `hold:*` 가 남아 후보로
  # 돌아오지 않는다(기계 해제 경로는 이미 둘 다 뗀다: transition.sh `⊘hold`·resume-sweep 재개).
  printf '%s' "$meta" | jq -e '[.labels[].name]|any(startswith("hold:"))' >/dev/null && continue
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
  # 창의 **여는 쪽 경계** = 최신 `마감 검증: ⚠ 보류` 코멘트 시각. 이게 없으면 이 PR 엔
  # 해소할 보류 자체가 없으므로 타임라인을 **아예 조회하지 않는다**(흔한 경로 비용 0).
  # 이건 판정이 아니라 창의 경계다 — "그 ⚠ 가 ✅ 를 실제로 가리는가" 의 판정은
  # finish-classify **한 자리**에 있다(로직 두 벌 금지). 위 hold:* 접두 필터(#242)는
  # **현재** 라벨 상태만 보므로, 이 헬퍼가 보는 **과거** 해제 이력(면제 창 경계)과는
  # 서로 다른 질문이라 겹치지 않는다.
  hold_at=$(printf '%s' "$comments" | jq -r '
    ([ .[] | select(.body | startswith("마감 검증") or startswith("Closeout verification"))
            | select(.body | contains("⚠")) ] | last | .createdAt? // "")' 2>/dev/null)
  hold_released_at=''
  if [ -n "$hold_at" ]; then
    # 조회 실패(exit 1)·해제 이벤트 없음(exit 0·빈 출력) 모두 빈 값으로 떨어진다 —
    # 둘 다 "보류가 해소됐음을 증명 못 함" 이라 하류가 게이트를 닫는다(fail-closed).
    # `$hold_at` 을 3번째 인자로 넘긴다 — 헬퍼가 "이 보류 이후 첫 사람 해제" 만 답하게
    # 해, 그 뒤 무관한 후속 hold:* 사이클의 해제가 이 면제 창(아래 unresolved)을 소급
    # 확장하지 않게 한다(#186 합류: 에피소드 스코프 해제).
    hold_released_at=$("$SCRIPT_DIR/pr-hold-released-at.sh" "$repo" "$pr" "$hold_at" 2>/dev/null) || hold_released_at=''
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
  # 판정은 `bounce-state.sh` 한 자리다(#196) — 마커 집합·선후 규칙(코멘트 배열의 마지막
  # 매칭 **인덱스**, createdAt 아님)은 그 파일 주석 참조. 이미 읽은 코멘트를 파일로 넘겨
  # 중복 gh 조회를 피한다(위 fc_comments_file 을 그대로 재사용 — 방금 같은 내용으로 썼다).
  # 조회·판정 실패(exit 1)·`bounced` 모두 "ok 아님" 이라 후보에서 빠진다(fail-closed —
  # 위 ✅ 갈래와 같은 방향: 반송되지 않았음을 **증명**했을 때만 통과).
  bounce_state=$(BOUNCE_COMMENTS_FILE="$fc_comments_file" \
    "$SCRIPT_DIR/bounce-state.sh" "$repo" "$pr" 2>/dev/null)
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
  # **보류~해제 창 안의 사람 코멘트는 미해결이 아니다 (#174).** 사람이 사유 라벨을 뗀
  # 행위가 곧 "내 몫은 끝났다" 는 신호다 — 운영자는 결정문을 코멘트로 남기고 그 직후
  # 라벨을 뗀다(실측 BodaT #4922: 결정문 08:18:51 → 라벨 제거 08:18:56). 그 결정문을
  # 미해결로 세면 사람이 답을 준 PR 이 영영 후보에 안 뜬다(이 이슈의 실측).
  #
  # 면제 창은 **반개구간 `(보류 코멘트, 해제]`** 로 좁힌다 — 해제 시각 하나로 "그 이전
  # 전부" 를 면제하면, 그 보류와 **무관한** 옛 사람 질문(보류 코멘트보다도 앞선 것)까지
  # 삼킨다. 사람이 답한 것은 *그 보류가 물은 것*이지 PR 의 모든 과거가 아니다.
  #   · 해제 **이후**의 사람 코멘트 → 미해결(사람이 새 질문을 던졌다).
  #   · 보류 코멘트 **이전**의 사람 코멘트 → 미해결(그 보류와 무관한 미결).
  #   · `$rel`·`$hold` 중 하나라도 못 얻음 → **아무것도 면제 안 함**(fail-closed, 종전 동작).
  # 결정문의 *내용*이 "원안 그대로 머지" 인지, 아니면 게이트를 다시 돌려야 하는지는
  # closeout SKILL ③-1 재진입 규칙이 판정한다(스크립트는 후보에 올리는 데까지만).
  unresolved=$(printf '%s' "$human_comments" \
    | jq --arg rel "$hold_released_at" --arg hold "$hold_at" '[.[]
    | select(($rel == "") or ($hold == "") or ((.createdAt // "") == "")
             or ((.createdAt // "") <= $hold) or ((.createdAt // "") > $rel))]
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
