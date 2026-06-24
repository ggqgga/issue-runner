#!/usr/bin/env bash
# claim 된 이슈 전수 점검. 이벤트를 JSON lines 로 출력하고 안전 정리를 수행.
# 이벤트:
#   merged   — PR 머지됨 → worktree 제거 + claim 해제 (이슈는 Closes 로 자동 닫힘)
#   rejected — PR 이 머지 없이 닫힘 → 정리 + agent-ready 도 제거 (자동 재시도 금지)
#   pr_open  — PR 열려 있음 (failing 카운트 포함 → Maintain 단계 입력)
#   harvesting — closeout 가 점유한 OPEN PR (harvesting 라벨) → Maintain 제외, 건드리지 않음
#   working  — PR 없고 worktree 있음 → 워커 진행 중으로 간주
#   stale    — PR 없고 worktree 도 없음 → 죽은 claim 해제
#   warn     — dirty/unpushed worktree → 제거 보류, 사람 확인 필요
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
me=$(gh api user -q .login)

# 세션 레포 스코프 (#40): 실행 cwd 의 .loop/repos 가 있으면 그 목록(owner/repo,
# 줄당 하나, # 주석·빈 줄 허용)의 레포만 점검한다. 없으면 계정 전체(기존 동작).
# eligible-issues.sh 와 일관 적용 — 다른 세션 워커의 claim 에 불간섭.
scope_file="$PWD/.loop/repos"
in_scope() {
  [ -f "$scope_file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$scope_file" | tr -d ' \t' | grep -qxF "$1"
}

# 주의: --state 미지정 = open+closed 모두 (merged PR 이 이슈를 자동으로 닫으므로 필수)
claimed=$(gh search issues "label:agent:claimed" --owner "$me" \
  --json repository,number --limit 100)

printf '%s' "$claimed" | jq -c '.[]' | while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner')
  num=$(printf '%s' "$row" | jq -r '.number')

  # 세션 레포 스코프 밖이면 불간섭 (#40)
  in_scope "$repo" || continue
  dir=$("$SCRIPT_DIR/repo-dir.sh" "$repo")
  branch="agent/issue-$num"
  wt="$dir/.claude/worktrees/issue-$num"

  # 안전 제거는 공유 헬퍼(cleanup-worktree.sh)로 일원화 (#62). 동작 불변:
  # --merged 안 넘기므로 기존 더티/미push 가드·warn JSON·반환코드가 그대로다.
  safe_remove_worktree() {
    "$SCRIPT_DIR/cleanup-worktree.sh" "$repo" "$num"
  }

  pr=$(gh pr list --repo "$repo" --head "$branch" --state all \
    --json number,state,statusCheckRollup,labels --limit 1 2>/dev/null | jq -c '.[0] // empty')

  if [ -z "$pr" ]; then
    if [ -d "$wt" ]; then
      printf '{"event":"working","repo":"%s","number":%s}\n' "$repo" "$num"
    else
      gh issue edit "$num" --repo "$repo" --remove-label "agent:claimed" >/dev/null 2>&1 || true
      printf '{"event":"stale","repo":"%s","number":%s}\n' "$repo" "$num"
    fi
    continue
  fi

  prnum=$(printf '%s' "$pr" | jq -r '.number')
  prstate=$(printf '%s' "$pr" | jq -r '.state')

  case "$prstate" in
    MERGED)
      if safe_remove_worktree; then
        gh issue edit "$num" --repo "$repo" --remove-label "agent:claimed" >/dev/null 2>&1 || true
        printf '{"event":"merged","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
      fi ;;
    CLOSED)
      if safe_remove_worktree; then
        gh issue edit "$num" --repo "$repo" \
          --remove-label "agent:claimed" --remove-label "agent-ready" >/dev/null 2>&1 || true
        printf '{"event":"rejected","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
      fi ;;
    OPEN)
      # closeout 가 점유한 PR(harvesting 라벨)은 ② Maintain 입력에서 제외 (#44).
      # 머지/닫힘 PR 은 위 MERGED/CLOSED 분기에서 정상 정리되므로 OPEN 만 가른다.
      if printf '%s' "$pr" | jq -e '[.labels[].name]|index("harvesting")' >/dev/null; then
        printf '{"event":"harvesting","repo":"%s","number":%s,"pr":%s}\n' "$repo" "$num" "$prnum"
        continue
      fi
      failing=$(printf '%s' "$pr" | jq '[.statusCheckRollup[]?
        | select((.conclusion // .state // "")
          | test("FAILURE|ERROR|CANCELLED|TIMED_OUT"))] | length')
      printf '{"event":"pr_open","repo":"%s","number":%s,"pr":%s,"failing":%s}\n' \
        "$repo" "$num" "$prnum" "$failing" ;;
  esac
done
