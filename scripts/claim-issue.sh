#!/usr/bin/env bash
# usage: claim-issue.sh <owner/repo> <issue-number>
# 검색 인덱스 지연 방어: claim 직전에 직접 API로 라벨 재확인(이중 디스패치 방지),
# claim 직후 재조회로 부착 확인.
#
# 라벨/assignee 부착은 **멱등**이라 그 자체로는 잠금이 못 된다 — 두 루프 세션이
# 사전 재확인을 함께 통과하면 둘 다 "성공"해 같은 이슈를 집는다(#108). GitHub 에서
# 진짜 원자적인 create-only 프리미티브는 **ref 생성**뿐(POST /git/refs 는 이미 있는
# ref 에 422 를 낸다) — 그래서 라벨을 붙이기 전에 잠금 ref 를 먼저 잡는다.
#
#   잠금 ref: refs/issue-runner/claim/<이슈번호>/<앵커>
#   앵커 = 원격 브랜치 agent/issue-<N> 의 head sha, 없으면 리터럴 `base`
#
# 앵커를 sha 로 두는 이유: 보수 재투입(re-dispatch)에서 브랜치는 정당하게 이미
# 존재한다. attempt 마다 head sha 가 달라지므로 잠금도 attempt 마다 새로 열린다 —
# 이전 attempt 의 잠금이 다음 attempt 를 막지 않는다(잠금 해제 배선·TTL 불필요).
#
# 워커가 **커밋을 하나도 안 남기고** 죽으면 다음 attempt 의 앵커가 이전과 같아 잠금이
# 이미 존재한다. 그 경우만 "경합 패배"와 "이전 attempt 의 스테일 잠금"을 구분해야
# 하므로, 422 를 받으면 대기창 동안 이슈를 반복 조회해 `agent:claimed` 유무로 판정한다
# (경쟁자가 살아 있으면 그 사이 라벨을 붙인다).
#
# 스테일로 판정해도 **그대로 진행하면 안 된다** — 신규 세션 둘이 같은 스테일 잠금에
# 동시에 들어오면 둘 다 422 를 받고 둘 다 라벨 없음을 보므로 둘 다 claim 한다(1차 잠금은
# 남이 만든 것이라 이들 사이의 중재력이 없다). 그래서 인수 자체를 create-only ref 로
# 한 번 더 중재한다:
#
#   takeover ref: refs/issue-runner/claim/<이슈번호>/<앵커>-takeover
#
# **형제 이름이어야 한다 — 자식(`<앵커>/takeover`)은 구조적으로 불가능하다.** git ref
# 네임스페이스는 파일시스템처럼 동작해서 `…/base` 가 존재하면 그 하위 `…/base/takeover`
# 는 D/F(디렉토리/파일) 충돌로 거부된다. takeover 시도는 정의상 1차 잠금이 이미 존재할
# 때만 도달하므로 자식 이름이면 **항상** 실패한다(실측 2026-08-12: 자식 생성 → 422
# `Reference update failed`, 형제 생성 → 201). 게다가 그 422 메시지엔 `already exists`
# 가 없어 아래 case 의 일반 분기로 떨어져 인수가 영구 불가가 된다.
#
# 이걸 잡은 하나만 진행하고 나머지는 패배로 접는다. takeover 도 이미 있으면 그 자리에서
# 닫는다(fail-closed) — 인수의 인수를 허용하면 무한 후퇴 끝에 결국 이중 claim 이 된다.
#
# 남는 절충: 인수한 워커까지 **커밋 없이** 죽으면 그 앵커에서는 더 이상 자동 재투입이
# 안 된다(사람이 ref 를 지워야 풀린다). 커밋이 하나라도 생기면 앵커 sha 가 바뀌어 잠금
# 전체가 새로 열리므로, 이 교착은 "두 번 연속 커밋 0 으로 사망" 에만 걸린다 — 이중
# claim(작업 유실)보다 이쪽이 안전하다는 판단(#108).
#
# env: CLAIM_STALE_WAIT  422 후 소유자 확인에 쓸 총 대기창(초, 기본 15). 0 이면 1회만 조회.
#      CLAIM_POLL_STEP   그 대기창 안에서의 재조회 간격(초, 기본 3).
set -euo pipefail
repo="${1:?usage: claim-issue.sh <owner/repo> <num>}"
num="${2:?usage: claim-issue.sh <owner/repo> <num>}"
me=$(gh api user -q .login)
stale_wait=${CLAIM_STALE_WAIT:-15}
poll_step=${CLAIM_POLL_STEP:-3}
[ "$poll_step" -gt 0 ] 2>/dev/null || poll_step=3

