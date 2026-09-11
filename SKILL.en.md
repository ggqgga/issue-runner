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

- `MAX_AGENTS = 4` — cap on concurrently in-flight issues (in-flight is defined
  in ③-1 — PRs waiting for human review do not occupy a slot). **Lowered 5→3 in a
  2026-07 contention experiment**: workers are all background subagents in one
  process, so N concurrent ones share API/CPU and each is throttled to ~1/N
  (measured: 0 concurrent ~10 min vs 1–4 concurrent ~30 min). Throughput is roughly
  preserved while box load and orphan risk drop. Lower to 2 if it is still slow.
- `MAX_OPEN_PRS = 14` — cap on total open PRs (backlog backpressure). When
  reached, only new dispatches stop (maintenance continues) — prevents rebase
  conflicts from multiplying across PRs while human merges lag
- `MAX_REPAIRS_PER_PR = 3` — cap on maintenance dispatches per PR
  (② Maintain circuit breaker)
- `ISSUE_TIMEBOX_HOURS = 1` — the claim age at which a `working` issue with no PR
  **starts being asked for progress evidence** (① Reconcile timebox). Exceeding it is
  **not by itself a reason to stop** — past this age the issue is still reprieved as
  long as there is progress evidence (#200).
- `STALL_MIN = 25` — the "no progress" threshold (minutes). Only when the latest commit
  on the remote branch `agent/issue-<num>` is older than this does the commit-side
  evidence die. Rationale: bodat's measured `bin/ci` upper bound of ~570s (9.5 min) for a
  single run plus slack for the box-wide serial CI queue (#127) — while a worker waits
  out one CI run it is normal for no new commit to appear, so that window must not be
  counted as stalling.
- `MAX_TIMEBOX_GRACE = 3` — cap on **cumulative reprieves** within the same claim (an
  `unknown` tick in between does not reset it — the counting window is everything after
  the claim timestamp). Past
  it the worker is stopped by the rule even with progress evidence — an unbounded
  reprieve would never catch a real zombie, making the relaxation itself a new hole. At a
  15-minute tick that is at most ~45 extra minutes, which covers the measured shapes
  (72 min · 64 min) while still leaving a ceiling. The count is not a state file: it is
  re-derived by counting issue comment markers (`<!-- timebox-grace: N -->`) created
  **after the current claim timestamp only**.
- `RESUME_AFTER_MIN = 120` — how long (minutes) the resume sweep waits before letting a
  stalled issue flow again. Once a `needs-human` + `hold:ladder` issue has gone this long
  without an update, ①'s resume sweep picks it up (passed to `resume-sweep.sh` as the
  environment variable of the same name).
- `LADDER_RESUME_LIMIT = 2` — cap on automatic resumes per issue. Beyond it the issue is
  escalated to `hold:policy` instead of resumed — only then is it a human's (no infinite
  retries).
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

