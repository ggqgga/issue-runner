#!/usr/bin/env bash
# verify-eligible.sh — verify-runner 후보 PR을 JSON lines 로 출력.
#
# 후보 조건: 열린 PR + head 가 agent/issue-* + `full-cycle` 라벨 미부착(사람 세션 레인, #246) +
#            `flow:verify` **또는 `verifying`** 라벨 부착 +
#            `harvesting` 미부착(closeout 이 이미 물었으면 제외) +
#            `needs-human`·`hold:*`(접두) 미부착(사람 대기·기계 정지는 손대지 않는다, #242).
# `flow:verify` = 워커가 구현+결정적CI+PR 까지 마치고 검증을 verify-runner 에 넘긴
# 소유 플래그(harvesting 과 동형). issue-runner 는 이 PR 을 건드리지 않고 in-flight
# 로도 안 센다 — **CI 상태 무관 전부 verify-runner 소유**(CI-fail 도 여기서 재디스패치
# 로 처리해 issue-runner 사각지대를 안 만든다). verify-runner 가 검증(E2E·codex) 후
# pass 면 flow:verify 를 떼고 `머지 판정: ✅`+flow:ready 로 closeout 에 넘긴다.
# `verifying`(#275) = verify-runner 가 **집는 순간** `flow:verify` 대신 붙이는 점유 라벨
# (transition.sh verify-pick — closeout 의 harvesting 동형). 판정(pass·redispatch·held)이
# 나면 출구 전이가 떼고, flake_retry(판정 아님)면 verify-unpick 이 flow:verify 로 되돌린다.
# 그래서 **틱 시작에 `verifying` 이 남아 있는 PR 은 정의상 이전 틱이 끝내지 못한 고아**다
# (verify-runner 는 단일 루프·직렬) — 별도 회수 스윕 없이 여기서 **먼저** 내보내
# 재개시키고, 그 줄에 `orphan:true` 를 실어 ④ Report 가 `고아 재집` 을 남기게 한다.
#
# 순서: `verifying`(고아 재개) 먼저 → 그 뒤 `flow:verify` FIFO(created asc — 오래된 PR
# 먼저). 두 라벨을 search 쿼리 둘로 각각 읽되(라벨 OR 쿼리에 기대지 않는다), **줄의 자리와
# `orphan` 값은 쿼리가 아니라 현재 라벨(meta)로** 정한다 — search 인덱스 지연·부분 전이로
# 한 PR 이 양쪽에 다 잡혀도 한 줄만 나오고(중복 제거), 두 라벨이 다 없으면(verify-pass 직후
# 인덱스에만 남은 PR) 후보가 아니다 — 라벨이 진실이다. 각 줄 안의 FIFO 는 search 갈래
# 순서가 아니라 PR 의 created 로 정렬한다(갈래 경계에서 순서가 뒤집히지 않게).
# 두 search 중 하나라도 gh 실패면 **후보를 내지 않는다**(fail-closed + stderr 한 줄) —
# verifying 갈래만 조용히 비면 "고아 먼저" 가 그 틱에 깨지는데 흔적이 없기 때문이다.
# 빈 결과(`[]`)는 실패가 아니다.
#
# 각 후보에 `ci` 필드(pass|revalidate|fail)를 실어 verify-runner 가 분기한다:
#   pass       결정적 CI 캐시 pass → 바로 E2E·codex 검증
#   revalidate rebase 등으로 HEAD 미실행(closeout-ci-pass exit 2) → worktree 동기화 후 재실행
#   fail       결정적 CI 실패 → 검증 안 하고 재디스패치(코드 회귀 — 워커로 반송)
#
# closeout-eligible.sh 동형 구조.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login 2>/dev/null); [ -n "$me" ] || exit 0

# shellcheck source=scripts/lib/scope.sh
. "$SCRIPT_DIR/lib/scope.sh"   # in_scope · scope_file 기본값 — 판정은 한 자리 (#427)

# 두 갈래를 임시 파일에 모아 마지막에 고아 → FIFO 순으로 합친다(bash 3.2 — 배열 누적 대신
# 파일. 파이프라인 안의 while 은 서브셸이라 변수 누적이 부모로 안 온다).
# 파일을 못 만들면 순서를 보장할 방법이 없으므로 후보를 내지 않고 끝낸다(fail-closed).
buf=$(mktemp -d "${TMPDIR:-/tmp}/verify-eligible.XXXXXX") || exit 0
trap 'rm -rf "$buf"' EXIT
: > "$buf/orphan"; : > "$buf/fifo"; : > "$buf/seen"

