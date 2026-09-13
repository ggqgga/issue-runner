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
> **This loop's incident history and design rationale live in `references/closeout-rationale.md`** (#453, Korean only).
> Why each rule exists · which incident (`#NNN`) or measurement established it · which alternative was rejected and
> why — read it there. The `(rationale: closeout-rationale §N)` line at the end of each section points at that
> section. **You do not need to read it to run a tick.** The body below carries rules and calls only: read that
> document first when you are about to change or revert a rule.

## Constants

- `MAX_CLOSEOUT = 1` — **concurrency 1** (close out exactly 1 PR end to end at a time). It is not a per-tick
  cap — the moment a PR reaches a terminal state (success·approval-required·blocked·dup·exhausted),
  **do not wait for the next tick**: go back to ①①-b② and pick the next candidate (⑤ Drain). Only when the
  queue is empty (② Pick returns 0 candidates) does the tick end and rest for the `/loop` interval. The
  `/loop` interval only tunes **the rescan gap while the queue is empty**.
- `REPAIR_RECUR_LIMIT = 2` — when the same post-deploy failure recurs N times, escalate to `needs-human`
  instead of re-issuing agent-ready (the step-5 circuit breaker).
- `QUIET_TICKS = 3` — after N consecutive ticks with no candidate or event, report stagnated. **① Reconcile,
  the ①-b sweep and ② Pick still run on every tick afterwards** — stagnated is a pure reporting label and
  skips no step.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = general-purpose` — the sub-agent type for the step-1 plan-conformance verifier. **Not codex**
  (#375). **The output contract's SSOT is the `VERIFIER` entry in issue-runner `SKILL.md`'s `## Constants`
  section** (#427) — it is not restated here: read-only · BLOCKER/WARN/NIT · CLEAN · BLOCKER is a hard gate,
  applied as-is. The verifier never reads this SKILL.md, so that contract text must be carried verbatim in the
  invocation prompt string — the prompt is `references/verifier-prompt-fallback.md` (the edition that
  **encloses** the diff, issue body and lessons), and `references/verifier-prompt.md` is for the built-in
  reviewer (codex) only, so it is not used here.
- `VERIFIER_TIMEOUT_MIN` — the wall-clock cap (minutes) per `VERIFIER` (or fallback) spawn. Poll against
  spawn time + this value as the deadline and, once past it, cut the run with `TaskStop` and treat it as
  "no verdict" (#96). **The value is `scripts/lib/constants.sh`'s `CODEX_GATE_TIMEOUT` (seconds) converted
  to minutes.**
- Absolutely forbidden: unattended production deploys (step 4 is a **handoff to the deploy lane
  (deploy-cycle)** — closeout never deploys) · unattended promotion of a production pointer branch (release
  etc.; pushing a verified SHA to a branch production/workers pull from ranks with deploying and belongs to
  the deploy lane) · direct pushes to main (doc reconcile also goes through the PR branch) · merging without
  `harvesting` occupation · touching worktrees/branches issue-runner created · breaking issue-runner's
  "never merges" invariant.

(rationale: closeout-rationale §1)

## ① Reconcile

Run `$SCRIPTS/closeout-reconcile.sh` and handle each event:

- `merged_cleanup` — the merge, labels and worktree cleanup are done (on a confirmed merge that script parses
  the PR head `agent/issue-N` and runs `cleanup-worktree.sh ... --merged` itself). But if the marker table
  below shows step 4 or 6 unfinished, resume from that step (idempotent resume).
- `resume` — the PR is OPEN and still `harvesting`. **Before reading the marker table, read the bounce-state
  table below.**
- `lookup_failed` — the PR's **state could not be read** (gh failure, empty response, #433). This is not
  CLOSED — do not strip labels, **touch nothing**, and let the next tick re-query. One line in ④ Report:
  `보류: PR #<pr>(<repo_short>) — 상태 조회 실패`.
- `human_hold` — the PR is OPEN but carries `needs-human` (a human is investigating), or that label could not
  be read (`why` distinguishes them). **Touch nothing** — leave one line in ④ Report,
  `보류: PR #<pr>(<repo_short>) — 사람 보류(<why>)`, and touch the PR no further this tick. **Release path**:
  once the human removes `needs-human` it comes back as `resume` on the next tick (`harvesting` stays, so the
  PR never leaks out of the lane).
- `stale` — report only.

Idempotency marker table (for re-judging finished steps — prevents duplicate work on resume):

| Step | Marker | Resume judgment |
|---|---|---|
| 1 verify | PR comment `마감 검증: ✅` | skip step 1 only when `$SCRIPTS/closeout-step1-marker.sh <repo> <pr>` says **exactly `skip`** — `verify` and any non-zero exit (lookup/parse failure) both mean **run it** |
| 2 merge | PR `MERGED` | if MERGED the merge is done (worktree cleanup right after the merge included) |
| 3 reconcile | plan-doc diff (merge commit) + epic comment | if included in the merge, done |
| 4 deploy | `배포 대기:` comment / `deployed:<sha>` | if present, do not re-request |
| 5 post | `✅ 스모크` comment / deploy issue CLOSED + verification·deploy-complete comment | if present, do not re-smoke (including when the deploy lane (deploy-cycle) finished verification and closed it) |
| 6 spinoffs | the `파생 판정:` comment (#411 — posted last, after every branch action) · the created issue-number (`파생:`) comment | `파생 판정:` present → step 6 done (including ⓔ = 0) · only `파생:` present → do not re-file that issue |

**The step-1 marker judgment is one place, `closeout-step1-marker.sh`** — it ANDs ⒜ is the latest
`마감 검증:` a `⚠ 보류` ⒝ is the marker earlier than the current head commit ⒞ does the marker precede the
newest bounce marker, all inside that script (the bounce-marker set and ordering come from
`bounce-state.sh --marker-index` — never a second copy of the marker matching, #171). Do not re-derive any of
the three here.

**`resume`'s resume point is decided by the bounce state before the marker table (#271).** Run
`$SCRIPTS/bounce-state.sh <repo> <pr>` once and let its value choose the resume point (the **same single
place** ①-b uses). All four values have a destination:

| `bounce-state.sh` | Meaning | `resume` resume point |
|---|---|---|
| `ok` | no bounce marker, or the last verdict after the newest bounce marker is `머지 판정: ✅` | **the marker table as-is** — skip finished steps and resume where it stopped |
| `bounced` | there is no verdict comment after the newest bounce marker, or the last one is `머지 판정: 🔄` | **do not read the marker table** — resume at ③-1 ⓐ's `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` **retry point** (procedure below); do not go to step-1 re-verification or the step-2 merge |
| `held` | the last verdict after the newest bounce marker is `머지 판정: ⚠ 보류` | **treat as `active`, touch nothing** — leave one line in ④ Report, `보류: PR #<pr>(<repo_short>) — 반송 뒤 워커 ⚠` |
| no output (exit 1 — no judgment) | comment lookup/parse failure | **treat as `active`, touch nothing** + one line in ④ Report, `BLOCKED: 반송 판정 실패 PR #<pr>(<repo_short>)` |

**The `bounced` resume procedure — align occupation before re-firing the transition.** Read the issue side
first with `gh issue view <issue> --repo <repo> --json labels` and branch (the PR side must already carry
`harvesting` or `resume` would not have fired):

- The issue carries `agent:claimed` = **a replacement worker is alive.** Do not fire the transition — treat as
  `active`, touch nothing, and leave one line in ④ Report,
  `보류: PR #<pr>(<repo_short>) — 교체 워커 점유(agent:claimed)`. When that worker stamps `머지 판정: ✅`, the
  next tick's judgment turns `ok` and the marker-table path resumes on its own.
- The issue carries neither `harvesting` nor `agent:claimed` = **a half recovery.** First fire
  `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` once more to align both sides (idempotent, so the
  PR side is a no-op) and continue below. On non-zero, report
  `BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report and stop for this
  tick.
- Both sides carry `harvesting` = a clean recovery. Continue below.

Then re-fire **only the transition call** from ③-1 ⓐ — **do not post the bounce comment again.** If that
retry fails **again**, follow ③-1 ⓐ's failure branch exactly (one recovery call plus
`BLOCKED: 전이 실패 closeout-redispatch …`), leave it as that `BLOCKED:` line in ④ Report, and **touch that PR
no further this tick** (do not retry inside the same tick — no infinite retries). The next tick's `resume`
picks the same spot up again.

**Epic sweep (end of ①, every tick)** — run `"$SCRIPTS/epic-sweep.sh"` with no `cd` (scope is applied
automatically from the loop session cwd's `.loop/repos`). It is a deterministic sweep that finds leaves via
the dedicated `Epic #N` line and closes only epics with **at least 1 leaf, all CLOSED**. Handle each event:

- `closed` — the epic was closed (evidence comment + `--reason completed`). Write it into ④ Report as
  `에픽 종료: #N(<repo short name>, leaf K)` (K = the length of `leaves`).
- `note` — a normal state where **nothing was touched**. **Do not report it.**
- `warn` — the judgment was **deferred** (the leaf search or open-issue listing hit a cap) or a
  lookup/write failed (including a deploy-wait issue's PR lookup). Copy `why` verbatim into ④ Report's warn
  line. A deferral is not a failure, so exit 0 is possible.

exit 1 means this tick had a lookup/write **failure** — the next tick retries, so leave it alone (the
`<!-- epic-sweep -->` marker on the closing-evidence comment guarantees idempotency so comments never stack).
Two exceptions: the `에픽 close 실패(N회 시도)` warn and the `종료 근거 코멘트 실패 + 되읽기 실패` warn (#441)
**may not be retried** by the next tick — copy `why` verbatim into Report so a human closes it or deletes the
marker comment. exit 64 means no scope (`.loop/repos` missing): call it once more naming this tick's repos with
`--repo <owner/repo>`, and if there are still none leave one warn line, `epic-sweep: 스코프 없음`.

(rationale: closeout-rationale §2 · §3)

## ①-b Stuck-PR sweep — lost-finish recovery (every tick)

`closeout-eligible.sh` only nominates PRs **that carry the `머지 판정: ✅` marker**. When a worker dies before
stamping that ✅, the PR piles up forever in the blind spot of **both** eligible.sh and issue-runner Maintain —
this sweep owns that recovery. It runs every tick even while stagnated. ✅ freshness is guarded in two layers
(`finish-classify.sh`'s proof that the verdict postdates head + `bounce-state.sh`'s bounce-marker safety net —
the marker set is the two bounce channels `재디스패치` (this skill's ①-b) and `재검증 실패` (verify-runner ④),
and that array plus its matching rules live in `bounce-state.sh`'s `BOUNCE_MARKERS`, **a single place**), and
comments and head time are read through `pr-comments.sh` and `pr-head-at.sh` respectively, **one place each**
(this avoids the 100-item cap of `gh pr view --json comments|commits` — do not use that path). Read head
time **after** reading the comments.

**Targets**: `me=$(gh api user -q .login)`, then `gh api -X GET search/issues -f q="user:$me
is:open is:pr" -f per_page=100 -f sort=created -f order=asc` (FIFO). For each PR whose head is
`agent/issue-*` and that is **not labeled `full-cycle`** (the human-session lane-ownership mark, #246),
**not labeled `harvesting`**, **not labeled `flow:verify`**, **not labeled `verifying`**
(verify-runner's occupation label — set by `verify-pick` the moment it picks the PR, replacing
`flow:verify`; the `harvesting` twin, #275), **not labeled `needs-human`**, and carries
**no `hold:`-prefixed label**, judge it. The two are **different stops** (#244): `needs-human` means a
human set the stop by hand, while `hold:<reason>` *is* the machine stop (verify-held · closeout-blocked ·
the dispatcher's runner-held repair cap). Never pick a PR until that label comes off — released by a
human (`hold:conflict` · `needs-human`) or by the resume sweep (`hold:ladder`, and a `hold:policy` that
passed re-review). The test is on the **prefix**, so new reasons (`hold:<new>`) do not break it and
`holding`/`on-hold`/`area:hold` do not match. **A `flow:verify` (awaiting verification) or `verifying`
(verification running) PR belongs to verify-runner — never pick it here.** This target filter runs
**first**, ahead of the 1) CONFLICTING branch as well (#206). `closeout-eligible.sh` carries the same
four-label filter — fix one without the other and the sweep and the candidate gate diverge.

**1) The bounce-marker gate comes first — before branching, common to CONFLICTING and MERGEABLE** (#218):
run `$SCRIPTS/bounce-state.sh <repo> <pr>` once **before** looking at mergeable. Output is one of `ok` /
`bounced` / `held`. The rule is one line: **among the verdict comments (`머지 판정: ✅`/`⚠ 보류`/`🔄`) that
follow the newest bounce marker, the latest one decides** — ✅ → `ok`, ⚠ → `held`, `🔄` → `bounced`.

- `held`, or **no output (exit 1 — no judgment)** → treat as `active`, **touch nothing**, stop here (do not
  look at mergeable, do not call 2) finish-classify). **The sweep does not promote `held` to needs-human
  either** (#218 second round, human decision (c)).
- `bounced` → **the rule is the same: touch nothing.** Open exactly **one exception branch** (#206):
  - Only when `gh pr view <pr> --repo <repo> --json mergeable` is **CONFLICTING**, classify with 2)'s
    `$SCRIPTS/finish-classify.sh <repo> <pr> [<issue>]`, and if the output is `stale_reverify` or
    `stale_inline`, **re-dispatch** (the same action as the `stale_reverify` row of the 2) table — the
    `closeout-redispatch` transition plus the idempotency marker). `stale_inline` is **not** adopted (merged)
    here either.
  - **The bounce marker's timestamp is part of the stale clock too (#308)** — the bounce transition strips
    `agent:claimed`, so in the **label gap right after a bounce, before the dispatcher re-attaches it**, all
    three progress-evidence axes read old/none. In that window `finish-classify.sh` returns `active`, so this
    branch never opens (marker detection is asked back to `bounce-state.sh`, the single place — never a second
    copy of the marker set).
  - **A MERGEABLE `bounced` is always untouched.** Even when CONFLICTING, every other output
    (`active`·`done_verdict`·`held`) is **untouched** — `done_verdict` is the normal ✅ path, owned by
    `closeout-eligible.sh` together with its own bounce safety net.
- Only when the output is exactly `ok` → branch on `gh pr view <pr> --repo <repo> --json mergeable`:
  - CONFLICTING → **adopt (rebase path)**: hand it to ② Pick as a candidate and let ③ step 2 rebase and merge
    it directly (the step-2 conflict path). (finish-classify is skipped.)
  - Otherwise (MERGEABLE etc.) → continue to 2) `finish-classify.sh`.

**A live worker is stopped by finish-classify.** Before emitting any 🔄-family branch that helper asks
`progress-evidence.sh` (the progress-evidence predicate #200 established — ① the newest commit is within
`STALL_MIN` ② that head SHA's CI ticket is alive in the queue ③ **this round's `agent:claimed` was attached
within `ISSUE_TIMEBOX_HOURS`**) and returns `active` when evidence exists. **The predicate lives in that one
file** — the very place `timebox-check.sh` calls — so do not build a second calculator here. **Failing to
judge** progress evidence is also `active` (queue.log unreadable · `pr-head-at.sh` failed · claim lookup
failed — `unknown` ≠ `none`). The claim lookup is `$SCRIPTS/claim-at.sh <repo> <issue>`, **one place** (it
decides attachment by the last matching index in the timeline — the same discipline as `bounce-state.sh`),
which is why 2)'s classification call also takes the issue number (`finish-classify.sh <repo> <pr> [<issue>]` — the head's `agent/issue-N` comes **first** and `closingIssuesReferences` is the fallback).
**Never use the *presence* of `agent:claimed` as an adopt/exclude gate** (#196 item 3) — that judgment is made
by the comment marker alone. The bounce judgment is likewise one place, `bounce-state.sh`, and
`closeout-eligible.sh` calls the same place (no second copy of the logic).

**2) Once the 1) bounce gate returns `ok`, classify deterministically with
`$SCRIPTS/finish-classify.sh <repo> <pr>`** — that helper derives the state from the newest
`머지 판정:`/`검증자 리뷰:` comments and the `STALE_FINISH_MIN` time buffer (reuse the tested helper instead of
hand-parsing comments). **A live worker or an unmet buffer is filtered to `active`, which prevents the race** —
no separate freshness gate is needed:

| finish-classify output | Meaning | Action |
|---|---|---|
| `done_verdict` | newest `머지 판정: ✅` **and that verdict is proven to postdate the current head commit** (#171) | the normal eligible.sh path handles it — the sweep skips. **But if an unresolved hold boundary** (`마감 검증: ⚠ 보류`·`<!-- hold-note: ` — `hold-resolve.sh`'s H token) **sits after that ✅, send it to ①-c instead of skipping** (#334 — the sweep picks up the shape where eligible's unresolved-comment gate blocks a human decision) |
| `stale_inline` | 🔄 + verifier CLEAN + buffer exceeded (verification was reached; only the final verdict was lost) | **adopt (merge)** — hand to ② Pick. ③ step 1 **re-verifies independently** and then closes out. **No new issue** (never redo finished work). But a `stale_inline` that came out of the `bounced` branch in 1) is **re-dispatched, not adopted** |
| `stale_reverify` | 🔄 + verifier missing / unresolved BLOCKER + buffer exceeded + **no progress evidence** (#206) (died before verification, implementation possibly incomplete) | **re-dispatch** — `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` (returns the linked issue to `agent-ready` and strips `agent:claimed` and the stage labels) → a new worker finishes on the same branch via verifier rerun → checkboxes → final verdict. Idempotency marker (below) |
| `no_verdict` | **zero** `머지 판정:` comments + **CI green** (0 failing and 0 incomplete — if even one check is running this is not the class, #421) + buffer exceeded + **no progress evidence** (#396). A comment **lookup failure** is not this class (`active`) | **re-dispatch** — **the same action** as the row above (the cause of death is the same). **If there is no linked issue, touch nothing** — do not fire the transition; put one line in ④ Report so a human sees it |
| `held` | newest `머지 판정: ⚠ 보류` (worker's explicit hold) | **stop (`hold:policy`)** — `$SCRIPTS/transition.sh closeout-blocked <repo> <issue\|-> <pr> --reason policy --note "<질문 한 줄>"` (attaches `hold:policy` to **both** the PR and the linked issue and tidies stage labels. **`needs-human` is not attached** (#244) — the human call-out is attached by `transition.sh policy-kept` only when the resume sweep's ③ re-review ends in "still a human's job"), closeout touches nothing further |
| `active` | in progress · buffer unmet · not our shape, or **✅ freshness unproven** (#171), or **progress evidence exists** (or that judgment itself was impossible) | **touch nothing** (next tick). But with an unresolved hold boundary, send it to ①-c (#334 — a commit with no bounce is a shape ①-c splits into `active`/`ambiguous`) |

**flow:\* auxiliary signal**: an old PR that has `flow:codex`/`flow:ci` but no `flow:ready` is itself evidence
of "worker died mid-verification" (the labels are set by the worker runtime outside this skill — use them as a
hint when present, and judge on finish-classify alone when absent).

**Re-dispatch idempotency marker (required)**: when re-dispatching `stale_reverify`·`no_verdict`, leave a
comment on the PR with `$SCRIPTS/bounce-comment.sh redispatch <repo> <pr> <issue>` (do not transcribe the
wording by hand — if the colon or word order shifts, `bounce-state.sh`'s bounce safety net misses it, #212. The
generated body is `재디스패치: #<issue> — 완결 유실(검증 전 사망) <!-- bodat:worker -->`). **If that marker is
already present and there has been no new commit or verifier comment since, do not re-post** (/loop spam
prevention; the same shape as the step-6 spinoff marker). Re-dispatch eligibility is
`open + agent-ready + ¬agent:claimed` (`eligible-issues.sh`), which the `closeout-redispatch` transition sets
in one move (do not run `gh issue edit` by hand). If either transition exits **non-zero**, report
`BLOCKED: transition failed <transition> PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report per
`references/state-machine.md`'s "common rules for failed transitions" (not restated here). When the
re-dispatch lands, issue-runner Dispatch reuses the existing `agent/issue-N` worktree via make-worktree and
**finishes on the same PR branch**, so no new PR appears.

Adoption candidates (rebase · `stale_inline`) are consumed by ② Pick; re-dispatch and needs-human counts are
tallied in ④ Report.

(rationale: closeout-rationale §4 · §5 · §6 · §7 · §8)

## ①-c Hold-release direction — never mistake "fix it" for "merge it" (right before ② Pick, per candidate)

A human removing `needs-human`·`hold:*` does not mean "merge". A release resolves one of two ways — **reject**
(merge as-is) or **correct** (fix the code) — and the label removal looks identical for both, while the PR's
`머지 판정: ✅` is a verdict on the **pre-hold** code, so the #171 freshness proof, the bounce markers and
eligible all pass normally (measured on bodat PR #4989 — the code a human had just said "fix this" about was one
tick from being merged). So ② Pick runs this section on every candidate (`closeout-eligible.sh` candidates + ①-b
adoptions) **before** picking it (rationale: closeout-rationale §17).

**The judgment is one script call** — it reads comment-array indices (hold boundary `h` · bounce marker `r` ·
completion verdict `f` · decision `D`), current labels (`H` human stop · `A` downstream active lane · `R`
redispatch target state) and the head time (`c`) and picks the branch. The SSOT for the predicates, the order
(resolve → started → idempotent → decision) and the issue-only-boundary rule is that script's header comment.
Do not compare indices by hand here.

```
$SCRIPTS/hold-resolve.sh <repo> <pr> <issue|->     # <issue> = the linked issue from the PR body's Closes/Refs, else -
```

| line 1 | meaning | action |
|---|---|---|
| `pick` | there was no hold, or a new completion verdict landed **after** the hold and the last bounce (and no labels remain) | proceed to ② Pick. If `resume: step2` is attached (`마감 검증: ✅ 기각 승계`), start ③ at **step 2 (merge)** — re-running step 1 reproduces the same P1 and the PR loops hold↔release forever |
| `keep` | the issue or PR still carries `needs-human`·`hold:*` | **touch nothing** — call no transition. Re-calling `closeout-blocked` writes a new hold-note that moves the boundary **past** the decision and discards it. Release = the human removing the labels |
| `restore` | issue-only boundary (no hold-note on the PR side) yet no labels — a shape to repair, not to compare | `$SCRIPTS/transition.sh closeout-blocked <repo> <issue> <pr> --reason policy --note "<the script's note: line, verbatim>"` to **restore both boundaries** (never retype the wording — it has no variable part, so the script emits it). A decision written **before** the restore does not count — the human answers again after it |
| `active` | a worker started after the bounce (new commit), a downstream lane (`agent:claimed`·`flow:verify`·`verifying`·`flow:ready`·`harvesting`) holds it, or the issue is already in the redispatch target state | **touch nothing** — re-post neither marker nor transition (stripping a live lane's labels is the accident PR #239 stopped). Release = that lane's completion verdict (→ `pick`); if the lane dies, `timebox-check.sh` and the #265 stop-mirror warn surface it |
| `recall` | this hold's bounce marker exists but nobody holds it and the dispatcher cannot pick it (only the transition's issue-side edit failed · a human removed `agent-ready`) | **re-call the transition only**, no new marker: `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`. On failure again, `BLOCKED: 전이 실패 재디스패치 PR #<pr>(<repo_short>) — <one stderr line>` |
| `direction` | a human decision after the boundary and no labels — the body (one line) is in the `pr_decision:`·`issue_decision:` lines | read reject/correct/ambiguous with the **direction table** below — the only LLM judgment in this section |
| `ambiguous` | `reason:` — `no_decision` (labels removed, no comment) · `new_commit` (a commit with no bounce and no lane — a human rebased and pushed by hand) · `no_issue` (a bounce marker with no linked issue) | `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<the script's note: line, verbatim — one fixed wording per reason>"`. The new hold-note advances the boundary, so this does not run away. On the **second** ambiguous on the same PR, add `방향 미판정 반복: PR #<pr>(<repo_short>)` to ④ Report |
| `blocked` | `reason:` — `comments_lookup`·`labels_lookup`·`head_lookup`·`comments_parse` | **state unchanged, touch nothing** — `BLOCKED: 보류 판정 조회 실패 PR #<pr>(<repo_short>) — <reason>` in ④ Report. Never send it to `closeout-blocked`: one transient gh failure would pin a human gate on a healthy candidate, and that gate only opens with an answer the human cannot invent. When the lookup succeeds next tick, it just continues |

**Direction table (on `direction`).** If both the PR and the issue carry a decision, the directions must agree;
if they differ it is **ambiguous** (never tie-break by time — second granularity cannot order them). If only one
side has one, read that side.

| direction | signal | action |
|---|---|---|
| **correct** | "the verdict is right" · "narrow / fix / change it" · implementation guidance · a request for more tests — **any sentence asking for a code change**. Agreement mixed with instructions is still correct — the misread costs are asymmetric (reading correct as reject is irreversible; the reverse costs one extra worker tick) | **Marker before transition.** `$SCRIPTS/bounce-comment.sh human-review <repo> <pr> <issue> "<one-line quote of the decision>"` and, **only after it succeeds**, `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` — the marker is in `BOUNCE_MARKERS`, so eligible excludes the PR from the next tick and there is no "transition landed but no marker" window. If posting the marker fails, do not call the transition: `BLOCKED: 전이 실패 재디스패치-마커 PR #<pr>(<repo_short>) — <one gh line>`. With no linked issue there is no lane to bounce to → the `ambiguous` row's action (`--note "시정 방향인데 연결 이슈가 없어 반송 불가"`) |
| **reject** | "the verdict is wrong / a false positive" · "merge as-is" · "no code change needed" is **explicit** and there is **no** correct signal at all | leave `마감 검증: ✅ 기각 승계 — 사람이 판정을 기각(<one-line quote>), ③-1 재실행 안 함`⏎`<!-- bodat:worker -->` on the PR (the step-1 completion marker — next tick's `pick` + `resume: step2` reads it) → ② Pick → ③ starts at **step 2** |
| **ambiguous** | a question only, conditional, or both directions mixed | the `ambiguous` row's action; quote the decision verbatim, one line |

All three actions **quote the decision's sentence verbatim, one line**, in the comment — so history alone answers
"why was this merged / bounced" (a branch with no decision writes `결정문 없음`). If a transition exits 1·2, change
nothing and report `BLOCKED: 전이 실패 <transition> PR #<pr>(<repo_short>) — <one stderr line>`
(`references/state-machine.md`, "common rule for transition failures"). Fold the counts into ④ Report's **existing
counters** — correct into `재디스패치 N`, ambiguous·`restore` into `검증보류 N`; the item line is
`방향 판정: PR #<pr>(<repo_short>, 시정|기각|모호|복구)`.

**Wiring with ①-b.** If a human writes the decision **on the PR** without a marker, `closeout-eligible.sh`'s
unresolved-comment gate (#379) drops that PR from the candidates and this section never gets to run — so ①-b's
`done_verdict`·`active` rows send the PR here instead of skipping when an unresolved hold boundary exists (see
those rows). Making a "labels removed, no decision" stall visible is the job of `loop-status.sh`'s stop-mirror
warn (#265), not this section's.

## ② Pick — 1 PR at a time (MAX_CLOSEOUT=1, concurrency 1)

Merge `$SCRIPTS/closeout-eligible.sh`'s output (normal ✅-marked candidates) with **the ①-b sweep's adoption
candidates** (`stale_inline` · CONFLICTING) and take **only the first candidate, FIFO**. With one at a time
there is no module-overlap judgment to make (serial closeout — ⑤ Drain picks the next candidate only after
this PR is fully closed out). Once picked, immediately declare occupation with
`$SCRIPTS/transition.sh closeout-pick <repo> - <pr>` (the issue number is only parsed in ③-1, so pass `-`
here). The transition attaches `harvesting` and strips the worker/verify-runner stage labels
(`flow:ready`·`flow:codex`·`flow:ci`·`flow:verify`·`verifying`) — `harvesting` is what keeps issue-runner
② Maintain and verify-runner off this PR (verify-eligible also excludes harvesting), and leaving only
`harvesting` in the PR list makes "closing out" unambiguous. If there are 0 candidates, skip ③ and report a
clean no-op in ④ Report. **Before picking, run ①-c (`hold-resolve.sh`) on each candidate** — proceed below only on `pick`; any other
result ends with ①-c's action and you move to the next candidate (#334).

**Missing-label top-up is done by the transition** — the mechanism and the per-site fallback are per the
`references/loop-conventions.md` §8 "label move" row. If the top-up also fails the transition exits 2, so skip
this PR and report `BLOCKED: transition failed closeout-pick PR #<pr>(<repo_short>) — <one stderr line>` in
④ Report (before `setup-labels.sh` is re-run the `harvesting` label may not exist — common to existing repos).

**Origin-issue mirror (progress visibility).** Immediately after ③-1 parses `<issue>` (the PR body's
`Closes #N`/`Refs #N`), if there is a linked issue call
`$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` **again** (idempotent — the PR side already matches
so it is a no-op; only the issue side moves to `harvesting`). **If this mirror call exits non-zero, do not
proceed to the merge** — skip this PR per `references/state-machine.md`'s "common rules for failed
transitions" and report `BLOCKED: transition failed closeout-pick PR #<pr>(<repo_short>) — <one stderr line>`
in ④ Report.

And from ③ onward, **every point where you take your hands off fail-closed** (delegation failure · conflict
needing human judgment · doc reconcile unfinished, etc.) must use the `closeout-blocked` (to a human) or
`closeout-redispatch` (bounce to the worker lane) **transition — never `gh issue edit` by hand**. The
transition table guarantees that `harvesting`·`flow:*` are tidied on both the PR and the issue.
`closeout-blocked` **requires `--reason <conflict|policy|ladder> [--note "<질문 한 줄>" — policy·conflict 필수]`** (without it, usage exit 64 — you cannot create a reasonless stop). A rebase/semantic
conflict is `conflict` (but a security-boundary or wide-scope conflict is `policy` — the judgment in the
step-2 CONFLICTING item, #344; `conflict`'s `--note` is not a question but a one-line worker-resume scope),
anything else the loop cannot decide — spec, policy, or a verdict never produced — is `policy`, and only a
case where you actually climbed a rung of the ladder
(`~/.claude/skills/issue-runner/references/live-verification-ladder.md`) and cited the failure output is
`ladder`.

**The stderr `blocked:` lines from `$SCRIPTS/closeout-eligible.sh` are relayed into ④ Report** (common to all
three loops — `references/loop-conventions.md` §3, #379). `✅ 이후 미해결 코멘트 N건` means "human review
remains **after** the boundary the verifier confirmed (the ✅'s `코멘트 스냅샷 N`, or the ✅ itself when
absent), so it was not picked, fail-closed", and the loop never clears it itself — the only way out is
verify-runner re-verifying and stamping a new ✅. A human reply does not clear it. So the human's job is to
return the PR to `flow:verify` (or have `verifying` re-pick it). Until then the same line repeating every tick
is normal. It is a `막힘` item rather than a `warn` per the channel boundary in
`references/loop-conventions.md` §2.

(rationale: closeout-rationale §9)

## ③ Pipeline — steps 1–6

Perform the 6 steps below in order on the picked PR. Plant the marker command at the end of each step
(① Reconcile's marker table) so the next tick can resume idempotently.
(rationale: closeout-rationale §10–§15)

**Step 1 — plan-conformance verification — `general-purpose` once, no codex (#375).** Obtain `<issue>` from
the PR body's dedicated `Closes #N` / `Refs #N` line (parse with
`gh pr view <pr> --repo <repo> --json body` — the production/consumption convention for that line is
`references/loop-conventions.md` §5). The correctness review was already done by verify-runner with codex
(`머지 판정: ✅` is this step's precondition). Here you look at **plan conformance only**: does this change
satisfy the issue AC / plan, and is there scope creep? The invocation is the single `VERIFIER`
(general-purpose) from ## Constants, and the prompt is `references/verifier-prompt-fallback.md` with its
placeholders filled — `<DIFF>` = the output of `gh pr diff <pr> --repo <repo>`, `<ISSUE_BODY>` = the output of
`gh issue view <issue> --repo <repo>` (empty string when there is no linked issue), `<PLAN_REF>` = the issue's
`## Plan` or the referenced `Plans/*.md` (empty string when absent), `<LESSONS_OR_"없음">` =
**`.loop/lessons-verifier.md`** under the path `$SCRIPTS/repo-dir.sh <repo>` resolves to (the verification
casebook — injects past misjudgment patterns; falls back to `.loop/lessons.md`, and to `none` when both are
missing or empty. `lessons.md` is for the **implementation worker**, so do not mix them). The instruction text
states "judge only whether the plan / issue AC is satisfied; unmet items and scope creep are `[P1]`, minor
deviations `[P2]`". Spawn with `run_in_background` + the `VERIFIER_TIMEOUT_MIN` deadline + `TaskStop` on
overrun. A deadline overrun or a response with no verdict is **no verdict** — retry **once** with the same
prompt, and if it is still absent, end on hold via ⓑ below (fail-closed — never proceed to the merge, #96). A
worktree (`make-worktree.sh`) is not needed at this step — step 3 secures its own.
`codex-review-gate.sh` is not called at this step.
- Verdict: BLOCKER → BLOCKER. CLEAN/NIT/WARN → pass (`[P3+]` = NIT is non-blocking).
  Machine comment marker (required): the closeout-verification comment left by `gh pr comment` below must
  include **`<!-- bodat:worker -->` on its last line** — the production/consumption convention, and the
  consequence of omitting it, are per `references/loop-conventions.md` §4.
- **Duplicate — the loop closes it itself (never hand it to a human).** If the verifier judges "the fix the
  issue asked for is **already on `origin/main`**" or "this PR duplicates another PR", treat it as neither
  BLOCKER nor CLEAN. Confirm the evidence commit (the SHA carrying that fix in `git log origin/<default>`) and
  close it in one line: `$SCRIPTS/transition.sh closeout-dup <repo> <issue> <pr> --note "<evidence commit·reason>"`
  — it closes the PR without merging, closes the issue with the evidence recorded, tidies the stage labels and
  leaves a `dup` label on the PR. **Do not attach `needs-human`.** → **dup exit** (no merge). **If the
  transition exits non-zero**, report
  `BLOCKED: transition failed closeout-dup PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report per
  `references/state-machine.md`'s "common rules for failed transitions". A verdict at the level of "it looks
  like a duplicate" is not dup — if you cannot point at the evidence commit, take the BLOCKER path below
  (`--reason policy`).
- BLOCKER (including no verdict; example reasons `검증자 미산출 — 타임아웃(>VERIFIER_TIMEOUT_MIN분)` / the raw
  model error) → **there are two branches. The test is one line: a defect that closes with implementation is
  ⓐ a bounce to the worker lane; a remaining spec/policy choice is ⓑ a human hold.** (When there is no linked
  issue — the PR body has no `Closes`/`Refs` so `<issue>` cannot be obtained — there is nothing to return, so
  ⓐ is impossible: go to ⓑ.)
- ⓐ **A defect that closes with implementation → bounce to the worker lane.**
  Leave the bounce comment with
  `$SCRIPTS/bounce-comment.sh closeout-blocker <repo> <pr> <issue> "<reason>"` — **do not transcribe the
  wording by hand** (#212 · #171). Write `<reason>` as what is blocked and why, so the worker can read it and
  fix it directly (do not borrow the `redispatch` channel's fixed wording).
  **If the comment exited 0, follow it with**
  `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` to return the linked issue to
  `agent-ready` (it strips `agent:claimed`, the stage labels, `needs-human` and `hold:*` — do not run
  `gh issue edit` by hand) → **`blocked` exit** (no merge; do not invent a new exit state — it is also tallied
  as `재디스패치 N` in ④ Report). When the re-dispatch lands, issue-runner Dispatch reuses the same
  `agent/issue-N` worktree and **finishes on the same PR branch**.
  **If the transition exits non-zero**, report
  `BLOCKED: transition failed closeout-redispatch PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report per
  `references/state-machine.md`'s "common rules for failed transitions", and **immediately fire
  `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` once more to restore occupation on both the PR
  and the issue** (the same call as ③-1's origin-issue mirror — idempotent, and never move labels by hand).
  This branch **always** has a linked issue, so do not call it in ② Pick's `<repo> - <pr>` form. That single
  call reverts **all three** of `transition.sh`'s failure branches (㉠ PR edit succeeded · issue edit failed,
  exit 2 · ㉡ both edits succeeded · PR readback mismatch, exit 1 · ㉢ both edits succeeded · issue readback
  failed, exit 1/2) to their pre-transition state — do not look up state first and split the call (attachment
  is idempotent).
  Once occupation is back to its pre-transition state in all three, the next tick's ① Reconcile picks the PR
  up again as `resume`, and **that resume point is decided by the bounce marker, not the marker table** — per
  ① Reconcile's `resume` value table, while `bounce-state.sh` says `bounced`, skip the marker table and
  re-fire the same transition **at the call site just above** (`closeout-redispatch` is idempotent, so a rerun
  is harmless, #157). If even the restore fails, the two `BLOCKED` lines in ④ Report are the human signal.
  **If the comment exits non-zero (gh failure, bad arguments), do not run `closeout-redispatch`** — with the
  issue back at `agent-ready` and no bounce marker on the PR, the old ✅ picks it up again. **Fold this round
  into ⓑ instead**:
  `$SCRIPTS/transition.sh closeout-blocked <repo> <issue> <pr> --reason policy --note "반송 코멘트 게시 실패 — <one stderr line>"`
  puts it on **human hold** → **`blocked` exit** (do not invent a new exit state). Report
  `BLOCKED: 반송 코멘트 실패 PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report.
  **If that transition also exits non-zero**, do not change the PR's exit state; add one more line,
  `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>`, to ④ Report and
  **touch that PR no further this tick**. The next tick's `resume` takes the marker-table path (the ledger
  holds no bounce trace), and what guarantees ③-1 runs again there is `closeout-step1-marker.sh`'s ⒜⒝⒞
  judgment.
- ⓑ **A spec/policy choice remains (including no verdict — after the single retry) → human hold.**
  `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <reason>
  <!-- bodat:worker -->"`
  + `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  (removes `harvesting` from the PR + attaches `hold:policy` to the PR and the linked issue and tidies stage
  labels — `needs-human` is not attached, #244) → **blocked exit** (no merge). The reason is `policy` (neither
  `conflict` nor `ladder`). A missing verdict is **always this branch.**
  **If the transition exits non-zero**, report
  `BLOCKED: transition failed closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report per
  `references/state-machine.md`'s "common rules for failed transitions".
- CLEAN/WARN → `gh pr comment <pr> --repo <repo> --body "마감 검증: ✅ <CLEAN or WARN n>
  <!-- bodat:worker -->"` (this comment is the step-1 completion marker).
- **Recording a reversed false BLOCKER (lessons).** If this PR already has a prior tick's
  `마감 검증: ⚠ 보류 — …` BLOCKER comment yet this re-verification is CLEAN/WARN, or a human released the stop
  and the original flowed through — that BLOCKER was reversed as a false judgment. Append one line,
  `- [YYYY-MM-DD PR#<pr>] <false-BLOCKER pattern → preventive action>`, to
  **`.loop/lessons-verifier.md`** under the path `$SCRIPTS/repo-dir.sh <repo>` resolves to and trim to the
  cap — **call the one place, `$SCRIPTS/lessons-trim.sh append <file> 20 "<line>"`** (it creates the file
  when missing). **Never append outside that call** (#208). **Cap: 20 entries** — when exceeded, delete whole
  entries oldest-first **until the entry count is at or below the cap** (an entry is one line starting with
  `- [`, or a `##` header through to just before the next entry — not line-by-line). If it is not a reversal
  (a normal CLEAN), record nothing.

**Step 2 — merge gate.** The merge command **must pass `--repo <repo>`** — closeout merges PRs in repos
outside cwd, so the ci-gate hook has to query that repo via `--repo` or it hits fail-closed (#47). Gate
conditions: `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` (exit 0) + the worker's `검증자 리뷰:` comment has 0
BLOCKERs + re-confirm `gh pr view <pr> --repo <repo> --json mergeable` ≠ CONFLICTING.
- **Re-verifying a rebased HEAD (`revalidate:true` pre-gate, #70).** If the candidate ② Pick took has
  `revalidate` true (= `closeout-ci-pass.sh` exited 2 — the current HEAD's local CI cache is empty, i.e. "not
  a fail but never run"), re-verify the current HEAD **before** judging the exit-0 gate above: one call to
  `$SCRIPTS/make-worktree.sh --sync <repo> <N>` secures the worktree and **force-syncs it to the rebased
  remote head** (`<N>` = parsed from the PR head `agent/issue-N`, same as step 3. The sync procedure and the
  trap that "an existing worktree is returned as-is and may still have the pre-rebase SHA checked out" are
  owned by that script's header comment — #445). If `--sync` exits **3 (uncommitted changes in the worktree —
  nothing was overwritten)** or **4 (no such head branch on the remote)**, do not merge: skip this PR and
  report `BLOCKED: worktree 동기화 실패 PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report.
  Then fill the **current HEAD** cache with `$SCRIPTS/run-local-ci.sh <repo> <N>`. If `run-local-ci.sh` exits
  non-zero (integration with the new base is broken), do not merge — end on hold, fail-closed
  (`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  + `blocked` exit, no new exit state — if that transition exits non-zero, report
  `BLOCKED: transition failed closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report per the
  "common rules for failed transitions"). On 0 the cache is filled as pass, so join the exit-0 gate below.
  This path fires **regardless of whether step 3 made a doc commit.** (With `revalidate:false` the cache is
  already pass, so skip this re-verification.)

If everything passes, **perform step 3 (doc reconcile) here first** to create and push the doc commit on the
PR branch — so the squash merge includes it — and then run
`gh pr merge <pr> --repo <repo> --squash` (the ci-gate hook judges once more). That is, the step numbers run
1→2→3, but the step-3 commit is inserted just before the step-2 merge (step 3's header "before the merge" is
that insertion point). **Just before `gh pr merge`, if step 3 pushed a new doc commit**, re-confirm that
`$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` is pass (exit 0) with bounded polling (e.g. every 2–3 s, at most 5
times; never wait indefinitely) — step 3's `run-local-ci.sh` fills the cache synchronously so it is usually
pass immediately — and if pass is not reached within the bound, do not merge and end on hold, fail-closed
(the same path as step 3's cache non-zero/unreached handling — the `closeout-blocked … --reason policy`
transition + `blocked` exit).
**Immediately after `gh pr merge` succeeds**, call `$SCRIPTS/cleanup-worktree.sh <repo> <N> --merged` to clean
up this PR's worktree (`agent/issue-<N>`) directly. `--merged` relaxes the unpushed guard for the trap where a
squash merge auto-deletes the remote head and `@{u}` disappears (the dirty guard stays — if dirty, warn and
defer, best-effort).

- **CONFLICTING → closeout rebases and proceeds itself.** Do not skip. Keeping `harvesting` occupation:
  `$SCRIPTS/make-worktree.sh <repo> <N>` to secure the worktree (`<N>` = head `agent/issue-N`) →
  `git -C <wt> fetch origin` → `git -C <wt> rebase origin/<BASE>` (`<BASE>` = the default branch).
  **If a conflict arises, spawn a rebase-repair agent synchronously** (read the worker template at
  `~/.claude/skills/issue-runner/references/worker-template.md`, fill its placeholders, but replace the
  "procedure" instruction with "in this worktree (`<WT_PATH>`), rebase onto `origin/<BASE>`, resolve the
  conflicts faithful to the original intent, `git push --force-with-lease`, **no merge commits**. **If you
  cannot resolve it, `git rebase --abort` and write in your exit report ⑴ the list of conflicting files (all
  paths) ⑵ why it exceeds the rebase scope — the extra work required (e.g. a guard on a new branch + 1 test
  that bites)**", keeping the push discipline and prohibitions. The agent's scope is "the rebase and only the
  test alignment it breaks") → after the agent exits, regenerate the rebased HEAD cache with
  `$SCRIPTS/run-local-ci.sh <repo> <N>`. On non-zero (integration with the new base is broken), do not merge —
  **delegate fail-closed**: `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` returns the
  linked issue to `agent-ready` (or spins one off) and hands it over; blocked exit. On 0, join the exit-0 merge
  gate above and squash-merge normally. If the agent **cannot resolve** the conflict (rebase abort, repeated
  failure), closeout does not resolve a semantic conflict itself (no unattended forced resolution) — instead
  **split the hold reason** (#344). The resume itself is done by the follow-on resume sweep (`hold:conflict`,
  one automatic resume):
  - **`--reason policy`** (a human's job — not an automatic-resume candidate) — if either: ⓐ **security
    boundary** — the conflicting files touch authentication, authorization, session, secret/credential,
    external-input validation, or trust-boundary paths. Use the repo `CLAUDE.md`'s designated
    security-boundary paths if it has them; otherwise, when the file path/name contains `auth`·`session`·
    `secret`·`credential`·`permission`·`policy`, or the agent reported it had to touch such code while
    resolving. ⓑ **wide scope** — **4 or more** conflicting files, or **6 or more** PR-unique commits
    (`git rev-list --count origin/<BASE>..HEAD`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
    — `--note` is the one-line question the human must answer, and must name which criterion (security
    boundary / scope) was hit (e.g. `보안 경계 — lib/auth/session.rb 충돌, 세션 만료 분기 어느 쪽?`).
  - **`--reason conflict`** (the loop will auto-resume it once) — everything else. `--note` is not a question
    but **the one-line scope the resuming worker receives** (the worker-resume-scope sentence form):
    `충돌 <상대 PR #M>·<파일 목록> — 워커 재개 범위: origin/<BASE> 위로 rebase 해 원안 의도대로 해소 + <에이전트가 보고한 추가 작업>`
    (i.e. `conflict <other PR #M>·<file list> — worker resume scope: rebase onto origin/<BASE> resolving per the original intent + <additional work the agent reported>`;
    e.g. `충돌 #5114·client.rb, client_test.rb — 워커 재개 범위: origin/main 위로 rebase 해 원안 의도대로 해소 + proxy_push 분기 before_send: guard + 무는 테스트 1건`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason conflict --note "<워커 재개 범위 한 줄>"`
    If the agent's exit report has no conflicting-file list (the judgment input is missing), it is **not**
    "everything else" — go **`policy`, fail-closed** (note:
    `판정 입력 부재 — 에이전트가 충돌 파일 목록을 보고하지 않음, 워커 재개인가 사람인가?`).
    **A PR with no linked open issue (`<issue>` is `-`) is also `policy`, not `conflict`** (#345).
  Either branch ends in a blocked exit (this path is the only one whose reason is `conflict`). If either
  transition (redispatch·blocked) exits **non-zero**, report
  `BLOCKED: transition failed <transition> PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report per
  `references/state-machine.md`'s "common rules for failed transitions".

**Step 3 — doc reconcile (before the merge, a commit on the PR branch).** Turn the `- [ ]` items in the plan
document sections whose implementation step 1 confirmed into `- [x]`. Commit and push from the PR-branch
worktree (`$SCRIPTS/make-worktree.sh <repo> <N>` secures it — `<N>` parsed from the PR head branch
`agent/issue-<N>` via `gh pr view <pr> --repo <repo> --json headRefName`, idempotent) so the squash merge
includes it (never push to main directly). If there is an epic, leave a progress roll-up comment.
- **Absorbing surface corrections (ride them on the same commit).** Among step 1's verifier WARN/NIT items,
  the **surface-correction** class is not handed to step-6 spinoff issues — **fix it right here** and load it
  onto this commit. **The criterion, what it accepts and what it blocks are one copy in
  `references/loop-conventions.md` §10** (**the same one line** as verify-runner ⓪). If it passes the
  criterion, fix it here; if even one item trips, it is a step-6 issue.
  - **State what you fixed in a comment on the original PR**: `표면 교정(closeout 3단계): <file> — <what>`.
  - If the cache top-up below exits non-zero (local CI failed), **revert that correction commit** and take the
    original fail-closed path.
  - If the verifier raised a BLOCKER, or this PR is heading for a hold or a re-dispatch, do not touch it
    (passing PRs only).
- **Cache top-up (right after the push, option 1).** If you pushed a doc commit, call
  `$SCRIPTS/run-local-ci.sh <repo> <N>` once **right after** (`<N>` = the issue number parsed above — used to
  identify the worktree path `issue-<N>`; different from `closeout-ci-pass.sh`'s `<pr>`). That helper reads
  the worktree HEAD SHA and fills the **main repo slug**'s local CI cache via `repo-dir.sh` — exactly where
  the step-2 merge gate reads. **Idempotency guard before the call**: if
  `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>` is already pass (exit 0), do not rerun `run-local-ci.sh`. If
  `run-local-ci.sh` exits non-zero (= bin/ci failed), the cache was not filled as pass, so do not merge — end
  on hold, fail-closed
  (`$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  + `blocked` exit — if that transition exits non-zero, report
  `BLOCKED: transition failed closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report per the
  "common rules for failed transitions").
- **Single-issue degrade**: if there is no `Plans/*.md` or `## Plan`, skip the doc edit. If there is no epic,
  skip the roll-up. Reconcile only the issue's own checkboxes. With neither, this step is a no-op — **and since
  there is no new doc commit or push, skip the cache top-up too** (there is no new HEAD SHA to fill).

**Step 4 — deploy-lane handoff (dry run).** **closeout does not deploy; it hands a deploy-wait issue to the
deploy-cycle loop.** Fill `references/deploy-check-issue.md` (`<DEPLOY_CMD>` = the repo's deploy entry point,
or "repo deploy procedure" if unknown; `<VERIFY_URL>` = the production base URL — the address the step-5 smoke
drives, or leave blank so step 5 falls back to URL-unreachable; `<LIVE_CHECKS>` = items from the PR test plan
and the issue body marked as **performable only after the merge** — "post-deploy live verification", hardware
/ real-device checks — the sole handoff destination for verification items step 1's verifier excluded from the
merge gate).

**`<LIVE_CHECKS>` must be one of two shapes — no prose.**
- If there is **nothing at all** to step through after the deploy, exactly the single word `없음`. Add no
  explanation after it.
- Otherwise, a **`- [ ]` checkbox list**. One line = one action `e2e-test` steps through once after the
  deploy. Background, rationale and caveats go in `## 변경 요약`; leave only what is to be stepped here.
- **A real-device line requires the prefix mark `[칸 ③]`** — write it as `- [ ] [칸 ③] <action>`. The mark is
  **shape enforcement of the same grade** as `없음` and `- [ ]` (#309). Even when a line moved here after
  failed rung-①② attempts says nothing about "TEST worker", **attach the mark if the rung it is stepped on is
  ③** — the basis for the test is the mark, not the sentence's meaning.
- **A line without the mark must be steppable by Chrome.** If a line is not rung ③ but needs a means outside
  the browser, write that means on the line so ⑦ can step it straight away.

**Before moving them, closeout climbs the ladder once (never move an untried `[ ]` as-is).** Among the
worker's unfinished items, do not move ones **left as bare `[ ]` with no ladder attempt or citation** —
closeout first tries **rung ① (dev server) and rung ② (`bin/dry-run` · AdsPower relay)** from
`~/.claude/skills/issue-runner/references/live-verification-ladder.md` **once each** and then moves them (the
per-actor cap table is `references/loop-conventions.md` §9 — this loop's cap is rung ②). **Rung ③ (the TEST
worker) belongs to `e2e-test` after the deploy.** Leave the rung-①② results alongside so ⑦ does not repeat the
same rung.
- If rungs ①② **produce a verdict**, **remove** that item from `<LIVE_CHECKS>`. Record the basis in a PR
  comment.
- **On failure**, move the item as `- [ ]` but **cite the rung attempted and the failure output (the command
  line + the last 20 lines)**. Put the citation in the `## 변경 요약` section.
- If the environment makes the attempt impossible (no such entry point in the repo, etc.), state that in one
  line in `## 변경 요약`. Never skip the attempt on the strength of "needs real hardware" alone.

**Branch — if you merged, always create a promotion ticket (user decision, 2026-08-16). A merged PR files
exactly one deploy-wait issue, without exception.** Do not judge — test-only or a one-line comment, being
merged means it entered the promotion scope, and that fact must be visible to a human.

- **Issuance command (required form — never substitute prose).** The whole issuance procedure — title shape ·
  body sections · labels · the 3-rung missing-label ladder · label readback right after issuance · the PR
  marker — is **one call to `$SCRIPTS/deploy-wait-issue.sh`** (#446). Do not assemble `gh issue create` by
  hand here:

  ```
  $SCRIPTS/deploy-wait-issue.sh <repo> <pr> --sha <merge SHA> \
    --title "<one-line summary>" --summary-file <change-summary file> --items-file <items file|없음> \
    [--verify-url <production base URL>] [--deploy-cmd <deploy entry point>] \
    [--parent-issue <parent issue#>] [--hardware]
  ```

  **The title regex (`배포 대기: PR #<M>`) · the section names (`## 검증 URL`·`## 라이브/하드웨어 검증 항목`) ·
  `없음` · `(승격만)` are the parsing contract deploy-cycle and deploy-bodat read**, and their SSOT is that
  script's header comment (not this prose — to change a literal, fix its consumers first). What it does: it
  enforces the item shape (either the single line `없음` or **every line** a `- [ ] ` checkbox — one prose
  line and it exits 65 **before issuing**) → appends ` (승격만)` to the title when there are 0 checkboxes →
  issues with `--label deploy-wait` (plus the P inherited via `--parent-issue`, and `needs:hardware` only when
  `--hardware` **and the repo defines it**) → on a missing label, `setup-labels.sh` once + one retry → and
  failing that, **issues with no `--label` at all** to prevent ticket loss → reads the labels back and tops
  them up → leaves the marker `배포 대기: #<number>` on the PR. stdout is the issue number, one line. Omit
  `--verify-url` when `<VERIFY_URL>` is unknown (step 5 falls back to URL-unreachable).
  - **exit 0** → the marker landed too, so **end as approval-required**.
  - **exit 65 (shape violation before issuance — the issue does not exist yet)** — it means `<LIVE_CHECKS>` is
    prose. Move background and rationale into `## 변경 요약`, leave only `없음` or `- [ ]` in the items slot,
    and **call it again**. **Do not end step 4 on exit 65** — if it is still 65 after one more call, move the
    prose to `## 변경 요약` and **issue** with `--items-file 없음` (a `(승격만)` ticket). In that case also
    report `BLOCKED: 배포 대기 항목 형태 위반 — PR #<pr>` in ④ Report.
  - **exit 1 (no issue created)** — report `BLOCKED: 배포 대기 이슈 발행 실패 — PR #<pr>` in ④ Report.
  - **exit 2 (the issue was created — number on stdout)** — labels/marker are off. Report
    `BLOCKED: 배포 대기 이슈 deploy-wait 라벨 부착 실패 — #<번호>` in ④ Report and ask the human for
    **the 3-rung recovery in `references/loop-conventions.md` §8**. Do not stack another attempt at the same
    label edit here (#223). Never pass over it silently.

  `deploy-wait` is both the bucket label `loop-status.sh` uses to separate deploy-waiting from needs-human and
  **the lane mark by which the deploy-cycle loop picks this ticket up** — that one label is mandatory.
  **closeout does not attach `needs-human` (#243, plan stage 2) — do not revert this.** The actor that
  attaches it is deploy-cycle.

**The `<LIVE_CHECKS>` shape discipline still stands** — it no longer decides whether the issue is filed, but
it still decides whether step 5 smokes:

- **If there is at least one checkbox**, that list is the condition for closing the issue, and step 5 checks it
  against a Chrome smoke.
- **If it is `없음`**, append `(승격만)` to the issue title and leave `없음` as-is under
  `## 라이브/하드웨어 검증 항목`. **Skip the step-5 smoke.** The deploy-cycle lane closes this issue once
  promotion is done.

**Do not bundle.** Never merge several deploy-wait issues into one (user decision, 2026-08-13). However many
there are, keep **one PR = one ticket = one vessel with a clear closing point**.

**Step 5 — post-deploy handling (Chrome smoke).** For a deploy issue **whose deploy has been reported** (who
reported it is not asked — the deploy report is left by the deploy-cycle lane), actively run a Chrome smoke
and judge, with no new detection machinery (no polling/timing). Parse `## 검증 URL` (`<VERIFY_URL>`) and
`## 라이브/하드웨어 검증 항목` (`<LIVE_CHECKS>`) from the deploy issue body into
`references/smoke-prompt.en.md`'s placeholders (**substitute that section untouched — do not pre-filter the
marked lines.** The prompt does not step `[칸 ③]`-marked lines and writes them out as `보류`, and **the
counting is done by `$SCRIPTS/smoke-tally.sh` alone**, #448), load the chrome-devtools MCP tools via
ToolSearch, and do the **entry cleanup (idempotent — crash-resume defense): with `list_pages`, close any
smoke page a previous tick left behind before cleanup with `close_page` first.** Then enter `<VERIFY_URL>`
with `navigate_page` and check each item with `evaluate_script`/`take_snapshot` to produce a per-item
pass/fail (mark structure/empty-state checks distinctly from real-data render checks in the result).
- **Tallying is one place, `$SCRIPTS/smoke-tally.sh` (#448).** The arithmetic of mark detection, denominator
  exclusion and hold summation is owned by that script's header comment. Do not count by hand here.
  - **Before the smoke — is there anything to step?** Write the deploy issue's
    `## 라이브/하드웨어 검증 항목` section to a file and call
    `$SCRIPTS/smoke-tally.sh --checks <section file>` (check-mode JSON: `open` · `steppable` · `held_marked` ·
    `skipped`). If `steppable` is 0, **do not launch Chrome.** But **how you end splits in two**:
    - **`open` is 0 (a `없음` section)** → leave the comment `스모크 생략: 밟을 항목 0` and pass it to
      **complete**.
    - **`steppable` is 0 but `held_marked` is not (only marked lines remain)** → do not launch Chrome, but
      **this is not complete.** Leave the comments
      `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다` (`<n>` = `held_marked`) and
      `보류 내역: 표식 <a>건 · 표식 없는 미밟음 0건` (`<a>` = `held_marked`) and **do not close the issue** —
      rung ③ belongs to `e2e-test` (deploy-cycle ⑦) after the deploy.
  - **After the smoke — what did you see?** Collect **only the verdict lines** the prompt produced
    (`<verdict> <original item line>` — the vocabulary is only `pass`·`fail`·`보류`, the grammar is in the
    script's header comment) into a file, call
    `$SCRIPTS/smoke-tally.sh --checks <section file> <result file>` (the original checklist is **the truth of
    the denominator**, #467), and split the branches below on that JSON: `verdict`
    (`green`|`fail`|`held`|`skip`) · denominator `denominator` · holds `held` (breakdown `held_marked` ·
    `held_unstepped`). **Do not look at `verdict` alone** — fail and hold can both be true, so even on the
    fail branch a remaining `held` means the issue is not closed. If `unparsed` or `duplicate` is non-zero,
    that item is counted as a hold and the tick cannot be green — put one line in ④ Report. **On a degraded
    tick where the smoke never ran at all, do not make this call** — degradation is owned by the degrade
    section below.
- **If real-device items remain, do not close even on green (Chrome cannot step rung ③).** The test is the
  prefix mark `[칸 ③]` **and nothing else** — do not invent a new detection predicate here. If `held` is
  non-zero, do not close the deploy issue even when everything else passed; end with the comment
  `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다` (`<n>` = `held`) — rung ③ belongs
  to `e2e-test` after the deploy (`references/loop-conventions.md` §9's per-actor cap table), and closing here
  would end a ticket holding real-device items without the TEST worker ever seeing it.
  - **A hold on an unmarked line is an observation, not an interpretation.** The prompt **actually steps**
    unmarked lines — if it stepped and got something other than expected, `fail` (→ the fail branch below); if
    the means to step it is outside the browser (worker box · `ssh` · driving the AdsPower client · the server
    shell `bin/rails runner` · grepping `log/*.out`) so it **could not even be attempted**, `보류`
    (= `held_unstepped`). Do not read a line's meaning and promote it to real-device. **Do not file a
    follow-up issue for that hold** (#309) — it is not a defect, only a different stepping lane.
  - **Do not attach the mark on their behalf.** Keep the marker wording single, but leave the breakdown as one
    line using the numbers the script produced:
    `보류 내역: 표식 <a>건 · 표식 없는 미밟음 <b>건 — 재고 · 4단계 표식 누락 · 또는 4단계가 수단을 적어 보낸 비-칸③ 줄`
    (`<a>` = `held_marked` · `<b>` = `held_unstepped`).
- **An already-closed deploy issue — skip the smoke.** If the deploy issue is already CLOSED and has a
  verification/deploy-complete comment, treat step 5 as done — do not re-smoke, proceed to the next step (the
  remaining verification items were moved into a `테스트` issue at that time).
- **Degrade — no silent skip.** If the chrome-devtools MCP is absent from the session, or `<VERIFY_URL>` is
  empty or unreachable, skip the smoke and fall back to the deploy lane's (deploy-cycle) human reporting path,
  but leave a `스모크 skip: <reason>` comment on the deploy issue (no hiding omissions). But **"unreachable" is
  used only as a last resort** (#153): if `<VERIFY_URL>` does not open, climb smoke-prompt's retry ladder
  before writing the skip — ① that repo's remote-access address ② an SSH tunnel. **Only when both fail** is it
  unreachable. **Since the browser was never launched there is nothing to clean up — the browser cleanup below
  is a no-op (not a leak).**
- **green (`verdict=green` — all passed + 0 holds)** → comment `✅ 스모크: <n>/<n> 통과`
  (`<n>/<n>` = `pass`/`denominator`) on the deploy issue and the original PR (this comment is the step-5
  completion marker — a resuming tick does not re-smoke). Then remove the `needs-human` label from the deploy
  issue and close it. **If `held` is non-zero this branch does not apply** — `verdict` comes out `held` and
  the real-device section above owns it: tidy the labels only, leave the issue open, and end with the
  `종결 보류: …` comment.
- **fail (`verdict=fail` — at least one `fail`)** — **only lines Chrome actually stepped arrive here.** The
  unstepped lines held fail-closed above are not fails, so exclude them from what is filed below (#309). → Do
  not fix it directly; use the existing issuance path: if auto-fixable, an agent-ready issue via
  `references/spinoff-issue.md` (**the same single call as step 6**,
  `$SCRIPTS/spinoff-issue.sh <repo> <parent-issue#> <parent-pr#> --title "<title>" --body-file <body-file>` —
  inheritance, labels, readback and the marker are inside it. Do not substitute prose here either); if live
  verification is required, a `--label needs-human` issue. If the same failure recurs `REPAIR_RECUR_LIMIT`
  times, escalate to `needs-human` (**exhausted exit**). Do not close the deploy issue. The label name is
  `needs-human` (hyphen) — `needs:human` does not exist as a label and would make `gh issue create` fail
  outright (the colon form is only `needs:hardware`).
  - **Recording a code-unrelated smoke failure (lessons).** If that smoke failure turns out to be unrelated to
    the code (infra outage, flake, a transient verification-URL error), then separately from the issuance path
    above, append one line, `- [YYYY-MM-DD PR#<pr>] <smoke misjudgment pattern → preventive action>`, to
    **`.loop/lessons-verifier.md`** under the path `$SCRIPTS/repo-dir.sh <repo>` resolves to, with the same
    call as step 1 — `$SCRIPTS/lessons-trim.sh append <file> 20 "<line>"`. Failures that turn out to be
    code defects are not recorded here — the issuance path owns those.
- **Browser cleanup — leak prevention (common exit; green, fail and degrade alike).** **After** leaving the
  smoke verdict comment above, close the chrome-devtools pages this tick opened with `list_pages`→`close_page`
  without exception, whichever of the three exits you took (never return before the cleanup). If degrade meant
  the browser was never opened there is nothing to clean up, a no-op (but if an error tab opened because you
  attempted `navigate_page` while judging unreachability, `close_page` that tab too), and a normal no-op tick
  with no smoke target never opens the browser either.

**Step 6 — spinoff issues.** The input is the worker PR body's `follow-up:` items plus the adjacent work
step 1's diff review flagged. **Do not transcribe the input into issues — judge every item first; an issue is
only the last of five branches, ⓔ** (user decision 2026-09-13, #411). The reviewer is input, not the decider —
"codex said P2, so it's an issue" is not a verdict (rationale: closeout-rationale §15).

| Nature of the item | Handling |
|---|---|
| ⓐ Ends inside this PR's files and changes no behavior (comments, terms, anchors, guard tokens, test names — what `references/loop-conventions.md` §10 accepts) | **Absorb** — the class step 3's surface-correction commit should have taken. If it is past the merge and there is no commit to ride, do not issue it; write `흡수 누락:` in the verdict comment below |
| ⓑ A scenario outside the loop's normal operation (a human rewriting history · settings outside the docs · a limit set past its cap) | **Reject** — `기각: <reason>` in the verdict comment |
| ⓒ The target code is being changed by a sibling PR, or the line is no longer in `origin/<default>` at issuance time (check with `git grep`) | If it already merged and the code is gone, **reject**. If the sibling has **not read its body yet** — the linked issue is waiting as `agent-ready` (no `agent:claimed`) or the PR is `flow:verify` (before the verifier picks it — a worker reads the body when its round starts, the verifier when it picks) — **append the finding to the sibling's linked issue body** — `gh issue edit <sibling issue> --repo <repo> --body-file` adding a `## 인접 지적 (closeout 6단계, PR #<origin>)` section + one line of what and why at the end (skip if a section for the same origin PR already exists — idempotent). **Re-read the sibling's state right after the edit** — if another loop claimed or picked it meanwhile (`agent:claimed`·`verifying`), it already read the pre-edit body, so **send this item back to ⓔ** (the race window is seconds, but losing it loses the defect for good). The body is the only **consumed input** (workers read the issue body, the verifier receives `<ISSUE_BODY>`). PR comments are not a channel (#379). closeout does not bounce another lane's PR (ownership). If the sibling is already running (`flow:claimed`·`verifying` — the body has been consumed), past ✅ (`flow:ready`·`harvesting`), or has no linked issue, nobody will read it, so **judge it ⓔ** |
| ⓓ A fork only a human can settle ("one of the two") | **Raise it to a machine-hold state, no issue** — the target must be an **open** issue (the resume sweep scans `--state open` only — a `hold:policy` on a closed issue is never seen): the parent epic (open) → else the deploy-wait issue step 4 filed (if it was closed meanwhile, `gh issue reopen <number> --repo <repo>` first). On that issue run `$SCRIPTS/transition.sh closeout-blocked <repo> <that issue> - --reason policy --note "<the one-line question a human must answer>"` (PR slot is `-` — the origin PR is already merged). That attaches `hold:policy` and leaves the question as a `사람 확인(policy):` comment, which the resume sweep ③ re-review carries into human-wait. A comment alone is invisible to every tick because `loop-status.sh` counts by labels only. One line in ④ Report: `사람 결정 요청 #<number>` |
| ⓔ What remains after ⓐ–ⓓ: a **real defect that must be fixed** — code outside this PR, or inside it when step 3 passed it on as "changes behavior". The source (verifier P2 · a P1 downgraded to WARN as out of scope · worker `follow-up:` items) is not a condition — follow-up items go through ⓐ–ⓓ first too | **Issue** — fill `references/spinoff-issue.md` and file an agent-ready issue with the command below. The body's second line `Spinoff of PR #<pr> (issue #<parent>)` origin line is filled by the script |

Leave the verdict as one comment on the original PR — `파생 판정: ⓐ N · ⓑ N · ⓒ N · ⓓ N · ⓔ N — <branch and one-line reason per item>`
(ending with `<!-- bodat:worker -->`). **That comment is the step-6 completion marker** (① Reconcile marker table) —
post it **last, after every branch action** (ⓒ body edit · ⓓ transition · ⓔ issuance) has succeeded. If the tick is
cut short, the next tick re-runs step 6 for lack of the marker; ⓒ skips when a section for the same origin PR exists
and ⓔ is blocked by the `파생:` marker, so the only repeat is ⓓ's (idempotent) transition. If ⓔ is 0, step 6 ends
with that comment — zero issuance is the normal case.
The whole issuance procedure for ⓔ — inheritance (#261) · the body's first line `Epic #N` · the second line
`Spinoff of PR #<pr> (issue #<parent>)` origin line (#411) · labels · the missing-label fail-closed · readback
right after issuance · the parent PR marker — is **one call to `$SCRIPTS/spinoff-issue.sh`** (#447). Do not
assemble `gh issue create` by hand here.

- **Deciding the parent (the input to inheritance — this is this step's judgment, not the script's).** The
  parent is **the N in the closing PR's head branch `agent/issue-<N>`**, first. Use
  `closingIssuesReferences` only to **cross-check** that N is in that list, or as the **fallback** when the
  head is not in `agent/issue-*` form — `[0]` is not guaranteed to be the branch issue. If you can obtain
  neither, do not pass `-` to the script: **do not file** — report
  `BLOCKED: spinoff parent unknown — PR #<pr>` in ④ Report (never file without inheritance).
- **Issuance command (required form — never substitute prose).** Write the filled `spinoff-issue.md` to a
  file and pass it with `--body-file` (the template is **body-only**, so labels written into it would render
  in the issue body — the script supplies labels on the command line):

  ```
  $SCRIPTS/spinoff-issue.sh <repo> <parent issue#> <parent PR#> \
    --title "<title>" --body-file <body file> [--label <repo-convention label>...]
  ```

  The rules' SSOT is that script's header comment. What it does: reads the parent **once** via
  `spinoff-inherit.sh` to get `epic=`·`priority=` → fills the body's dedicated `<EPIC_LINE>` slot with
  `Epic #N` (a blank line when there is no epic), guaranteeing it is the **first line** → fills the `<ORIGIN_LINE>` slot with
  `Spinoff of PR #<pr> (issue #<parent>)`, guaranteeing it is the **second line** (#411) → issues with
  `--label agent-ready --label spinoff --label "$priority"` plus the convention labels you passed → on a
  missing label, per the `references/loop-conventions.md` §8 "issue filing" row → reads the labels and the
  `Epic #N` first line back and tops them up → leaves the marker
  `파생: #<new number> (Epic #<N|없음> · <P>)` on the parent PR. stdout is the new issue number, one line.
  - **exit 0** — copy the stderr `marker:` line verbatim into ④ Report's `파생` item.
  - **exit 1 (no issue was created · no output)** — unknown parent, inheritance failure, or filing failure.
    Report `BLOCKED: spinoff parent unknown — PR #<pr>` or `BLOCKED: spinoff issuance failed — PR #<pr>` in ④ Report.
  - **exit 2 (the issue was created — number on stdout)** — one of labels/body/marker is off. Report
    `BLOCKED: spinoff issue labeling failed — #<number>` in ④ Report (recovery is a human's job: rerun
    `setup-labels.sh` → `gh issue edit --add-label`). Do not stack another attempt at the same edit here.

  What you pass via `--label` is **the repo convention axis only** (BoDAT's `difficulty:*`·`frontend` (only
  when touching UI)·`needs:hardware` — the label section of the repo CLAUDE.md is SSOT). `agent-ready`,
  `spinoff` and P are attached by the script, so do not pass them again. Do not raise `priority` by hand — to
  raise it, a human raises it per epic (#401).
- **Surface corrections step 3 already absorbed are not filed here.** When one finding mixes surface and code,
  step 3 takes the surface and **only the code part** becomes an issue — do not restate the already-fixed part
  in the issue body.

## ⑤ Drain — continue to the next candidate immediately

**Immediately after** the ③ pipeline drives the picked PR to a terminal state
(success·approval-required·blocked·dup·exhausted), accumulate that PR's result for ④ Report and **go back to
①①-b② without waiting for the next tick**:

- Run ① Reconcile + the ①-b stuck sweep + ② Pick again. If ② Pick **takes a new candidate**, continue
  immediately into the ③ pipeline with that PR.
- If ② Pick has **0 candidates**, the queue is empty — stop draining, report **all PRs processed this tick
  tallied at once** in ④ Report, and schedule the next tick on the `/loop` interval.

Infinite-loop prevention: each iteration reduces the eligible/adoption set by at least 1. If the same PR is
picked twice (unexpected — a missing marker, etc.), skip that PR and report
`BLOCKED: re-selection loop — #<pr>` in ④ Report to break the drain. If a separate cap is needed, one tick's drain
runs at most the length of the eligible snapshot (PRs opened after the snapshot belong to the next tick).

## ④ Report

When the drain ends (② Pick has 0 candidates), report **all PRs processed this tick summed**
(N is this tick's cumulative count): `closed N · verify-hold N · dup-closed N · deploy-wait N · spinoff N · recovered N · re-dispatched N · stale N`
(the Korean report line calls the third one `중복종료 N`).
Count PRs the ①-b sweep adopted to close/rebase as `recovered N` (also reflected in `closed`
if it became that tick's Pick), and `stale_reverify` re-dispatches / `held` needs-human as
`re-dispatched N`.

Below that, **name the numbers item by item**:
`closed: PR #4795(bodat)←#4788 · spinoff: #4823(bodat)←PR #4788 (Epic #4968 · P1) · re-dispatched: #4770(bodat, stale_reverify)`.
Write the spinoff item in the **same shape** as step 6's PR marker comment —
`#<new number> (Epic #<N|없음> · <P>)`.
The repo short-name rule is per `references/loop-conventions.md` §6.
Epics closed by ①'s epic sweep are appended to the same line as
`에픽 종료: #285(runner, leaf 4)` — omit that fragment entirely when none were closed
(`note` is never reported).

**Also report `승격 대기 N커밋` every tick (never omit it).** Do not drop it even on a tick
with zero closeouts — it is the only number a human reads to see whether anything is waiting
to be promoted. If the repo has a promotion pointer branch (`release` etc.), count with
`git fetch origin <pointer> <default-branch>` then
`git rev-list --count origin/<pointer>..origin/<default-branch>`; if the repo has no pointer
branch, write `승격 대기 —` to state that it does not apply. If it is 0, write
`승격 대기 0커밋` verbatim (do not omit — omission and 0 are different).
(The `loop-status.sh` block below also prints promotion-waiting, but this line **stays** —
the duplication is deliberate redundancy given that omission history.)

**Pipeline snapshot (required every tick).** After the lines above, run
`$SCRIPTS/loop-status.sh --post closeout --delta "<this tick's one-line summary>"` and paste its
output verbatim — the pasting discipline (no `cd` · even on a quiet tick) and the exit 1·64
handling are per `references/loop-conventions.md` §7.
- The stderr `blocked: PR #<pr>(<repo>) — ✅ 이후 미해결 코멘트 <n>건(마커 없음 = 사람 리뷰
  대기)` line from `$SCRIPTS/closeout-eligible.sh` (see ② Pick; literally "N unresolved
  comments after ✅, no marker = awaiting human review") is pasted verbatim as a `막힘`
  (blocked) item, one line — not as a warn. It is normal for it to repeat every tick until
  verify-runner re-verifies and stamps a new ✅ (a human reply does not clear it — see ② Pick).

State the 7 exit states — for **each** PR processed (per-PR when the drain handled several):
- **success** — ran steps 1–6, merged the PR, and issued follow-ups (including adopt/rebase recoveries).
- **clean no-op** — ② Pick had 0 candidates, so there was no PR to close (but if there were ①-b re-dispatches it is not a no-op — report `re-dispatched N`).
- **blocked** — step-1 verification was a BLOCKER, or step-2 rebase integration failed, so it is on hold (no merge).
- **dup** — step-1 verification judged it "already on `origin/main`·duplicate", so
  `closeout-dup` closed the PR and the issue without merging (no `needs-human` — the loop
  finished it). Counted as `dup-closed N` (`중복종료 N` in the Korean report line).
- **approval-required** — step 4 issued a deploy issue and handed it to the deploy-cycle lane.
- **exhausted** — the same step-5 failure recurred `REPAIR_RECUR_LIMIT` times,
  escalated to needs-human.
- **stagnated** — quiet for `QUIET_TICKS` consecutive ticks (the ①-b sweep runs every tick even then).

Even after `QUIET_TICKS` consecutive quiet ticks, ①② still run on every tick —
stagnated only affects reporting; no step is ever skipped. (rationale: closeout-rationale §16)

## References

Non-operational notes — they do not affect tick execution.

- Incident history and design rationale: `references/closeout-rationale.md` (§1–§16, **Korean only**). The
  `(rationale: closeout-rationale §N)` line at the end of each section points at that section.
- Role split: issue-runner = the factory that opens work (never merges, preserves
  invariants), closeout = the closing dock (monopolizes merging). The two loops
  prevent conflict via `harvesting` label occupation.
- Deploy lane (deploy-cycle): closeout does not deploy to production or promote
  release — step 4 files a dry-run deploy-wait issue and hands it to the deploy-cycle
  loop, whose ⑦ owns deploying, promoting, real-device testing (rung ③, the TEST worker)
  and closing. The rest — merge, doc reconcile, follow-up issuance — closeout does
  unattended.
- Operation: run closeout as a `/loop` session separate from issue-runner
  (e.g. `/loop 20m /closeout`) — the two coordinate occupation purely by label.
- Dependencies: the deterministic helpers (`closeout-reconcile.sh`·
  `closeout-eligible.sh`·`closeout-ci-pass.sh`·`closeout-step1-marker.sh`
  (the ① marker table's step-1 judgment)·`transition.sh` (label moves)·
  `loop-status.sh` (the ④ Report snapshot)) live in `$SCRIPTS`
  (=`~/.claude/skills/issue-runner/scripts`), and the 3 references
  (`verifier-prompt.md`·`deploy-check-issue.md`·`spinoff-issue.md`) live in
  `skills/closeout/references/`.
- The attempt order, transports and citation rules for anything needing live measurement
  are in `~/.claude/skills/issue-runner/references/live-verification-ladder.md`
  (rung ①dev → ②worker runtime → ③TEST worker → ④human; the basis for the step-4 `<LIVE_CHECKS>` rung-①② attempt and the
  precondition for `--reason ladder`).
