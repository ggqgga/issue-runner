#!/usr/bin/env bash
# 루프 전이 = 라벨 이동. 세 루프(issue-runner·verify-runner·closeout)가 산문으로 흩어서
# 하던 `gh issue edit`(PR + 연결 이슈 미러)를 **전이 하나 = 호출 하나**로 묶는다. 흩어져
# 있으면 한쪽만 고쳐져 PR 과 이슈의 라벨이 갈리고, 다음 틱이 어긋난 쪽을 진실로 읽는다.
#
# 사용: transition.sh <전이> <owner/repo> <issue#|-> [pr#|-] [--reason R] [--note "…"]
#   `-` = 그쪽 없음(연결 이슈 없는 PR / PR 없는 이슈). 둘 다 `-` 면 usage 오류(exit 64).
#   옵션(`--reason`·`--note`)은 인자 어디에 와도 된다(맨 앞/뒤 모두 허용).
#
# ★전이 표 — 이 표가 SSOT★ (스킬 문서가 산문 대신 이 표를 가리킨다. 이슈는 OPEN 기준)
#
#   전이                  | PR add      | PR remove                          | 이슈 add    | 이슈 remove
#   ----------------------|-------------|------------------------------------|-------------|------------------------------------------------
#   handoff-verify        | flow:verify | flow:ci flow:codex                 | flow:verify | agent:claimed
#   verify-pass           | flow:ready  | flow:verify                        | flow:ready  | flow:verify
#   verify-redispatch     | —           | flow:verify ⊘hold                  | agent-ready | flow:verify agent:claimed ⊘hold
#   verify-held †         | needs-human hold:R | flow:verify ⊘R              | needs-human hold:R | flow:verify agent:claimed ⊘R
#   closeout-pick         | harvesting  | flow:ready flow:codex flow:ci flow:verify | harvesting | flow:ready flow:verify
#   closeout-blocked †    | needs-human hold:R | harvesting ⊘R               | needs-human hold:R | harvesting flow:ready flow:verify ⊘R
#   closeout-redispatch   | —           | harvesting flow:ready flow:verify ⊘hold | agent-ready | harvesting flow:ready flow:verify agent:claimed ⊘hold
#   runner-held(#151)     | needs-human hold:<r> | (다른 hold)                        | needs-human hold:<r> | agent:claimed (다른 hold)
#   closeout-dup ‡        | dup         | harvesting flow:ci flow:codex flow:verify flow:ready | (라벨 편집 없음 — ④ release-labels.sh) |
#
#   기호: `hold:R` = `hold:<--reason>` · `⊘R` = 나머지 두 `hold:*`(사유 교체가 멱등이 되게)
#         `⊘hold` = `needs-human hold:conflict hold:policy hold:ladder`(반송 = 사람 대기 해제)
#         † `--reason <conflict|policy|ladder>` 필수 · ‡ `--note "<근거>"` 필수
#
#   · `agent-ready` 는 사다리 전체에서 유지되는 **자격** 라벨 — 위에서 명시적으로 add 하는
#     칸 외엔 건드리지 않는다(어느 remove 칸에도 없다). 근거는 release-labels.sh 의 #117:
#     OPEN 이슈의 agent-ready 를 떼면 디스패치 자격만 사라져 조용히 좌초한다.
#     (예외는 closeout-dup 뿐 — 이슈를 **닫으므로** release-labels.sh 가 회수한다.)
#   · `needs-human` 은 직교하는 일시정지 플래그 — 위에 적힌 전이 외엔 건드리지 않는다.
#     사람 대기 두 전이(verify-held·closeout-blocked)는 **PR 에도** 붙인다: 연결 이슈 없는
#     PR(`issue=-`)은 정식 호출 형태인데, 이슈에만 붙이면 사람 신호가 아무 데도 안 남고
#     exit 0 `ok` 로 끝나 조용히 사라진다.
#   · 사람 대기 사유는 라벨이다(#147) — `needs-human` 만으론 왜 멈췄는지 목록에서 안 보여
#     사유 없는 쓰레기통이 됐다. 그래서 `--reason` 이 **필수**고, `dup`·`hardware` 는 사유가
#     될 수 없다: 중복은 `closeout-dup` 이 닫고, 실장비는 검증 사다리를 오른다.
#   · 반송 두 전이(verify-redispatch·closeout-redispatch)는 `needs-human`·`hold:*` 를 뗀다 —
#     반송 = 사람 대기 해제. 재개 스윕(#147 §4)이 이 전이로 멈춘 건을 다시 태운다.
#
# ★closeout-dup 순서★ — 이슈가 요구한 수정이 **이미 main 에 있을 때** 루프가 직접 닫는다
#   (`needs-human` 금지 — 루프가 결정할 수 있는 건 루프가 끝낸다).
#     ① PR 라벨 `dup` 부착 + `harvesting`·`flow:*` 제거   ② PR 코멘트(근거)
#     ③ 이슈 코멘트 + `gh issue close`                    ④ `release-labels.sh`(닫힌 이슈
#        라 agent-ready 까지 회수)                        ⑤ **마지막에** `gh pr close`
#     이슈가 `-` 면 ①②⑤ 만.
#   ★PR close 가 왜 마지막인가★ — 먼저 닫으면 뒤(③④)가 실패했을 때 PR 이 CLOSED 라
#   closeout 의 다음 틱이 **다시 집지 못한다**(복구 불능). 마지막에 두면 중간 실패 시
#   PR 은 `dup` 라벨을 단 채 열려 남고, 다음 틱이 같은 전이를 다시 걸어 완주한다.
#   그래서 ①~④ 는 전부 멱등이어야 한다 — 라벨 편집은 원래 멱등이고, 코멘트는 중복을
#   감수한다(근거가 두 번 남는 쪽이 안 남는 쪽보다 낫다).
#   멱등: 이미 CLOSED 인 쪽의 close 만 건너뛴다. readback 은 순서가 아니라 **최종 상태**
#   (PR 라벨 dup 부착·harvesting 부재 · PR/이슈 CLOSED)를 본다.
#
# ★사람 대기 세 전이의 순서★ (#157) — `--note` 가 붙는 verify-held·closeout-blocked·
#   runner-held 는 **질문 코멘트 → 라벨 편집 → readback** 순이다. 코멘트가 뒤였을 땐 코멘트
#   API 의 일시 실패가 "라벨은 붙었는데 질문이 없는 홀드" 를 남겼고(재시도 주체 없음),
#   앞으로 옮기면 그 실패가 라벨 편집 전에 exit 2 로 끝나 상태가 전이 이전 그대로 남는다 —
#   호출부가 다음 틱에 같은 전이를 다시 걸면 그게 곧 재시도다. `--note` 가 없는 전이는
#   이 단계를 아예 거치지 않으므로 종전 경로 그대로다.
#
# 멱등: 같은 전이를 두 번 걸어도 무해하다(`--remove-label` 은 없는 라벨에 무해).
# 검증: edit 뒤 라벨을 **다시 읽어** add ⊆ 현재 · remove ∩ 현재 = ∅ 인지 확인한다.
#   불일치 → stderr 한 줄 + exit 1 / gh 호출 자체 실패(네트워크·권한) → stderr + exit 2.
#   라벨 부재(`not found`)면 setup-labels.sh 를 **프로세스당 1회** 돌리고 같은 edit 를
#   (실측 2026-09-09: 레포에 **없는** 라벨은 `--remove-label` 도 편집 전체를 실패시킨다 —
#   gh 메시지는 `'hold:conflict' not found` 형식이라 "label" 단어가 없다. 따옴표 형식도 잡는다.)
#   **1회만** 재시도한다(무한루프 금지).
set -uo pipefail

