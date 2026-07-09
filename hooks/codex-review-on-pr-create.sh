#!/usr/bin/env bash
# PostToolUse on Bash (if: "Bash(gh pr create*)") — after a PR is created,
# inject an instruction telling Claude to spawn an independent codex:codex-rescue
# diff review in the background. Every PR gets a second, adversarial pair of eyes
# on its diff; the review runs in parallel and its result is injected on Claude's
# next turn. No-op if the codex plugin is absent (Claude simply can't spawn it).
#
# This ships the codex half of the PR-create flow on its own — pair it with your
# own test-plan / checkbox-reconcile hooks if you run those too.
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
stdout=$(printf '%s' "$input" | jq -r '.tool_response.stdout // ""')

# Self-filter — pass through anything that is not `gh pr create`.
printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
  || exit 0

# Extract the PR number — `gh pr create` prints the new PR URL last.
pr_url=$(printf '%s' "$stdout" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -1)
pr_num=$(printf '%s' "$pr_url" | grep -oE '[0-9]+$')
[ -z "$pr_num" ] && exit 0

# Fetch title + branch refs for the review prompt.
meta=$(gh pr view "$pr_num" --json headRefName,baseRefName,title 2>/dev/null) || exit 0
[ -z "$meta" ] && exit 0
pr_title=$(printf '%s' "$meta" | jq -r '.title // ""')
head_ref=$(printf '%s' "$meta" | jq -r '.headRefName // ""')
base_ref=$(printf '%s' "$meta" | jq -r '.baseRefName // "main"')

# Feed the heredoc directly into jq (avoid a heredoc inside $(...), which
# macOS bash 3.2 mis-parses). jq -Rs slurps stdin as one raw string.
cat <<EOF | jq -Rs '{ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: . } }'
**Spawn a codex:codex-rescue background review now.** Call the Agent tool to get an independent code review of this PR's diff:

\`\`\`
Agent(
  description: "Codex diff review PR #${pr_num}",
  subagent_type: "codex:codex-rescue",
  run_in_background: true,
  prompt: """Review PR #${pr_num} (--fresh).

Branch: ${head_ref} -> ${base_ref}
Title: ${pr_title}

Task: read the changes in \`git diff ${base_ref}...HEAD\` and check for:
1. correctness bugs — race conditions, off-by-one, missing nil/empty handling
2. module-boundary violations — one module reaching into another's internals
3. missing edge cases — skipped validation, permission bypass, trusting bad input
4. test adequacy — do assertions verify real behavior, no mock bypasses
5. clear over-engineering or backwards-compat cruft

Report high-priority findings only (drop low-confidence speculation). Read-only — do not change code. End with a 'BLOCKER / WARN / NIT' classification."""
)
\`\`\`

Keep working after you spawn it. When codex finishes you get a notification — then read the result and: (a) commit a fix for any BLOCKER, (b) summarize WARN/NIT into a "## Codex review" section on the PR body, (c) mark items you can dismiss.
EOF
