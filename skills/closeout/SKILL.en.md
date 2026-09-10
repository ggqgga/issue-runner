---
name: closeout
description: Loop that auto-closes the green PRs issue-runner opened — merge, doc reconcile, deploy prep, and follow-up issuance. Use with /loop (e.g. /loop 20m /closeout). Each tick performs Reconcile → Pick → pipeline → (Drain repeats while candidates remain) → Report. One tick drains the whole eligible queue.
---

> English translation of [SKILL.md](SKILL.md). The Korean original is the source of
> truth — when the two diverge, follow SKILL.md and update this file to match.
> To run closeout in English, replace SKILL.md with this file's contents.

# closeout — closing-dock tick

You are an unattended closeout worker. Perform the steps below **in order**. You take
the green PRs that issue-runner opened and close them out fully — merge, doc reconcile,
deploy prep, and follow-up issuance. issue-runner never merges, so merging is this
loop's monopoly. Conflict between the two loops is prevented by `harvesting` label
occupation (issue-runner ② Maintain does not touch `harvesting` PRs).

## Constants

- `MAX_CLOSEOUT = 1` — **concurrency 1** (only 1 PR closed out to completion at a
  time, serially). Not a per-tick cap — when a PR reaches a terminal state
  (success·approval-required·blocked·dup·exhausted), **do not wait for the next tick**;
  loop back to ①①-b② and pick the next candidate (see ⑤ Drain). Only end the tick and
  rest for the `/loop` interval when the queue is empty (② Pick has 0 candidates). The
  drain is finite — a processed PR drops out of eligible (merged→gone from the OPEN
  list · blocked→`needs-human` · dup→the PR is **closed** without merging so it is gone
  from the OPEN list too (same effect as a merge) · approval-required→`배포 대기:` marker ·
  re-dispatch→PR `재디스패치:` marker + fresh updatedAt). The `/loop` interval only tunes the
  **re-scan cadence when the queue is empty** (not the drain rate). This drain fixes the
  accumulation that built up when only one PR was processed per tick.
- `REPAIR_RECUR_LIMIT = 2` — if the same post-deploy failure recurs N times,
  escalate to `needs-human` instead of re-issuing agent-ready (step-5 circuit
  breaker).
- `QUIET_TICKS = 3` — if there are no candidates/events for N consecutive ticks,
  report stagnated. **① Reconcile and ② Pick still run every tick afterwards** —
  both are mere `gh api` lookups with effectively zero cost (the real cost is only
  in the ③ pipeline), and new PRs open at any time regardless of what is already
  in flight, so skipping the scan saves nothing and only misses candidates
  (evidenced by #805 — a tick that skipped Pick after stagnated missed a PR that
  had newly become eligible). stagnated is a pure reporting label — no step is
  ever skipped.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — verifier subagent type for the step-1 plan-
  conformance check.
  **Output contract (SSOT — everywhere else refers to this entry)**: calls are
  read-only (no code changes), classify each finding as BLOCKER/WARN/NIT, output
  'CLEAN' if there are no findings, and BLOCKERs are a hard gate (no finishing
  before they are resolved). The verifier does not read this SKILL.md, so the
  call's prompt string must carry this contract verbatim — the prompt is the only
  delivery path.
  **Fallback**: use `general-purpose` as the verifier (invoked with the same
  prompt, so the same contract applies) if either — (a) the codex plugin is
  missing (the type above is absent from the Agent tool's subagent_type list, or
  the call fails with an unknown subagent type error), or (b) codex stalls/fails
  and produces no verdict (BLOCKER/WARN/NIT/CLEAN) — including network block,
  timeout, or a verdict-less response (demonstrated 2026-06-24 #54: codex
  produced no verdict because gh network was blocked in the sandbox). If the
  fallback call also produces no verdict, treat it as a BLOCKER and exit on hold
  (gate fail-closed).
