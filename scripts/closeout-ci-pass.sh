#!/usr/bin/env bash
# PR 의 CI 통과를 판정 — pass 면 exit 0, 아니면 exit 1. closeout 진입 조건용(무출력 필터).
#  • 로컬 CI 옵트인 레포(실행 가능한 bin/ci 보유): PR head SHA 의 로컬 CI 캐시로 판정.
#  • 그 외 레포: GitHub statusCheckRollup 으로 판정 (ci-gate-before-pr-merge.sh 의
#    그 외 레포 분기와 동일 계약 — 등록 체크 1개 이상 + 전부 SUCCESS 면 0, 아니면 1).
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
  [ -f "$result" ] && [ "$(cat "$result" 2>/dev/null)" = pass ]
else
  # ── 그 외 레포 — GitHub statusCheckRollup 폴백 (ci-gate SSOT 와 동일 판정) ──
  rollup=$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup 2>/dev/null)
  [ -n "$rollup" ] || exit 1   # 조회 불가 → fail-closed

  checks=$(printf '%s' "$rollup" | jq -c '.statusCheckRollup // []')
  count=$(printf '%s' "$checks" | jq 'length')
  [ "$count" -gt 0 ] || exit 1   # 등록된 체크 0개 → fail-closed

  # 미완료 (check-run status != COMPLETED 이고 commit-status state 도 종료상태 아님).
  pending=$(printf '%s' "$checks" | jq -r '
    .[]
    | select(
        ((.status // "") != "COMPLETED")
        and ((.state // "") != "SUCCESS")
        and ((.state // "") != "FAILURE")
        and ((.state // "") != "ERROR")
      )' | head -1)
  [ -z "$pending" ] || exit 1   # 진행 중 → fail-closed

  # 실패 항목 (check-run conclusion 또는 commit-status state).
  failed=$(printf '%s' "$checks" | jq -r '
    .[]
    | select(
        ((.conclusion // "") == "FAILURE")
        or ((.conclusion // "") == "CANCELLED")
        or ((.conclusion // "") == "TIMED_OUT")
        or ((.conclusion // "") == "ACTION_REQUIRED")
        or ((.state // "") == "FAILURE")
        or ((.state // "") == "ERROR")
      )' | head -1)
  [ -z "$failed" ]   # 실패 있으면 비0 → exit 1, 없으면(전부 SUCCESS) exit 0
fi
