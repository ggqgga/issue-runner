#!/usr/bin/env bash
# PreToolUse on Bash (if: "Bash(gh pr create*)") — block PR creation when the
# command lacks a *dedicated-line* issue reference: an auto-close keyword
# (Closes/Fixes/Resolves #N) OR a non-closing Refs #N for epic part-progress
# PRs. Escape hatch: include "(no-issue)" anywhere in the command (usually the
# PR body) to bypass. Keeps every PR traceable to the issue it came from.
#
# The script self-filters on the command too — settings.json's
# `if: Bash(gh pr create*)` does not match every call path (compound commands,
# shell substitution), so the guard re-checks. Same self-filter pattern the
# other PR-create hooks use.
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Pass through anything that is not `gh pr create`.
printf '%s' "$cmd" \
  | grep -qE '(^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
  || exit 0

# Accept a *dedicated-line* issue reference — the keyword must start the line
# (optional leading whitespace) so a prose mention (e.g. "a follow-up PR will
# `close #N`") does not pass by accident. Supports every GitHub auto-close
# keyword (close/closes/closed · fix/fixes/fixed · resolve/resolves/resolved)
# plus the non-closing refs?(ref/refs), case-insensitive. `refs` references
# without closing — used when one PR only part-completes an epic (same regex as
# the checkbox-reconcile hook, so both recognize the same line). grep is
# line-oriented, so `^` matches each line of a multi-line heredoc body.
if printf '%s' "$cmd" | grep -qiE '^[[:space:]]*(close[sd]?|fix(e[sd])?|resolve[sd]?|refs?)[[:space:]]+#[0-9]+'; then
  exit 0
fi

# Escape hatch: bypass with "(no-issue)" anywhere in the command when there
# genuinely is no related issue.
if printf '%s' "$cmd" | grep -qF '(no-issue)'; then
  exit 0
fi

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "The PR body has no *dedicated-line* issue reference. To close an issue put `Closes #N` (or fixes/resolves); to reference without closing (e.g. partial epic progress) put `Refs #N` on its own body line — inline/prose mentions are ignored. If there genuinely is no related issue, add `(no-issue)` to the body and retry."
  }
}'