- `VERIFIER_TIMEOUT_MIN = 10` — wall-clock cap in minutes per `VERIFIER` (and
  fallback) spawn. Poll against a deadline of spawn time + this value; if the
  deadline is exceeded, cut it off with `TaskStop` and treat it as no verdict
  produced — the guard rail that stops an external-CLI codex stall from
  blocking the tick indefinitely (#96).
- Absolutely forbidden: unattended production deploys (step 4 is a human gate — no
  real deploy) · unattended promotion of a production pointer branch (release etc. —
  pushing a verified SHA to a branch that production/workers pull is a human gate on
  par with a deploy) · pushing directly to main (doc reconcile also goes through the PR
  branch) · merging without `harvesting` occupation · touching worktrees/branches
  that issue-runner created · breaking issue-runner's "never merges" invariant.

## ① Reconcile

Run `$SCRIPTS/closeout-reconcile.sh` and handle each event:

- `merged_cleanup` — the merge, label, and worktree cleanup are done
  (`closeout-reconcile.sh`, on a confirmed merge, parses the PR head
  `agent/issue-N` and reaps the worktree too via `cleanup-worktree.sh ... --merged`
  — preventing buildup on the crash-resume path). But if the marker table below
  shows an incomplete step-4 or step-6 marker, resume from that step (idempotent
  resume).
- `resume` — the PR is OPEN and still holds `harvesting`. Skip the steps the
  marker table shows as finished and resume the pipeline from where it stopped.
- `stale` — report only.

Idempotent marker table (for re-judging finished steps — prevents duplicate work on
resume):

| Step | Marker | Resume judgment |
|---|---|---|
| 1 verify | PR comment `마감 검증:` | if present, skip step 1 |
| 2 merge | PR `MERGED` | if MERGED, merge is done (includes post-merge worktree cleanup) |
| 3 reconcile | plan-doc diff (merge commit) + epic comment | if in the merge, done |
| 4 deploy | `배포 대기:` comment / `deployed:<sha>` | if present, do not re-request |
| 5 post | `✅ 스모크` comment / deploy issue CLOSED + verification·deploy-complete comment | if present, do not re-smoke (including when the human gate finished verification and closed it) |
| 6 spinoff | created-issue number comment | if present, do not re-issue |

## ①-b Stuck-PR sweep — lost-finish recovery (every tick)

`closeout-eligible.sh` only surfaces PRs that carry a **`머지 판정: ✅` marker**. That ✅
is written by the worker **right before it exits** (worker-template final step), so if the
worker dies or is timeboxed between `🔄 진행 중` → verifier review → `✅`, the ✅ is lost and
the PR accumulates forever in the **blind spot of both** eligible.sh (no ✅) and issue-runner
Maintain (CI-green-with-no-review = left as awaiting human review) — evidenced by #970
(verifier `BLOCKER 없음` but ✅ lost) and #971 (died at `🔄 진행 중`). **Lost-finish recovery
is owned by this loop** (the closer) — the finish logic is unified into closeout rather than
loaded onto issue-runner (role split, user decision 2026-07-06). Like the QUIET_TICKS rule
(gh-query-only, ~0 cost), it runs every tick even when stagnated.

**Targets**: `me=$(gh api user -q .login)`, then `gh api -X GET search/issues -f q="user:$me
is:open is:pr" -f per_page=100 -f sort=created -f order=asc` (FIFO). For each PR whose head is
`agent/issue-*` and that is **not labeled `harvesting`**, **not labeled `flow:verify`**, and **not
labeled `needs-human`**, judge it. A `needs-human` PR is a human hold (`hold:*` reason — verify-held ·
closeout-blocked · the dispatcher's runner-held repair cap); adopting or re-dispatching it here would undo
that hold (#151) — never pick it until a human removes the label:

**1) CONFLICTING first**: if `gh pr view <pr> --repo <repo> --json mergeable` is CONFLICTING
→ **Adopt (rebase path)** — hand to ② Pick; ③ step 2 has closeout rebase then merge (step-2
conflict path). (Skip finish-classify.)

**2) Otherwise `$SCRIPTS/finish-classify.sh <repo> <pr>` for deterministic classification** —
the helper reads the latest `머지 판정:`/`검증자 리뷰:` comments and the `STALE_FINISH_MIN`
time buffer to emit a state (reuse the tested helper instead of hand-rolled comment parsing).
**A live worker / time-buffer-not-reached is filtered out as `active`, preventing races** — no
separate freshness gate needed:

| finish-classify output | Meaning | Action |
|---|---|---|
| `done_verdict` | latest `머지 판정: ✅` | eligible.sh's normal path handles it — sweep skips |
| `stale_inline` | 🔄 + verifier CLEAN + past buffer (reached verification, only final verdict lost, #970-type) | **Adopt (merge)** — hand to ② Pick. ③ step 1 **re-verifies independently**, then closes out. **Do not create a new issue** (no redoing completed work). |
| `stale_reverify` | 🔄 + verifier absent / unresolved BLOCKER + past buffer (died before verifying, implementation may be incomplete, #971-type) | **Re-dispatch** — do not merge unfinished work on codex re-verify alone (user decision). `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` (returns the linked issue to `agent-ready`, strips `agent:claimed` and the stage labels) → a fresh worker completes verifier→checkboxes→final verdict on the same branch. Idempotency marker (below). — if the head commit is fresh (#110, commit freshness folded into the stale clock), it falls back to `active` even when the verdict comment is stale, so a live attempt-N+1 worker isn't misclassified. |
| `held` | latest `머지 판정: ⚠ 보류` (worker's explicit hold) | **needs-human** — `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` (attaches `needs-human` + `hold:policy` to **both** the PR and the linked issue and clears the stage labels — the human signal survives even with no linked issue), closeout leaves it (no auto-progress). |
| `active` | in progress · buffer not reached · not our shape | **Leave it** (next tick). |

**`flow:*` supplementary signal**: finish-classify judges by comments, but a stale PR with
`flow:codex`/`flow:ci` and no `flow:ready` is itself evidence of "worker died during verify"
(the labels are set outside this skill by the worker runtime — use as a supplement when
present; judge by finish-classify alone when absent).

**Re-dispatch idempotency marker (required)**: on a `stale_reverify` re-dispatch, leave
`gh pr comment <pr> --repo <repo> --body "재디스패치: #<issue> — lost finish (died before verify) <!-- bodat:worker -->"`,
and **if this marker already exists and there has been no new commit / verifier comment since,
do not re-issue** (prevents /loop spam, isomorphic to the step-6 spinoff marker). Re-dispatch
eligibility is `open + agent-ready + ¬agent:claimed` (eligible-issues.sh), and the
`closeout-redispatch` transition sets both in one call (do not hand-run `gh issue edit`).
For both transitions above: **on exit 1 (readback mismatch) or 2 (gh failure), do NOT change
that PR's terminal state** — report
`BLOCKED: transition failed <transition> PR #<pr>(<repo_short>) — <one stderr line>` in
④ Report instead (the point is to leave the half-moved labels for the next tick to catch —
never pass over it silently). Once the re-dispatch lands, issue-runner Dispatch's make-worktree reuses
the existing `agent/issue-N` worktree, so **the fix continues on the same PR branch and no new
PR is created** (a repair, not a duplicate).

Adopt candidates (rebase · `stale_inline`) are consumed by ② Pick; re-dispatch / needs-human
counts are tallied in ④ Report.

## ② Pick — 1 PR at a time (MAX_CLOSEOUT=1, concurrency 1)

Take the **first candidate** (FIFO) from `$SCRIPTS/closeout-eligible.sh` output (✅-marked
normal candidates) merged with the **①-b sweep's adopt candidates** (`stale_inline` ·
CONFLICTING). One
at a time, there is no module-overlap judgment to make (serial closeout — only after this
PR is closed out to completion does ⑤ Drain pick the next candidate). Once
picked, immediately declare occupation with
`$SCRIPTS/transition.sh closeout-pick <repo> - <pr>` (the issue number is only parsed in
③-1, so pass `-` here). The transition attaches `harvesting` and strips the worker /
verify-runner stage labels (`flow:ready`·`flow:codex`·`flow:ci`·`flow:verify`) — `harvesting`
is what keeps issue-runner ② Maintain and verify-runner off this PR (verify-eligible also
excludes harvesting), and leaving only `harvesting` makes "closing out" unambiguous in the
PR list. If there are 0 candidates, skip the ③ pipeline and report a clean no-op in ④ Report.

**Missing labels are auto-provisioned by the transition.** Even an opted-in repo may lack
the `harvesting` label until `setup-labels.sh` is re-run (common for existing repos); on a
`not found`-type failure `transition.sh` runs `setup-labels.sh` **once per process** and
retries the same edit **exactly once** (no infinite loop). If that still fails it exits 2 —
skip this PR and report
`BLOCKED: transition failed closeout-pick PR #<pr>(<repo_short>) — <one stderr line>`
in ④ Report.

**Mirror onto the source issue (progress visibility).** Right after parsing `<issue>`
(the PR body's `Closes #N`/`Refs #N`) in ③-1, if there is a linked issue call
`$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` **again** (idempotent — the PR
side already matches and is a no-op; only the issue moves to `harvesting`).
**If this mirror call exits 1 (readback mismatch) or 2 (gh failure), do not proceed to the
merge** — skip this PR and report
`BLOCKED: transition failed closeout-pick PR #<pr>(<repo_short>) — <one stderr line>`
in ④ Report (so the next tick picks up the half-moved state where the PR is `harvesting`
but the issue is not). This way "closing out"
also shows on the issue list — the stage (verify→closeout) is then visible from the issue
list alone (it shows only briefly, since a successful merge closes the issue via
`Closes #N`). And **every point after ③ that lets go fail-closed** (delegation failure·
conflict needing human judgment·incomplete doc reconcile·etc.) **must use the
`closeout-blocked` (to a human) or `closeout-redispatch` (back to a worker) transition —
never a hand-run `gh issue edit`**. The transition table guarantees the `harvesting`·`flow:*`
cleanup on both the PR and the issue (prevents stale stage-label residue).
`closeout-blocked` **requires `--reason <conflict|policy|ladder> [--note "<질문 한 줄>" — policy·conflict 필수]`** (without it the
transition refuses with usage exit 64 — no reasonless `needs-human` can be created). A
rebase/semantic conflict is `conflict`; anything else the loop cannot decide (spec·policy·
no verdict) is `policy`; `ladder` only when the rungs of
`~/.claude/skills/issue-runner/references/live-verification-ladder.md`
were actually climbed and the failure output cited.

## ③ Pipeline — steps 1–6

For the picked PR, perform the 6 steps below in order. At the end of each step, plant
the marker command (① Reconcile marker table) so the next tick can resume idempotently.

**Step 1 — plan-conformance verification — built-in reviewer.** Get `<issue>` from the PR body's
`Closes #N` / `Refs #N` line (parse via `gh pr view <pr> --repo <repo> --json body`). Verification is
**two synchronous calls** of `$SCRIPTS/codex-review-gate.sh` (#134, Plans/codex-native-review-gate.md) —
no subagent spawn, polling, or `TaskStop` wiring:
1. correctness: `codex-review-gate.sh --base origin/<default> --cd <worktree> --out <scratch>/a` →
   last stdout line `verdict=… p1= p2=`, body in `a/review.md`. `[P1]` = BLOCKER.
2. plan conformance: `codex-review-gate.sh --base origin/<default> --prompt "<instructions>" --cd <worktree> --out <scratch>/b`
   (the helper prefixes the `--base` range to the prompt so the reviewer actually reads the committed diff — without it, only the working tree) —
   the instructions are `references/verifier-prompt.md` with placeholders filled: `<PR>`·`<REPO>`·`<BASE>`=default
   branch·`<PLAN_REF>`=the issue's `## Plan` or the referenced `Plans/*.md` (empty string if none)·`<ISSUE_BODY>`=
   `gh issue view <issue> --repo <repo>` output (empty string if no linked issue)·`<LESSONS_OR_"없음">`=the contents
   of **`.loop/lessons-verifier.md`** (the verdict casebook — injects past misjudgment patterns; fall back to
   `.loop/lessons.md`, `없음` if both are missing or empty. `lessons.md` is for the **implementing worker** — do not
   mix it in, it dilutes the misjudgment-prevention signal) under the path from `$SCRIPTS/repo-dir.sh <repo>`.
   `<DIFF>` is not embedded — the built-in reviewer reads the worktree itself. The instructions state "judge only
   whether this change meets the plan / issue AC; unmet or out-of-scope = `[P1]`, minor deviation = `[P2]`".
The helper has its own timeout (`CODEX_GATE_TIMEOUT`, default 900s = in step with `VERIFIER_TIMEOUT_MIN`). If either
call returns **exit 2 (`verdict=NONE`) = no verdict** (codex missing · model error · timeout), only then use the
`VERIFIER` fallback from ## Constants (general-purpose, with the diff, issue body, and lessons embedded in the prompt,
`run_in_background` + the `VERIFIER_TIMEOUT_MIN` deadline + `TaskStop` on overrun). If the fallback also produces no
verdict, exit on hold via the BLOCKER path below (fail-closed — never proceed to merge, #96). A model error in the
helper's stderr (404 · not supported · requires a newer version) is not a stall — quote it verbatim in the comment.
- Combining verdicts: BLOCKER from either call → BLOCKER. Both CLEAN/NIT/WARN → pass (`[P3+]` = NIT is non-blocking; WARN counts add up).
  Machine-comment marker (required): the closeout-verification comment posted below via
  `gh pr comment` must include **a final line `<!-- bodat:worker -->`** — it is how
  closeout-eligible tells a machine comment from a human review (#72). Without it, on
  re-evaluation the PR is mistaken for an unresolved human comment and drops out.
- **Duplicate — the loop closes it itself (never handed to a human).** If the verifier
  judges that the fix the issue asked for is **already on `origin/main`**, or that this PR
  duplicates another, treat it as neither BLOCKER nor CLEAN. Confirm the evidence commit
  (the SHA carrying that fix in `git log origin/<default>`), then close it in one line:
  `$SCRIPTS/transition.sh closeout-dup <repo> <issue> <pr> --note "<evidence commit·reason>"`
  — it closes the PR without merging, comments the evidence on the issue and closes it,
  clears the stage labels, and leaves the `dup` label on the PR. **Do not attach
  `needs-human`** — a duplicate is something the loop can decide, and handing it over piles
  up reasonless `needs-human` (the #4803 shape: closeout judged it a duplicate and still
  threw it at a human). → **dup exit** (no merge).
  **On exit 1 (readback mismatch) or 2 (gh failure), do NOT change that PR's terminal state** —
  report `BLOCKED: transition failed closeout-dup PR #<pr>(<repo_short>) — <one stderr line>`
  in ④ Report. A hunch ("looks like a duplicate") is not dup — if you cannot name the
  evidence commit, take the BLOCKER path below (`--reason policy`).
- BLOCKER (including no-verdict, e.g. reason `검증자 미산출 — 타임아웃
  (>VERIFIER_TIMEOUT_MIN분)`) → `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <reason>
  <!-- bodat:worker -->"`
  + `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  (removes `harvesting` from the PR, attaches `needs-human` + `hold:policy` to the linked
  issue and clears the stage labels) → **blocked exit** (do not merge). A verifier BLOCKER
  or no-verdict needs a spec/policy call, so the reason is `policy` (neither `conflict`
  nor `ladder`).
  **On exit 1 (readback mismatch) or 2 (gh failure), do NOT change that PR's terminal state** —
  report `BLOCKED: transition failed closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>`
  in ④ Report instead (the point is to leave the half-moved labels for the next tick to catch —
  never pass over it silently).
- CLEAN/WARN → `gh pr comment <pr> --repo <repo> --body "마감 검증: ✅ <CLEAN or WARN n>
  <!-- bodat:worker -->"`
  (this comment is the step-1 completion marker).
- **Record a false-BLOCKER reversal (lessons).** If this PR already has a prior
  tick's `마감 검증: ⚠ 보류 — …` BLOCKER comment (a prior BLOCKER) yet this
  re-verification is CLEAN/WARN, or a human removed `needs-human` and the original
  flowed through unchanged — that BLOCKER was a false judgment that got reversed.
  Append one line `- [YYYY-MM-DD PR#<pr>] <false-BLOCKER pattern → recurrence-
  prevention action>` to **`.loop/lessons-verifier.md`** under the path output by
  `$SCRIPTS/repo-dir.sh <repo>` (create it if absent — this is the verifier's
  casebook, kept separate from the worker's `lessons.md`). **Cap: 20 entries** —
  on overflow drop the oldest **entry as a whole**, not by line: this file mixes
  multi-line cases starting with `##`, and cutting by line tears the prose apart
  (an entry = one line starting with `- [`, or a `##` header through just before the
  next entry). This record is fed back into
  the next verification via the `<LESSONS_OR_"없음">` injection above, preventing
  recurrence of the same misjudgment (citation misreads·base blind spots·etc.).
  (If it was not a reversal — a normal CLEAN — do not record.)

**Step 2 — merge gate.** The merge command **must pass `--repo <repo>`** — closeout
merges PRs in repos outside cwd, so the ci-gate hook must query that repo via
`--repo` to not hit fail-closed (the hook's `--repo` recognition is #47; demonstrated
2026-06-24: in a BoDAT cwd session, merging an issue-runner PR was blocked because the
hook queried the cwd repo). Gate conditions: `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>`
(exit 0) + the worker's `검증자 리뷰:` comment shows BLOCKER 0 + recheck
`gh pr view <pr> --repo <repo> --json mergeable` ≠ CONFLICTING.
- **Revalidate the rebased HEAD (`revalidate:true` precondition gate, #70).** If the
  candidate ② Pick took has `revalidate` true (= `closeout-ci-pass.sh` returned exit 2 —
  the current HEAD's local-CI cache is empty due to a rebase etc., i.e. "not run, not
  fail"), then **before** evaluating the exit-0 gate above, revalidate the current HEAD:
  obtain a worktree via `$SCRIPTS/make-worktree.sh <repo> <N>` (`<N>` parsed from the PR
  head `agent/issue-N`, same as step 3) → **sync that worktree to the rebased remote
  head** (`make-worktree.sh` returns an existing worktree as-is, so it may still have the
  pre-rebase SHA checked out — unlike step 3, this path makes no new commit, so the sync
  is the only freshness guarantee): `git -C <wt> fetch origin` then
  `git -C <wt> reset --hard origin/agent/issue-<N>` to align the worktree HEAD to the PR's
  current (rebased) head SHA (this is exactly the SHA `closeout-ci-pass.sh` looks up via
  `gh pr view headRefOid` — without the sync, run-local-ci caches the old SHA and it stays
  permanently exit 2) → fill the **current HEAD** cache with
  `$SCRIPTS/run-local-ci.sh <repo> <N>`. If `run-local-ci.sh` exits nonzero (integration
  with the new base is broken), do not merge: exit on hold fail-closed
  (`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` +
  `blocked` exit, do not
  invent a new exit state — if that transition exits 1·2, report
  `BLOCKED: transition failed closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>`
  in ④ Report). If 0, the cache is
  filled with pass, so join the exit-0 gate below. This path fires **independent of
  whether step 3 produced a doc commit** — step 3's cache supplement only runs after a
  doc push, so it cannot cover the rebase·no-doc-change case (where the worker's
  `머지 판정 ✅` did not follow the new SHA). (If `revalidate:false`, the cache is
  already pass so this revalidation is skipped.)

If all pass, **perform step 3 (doc reconcile) right
here** to create the doc commit on the PR branch and push it — so the squash merge
includes that doc reconcile — then `gh pr merge <pr> --repo <repo> --squash` (the
ci-gate hook judges once more). That is: the step numbering is 1→2→3, but the step-3
commit is slotted in just before the step-2 merge ("before merge" in the step-3 header
marks this slot-in point). **Just before `gh pr merge`, if step 3 pushed a new doc
commit**, re-confirm `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` is pass (exit 0) with a
short bounded poll (e.g. 2–3s interval × max 5 tries, never wait forever) — since
step 3's `run-local-ci.sh` fills the cache synchronously this is usually pass
immediately — and if pass is not reached within the limit, do not merge: exit on hold
fail-closed (same path as step 3's nonzero-cache/not-reached handling — the
`closeout-blocked … --reason policy` transition + `blocked` exit, do not invent a new
exit state). **Right after `gh pr merge`
succeeds**, call `$SCRIPTS/cleanup-worktree.sh <repo> <N> --merged` to clean up this
PR's worktree (`agent/issue-<N>`) directly (`<N>` parsed from the PR head
`agent/issue-N`, same as step 3). Since closeout monopolizes merging, it reaps the
worktree itself at merge time and does not depend on issue-runner reconcile — so even
a closeout-only session has no buildup. `--merged` relaxes the unpushed guard for the
trap where a squash merge auto-deletes the remote head and `@{u}` disappears (the
dirty guard stays — if dirty, warn and hold; best-effort).

- **CONFLICTING → closeout rebases it and proceeds directly** (conflict-rebase ownership
  transferred from issue-runner Maintain to closeout). Do not skip — conflict must be
  **caught at the merge stage** and that responsibility is this loop's. Keeping the
  `harvesting` occupation: `$SCRIPTS/make-worktree.sh <repo> <N>` (`<N>` = head
  `agent/issue-N`) → `git -C <wt> fetch origin` → `git -C <wt> rebase origin/<BASE>`
  (`<BASE>` = default branch). **If conflicts arise, synchronously spawn a rebase agent**
  (read worker-template `~/.claude/skills/issue-runner/references/worker-template.md`, fill
  placeholders, replace the "Procedure" with "in this worktree (`<WT_PATH>`), rebase onto
  `origin/<BASE>`, resolve conflicts per the original intent, `git push --force-with-lease`,
  **no merge commit**", keeping push discipline and prohibitions) → after the agent exits,
  run `$SCRIPTS/run-local-ci.sh <repo> <N>` to regenerate the rebased-HEAD cache. If nonzero
  (integration with the new base is broken), do not merge — **delegate fail-closed**:
  `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` returns the linked issue
  to `agent-ready` (or spinoff), blocked exit. If 0,
  join the exit-0 merge gate above and squash-merge normally. If the agent **cannot resolve**
  the conflict (rebase abort / repeated failure), a semantic conflict is a human call:
  `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason conflict --note "<질문 한 줄>"`,
  blocked exit (no unattended forced resolution — this path alone uses `conflict`). For both transitions: **on exit 1 (readback mismatch) or
  2 (gh failure), do NOT change that PR's terminal state** — report
  `BLOCKED: transition failed <transition> PR #<pr>(<repo_short>) — <one stderr line>` in
  ④ Report instead.

**Step 3 — doc reconcile (before merge, PR-branch commit).** Change the `- [ ]` to
`- [x]` in the plan-doc section that step 1 confirmed implemented. Commit and push
from the PR-branch worktree (obtained via `$SCRIPTS/make-worktree.sh <repo> <N>` —
`<N>` parsed from the PR head branch `agent/issue-<N>` via
`gh pr view <pr> --repo <repo> --json headRefName`, idempotent) so it is included in
the squash merge (no direct push to main). If there is an epic, leave a progress rollup
comment.
- **Absorb surface corrections (into the same commit).** Among step 1's verifier
  WARN/NIT findings, the **surface-correction** class does not go to step 6 as a spinoff
  issue — **fix it here** and carry it in this commit. The PR-branch worktree is already
  checked out and the cache reinforcement below re-runs local CI on the new SHA, so this
  costs **zero extra cycles** — whereas issuing it spends a whole dispatch→implement→
  verify→closeout lap on a one-line fix.
  **The criterion, one line: does this change flip the pass/fail of any test at all?**
  If none, fix it here; if even one, it is a step-6 issue. What the criterion admits —
  comment prose, terminology/notation unification, numbers and coordinates inside
  comments, dead-reference removal, **test names** (the description string in `test "…"`
  executes but does not flip pass/fail). What it blocks — new assertions·new guards·
  added coverage·constant values·execution branches. "While I'm fixing the comment, one
  more assertion" is an issue.
  - State what was fixed in a comment on the original PR:
    `표면 교정(closeout 3단계): <file> — <what>`. Closeout merges what it fixed itself,
    so that fact must be visible to a human.
  - If the cache reinforcement below is non-zero (local CI failed), **revert that
    correction commit** and take the normal fail-closed path — a surface correction must
    never become the reason a merge is blocked.
  - Do not touch it if the verifier raised a BLOCKER or this PR is heading to hold/
    re-dispatch (passing PRs only — the same discipline as verify-runner ⓪).
- **cache supplement (right after push, option 1).** Once the doc commit is pushed,
  **right after** call `$SCRIPTS/run-local-ci.sh <repo> <N>` once (`<N>`=the issue
  number parsed above — identifies the worktree path `issue-<N>`; distinct from
  `closeout-ci-pass.sh`'s `<pr>`). This helper reads the worktree HEAD SHA and, via
  `repo-dir.sh`, fills the local-CI cache under the **main repo slug**
  (`<main-slug>/<SHA>.result`) — exactly where step 2's merge gate (`ci-gate`·
  `closeout-ci-pass.sh`) reads, closing the gap where the result lands only under the
  worktree slug and the gate fail-closes on a permanent cache-miss. **Idempotency guard
  before the call**: if `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` is already pass
  (exit 0) (a prior tick already cached the same HEAD), do not re-run `run-local-ci.sh`
  (the helper has no dedup of its own, so the caller guards). If `run-local-ci.sh`
  exits nonzero (=bin/ci failed) the cache is not filled with pass, so do not merge:
  exit on hold fail-closed
  (`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  + `blocked` exit, follow the existing BLOCKER path — do not invent a new exit state; if
  that transition exits 1·2, report
  `BLOCKED: transition failed closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>`
  in ④ Report).
- **single-issue degrade**: if there is no `Plans/*.md`·`## Plan`, skip the doc edit.
  If there is no epic, skip the rollup. Reconcile only the issue's own checkboxes. If
  neither exists, this step is a no-op — **since there is no new doc commit·push, skip
  the cache supplement above too** (no new HEAD SHA to fill).

**Step 4 — deploy (human gate, dry-run).** **Do not deploy for real.** Fill
`references/deploy-check-issue.md` (`<DEPLOY_CMD>`=the repo's deploy entrypoint, or
"the repo's deploy procedure" if unknown; `<VERIFY_URL>`=the production base URL the
step-5 smoke drives — leave it blank if unknown so step 5 falls back as URL-unreachable;
`<LIVE_CHECKS>`=carry over the items from the PR test plan·issue body marked
as **only performable after merge** — e.g. "post-deploy live verification",
hardware/real-device checks; this is the sole hand-off destination
for out-of-merge-scope verification the step-1 verifier excluded from the merge gate).

**`<LIVE_CHECKS>` must take one of two shapes — no free prose.**
- If there is **nothing at all** for a human to do after deploy, exactly the one word
  `없음`. Do not append an explanation after it.
- Otherwise a **`- [ ]` checkbox list**. One line = one action a human performs.
  Background·rationale·caveats go in `## 변경 요약`; leave only the actions here.

Why the shape is enforced: the branch below reads this section to decide whether an issue
is filed at all, and free prose leaves that decision to per-tick interpretation, which
drifts (measured 2026-08-12~13: of 186 deploy-check issues, **zero** used checkboxes —
all prose). A sentence like "없음. 주석 13줄이 전부다 — 관찰 가능한 변화가 없다" is clear
to a human but is not `없음` to a machine branch.

**Before carrying an item over, closeout climbs the ladder once (an untried `[ ]` is not
carried over as-is).** Unfinished items the worker left as a bare `[ ]` **with no rung
attempt and no citation** (no attempted rung, no failure output in the PR test plan) must
not be copied into this section as-is — doing so promotes work nobody attempted into a
human's lap. closeout attempts **rung ① (dev server — `bin/rails runner`·localhost) and
rung ② (`bin/dry-run`·the AdsPower relay)** of
`~/.claude/skills/issue-runner/references/live-verification-ladder.md`
**once each** first (rung ③, real hardware, is not closeout's job — record it with the
attempt results).
- If rung ①② **yields a verdict**, **drop** the item from `<LIVE_CHECKS>` (it is not a human
  action any more). Record the basis in a PR comment.
- If they **fail**, carry the item over as `- [ ]` but **cite the rung attempted and its
  failure output (the command plus its last 20 lines)**. The citation goes in the
  `## 변경 요약` section — `<LIVE_CHECKS>` keeps the shape discipline above and holds
  **actions only**, no prose or output.
- If the attempt is impossible in this environment (no such entrypoint in the repo, etc.),
  say so in one line in `## 변경 요약`. Never skip the attempt on the strength of the words
  "real hardware needed".

**Branch — once it is merged, always create a promotion ticket (user decision, 2026-08-16).**

**A merged PR files exactly one deploy-wait issue, without exception.** Do not judge — even
if it is tests-only or a one-line comment, being merged means it entered the promotion scope,
and that fact must be visible to a human. File it with
`gh issue create --repo <repo> --label needs-human --label deploy-wait` — `needs-human`
stays for compatibility with the existing human-gate collection (deploy-bodat etc.), and
`deploy-wait` is the bucket label `loop-status.sh` uses to separate deploy-waiting from
human-waiting — leave the marker
`gh pr comment <pr> --repo <repo> --body "배포 대기: #<created-number>"`, then
**exit as approval-required**.

**Missing label — fail closed, never lose the ticket (same shape as the step-6 spinoff rule).**
`gh issue create` fails **without creating the issue** when any `--label` does not exist in the
repo. Existing opted-in repos lack `deploy-wait` until `setup-labels.sh` is rerun, so without
this rule the first closeout after upgrading ends with the PR merged but no ticket and no marker.
On a `'deploy-wait' not found`-style failure, run `$SCRIPTS/setup-labels.sh <repo>` **once** and
retry the same command **once**. If the retry also fails, do not loop — file with
**`--label needs-human` only** (no lost ticket — `loop-status.sh` still counts it as
deploy-waiting via the `배포 대기:` title fallback) and report
`BLOCKED: deploy-wait label attach failed on deploy issue — #<number>` in ④ Report.

Why this rule was flipped: the previous rule created no issue when `<LIVE_CHECKS>` was `없음`,
justified by "④ Report's `승격 대기 N커밋` holds the unpromoted state". But that Report line
turns out to be easy to omit (observed 2026-08-16: three consecutive closeouts had neither an
issue nor the number, so the merged work looked like it had evaporated) — leaving us **unable
to tell whether there is anything to promote at all**. Do not leave the ledger to the report
alone; keep it as an issue too.

**The `<LIVE_CHECKS>` shape discipline still stands, though** — it no longer decides whether an
issue is filed, but this section still decides the step-5 smoke:

- **If there is at least one checkbox**, that list is what closing the issue requires, and
  step 5 checks it with a Chrome smoke.
- **If it is `없음`**, append `(승격만)` (promotion-only) to the issue title and leave `없음`
  as-is in the body's `## 라이브/하드웨어 검증 항목`. **Skip the step-5 smoke** — a smoke with
  zero items to check did not pass anything, it looked at nothing, yet it prints as
  `✅ 스모크 0/0 통과` and reads as verified (false green). A human closes this issue once the
  promotion is done.

**Do not batch.** Never merge several deploy-wait issues into one — a long-lived issue that
keeps accruing items loses its closing moment and becomes an issue that never ends (user
decision, 2026-08-13). Even as the count grows, keep **one PR = one ticket = a container with
a clear closing moment**.

**Step 5 — post-deploy handling (Chrome smoke).** For a deploy issue a human has
reported deployed, without any new detection mechanism (no polling/timing), actively run
a Chrome smoke to judge it. Parse `## 검증 URL` (`<VERIFY_URL>`) and
`## 라이브/하드웨어 검증 항목` (`<LIVE_CHECKS>`) from the deploy issue body, fill
`references/smoke-prompt.en.md`'s placeholders, load the chrome-devtools MCP tools via
ToolSearch, then **entry cleanup (idempotent — crash-resume defense): via `list_pages`,
if a prior tick died before cleanup and left a smoke page, `close_page` it first.** Then
`navigate_page` to `<VERIFY_URL>`, and compare each item via
`evaluate_script`/`take_snapshot` to produce a per-item pass/fail (distinguish
structure/empty-state confirmation from real-data render confirmation in the result).
- **No items to step through — do not smoke.** A PR that step 4 routed down the `없음`
  branch has no issue, so it is not a step-5 subject at all. Even when a deploy issue
  exists, if `## 라이브/하드웨어 검증 항목` holds no `- [ ]` at all, do not open Chrome —
  a smoke with zero items to compare has not passed anything, it **looked at nothing**,
  yet it prints as `✅ 스모크 0/0 통과` and reads as verified (a false green). Leave the
  reason as a comment instead: `스모크 생략: 밟을 항목 0`.
- **Already-closed deploy issue — skip the smoke.** If the deploy issue is already
  CLOSED and has a verification/deploy-complete comment, treat step 5 as complete —
  do not re-smoke, proceed to the next step (the case where the human gate finished
  verification and closed it — the standard finalization in a promotion-model repo).
- **Degrade — no silent skip.** If the chrome-devtools MCP is absent from the session
  (headless/cron — interactive-auth MCP may be missing) or `<VERIFY_URL>` is blank or
  unreachable, skip the smoke and fall back to the existing human-report path, but leave
  a `스모크 skip: <reason>` comment on the deploy issue (no hiding the gap).
  But **"unreachable" is the last word, not the first** (#153): some addresses open only
  outside Chrome, so before writing the skip, walk the retry ladder in smoke-prompt —
  ① the repo's remote-access address ② an SSH tunnel. Only when **both** fail is it
  unreachable. **Since no
  browser was started at all, there is nothing to clean up — the browser cleanup below
  is a no-op (not a leak).**
- **green (all pass)** → a `✅ 스모크: <n>/<n> 통과` comment on the deploy issue + the
  original PR (this comment is the step-5 completion marker — a resumed tick does not
  re-smoke). Then remove the `needs-human` label from the deploy issue and close the
  deploy issue (the only remaining gate was verification and it passed, so closeout
  finalizes — the recommended option of the open decision).
- **fail (any item fails)** → do not fix it directly; use the existing publish path: an
  agent-ready issue via `references/spinoff-issue.md` if auto-fixable (**use step 6's
  "issuance command" form verbatim** — `--label agent-ready --label spinoff --label <P1|P2>`;
  no prose substitute here either), a `--label needs-human` issue if live verification is needed.
  If the same failure recurs `REPAIR_RECUR_LIMIT`
  times, escalate to `needs-human` (**exhausted exit**). Do not close the deploy issue.
  The label is `needs-human` (hyphen) — `needs:human` does not exist and makes
  `gh issue create` fail outright (the only colon form is `needs:hardware`).
  - **Record a code-unrelated smoke failure (lessons).** If that smoke failure turns
    out to be code-unrelated (infra outage·flake·transient verify-URL error·etc.),
    separately from the publish path above, append one line
    `- [YYYY-MM-DD PR#<pr>] <smoke-misjudgment pattern → recurrence-prevention action>`
    to **`.loop/lessons-verifier.md`** under the path output by `$SCRIPTS/repo-dir.sh <repo>`
    (same file and cap as step 1 — it is a verdict-misjudgment class, so it belongs in
    the verifier's casebook). A failure that turns out to be a code defect is not recorded
    here — the publish path handles it.
- **Browser cleanup — leak prevention (common exit; green·fail·degrade all).** **After**
  leaving the smoke-verdict comment above, always close the chrome-devtools page this tick
  opened via `list_pages`→`close_page` — no matter which of the three exit paths was taken
  (do not return before cleanup). Production pages keep client pollers alive (adspower_pool
  30s auto-refresh·aging live poll·assembler live-sync, etc.), so a stranded tab accumulates
  every tick and spins CPU via `setInterval`, tipping the mini into overload within days
  (2026-07-06 load-66 incident). If degrade opened no browser there is nothing to clean up
  (no-op — but if `navigate_page` was attempted to judge URL-unreachability and it opened
  an error tab, `close_page` that tab too), and a normal no-op tick (no smoke target)
  likewise opens no browser, so this cleanup is skipped without regression.

**Step 6 — spinoff issues.** Fill `references/spinoff-issue.md` with the worker PR
body's `follow-up:` items + adjacent work the step-1 diff review flagged, and issue an
agent-ready issue. Link it as a sub-issue if there is an epic, or as a standalone
issue if not. Record the created number in a comment on the original PR (a
duplicate-issuance marker).

- **Issuance command (required form — do not substitute prose).** Write the filled
  `spinoff-issue.md` to a file and pass it via `--body-file` (the template is
  **body-only** — labels written there render into the issue body; labels must come
  from the command line):

  ```
  gh issue create --repo <repo> --title "<title>" --body-file <body-file> \
    --label agent-ready --label spinoff --label <P1|P2> [--label <repo-convention label>...]
  ```

  **`--label agent-ready` is not optional** — `eligible-issues.sh` gates dispatch on
  `open + agent-ready + ¬agent:claimed`, so without it the issue is created but
  issue-runner **never picks it up** (measured 2026-08-13 on BoDAT: step 6 attached only
  the 3-axis convention labels and dropped agent-ready, stranding 17 open issues outside
  the loop — while step 4, whose command literally carries `--label needs-human`, was
  correct on all 186. The step with a command did not leak; the prose-only step did).
  Attach a priority (`P1`/`P2`) too — without one it sorts last (`P0 > P1 > P2 > none`).
  Add the other axes per repo convention (BoDAT: `difficulty:*`·`frontend`/`backend`·
  `area:*`·`needs:hardware`), but **never let convention labels displace `agent-ready`** —
  that is exactly the observed failure shape.
  `--label spinoff` is the provenance mark — `loop-status.sh`'s `파생` line counts spinoff
  issues in the window by this label alone (no title heuristic). Without it the issue is
  invisible in the inventory.
- **Missing-label fail-closed (isomorphic to ② Pick's harvesting top-up).**
  `gh issue create` **fails without creating the issue** when a `--label` does not exist
  (unlike the harmless `--remove-label`). On a `'agent-ready' not found` / `'spinoff' not found`-type failure,
  call `$SCRIPTS/setup-labels.sh <repo>` **once** and retry the same command **once**.
  If the retry also fails, do not loop further — **create the issue without labels**
  (never lose the issuance) and report `BLOCKED: spinoff issue labeling failed —
  #<number>` in ④ Report.
- **Verify right after issuance.** Check with
  `gh issue view <number> --repo <repo> --json labels` that **both** `agent-ready` and
  `spinoff` actually landed; if either is missing, top it up with
  `gh issue edit <number> --repo <repo> --add-label agent-ready --add-label spinoff`.
- **Do not issue what step 3 already absorbed.** A finding that passed step 3's
  "absorb surface corrections" criterion (does this flip the pass/fail of any test?)
  and rode along in that commit is not remaining work. When one finding mixes surface
  and code (e.g. "the terminology diverged + the count has no guard"), step 3 takes the
  surface and **only the code part** becomes an issue — do not restate the already-fixed
  part in the issue body (the next worker will go fix it again).
  Why this clause exists: it stops a full issue→PR→verify→closeout lap from running for
  one line of comment prose, and such a lap was measured to spawn fresh comment findings
  of its own, lengthening the chain.

## ⑤ Drain — continue to the next candidate immediately

**Right after** ③ Pipeline drives the picked PR to a terminal state
(success·approval-required·blocked·dup·exhausted), accumulate that PR's result for ④ Report and
**loop back to ①①-b② without waiting for the next tick** — this drain exhausts the queue
within one tick, fixing the accumulation that built up when only one PR was handled per tick:

- Re-run ① Reconcile + ①-b stuck-PR sweep + ② Pick. If ② Pick **picks a new candidate** (the
  PR just processed has already dropped out of eligible/adopt candidates), continue into ③
  Pipeline with it immediately.
- If ② Pick has **0 candidates**, the queue is empty — stop draining, report **all PRs
  processed this tick at once** in ④ Report, then schedule the next tick on the `/loop` interval.

Infinite-loop guard: each iteration reduces eligible/adopt candidates by ≥1 (merged→gone ·
blocked→`needs-human` · dup→PR closed without merging so it is gone ·
approval-required→`배포 대기:` marker · re-dispatch→PR `재디스패치:`
marker so it is not re-selected — the sweep won't re-issue with no new activity after the marker).
If the same PR is picked twice (unexpected, e.g. a missing marker), skip it and report
`BLOCKED: re-selection loop — #<pr>` in ④ Report to break the drain. If a hard cap is needed, one
tick's drain runs at most the length of the eligible snapshot (PRs opened after the snapshot are
the next tick's).

## ④ Report

When the drain ends (② Pick has 0 candidates), report **all PRs processed this tick summed**
(N is this tick's cumulative count): `closed N · verify-hold N · dup-closed N · deploy-wait N · spinoff N · recovered N · re-dispatched N · stale N`
(the Korean report line calls the third one `중복종료 N`).
Count PRs the ①-b sweep adopted to close/rebase as `recovered N` (also reflected in `closed`
if it became that tick's Pick), and `stale_reverify` re-dispatches / `held` needs-human as
`re-dispatched N`.

Below that, **name the numbers item by item** — counts alone do not tell the next tick where
each PR/issue went:
`closed: PR #4795(bodat)←#4788 · spinoff: #4823(bodat)←PR #4788 · re-dispatched: #4770(bodat, stale_reverify)`.
The repo short-name rule is the same as `loop-status.sh`'s (the repo part of `owner/repo`
lowercased — bodat·bodac; `issue-runner` alone maps to `runner`).

**Also report `승격 대기 N커밋` every tick (never omit it).** Do not drop it even on a tick
with zero closeouts — it is the only number a human reads to see whether anything is waiting
to be promoted. If the repo has a promotion pointer branch (`release` etc.), count with
`git fetch origin <pointer> <default-branch>` then
`git rev-list --count origin/<pointer>..origin/<default-branch>`; if the repo has no pointer
branch, write `승격 대기 —` to state that it does not apply. If it is 0, write
`승격 대기 0커밋` verbatim (do not omit — omission and 0 are different).
Evidenced 2026-08-16: three consecutive ticks dropped this line and, overlapping a period
with no deploy issues, the closed work looked like it had evaporated. That incident is why
step 4 went back to "merged ⇒ always a ticket".
(The `loop-status.sh` block below also prints promotion-waiting, but this line **stays** —
the duplication is deliberate redundancy given that omission history.)

**Pipeline snapshot (required every tick).** After the lines above, run
`$SCRIPTS/loop-status.sh --post closeout --delta "<this tick's one-line summary>"` (it also overwrites the per-repo pinned dashboard issue `루프 현황` — label `loop-dashboard` — so GitHub alone shows who holds what and when each loop last ticked, #163) and paste its output **verbatim** — the counters only say "what
this tick did"; what is piled up is visible only in this block. Call it with no `cd` (the
scope auto-applies from the loop session cwd's `.loop/repos`). **Paste it even on a quiet
tick where every count is 0** — the snapshot is the only window onto what is idling.
- On exit 1 (partial failure — some repos failed to query), paste the output as-is and add
  one warn line `loop-status 부분 실패`.
- On exit 64 (no scope — an account-wide session with no `.loop/repos`), call it once more
  naming the repos touched this tick with `--repo <owner/repo>`; if there are none, leave one
  warn line `loop-status: 스코프 없음(.loop/repos 부재)`.

State the 7 exit states — for **each** PR processed (per-PR when the drain handled several):
- **success** — ran steps 1–6, merged the PR, and issued follow-ups (including adopt/rebase recoveries).
- **clean no-op** — ② Pick had 0 candidates, so there was no PR to close (but if there were ①-b re-dispatches it is not a no-op — report `re-dispatched N`).
- **blocked** — step-1 verification was a BLOCKER, or step-2 rebase integration failed, so it is on hold (no merge).
- **dup** — step-1 verification judged it "already on `origin/main`·duplicate", so
  `closeout-dup` closed the PR and the issue without merging (no `needs-human` — the loop
  finished it). Counted as `dup-closed N` (`중복종료 N` in the Korean report line).
- **approval-required** — step 4 issued a deploy issue and is awaiting the human gate.
- **exhausted** — the same step-5 failure recurred `REPAIR_RECUR_LIMIT` times,
  escalated to needs-human.
- **stagnated** — quiet for `QUIET_TICKS` consecutive ticks.

Even after `QUIET_TICKS` consecutive quiet ticks, ①② still run on every tick —
stagnated only affects reporting; no step is ever skipped.

## References

Non-operational notes — they do not affect tick execution.

- Role split: issue-runner = the factory that opens work (never merges, preserves
  invariants), closeout = the closing dock (monopolizes merging). The two loops
  prevent conflict via `harvesting` label occupation — issue-runner ② Maintain does
  not touch a PR that closeout has picked.
- Human gate: only production deploys are human-approved (step-4 dry-run issue →
  approval). The rest — merge, doc reconcile, follow-up issuance — is unattended.
- Operation: run closeout as a `/loop` session separate from issue-runner
  (e.g. `/loop 20m /closeout`) — the two coordinate occupation purely by label.
- Dependencies: the deterministic helpers (`closeout-reconcile.sh`·
  `closeout-eligible.sh`·`closeout-ci-pass.sh`·`transition.sh` (label moves)·
  `loop-status.sh` (the ④ Report snapshot)) live in `$SCRIPTS`
  (=`~/.claude/skills/issue-runner/scripts`), and the 3 references
  (`verifier-prompt.md`·`deploy-check-issue.md`·`spinoff-issue.md`) live in
  `skills/closeout/references/`.
- The attempt order, transports and citation rules for anything needing live measurement
  are in `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  (rung ①dev → ②worker runtime → ③TEST worker → ④human; the basis for the step-4 `<LIVE_CHECKS>` rung-①② attempt and the
  precondition for `--reason ladder`).