# 사전 재확인 — 직접 API (인덱스 지연 없음)
pre=$(gh issue view "$num" --repo "$repo" --json labels,state)
state=$(printf '%s' "$pre" | jq -r '.state')
[ "$state" = "OPEN" ] || { echo "skip: $repo#$num is $state" >&2; exit 1; }
if printf '%s' "$pre" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null; then
  echo "skip: $repo#$num already claimed" >&2; exit 1
fi
# needs-human 재확인 — eligible-issues.sh 이후 사람이 붙였거나 인덱스 지연으로
# 후보에 남아 있어도, 사람이 라벨을 떼기 전에는 claim 금지
if printf '%s' "$pre" | jq -e '.labels | map(.name) | index("needs-human")' >/dev/null; then
  echo "skip: $repo#$num needs-human" >&2; exit 1
fi

# ── 원자적 잠금 (#108) ──
# 앵커 결정: 원격 브랜치가 있으면 그 head sha(재투입), 없으면 기본 브랜치 head 를
# 잠금 ref 의 객체로 쓰고 이름 앵커는 `base`(신규). 이름이 같으면 sha 값이 달라도
# 중재는 성립한다 — 중재는 ref **이름** 으로 이뤄진다.
lock_key=base
lock_sha=$(gh api "repos/$repo/git/ref/heads/agent/issue-$num" -q '.object.sha' 2>/dev/null || true)
if [ -n "$lock_sha" ]; then
  lock_key="$lock_sha"
else
  default=$(gh api "repos/$repo" -q '.default_branch' 2>/dev/null || true)
  [ -n "$default" ] || { echo "claim 중단: $repo 기본 브랜치 조회 실패" >&2; exit 1; }
  lock_sha=$(gh api "repos/$repo/git/ref/heads/$default" -q '.object.sha' 2>/dev/null || true)
fi
# 앵커 sha 를 못 구하면 잠금 없이 claim 하지 않는다(fail-closed — 안 집는 쪽이 안전).
[ -n "$lock_sha" ] || { echo "claim 중단: $repo#$num 잠금 앵커 sha 조회 실패" >&2; exit 1; }