# search_prs <label> → [{repo,pr,created}] (created asc). gh 실패면 rc 비0(빈 결과 `[]` 와 구분).
search_prs() {
  gh api -X GET search/issues \
    -f q="user:$me is:open is:pr label:$1" -f per_page=50 \
    -f sort=created -f order=asc \
    -q '[.items[] | {repo:(.repository_url|sub(".*/repos/";"")), pr:.number, created:(.created_at // "")}]' 2>/dev/null
}

# 고아(verifying) 갈래를 먼저 읽는다 — 같은 PR 이 뒤 갈래에도 오면 seen 으로 거른다.
# 어느 갈래든 조회 실패면 이 틱은 후보 없음(fail-closed) — 이유는 위 머리 주석.
if ! prs_orphan=$(search_prs verifying); then
  echo "verify-eligible: search(verifying) 실패 — 이 틱 후보 없음" >&2; exit 0
fi
if ! prs_verify=$(search_prs flow:verify); then
  echo "verify-eligible: search(flow:verify) 실패 — 이 틱 후보 없음" >&2; exit 0
fi
[ -n "$prs_orphan" ] || [ -n "$prs_verify" ] || exit 0

{ [ -n "$prs_orphan" ] && printf '%s' "$prs_orphan" | jq -c '.[]'
  [ -n "$prs_verify" ] && printf '%s' "$prs_verify" | jq -c '.[]'; } | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repo')
  pr=$(printf '%s'  "$row" | jq -r '.pr')
  created=$(printf '%s' "$row" | jq -r '.created // ""')
  in_scope "$repo" || continue
  # 중복 제거 — 한 PR 이 두 쿼리에 다 잡혀도(인덱스 지연·부분 전이) 한 번만 본다.
  grep -qxF -- "$repo#$pr" "$buf/seen" && continue
  printf '%s#%s\n' "$repo" "$pr" >> "$buf/seen"

  meta=$(gh pr view "$pr" --repo "$repo" \
    --json headRefName,mergeable,labels,closingIssuesReferences 2>/dev/null)
  [ -n "$meta" ] || continue

  head=$(printf '%s' "$meta" | jq -r '.headRefName')
  case "$head" in agent/issue-*) : ;; *) continue ;; esac
  # 레인 두 번째 축 — `full-cycle` 라벨은 **명시적 제외**다(#246, 플랜 5단계). 위 head 필터와
  # AND 이지 OR 가 아니다: head 가 `agent/issue-*` 여도 라벨이 붙어 있으면 "루프 소유 아님".
  # 왜 브랜치 이름만으로는 부족한가 — `agent/issue-*` 는 make-worktree 의 **관례**지 라벨처럼
  # 강제되는 축이 아니다. 사람 세션(full-cycle 스킬)이 같은 접두의 브랜치를 쓰거나 루프가
  # 접두를 바꾸는 날 head 만 보는 판별은 조용히 깨진다. `full-cycle` 은 사람 세션 사이클이
  # 자기 산출물(구현 이슈·PR·배포 대기)에 붙이는 **레인 소유 표시**라 그 자체가 판정 근거다.
  # head 필터를 지우지 않는 이유는 라벨 도입 전에 열린 PR 들이 라벨 없이 남아 있어서다 —
  # 라벨은 보강이지 대체가 아니다. 판별은 배열 원소의 완전 일치(index)라 `full-cycle-*` 류는
  # 걸리지 않는다(과잉 제외는 검증 대기 PR 을 조용히 지우는 방향이라 원래 결함보다 나쁘다).
  # closeout-eligible.sh 의 같은 자리와 **같은 정의**다(격자 단언: tests/lane-gate.test.sh).
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("full-cycle")' >/dev/null && continue
  # closeout 이 이미 물었으면(harvesting) verify-runner 는 손대지 않는다.
  printf '%s' "$meta" | jq -e '[.labels[].name]|index("harvesting")' >/dev/null && continue
  # 사람 대기(needs-human) · 기계 정지(hold:*) 제외 (#242) — closeout-eligible.sh 의 같은
  # 자리와 **같은 정의**다(두 번째 계산기를 만들지 않는다. 격자 단언: tests/hold-gate.test.sh).
  #
  # 이 파일엔 지금까지 이 필터가 **없었다**. 평상시엔 transition.sh 의 `verify-held` 가
  # PR 에서 `flow:verify` 를 떼므로 위 서버 쿼리(label:flow:verify)에 애초에 안 잡혀서
  # 가려져 있었을 뿐이고, `runner-held`(#151)는 **flow:verify 를 떼지 않는다** — 디스패처가
  # 방금 정지시킨 PR 이 그대로 검증 후보로 떠서 정지가 무시된다. 순수 추가로 그 구멍을 막는다.
  # → 그래서 **이 한 자리는 오늘 동작이 바뀐다**(나머지 세 자리와 달리 무동작 안전망이 아니다):
  #   runner-held 로 정지된 PR 이 이 틱부터 verify 후보에서 빠진다.
  #
  # `hold:` 는 **접두사** 판별이라 사유가 늘어도 안 깨지고, `hold:` 로 시작하지 않는 라벨
  # (`holding`·`on-hold`·`area:hold`)은 걸리지 않는다 — 과잉 제외는 검증 대기 PR 을 조용히
  # 큐에서 지우는 방향이라 원래 결함보다 나쁘다.
  #
  # 해제는 **붙어 있는 정지 라벨을 다** 떼는 것이다 — `hold:*` 만 남아도 후보로
  # 돌아오지 않는다(기계 해제 경로는 이미 둘 다 뗀다: transition.sh `⊘hold`·resume-sweep 재개).
  printf '%s' "$meta" | jq -L "$SCRIPT_DIR/lib" -e \
    'include "loop"; [.labels[].name] | any(is_human_stop_label)' >/dev/null && continue
  printf '%s' "$meta" | jq -L "$SCRIPT_DIR/lib" -e \
    'include "loop"; [.labels[].name] | any(is_hold_label)' >/dev/null && continue   # 술어는 lib/loop.jq (#426)

  # 결정적 CI 상태를 분류해 실어보낸다(탈락 아님 — flow:verify 는 전부 소유).
  "$SCRIPT_DIR/closeout-ci-pass.sh" "$repo" "$pr"; cp=$?
  case "$cp" in
    0) ci=pass ;;
    2) ci=revalidate ;;
    *) ci=fail ;;
  esac

  # 연결 이슈는 `lib/loop.jq` 의 `linked_issue` 한 자리(#495) — finish-classify·closeout-eligible·
  # pr-state 와 같은 답. `[0]` 은 `Closes` 가 둘 이상인 PR 에서 남의 이슈를 가리켜(PR #113 head
  # 109·refs [108,109]) verify-pass/verify-redispatch 가 closeout 과 **다른 이슈**를 옮긴다 —
  # 검증→마감 인계의 이슈 정체성이 갈린다. 짝을 증명 못 하면 빈 값(fail-closed) — 소비자
  # (verify-runner 전이)는 종전처럼 빈 issue 를 "연결 없음" 으로 받는다.
  issue=$(printf '%s' "$meta" | jq -L "$SCRIPT_DIR/lib" -r 'include "loop";
    linked_issue(.headRefName; [(.closingIssuesReferences // [])[].number]) // empty')
  # 고아 판정은 **현재 라벨**로 — search 갈래가 아니다(라벨이 진실, 위 머리 주석).
  # 둘 다 없으면 이 루프 소유가 아니다(verify-pass 직후 인덱스 지연) — 후보에서 뺀다.
  if printf '%s' "$meta" | jq -e '[.labels[].name]|index("verifying")' >/dev/null; then
    orphan=true; dest="$buf/orphan"
  elif printf '%s' "$meta" | jq -e '[.labels[].name]|index("flow:verify")' >/dev/null; then
    orphan=false; dest="$buf/fifo"
  else
    continue
  fi
  # 줄 안 정렬 키 = created(탭 구분, 마지막에 잘라낸다). 빈 created 는 앞으로 가되 같은 키끼리는
  # 입력 순서를 유지한다(sort -s) — 갈래 순서가 곧 created 순인 평상시엔 무변동.
  printf '%s\t{"repo":"%s","pr":%s,"issue":"%s","head":"%s","ci":"%s","orphan":%s}\n' \
    "$created" "$repo" "$pr" "$issue" "$head" "$ci" "$orphan" >> "$dest"
done

# 고아(재개) 먼저, 그 뒤 검증대기 — 각 줄은 created asc(FIFO).
for f in orphan fifo; do
  sort -s -t "$(printf '\t')" -k1,1 "$buf/$f" | cut -f2-
done
