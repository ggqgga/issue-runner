#!/usr/bin/env bash
# bounce-comment.sh <채널> <repo> <pr> <issue> [<attempt> <사유>]
#
# 반송(bounce) 코멘트 **문구를 만드는 한 자리**(#212). 마커 어휘 자체의 SSOT 는
# `bounce-state.sh` 상단의 반송 마커 배열(그 파일 밖에 정의를 두지 않는다 —
# bin/ci 가 검사) — 이 스크립트는 그 마커로 시작하는 실제 코멘트
# 본문을 만들어 `gh pr comment` 로 게시한다. 지금까지는 SKILL.md 본문에 박힌 예시
# 문자열을 사람·워커가 매번 손으로 옮겨 적었는데, 그러다 콜론이 빠지거나 어순이
# 바뀌는 변형이 생겼다(#212 사고 원인 그 자체 — PR #202 의 `재디스패치 attempt 3`).
# `transition.sh` 가 라벨 이동을 한 자리로 모은 것과 같은 이유로 문구도 한 자리로
# 모은다.
#
# 채널은 셋이고 각자 다른 인자를 받는다(형식이 달라 하나로 합치지 않는다 — closeout
# ①-b 는 사유가 고정, 나머지 둘은 사유·attempt 번호가 매 호출 가변):
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
#   bounce-comment.sh human-review <repo> <pr> <issue> "<결정문 인용 한 줄>"
#     → closeout ①-c 3) 시정 전용(skills/closeout/SKILL.md). 사람이 보류를 **시정 방향**
#       으로 풀었을 때의 반송이다. 사유 문구는 고정("사람 재심이 시정 방향")이고 가변인
#       것은 결정문 인용 한 줄뿐이라, `redispatch` 채널처럼 사유를 인자로 받지 않는다.
#       이 채널이 없던 동안 SKILL 본문이 `gh pr comment --body "재디스패치: #<이슈> — …"`
#       를 **손으로 옮겨 적으라**고 지시했는데, 그게 #212 사고 원인 그 자체다.
#       인용 안의 개행은 한 줄로 접는다 — 반송 마커는 **첫 줄 접두**로 판정되므로
#       (`bounce-state.sh`) 인용이 줄을 넘기면 뒤따르는 줄이 마커 밖으로 새어 나간다.
#
#   bounce-comment.sh closeout-blocker <repo> <pr> <issue> "<사유>"
#     → closeout ③-1 마감 검증 BLOCKER 중 **구현으로 닫히는 결함**을 워커 레인으로
#       반송하는 자리 전용(skills/closeout/SKILL.md ③ 1단계). 사유는 호출자가 넘긴다
#       — 매 호출 다르다(reverify-fail 과 같은 이유). `redispatch` 를 재사용하지
#       않는 이유: 그 채널의 고정 문구("완결 유실(검증 전 사망)")는 이 갈래에서
#       **거짓**이고(PR 은 죽지 않았고 검증도 끝났다), 그 거짓 사유는 다음 틱의 판정
#       입력이다(finish-classify 와 사람이 같은 코멘트를 읽는다, #271).
#
# 넷 다 문구 생성과 게시(`gh pr comment`)를 한 호출로 묶는다 — 문구만 stdout 으로
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
  bounce-comment.sh human-review <repo> <pr> <issue> "<결정문 인용 한 줄>"
  bounce-comment.sh closeout-blocker <repo> <pr> <issue> "<사유>"
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
  human-review)
    quote=${5:-}
    if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$issue" ] || [ -z "$quote" ]; then
      usage; exit 2
    fi
    # 개행·탭을 공백 하나로 접는다 — 첫 줄 접두 판정을 인용이 깨뜨리지 않게.
    quote=$(printf '%s' "$quote" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
    body="재디스패치: #${issue} — 사람 재심이 시정 방향(${quote}) <!-- bodat:worker -->"
    ;;
  closeout-blocker)
    reason=${5:-}
    if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$issue" ] || [ -z "$reason" ]; then
      usage; exit 2
    fi
    # 첫 줄 앵커는 `redispatch` 와 같은 마커로 시작한다 — 마커 어휘의 SSOT 는
    # bounce-state.sh 의 반송 마커 배열이고, 이 채널은 그 어휘를 **쓰는** 쪽이다
    # (새 어휘를 만들면 판정기 밖에 정의가 하나 더 생긴다. 그 배열 주석도 이 마커를
    # "마감 검증 BLOCKER·완결 유실 반송" 두 쓰임으로 이미 규정한다).
    # 마커를 `redispatch` 와 공유해도 회차 계수를 부풀리지 않는다 — `재디스패치` 를
    # 세는 소비자는 없다(bounce-state.sh 는 **마지막 인덱스**로 선후만 가린다).
    # 세는 쪽은 verify-runner 의 `재검증 실패:` 코멘트 수이고 그건 다른 마커다.
    body="재디스패치: #${issue} — ${reason}
<!-- bodat:worker -->"
    ;;
  *)
    usage; exit 2
    ;;
esac

exec gh pr comment "$pr" --repo "$repo" --body "$body"