- `merged` — the PR merged. ★**This does not mean the issue closed**★ — a PR that
  lands only part of the work uses `Refs` instead of `Closes`, so the issue stays
  OPEN and `release-labels.sh` keeps `agent-ready` in that case, letting a later
  tick pick up the remaining half (#117 — it used to strip the label
  unconditionally, silently stranding the issue). **Orphan-worker cleanup (first)**: if this
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
  `gh issue view <num> --repo <repo> --json comments --jq '[.comments[] | select((.body | test("<!--\\s*timebox-grace:")) | not)] | last.body'`
  (timebox reprieve markers are skipped — if a marker takes the latest-comment slot it
  hides the worker's `BLOCKED:` and the issue silently loses its claim instead of being
  escalated to a human, #200).
  If it starts with `BLOCKED:`, the worker stopped because human intervention is
  needed (ambiguous spec / plan-reality mismatch / same failure repeating):
  instead of returning the issue to a re-dispatchable state, attach the
  `needs-human` + `hold:policy` labels with
  `$SCRIPTS/transition.sh runner-held <repo> <num> <pr|-> --reason policy --note "<the one-line question a human must answer>"` (this also releases
  the claim — a reason-less `needs-human` is never produced, #151), remove the
  worktree, and surface the BLOCKED reason as a warn in
  ④ Report (once a human resolves the cause and removes **both** `needs-human`
  **and** `hold:*`, the issue flows again — the gate also reads the `hold:` prefix,
  so dropping only one of the two leaves it out of the queue, #242. The README
  'guardrails' convention). If the latest comment is not
  a BLOCKED comment, remove the worktree and release the claim (returning the
  issue to a re-dispatchable state).
  **Timebox (no-progress detection)**: even if it is alive, check whether it is **making
  progress** — the decision input is progress evidence, not elapsed time (#200: the
  elapsed time swallows the box-wide serial CI queue wait, which the worker does not
  control; in two measured cases that nearly killed workers that were still working).
  Get the claim timestamp with
  `gh api repos/<repo>/issues/<num>/timeline --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed")] | last.created_at'`
  (if the response is empty, fall back to the worktree directory's creation time) and
  hand it to `$SCRIPTS/timebox-check.sh <repo> <num> --claim-at <ISO8601>` (`working` by
  definition means there is no PR). The verdict is one line —
  `<verdict> <reason> elapsed=..m commit=..m queue=.. grace=n/max`:
  - `ok` (exit 0) — the claim age is still within `ISSUE_TIMEBOX_HOURS`. Leave it alone.
  - `grace` (exit 0) — past the age but there is progress evidence: the latest commit is
    within `STALL_MIN` (`recent_commit`), or that head SHA's CI ticket is still alive in
    the box-wide queue (`ci_queued`). **Do not stop it this tick.** The helper appends a
    reprieve marker to the issue, so the next tick counts those markers against
    `MAX_TIMEBOX_GRACE`. Put the verdict line as-is (elapsed · last commit · queue state ·
    reprieve n/max) into ④ Report as an **info line, not a warn**, so an endless reprieve
    is visible.
  - `stop` (exit 1) — no progress (`no_progress`) or the reprieve cap is spent
    (`grace_exhausted`). Do ⓐ–ⓓ below as written.
  - `unknown` (exit 2) — a decision input could not be obtained (claim timestamp, branch
    lookup, comment lookup, or the reprieve-marker append failed). **Do not stop it** —
    surface it as a warn in ④ Report. Killing a live worker on a lookup failure discards
    unpushed leftovers irreversibly, whereas a reprieve can be reversed next tick.
  Only when the verdict is `stop`:
  ⓐ stop the worker with TaskStop (pushed commits are preserved on the remote
  branch),
  ⓑ remove the worktree — `git -C <repo-dir> worktree remove --force <wt>` then
  `git -C <repo-dir> branch -D agent/issue-<num>`. Unpushed leftovers are
  **deliberately discarded** as the price of the `stop` verdict — if left in
  place, the next dispatch's make-worktree would hand the stopped worker's
  intermediate state to a fresh worker, breaking worktree isolation (the
  dirty-warn hold rule is for leftovers of unknown origin, so it does not apply
  to this deliberate stop),
  ⓒ release the claim with
  `gh issue edit <num> --repo <repo> --remove-label "agent:claimed"`, and
  ⓓ surface it as a warn in ④ Report (agent-ready remains, so the next tick
  re-dispatches in a fresh worktree on top of the remote branch).

**Resume sweep — a stalled issue is retried by the tick.** After handling every event
above, run `$SCRIPTS/resume-sweep.sh` with no arguments (the script applies the loop
session cwd's `.loop/repos` scope on its own). Of the stops recorded by `needs-human` plus
a reason label, only **`hold:ladder`** (stopped because ladder rungs ①–③ of live
verification all failed) is reverted automatically once the window (`RESUME_AFTER_MIN`)
passes — `hold:conflict` and `hold:policy` are human decisions and are left alone. Run it
**before** ③ Dispatch so this same tick can pick the issue up.
The resume count is the number of issue **comments** carrying the marker
`<!-- ladder-resume: N -->` — the body is neither read nor written (append-only, so it can
never overwrite someone's edit). Stop labels are mirrored onto the issue **and its open
linked PR**, so a resume/escalation reverts the PR's labels too — otherwise the PR stays
permanently human-blocked and the downstream transitions (handoff-verify, verify-pass,
closeout-pick) never remove it. Per event:

- `resumed` — `needs-human` and `hold:ladder` are off and `agent-ready` is untouched (the
  eligibility label is never touched). **Nothing for the dispatcher to do** — the issue
  reappears naturally as an `eligible-issues.sh` candidate in ③ this tick. Record the
  number and `attempt` under `resumed` in ④ Report. An issue carrying the deploy-wait
  label (`deploy-wait`) never emits this event even once the window passes (#217) — it
  goes to `note` below instead.
- `escalated` — the resume cap (`LADDER_RESUME_LIMIT`) was exceeded, so the issue was
  escalated to `hold:policy` (`attempt`/`limit` are the resumes the marker comments actually
  recorded vs. the cap — read as `2/2`). The script already applied the label, so with
  **no further action** list it under `escalated` in ④ Report for a human to see.
- `warn` — a `needs-human` with no reason label (`hold:*` — a human may have attached it by
  hand, so it is not an auto-resume target), a human-owned `hold:*` coexisting with
  `hold:ladder`, a race against human edits, a failure **before** any write, or a
  **listing/search cap hit** (the `--limit 200` window filled, so truncated issues are
  invisible this tick — repeated hits mean it is time to narrow scope with `.loop/repos`;
  a `repo` of `*` means the account-wide search). The script did **not** touch it —
  **do not touch it either**; copy it verbatim into ④ Report's warns.
- `note` — an informational line the script did **not** touch (a `needs-human` with no reason
  label on a deploy-wait issue, or a deploy-wait issue's `hold:ladder` (#217, not a resume/
  escalation target even once the window passes) — a **normal state** with nothing to act
  on). It is not a warn, so it does not go into ④ Report's warns — if it is worth reporting at all,
  carry it as an info line only. Narrowing `warn` to "an invariant violation the loop can
  correct" and demoting everything else to `note` is the contract #188/#190 set.
- `warn_after_edit` — a side failure **after** a write was already applied (label-release
  failure · escalate/resume readback lookup failure or mismatch · **linked-PR mirror label
  release failure**, whose message names `PR #<number>`). The
  resume/escalation itself may have happened, so do not revert; copy it into ④ Report's warns
  tagged `(edit applied)` — next tick's loop-status shows the actual label state.
- `policy_review_due` — an issue parked with `hold:policy` for longer than `RESUME_AFTER_MIN` that
  has not been re-reviewed yet (#155). **The dispatcher judges it once**: re-read the one-line
  question in the issue's `<!-- hold-note: policy -->` comment; if the answer can be found in the
  plan (`Plans/*.md`), the issue body, or the verification ladder, **the loop answers** — leave the
  answer as a comment (`재심: <answer> <!-- policy-review: resumed --><!-- bodat:worker -->`) and
  resume with `$SCRIPTS/transition.sh verify-redispatch <repo> <issue> <pr|->` (clears
  needs-human/hold:*, keeps agent-ready → a ③ candidate this tick). If it truly is a human
  decision, leave only `재심: 사람 몫 유지 — <one-line reason> <!-- policy-review: kept --><!-- bodat:worker -->`.
  Either way a marker remains, so **the same issue is never asked twice** (until a human removes
  the label). Report it in ④ as `re-reviewed N (resumed n · kept m)`.
- `waiting` — still inside the window. Pass over it quietly (no reporting needed).
- exit 2 — a listing failed for some repos (the rest were processed normally), or the
  account-wide search failed. Leave one warn line `resume-sweep 부분 실패(레포 조회)` in
  ④ Report.
- exit 64 — `RESUME_AFTER_MIN` / `LADDER_RESUME_LIMIT` is not an integer (it stops before any
  write). The sweep does not run at all until the constant is fixed, so raise it as a warn.

## ② Maintain — finish what you started first

For each `pr_open` event:

**Circuit breaker — common to every maintenance dispatch in 1–3 below**:
read the `<!-- repair-count: N -->` HTML comment from the PR body
(`gh pr view <pr> --repo <repo> --json body`; if the comment is absent, N = 0).
If N ≥ `MAX_REPAIRS_PER_PR`, **do not dispatch a repair** — attach the
`needs-human` + `hold:policy` labels to the PR and the issue with
`$SCRIPTS/transition.sh runner-held <repo> <num> <pr> --reason policy --note "<one-line question>"` and surface it as a
warn in ④ Report (a reason-less `needs-human` is never produced, #151). If N is below the cap, dispatch the maintenance agent and at
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
      leaves one winner and atomicity holds on the stale-takeover path too. If the
      taking-over worker also dies without committing, that anchor is wedged — only
      then does a human clear it: list with `gh api
      repos/<repo>/git/matching-refs/issue-runner/claim/<num> -q '.[].ref'` and delete
      via `gh api -X DELETE repos/<repo>/git/refs/<ref minus the leading refs/>`.
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
      Instead of a codex verifier, the worker **nests one self-review pre-reviewer
      (`general-purpose`) before opening its PR** (template step 9-b — non-gating, fail-open,
      one round; outcome recorded in the PR body's `## Pre-review` section). Nothing for the
      dispatcher to do — the worker waits on the reviewer with a blocking `TaskOutput`, so the
      stream count is +1 only for that window and `MAX_AGENTS` stays as is. Copy the worker exit
      report's `pre-review: <value>` line into ④ Report (absence is a line too) — measure the
      effect by verify-runner bounces (`재검증 실패:` comments) / the share of reviews that
      actually ran (CLEAN or findings).
      **If the issue was resumed, inline two more things in the prompt.** If any **comment**
      carries the marker `<!-- ladder-resume: N -->`, the issue was revived by ①'s resume
      sweep, and the number of such comments is which resume this is (the body has no marker —
      the sweep never touches it):
      (quoted markers do not count — a marker inside inline backticks or a code fence is not
      the signal but prose *about* the signal, so it is stripped first, with the **same
      definition** as `JQ_UNQUOTE` in `resume-sweep.sh`. If the two drift apart, a second
      invisible counter counts a different number — #197)

      ````sh
      gh issue view <num> --repo <repo> --json comments --jq 'def unquoted: gsub("\\r\\n"; "\n") | gsub("(^|\\n) {0,3}(?<f>```+)[^`\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<f>`*[ \\t]*(?=\\n|$)|$)|(^|\\n) {0,3}(?<t>~~~+)[^\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<t>~*[ \\t]*(?=\\n|$)|$)"; " ") | gsub("(?<!`)(?<r>`+)(?!`)([^\\n]*?)(?<!`)\\k<r>(?!`)"; " "); [.comments[] | select(.body|unquoted|test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))] | length'
      ````

      After the filled template, append ⓐ the ladder document's path
      `~/.claude/skills/issue-runner/references/live-verification-ladder.md` (where the
      worker reads which rung is climbed with which command) and ⓑ **the previous attempt's
      failure output** — the body of the issue's last ladder-related comment:
      `gh issue view <num> --repo <repo> --json comments --jq '[.comments[] | select((.body|test("사다리|ladder")) and ((.body|test("^재개 "))|not))] | last.body // ""'`
      (exclude the sweep's own `재개 N/…` comment — it is the most recent one, so without the
      filter you would hand the worker that line instead of the failure output). Then state
      in one line: **"Do not repeat the same failure on the same rung — start from the next
      rung (this is resume N). If you still cannot climb it, stop with `BLOCKED:` quoting the
      rung you tried and its failure output"** — deferring without a quote is not allowed.

## ④ Report

One-line summary: `reconciled N · maintained N · new N · resumed N · escalated N · waiting(human review) N · warn N`
(`resumed`/`escalated` are the counts of ①'s resume-sweep `resumed`/`escalated` events).
Below it, **name the numbers item by item** — counts alone do not tell the next tick where
each issue/PR went:
`reconciled: #4801(bodat, PR #4810 merged) · maintained: PR #4812(bodat, rebase) · new: #4818(bodat) · resumed: #4772(bodat, 2/2) · escalated: #4803(bodat, hold:policy) · warn: #4799(bodat) dirty worktree`.
The repo short-name rule is the same as `loop-status.sh`'s (the repo part of `owner/repo`
lowercased — bodat·bodac; `issue-runner` alone maps to `runner`).
If there are warns, list the paths and reasons below it.
**Token observation (soft budget)**: if any worker delivered a completion report, add
one line per issue — `tokens: <repo>#<num> <this report's count> (cumulative <sum>)`.
Also copy that worker report's `pre-review: <value>` as one line `pre-review: <repo>#<num> <value>` (no line → `none` — the signal that 9-b silently dropped out). This count is subagent_tokens from the completion notification (absent → `?`, counted as 0);
cumulative = the same issue's `tokens:` figures from previous tick Reports visible in
context + this count (none visible → just this count). If it exceeds `SOFT_TOKEN_BUDGET_PER_ISSUE`,
state **"soft budget exceeded — recommend escalating to needs-human"** on that line (report only — never auto-label or stop workers).
If every count is 0, output the single line "quiet".

**Pipeline snapshot (required every tick).** After the lines above, run
`$SCRIPTS/loop-status.sh --post issue-runner --delta "<this tick's one-line summary>"` (it also overwrites the per-repo pinned dashboard issue `루프 현황` — label `loop-dashboard` — so GitHub alone shows who holds what and when each loop last ticked, #163) and paste its output **verbatim** — the counters only say "what
this tick did"; what is piled up is visible only in this block. Call it with no `cd` (the
scope auto-applies from the loop session cwd's `.loop/repos`). **Paste it even on a quiet
tick where every count is 0** — the snapshot is the only window onto what is idling.
- On exit 1 (partial failure — some repos failed to query), paste the output as-is and add
  one warn line `loop-status 부분 실패`.
- On exit 64 (no scope — an account-wide session with no `.loop/repos`), call it once more
  naming the repos touched this tick with `--repo <owner/repo>`; if there are none, leave one
  warn line `loop-status: 스코프 없음(.loop/repos 부재)`.
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
