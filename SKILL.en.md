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

- `MAX_AGENTS = 2` — cap on concurrently in-flight issues (in-flight is defined
  in ③-1 — PRs waiting for human review do not occupy a slot)
- `MAX_OPEN_PRS = 10` — cap on total open PRs (backlog backpressure). When
  reached, only new dispatches stop (maintenance continues) — prevents rebase
  conflicts from multiplying across PRs while human merges lag
- `MAX_REPAIRS_PER_PR = 3` — cap on maintenance dispatches per PR
  (② Maintain circuit breaker)
- `ISSUE_TIMEBOX_HOURS = 1` — allowed claim age for a `working` issue with no PR
  (① Reconcile timebox)
- `SOFT_TOKEN_BUDGET_PER_ISSUE = 300000` — soft token budget per issue. Not a
  hard cap but the observation threshold for ④ Report (the Agent call has no
  budget API, so it cannot be enforced).
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — verifier subagent type for reviews and lesson
  extraction. **Output contract (SSOT — everywhere else refers to this entry)**:
  review calls are read-only (no code changes), classify each finding as
  BLOCKER/WARN/NIT, output 'CLEAN' if there are no findings, and BLOCKERs are a
  gate (no finishing before they are resolved); lesson-extraction calls
  (① Reconcile) output 'one lesson line or NONE'. The verifier does not read
  SKILL.md, so the call's prompt string must carry this contract verbatim — the
  prompt is the only delivery path.
  **Fallback**: in environments without the codex plugin (the type above is
  missing from the Agent tool's subagent_type list, or the call fails with an
  unknown subagent type error), use `general-purpose` as the verifier — it is
  invoked with the same prompt, so the same contract applies.
- Absolutely forbidden: merging PRs, pushing directly to main, touching
  human-created branches, attaching the agent-ready label on your own

## ① Reconcile

Run `$SCRIPTS/reconcile.sh` and handle each event:

- `merged` — successful completion. **Lessons step**: if the PR had a
  CHANGES_REQUESTED review or a history of CI failures (check with
  gh pr view <pr> --repo <repo> --json reviews and gh run list), synchronously
  invoke the `VERIFIER` subagent (following the VERIFIER contract and fallback
  in ## Constants):

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
   **maintenance agent** in the background using the worker template file
   `~/.claude/skills/issue-runner/references/worker-template.en.md` (read and
   filled the same way as ③-4d; if the worktree is gone,
   `$SCRIPTS/make-worktree.sh` recreates it on top of the remote branch). Replace
   the template's "Procedure" with the concrete repair instructions, but keep
   everything else (compound commands, push discipline, prohibitions).
2. Unresolved review comments → in the same way, instruct a maintenance agent to
   resolve the comments. However, status comments left by the worker itself
   (starting with `Merge verdict:`/`머지 판정:` or `Verifier review:`/`검증자 리뷰:`)
   are not review comments — do not count them as repair triggers.
3. Conflict with base → instruct a maintenance agent to rebase (merging is
   forbidden).
4. CI green + no review comments → leave it alone. It is waiting for human review.

A `harvesting` event = closeout is in progress → **leave it alone** (no repair, rebase, or review-comment resolution). closeout merges/cleans it up.

## ③ Dispatch — only as many as there are free slots

1. Compute in-flight: the count of ①'s `working` + whatever this tick sent
   into ② + **red PRs** (`pr_open` with failing CI, unresolved review comments,
   or a conflict — the targets of ② 1–3). **PRs that are CI green with no
   comments (② 4, waiting for human review) do not occupy a slot** — they are
   dormant with nothing for an agent to do, so they must not block new work.
   `slots = MAX_AGENTS - in-flight`. If slots ≤ 0, skip this phase.
   **Backlog backpressure**: if the total number of open PRs (regardless of
   state) is ≥ `MAX_OPEN_PRS`, skip new dispatches and raise a
   "merge backlog: N PRs" warn in ④ Report (maintenance keeps running in ②).
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
   d. Right before dispatching, read
      `~/.claude/skills/issue-runner/references/worker-template.en.md`, fill the
      placeholders (`<WT_PATH>` `<REPO>` `<NUM>` `<TITLE>` `<DEFAULT_BRANCH>`
      `<REPO_DIR>` `<VERIFIER>` `<LESSONS_OR_"none">`), and dispatch it (background
      Agent tool call — the call signature is at the top of the template file). Fill
      `<DEFAULT_BRANCH>` from
      `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name`.
      Fill `<REPO_DIR>` with the output of `$SCRIPTS/repo-dir.sh <repo>` (the main
      checkout's absolute path) — the worker's codegraph exploration (`-p`) reads
      the index at this path.
      Fill `<VERIFIER>` from ## Constants with the fallback rule applied
      (`general-purpose` if codex is not installed).

## ④ Report

One-line summary: `reconciled N · maintained N · new N · waiting(human review) N · warn N`.
If there are warns, list the paths and reasons below it.
**Token observation (soft budget)**: if any worker delivered a completion report, add
one line per issue — `tokens: <repo>#<num> <this report's count> (cumulative <sum>)`.
This count is subagent_tokens from the completion notification (absent → `?`, counted as 0);
cumulative = the same issue's `tokens:` figures from previous tick Reports visible in
context + this count (none visible → just this count). If it exceeds `SOFT_TOKEN_BUDGET_PER_ISSUE`,
state **"soft budget exceeded — recommend escalating to needs-human"** on that line (report only — never auto-label or stop workers).
If every count is 0, output the single line "quiet".
After 3 consecutive quiet ticks, from the next tick on do only reconcile and stop.

## References

Non-operational notes — they do not affect tick execution.

- Prerequisite: this loop works **only on GitHub** — issues, labels, assignees, and
  PRs are the single source of truth for loop state, and GitHub Actions is not
  required (the local-ci design). See README, Prerequisites, for required permissions.
- Install model: as an account-wide dispatcher, the skill is installed at the user
  level (`~/.claude/skills`), while per-repo participation is a separate label
  opt-in (`setup-labels.sh`) — see README, Install.
- Running loops in parallel: if the session cwd has a `.loop/repos` allowlist,
  collection (eligible) and inspection (reconcile) are restricted to those repos —
  for per-project loop sessions; without the file, the whole account is in scope.
  The scripts apply this automatically, so the tick has nothing extra to do
  (see README, Usage).
- Recommended companion: [codegraph](https://github.com/colbymchenry/codegraph) —
  when a repo has a `.codegraph/` index, workers explore existing code via index
  queries instead of repeated grep/Read scans, cutting tokens and tool calls.
  Opt-in per repo with `codegraph init` — the loop works fine without it
  (see README, Prerequisites).
- Sources consulted for the design: [Keep Claude working toward a goal — official Claude Code docs](https://code.claude.com/docs/en/goal) ·
  [loop-engineering discourse (YouTube)](https://www.youtube.com/watch?v=EH2MMQTaPEA) ·
  [Reddit discussion](https://www.reddit.com/r/myclaw/comments/1u047p8/so_is_loop_engineering_the_next_ai_dev_buzzword/) ·
  [agent loop internals analysis](https://internals.laxmena.com/p/why-claude-codes-agent-loop-is-over) ·
  [Rails 8.1 release notes — origin of the `bin/ci` convention](https://guides.rubyonrails.org/8_1_release_notes.html)