usage() {
  echo "usage: transition.sh <전이> <owner/repo> <issue#|-> [pr#|-] [--reason R] [--note \"…\"]" >&2
  echo "  전이: handoff-verify verify-pass verify-redispatch verify-held \\" >&2
  echo "        closeout-pick closeout-blocked closeout-redispatch closeout-dup runner-held" >&2
  echo "  --reason <conflict|policy|ladder>: verify-held·closeout-blocked·runner-held 에 **필수**(다른 전이엔 금지)" >&2
  echo "        dup 은 closeout-dup 이 닫고, hardware 는 검증 사다리를 오른다 — 사유가 될 수 없다" >&2
  echo "  --note \"<근거>\": closeout-dup 에 **필수** · --reason policy|conflict 에 **필수**(사람이 답해야 할" >&2
  echo "        질문 한 줄 — 코멘트로 남는다) · ladder 는 선택 · 그 밖의 전이엔 금지" >&2
  exit 64
}

# 옵션은 위치 무관 — 먼저 훑어 걷어내고 남은 것만 위치 인자로 본다(bash 3.2: 배열만 사용).
reason=""; note=""; has_reason=0; has_note=0
rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)   shift; [ $# -gt 0 ] || usage; reason=$1; has_reason=1 ;;
    --reason=*) reason=${1#--reason=}; has_reason=1 ;;
    --note)     shift; [ $# -gt 0 ] || usage; note=$1; has_note=1 ;;
    --note=*)   note=${1#--note=}; has_note=1 ;;
    *)          rest+=("$1") ;;
  esac
  shift
