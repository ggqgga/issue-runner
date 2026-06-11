---
name: issue-prep
description: Closing checklist before handing an issue to the issue-runner loop. Use when finishing issue writing in a planning session, or on requests like "finalize this issue" or "attach agent-ready". Attach the agent-ready label only after the checklist passes.
---

> English translation of [SKILL.md](SKILL.md). The Korean original is the source of
> truth — when the two diverge, follow SKILL.md and update this file to match.
> To run this skill in English, replace SKILL.md with this file's contents.

# issue-prep — issue closing checklist

Before handing an issue to the loop, confirm **all** of the items below, and attach
`agent-ready` only to issues that pass. The worker shares none of this session's
context — the issue body is the only spec.

## Checklist

1. **Self-contained spec**: can it be implemented by reading the issue body alone,
   without the context of this conversation? Are the background, motivation, and
   constraints all written in the body?
2. **Acceptance criteria**: concrete and verifiable `- [ ]` checkboxes. No vague
   wording like "works well".
3. **Test plan**: a `## Test plan` section with the verification commands/scenarios
   to run.
4. **Dependencies**: if there are prerequisite issues, put a **dedicated line**
   `Blocked by #N` in the body (one per line, at the start of the line). Mentions
   buried in prose are invisible to the dispatcher.
5. **Hierarchy**: if it is an epic (parent), split it into sub-issues and attach
   agent-ready **only to leaves**. Never attach it to the epic itself.
6. **Priority**: attach exactly one P0/P1/P2 label (without one it is treated as
   lowest priority).
7. **Repo readiness**: does the repo have (a) the label set —
   if not, run `~/.claude/skills/issue-runner/scripts/setup-labels.sh <owner/repo>`;
   (b) build/test commands in CLAUDE.md — without them the worker cannot verify
   its work. Fix these first.
8. **Conflict forecast**: does it touch the same module as another issue that is
   already agent-ready/claimed? If so, consider serializing with Blocked by.

## Closing

All items pass → `gh issue edit <N> --repo <owner/repo> --add-label agent-ready` +
a priority label. Any item fails → report what needs fixing to the user and do not
attach the label.
