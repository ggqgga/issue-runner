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

- `MAX_AGENTS = 5` — cap on concurrently in-flight issues (in-flight is defined
  in ③-1 — PRs waiting for human review do not occupy a slot)
- `MAX_OPEN_PRS = 10` — cap on total open PRs (backlog backpressure). When
  reached, only new dispatches stop (maintenance continues) — prevents rebase
  conflicts from multiplying across PRs while human merges lag
- `MAX_REPAIRS_PER_PR = 3` — cap on maintenance dispatches per PR
  (② Maintain circuit breaker)
- `ISSUE_TIMEBOX_HOURS = 1` — allowed claim age for a `working` issue with no PR
  (① Reconcile timebox)
- `STALE_FINISH_MIN = 30` — lost-finish time buffer (minutes, ② Maintain rules
  4b/4c). A live worker posts its final verdict within seconds of the
  `Verifier review:` comment, so if the latest `Verifier review:` is CLEAN yet no
  final verdict appears past this buffer, the worker is considered dead (→ 4b
  inline re-emit). In-progress fix loops are auto-excluded because their latest
  verifier comment is either recent or non-CLEAN.
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
  human-created branches, attaching the agent-ready label on your own.
  **Exception (allowed)**: in ② Maintain rule 4b, **appending the final
  `Merge verdict:` comment on behalf of** a lost-finish PR + reconciling the
  referenced issue's checkboxes — this is not a merge or label manipulation but
  posting step 13 (the final verdict append) in place of a dead worker, merely
  restoring the positive gate for closeout pickup.

## ① Reconcile

Run `$SCRIPTS/reconcile.sh` and handle each event:

