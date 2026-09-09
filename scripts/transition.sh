#!/usr/bin/env bash
# 루프 전이 = 라벨 이동. 세 루프(issue-runner·verify-runner·closeout)가 산문으로 흩어서
# 하던 `gh issue edit`(PR + 연결 이슈 미러)를 **전이 하나 = 호출 하나**로 묶는다. 흩어져
# 있으면 한쪽만 고쳐져 PR 과 이슈의 라벨이 갈리고, 다음 틱이 어긋난 쪽을 진실로 읽는다.
#
# 사용: transition.sh <전이> <owner/repo> <issue#|-> [pr#|-]
#   `-` = 그쪽 없음(연결 이슈 없는 PR / PR 없는 이슈). 둘 다 `-` 면 usage 오류(exit 64).
#
# ★전이 표 — 이 표가 SSOT★ (스킬 문서가 산문 대신 이 표를 가리킨다. 이슈는 OPEN 기준)
#
#   전이                  | PR add      | PR remove                          | 이슈 add    | 이슈 remove
#   ----------------------|-------------|------------------------------------|-------------|------------------------------------------------
#   handoff-verify        | flow:verify | flow:ci flow:codex                 | flow:verify | agent:claimed
#   verify-pass           | flow:ready  | flow:verify                        | flow:ready  | flow:verify
#   verify-redispatch     | —           | flow:verify                        | agent-ready | flow:verify agent:claimed
#   verify-held           | —           | flow:verify                        | needs-human | flow:verify agent:claimed
#   closeout-pick         | harvesting  | flow:ready flow:codex flow:ci flow:verify | harvesting | flow:ready flow:verify
#   closeout-blocked      | —           | harvesting                         | needs-human | harvesting flow:ready flow:verify
#   closeout-redispatch   | —           | harvesting flow:ready flow:verify   | agent-ready | harvesting flow:ready flow:verify agent:claimed
#
#   · `agent-ready` 는 사다리 전체에서 유지되는 **자격** 라벨 — 위에서 명시적으로 add 하는
#     칸 외엔 건드리지 않는다(어느 remove 칸에도 없다). 근거는 release-labels.sh 의 #117:
#     OPEN 이슈의 agent-ready 를 떼면 디스패치 자격만 사라져 조용히 좌초한다.
#   · `needs-human` 은 직교하는 일시정지 플래그 — 위에 적힌 전이 외엔 건드리지 않는다.
#
# 멱등: 같은 전이를 두 번 걸어도 무해하다(`--remove-label` 은 없는 라벨에 무해).
# 검증: edit 뒤 라벨을 **다시 읽어** add ⊆ 현재 · remove ∩ 현재 = ∅ 인지 확인한다.
#   불일치 → stderr 한 줄 + exit 1 / gh 호출 자체 실패(네트워크·권한) → stderr + exit 2.
#   라벨 부재(`not found`)면 setup-labels.sh 를 **프로세스당 1회** 돌리고 같은 edit 를
#   **1회만** 재시도한다(무한루프 금지).
set -uo pipefail

usage() {
  echo "usage: transition.sh <전이> <owner/repo> <issue#|-> [pr#|-]" >&2
  echo "  전이: handoff-verify verify-pass verify-redispatch verify-held \\" >&2
  echo "        closeout-pick closeout-blocked closeout-redispatch" >&2
  exit 64
}

name=${1:-}
repo=${2:-}
issue=${3:-}
pr=${4:--}

[ -n "$name" ] && [ -n "$repo" ] && [ -n "$issue" ] || usage
case "$repo" in */*) ;; *) usage ;; esac
# 둘 다 없으면 적용할 대상이 없다 — 조용한 no-op 대신 usage 오류로 드러낸다.
[ "$issue" = "-" ] && [ "$pr" = "-" ] && usage

case "$name" in
  handoff-verify)
    pr_add="flow:verify"; pr_rm="flow:ci flow:codex"
    iss_add="flow:verify"; iss_rm="agent:claimed" ;;
  verify-pass)
    pr_add="flow:ready"; pr_rm="flow:verify"
    iss_add="flow:ready"; iss_rm="flow:verify" ;;
  verify-redispatch)
    pr_add=""; pr_rm="flow:verify"
    iss_add="agent-ready"; iss_rm="flow:verify agent:claimed" ;;
  verify-held)
    pr_add=""; pr_rm="flow:verify"
    iss_add="needs-human"; iss_rm="flow:verify agent:claimed" ;;
  closeout-pick)
    pr_add="harvesting"; pr_rm="flow:ready flow:codex flow:ci flow:verify"
    iss_add="harvesting"; iss_rm="flow:ready flow:verify" ;;
  closeout-blocked)
    pr_add=""; pr_rm="harvesting"
    iss_add="needs-human"; iss_rm="harvesting flow:ready flow:verify" ;;
  closeout-redispatch)
    pr_add=""; pr_rm="harvesting flow:ready flow:verify"
    iss_add="agent-ready"; iss_rm="harvesting flow:ready flow:verify agent:claimed" ;;
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
  case "$out" in
    *"not found"*|*"Not Found"*|*"could not add label"*|*"could not remove label"*)
      if [ "$labels_fixed" -eq 0 ]; then
        labels_fixed=1
        "$(dirname "$0")/setup-labels.sh" "$repo" >/dev/null 2>&1 || true
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
