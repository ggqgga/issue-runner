#!/usr/bin/env bash
# ci-gate-before-pr-merge.sh — `gh pr merge` 직전 게이트.
#
#  • 로컬 CI 세팅된 레포(실행 가능한 bin/ci 보유 — 언어 무관.
#    예: BoDAT=Rails 8 네이티브, Temphra=폴리글롯 스크립트):
#      local-ci.sh 가 push 때 캐시한 PR head SHA 의 결과로 판정.
#      pass=통과 / fail=차단(실패 스텝) / 진행중=차단 / 없음=차단. GitHub Actions 미사용.
#  • 그 외 레포:
#      기존 동작 — GitHub statusCheckRollup(Actions/commit status)으로 판정.
#
# 차단은 exit 2 + stderr(다음 턴에 Claude/사용자가 즉시 인지). PreToolUse(Bash, if: gh pr merge*).
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && cmd=$(printf '%s' "$input" \
  | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)

# self-filter — settings 의 if 매칭이 빠진 경로에서도 안전하게 패스스루.
printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' \
  || exit 0

# PR 번호 추출 — `gh pr merge <N>` 패턴.
pr_num=$(printf '%s' "$cmd" | sed -n 's/.*gh[[:space:]]\+pr[[:space:]]\+merge[[:space:]]\+\([0-9]\+\).*/\1/p')
# 번호 인자 없이 호출한 경우 — 현재 브랜치의 PR.
if [ -z "$pr_num" ]; then
  pr_num=$(gh pr view --json number 2>/dev/null | jq -r '.number // empty')
fi
[ -z "$pr_num" ] && exit 0  # PR 식별 불가 — 게이트 적용 안 함.

ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

# ── 로컬 CI 레포 분기 ────────────────────────────────────────────────
if [ -n "$ROOT" ] && [ -x "$ROOT/bin/ci" ]; then
  slug=$(printf '%s' "$ROOT" | sed 's#[/ ]#_#g; s#^_##')
  dir="$HOME/.claude/.local-ci/$slug"

  # PR head SHA(무료 API — Actions 아님).
  sha=$(gh pr view "$pr_num" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty')
  if [ -z "$sha" ]; then
    printf 'PR #%s 의 head SHA 를 조회할 수 없습니다(gh pr view 실패). 네트워크/인증을 확인하세요.\n' "$pr_num" >&2
    exit 2
  fi
  short=$(printf '%s' "$sha" | cut -c1-8)
  result="$dir/$sha.result"
  log="$dir/$sha.log"

  if [ -f "$result" ]; then
    verdict=$(cat "$result" 2>/dev/null)
    [ "$verdict" = pass ] && exit 0
    printf 'PR #%s 로컬 CI 실패(%s).\n--- bin/ci 마지막 출력 ---\n%s\n----------------------------\n실패를 고치고 다시 push 하세요.\n' \
      "$pr_num" "$short" "$(tail -25 "$log" 2>/dev/null)" >&2
    exit 2
  fi

  # 결과 없음 — 진행 중인지 미실행인지 구분. local-ci.sh 와 동일하게 소유 PID 생존으로
  # 판단(pid 미기록이면 30분 backstop). 죽은 락은 '미실행'으로 떨어뜨려 재push 를 유도.
  lock_active=0
  if [ -d "$dir/.lock" ]; then
    if [ -f "$dir/.lock/pid" ]; then
      lp=$(cat "$dir/.lock/pid" 2>/dev/null)
      { [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; } && lock_active=1
    elif [ -z "$(find "$dir/.lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
      lock_active=1
    fi
  fi
  if [ "$lock_active" = 1 ]; then
    printf 'PR #%s 로컬 CI 진행 중(%s) — 완료 알림 후 다시 머지하세요.\n' "$pr_num" "$short" >&2
    exit 2
  fi
  printf 'PR #%s 로컬 CI 결과 없음(%s).\n해당 커밋을 push 하면 자동 실행되거나, 레포에서 `bin/ci` 를 돌린 뒤 머지하세요.\n' \
    "$pr_num" "$short" >&2
  exit 2
fi

# ── 그 외 레포 — 기존 GitHub statusCheckRollup 동작 ───────────────────
rollup=$(gh pr view "$pr_num" --json statusCheckRollup 2>/dev/null)
if [ -z "$rollup" ]; then
  printf 'CI 상태를 조회할 수 없습니다 (gh pr view 실패). 네트워크 또는 인증 상태를 확인하세요.\n' >&2
  exit 2
fi

checks=$(printf '%s' "$rollup" | jq -c '.statusCheckRollup // []')
count=$(printf '%s' "$checks" | jq 'length')

if [ "$count" = "0" ]; then
  printf 'PR #%s 에 등록된 CI 체크가 없습니다.\nCI 워크플로우가 트리거됐는지 확인한 뒤 다시 머지를 시도하세요.\n' "$pr_num" >&2
  exit 2
fi

# 미완료 (status != COMPLETED 이고 commit-status state 도 SUCCESS/FAILURE 가 아닌 것).
pending=$(printf '%s' "$checks" | jq -r '
  .[]
  | select(
      ((.status // "") != "COMPLETED")
      and ((.state // "") != "SUCCESS")
      and ((.state // "") != "FAILURE")
      and ((.state // "") != "ERROR")
    )
  | "  - \(.name // .context // .workflowName // "?") = \(.status // .state // "PENDING")"
' | head -20)

if [ -n "$pending" ]; then
  printf 'PR #%s 의 CI 가 아직 끝나지 않았습니다:\n%s\n완료 후 다시 머지를 시도하세요.\n' "$pr_num" "$pending" >&2
  exit 2
fi

# 실패 항목.
failed=$(printf '%s' "$checks" | jq -r '
  .[]
  | select(
      ((.conclusion // "") == "FAILURE")
      or ((.conclusion // "") == "CANCELLED")
      or ((.conclusion // "") == "TIMED_OUT")
      or ((.conclusion // "") == "ACTION_REQUIRED")
      or ((.state // "") == "FAILURE")
      or ((.state // "") == "ERROR")
    )
  | "  - \(.name // .context // .workflowName // "?") = \(.conclusion // .state // "?")"
' | head -20)

if [ -n "$failed" ]; then
  printf 'PR #%s 의 CI 가 실패한 체크를 포함합니다:\n%s\n실패 원인을 해결한 뒤 머지하세요.\n' "$pr_num" "$failed" >&2
  exit 2
fi

# 여기까지 왔으면 모두 SUCCESS — 통과.
exit 0
