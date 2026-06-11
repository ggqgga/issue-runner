---
name: issue-runner
description: Autonomous dispatcher that picks up agent-ready issues across your entire GitHub account, implements them in worktrees, and opens PRs. Use with /loop (e.g. /loop 15m /issue-runner). Each tick performs Reconcile → Maintain → Dispatch → Report. Never merges.
---

> English translation of [SKILL.md](SKILL.md). The Korean original is the source of
> truth — when the two diverge, follow SKILL.md and update this file to match.
> To run the dispatcher in English, replace SKILL.md with this file's contents.

# issue-runner — issue dispatcher tick

You are an unattended dispatcher. Perform the four phases below **in order**. Do not
reorder the phases (cleanup must come first so the slot count is accurate, and
maintenance must come before new work).

## Constants

- `MAX_AGENTS = 2` — cap on concurrently in-flight (claimed) issues
- `MAX_REPAIRS_PER_PR = 3` — cap on maintenance dispatches per PR
  (② Maintain circuit breaker)
- `ISSUE_TIMEBOX_HOURS = 1` — allowed claim age for a `working` issue with no PR
  (① Reconcile timebox)
- `SOFT_TOKEN_BUDGET_PER_ISSUE = 300000` — soft token budget per issue. Not a
  hard cap but the observation threshold for ④ Report (the Agent call has no
  budget API, so it cannot be enforced).
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — verifier subagent type for reviews and lesson
  extraction. **Fallback**: in environments without the codex plugin (the type above
  is missing from the Agent tool's subagent_type list, or the call fails with an
  unknown subagent type error), use `general-purpose` as the verifier. The fallback
  verifier must follow **the same per-call output contract**: review calls are
  read-only (no code changes), classify each finding as BLOCKER/WARN/NIT, output
  'CLEAN' if there are no findings, and BLOCKERs are a gate (no finishing before
  they are resolved); lesson-extraction calls (① Reconcile) output
  'one lesson line or NONE'.
- Absolutely forbidden: merging PRs, pushing directly to main, touching
  human-created branches, attaching the agent-ready label on your own

## ① Reconcile

Run `$SCRIPTS/reconcile.sh` and handle each event:

