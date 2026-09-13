---
name: issue-runner
description: Autonomous dispatcher that picks up agent-ready issues across your entire GitHub account, implements them in worktrees, and opens PRs. Use with /loop (e.g. /loop 5m /issue-runner). Each tick performs Reconcile → Maintain → Dispatch → Report. Never merges.
---

> English translation of [SKILL.md](SKILL.md). The Korean original is the source of
> truth — when the two diverge, follow SKILL.md and update this file to match.
> To run the dispatcher in English, replace SKILL.md with this file's contents.

# issue-runner — issue dispatcher tick

You are an unattended dispatcher. Perform the four phases below **in order**. Do not
reorder the phases (cleanup must come first so the slot count is accurate, and
maintenance must come before new work).

> **The SSOT for ownership, holds and failed transitions is `references/state-machine.md`** (#393). Which loop owns
> which state (owner labels `flow:verify`·`verifying`·`flow:ready`·`harvesting`), how machine holds (`hold:*`) and human
> holds (`needs-human`) clear, and who recovers a half-moved state after `transition.sh` exits 1·2 — read that table;
> where prose below restates a rule, the table wins.
>
> **The SSOT for the conventions all three loops share is `references/loop-conventions.md`** (#452, Korean only).
> What fail-closed means (§1) · the warn·note·blocked channel boundary (§2) · relaying script stderr into ④ Report
> (§3) · the sentinel marker (§4) · the dedicated `Closes #N` line (§5) · repo short names (§6) · the pipeline
> snapshot discipline (§7) · the missing-label fallback (§8) · verification-ladder rungs (§9) · the surface-correction
> criterion (§10) — the prose below points at those sections instead of restating them.
>
> **Why each rule exists (history, field measurements, rejected alternatives) lives in
> `references/issue-runner-rationale.md`** (#454, Korean only). The `(rationale §N)` markers below point at its
> sections — a tick never needs to read that file.

## Constants

Only the knobs the LLM judges with. The measurement history behind the values is rationale §1·§2.

- `MAX_AGENTS = 4` — cap on concurrently in-flight issues (in-flight is defined in ③-1 — PRs waiting for human
  review do not occupy a slot). Lower to 2 if it is still slow. **Never raise it above 4 without measuring** —
  the real ceiling is machine load, not the API (rationale §1).
- `MAX_OPEN_PRS = 14` — **per-repo** cap on open PRs. When a repo reaches it, only new dispatches for that repo
  stop (maintenance continues, other repos dispatch normally) — backpressure that prevents rebase conflicts from
  multiplying across PRs while human merges lag (rationale §1).
- `MAX_REPAIRS_PER_PR = 3` — cap on maintenance dispatches per PR (② Maintain circuit breaker)
- **Constants the scripts read — the values live in `scripts/lib/constants.sh`, in one place** (#427). This section
  does not restate them: names and meanings only. For a value, run `grep '<name>' $SCRIPTS/lib/constants.sh`
  (rationale §2).
  - `ISSUE_TIMEBOX_HOURS` — the claim age at which a `working` issue with no PR **starts being asked for progress
    evidence** (① Reconcile timebox). Exceeding it is **not by itself a reason to stop** — past this age the issue
    is still reprieved as long as there is progress evidence (#200).
  - `STALL_MIN` — the "no progress" threshold (minutes). `timebox-check.sh` decides commit-side evidence freshness.
  - `MAX_TIMEBOX_GRACE` — cap on **cumulative reprieves** within the same claim. The count is not a state file: it
    is re-derived by counting issue comment markers (`<!-- timebox-grace: N -->`) created **after the current claim
    timestamp only**.
  - `RESUME_AFTER_MIN` — how long (minutes) the resume sweep waits before letting a stalled issue flow again.
  - `LADDER_RESUME_LIMIT` — cap on automatic resumes per issue. Beyond it the issue is escalated to `hold:policy`
    instead of resumed (no infinite retries).
  - `CONFLICT_RESUME_LIMIT` — cap on automatic resumes of `hold:conflict` (#345). The window is the shared
    `RESUME_AFTER_MIN`. Beyond the cap: `hold:policy` escalation → the re-review (③) question is "ⓑ takeover, or
    reissue?".
  - `MIRROR_RETRY_LIMIT` — cap on retries of ①'s resume-sweep **stop-mirror cleanup** (#397). The round count is
    the number of `<!-- mirror-retry: <reason> pr=<n> -->` marker comments on the paired issue (what is in scope is
    rationale §2) — at the cap the script emits `mirror_retry_exhausted`.
  - `STALE_FINISH_MIN` — lost-finish time buffer (minutes). Consumed by the **closeout ①-b stuck-PR sweep**
    (`finish-classify.sh`; issue-runner no longer uses it directly).
- `SOFT_TOKEN_BUDGET_PER_ISSUE = 300000` — soft token budget per issue. Not a hard cap but the observation
  threshold for ④ Report.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — verifier subagent type for reviews and lesson extraction. **Output contract
  (SSOT — everywhere else refers to this entry)**: review calls are read-only (no code changes), classify each
  finding as BLOCKER/WARN/NIT, output 'CLEAN' if there are no findings, and BLOCKERs are a gate (no finishing
  before they are resolved); lesson-extraction calls (① Reconcile) output 'one lesson line or NONE'. The verifier
  does not read SKILL.md, so the call's prompt string must carry this contract verbatim — the prompt is the only
  delivery path. **Fallback**: in environments without the codex plugin (the type above is missing from the Agent
  tool's subagent_type list, or the call fails with an unknown subagent type error), use `general-purpose` as the
  verifier — it is invoked with the same prompt, so the same contract applies.
- Absolutely forbidden: merging PRs, pushing directly to main, touching human-created branches, attaching the
  agent-ready label on your own, appending the final `Merge verdict: ✅` on behalf of a lost-finish PR (that
  recovery is owned by the closeout ①-b sweep). **Allowed**: the ② Maintain rule-0 flow-label (`flow:*`)
  correction (rationale §2).

## ① Reconcile

Run `$SCRIPTS/reconcile.sh` and handle each event:

- `merged` — the PR merged. ★**This does not mean the issue closed**★ (#117, rationale §3).
  **Orphan-worker cleanup (first)**: if this issue's worker is still alive (check TaskList for the
  `implement <repo>#<num>` background agent), stop it with `TaskStop`. Then the **Lessons step**: if any of the
  failure signals below is present (all checked via `gh pr view <pr> --repo <repo>`), synchronously invoke the
  `VERIFIER` subagent (following the VERIFIER contract and fallback in ## Constants). If no signal is present, do
  not invoke it and leave it NONE (record no lesson): (1) a CHANGES_REQUESTED review (`--json reviews`) ·
  (2) a `gh run list` CI failure (GitHub Actions repos) · (3) a **local-ci commit status failure history** — if
  any of the PR's commits had the local-ci context as FAILURE (enumerate commit SHAs via `--json commits` and
  query each SHA via `gh api repos/<repo>/commits/<sha>/statuses` — do not use the HEAD's `--json
  statusCheckRollup`, rationale §4) · (4) a **BLOCKER in a verifier review comment** — if the PR's
  `마감 검증:`·`검증자 리뷰:` comment had a BLOCKER (`--json comments`).

  ⚠️ **A rebase voids signal (3) — never trust "no failure history" as a verdict** (rationale §4).
  Detect it with `gh api repos/<repo>/issues/<pr>/timeline --jq '[.[]|select(.event=="head_ref_force_pushed")]|length'`:
  greater than 0 means the commit enumeration is incomplete. Then — ⓐ if context (the worker's completion report,
  or a previous tick's Report `run-local-ci` result) still holds the **pre-rebase SHA**, query that SHA directly
  with `gh api repos/<repo>/commits/<sha>/statuses` and decide. ⓑ If you do not know the pre-rebase SHA, treat (3)
  as unknown, decide on signals 1·2·4 alone, and leave one line **"failure history undecidable after rebase"** in
  ④ Report. Never pass it off silently as "none".
  (If the same lesson already exists in `lessons.md`, do not append a duplicate; write "same as an existing
  lesson — not recorded" in Report instead.)

  > "Read the review comments and CI failure logs of PR #<pr> (<repo>), and from
  > the objective failure facts produce exactly one recurrence-prevention lesson
  > line in the form 'When <situation>, do <specific action>'. No speculation or
  > generalities. If there are no failure facts, output 'NONE'."

  If the result is not NONE, append one line `- [YYYY-MM-DD PR#<pr>] <lesson>` to the `.loop/lessons.md` under the
  path output by `$SCRIPTS/repo-dir.sh <repo>` (= `<repo-dir>/.loop/lessons.md`), then trim to the cap —
  **call `$SCRIPTS/lessons-trim.sh append <file> 20 "<line>"` in one place** (it creates the file if absent).
  **Do not append by hand outside this call** (#208, rationale §5). **Cap: 20 entries** — on overflow, drop the
  oldest entries **until the entry count is at or below the cap**. Only a human moves lessons into CLAUDE.md.
  **Routing — `lessons.md` is for implementation lessons only** (③-4d loads it verbatim into the worker prompt).
  If the lesson is about **verification judgment** (what the verifier misread · how a false BLOCKER was overturned ·
  the BLOCKER vs WARN boundary), do not write it here — append it to **`.loop/lessons-verifier.md`** in the same
  directory, **through the same call**: `$SCRIPTS/lessons-trim.sh append <file> 20 "<line>"` (rationale §5).
- `rejected` — a human rejected the PR. **If a worker is still alive, stop it first with `TaskStop` the same as
  `merged`** (orphan prevention). Perform the lessons step the same way. Do not re-dispatch the issue
  (agent-ready has already been removed).
- `stale` — a dead claim was released. Report only.
- `warn` — dirty/unpushed worktree. **Do not touch it** — surface it as-is in Report so a human sees it.
- `half_moved_redispatch` — a PR whose `verify-redispatch` **half-failed** (#394, rationale §6).
  **Re-run the same transition idempotently**: `$SCRIPTS/transition.sh verify-redispatch <repo> <issue> <pr>`
  (the PR side is a no-op; only the issue returns to `agent-ready` → a ③ candidate this tick). On success add
  `#<num>(반쯤 이동 회수)` to `보수` in ④ Report. If the transition exits non-zero, act per
  `references/state-machine.md` 「전이 실패의 공통 규칙」 (the common rule for failed transitions) — report
  `BLOCKED: transition failed verify-redispatch PR #<pr>(<repo_short>) — <one stderr line>` and move on (the rule
  is not restated here). A PR with this event is **not** ② Maintain input. Do not re-judge freshness here.
- `pr_open` — input to ② Maintain.
- `working` — a worker is in progress. Use TaskList to check whether that background agent is actually alive.
  **Do not assume "looks dead" (the task has ended in TaskList) means actually dead** — first read the task's last
  message with `TaskOutput(task_id)`. If its last line reads
  `CI 대기 중 — <SHA 40자> <queued N|running|none>, 다음 할 일: <한 줄>`
  (the signal is a verbatim Korean literal), the worker only ended its turn while waiting in the
  `run-local-ci.sh` queue — it is not dead (#185). **Do not remove the worktree or release the claim** — wake the
  worker with `SendMessage` to that task, telling it to resume (pick up the "다음 할 일" / next step it reported).
  Once resumed, record it in ④ Report's `maintained` line as `#<num>(resumed from CI wait)` — and **once the
  resume succeeds, this issue is finished for this tick: do not run the genuine-death path below, and do not run
  the timebox cleanup at its end; move on to the next event** (in code terms, `continue` here).
  **The state token is one of `queued N`, `running`, `none` — all three states are resume signals.** Whichever one
  arrives, resume exactly as above; **in all three cases** do not remove the worktree and do not release the claim.
  What the three tokens mean, and the evidence that a background subagent whose turn has ended is still resumable
  with `SendMessage`, is rationale §7. If the message is not in that format (a genuine death), continue below.
  **Fallback — if the resume message also gets no response** (the rare case where the task really is gone), do not
  release the claim: **dispatch a replacement worker reusing the existing worktree and branch**. **Do not create a
  new claim and do not open a new PR** (if a PR is already open, have it continue that one). Only if this fallback
  also fails do you fall through to the genuine-death path below.
  If it is dead and there are pushed commits, treat it as a maintenance target for ②. If there are no commits at
  all, check the issue's latest comment **before** releasing the claim —
  `gh issue view <num> --repo <repo> --json comments --jq '[.comments[] | select((.body | test("<!--\\s*timebox-grace:")) | not)] | last.body'`
  (timebox reprieve markers are skipped — rationale §7). If it starts with `BLOCKED:`, the worker stopped because
  human intervention is needed (ambiguous spec / plan-reality mismatch / same failure repeating): instead of
  returning the issue to a re-dispatchable state, attach the `hold:policy` label with
  `$SCRIPTS/transition.sh runner-held <repo> <num> <pr|-> --reason policy --note "<the one-line question a human must answer>"`
  (this also releases the claim — a machine stop carries the reason label only, #244), remove the worktree, and
  surface the BLOCKED reason as a warn in ④ Report (rationale §7). If the latest comment is not a BLOCKED comment,
  remove the worktree and release the claim (returning the issue to a re-dispatchable state).
  **Timebox (no-progress detection)** — **an issue resumed via `SendMessage` in this tick is exempt.** For an
  issue you did not resume, check whether it is **making progress** even if it is alive — the decision input is
  progress evidence, not elapsed time (#200, rationale §8). Get the claim timestamp with
  `gh api repos/<repo>/issues/<num>/timeline --jq '[.[] | select(.event=="labeled" and .label.name=="agent:claimed")] | last.created_at'`
  (if the response is empty, fall back to the worktree directory's creation time) and hand it to
  `$SCRIPTS/timebox-check.sh <repo> <num> --claim-at <ISO8601>` (`working` by definition means there is no PR).
  The verdict is one line — `<verdict> <reason> elapsed=..m commit=..m queue=.. grace=n/max`:
  - `ok` (exit 0) — the claim age is still within `ISSUE_TIMEBOX_HOURS`. Leave it alone.
  - `grace` (exit 0) — past the age but there is progress evidence (`recent_commit`·`ci_queued`). **Do not stop it
    this tick.** The helper appends a reprieve marker to the issue, so the next tick counts those markers against
    `MAX_TIMEBOX_GRACE`. Put the verdict line as-is into ④ Report as an **info line, not a warn**.
  - `stop` (exit 1) — no progress (`no_progress`) or the reprieve cap is spent (`grace_exhausted`). Do ⓐ–ⓓ below
    as written.
  - `unknown` (exit 2) — a decision input could not be obtained (claim timestamp, branch lookup, comment lookup,
    or the reprieve-marker append failed). **Do not stop it** — surface it as a warn in ④ Report (rationale §8).

  Only when the verdict is `stop`: ⓐ stop the worker with TaskStop, ⓑ remove the worktree —
  `git -C <repo-dir> worktree remove --force <wt>` then `git -C <repo-dir> branch -D agent/issue-<num>`
  (unpushed leftovers are **deliberately discarded** as the price of the `stop` verdict, rationale §8),
  ⓒ release the claim with `gh issue edit <num> --repo <repo> --remove-label "agent:claimed"`, and ⓓ surface it as
  a warn in ④ Report.

**Resume sweep — a stalled issue is retried by the tick.** After handling every event above, run
`$SCRIPTS/resume-sweep.sh` with no arguments (the script applies the loop session cwd's `.loop/repos` scope on its
own). Run it **before ③ Dispatch** so this same tick can pick the issue up. Of the machine stops (`hold:*`), the
sweep reverts **`hold:ladder`** and **`hold:conflict`** (#345) once the window (`RESUME_AFTER_MIN`) passes (the
resume count is the number of issue **comments** carrying `<!-- ladder-resume: N -->` / `<!-- conflict-resume: N -->`
— each branch counts only its own marker), reverts the mirrored labels on the linked open PR too (#420), and also
runs the **stop-mirror cleanup** (#265) for a PR whose hold was cleared on the issue alone. Only `hold:policy`
stays a human decision, after one re-review (③). A coexisting `needs-human`, and a `hold:conflict` carrying
`full-cycle`, are never auto-resumed (#244·#345). The sweep's own evidence discipline (positive evidence · never
stripping a bare `needs-human`) belongs to the script (rationale §9·§10). Per event:

- `mirror_cleared` — the script removed the **PR copy** of a hold a human cleared on the issue alone (#265). The
  issue was already clean, so it is left untouched. **Nothing further to do** — that PR returns as a
  `verify-eligible.sh`/`closeout-eligible.sh` candidate from this tick on. Put one line under `mirror cleared N`
  in ④ Report (`pr` is the PR, `number` the linked issue, `removed` the labels taken off).
- `mirror_retry_exhausted` — the stop-mirror cleanup hit `MIRROR_RETRY_LIMIT` rounds **without ever obtaining
  positive evidence** (#397 — read `attempts`/`limit` as `3/3`). **Escalate it to a human here**:
  `$SCRIPTS/transition.sh runner-held <repo> <number> <pr> --reason policy --note "미러 불일치 증거 부재 <attempts>회 — PR 과 이슈의 정지 라벨이 어긋난다"`
  (attaches `hold:policy` plus the question comment on both the issue and the PR). If the transition exits
  non-zero, act per `references/state-machine.md` 「전이 실패의 공통 규칙」 — leave one line
  `BLOCKED: transition failed runner-held #<number>(exit N)` in ④ Report; the next tick re-emits the same event.
  Report one warn line `미러 상한 #<pr>` in ④ (rationale §10).
- `resumed` — the hold (`reason` field: `ladder` → `hold:ladder`, `conflict` → `hold:conflict`, #345) is off and
  `agent-ready` is untouched. **Nothing for the dispatcher to do** — the issue reappears naturally as an
  `eligible-issues.sh` candidate in ③ this tick (for a conflict resume, the "If the issue was resumed" item in ③
  inlines the hold note and the rebase instruction). Record the number with `reason` and `attempt` under `resumed`
  in ④ Report, as `resumed #N(conflict 1/1)`. An issue carrying the deploy-wait label goes to `note` below instead
  of this event (#217).
- `escalated` — the resume cap (`LADDER_RESUME_LIMIT` when `reason` is `ladder`, `CONFLICT_RESUME_LIMIT` when
  `conflict`) was exceeded, so the issue was escalated to `hold:policy` (`attempt`/`limit` are the resumes spent
  vs. the cap — read as `2/2` / `1/1`). The script already applied the label, so with **no further action** list it
  under `escalated` in ④ Report with the reason (`escalated #N(conflict, hold:policy)`) for a human to see.
  **PR axis** (`number` is `null` and `pr` is set, #345 bounce) is also **no further action**
  (`attempt`/`limit` read `0/0`) — write `escalated PR #N(conflict, hold:policy)` in ④ Report (rationale §10).
- `warn` — another stop coexisting with the hold (`needs-human` or another `hold:*`; a `needs-human` next to
  `hold:conflict` is a `note` instead) · a race against human edits · a failure **before** any write · a
  **listing/search cap hit** (`--limit 200`). The script did **not** touch it — **do not touch it either**; copy
  it verbatim into ④ Report's warns (rationale §10).
- `note` — an informational line the script did **not** touch (a `needs-human` with no reason label; the same on a
  deploy-wait issue; a deploy-wait issue's `hold:ladder` (#217); or a `hold:conflict` a human took over
  (`full-cycle`) or parked with `needs-human` (#345) — a **normal state** with nothing to act on). It is not a
  warn, so it does not go into ④ Report's warns — if it is worth reporting at all, carry it as an info line only.
  The boundary between the three channels is per `references/loop-conventions.md` §2.
- `warn_after_edit` — a side failure **after** a write was already applied (label-release failure · escalate/resume
  readback lookup failure or mismatch · **linked-PR mirror label release failure**, whose message names
  `PR #<number>`). The resume/escalation itself may have happened, so do not revert; copy it into ④ Report's warns
  tagged `(edit applied)`.
- `policy_review_due` — an issue parked with `hold:policy` for longer than `RESUME_AFTER_MIN` that
  has not been re-reviewed yet (#155). **The dispatcher judges it once**: re-read the one-line
  question in the issue's `<!-- hold-note: policy -->` comment; if the answer can be found in the
  plan (`Plans/*.md`), the issue body, or the verification ladder, **the loop answers** — leave the
  answer as a comment (`재심: <answer> <!-- policy-review: resumed --><!-- bodat:worker -->`) and
  resume with `$SCRIPTS/transition.sh verify-redispatch <repo> <issue> <pr|->` (clears
  needs-human/hold:*, keeps agent-ready → a ③ candidate this tick). If it truly is a human
  decision, **the transition comes first** — run
  `$SCRIPTS/transition.sh policy-kept <repo> <issue> <pr|->` to attach `needs-human` to the PR
  and the issue (#244 — the only place the loop attaches it; `hold:policy` stays as the reason),
  and **only after that transition ends with exit 0 `ok`** leave
  `재심: 사람 몫 유지 — <one-line reason> <!-- policy-review: kept --><!-- bodat:worker -->`.
  **The order is the contract** (#244, rationale §11).
  If the transition exits non-zero, **do not post the marker comment**; leave one line
  `BLOCKED: 전이 실패 policy-kept #<issue>(exit N)` in ④ Report instead. What each exit code means and what to do
  about it lives in `references/state-machine.md` 「전이 실패의 공통 규칙」 — not restated here.
  The one thing specific to this spot is the **marker disposition**: on exit 0 post the marker,
  on non-zero do not (the next sweep re-emits the re-review). **Only an issue whose
  marker remains** is **never asked twice** (until a human removes the label). Report it in ④ as
  `re-reviewed N (resumed n · kept m)`.
  **A PR-only hold always ends as "kept human"** (#395 → #421). The event's `pr` field splits the
  axes: a filled `pr` with `number` = `null` is the `hold:policy` of a **PR with no open linked
  issue**. The question (`<!-- hold-note: policy -->`) lives on that PR, so read it there — but
  **do not resume, even when the plan answers it** (rationale §12). So this axis has exactly one disposition: run
  `$SCRIPTS/transition.sh policy-kept <repo> - <pr>` (the issue argument of the transition is `-`)
  and **only after it ends with exit 0 `ok`** leave `재심: 사람 몫 유지 — 연결 이슈 없음 — 사람이
  이슈를 연결하거나 PR 을 닫는다 <!-- policy-review: kept --><!-- bodat:worker -->` on **that PR**
  via `gh pr comment <pr>` (order, marker and non-zero disposition are letter-for-letter the same
  as above — on non-zero post no marker and leave `BLOCKED: 전이 실패 policy-kept #<PR>(exit N)`).
  Count it in ④ Report's `kept m`.
- `waiting` — still inside the window. Pass over it quietly (no reporting needed).
- exit 2 — a listing failed for some repos (the rest were processed normally), or the account-wide search failed.
  Leave one warn line `resume-sweep 부분 실패(레포 조회)` in ④ Report.
- exit 64 — `RESUME_AFTER_MIN` / `LADDER_RESUME_LIMIT` / `CONFLICT_RESUME_LIMIT` is not an integer (it stops before
  any write). The sweep does not run at all until the constant is fixed, so raise it as a warn.

## ② Maintain — finish what you started first

For each `pr_open` event:

**0. Flow-label correction (best-effort, applied while scanning).** One line decides it:
`$SCRIPTS/pr-state.sh <repo> <pr>` (#449) — it reads the three axes (PR labels, linked-issue
labels, last verdict comment) and returns the row name from `references/state-machine.md` as
`{state, owner, mismatch}`. This prose no longer restates that table.
**When `mismatch` is non-empty, the loop that owns the row fixes it with a transition** — and
**only the `verdict:` axis is this loop's share** (the safety net for legacy PRs opened without a
mirror label). That item reads `verdict: pr=<row> target=<label>` and **hands you the label to
attach** (the verdict-symbol → label mapping lives in the script alone — do not restate it here):
`gh issue edit <pr> --repo <repo> --add-label <the item's target> --remove-label <the other flow:*>`
(idempotent — skip when equal; `--remove-label` is harmless on a missing label). **Leave the other
axes alone** (`rung`·`stage`·`stop`) and raise one warn line in ④ Report,
`mismatch PR #<pr>(<repo_short>) — <item>`: the `owner` field names who owns that row
(verify-runner / closeout / resume-sweep / a human).
Where the script does **not** emit a `verdict:` axis is exactly the old skip list —
PRs labeled `flow:verify`, `verifying`, `harvesting`, `flow:claimed` or `flow:agent-ready`
(#275·#420), plus the stop (H:*) and terminal (E) rows.
**On exit 2 (lookup failed) skip this PR's correction** — never guess the state.
(Why those lanes are skipped: rationale §13.)

**Circuit breaker — common to every maintenance dispatch in 1–3 below**:
read the attempt count with `N=$($SCRIPTS/attempt-counter.sh <repo> <pr> repair-count)`
(`0` when the marker is absent; **exit 2 = lookup failed → skip this PR's repair for
this tick**, since reading it as 0 would reset the cap, #444).
If N ≥ `MAX_REPAIRS_PER_PR`, **do not dispatch a repair** — attach the `hold:policy` label to the PR and the issue
with `$SCRIPTS/transition.sh runner-held <repo> <num> <pr> --reason policy --note "<one-line question>"` and
surface it as a warn in ④ Report (a machine stop carries the reason label only, #244). If N is below the cap,
dispatch the maintenance agent and at the same time bump the counter with
`$SCRIPTS/attempt-counter.sh <repo> <pr> repair-count --bump` (the script rewrites the marker, appends it at the
end when absent, and leaves the rest of the body untouched. **On exit 2 the count did not go up** — skip that
dispatch and leave one warn line in ④ Report). Even when several of the causes 1–3 apply to the same PR, dispatch
**one maintenance agent per PR per tick** — merge all repair instructions into that single agent's prompt, and
increment N by exactly 1 per dispatch.

1. `failing > 0` → inspect the failure logs (gh run view --log-failed); if it looks like a flake, re-run
   (gh run rerun); if it is a real failure, dispatch a **maintenance agent** in the background using the worker
   template file `~/.claude/skills/issue-runner/references/worker-template.en.md` (read and filled the same way as
   ③-4d; if the worktree is gone, `$SCRIPTS/make-worktree.sh` recreates it on top of the remote branch). Replace
   the template's "Procedure" with the concrete repair instructions, but keep everything else (compound commands,
   push discipline, prohibitions).
2. Unresolved review comments → in the same way, instruct a maintenance agent to resolve the comments. However,
   status comments left by the worker itself (starting with `Merge verdict:`/`머지 판정:` or
   `Verifier review:`/`검증자 리뷰:`) are not review comments — do not count them as repair triggers.
3. Conflict with base → **no longer rebase here** — conflict-rebase ownership was transferred to closeout
   (closeout ③ step 2 rebases and merges directly after taking the `harvesting` occupation). issue-runner leaves
   conflict PRs untouched and defers to the next closeout tick. Still count them as in-flight since they are
   unfinished (③ backpressure stays).
4. CI green + no unresolved review comments → **leave it alone.** Either it is waiting for human review, or the
   worker died before writing the final `Merge verdict: ✅` (**lost finish**). Lost-finish recovery is owned by the
   **closeout ①-b stuck-PR sweep** (which consumes `finish-classify.sh`). issue-runner does **not** append final
   verdicts on behalf of lost-finish PRs or re-dispatch completion agents. Only the flow-label correction (rule 0)
   is kept (rationale §13).

A `harvesting` event = closeout is in progress → **leave it alone** (no repair, rebase, or review-comment resolution). closeout merges/cleans it up.

## ③ Dispatch — only as many as there are free slots

1. Compute in-flight: the count of ①'s `working` + whatever this tick sent into ② + **red PRs** (`pr_open` with
   failing CI or unresolved review comments = targets of ② 1–2; plus conflicts = closeout's transferred
   responsibility but still counted as backpressure since unfinished). **PRs that are CI green with no comments
   (② 4, waiting for human review) do not occupy a slot.** **`flow:verify`/`verifying` PRs do not occupy a slot
   either** — they are verify-runner's, so they are excluded from in-flight (rationale §14).
   `slots = MAX_AGENTS - in-flight`. If slots ≤ 0, skip this phase.
   **Backlog backpressure — judged per repo** (#362): count open PRs (regardless of state) for each repo in scope —
   `for r in <scope repos>: gh pr list --repo $r --state open --limit 100 --json number --jq length`.
   A repo at or above `MAX_OPEN_PRS` has **only its own issues** skipped among the ③-2 candidates; candidates from
   repos under the cap dispatch normally. For each repo at the cap raise one `머지 대기 적체 <repo> N개`
   ("merge backlog <repo> N") warn line in ④ Report (`<repo>` is ④'s repo short name — runner·bodat; repos under
   the cap are not listed. Maintenance keeps running in ②).
2. Run `$SCRIPTS/eligible-issues.sh` → priority-sorted candidates (**stdout**).
   **Carry its stderr `blocked:` / `blocked-summary:` / `warn:` lines into ④ Report** (#247) —
   which channel goes where, and why, is per `references/loop-conventions.md` §3.
3. **LLM judgment (only toward picking less)**: if two or more candidates look like they will touch the same repo
   and the same module, pick only one this tick. If you cannot tell, pick it (a conflict gets resolved by the next
   tick's rebase).
   This deferral touches no labels — the deferred issue comes back to the next
   tick's ③-2 as-is, and ④ Report records it as `미룸: #N(<repo>, 같은 모듈 #M)` ("deferred").
   **Never park a candidate because of a label (#493).** A candidate on the stdout of
   `eligible-issues.sh` has already passed the gate the script decides (`open + agent-ready +
   ¬agent:claimed + ¬needs-human + ¬hold:* + every blocker CLOSED`) — no other label is a
   gate, and the session must not read a label and bolt on its own "hold/skip". In
   particular **`needs:hardware` is not a parking reason** — it classifies the issue as
   "hardware is involved", it is not an eligibility gate, and it means "walk the hardware
   path the issue body describes". That procedure is the worker's job and is already in the
   worker prompt: worker template step 11-a sends the worker up the issue body's path section
   (`ssh <worker>` direct · measurement commands · escape hatch) and the rungs of
   `references/live-verification-ladder.md`, and when there is no path or it does not work
   the worker quotes the rungs it tried plus the failure output in the PR `## Test plan`, leaves
   that item `[ ]`, and hands off to verify-runner via 11-b (it does not stop — the worker emits no
   BLOCKED). From there verify-runner ③-2 retries rungs ②③ and only when all fail does it hold with
   `verify-held --reason ladder` → `hold:ladder` (one of `transition.sh`'s three reasons — the reason
   for a failure that climbed the whole ladder; `hold:policy` is for human-decision cases such as a
   worker's `BLOCKED:` exit or a missing linked issue). Measured: on 2026-09-13 ticks
   #188–#190 left slots empty and reported `needs:hardware 관측 의존(스킵)` for 3 ticks in a
   row with 0 new — yet those two issues (BoDAT #5100·#5198) either already had the path
   inlined in the body or had no hardware in their implementation scope (2026-08-26 BoDAT
   #3852 idled 11 hours the same way). Label parking turns `needs:hardware + agent-ready`
   into an indefinite wait, and the dashboard shows it only as `대기`, so "eligible · slot
   free · not picked" is recorded nowhere.
   **Deciding not to pick is a transition, not a skip (#493).** If you decide not to pick a
   candidate for any reason other than the same-module deferral above (spec not settled ·
   duplicate · policy decision needed), do not leave that judgment label-less — right there run
   `$SCRIPTS/transition.sh runner-held <repo> <num> - --reason policy --note "<why not picked + the one-line question a human must answer>"`
   to attach `hold:policy` (this holds as-is for an unclaimed issue with no PR — `-` is the
   official form and removing an absent `agent:claimed` is harmless. The transition leaves the
   reason comment. Never attach
   `needs-human` by hand — #244; `policy-kept` attaches it when the review ends as "stays
   with a human". There is deliberately no `hold:hardware`). From the next tick the gate
   (`¬hold:*`) drops it from the candidates and the review (① `policy_review_due`) answers once —
   the same judgment is not repeated every tick. **Duplicates are the same**: if it duplicates
   another issue or a fix already on main, run the same transition with
   `--note "중복: #<원본> — 닫을지 사람이 판단"` (closing is the human's job — `closeout-dup`
   needs a PR to exist, and there is deliberately no `hold:dup` label). Do not repeat
   "duplicate (skip)" tick after tick (that is how BoDAT #5144 stayed in the waiting line).
   Raise one warn line in ④ Report: `#N(<repo>) 안 집음 → hold:policy — <reason>`.
4. For up to `slots` candidates in priority order:
   a. `$SCRIPTS/claim-issue.sh <repo> <num>` — on failure (already claimed, lost the lock race, etc.) move on to
      the next candidate. Before touching labels the helper takes a create-only lock ref
      (`refs/issue-runner/claim/<num>/<anchor>`) (#108). When a previous attempt died without committing and only
      its lock remains, the helper takes over by creating `<anchor>-takeover`, also create-only. If the
      taking-over worker also dies without committing, that anchor is wedged — only then does a human clear it:
      list with `gh api repos/<repo>/git/matching-refs/issue-runner/claim/<num> -q '.[].ref'` and delete via
      `gh api -X DELETE repos/<repo>/git/refs/<ref minus the leading refs/>` (rationale §14).
   b. `$SCRIPTS/make-worktree.sh <repo> <num>` — the last output line is the worktree path. Secret symlinks
      (`.env`, `config/master.key`) are off by default — they appear only in repos that opt in via `link-secrets`
      in `repos.conf` (#109). In repos without it, credential-dependent tests are reported as **skipped**, not
      failed.
   c. If the `.loop/lessons.md` under the path output by `$SCRIPTS/repo-dir.sh <repo>`
      (= `<repo-dir>/.loop/lessons.md`, same interpretation as the record path) exists, read its contents.
      **Do not read `.loop/lessons-verifier.md`** — it is the verifier's casebook, irrelevant to an implementation
      worker and it only inflates the prompt (see the routing item in ①).
   d. Right before dispatching, read `~/.claude/skills/issue-runner/references/worker-template.en.md`, fill the
      placeholders (`<WT_PATH>` `<REPO>` `<NUM>` `<TITLE>` `<DEFAULT_BRANCH>` `<REPO_DIR>` `<VERIFIER>`
      `<LESSONS_OR_"none">`), and dispatch it (background Agent tool call — the call signature is at the top of the
      template file). Fill `<DEFAULT_BRANCH>` from
      `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name`. Fill `<REPO_DIR>` with the output of
      `$SCRIPTS/repo-dir.sh <repo>` (the main checkout's absolute path) — the worker's codegraph exploration (`-p`)
      reads the index at this path. Fill `<VERIFIER>` from ## Constants with the fallback rule applied
      (`general-purpose` if codex is not installed). Copy the worker exit report's `pre-review: <value>` line into
      ④ Report (absence is a line too) — the nested pre-reviewer (template step 9-b) needs nothing from the
      dispatcher (rationale §14).
      **If the issue was resumed, inline two more things in the prompt.** If any **comment** carries the marker
      `<!-- ladder-resume: N -->`, the issue was revived by ①'s resume sweep, and the number of such comments is
      which resume this is. Quoted markers do not count, and the full comment set is read with `pr-comments.sh`
      (rationale §14):

      ````sh
      $SCRIPTS/pr-comments.sh <repo> <num> | jq 'def unquoted: gsub("\\r\\n"; "\n") | gsub("(^|\\n) {0,3}(?<f>```+)[^`\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<f>`*[ \\t]*(?=\\n|$)|$)|(^|\\n) {0,3}(?<t>~~~+)[^\\n]*(\\n[\\s\\S]*?)?(\\n {0,3}\\k<t>~*[ \\t]*(?=\\n|$)|$)"; " ") | gsub("(?<!`)(?<r>`+)(?!`)([^\\n]*?)(?<!`)\\k<r>(?!`)"; " "); [.[] | select(.body|unquoted|test("<!--\\s*ladder-resume:\\s*[0-9]+\\s*-->"))] | length'
      ````

      After the filled template, append ⓐ the ladder document's path
      `~/.claude/skills/issue-runner/references/live-verification-ladder.md` (where the worker reads which rung is
      climbed with which command) and ⓑ **the previous attempt's failure output** — the body of the issue's last
      ladder-related comment:
      `$SCRIPTS/pr-comments.sh <repo> <num> | jq -r '[.[] | select((.body|test("사다리|ladder")) and ((.body|test("^재개 "))|not))] | last.body // ""'`
      (exclude the sweep's own `재개 N/…` comment). Then state in one line: **"Do not repeat the same failure on
      the same rung — start from the next rung (this is resume N). If you still cannot climb it, stop with
      `BLOCKED:` quoting the rung you tried and its failure output"** — deferring without a quote is not allowed.

      **Conflict-resume branch (#345).** If the marker is `<!-- conflict-resume: N -->` (count it with the jq
      above, swapping `ladder-resume` for `conflict-resume` — same `unquoted` definition), ① reverted a
      `hold:conflict`. Instead of the ladder document, inline two things for this worker:
      ⓐ the body of the issue's **last `사람 확인(conflict):` comment**:
      `$SCRIPTS/pr-comments.sh <repo> <num> | jq -r '[.[] | select(.body|test("^사람 확인\\(conflict\\):"))] | last.body // ""'`
      ⓑ one line of instruction: **"This branch already has an open PR. Bring it up with
      `git fetch origin && git rebase origin/<DEFAULT_BRANCH>`, resolve the conflicts the way the original
      intended, implement the extra work in the note, push with `--force-with-lease`, and continue the existing PR
      (no new PR · no merge commit). If you cannot merge it, stop with `BLOCKED:` quoting the conflicting files and
      why"** (rationale §14).

## ④ Report

One-line summary: `reconciled N · maintained N · new N · resumed N · escalated N · blocked N · waiting(human review) N · warn N`
(`resumed`/`escalated` are the counts of ①'s resume-sweep `resumed`/`escalated` events — each
item carries the event's `reason` (`ladder`|`conflict`, #345);
`blocked` is the count from the ③-2 eligible scan's `blocked-summary:` — candidates dropped
by an OPEN blocker. Print it even when it is 0).
Below it, **name the numbers item by item**:
`reconciled: #4801(bodat, PR #4810 merged) · maintained: PR #4812(bodat, rebase) · new: #4818(bodat) · resumed: #4772(bodat, ladder 2/2) #5103(bodat, conflict 1/1) · escalated: #4803(bodat, ladder, hold:policy) · blocked: #4986(bodat ← #4985 needs-human) · warn: #4799(bodat) dirty worktree`.
Copy the search-window `warn:` lines (`검색 창 절단` / `검색 창 임박`) into the warn list as they are.
Repo short names are per `references/loop-conventions.md` §6.
If there are warns, list the paths and reasons below it.
**The word `스킵` / "skip" (#493).** In the Report, `스킵` is used **only for gate rejections** —
the script gate (issues that never reached the ③-2 stdout because of `막힘` (an OPEN blocker),
`needs-human` or `hold:*`) and ③-1's numeric caps (`slots ≤ 0` · the per-repo `MAX_OPEN_PRS` =
the `머지 대기 적체` warn). Both are deterministic, not judgment. A candidate that was on
stdout and not picked by the session's judgment is not a skip — it is recorded through ③-3's
transition (`hold:policy`) as the warn item `#N(<repo>) 안 집음 → hold:policy — <reason>`, and a
same-module deferral as `미룸: #N(<repo>, 같은 모듈 #M)` (both are items, not counts). A tick
with candidates and 0 new is valid only if one of those two items (or a record of a ③-1 cap skip ·
③-4a claim failure) is present — `신규 없음: … (스킵)` with none of them is exactly label parking
(the shape #493 measured).
**Token observation (soft budget)**: if any worker delivered a completion report, add
one line per issue — `tokens: <repo>#<num> <this report's count> (cumulative <sum>)`.
Also copy that worker report's `pre-review: <value>` as one line `pre-review: <repo>#<num> <value>` (no line → `none`). This count is subagent_tokens from the completion notification (absent → `?`, counted as 0);
cumulative = the same issue's `tokens:` figures from previous tick Reports visible in
context + this count (none visible → just this count). If it exceeds `SOFT_TOKEN_BUDGET_PER_ISSUE`,
state **"soft budget exceeded — recommend escalating to needs-human"** on that line (report only — never auto-label or stop workers).
If every count is 0, output the single line "quiet" — `blocked N` is one of those counts (rationale §15).

**Pipeline snapshot (required every tick).** After the lines above, run
`$SCRIPTS/loop-status.sh --post issue-runner --delta "<this tick's one-line summary>"` and paste its
output verbatim — the pasting discipline (no `cd` · even on a quiet tick) and the exit 1·64 handling
are per `references/loop-conventions.md` §7.
Even on a quiet tick, **run the eligible scan of ③ Dispatch (eligible-issues.sh) every tick** (rationale §15).
If eligible is empty and reconcile is also quiet, report the single line "quiet" and stop.

## References

Non-operational notes — they do not affect tick execution.

- Design history and rationale, plus the sources consulted for the design:
  `references/issue-runner-rationale.md` (#454, Korean only) — the target of the `(rationale §N)` markers above.
- Prerequisite: this loop works **only on GitHub** — issues, labels, assignees, and PRs are the single source of
  truth for loop state, and GitHub Actions is not required (the local-ci design). Required permissions, the
  install model (user-level global install + per-repo label opt-in via `setup-labels.sh`), running loops in
  parallel (the `.loop/repos` allowlist) and the codegraph companion are in the README and in rationale §15.
