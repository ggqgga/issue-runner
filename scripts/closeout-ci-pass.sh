#!/usr/bin/env bash
# PR 의 CI 통과를 판정 — pass 면 exit 0, 아니면 exit 1. closeout 진입 조건용(무출력 필터).
#  • exit 2 = 로컬 CI HEAD 미실행(결과파일 부재 → 재검증 필요, #70). 로컬 CI 분기
#    한정 — rebase 로 HEAD SHA 가 바뀌어 새 SHA 캐시가 비었을 때를 fail(1)과 구분한다
#    (closeout 머지 도크가 떠안아 재검증). GitHub rollup 폴백 분기는 0/1 그대로.
#  • 로컬 CI 옵트인 레포(실행 가능한 bin/ci 보유): PR head SHA 의 로컬 CI 캐시로 판정.
#  • 그 외 레포: GitHub statusCheckRollup 으로 판정 (ci-gate-before-pr-merge.sh 의
#    그 외 레포 분기와 같은 취지 — 등록 체크 1개 이상 + 전부 SUCCESS 면 0, 아니면 1).
#    판정은 SUCCESS-only allowlist (#51 수용기준: "전부 SUCCESS 면 exit 0").
#    SUCCESS 가 아닌 종결 상태(CANCELLED·TIMED_OUT·STARTUP_FAILURE·미래/미열거 값
#    포함)는 전부 fail — denylist 면 미열거 종결값이 새어 CI 미통과를 pass 로
#    오인한다. (ci-gate 쪽은 아직 denylist 라 같은 갭 잔존 — 별건 후속.)
set -uo pipefail
repo=${1:?repo}; pr=${2:?pr_num}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

root=$("$SCRIPT_DIR/repo-dir.sh" "$repo" 2>/dev/null)

if [ -n "$root" ] && [ -x "$root/bin/ci" ]; then
  # ── 로컬 CI 옵트인 레포 — head SHA 캐시 판정 (기존 동작 100% 보존) ──
  sha=$(gh pr view "$pr" --repo "$repo" --json headRefOid 2>/dev/null \
    | jq -r '.headRefOid // empty')
  [ -n "$sha" ] || exit 1

  slug=$(printf '%s' "$root" | sed 's#[/ ]#_#g; s#^_##')
  result="$HOME/.claude/.local-ci/$slug/$sha.result"
  # 세 결과 구분 (#70): 결과파일 부재=exit 2(미실행, 재검증 필요)·내용 pass=exit 0·
  # 그 외(fail/빈값)=exit 1. exit 2 도 비0이라 `if ci-pass; then` 호출부엔 무손상.
  if [ ! -f "$result" ]; then
    exit 2
  elif [ "$(cat "$result" 2>/dev/null)" = pass ]; then
    exit 0
  else
    exit 1
  fi
else
  # ── 그 외 레포 — GitHub statusCheckRollup 폴백 (SUCCESS-only allowlist) ──
  rollup=$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup 2>/dev/null)
  [ -n "$rollup" ] || exit 1   # 조회 불가 → fail-closed

  checks=$(printf '%s' "$rollup" | jq -c '.statusCheckRollup // []')
  count=$(printf '%s' "$checks" | jq 'length')
  [ "$count" -gt 0 ] || exit 1   # 등록된 체크 0개 → fail-closed

  # 미완료 (check-run status != COMPLETED 이고 commit-status state 도 종료상태 아님).
  # closeout 진입 필터라 진행 중 PR 은 아직 거두지 않는다 → fail-closed.
  pending=$(printf '%s' "$checks" | jq -r '
    .[]
    | select(
        ((.status // "") != "COMPLETED")
        and ((.state // "") != "SUCCESS")
        and ((.state // "") != "FAILURE")
        and ((.state // "") != "ERROR")
      )' | head -1)
  [ -z "$pending" ] || exit 1   # 진행 중 → fail-closed

  # 통과 항목 = SUCCESS 로 종결된 것만 (allowlist):
  #   • check-run: status==COMPLETED 이고 conclusion==SUCCESS
  #   • 레거시 commit-status: status 없이 state==SUCCESS
  # 그 외(CANCELLED·TIMED_OUT·STARTUP_FAILURE·NEUTRAL·미열거 conclusion 등)는
  # 전부 비통과로 본다. denylist 가 아니라 good-then-negate 라 미래/오타 종결값도
  # 자동으로 fail 로 잡힌다.
  bad=$(printf '%s' "$checks" | jq -r '
    .[]
    | select(
        (
          ((.status // "") == "COMPLETED") and ((.conclusion // "") == "SUCCESS")
        ) or (
          ((.status // "") == "") and ((.state // "") == "SUCCESS")
        )
        | not
      )' | head -1)
  [ -z "$bad" ]   # 비통과 있으면 비0 → exit 1, 없으면(전부 SUCCESS) exit 0
fi
