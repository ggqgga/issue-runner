#!/usr/bin/env bash
# 마감 후보 PR을 JSON lines 로 출력. 진입 조건 모두 충족 + harvesting 미부착
# (+ verify-runner 소유 라벨 flow:verify·verifying 미부착 — #275).
# 레인 판별은 head 이름(`agent/issue-*`) **과** `full-cycle` 라벨 미부착 두 축이다(#246).
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
  # 레인 두 번째 축 — `full-cycle` 라벨은 **명시적 제외**다(#246, 플랜 5단계). 위 head 필터와
  # AND 이지 OR 가 아니다: head 가 `agent/issue-*` 여도 라벨이 붙어 있으면 "루프 소유 아님".
  # 왜 브랜치 이름만으로는 부족한가 — `agent/issue-*` 는 make-worktree 의 **관례**지 라벨처럼
  # 강제되는 축이 아니다. 사람 세션(full-cycle 스킬)이 같은 접두의 브랜치를 쓰거나 루프가
  # 접두를 바꾸는 날 head 만 보는 판별은 조용히 깨진다 — 마감이 사람 세션 PR 을 squash
  # 머지해 버리는 방향이라 특히 나쁘다. `full-cycle` 은 사람 세션 사이클이 자기 산출물
  # (구현 이슈·PR·배포 대기)에 붙이는 **레인 소유 표시**라 그 자체가 판정 근거다.
  # head 필터를 지우지 않는 이유는 라벨 도입 전에 열린 PR 들이 라벨 없이 남아 있어서다 —
  # 라벨은 보강이지 대체가 아니다. 판별은 배열 원소의 완전 일치(index)라 `full-cycle-*` 류는
  # 걸리지 않는다(과잉 제외는 머지 가능한 PR 을 조용히 지우는 방향이라 원래 결함보다 나쁘다).
  # verify-eligible.sh 의 같은 자리와 **같은 정의**다(격자 단언: tests/lane-gate.test.sh).
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("full-cycle")' >/dev/null && continue
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("harvesting")' >/dev/null && continue
  # flow:verify = verify-runner 소유(harvesting 동형). 정상 인계에선 verify-runner 가
  # flow:verify 를 떼고 나서 ✅ 를 남기지만, ✅ 코멘트가 라벨 제거보다 먼저 달리면 두
  # 루프(별도 프로세스)가 같은 PR 을 문다 — 라벨이 붙어 있는 한 closeout 은 손대지
  # 않는다(verify-eligible.sh 의 harvesting 제외와 대칭).
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("flow:verify")' >/dev/null && continue
  # verifying = verify-runner 가 **지금 검증 중**(#275 — flow:verify 를 떼고 붙이는 점유 라벨,
  # harvesting 동형). 위 flow:verify 와 같은 이유로 closeout 은 손대지 않는다 — 검증이 도는
  # 동안 ✅ 가 남아 있을 수 있는 PR(재검증 중)을 두 루프가 함께 물지 않게.
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("verifying")' >/dev/null && continue
  # needs-human = 사람이 직접 세운 정지(#244 — 기계 정지는 아래 hold:* 가 문다). 마감이 집으면
  # 방금 건 사람 대기를 자동으로 되돌린다(#151). 사람이 라벨을 뗄 때까지 후보가 아니다.
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("needs-human")' >/dev/null && continue
  # hold:* = 기계 정지 그 자체 (#242). `needs-human` 부착이 사유별로 걷혔으므로(#244)
  # 이제 이 줄만이 기계 정지를 지킨다 — 위 needs-human 필터는 사람이 직접 세운 정지용이다.
  # **접두사** 판별이라 사유가 늘어도(`hold:<새사유>`) 안 깨지고, `hold:` 로 시작하지 않는
  # 라벨(`holding`·`on-hold`·`area:hold`)은 걸리지 않는다 — 과잉 제외는 머지 가능한 PR 을
  # 조용히 큐에서 지우는 방향이라 원래 결함보다 나쁘다.
  #
  # 해제는 **붙어 있는 정지 라벨을 다** 떼는 것이다 — `hold:*` 만 남아도 후보로
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

  # 긍정 게이트는 ✅ 의 **마지막 매칭 인덱스**를 낸다(없으면 빈 값 → 탈락). 이 인덱스는
  # 아래 미해결 코멘트 판정의 경계로 그대로 쓰인다(#379) — ✅ 술어를 한 벌만 두려는 것이다
  # (같은 startswith 를 두 jq 에 베끼면 한쪽만 고쳐질 때 게이트와 경계가 갈린다). 선후는
  # createdAt 이 아니라 배열 인덱스다(`bounce-state.sh` 와 같은 규율 — 동초 선후 문제).
  vi=$(printf '%s' "$comments" | jq -r '[ to_entries[]
    | select(.value.body | startswith("머지 판정: ✅") or startswith("Merge verdict: ✅"))
    | .key ] | last // empty')
  [ -n "$vi" ] || continue

  # ✅ 본문의 `코멘트 스냅샷 N` 토큰 — verify-runner 가 사람 코멘트를 **읽은 시점**의
  # 전체 코멘트 수다(#384 Codex 2회차). ④ 의 확인 단계는 읽고 **나서** ✅ 를 게시하므로,
  # 그 사이(수 초)에 끼어든 사람 코멘트는 ✅ 보다 **앞** 인덱스에 앉는다 — 아래 경계가
  # ✅ 인덱스였을 때 그건 "검증자가 이미 확인한 것" 으로 넘어갔다(경합 창). N 을 경계로
  # 쓰면 인덱스 N..vi-1 이 다시 잡혀 창이 닫힌다(✅ 자신은 마커가 있어 어차피 안 세어진다).
  #
  # 스냅샷 토큰이 없는 **옛 ✅**(토큰 도입 이전·확인 단계 이전에 찍힌 것)은 종전 경계
  # `vi+1` 을 그대로 쓴다 — 소급하지 않기로 한 사용자 결정(#379)이고, 실측상 노출도
  # 없다(issue-runner 열린 ✅ PR 6건 전부 ✅ 이전 무마커 코멘트 0건). 판정은 여전히
  # 결정론·인덱스 기반이다(시각 비교 아님).
  #
  # 추출 실패는 전부 빈 값으로 떨어뜨려 `vi+1` 로 접는다(토큰 부재 · 본문 null · jq 오류
  # — 셋 다 "옛 ✅ 와 같이 다뤄라"). 이 폴백은 fail-open 이 아니다: 옛 경계와 같아질 뿐
  # ✅ **뒤**의 사람 코멘트는 하나도 놓치지 않는다.
  cut=$(printf '%s' "$comments" | jq -r --argjson vi "$vi" \
    '.[$vi].body | capture("코멘트 스냅샷 (?<n>[0-9]+)").n // empty' 2>/dev/null)
  case "$cut" in ''|*[!0-9]*) cut=$((vi + 1)) ;; esac
  # 경계는 스냅샷 토큰이 있어도 **절대 `vi+1` 을 넘지 않는다**(= min(N, vi+1)). N ≤ vi 는
  # 정상 경로에선 구조적으로 보장되지만(읽고 나서 게시하므로 ✅ 인덱스는 N 이상),
  # verify-runner 가 수를 잘못 적거나 ✅ 이후 코멘트가 **삭제**돼 배열이 줄면 깨진다.
  # 그때 경계가 ✅ 뒤로 밀리면 ✅ 이후의 사람 리뷰를 건너뛰는 fail-open 이 된다 — 이
  # 스크립트가 지키는 방향(증명 못 하면 통과 아님)의 정반대라 상한을 박아 둔다. 스냅샷 토큰가
  # 하는 일은 경계를 **앞으로** 당기는 것뿐이고, 뒤로 미는 힘은 주지 않는다.
  [ "$cut" -le "$vi" ] || cut=$((vi + 1))

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
    FC_HEAD_AT="$head_at" FC_FAILING=0 \
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
  # **세는 범위는 최신 `머지 판정: ✅` 이후뿐이다**(#379). ✅ 이전의 무마커 코멘트는
  # verify-runner 가 **보고 나서** ✅ 를 찍은 것이라 이미 해소된 사실이다 — 그걸 다시
  # 세는 건 같은 사실을 두 번 세는 것이고, 재심·리베이스를 여러 번 거친 PR 일수록
  # 무마커 보고가 쌓여 **더 잘 걸리는 역방향**이었다(실측 #5106: 워커 리베이스 보고 2건
  # + 사람 세션 재심 1건이 "미해결 사람 리뷰 3건" 으로 집계돼 조용히 큐에서 사라졌다).
  # 경계 `$vi` 는 위 긍정 게이트가 낸 ✅ 의 마지막 매칭 인덱스다(그 자리 주석 참조 —
  # 술어는 거기 한 벌뿐). `$comments` 는 이 회전 안에서 불변이라 그대로 재사용한다.
  # 실제로 쓰는 경계값은 `$cut` 이다 — ✅ 본문에 `코멘트 스냅샷 N` 토큰가 있으면 N,
  # 없으면 `vi+1`(위 스냅샷 토큰 주석). 스냅샷 토큰이 있는 ✅ 에선 verify-runner 의
  # 읽기~게시 사이에 낀 사람 코멘트(인덱스 N..vi-1)까지 잡힌다 = 경합 창 폐쇄(#384).
  #
  # fail-open 이 아니다: ✅ **뒤**의 사람 코멘트는 종전 그대로 후보를 막는다. 좁힌 것은
  # "언제부터 세는가" 뿐이고, 판정 이후 들어온 진짜 새 리뷰는 하나도 놓치지 않는다.
  #
  # 탈락은 stderr 한 줄로 **드러낸다** — `continue` 만 하면 큐에서 조용히 사라져
  # 아무도 눈치 못 챈다(조용한 큐 사망 금지, SKILL #206 원칙). 접두는 `warn:` 이 아니라
  # `blocked:` 다 — warn 은 **루프가 교정 가능한** 불변식 위반에만 쓴다(`loop-status.sh`
  # 정의 · #188: 조치 불가능한 warn 은 신호를 죽인다). 이 탈락은 사람이 답하거나
  # verify-runner 가 새 ✅ 를 찍어야 풀리는 **정당한 미집계**라 `eligible-issues.sh` 의
  # `blocked:` 줄과 같은 부류이고, ④ Report 가 그대로 한 줄로 옮긴다.
  unresolved=$(printf '%s' "$comments" | jq --argjson cut "$cut" '[ to_entries[]
    | select(.key >= $cut)
    | .value.body
    | select((contains("<!-- bodat:worker -->")
              or startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증")) | not)]
    | length')
  # 계산 자체가 실패해 빈 값이면 "0건" 으로 접지 않는다 — 판정 실패는 통과가 아니다
  # (fail-closed, 위 ✅ 갈래와 같은 방향). 종전 `${unresolved:-0}` 는 이 실패를 조용히
  # 통과시키는 구멍이었다(#384 보조 리뷰). jq 의 stderr 는 그대로 흘려 원인이 보이게 둔다.
  if [ -z "$unresolved" ]; then
    echo "blocked: PR #$pr($repo) — 미해결 코멘트 판정 실패(jq 빈 출력) — fail-closed" >&2
    continue
  fi
  if [ "$unresolved" -gt 0 ]; then
    echo "blocked: PR #$pr($repo) — ✅ 이후 미해결 코멘트 ${unresolved}건(마커 없음 = 사람 리뷰 대기)" >&2
    continue
  fi

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