lock_ref="refs/issue-runner/claim/$num/$lock_key"
lock_rc=0
lock_out=$(gh api "repos/$repo/git/refs" -f ref="$lock_ref" -f sha="$lock_sha" 2>&1) || lock_rc=$?
if [ "$lock_rc" != 0 ]; then
  case "$lock_out" in
    *"already exists"*) : ;;      # "Reference already exists" (422) — 정상 중재 결과
    # 422 가 아닌 실패(네트워크·권한)는 중재 결과를 모른다 → fail-closed
    *) echo "claim 중단: $repo#$num 잠금 ref 생성 실패 — $lock_out" >&2; exit 1 ;;
  esac
  # 경합 패배 vs 이전 attempt 의 스테일 잠금 구분 — 살아있는 경쟁자는 잠금을 잡은 직후
  # agent:claimed 를 붙이므로 그 라벨이 소유자 생존의 증거다.
  #
  # 조회를 **한 번**만 하면 "잠금은 잡았는데 라벨 부착이 느려진 살아있는 소유자"를
  # 스테일로 오판해 원자성이 다시 깨진다 → 대기창을 잘게 나눠 반복 확인한다. 라벨이
  # 늦게라도 뜨면 패배로 접는다.
  waited=0
  while :; do
    if ! recheck=$(gh issue view "$num" --repo "$repo" --json labels 2>/dev/null) || [ -z "$recheck" ]; then
      # 소유자를 확인하지 못했다 = 중재 결과를 모른다 → 안 집는다(fail-closed).
      echo "claim 중단: $repo#$num 잠금 후 재조회 실패 — 잠금 소유자 확인 불가" >&2; exit 1
    fi
    if printf '%s' "$recheck" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null; then
      echo "skip: $repo#$num 잠금 경합 패배(다른 세션이 claim)" >&2; exit 1
    fi
    [ "$waited" -lt "$stale_wait" ] || break
    step=$poll_step
    if [ $((waited + step)) -gt "$stale_wait" ]; then step=$((stale_wait - waited)); fi
    [ "$step" -gt 0 ] || break
    sleep "$step"
    waited=$((waited + step))
  done
  # 여기까지 오면 "이전 attempt 의 스테일 잠금" 판정이다. **그대로 진행하면 원자성이
  # 다시 깨진다** — 스테일 잠금에 신규 세션이 둘 동시에 들어오면 둘 다 422 를 받고 둘 다
  # 대기창 내내 라벨 없음을 보므로 둘 다 claim 한다(1차 잠금은 이미 남이 만든 것이라
  # 중재력이 없다). 그래서 스테일 인수 자체를 **또 하나의 create-only ref** 로 중재한다:
  # takeover ref 를 잡은 하나만 진행하고 나머지는 패배로 접는다.
  # 형제 이름(하이픈) — 자식 경로는 D/F 충돌로 항상 실패한다(위 헤더 주석).
  takeover_ref="${lock_ref}-takeover"
  to_rc=0
  to_out=$(gh api "repos/$repo/git/refs" -f ref="$takeover_ref" -f sha="$lock_sha" 2>&1) || to_rc=$?
  if [ "$to_rc" != 0 ]; then
    case "$to_out" in
      *"already exists"*)
        # takeover 도 이미 있다 = 다른 세션이 이 스테일 잠금을 먼저 인수했다. 그 세션이
        # 라벨을 붙였는지와 무관하게 **여기서 닫는다**(fail-closed) — 인수의 인수를
        # 허용하면 무한 후퇴가 되고, 그 끝은 결국 이중 claim 이다.
        echo "skip: $repo#$num 스테일 잠금 인수 경합 패배(다른 세션이 인수)" >&2; exit 1 ;;
      *) echo "claim 중단: $repo#$num takeover ref 생성 실패 — $to_out" >&2; exit 1 ;;
    esac
  fi
  echo "note: $repo#$num 잠금 ref 기존재하나 ${stale_wait}초 동안 claim 라벨 없음 — 스테일 잠금 인수(takeover)로 진행" >&2
fi

gh issue edit "$num" --repo "$repo" --add-label "agent:claimed" --add-assignee "$me" >/dev/null

# 사후 확인
post=$(gh issue view "$num" --repo "$repo" --json labels)
printf '%s' "$post" | jq -e '.labels | map(.name) | index("agent:claimed")' >/dev/null \
  || { echo "claim 실패: 라벨 미부착 $repo#$num" >&2; exit 1; }

# stale blocked-by 라벨 청소(#85 should): 이 이슈가 eligible 게이트를 통과해 claim 됐다는
# 것은 남아 있는 blocked-by:<N> 중 CLOSED 인 블로커의 라벨이 이제 무의미하다는 뜻이다.
# 목록 청소용으로만 제거한다 — 게이트는 N=CLOSED 면 라벨 제거 없이도 이미 통과한다.
# (eligible-issues.sh 는 순수 조회라 부수효과를 claim 시점으로 옮긴 최소 침습 위치.)
printf '%s' "$post" | jq -r '.labels[].name | select(startswith("blocked-by:"))' \
  | while IFS= read -r lbl; do
      bn=${lbl#blocked-by:}
      bstate=$(gh issue view "$bn" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
      if [ "$bstate" = "CLOSED" ]; then
        gh issue edit "$num" --repo "$repo" --remove-label "$lbl" >/dev/null 2>&1 || true
      fi
    done

echo "claimed: $repo#$num"