done
# 빈 배열 전개는 bash 3.2 + `set -u` 에서 unbound 오류다 — `${a[@]+…}` 로 감싼다.
set -- ${rest[@]+"${rest[@]}"}

name=${1:-}
repo=${2:-}
issue=${3:-}
pr=${4:--}

[ -n "$name" ] && [ -n "$repo" ] && [ -n "$issue" ] || usage
case "$repo" in */*) ;; *) usage ;; esac
# 둘 다 없으면 적용할 대상이 없다 — 조용한 no-op 대신 usage 오류로 드러낸다.
[ "$issue" = "-" ] && [ "$pr" = "-" ] && usage

# 사유 검증 — 없거나 허용값 밖(dup·hardware 포함)이면 usage. 사유 없는 `needs-human` 을
# 만들 수 없게 하는 게 목적이라 "빠뜨리면 조용히 기본값" 은 쓰지 않는다.
case "$name" in
  verify-held|closeout-blocked|runner-held)
    case "$reason" in conflict|policy|ladder) ;; *) usage ;; esac ;;
  *)
    # 다른 전이에 준 --reason 은 무시하지 않는다 — 무시하면 호출부가 붙였다고 착각한다.
    [ "$has_reason" -eq 1 ] && usage ;;
esac
case "$name" in
  closeout-dup) [ -n "$note" ] || usage ;;
  verify-held|closeout-blocked|runner-held)
    # policy·conflict = 사람이 결정해야 하는 것 → "사람이 답해야 할 질문 한 줄" 이 없으면
    # 사람 몫이 아니다(질문을 못 쓰면 루프가 스스로 답할 수 있는 일이다). ladder 는 선택.
    case "$reason" in policy|conflict) [ -n "$note" ] || usage ;; esac ;;
  *) [ "$has_note" -eq 1 ] && usage ;;
esac
# closeout-dup 은 닫을 PR 이 있어야 성립한다(`pr=-` 면 ①②가 통째로 사라진다).
[ "$name" = "closeout-dup" ] && [ "$pr" = "-" ] && usage

# 사유 교체가 멱등이 되게 — 붙이는 사유 외 나머지 두 hold:* 는 remove 집합에 넣는다.
HOLD_ALL="hold:conflict hold:policy hold:ladder"
hold_others() {
  case "$1" in
    conflict) echo "hold:policy hold:ladder" ;;
    policy)   echo "hold:conflict hold:ladder" ;;
    ladder)   echo "hold:conflict hold:policy" ;;
  esac
}

case "$name" in
  handoff-verify)
    pr_add="flow:verify"; pr_rm="flow:ci flow:codex"
    iss_add="flow:verify"; iss_rm="agent:claimed" ;;
  verify-pass)
    pr_add="flow:ready"; pr_rm="flow:verify"
    iss_add="flow:ready"; iss_rm="flow:verify" ;;
  verify-redispatch)
    pr_add=""; pr_rm="flow:verify needs-human $HOLD_ALL"
    iss_add="agent-ready"; iss_rm="flow:verify agent:claimed needs-human $HOLD_ALL" ;;
  verify-held)
    pr_add="needs-human hold:$reason"; pr_rm="flow:verify $(hold_others "$reason")"
    iss_add="needs-human hold:$reason"; iss_rm="flow:verify agent:claimed $(hold_others "$reason")" ;;
  closeout-pick)
    pr_add="harvesting"; pr_rm="flow:ready flow:codex flow:ci flow:verify"
    iss_add="harvesting"; iss_rm="flow:ready flow:verify" ;;
  closeout-blocked)
    pr_add="needs-human hold:$reason"; pr_rm="harvesting $(hold_others "$reason")"
    iss_add="needs-human hold:$reason"; iss_rm="harvesting flow:ready flow:verify $(hold_others "$reason")" ;;
  closeout-redispatch)
    pr_add=""; pr_rm="harvesting flow:ready flow:verify needs-human $HOLD_ALL"
    iss_add="agent-ready"; iss_rm="harvesting flow:ready flow:verify agent:claimed needs-human $HOLD_ALL" ;;
  runner-held)
    # 디스패처(issue-runner) 자체의 사람 대기 — 죽은 워커 BLOCKED · 보수 상한(#151).
    # PR 이 없을 수 있어 `-` 허용. 사다리 라벨(flow:*·harvesting)은 건드리지 않는다 — 디스패처가
    # 멈추는 시점의 PR 은 워커 소유 단계(flow:ci/없음)라 뗄 단계 라벨이 없다.
    pr_add="needs-human hold:$reason"; pr_rm="$(hold_others "$reason")"
    iss_add="needs-human hold:$reason"; iss_rm="agent:claimed $(hold_others "$reason")" ;;
  closeout-dup)
    # 라벨 이동은 ① 단계뿐 — PR 만. 이슈 라벨은 ④ release-labels.sh 가 정리한다.
    pr_add="dup"; pr_rm="harvesting flow:ci flow:codex flow:verify flow:ready"
    iss_add=""; iss_rm="" ;;
  *) usage ;;
esac

labels_fixed=0   # setup-labels.sh 보강은 프로세스당 1회 (PR·이슈가 각각 물어도 1회)

# build_args <adds> <rms> → EDIT_ARGS
# 라벨 집합은 공백 구분 문자열이다(bash 3.2 — 연관배열·mapfile 금지).
build_args() {
  EDIT_ARGS=()
  local l
  # shellcheck disable=SC2086  # 의도적 단어분리 — 인자는 공백 구분 라벨 목록이다
  for l in $1; do EDIT_ARGS+=(--add-label "$l"); done
  # shellcheck disable=SC2086  # 위와 같은 이유
  for l in $2; do EDIT_ARGS+=(--remove-label "$l"); done
}

# run_edit <side> <num> <adds> <rms> → 0 성공 / 2 gh 실패
run_edit() {
  local side=$1 num=$2 out=""
  build_args "$3" "$4"
  [ ${#EDIT_ARGS[@]} -eq 0 ] && return 0
  if out=$(gh issue edit "$num" --repo "$repo" "${EDIT_ARGS[@]}" 2>&1); then
    return 0
  fi
  # 라벨이 레포에 아직 없을 뿐이면 한 번만 보강하고 재시도한다.
  # 패턴은 **라벨 문맥으로 좁힌다** — 맨숭한 `not found` 까지 받으면 오타 이슈 번호의 404
  # 에도 setup-labels.sh(라벨 전량 --force + `gh repo edit`)라는 쓰기를 돌리게 된다.
  case "$out" in
    *"could not add label"*|*"could not remove label"*|*[Ll]abel*"not found"*|*"' not found"*)
      if [ "$labels_fixed" -eq 0 ]; then
        labels_fixed=1
        # 보강 실패(스크립트 부재·권한·부분 적용)를 삼키지 않는다 — 이어지는 재시도가
        # 성공해도 레포엔 라벨이 반만 깔렸을 수 있어 사람이 알아야 한다.
        if ! sl_out=$("$(dirname "$0")/setup-labels.sh" "$repo" 2>&1); then
          echo "transition $name: 라벨 보강 실패(부분 적용 가능) — $(printf '%s\n' "$sl_out" | grep -v '^$' | tail -1)" >&2
        fi
      fi
      if out=$(gh issue edit "$num" --repo "$repo" "${EDIT_ARGS[@]}" 2>&1); then
        return 0
      fi ;;
  esac
  echo "transition $name: $side #$num 라벨 편집 실패 — $out" >&2
  return 2
}

# verify_side <side> <num> <adds> <rms> → 0 일치 / 1 불일치 / 2 조회 실패
verify_side() {
  local side=$1 num=$2 json="" cur="" l
  if ! json=$(gh issue view "$num" --repo "$repo" --json labels 2>&1); then
    echo "transition $name: $side #$num 라벨 재조회 실패 — $json" >&2
    return 2
  fi
  if ! cur=$(printf '%s' "$json" | jq -r '.labels[].name' 2>&1); then
    echo "transition $name: $side #$num 라벨 응답 파싱 실패 — $cur" >&2
    return 2
  fi
  # shellcheck disable=SC2086  # 의도적 단어분리 — 공백 구분 라벨 목록
  for l in $3; do
    printf '%s\n' "$cur" | grep -qxF -- "$l" && continue
    echo "transition $name: $side #$num 라벨 불일치 — '$l' 미부착" >&2
    return 1
  done
  # shellcheck disable=SC2086  # 위와 같은 이유
  for l in $4; do
    printf '%s\n' "$cur" | grep -qxF -- "$l" || continue
    echo "transition $name: $side #$num 라벨 불일치 — '$l' 잔존" >&2
    return 1
  done
  return 0
}

# gh_state <pr|issue> <num> → stdout OPEN|CLOSED|MERGED / rc 2 조회·파싱 실패
gh_state() {
  local kind=$1 num=$2 json="" st=""
  if ! json=$(gh "$kind" view "$num" --repo "$repo" --json state 2>&1); then
    echo "transition $name: $kind #$num 상태 조회 실패 — $json" >&2
    return 2
  fi
  if ! st=$(printf '%s' "$json" | jq -r '.state' 2>&1); then
    echo "transition $name: $kind #$num 상태 응답 파싱 실패 — $st" >&2
    return 2
  fi
  printf '%s' "$st"
}

# ── closeout-dup — 라벨 이동이 아니라 "닫기" 라 흐름이 다르다(위 순서 주석 참조) ──────
if [ "$name" = "closeout-dup" ]; then
  # ① PR 라벨: dup 부착 + harvesting·flow:* 제거
  run_edit pr "$pr" "$pr_add" "$pr_rm" || exit 2

  # ② PR 에 근거를 남긴다 — **무조건**. close 조건에 묶으면 재실행 때 근거가 안 남는다.
  #    본문은 printf 로 만든다: 인용 안 한 heredoc 은 lint-heredoc.sh 대상이고, 인용한
  #    heredoc 은 $note 를 전개하지 않는다.
  body=$(printf '중복 종료: %s\n<!-- bodat:worker -->' "$note")
  if ! out=$(gh pr comment "$pr" --repo "$repo" --body "$body" 2>&1); then
    echo "transition $name: pr #$pr 코멘트 실패 — $out" >&2
    exit 2
  fi

  if [ "$issue" != "-" ]; then
    # ③ 이슈에 근거를 남기고 닫는다. 코멘트는 close 를 건너뛰는 재실행에도 남긴다 —
    #    사유가 안 남은 채 닫힌 이슈를 만들지 않기 위해서다.
    body=$(printf '중복: %s — PR #%s 머지 없이 종료\n<!-- bodat:worker -->' "$note" "$pr")
    if ! out=$(gh issue comment "$issue" --repo "$repo" --body "$body" 2>&1); then
      echo "transition $name: issue #$issue 코멘트 실패 — $out" >&2
      exit 2
    fi
    st=$(gh_state issue "$issue") || exit 2
    if [ "$st" = "OPEN" ]; then
      if ! out=$(gh issue close "$issue" --repo "$repo" 2>&1); then
        echo "transition $name: issue #$issue 종료 실패 — $out" >&2
        exit 2
      fi
    fi
    # ④ 라벨 정리 — **닫은 뒤에** 부른다(release-labels.sh 는 CLOSED 일 때만 agent-ready
    #    까지 회수한다). best-effort 라 흐름은 안 막지만, 조용히 넘기지도 않는다 —
    #    회수가 빠지면 닫힌 이슈에 실행 흔적 라벨이 남아 다음 틱이 오판할 수 있다.
    if ! "$(dirname "$0")/release-labels.sh" "$repo" "$issue"; then
      echo "transition $name: issue #$issue 라벨 회수 실패(best-effort) — 사람 확인" >&2
    fi
  fi

  # ⑤ 마지막에 PR 을 머지 없이 닫는다(위 순서 주석 참조). 이미 닫혀 있으면 건너뛴다.
  st=$(gh_state pr "$pr") || exit 2
  if [ "$st" = "OPEN" ]; then
    if ! out=$(gh pr close "$pr" --repo "$repo" 2>&1); then
      echo "transition $name: pr #$pr 종료 실패 — $out" >&2
      exit 2
    fi
  fi

  # readback — 순서가 아니라 최종 상태: PR 라벨(dup 부착·harvesting 부재) + 양쪽 CLOSED
  verify_side pr "$pr" "$pr_add" "$pr_rm" || exit $?
  st=$(gh_state pr "$pr") || exit 2
  if [ "$st" != "CLOSED" ]; then
    echo "transition $name: pr #$pr 상태 불일치 — CLOSED 아님($st)" >&2
    exit 1
  fi
  if [ "$issue" != "-" ]; then
    st=$(gh_state issue "$issue") || exit 2
    if [ "$st" != "CLOSED" ]; then
      echo "transition $name: issue #$issue 상태 불일치 — CLOSED 아님($st)" >&2
      exit 1
    fi
  fi
  echo "transition $name $repo issue=$issue pr=$pr  ok"
  exit 0
fi

# ★질문 코멘트가 라벨보다 먼저★ (#157) — 코멘트가 라벨 **뒤**였을 때, 코멘트 API 의 일시
# 실패(502 등)는 exit 2 로 끝나면서도 라벨(`needs-human`+`hold:*`)은 이미 붙여 놓았다.
# 남는 건 "질문 없는 홀드" — 사람은 무엇을 답해야 할지 모르고, 재심(resume-sweep)은
# `hold:policy` 를 `no-note` warn 으로만 흘리며(hold:conflict 는 그마저 없다) 아무도
# 재시도하지 않는다. 순서를 뒤집으면 실패가 라벨 편집 **전에** 나므로 상태는 전이 이전
# 그대로고, 호출부(BLOCKED)가 다음 틱에 같은 전이를 통째로 다시 걸어 자연히 재시도된다.
# 반대 방향의 부분 실패(코멘트만 남고 라벨이 실패)는 무해하다 — 다음 시도가 코멘트를
# 한 번 더 남길 뿐이고(중복 감수), 마커를 읽는 쪽은 마지막 것을 기준으로 본다.
# 마커 `<!-- hold-note: <reason> -->` 는 loop-status/재심(resume-sweep policy_review_due)이 읽는다.
if [ "$has_note" -eq 1 ] && [ -n "$note" ]; then
  case "$name" in
    verify-held|closeout-blocked|runner-held)
      body=$(printf '사람 확인(%s): %s\n<!-- hold-note: %s --><!-- bodat:worker -->' "$reason" "$note" "$reason")
      for side in issue pr; do
        if [ "$side" = issue ]; then n=$issue; else n=$pr; fi
        [ "$n" != "-" ] || continue
        if ! out=$(gh "$side" comment "$n" --repo "$repo" --body "$body" 2>&1); then
          echo "transition $name: $side #$n 사유 코멘트 실패(라벨 미편집 — 다음 틱 재시도) — $out" >&2
          exit 2
        fi
      done ;;
  esac
fi

# 편집 먼저 양쪽, 그다음 재조회 양쪽 — 한쪽 실패는 즉시 종료(fail-loud).
if [ "$pr" != "-" ]; then
  run_edit pr "$pr" "$pr_add" "$pr_rm" || exit 2
fi
if [ "$issue" != "-" ]; then
  run_edit issue "$issue" "$iss_add" "$iss_rm" || exit 2
fi
if [ "$pr" != "-" ]; then
  verify_side pr "$pr" "$pr_add" "$pr_rm" || exit $?
fi
if [ "$issue" != "-" ]; then
  verify_side issue "$issue" "$iss_add" "$iss_rm" || exit $?
fi
echo "transition $name $repo issue=$issue pr=$pr  ok"
