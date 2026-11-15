#!/usr/bin/env bash
# deploy-wait-after-merge.sh — `gh pr merge` 직후(PostToolUse) 배포 대기 이슈 발행 요구 (#637).
#
# ci-gate-before-pr-merge.sh 는 코드 변경 + `(no-issue)` PR 의 머지를 거부하지만, 본문에 전용 줄
# `배포 대기: 머지 뒤 발행` 이 있으면 통과시킨다. 그 약속이 지켜지게 하는 쪽이 이 훅이다:
# 머지된(state MERGED) PR 본문에 그 줄이 있고 PR 에 `배포 대기: #<번호>` 마커 코멘트
# (deploy-wait-issue.sh ⑸ 가 남긴다)가 아직 없으면, additionalContext 로 발행 명령을 요구한다.
# 배포 대기 이슈가 없으면 deploy-cycle 승격이 그 커밋에서 멈춘다(BoDAT #7662).
#
# PostToolUse 는 막지 못한다 — 출력은 세션에 덧붙이는 안내뿐이다. 아직 OPEN 이면(merge queue 가
# `--auto` 없이도 PR 을 줄 세운다) 나중에 머지를 볼 PostToolUse 가 없으므로, 지금 "머지가 끝나면
# 발행하라" 고 같은 명령을 남긴다(리마인더 소실 방지). CLOSED(미머지 종료)는 조용히 끝낸다.
# PostToolUse(Bash, if: gh pr merge*). macOS bash 3.2 대상.
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' \
  || exit 0

ctx() { printf '%s' "$1" | jq -Rs '{ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: . } }'; }

# 대상·--repo 읽기는 ci-gate-before-pr-merge.sh 와 같다. gh pr view 는 번호·URL·브랜치를 다 받는다.
flag_repo=$(printf '%s' "$cmd" | sed -n -E 's/.*--repo[ =]+([^ ]+).*/\1/p' | head -1)
target=$(printf '%s' "$cmd" | awk '{
  for (i = 1; i <= NF - 2; i++)
    if ($i ~ /(^|[;|&])gh$/ && $(i+1) == "pr" && $(i+2) == "merge") {
      for (j = i + 3; j <= NF; j++)
        if ($(j) !~ /^-/) { print $(j); exit }
      exit
    }
}')
set -- pr view
[ -n "$target" ] && set -- "$@" "$target"
[ -n "$flag_repo" ] && set -- "$@" --repo "$flag_repo"
if ! pr=$(gh "$@" --json number,state,url,mergeCommit,body,comments 2>/dev/null) || [ -z "$pr" ]; then
  ctx "머지한 PR(${target:-현재 브랜치})을 다시 읽지 못했다(gh pr view 실패). 본문에 \`배포 대기: 머지 뒤 발행\` 줄이 있었다면 deploy-wait-issue.sh 로 배포 대기 이슈를 지금 발행하라 — 없으면 deploy-cycle 승격이 그 커밋에서 멈춘다."
  exit 0
fi

state=$(printf '%s' "$pr" | jq -r '.state // empty')
case "$state" in MERGED|OPEN) ;; *) exit 0 ;; esac
printf '%s' "$pr" | jq -r '.body // empty' | tr -d '\r' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF '배포 대기: 머지 뒤 발행' || exit 0
# 이미 발행됐으면(마커 코멘트 실재) 조용히 끝낸다. 번호까지 요구해 인용된 문구와 가른다.
printf '%s' "$pr" | jq -r '.comments[].body // empty' | tr -d '\r' \
  | grep -qE '^배포 대기: #[0-9]+' && exit 0

num=$(printf '%s' "$pr" | jq -r '.number // empty')
sha=$(printf '%s' "$pr" | jq -r '.mergeCommit.oid // empty')
repo=${flag_repo:-$(printf '%s' "$pr" | jq -r '.url // empty' \
  | sed -n -E 's#^https://[^/]+/([^/]+/[^/]+)/pull/[0-9]+.*#\1#p')}

issue_cmd="~/.claude/skills/issue-runner/scripts/deploy-wait-issue.sh ${repo:-<owner/repo>} $num --sha ${sha:-<머지 SHA>} --title <한 줄 요약> --summary-file <변경요약 파일> --items-file <항목 파일|없음>"
if [ "$state" = OPEN ]; then
  ctx "PR #$num 은 \`배포 대기: 머지 뒤 발행\` 통로인데 아직 MERGED 가 아니다(merge queue 대기 또는 머지 실패). 이 훅은 나중의 머지를 보지 못한다 — 머지가 끝나는 것을 확인(\`gh pr view $num${repo:+ --repo $repo} --json state,mergeCommit\`)한 뒤 바로 발행하라. 없으면 deploy-cycle 승격이 그 커밋에서 멈춘다:
  $issue_cmd
(\`<머지 SHA>\` 는 머지 뒤 mergeCommit.oid. 항목 형태·표식 규칙은 deploy-wait-issue.sh 머리 주석.)"
  exit 0
fi
ctx "PR #$num 은 \`배포 대기: 머지 뒤 발행\` 으로 머지됐는데 배포 대기 이슈 마커(\`배포 대기: #N\`)가 아직 없다. 지금 발행하라 — 없으면 deploy-cycle 승격이 이 커밋에서 멈추고 뒤 커밋까지 묶인다:
  $issue_cmd
(항목 형태·표식 규칙은 deploy-wait-issue.sh 머리 주석. 발행이 PR 에 마커를 남긴다.)"
exit 0
