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

- `MAX_AGENTS = 3` — cap on concurrently in-flight issues (in-flight is defined
  in ③-1 — PRs waiting for human review do not occupy a slot). **Lowered 5→3 in a
  2026-07 contention experiment**: workers are all background subagents in one
  process, so N concurrent ones share API/CPU and each is throttled to ~1/N
  (measured: 0 concurrent ~10 min vs 1–4 concurrent ~30 min). Throughput is roughly
  preserved while box load and orphan risk drop. Lower to 2 if it is still slow.
- `MAX_OPEN_PRS = 10` — cap on total open PRs (backlog backpressure). When
  reached, only new dispatches stop (maintenance continues) — prevents rebase
  conflicts from multiplying across PRs while human merges lag
- `MAX_REPAIRS_PER_PR = 3` — cap on maintenance dispatches per PR
  (② Maintain circuit breaker)
- `ISSUE_TIMEBOX_HOURS = 1` — allowed claim age for a `working` issue with no PR
  (① Reconcile timebox)
- `STALE_FINISH_MIN = 30` — lost-finish time buffer (minutes). The buffer for
  `finish-classify.sh`, which is now consumed by the **closeout ①-b stuck-PR sweep**
  (issue-runner no longer uses it directly after the rule-4 revert). A live worker
  posts its final verdict within seconds of the `Verifier review:` comment, so if the
  latest verifier is CLEAN yet no final verdict appears past this buffer, the worker
  is considered dead. In-progress fix loops are auto-excluded because their latest
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
  human-created branches, attaching the agent-ready label on your own, appending the
  final `Merge verdict: ✅` on behalf of a lost-finish PR (that recovery is owned by
  the closeout ①-b sweep).
  **Allowed**: the ② Maintain rule-0 flow-label (`flow:*`) correction (these are
  self-describing labels the worker attaches at each step, so aligning them to the
  actual state as a scan safety net is not manipulation).

## ① Reconcile

Run `$SCRIPTS/reconcile.sh` and handle each event:

- `merged` — successful completion. **Orphan-worker cleanup (first)**: if this
  issue's worker is still alive (check TaskList for the `implement <repo>#<num>`
  background agent), stop it with `TaskStop` — the PR has merged so the worker's
  work is moot, and if left alone it holds the already-closed PR and spins forever
  (the recovery path for the observed orphan ghost). Then the **Lessons step**: if any of the failure
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
- `rejected` — a human rejected the PR. **If a worker is still alive, stop it first
  with `TaskStop` the same as `merged`** (orphan prevention). Perform the lessons step the same way.
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
3. Conflict with base → **no longer rebase here** — conflict-rebase ownership was
   transferred to closeout (closeout ③ step 2 rebases and merges directly after
   taking the `harvesting` occupation). issue-runner leaves conflict PRs untouched
   and defers to the next closeout tick. Still count them as in-flight since they
   are unfinished (③ backpressure stays).
4. CI green + no unresolved review comments → **leave it alone.** Either it is
   waiting for human review, or the worker died before writing the final
   `Merge verdict: ✅` (**lost finish**). Lost-finish recovery (closing out PRs that
   reached verification / re-dispatching PRs that died before verifying) is owned by
   the **closeout ①-b stuck-PR sweep** (which consumes `finish-classify.sh`).
   issue-runner does **not** append final verdicts on behalf of lost-finish PRs or
   re-dispatch completion agents — the finish logic is unified into the closeout
   loop rather than loaded onto this one (role split). Only the flow-label
   correction (rule 0) is kept, to leave self-describing PR lists and a supplementary
   signal for the closeout sweep.

A `harvesting` event = closeout is in progress → **leave it alone** (no repair, rebase, or review-comment resolution). closeout merges/cleans it up.

## ③ Dispatch — only as many as there are free slots

1. Compute in-flight: the count of ①'s `working` + whatever this tick sent
   into ② + **red PRs** (`pr_open` with failing CI or unresolved review comments =
   targets of ② 1–2; plus conflicts = closeout's transferred responsibility but still
   counted as backpressure since unfinished). **PRs that are CI green with no
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
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — on failure (already claimed, lost
      the lock race, etc.) move on to the next candidate. Before touching labels
      the helper takes a create-only lock ref
      (`refs/issue-runner/claim/<num>/<anchor>`) — label writes are idempotent and
      therefore cannot serve as a lock on their own (#108). Two loop sessions
      racing for the same issue leave exactly one winner. When a previous attempt
      died without committing and only its lock remains, the helper takes over by
      creating `<anchor>-takeover` (a sibling — a child path is impossible due to
      git's ref D/F conflict) — also create-only, so that race likewise
      leaves one winner and atomicity holds on the stale-takeover path too.
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — the last output line is the
      worktree path. Secret symlinks (`.env`, `config/master.key`) are off by
      default — they appear only in repos that opt in via `link-secrets` in
      `repos.conf` (#109). In repos without it, credential-dependent tests are
      reported as **skipped**, not failed.
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

One-line summary: `reconciled N · maintained N · new N · waiting(human review) N · warn N`.
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
