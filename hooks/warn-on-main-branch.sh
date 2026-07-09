#!/usr/bin/env bash
# PreToolUse on Write|Edit — warn when editing on main/master.
# Non-blocking: injects additionalContext so Claude knows to branch first.
# No-op for non-git directories. Keeps loop work off the default branch —
# every task should land on a topic branch that becomes a PR.
set -u
cat >/dev/null  # consume stdin

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
case "$branch" in
  main|master)
    jq -n --arg b "$branch" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: ("⚠️ You are about to edit a file on the \($b) branch. If this is new work, create a topic branch first (feat/..., fix/..., chore/...). A trivial README/typo fix is fine to do in place.")
      }
    }'
    ;;
esac
exit 0
