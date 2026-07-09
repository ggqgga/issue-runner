---
name: loop-issues
description: Closing checklist before handing an issue to the issue-runner loop. Use closing mode on requests like "send this to the loop", "hand it to the loop", "put it on the loop", "finalize this issue", or "attach agent-ready". Use creation mode on "make a loop issue for this", "we'll put this on the loop" (no issue exists yet, or starting from a plan/spec) — create the issue first, then close it out. For batch-analysis requests over existing issues like "analyze which issues can go on the loop" or "analyze the issues and label them", use triage mode. Attach the agent-ready label only after the checklist passes.
---

> English translation of [SKILL.md](SKILL.md). The Korean original is the source of
> truth — when the two diverge, follow SKILL.md and update this file to match.
> To run this skill in English, replace SKILL.md with this file's contents.

# loop-issues — issue closing checklist

There are three modes: **closing mode** (default — finalize the single issue at hand
against the checklist), **creation mode** (no issue exists yet, or starting from a
plan/spec — create the issue first, then close it out; see the "Creation mode"
section below), and **triage mode** (batch-analyze and classify the repo's existing
open issues — see the "Triage mode" section below).

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
   buried in prose are invisible to the dispatcher. You may also express it with a
   `blocked-by:<N>` **label** (blocking is then visible right in the issue list —
   attach via `scripts/block-issue.sh <owner/repo> <issue#> <blocker#>`). The body
   line and the label are combined with **OR**, and `<N>` is the **issue number** —
   when the blocker issue is CLOSED the gate releases automatically. Either one
   suffices.
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
9. **Difficulty assessment**: if it touches multiple files/modules at once, has more
   than one viable design choice, or the acceptance criteria alone do not pin down a
   single implementation path, it is **high**.
   For high issues, settle the spec through conversation in the planning session
   (the only point where a human is available to talk to; superpowers users may use
   /superpowers:brainstorming — it is not a dependency, a hand-written plan has the
   same effect), and attach a `## Plan` section to the issue body.
   Required `## Plan` structure: a step-by-step task list (each task names the file
   paths to modify/create) + a verification command per task. Task order is the
   execution order.

   **Split first**: for high issues, consider splitting into staged sub-issues
   before attaching a Plan (ties into hierarchy item 5) — the smaller the PR, the
   more accurate both the worker's implementation and the verifier's review. The
   criterion is not task count but **whether the seam is independently verifiable**:
   - If each piece leaves an independently observable, verifiable result (e.g. a
     data-ledger issue and a viewing-UI issue on top of it) → split and serialize
     with `Blocked by`. Split pieces usually drop to medium or below, and
     hardware verification (needs:hardware) stays only on the pieces that need it.
   - If the seam runs through the middle of a contract so that either half is
     meaningless alone (e.g. sender/receiver — neither has an observable result by
     itself) → keep it whole and attach a `## Plan`.
   A Plan beyond 5 tasks is almost always the former — split first.

   `## Plan` format example:

   ```markdown
   ## Plan

   1. Add a --dry-run flag to scripts/foo.sh (arg parsing + print plan without changes)
      - Verify: `ISSUE_RUNNER_PROJECTS_ROOT=/tmp scripts/foo.sh --dry-run owner/repo`
        output contains "would clone", no filesystem changes
   2. Add one line about dry-run usage to the Dispatch step in SKILL.md
      - Verify: `bin/ci` passes
   3. Mirror the same content in English in SKILL.en.md
      - Verify: `bin/ci` passes (including the KR/EN structure sync check)
   ```

## Closing

All items pass → `gh issue edit <N> --repo <owner/repo> --add-label agent-ready` +
a priority label. Any item fails → report what needs fixing to the user and do not
attach the label.

## Creation mode — making issues from a plan or spec

Trigger: the user wants to put work on the loop that isn't an issue yet — "make a
loop issue for this", "we'll put this on the loop" (after discussing a plan/spec). If
no issue exists, **create it first**, then run the closing checklist.

1. **The scope is the user's.** Background, goal, and constraints come from this
   session's discussion/plan — same rule as triage: the skill does not invent scope or
   add requirements the human didn't set. If no plan was discussed, settle the spec
   with the user first, then create.
2. **Check repo readiness** (checklist item 7): if the target repo has no label set,
   run `~/.claude/skills/issue-runner/scripts/setup-labels.sh <owner/repo>`; if
   `CLAUDE.md` has no build/test commands, add them first (without them the worker
   can't verify).
3. **Write the body in checklist form**: background + `- [ ]` acceptance criteria +
   `## Test plan` + (if there's a prerequisite) a dedicated `Blocked by #N` line — i.e.
   a self-contained spec from the moment it's created.
4. **Split large work** (checklist item 9): if it's high (several modules, or more
   than one reasonable design), break it into independently-verifiable sub-issues
   serialized with `Blocked by` (create each), or keep it whole and attach a `## Plan`
   (numbered tasks + file paths + per-task verification). A parent gets only the `epic`
   label; `agent-ready` goes on leaves only.
5. **Create + close out**: `gh issue create --repo <owner/repo> --title ... --body ...`
   (create blockers first to get their numbers), then run each issue through the
   closing steps above to attach a priority + `agent-ready` (last). If any checklist
   item fails, don't attach the label — report what's missing. Creating an issue does
   not auto-enroll it.

## Triage mode — batch analysis of existing issues

Trigger: the user asks for a loop-suitability analysis of a repo's (or account's)
existing issues ("analyze which issues can go on the loop", "analyze the issues and
label them").

1. **Collect targets**: first decide the list of repos to walk —
   - For a single-repo request, just that repo.
   - **For an account-scoped request**, get the repo list with
     `gh repo list <me> --no-archived --limit 200 --json nameWithOwner`
     (or an equivalent method) and walk **only the repos where the agent-ready
     label set exists (= opted in)**. Determine opt-in by whether agent-ready
     appears in `gh label list --repo <repo>`.

   In each repo, collect with
   `gh issue list --repo <owner/repo> --state open --limit 200 --json number,title,labels,body`
   and exclude issues that already have the agent-ready, agent:claimed, or
   needs-human label. If the result count reaches the limit (200), flag the report
   with a **"collection limit reached — possible omissions"** warning — no silent
   truncation.
2. **Classify**: check each issue against the 9 checklist items above and sort it
   into one of three buckets:
   - **READY** — passes the checklist. Include a proposed priority (P0/P1/P2) to
     attach.
   - **FIXABLE** — name the missing items (e.g. no Test plan, vague acceptance
     criteria, missing Blocked by) and propose a body amendment.
   - **UNFIT** — an epic (split first), needs a human decision, or requires a spec
     rewrite. State the reason.
3. **Report**: present the results as a table —
   issue number / title / classification / reason·amendment / proposed priority.
4. **Apply — only after user approval**: attach labels to READY; for FIXABLE, update
   the body with the approved amendment and then attach the label. Leave UNFIT
   untouched.
   Before approval, modify no issue body and attach no label —
   triage must not rewrite a human's spec on its own and push it into the loop.
   As always, labels go only to issues that pass the checklist.
