#!/usr/bin/env bash
# 마감 후보 PR을 JSON lines 로 출력. 진입 조건 모두 충족 + harvesting 미부착.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0

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

  meta=$(gh pr view "$pr" --repo "$repo" \
    --json headRefName,mergeable,labels,comments,closingIssuesReferences 2>/dev/null)
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

  printf '%s' "$meta" \
    | jq -e '[.comments[].body] | map(select(startswith("머지 판정: ✅") or startswith("Merge verdict: ✅"))) | length > 0' \
    >/dev/null || continue

  # 결정론 재사용 — finish-classify.sh 의 head-SHA 대조 판정을 그대로 쓴다(#171 개발계획
  # 2항: 로직 두 벌 금지). ✅ 존재만으로 후보 삼지 않는다 — 반송(재디스패치) 뒤 새
  # 커밋이 올라왔는데 그 커밋 이전에 찍힌 ✅ 가 남아 있으면 finish-classify 가
  # done_verdict 를 내지 않고(active) 여기서도 걸러진다.
  # FC_COMMENTS_JSON 으로 이미 가져온 comments 를 그대로 넘겨 중복 gh 조회를 피한다
  # (head 커밋 시각·failing 은 finish-classify 가 자체 실측 — 여기 meta 에 없다).
  verdict=$(FC_COMMENTS_JSON="$(printf '%s' "$meta" | jq -c '.comments')" \
    "$SCRIPT_DIR/finish-classify.sh" "$repo" "$pr" 2>/dev/null)
  [ "$verdict" = "done_verdict" ] || continue

  # 재디스패치 마커 안전망(#171 개발계획 3항) — 1·2 의 head-SHA 시각 비교가 못 잡는
  # 창을 막는다: 반송 직후 워커가 아직 새 커밋을 안 올렸으면 head 커밋 시각이 그대로라
  # finish-classify 도 done_verdict 를 낼 수 있다(코멘트 시각과 커밋 시각의 시계가
  # 다를 수 있다는 전제). 최신 `재디스패치:` 코멘트가 최신 ✅ 코멘트보다 **뒤**면(그
  # 사이 새 ✅ 가 안 찍혔으면) 후보에서 뺀다. createdAt 은 둘 다 ISO8601 UTC(...Z) 라
  # 문자열 비교로 시간순이 보존된다(reconcile.sh:278 와 같은 관행).
  redispatch_at=$(printf '%s' "$meta" | jq -r \
    '[.comments[] | select(.body|startswith("재디스패치:"))] | last | .createdAt // empty')
  if [ -n "$redispatch_at" ]; then
    verdict_at=$(printf '%s' "$meta" | jq -r \
      '[.comments[] | select((.body|startswith("머지 판정: ✅")) or (.body|startswith("Merge verdict: ✅")))] | last | .createdAt // empty')
    if [ -z "$verdict_at" ] || [[ "$redispatch_at" > "$verdict_at" ]]; then
      continue
    fi
  fi

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
  unresolved=$(printf '%s' "$meta" | jq '[.comments[].body
    | select((contains("<!-- bodat:worker -->")
              or startswith("머지 판정") or startswith("검증자 리뷰") or startswith("마감 검증")) | not)]
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
