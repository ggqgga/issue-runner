#!/usr/bin/env bash
# bounce-comment.sh <채널> <repo> <pr> <issue> [<attempt> <사유>]
#
# 반송(bounce) 코멘트 **문구를 만드는 한 자리**(#212). 마커 어휘 자체의 SSOT 는
# `bounce-state.sh` 의 BOUNCE_MARKERS — 이 스크립트는 그 마커로 시작하는 실제 코멘트
# 본문을 만들어 `gh pr comment` 로 게시한다. 지금까지는 SKILL.md 본문에 박힌 예시
# 문자열을 사람·워커가 매번 손으로 옮겨 적었는데, 그러다 콜론이 빠지거나 어순이
# 바뀌는 변형이 생겼다(#212 사고 원인 그 자체 — PR #202 의 `재디스패치 attempt 3`).
# `transition.sh` 가 라벨 이동을 한 자리로 모은 것과 같은 이유로 문구도 한 자리로
# 모은다.
#
# 채널은 둘이고 각자 다른 인자를 받는다(형식이 달라 하나로 합치지 않는다 — closeout
# 은 사유가 고정, verify-runner 는 사유·attempt 번호가 매 호출 가변):
#
#   bounce-comment.sh redispatch <repo> <pr> <issue>
#     → closeout ①-b stale_reverify 재디스패치 전용(skills/closeout/SKILL.md).
#       사유 문구는 고정("완결 유실(검증 전 사망)") — 이 채널은 사유가 항상 같다.
#
#   bounce-comment.sh reverify-fail <repo> <pr> <issue> <attempt> "<사유>"
#     → verify-runner ④ redispatched 전용(skills/verify-runner/SKILL.md).
#       <attempt> 는 PR 본문 `<!-- verify-attempt: N -->` 의 N+1(호출자가 계산해 넘긴다
#       — 이 스크립트는 본문을 읽지 않는다).
#
# 둘 다 문구 생성과 게시(`gh pr comment`)를 한 호출로 묶는다 — 문구만 stdout 으로
# 돌려주고 게시는 호출자가 따로 하게 하면, 그 게시 지점이 다시 손으로 옮겨 적는
# 자리가 된다.
set -euo pipefail

channel=${1:-}
repo=${2:-}
pr=${3:-}
issue=${4:-}

usage() {
  cat >&2 <<'USAGE'
usage:
  bounce-comment.sh redispatch <repo> <pr> <issue>
  bounce-comment.sh reverify-fail <repo> <pr> <issue> <attempt> "<사유>"
USAGE
}

case "$channel" in
  redispatch)
    if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$issue" ]; then
      usage; exit 2
    fi
    body="재디스패치: #${issue} — 완결 유실(검증 전 사망) <!-- bodat:worker -->"
    ;;
  reverify-fail)
    attempt=${5:-}
    reason=${6:-}
    if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$issue" ] || [ -z "$attempt" ] || [ -z "$reason" ]; then
      usage; exit 2
    fi
    body="재검증 실패: #${issue} — ${reason} (attempt ${attempt})
<!-- bodat:worker -->"
    ;;
  *)
    usage; exit 2
    ;;
esac

exec gh pr comment "$pr" --repo "$repo" --body "$body"