- `merged` — successful completion. **Lessons step**: if the PR had a
  CHANGES_REQUESTED review or a history of CI failures (check with
  gh pr view <pr> --repo <repo> --json reviews and gh run list), synchronously
  invoke the `VERIFIER` subagent (including the not-installed fallback —
  see ## Constants) to get a one-line lesson:

  > "Read the review comments and CI failure logs of PR #<pr> (<repo>), and from
  > the objective failure facts produce exactly one recurrence-prevention lesson
  > line in the form 'When <situation>, do <specific action>'. No speculation or
  > generalities. If there are no failure facts, output 'NONE'."

  If the result is not NONE, append to `~/Projects/<repo-name>/.loop/lessons.md`
  in the form `- [YYYY-MM-DD PR#<pr>] <lesson>`. **If the file exceeds 20 lines,
  delete the oldest lines** (context-rot defense). Only a human moves lessons
  into CLAUDE.md.
- `rejected` — a human rejected the PR. Perform the lessons step the same way.
  Do not re-dispatch the issue (agent-ready has already been removed).
- `stale` — a dead claim was released. Report only.
- `warn` — dirty/unpushed worktree. **Do not touch it** — surface it as-is in
  Report so a human sees it.
- `pr_open` — input to ② Maintain.
- `working` — a worker is in progress. Use TaskList to check whether that
  background agent is actually alive. If it is dead and there are pushed commits,
  treat it as a maintenance target for ②. If there are no commits at all, check
  the issue's latest comment **before** releasing the claim —
  `gh issue view <num> --repo <repo> --json comments --jq '.comments | last.body'`.
  If it starts with `BLOCKED:`, the worker stopped because human intervention is
  needed (ambiguous spec / plan-reality mismatch / same failure repeating):
  instead of returning the issue to a re-dispatchable state, attach the
  `needs-human` label with
  `gh issue edit <num> --repo <repo> --add-label needs-human`, remove the
  worktree, release the claim, and surface the BLOCKED reason as a warn in
  ④ Report (once a human resolves the cause and removes needs-human, the issue
  flows again — the README 'guardrails' convention). If the latest comment is not
  a BLOCKED comment, remove the worktree and release the claim (returning the
  issue to a re-dispatchable state).
  **Timebox (no-progress detection)**: even if it is alive, check the claim age —
  get the claim timestamp with
  `gh api repos/<repo>/issues/<num>/timeline --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed")] | last.created_at'`
  (if the response is empty, fall back to the worktree directory's creation time).
  If the difference from the current time exceeds `ISSUE_TIMEBOX_HOURS`
  (`working` by definition means there is no PR):
  ⓐ stop the worker with TaskStop (pushed commits are preserved on the remote
  branch),
  ⓑ remove the worktree — `git -C <repo-dir> worktree remove --force <wt>` then
  `git -C <repo-dir> branch -D agent/issue-<num>`. Unpushed leftovers are
  **deliberately discarded** as the price of exceeding the timebox — if left in
  place, the next dispatch's make-worktree would hand the stopped worker's
  intermediate state to a fresh worker, breaking worktree isolation (the
  dirty-warn hold rule is for leftovers of unknown origin, so it does not apply
  to this deliberate stop),
  ⓒ release the claim with
  `gh issue edit <num> --repo <repo> --remove-label "agent:claimed"`, and
  ⓓ surface it as a warn in ④ Report (agent-ready remains, so the next tick
  re-dispatches in a fresh worktree on top of the remote branch).

## ② Maintain — finish what you started first

For each `pr_open` event:

**Circuit breaker — common to every maintenance dispatch in 1–3 below**:
read the `<!-- repair-count: N -->` HTML comment from the PR body
(`gh pr view <pr> --repo <repo> --json body`; if the comment is absent, N = 0).
If N ≥ `MAX_REPAIRS_PER_PR`, **do not dispatch a repair** — attach the
`needs-human` label to the issue with
`gh issue edit <num> --repo <repo> --add-label needs-human` and surface it as a
warn in ④ Report. If N is below the cap, dispatch the maintenance agent and at
the same time update the comment in the PR body to `<!-- repair-count: N+1 -->`
(`gh pr edit <pr> --repo <repo> --body ...` — if the comment was absent, append
it at the end of the body, keeping the rest of the body unchanged). Even when
several of the causes 1–3 apply to the same PR, dispatch **one maintenance agent
per PR per tick** — merge all repair instructions into that single agent's
prompt, and increment N by exactly 1 per dispatch.

1. `failing > 0` → inspect the failure logs (gh run view --log-failed); if it
   looks like a flake, re-run (gh run rerun); if it is a real failure, dispatch a
   **maintenance agent** in the background using the worker template below (if the
   worktree is gone, `$SCRIPTS/make-worktree.sh` recreates it on top of the remote
   branch). Replace the template's "Procedure" with the concrete repair
   instructions, but keep everything else (compound commands, push discipline,
   prohibitions).
2. Unresolved review comments → in the same way, instruct a maintenance agent to
   resolve the comments.
3. Conflict with base → instruct a maintenance agent to rebase (merging is
   forbidden).
4. CI green + no review comments → leave it alone. It is waiting for human review.

## ③ Dispatch — only as many as there are free slots

1. Compute in-flight: the count of ①'s `working` + `pr_open` + whatever this tick
   sent into ②. `slots = MAX_AGENTS - in-flight`. If slots ≤ 0, skip this phase.
2. Run `$SCRIPTS/eligible-issues.sh` → priority-sorted candidates.
3. **LLM judgment (only toward picking less)**: if two or more candidates look
   like they will touch the same repo and the same module, pick only one this
   tick. If you cannot tell, pick it (a conflict gets resolved by the next tick's
   rebase).
4. For up to `slots` candidates in priority order:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — on failure (already claimed, etc.)
      move on to the next candidate.
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — the last output line is the
      worktree path.
   c. If `~/Projects/<repo-name>/.loop/lessons.md` exists, read its contents.
   d. Dispatch in the background via the Agent tool using the worker template
      below. Fill the template's `<DEFAULT_BRANCH>` from
      `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name`.
      Fill `<VERIFIER>` from ## Constants with the fallback rule applied
      (`general-purpose` if codex is not installed).

### Worker prompt template

Agent(subagent_type: "general-purpose", run_in_background: true,
      description: "implement <repo>#<num>", prompt: below)

```
You are an unattended issue-implementation worker. Working directory: <WT_PATH> (do not modify anything outside it)
Target: <REPO> issue #<NUM> — <TITLE>

Important: the shell cwd does not persist between Bash calls. Run every shell command
as a compound `cd <WT_PATH> && <command>` or use absolute paths (`git -C <WT_PATH>`).

Procedure:
1. Read CLAUDE.md in <WT_PATH> to learn how to build and test.
2. Read the 'Past lessons' below and avoid repeating the same mistakes.
3. Read the issue body (acceptance-criteria checkboxes) carefully with
   `gh issue view <NUM> --repo <REPO>`. If the body is too ambiguous to determine
   an implementation direction, **do not work** — leave a comment starting with
   `BLOCKED: <reason>` (including your question) on the issue with
   `gh issue comment`, then finish with the report "BLOCKED: <reason>".
4. If the issue body has a `## Plan` section, **do not design on your own** —
   follow its task order as written. If the plan conflicts with reality (a named
   file does not exist, or a premise no longer holds), do not work around it by
   guessing — leave a comment starting with
   `BLOCKED: plan-reality mismatch — <details>` on the issue with
   `gh issue comment`, then finish with the report
   "BLOCKED: plan-reality mismatch — <details>".
5. Implement with TDD. Follow this discipline:
   - Do not write implementation code before a test exists.
   - Write a failing test first, and implement **only after confirming it fails
     for the right reason**.
   - Map at least one test to each acceptance-criteria checkbox.
   - After it passes, finish behavior-preserving refactoring before committing.
     Commit in small units.
   - If the repo has no test runner, do not introduce one on your own — follow
     the CLAUDE.md guidance, and if there is none, state in the PR body why
     testing was not possible.
6. Before each commit, run the stack's lint and tests yourself and confirm they pass
   (the global quality-gate hook does not protect worktree commits — you are the
   only line of defense).
7. If the same test/build failure repeats 3 times in a row (the same check failing
   for the same cause), stop trying — leave a comment starting with
   `BLOCKED: same failure repeating — <failure details>` on the issue with
   `gh issue comment`, then finish with the report
   "BLOCKED: same failure repeating — <failure details>".
   (Every BLOCKED exit must leave an issue comment — the dispatcher reads that
   comment and escalates to needs-human instead of re-dispatching.)
8. **Immediately after every commit, run `cd <WT_PATH> && git push -u origin agent/issue-<NUM>`** —
   this worktree can be discarded at any time. Unpushed work is as good as nonexistent.
9. After the final push, run local CI:
   `~/.claude/skills/issue-runner/scripts/run-local-ci.sh <REPO> <NUM>`
   (Automatically skipped if the repo has not opted into bin/ci.) If it fails, fix,
   re-commit/re-push, and run it again — the human merge gate reads this result
   cache. Re-run it after every subsequent pushed commit so the cache holds the
   result for the latest HEAD.
10. Open the PR. **It must be a standalone command with no cd**:
   `gh pr create --repo <REPO> --head agent/issue-<NUM> --base <DEFAULT_BRANCH> ...`
   (Prefixing cd breaks the PR hooks' if-matching, so the issue-reference check and
   the codex review injection get skipped.) The body must include a dedicated line
   `Closes #<NUM>` and a `## Test plan` section (checkboxes based on the
   acceptance criteria).
11. After creating the PR, **spawn the verifier review yourself** (the PostToolUse
   hook's codex injection does not reach subagent contexts — do not wait for it).
   Synchronous Agent tool call: subagent_type: "<VERIFIER>", prompt:
   "Code review of PR #<PR_NUMBER> (<REPO>). Read the changes from
   `git -C <WT_PATH> diff <DEFAULT_BRANCH>...HEAD` and review for:
   (1) correctness bugs (2) missing edge cases (3) test adequacy
   (4) obvious over-engineering. No code changes, read-only. Report in English,
   classifying each finding as BLOCKER/WARN/NIT. If there are no findings, output 'CLEAN'."
   If the call fails with an unknown subagent type error, retry **the same prompt**
   with subagent_type: "general-purpose" (same contract — read-only,
   BLOCKER/WARN/NIT, CLEAN).
   If the verifier reports a BLOCKER, finish **only after a fix commit + push +
   local CI re-run**. Never finish with an unresolved BLOCKER. Summarize WARN/NIT
   in the PR body under a "## Verifier review" section.
12. Final report: PR number/URL, test results, how the verifier review was handled,
    anything left over.

Forbidden: merging, pushing directly to main/master, changing issue labels,
working on other issues, modifying anything outside <WT_PATH>.

Past lessons:
<LESSONS_OR_"none">
```

## ④ Report

One-line summary: `reconciled N · maintained N · new N · waiting(human review) N · warn N`.
If there are warns, list the paths and reasons below it.
**Token observation (soft budget)**: if any worker delivered a completion report
this tick, add below it one line per issue —
`tokens: <repo>#<num> <this report's count> (cumulative <sum>)` — where this
report's count is subagent_tokens from the completion notification (if the
figure is absent, write `?` and treat it as 0 in the cumulative sum), and the
cumulative sum is the figures from **this loop session's previous tick Reports**
(the `tokens:` lines for the same issue still in the conversation context) plus
this report's count (if no previous line is in context, this report's count =
the cumulative sum). If the cumulative sum is greater than
`SOFT_TOKEN_BUDGET_PER_ISSUE`, state on that line **"soft budget exceeded —
recommend escalating to needs-human"** (report only — it is a soft budget, so do
not auto-attach the label or stop the worker).
If every count is 0, output the single line "quiet".
After 3 consecutive quiet ticks, from the next tick on do only reconcile and stop.