- `merged` — successful completion. **Lessons step**: if any of the failure
  signals below is present (all checked via `gh pr view <pr> --repo <repo>`),
  synchronously invoke the `VERIFIER` subagent (following the VERIFIER contract
  and fallback in ## Constants). If no signal is present, do not invoke it and
  leave it NONE (record no lesson): (1) a CHANGES_REQUESTED review (`--json
  reviews`) · (2) a `gh run list` CI failure (GitHub Actions repos) · (3) a
  **local-ci commit status failure history** — if any of the PR's commits had the
  local-ci context as FAILURE (enumerate commit SHAs via `--json commits` and query
  each SHA via `gh api repos/<repo>/commits/<sha>/statuses` — the HEAD's `--json
  statusCheckRollup` keeps only the latest state per context and cannot see a
  failure history; a lesson candidate even if the final state is SUCCESS after a
  mid-life failure was fixed on a new SHA, as long as there is a failure history;
  on local-ci repos `gh run list` is always empty, so this is the effective
  trigger) · (4) a **BLOCKER in a verifier review comment** — if the PR's
  `마감 검증:`·`검증자 리뷰:` comment had a BLOCKER (`--json comments`).

  > "Read the review comments and CI failure logs of PR #<pr> (<repo>), and from
  > the objective failure facts produce exactly one recurrence-prevention lesson
  > line in the form 'When <situation>, do <specific action>'. No speculation or
  > generalities. If there are no failure facts, output 'NONE'."

  If the result is not NONE, append to the `.loop/lessons.md` under the path
  output by `$SCRIPTS/repo-dir.sh <repo>` (= `<repo-dir>/.loop/lessons.md` — the
  only interpretation that makes record and read point at the same file even on
  a repos.conf-mapped machine) in the form `- [YYYY-MM-DD PR#<pr>] <lesson>`.
  **If the file exceeds 20 lines, delete the oldest lines** (context-rot defense).
  Only a human moves lessons into CLAUDE.md.
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
4. CI green + no unresolved review comments → **classify the finish state** and
   branch. Only PRs where none of rules 1–3 fired reach here (failing==0, no
   unresolved human comment, no conflict). Run
   `$SCRIPTS/finish-classify.sh <repo> <pr>` and branch on its output
   (deterministic helper — the latest `Merge verdict:`/`Verifier review:` uses the
   last match in the comment array):

   - **4a finished — untouched.** `done_verdict` (latest `Merge verdict: ✅`) →
     waiting for closeout pickup, leave it. `held` (latest `Merge verdict: ⚠`) →
     worker's explicit hold (needs-human territory), no auto-progress. `active`
     (in progress · time buffer not reached · a recent non-CLEAN verifier) →
     waiting for human review or still finishing, leave it.
   - **4b lost finish · inline re-emit (common).** `stale_inline` (🔄 + latest
     verifier CLEAN + past `STALE_FINISH_MIN`) → the worker died just before step
     13 and only the final-verdict append was lost. **With no agent or worktree**,
     Maintain appends the final verdict itself (the allowed exception in the
     Constants "Absolutely forbidden"). Get the HEAD sha via
     `gh pr view <pr> --repo <repo> --json headRefOid -q .headRefOid`, then (body =
     verdict line + newline + sentinel as one `--body`, using `$'...\n...'` to put
     the marker on the last line):
     `gh pr comment <pr> --repo <repo> --body $'Merge verdict: ✅ mergeable — worker lost finish, re-emitted by Maintain (verifier CLEAN · local CI pass HEAD <sha> · nothing unresolved)\n<!-- bodat:worker -->'`
     — the last line must be exactly `<!-- bodat:worker -->` (closeout-eligible's positive
     gate matches `Merge verdict: ✅` by startswith and recognizes the machine via
     the sentinel — the marker must be the last line). Then, isomorphic to worker
     step 12, **conservatively reconcile the referenced issue's checkboxes**:
     read the body via `gh issue view <num> --repo <repo> --json body`, and for
     items marked `[x]` in the PR's `## Test plan`, flip only the corresponding
     acceptance-criteria/Test-plan lines' marks to `[x]` — **do not change a single
     character of the body text** (conservatively substitute only the checkbox
     `- [ ]`/`- [x]` marks). Set the flow label with
     `gh issue edit <pr> --repo <repo> --add-label flow:ready --remove-label flow:codex --remove-label flow:ci`
     (idempotent, best-effort). Count this PR in ④ Report's `lost-finish re-emit`
     count. **Not an agent dispatch — does not consume the circuit breaker.**
   - **4c verification incomplete · re-dispatch (rare).** `stale_reverify` (🔄 +
     the `Verifier review:` is itself absent or notes an unresolved BLOCKER + past
     `STALE_FINISH_MIN`) → code-quality verification did not finish (closeout's
     step 1 is plan-conformance verification only, not a code-quality gate, so an
     inline verdict is unsafe). Via the circuit breaker (common section),
     re-dispatch a **completion agent** — re-run the verifier → reconcile
     checkboxes → final verdict (worker steps 11–13). Replace the template's
     "Procedure" with "The PR is CI green with no conflict, but the finish
     (verifier → checkboxes → final verdict) was lost. Re-run the verifier review
     and complete it," keeping the rest (compound commands, push discipline,
     prohibitions). On breaker exhaustion, `needs-human` per the common section.

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
   c. If the `.loop/lessons.md` under the path output by `$SCRIPTS/repo-dir.sh
      <repo>` (= `<repo-dir>/.loop/lessons.md`, same interpretation as the record
      path) exists, read its contents.
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

One-line summary: `reconciled N · maintained N · lost-finish re-emit N · new N · waiting(human review) N · warn N`.
`lost-finish re-emit` = the number of PRs where ② Maintain 4b inline-appended a final verdict this tick.
If there are warns, list the paths and reasons below it.
**Token observation (soft budget)**: if any worker delivered a completion report, add
one line per issue — `tokens: <repo>#<num> <this report's count> (cumulative <sum>)`.
This count is subagent_tokens from the completion notification (absent → `?`, counted as 0);
cumulative = the same issue's `tokens:` figures from previous tick Reports visible in
context + this count (none visible → just this count). If it exceeds `SOFT_TOKEN_BUDGET_PER_ISSUE`,
state **"soft budget exceeded — recommend escalating to needs-human"** on that line (report only — never auto-label or stop workers).
If every count is 0, output the single line "quiet".
Even on a quiet tick, **run the eligible scan of ③ Dispatch (eligible-issues.sh)
every tick** — new agent-ready issues create no reconcile events, so skipping the
eligible scan makes quiet mode permanently blind to new candidates (on an empty
queue it is a single search/issues call, so the cost is negligible).
If eligible is empty and reconcile is also quiet, report the single line "quiet" and stop.

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
