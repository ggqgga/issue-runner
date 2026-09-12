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
  **Fallback**: use `general-purpose` as the verifier if either — (a) the codex
  plugin is missing (the type above is absent from the Agent tool's
  subagent_type list, or the call fails with an unknown subagent type error), or
  (b) codex stalls/fails and produces no verdict (BLOCKER/WARN/NIT/CLEAN) —
  including network block, timeout, or a verdict-less response (demonstrated
  2026-06-24 #54: codex produced no verdict because gh network was blocked in
  the sandbox). **Not the same prompt (#207).** The fallback is invoked with
  `references/verifier-prompt-fallback.md` — the output contract above
  (BLOCKER/WARN/NIT/CLEAN classification) still applies, but the prompt body
  differs from the native path (`references/verifier-prompt.md`): a
  `general-purpose` subagent has no Agent-tool equivalent of `--cd`, so it is
  not scoped to a worktree — its cwd is the loop session's cwd, not the PR's
  worktree. Giving it the native template's "this worktree is current" premise
  would be false, so the fallback template instead embeds the diff, issue body,
  and lessons directly in the prompt (see Step 1 below). If the fallback call
  also produces no verdict, treat it as a BLOCKER and exit on hold
  (gate fail-closed).
- `VERIFIER_TIMEOUT_MIN = 10` — wall-clock cap in minutes per `VERIFIER` (and
  fallback) spawn. Poll against a deadline of spawn time + this value; if the
  deadline is exceeded, cut it off with `TaskStop` and treat it as no verdict
  produced — the guard rail that stops an external-CLI codex stall from
  blocking the tick indefinitely (#96).
- Absolutely forbidden: unattended production deploys (step 4 is a **deploy-lane
  (deploy-cycle) hand-off** — closeout itself never deploys for real) · unattended
  promotion of a production pointer branch (release etc. — pushing a verified SHA to a
  branch that production/workers pull is deploy-grade and belongs to the **deploy lane
  (deploy-cycle)**) · pushing directly to main (doc reconcile also goes through the PR
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
| 1 verify | PR comment (`마감 검증: ✅ 기각 승계` shares it and is caught too — the prefix is `마감 검증: ✅`) | if present, skip step 1. **`마감 검증: ⚠ 보류` does not match** — if only a stale hold marker remains, step 1 (③-1) runs again (#198: leave the prefix at `마감 검증:` and the hold comment matches too, opening a window where a post-hold commit slips into the merge gate unverified) |
| 2 merge | PR `MERGED` | if MERGED, merge is done (includes post-merge worktree cleanup) |
| 3 reconcile | plan-doc diff (merge commit) + epic comment | if in the merge, done |
| 4 deploy | `배포 대기:` comment / `deployed:<sha>` | if present, do not re-request |
| 5 post | `✅ 스모크` comment / deploy issue CLOSED + verification·deploy-complete comment | if present, do not re-smoke (including when the deploy lane (deploy-cycle) finished verification and closed it) |
| 6 spinoff | created-issue number comment | if present, do not re-issue |

**Epic sweep (end of ①, every tick)** — an epic whose leaves are all closed is closed by
**no loop at all** (an epic is never picked up by a worker; it is a sub-issue rollup target).
Run `"$SCRIPTS/epic-sweep.sh"` with no `cd` (the scope auto-applies from the loop session
cwd's `.loop/repos`). It is a deterministic sweep that finds leaves by their dedicated
`Epic #N` body line and closes only epics with **at least one leaf, all CLOSED**. Handle each
event:

- `closed` — the epic was closed (rationale comment + `--reason completed`). Report it in
  ④ Report as `에픽 종료: #N(<repo short name>, leaf K)` (K = the length of `leaves`).
- `note` — a line that **touched nothing** and is a normal state (an old epic with no
  `Epic #N` lines · an epic carrying `deploy-wait`). **Do not report it** — the same line
  every tick buries the real signals.
- `warn` — the judgment was **deferred** (the leaf search hit its cap) or a read/write
  failed. Copy `why` verbatim into ④ Report's warn lines. A deferral is not a failure, so
  exit 0 is possible alongside it.

exit 1 means this tick had a read/write **failure** — leave it alone, the next tick retries
(the `<!-- epic-sweep -->` marker in the rationale comment keeps it idempotent, so comments
never pile up). exit 64 means no scope (`.loop/repos` missing): call it once more naming the
repos touched this tick with `--repo <owner/repo>`, and if there are none, leave one warn line
`epic-sweep: 스코프 없음`.

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

**A ✅ must also answer "which SHA was it about?" (#171).** A bounced PR still carries the ✅
that was written for the very code the bounce was about — leave that alone and closeout merges
the code closeout itself blocked. So `closeout-eligible.sh` never promotes on the presence of a
✅ alone; two layers guard it, both pointing the same way — **do not open unless proven**:

1. Reuse `finish-classify.sh` (never a second copy of the logic) — `done_verdict` only when
   **both** the ✅ comment time and the head commit time were obtained and the verdict is shown
   to postdate the head. A lookup/parse failure is `active`, not a pass (treating failure-to-prove
   as a pass is exactly fail-open on a merge gate).
2. **Bounce-marker safety net** — covers the window right after a bounce, before the replacement
   worker pushes, when the head time is still unchanged. The marker set lives in **one place**
   (`BOUNCE_MARKERS` in `bounce-state.sh`) and holds both bounce channels: `재디스패치`
   (this skill, ①-b) and `재검증 실패` (verify-runner ④). Matching is **start of the first line
   + the shape after the marker**: no literal colon is required (#212). A bounce idiom right
   after the marker (**any run of whitespace** followed by `:` / `#N` / `(` / `[` / a dash / a
   digit, or end of line — #299) is a bounce; if **prose
   continues** (a Hangul particle/ending, or a space plus a word) it counts only when a bounce
   token (`#N` / `attempt` / a dash / `반송`) is present (#221 · #251). Resolution vocabulary
   (`완료` / `해소`) is **kept out of the decision** — giving it a veto over the tokens leaks
   real bounces such as `해소가 필요합니다` / `해소되지 않았습니다` as `ok` (measured in #251
   attempt 2). The axis where a worker's bounce-resolution report started with a marker and
   stalled (#251 ②) is closed by the **wording**, not by the classifier — reports use the
   `반송 반영 …` prefix (`references/worker-template.md` step 10, guarded by `bin/ci`).
   New bounce wording goes in that array and nowhere else. Ordering is
   decided by the **last matching index in the comment array**, not
   by `createdAt` — GitHub comment times are second-granular, so a ✅ and a marker written in the
   same second cannot be ordered by time.

Both layers rest on having seen **every** comment. `gh pr view --json comments` returns only the
**first 100**, with no pagination, so neither helper uses that path — both read through
`pr-comments.sh` (`gh api .../issues/N/comments --paginate`), in **one place**. A PR that bounces
several times piles up worker/verify/closeout comments, so 100 is not a distant number, and being
capped is silently wrong in both directions: a new ✅ past #100 means a mergeable PR never surfaces
as a candidate (a queue that dies quietly), and a bounce marker past #100 slips through the net.

The same cap existed **on the commit side**. `gh pr view --json commits` is GraphQL
`commits(first: 100)`, so commit #101 onward never arrives and `last` is the 100th commit rather
than the head — comparing against that earlier time lets a stale ✅ satisfy `head <= verdict` and
pass. So the head time is read without counting commits at all, through `pr-head-at.sh` in **one
place** (`--json headRefOid` for the head SHA, then a single `gh api repos/<repo>/commits/<sha>`).
That lookup runs **after** the comments are read — taken first, a push landing in between would be
missing from `head_at` and an unverified head would surface as a candidate.

**Targets**: `me=$(gh api user -q .login)`, then `gh api -X GET search/issues -f q="user:$me
is:open is:pr" -f per_page=100 -f sort=created -f order=asc` (FIFO). For each PR whose head is
`agent/issue-*` and that is **not labeled `harvesting`**, **not labeled `flow:verify`**, and **not
labeled `needs-human`**, judge it. A `needs-human` PR is a human hold (`hold:*` reason — verify-held ·
closeout-blocked · the dispatcher's runner-held repair cap); adopting or re-dispatching it here would undo
that hold (#151) — never pick it until a human removes the label. This target filter runs
**first**, ahead of the 1) CONFLICTING branch as well (#206).

**1) Bounce-marker gate first — before the branch splits, common to CONFLICTING and
MERGEABLE** (#218): run `$SCRIPTS/bounce-state.sh <repo> <pr>` once, **before** looking at
`mergeable` at all. Output is one of three values — `ok`/`bounced`/`held` (#218 attempt 2 —
`held` is new). The rule is one line: **among the verdict comments that come after the latest
bounce marker (`머지 판정: ✅`/`⚠ 보류`/`🔄`), the latest one decides** — ✅ → `ok`,
⚠ → `held`, `🔄` → `bounced` (a `🔄` is the strongest evidence that a replacement worker is
working right now, so the worker lane owns it — #218 attempt 4).

- If it is `held` or **there is no output (exit 1 — undecidable)** → treat as `active`,
  **leave it right here** (do not even check `mergeable`, do not call 2) finish-classify).
  A bounce round in flight is owned by the worker lane (fail-closed — open only once
  "not bounced" is *proven*, same direction as #171).
  **The sweep no longer promotes `held` to needs-human either** (#218 second pass — human
  decision (c), see "Why the sweep no longer promotes `held`" below).
- If it is `bounced` → **the rule is the same leave-it** (a bounce round in flight is owned
  by the worker lane). **A PR whose `held` a human just released (labels removed) and whose
  replacement worker resumed with `머지 판정: 🔄` lands here too** — that is the
  `bounced`-side release path (#218 attempt 4). Exactly **one exception branch** opens on
  that leave-it (#206, see "The stranding that narrowing left behind" below):
  - Only when `gh pr view <pr> --repo <repo> --json mergeable` says **CONFLICTING**, classify
    it with 2)'s `$SCRIPTS/finish-classify.sh <repo> <pr> [<issue>]`, and on `stale_reverify`
    or `stale_inline` → **Re-dispatch** (the same action as the `stale_reverify` row of the
    2) table — the `closeout-redispatch` transition plus the idempotency marker). This is the
    shape where the bounce-round worker pushed its fix and then died just before ✅.
  - **`stale_inline` is re-dispatched too, never adopted (merged).** A `검증자 리뷰: CLEAN`
    left on a bounced PR may be from the round **before** the bounce, so adopting it would
    merge code that was just rejected (exactly the direction #196 closed). Leaving it
    untouched instead would keep the very stranding this section removes, one cell over —
    re-dispatching without merging is the only action that satisfies both requirements.
  - **Every `bounced` PR that is MERGEABLE is left untouched.** Opening that side too would
    bring back the misclassification #218 closed (a just-bounced MERGEABLE PR read as
    `stale_reverify` = "died before verifying", stamping a false idempotency marker onto the
    ledger). CONFLICTING is the only exception.
  - Even on CONFLICTING, every other output (`active` · `done_verdict` · `held`) → **leave
    it**. `done_verdict` is the normal ✅ path, owned by `closeout-eligible.sh` together with
    its own bounce safety net.
- Only when the output is exactly `ok` → branch on
  `gh pr view <pr> --repo <repo> --json mergeable`:
  - CONFLICTING → **Adopt (rebase path)**: hand to ② Pick; ③ step 2 has closeout rebase
    then merge (step-2 conflict path). (Skip finish-classify.)
  - Otherwise (MERGEABLE, etc.) → continue to 2) `finish-classify.sh`.

Why in front of the branch, not inside it (#218, measured: bodat PR #5050 / issue #5036): a
gate scoped to the CONFLICTING branch alone (#196) misses a PR that is **MERGEABLE but was
just bounced** — `finish-classify.sh` misclassifies it as `stale_reverify` (died before
verifying) and re-dispatches it, stamping a false idempotency marker
(`재디스패치: #<issue> — lost finish (died before verify)`) onto the ledger.
`finish-classify.sh ggqgga/BodaT 5050` → `stale_reverify`, `bounce-state.sh ggqgga/BodaT
5050` → `bounced` (verify-runner had already bounced that round — `stale_reverify` names the
wrong cause of death). The same overlap happens when verify bounces right after a worker
posts `held` (`⚠ 보류`); pulling the gate ahead of the branch covers CONFLICTING ·
`stale_reverify` · `held` in one place, so a fourth branch would be covered automatically too.

**Attempt 1 → attempt 2 — the reasoning that splits ⓐ/ⓑ** (#218 attempt 2, codex BLOCKER on
re-verify of PR #225): attempt 1 unconditionally short-circuited here on `bounced`. But
`bounced` was carrying two meanings at once — "bounce in flight right now" and "activity has
piled up after the bounce" (the same shape as the PR#168 lesson: one shared sentinel hides
which cause fired). Post-bounce activity splits into two branches:
- **ⓐ replacement worker died (neither ✅ nor ⚠)**: another lane already covers this — the
  bounce transition returns the linked issue to `agent-ready`, so the dispatcher attaches a
  fresh worker, and if that one dies too the timebox judge (`scripts/timebox-check.sh`, #200)
  reclaims the claim and returns it to `agent-ready` again. Not permanent stranding, so **not
  fixed here.**
- **ⓑ a `머지 판정: ⚠ 보류` posted after the bounce**: no lane covers this. The worker
  explicitly signaled "a human needs to decide," but the gate stopped at `bounced` before
  ever calling `finish-classify`, so `held` (→ needs-human) **never ran.** The human signal
  goes silently missing — exactly the shape this sweep exists to recover, so this round
  fixes it.

The split lives **inside** `bounce-state.sh` (no new freshness predicate gets hand-rolled into
SKILL prose) — it is the exact same rule already used for ✅ (last-matching **index**, not
createdAt) applied to ⚠ as well, yielding a third output value `held` (see
`scripts/bounce-state.sh`). `stale_reverify`/`stale_inline`/`done_verdict` still do not get
promoted while `bounced` — ⓐ is already proven non-regressing above, and promoting those
values while `bounced` would resurrect exactly the incident #218 attempt 1 closed (misclassifying
bounced code as finished).

**attempt 4 — how `held` gets *released*** (closeout-verification BLOCKER, PR #225): the `held`
built in attempts 2·3 had **an entry path but no exit.** The candidate set was ✅ and ⚠ only,
leaving `머지 판정: 🔄` out, so this sequence repeated every tick: ⑴ bounce marker ⑵ worker
posts `⚠ 보류` → `held` → `needs-human`+`hold:policy` ⑶ **a human clears the hold and removes
the labels** ⑷ the replacement worker resumes with `🔄` ⑸ next tick: `needs-human` is gone so
the PR is swept again, but the verdict is **still `held`** → `closeout-blocked` fires **again**,
**resurrecting the hold the human just cleared and cutting off the live replacement worker**
(only a `✅` releases it, and it can never get there once cut off). That is the repo's
"loop vs. human" failure (#151) with the direction flipped, and this gate runs on **every**
tick, so the regression repeats silently. The fix keeps the rule and only fills the candidate
set symmetrically — add `🔄`, but map it to `bounced`, **not** `ok` (mapping it to `ok` would
bring back the incident attempt 1 closed: the CONFLICTING branch adopting/rebasing a live
worker's PR).

**Why the sweep no longer promotes `held`** (#218 second pass, human decision (c)): attempt
4's release path only fixes things **after** the replacement worker has already posted `🔄`.
A window remains between ⑶ a human clearing the hold's labels and ⑷ the replacement worker
posting `🔄` — inside that window the comment array is byte-for-byte identical to how it read
at ⑵, so `bounce-state.sh` still returns `held`. That function is a pure function of the
comment array, so it cannot tell "the sweep already consumed this `held` once, attached
needs-human, and a human just released it" apart from "the sweep has never seen this `held`
before" (attempt 2's original target) — both read as the same string. Reading the release off
signals outside the comments (a timeline history, a release marker) was considered and
rejected — a release marker breaks the instant a human removes just the label, and a timeline
history is the wider axis #174's episode key owns (that PR decides "what counts as a release";
this one narrows "who may re-attach after one").

So, (c): **the sweep treats `held` exactly like `bounced` and an undecidable judgment — hands
off, unconditionally** — the promote-to-needs-human branch is removed here entirely. This is a
known regression, accepted on purpose: the original incident attempt 2 closed (a post-bounce
`⚠` never becoming needs-human) comes back **at this specific gate**. One path survives —
a plain `⚠` with **no bounce marker at all** (where `bounce-state.sh`'s `$bi == null` already
returns `ok`) passes this gate as `ok` and still gets promoted by `finish-classify.sh`'s own
`held` row in 2) below, unmodified by this change. That path too keeps **a window where the
next sweep re-attaches the hold from the same `⚠` after a human removed the label** — that
release judgment (the attach↔release episode) is closed in `finish-classify.sh` by #174
(PR #182: after a release it yields `active` instead of `held`). `bounce-state.sh`'s own `held` computation is unchanged (the value is
still correct) — what is retired is only what this one caller (the sweep) does with it.

**Discipline (bitten three times at this spot)**: when you introduce a new terminal state, do
not design only its entry path — build the **exit path in the same change.** Entry-only means
that state undoes the human's release every tick.

Why CONFLICTING originally needed it (#196, measured: bodat PR #5009 / issue #4973): a bounced
PR has no `머지 판정: ✅`, so it never shows up in `closeout-eligible.sh`, and the
finish-classify-skipping CONFLICTING branch had no place of its own to look at bounce markers.
Right after a bounce, `transition.sh` clears the stage labels, so "no stage labels +
CONFLICTING" is not evidence of stranding — it is also the normal shape of a bounce round. In
the real incident closeout adopted a live worker's PR, attached `harvesting`, and ran
`git rebase origin/main` inside that worker's worktree (nothing was lost only because it had
not been pushed yet).

**The stranding that narrowing left behind (#206).** Treating `bounced` as **unconditionally**
leave-it creates a new stranded class: ⑴ a PR is bounced → ⑵ a replacement worker attaches, fixes
it and pushes → ⑶ that worker dies just before ✅, so `handoff-verify` never runs (no stage
labels) → ⑷ main moves meanwhile and the PR turns CONFLICTING. Such a PR falls out of **all three
lanes** — closeout ①-b (bounce marker is latest), verify-runner (no `flow:verify`), issue-runner ②
(CI green, no unresolved comments) — and stays stranded until a human spots it. Stranding beats
damage (which is why the "adopt only on `ok`" predicate stays exactly as it is), but a safety net
that is not **detectable** turns into a silent omission. So `bounced` is not discarded: it is run
through finish-classify so that only the *dead* bounce rounds are routed to re-dispatch.

**Live workers are stopped by finish-classify.** Even when the bounce marker is the latest
comment, a recent commit after it means the attempt-N+1 worker is **alive** — a recurring
false positive in this repo. Before emitting either 🔄-family branch, finish-classify asks
`progress-evidence.sh` (the progress-evidence predicate established by #200 — ① latest commit
within `STALL_MIN`, ② the head SHA's CI ticket still alive in the queue) and returns `active`
when there is evidence. ② matters especially: waiting in the box-wide serial CI queue (#127) is
time the worker cannot control, so a worker can be alive with commits over an hour old (#200
measured 72 and 64 minutes). **The predicate lives in that one file** — the same one
`timebox-check.sh` calls — and no second calculator is built here (`bin/ci` rejects duplicate
`^STALL_MIN=` / `^queue_alive()` definitions). When the evidence itself **cannot be judged**
the answer is also `active`: hijacking a live worker's branch over one failed lookup is not
reversible. "Cannot be judged" covers both an unreadable queue.log and a **failed head lookup
(`pr-head-at.sh`)**: a failed lookup (`unknown`) and an absence of commit evidence (`none`) are
different states, and folding the former into the latter re-dispatches a live bounce round the
moment `gh` hiccups once.

The judgment lives in `bounce-state.sh` **in one place** — both the marker set
(`재디스패치` · `재검증 실패`, first-line match with no literal colon required, split by the
shape that follows the marker — #212 · #221 · #251) and the
rule that ordering is measured by the **last matching
index in the comments array**, not by `createdAt`; `closeout-eligible.sh` calls the same place
(no second copy of the logic).

**The *presence* of `agent:claimed` is deliberately NOT used as a supplementary gate** (#196 item 3, evidence-based):
`reconcile.sh` does **not** strip `agent:claimed` from an issue that still has an open PR (it only
does so as `stale` when the worktree is gone *and* no open PR exists). So the genuinely stranded
CONFLICTING PRs that ①-b exists to rescue carry that label too — using it as an exclusion would
close the whole CONFLICTING adoption lane. It fails in the other direction as well: right after a
bounce, `closeout-redispatch`/`verify-redispatch` remove `agent:claimed`, so until the dispatcher
attaches a new worker there is a window that **is worker-lane-owned with no label**. Wrong both
ways, so **the adopt/exclude decision** rests on the comment marker alone.

**Its *attach time*, however, is used — that is a different signal** (#206 attempt 3, codex
BLOCKER). Presence only says "someone claimed this at some point"; the attach time says **when
the current round started**. A claim the dispatcher attached right after a bounce is minutes old;
a stranded round's claim is hours old. Why this is needed: progress evidence ① (commit freshness)
and ② (CI queue ticket) only exist **after the worker has left something behind**, so neither
covers the window where a replacement worker was dispatched after the bounce but **has not pushed
yet** — in that window every value `finish-classify.sh` sees belongs to the *previous* attempt, so
`stale_reverify` fires and `closeout-redispatch` **strips the `agent:claimed` of the worker that
is working right now.** So progress evidence ③ is: if `agent:claimed` is **attached now** and its
last attachment is within `ISSUE_TIMEBOX_HOURS`, the PR is `active` even with no commits. The
lookup lives in `$SCRIPTS/claim-at.sh <repo> <issue>` **in one place** (attachment decided by the
last matching index in the timeline — the same rule as `bounce-state.sh`), which is why the
classify call in 2) also takes the issue number (`finish-classify.sh <repo> <pr> [<issue>]` — when
omitted it asks once, taking the head's `agent/issue-N` **first** and falling back to
`closingIssuesReferences`). Why that order: what is needed here is not "the issue this PR closes"
but **"the issue this branch's worker claimed"** — `[0]` points at **someone else's issue** when a
PR closes more than one (measured: PR #113 head=`agent/issue-109` refs=`[108,109]` — `[0]` is
#108). Asking that one returns `none` for the claim, silently switching off evidence ③ and
redispatching the worker that is working right now. Why `ISSUE_TIMEBOX_HOURS` as the bound: a claim
older than that is already reclaimable by ① Reconcile's `timebox-check.sh`, so there is nothing to
save here — both places read the same constant and therefore the same boundary. A failed lookup is
`unknown`, not `none` (stripping a live worker's claim over one failed lookup is irreversible).

**2) Once 1)'s bounce gate has passed `ok`, `$SCRIPTS/finish-classify.sh <repo> <pr>` for
deterministic classification** — the helper reads the latest `머지 판정:`/`검증자 리뷰:` comments and the `STALE_FINISH_MIN`
time buffer to emit a state (reuse the tested helper instead of hand-rolled comment parsing).
**A live worker / time-buffer-not-reached is filtered out as `active`, preventing races** — the
freshness judgment is inside the helper (`progress-evidence.sh`, #200 · #206), so callers need no
gate of their own:

| finish-classify output | Meaning | Action |
|---|---|---|
| `done_verdict` | latest `머지 판정: ✅` **and it is proven to postdate the current head commit** (#171) | eligible.sh's normal path handles it — sweep skips. But that normal path must **pass ①-c's direction judgment first** before ② Pick takes it (#198 — a hold a human released with "fix it" is not a merge candidate however fresh the ✅ looks). And **when ①-c's hold boundary is unresolved, do not skip — route it to ①-c** — because if a human writes the decision on the PR without the marker, eligible's `unresolved` gate (#72) drops that PR from the candidate list and ①-c never runs at all (a silent stall). **The boundary is defined in ①-c, in one place** — do not repeat a literal here (a hold that leaves only `<!-- hold-note: `, e.g. `closeout-blocked --reason conflict`, would fall outside a narrower literal and the promised re-entry would never happen) |
| `stale_inline` | 🔄 + verifier CLEAN + past buffer (reached verification, only final verdict lost, #970-type) | **Adopt (merge)** — hand to ② Pick. ③ step 1 **re-verifies independently**, then closes out. **Do not create a new issue** (no redoing completed work). Except: a `stale_inline` coming out of the `bounced` branch in 1) is **re-dispatched, never adopted** (that CLEAN may predate the bounce). |
| `stale_reverify` | 🔄 + verifier absent / unresolved BLOCKER + past buffer + **no progress evidence** (#206) (died before verifying, implementation may be incomplete, #971-type). A CONFLICTING PR whose bounce marker is latest landing here *is* the "died just before ✅ after a bounce" class from 1) | **Re-dispatch** — do not merge unfinished work on codex re-verify alone (user decision). `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` (returns the linked issue to `agent-ready`, strips `agent:claimed` and the stage labels) → a fresh worker completes verifier→checkboxes→final verdict on the same branch. Idempotency marker (below). — if the head commit is fresh (#110, commit freshness folded into the stale clock), it falls back to `active` even when the verdict comment is stale, so a live attempt-N+1 worker isn't misclassified. |
| `held` | latest `머지 판정: ⚠ 보류` (worker's explicit hold — one of ①-c's three **hold boundary** forms) | **If the release already happened** (①-c 2)'s conjunction is true — a decision comment after the window ∧ `needs-human`·`hold:*` currently absent) **send it to ①-c** (correction→`closeout-redispatch` bounce, ambiguous→`closeout-blocked`, rejection→② Pick) — calling `closeout-blocked` again before that **revives, every tick, a hold the human just released** (the spot #225 nailed down — measure only the entry and skip the release path, and the loop fights the human). **If it is not yet released, needs-human** — `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` (attaches `needs-human` + `hold:policy` to **both** the PR and the linked issue and clears the stage labels — the human signal survives even with no linked issue), closeout leaves it (no auto-progress). |
| `active` | in progress · buffer not reached · not our shape, **or the ✅'s freshness could not be proven** (✅ predates the head commit, or either timestamp could not be obtained, #171), **or there is progress evidence** (commit within `STALL_MIN` · the head SHA's CI ticket alive in the queue · **the current round's `agent:claimed` was attached within the timebox** — or that judgment itself is unavailable: queue.log unreadable · head lookup failed · claim lookup failed (`unknown` ≠ `none`), #206 · `progress-evidence.sh`). A MERGEABLE bounce round is already filtered to leave-it by the 1) gate and never reaches here (#218) — the only bounce rounds that arrive here came through 1)'s **CONFLICTING exception branch** (#206), and an undecidable bounce state was filtered there as well (#196). **Do not end here for a PR whose ①-c hold boundary is unresolved** (#198 — the boundary is defined in ①-c, in one place; do not repeat a literal here): ①-c reads the release direction, and if it is *correction* the answer is not `active` (leave it) but a **bounce** (`closeout-redispatch`), and if the direction is *ambiguous* it is `closeout-blocked` (human). Left untouched it simply becomes a candidate again next tick | **If ①-c's hold boundary is unresolved, go to ①-c** (correction→`closeout-redispatch` bounce, ambiguous→`closeout-blocked`, rejection→② Pick) — **otherwise leave it** (next tick). |

**`flow:*` supplementary signal**: finish-classify judges by comments, but a stale PR with
`flow:codex`/`flow:ci` and no `flow:ready` is itself evidence of "worker died during verify"
(the labels are set outside this skill by the worker runtime — use as a supplement when
present; judge by finish-classify alone when absent).

**Re-dispatch idempotency marker (required)**: on a `stale_reverify` re-dispatch, leave the
comment with `$SCRIPTS/bounce-comment.sh redispatch <repo> <pr> <issue>` (do not hand-type the
wording — a dropped colon or reordering lets the `bounce-state.sh` bounce safety net miss it,
#212. The generated body is `재디스패치: #<issue> — 완결 유실(검증 전 사망) <!-- bodat:worker -->`
— the marker word itself stays Korean across both skill languages, see bounce-state.sh).
**if this marker already exists and there has been no new commit / verifier comment since,
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

## ①-c Hold-release direction judgment — never mistake a correction for a merge (every tick, before ② Pick)

A human removing `needs-human`·`hold:*` does **not** by itself mean "safe to merge". A hold is
released in one of two directions, and label removal looks identical in both:

- **Rejection** — "the gate was wrong / merge it as is" → back to the closeout queue.
- **Correction** — "the gate was right / fix the code" → must go back to the **worker lane**.

If nobody reads the direction, the **correction side is a hole from end to end** (#198 field
measurement: bodat PR #4989 / issue #4959). That PR's `머지 판정: ✅` is a verdict on the code
**before** the hold, and since the code never changed the head-commit time is unchanged too, so
#171's freshness proof **passes normally**, and there is no bounce marker
(`재디스패치:`·`재검증 실패:`) yet, so that safety net **passes it too**. All three layers are
open — the very code a human just said "fix this" about gets squash-merged on the next tick, and
the history reads "human gate passed → normal candidate → merged", so nobody can find it later.

So ② Pick runs candidates through this section **before** picking. It applies to **both**
`closeout-eligible.sh` normal candidates and ①-b adopt candidates.

**This section is a gate that holds cells — every cell it holds gets its release path written
next to it.** The recurring failure shape at this spot is "a new gate does not count the release
path of every column it holds" (#225 · #265), so every leave-it / BLOCKED branch below states
**what releases that cell**. Do not add a branch here without one.

**1) Is there an unresolved hold?** Read comments through `$SCRIPTS/pr-comments.sh <repo> <pr>`,
**one place only** (no second copy of the lookup logic; avoids the first-100 cap — same reason as
①-b; `--paginate` lives **inside** that helper, do not pass it as an argument). If the lookup
exits 1 that is a **failed proof**, so do not let it through — go to *ambiguous* in 3) below.

**Take the hold, the marker and the verdict each as an index — the latest one wins.** Do not put
an "does it exist" test at the head of the branch chain; compare indices (the spot #225 nailed
down — an existence test in front makes later branches unreachable).

- **Hold boundary** = the **last matching index** among comments that start with
  `마감 검증: ⚠ 보류` or `머지 판정: ⚠ 보류`, or that contain `<!-- hold-note: `. The worker's own
  `머지 판정: ⚠ 보류` is the same boundary — its release is judged here too (#174 absorbed).
  Measured by **comment array index**, not `createdAt` — GitHub comment times are second-grained,
  so two comments in the same second cannot be ordered by time (the same idiom
  `closeout-eligible.sh` uses for its bounce-marker safety net). **These three forms are the one
  definition site of the hold boundary** — when ①-b's `done_verdict`·`active`·`held` rows say
  "unresolved hold" they point here, and they do not repeat a literal of their own (if the
  definition splits in two, the shape where `closeout-blocked` leaves only `<!-- hold-note: `
  — e.g. ③-2 rebase integration failure with `--reason conflict` — makes ①-b's re-entry condition
  narrower than ①-c's boundary, and the promised "retry next tick" never actually re-enters).
- **Re-dispatch marker** = the **last matching index** among comments starting with
  `재디스패치: #<issue>`, left by the *correction* row in 3) below.
- **Completion-verdict comment** = a comment **starting with** `머지 판정: ✅` or `마감 검증: ✅`,
  **those two only.** `머지 판정: 🔄` (in progress) is what a worker leaves on handoff and is
  **not** a completion; the `⚠ 보류` forms are not completions either — they advance the **hold
  boundary** above. Lump the three together and a single worker handoff comment leaks through as
  a resolution, merging a half-fixed PR.
- **Count the English pairs too** (removing the vocabulary asymmetry) — completion
  `Merge verdict: ✅`, boundary `Merge verdict: ⚠`, in-progress `Merge verdict: 🔄`.
  `bounce-state.sh:302-308` and `finish-classify.sh:140` **already match the English prefixes**.
  No producer emits them today (the producers of a completion ✅ are verify-runner and closeout,
  both hardcoding Korean, and workers are forbidden from posting ✅/⚠ in **both** language
  templates — `references/worker-template.en.md:198`), so this is not a behavior change but
  **keeping the vocabulary aligned with the helpers**. The day an English-verdict producer
  appears, this list is already correct.
- **Compute the boundary per source, in that source's own array.** An index only means something
  inside its own array, so a PR-array index cannot be used against the issue array — since 2)
  below also reads the linked issue, recompute the issue-side boundary in the **issue comment
  array** by the same rule. **If the issue side has no boundary comment at all, the issue side
  offers no decision candidate** (do not scan the whole array — misreading an old comment from
  **before** the hold as a decision, and reading it as rejection, is a straight mis-merge).
  `closeout-blocked` leaves `<!-- hold-note: <reason> -->` on **both** the PR and the issue, so in
  the normal shape both sides have a boundary.
- If no such comment exists at all (PR side) → there was no hold → ② Pick as usual.

**Resolution test ⑴ — only a new completion verdict is a resolution (#198 10:11/P1 axis①).**
In the PR array, if the
**completion-verdict comment's index > `max(hold boundary, redispatch marker)`**
(i.e. a new completion verdict landed **after** the hold **and** after the last bounce),
it is a resolution candidate. Why the comparison base is `max(hold boundary, redispatch marker)`
and not the hold boundary alone: a ✅ **earlier** than the marker is a verdict on pre-bounce code,
so counting it as a resolution the moment it clears the hold boundary reopens the same hole
through the side door.

**Resolution test ⑵ — resolution also requires label absence (conjunction, BLOCKER ②).** Even
when the index condition above holds, **if `needs-human`·`hold:*` is still present on either the
issue or the PR, this is not a resolution** → end the tick with **hold stands · leave it**
(and do not fall through to the start-of-work / idempotency branches either — at the end of those
sits `closeout-redispatch`, which strips `hold:*`, so merely descending is itself a path that
peels off a live human gate). This condition is **the same one** as ⓑ in 2) below — if only 2)
carries it, the resolution path exits to ② Pick **before reaching** 2) and never reads a label at
all. And that bypass is not hypothetical: ①-b's `done_verdict` row routes here **around eligible**
from the sweep (so eligible's `unresolved` / hold exclusion cannot be leaned on), which is exactly
the shape — a human removing only `needs-human` and leaving `hold:policy` (this repo has a
precedent) — where a live human gate gets peeled off.
**Release path**: once the human removes the remaining `hold:*`·`needs-human`, the same index
condition makes the resolution stand on the next tick and it goes to ② Pick — this cell is
released by a human.

**Why label absence gates only the resolution, not the bounce / transition re-call (the asymmetry,
justified).** The two directions do not cost the same. Resolution **opens the merge gate**, so a
failed proof there is irreversible; bounce and transition re-call **return the work to the worker
lane**, where the worst case is one more tick. And putting the same condition on the bounce side
**closes its own release path**: `closeout-redispatch` is a transition that also does `⊘hold`
(removes `needs-human`·`hold:*`), so a **partial failure** that hit only the PR or only the issue
ends in a shape where `hold:*` survives — demand label absence there and the **transition re-call**
in the idempotency branch below (the only path that repairs that partial failure) becomes forever
unreachable, i.e. a permanent stall. So label absence gates **only the opening branch**.

- **Exception — `마감 검증: ✅ 기각 승계`.** If that ✅ is the succession marker left by the
  *rejection* row in 3) below, treat it as a resolution but **still start ③ at step 2 (merge)**.
  The code is still unchanged, so if the merge fails or is interrupted and the PR survives to the
  next tick, re-running ③-1 **reproduces the same `[P1]`** and the hold↔release loop this section
  exists to stop goes around once more. The succession marker itself is the step-1 completion
  marker (isomorphic to ① Reconcile's marker table).

**Start-of-work test — a new commit is a start signal, not a resolution (#198 re-review/P1 +
10:11/P1 axis①).** Call `$SCRIPTS/pr-head-at.sh <repo> <pr>`; **each exit code has its own
destination**:

| `pr-head-at.sh` | meaning | destination |
|---|---|---|
| exit 0 + an ISO8601 value | head commit time obtained | continue with the comparison below |
| **exit 1 (no output)** | **the value could not be obtained** (gh hiccup, shape change) | **raise this tick as `BLOCKED` and stop** — **do not reach the readback branch** below |
| any other exit code / non-ISO8601 output | an undefined outcome | the **same cell** as exit 1 (BLOCKED) |

If the time obtained is **later** than the `createdAt` of the comment at `max(hold boundary,
redispatch marker)`, that is evidence somebody **started**, not that they **finished** →
leave it as **`active` (untouched)** and **leave this tick alone**. Do not rewrite the marker and
do not call `$SCRIPTS/transition.sh closeout-redispatch` again. This is **the same predicate** the
`stale_reverify` row uses (a fresh head commit falls back to `active` even with a stale verdict
comment, so a live attempt-N+1 worker is not misclassified), and it reuses the existing
`pr-head-at.sh` rather than inventing a new helper.
**Release path**: when a new completion verdict lands, the resolution test above releases this
cell. If it never lands, that is a stall, and `loop-status.sh`'s stall-mirror warn (#265) is what
surfaces it.

**With no value, make no reverting judgment (BLOCKER ①-b).** Not reading exit 1 as "no new
commit" is not enough — the old wording said *"treat it as unresolved and **read on**"*
(fail-closed), but the very next branch is the one that **reverts a transition**, and there this
is **fail-open** (with no value at all it reads "the transition did not land" and strips a live
lane). So when the value is missing, do not descend: report
`BLOCKED: head lookup failed PR #<pr>(<repo_short>) — pr-head-at.sh exit <code>` in ④ Report and
**do not change that PR's state**. **Release path**: the next tick continues normally once the
lookup succeeds (the unresolved hold is still there, so the `active`/`done_verdict` judgment
routes it back into this section). If the lookup keeps failing, the same `BLOCKED` line piles up
in ④ Report every tick where a human sees it — it is not a silent stall.

- **This branch used to be a resolution** — "if the head commit postdates the hold, resolved →
  ② Pick" **fired upstream first**, so the 'start ≠ finish' rule set up by the idempotency branch
  below was **never even reached**. The moment a re-dispatched worker pushed its first commit, a
  half-fixed PR went straight to ② Pick. That is why the branch order is part of the contract:
  read **resolution test (completion-verdict comment) → start-of-work test (new commit) →
  idempotency branch**, in that order only.
- The **known cost** of this order: in the cell `(no completion, new commit, marker > boundary,
  no lane label)` the start-of-work test emits `active` first, so the *re-call only the transition*
  arm of the idempotency branch below is not reached (grid row 7). The reach condition is narrow —
  once a transition lands, `agent-ready` survives for the worker's whole lifetime
  (`transition.sh` transition table: `agent-ready` appears in no remove cell), so it only stands
  for "transition failed ∧ a human then committed directly". The direction is fail-closed (no
  mis-merge, a stall), and the **release path** is the #265 stall-mirror warn plus a human. Do not
  flip the order to rescue this cell — that reopens axis①.

**If it was already bounced, do not bounce it again — but split on 'the transition landed', not on
'a marker exists' (idempotency, #198 bounce3/P1 + 10:11/P1 axis②).** If the **re-dispatch marker
index > hold boundary** (a bounce for this hold already went out), do not leave it alone on the
strength of the marker — do one **transition-effect readback**: does the linked issue currently
carry a **downstream active lane label**?

**Downstream active lane labels = `agent-ready` ∨ `agent:claimed` ∨ `flow:verify` ∨ `flow:ready` ∨
`harvesting`** — **every** cell the ladder **after** `closeout-redispatch` leaves on the issue, per
the transition table in `scripts/transition.sh` (`closeout-redispatch`→`agent-ready`, dispatcher
claim→`agent:claimed`, `handoff-verify`→`flow:verify`, `verify-pass`→`flow:ready`,
`closeout-pick`→`harvesting`). **Looking at the two worker-lane labels
(`agent-ready`·`agent:claimed`) only is wrong (BLOCKER ①-a)**: `handoff-verify` **removes**
`agent:claimed` from the issue and adds `flow:verify`, so in the window after a correction worker
has finished and handed off to the verify lane — **tens of minutes**, until the verifier posts its
completion verdict — **neither** of those two labels is present. Re-calling `closeout-redispatch`
in that window **strips the live verify lane's `flow:verify` and throws an already-fixed PR back at
a worker.** The resolution test does not shield it either — there is no completion verdict yet in
that window (a consequence of this section's own contract that ✅ is owned by verify-runner).
**The transition table is the SSOT** — when a new transition starts leaving a cell on the issue,
add that cell to this list.

- **Any one of them present** → the transition landed → a downstream lane owns this →
  **leave this tick alone** (`active`, untouched). Do not rewrite the marker and do not call
  `closeout-redispatch` again. ①-b's idempotency-marker paragraph says "if the marker already
  exists and there has been no new commit / verifier comment since, do not re-issue **the
  comment**" — it does **not** stop the transition from being re-called; through that hole, with
  the code unchanged, every tick's ①-b sweep classified the same PR as `done_verdict`, sent it back
  into this section, and each `closeout-redispatch` re-call stripped `agent:claimed` off the live
  attempt-N+1 worker dispatched in the meantime (measured in the verify lane — the whole
  dispatch-wait + implementation window was a re-call window every tick). **Release path**: when
  that lane posts its completion verdict, the resolution test above releases it; if the lane dies,
  `timebox-check.sh` (claim reclamation) and the #265 stall-mirror warn surface it.
  **The cost of widening** is stated with it — the wider the label set, the more often "the
  transition landed" is true, so the *re-call only the transition* arm gets narrower. That
  direction is fail-closed (a live lane is never touched), and the stall that narrowing costs is
  covered by the two release paths just named.
- **None of them present** → the marker stands but **the transition did not** (in the
  marker-first order only the transition failed, or it was reverted later) → left alone, the issue
  never gets `agent-ready` back and no worker ever comes (permanent stall). The marker is already
  there, so **do not rewrite it — re-call only the transition**:
  `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`. If that fails too, it lands in
  the **same cell** as a marker-posting failure: report
  `BLOCKED: transition failed re-dispatch PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report
  and do not change that PR's state (retried next tick — the unresolved hold is still there, so
  `active`/`done_verdict` routes it back here). **Why both failures must land in the same cell**:
  if only the marker failure is covered by retry and the transition failure is not, that
  **asymmetry** stalls the latter silently forever — the marker is in `BOUNCE_MARKERS`, so
  `closeout-eligible.sh` drops it too and nobody picks it up.
- **The order is the contract** — the **resolution test comes before this branch**. If this branch
  ran first after a worker finished, posted `머지 판정: ✅` and had its lane labels cleared, it
  would misread "no label = transition failed" and bounce a finished PR. The completion verdict
  after `max(hold boundary, redispatch marker)` filters that misreading out first.
- **If there is no linked issue** there is no label to read and no lane to bounce to → send it to
  the human by the **same path as the *ambiguous* row** in 3).
- If there is no such marker at all (first entry into this section) → go to 2).

**2) Did the release actually happen — decision comment ∧ label absence (conjunction, #174
absorbed).** To treat an unresolved hold as void and move on to the direction judgment,
**both must hold**:

- ⓐ **There is a decision comment after the window** — identified by the rule below.
- ⓑ **`needs-human`·`hold:*` are currently absent on both the issue and the PR** — meaning the
  human actually let go. This is the same condition **resolution test ⑵** above requires (defined
  here, in one place).

If both are true, that `⚠ 보류` no longer counts as the latest verdict (void) → go to the 3)
direction judgment. **If either is false, the hold stands** (fail-closed — do not open what is not
proven):

- ⓑ false (**labels are still there**) → the human still has it → **leave it**. Do not re-call the
  transition (it is already held; the call changes nothing). The same applies even if a decision
  comment is already posted — while the labels remain, the human has not let go.
  **Release path**: the human removes the labels.
- ⓐ false (**labels removed with no decision comment**) → go to **ambiguous** in 3) below. The
  `closeout-blocked` called there re-attaching the labels *is* the **hold standing**. Stalling this
  way is the intended outcome, and surfacing the stall is not this section's job but that of
  `loop-status.sh`'s stall-mirror warn (#265).

**Timeline event lookups, attach↔release pairing and `pr-hold-released-at.sh` are not used.** #174
went four rounds on that approach (label-name enumeration A merely moved to event-pair enumeration
B) and a human retired it — do not bring PR #182's code here. The two conditions above are decided
from the **existing comment array and the current labels** alone.

Once it is void, **the direction judgment is exactly rule 3) below** — rejection → ② Pick (do not
re-run ③-1), correction → `closeout-redispatch` + bounce marker, ambiguous → `closeout-blocked`.

**Identifying the decision comment.** Among the comments **after that source's own** hold-boundary
index, a comment is a decision candidate if it is either of the two below, and the **last matching
index** among them is taken (boundary computation follows 1)'s "per source" rule):

- a comment **without** the `<!-- bodat:worker -->` marker (written by a human directly), or
- a `<!-- policy-review: resumed -->` marker comment — the spot in the re-review procedure where
  **the loop removed the labels itself**, so its body *is* the release decision.
  `<!-- policy-review: kept -->` means "still the human's — labels untouched", so it is **not** a
  decision comment (follow resume-sweep's `resumed`/`kept` convention exactly — do not invert it).

**Pull from the PR and the linked issue separately** by this rule. `pr-comments.sh` reads
`issues/<n>/comments`, so an issue number is **the same call**
(`$SCRIPTS/pr-comments.sh <repo> <issue>`). In the field measurement (#198) the decision was on
**the issue, not the PR**, and it even carried the `<!-- bodat:worker -->` marker
(`재심: 좁힌다 — … <!-- policy-review: resumed --><!-- bodat:worker -->`). Look only at the PR, or
only for "comments without the marker", and you find **no** decision at all, so every case falls to
ambiguous.

- If the two directions pulled from both sides **agree**, that is the direction.
- **If only one side has a decision** (the other has no candidate), **adopt the direction of the
  side that has one.** Even with a linked issue, the decision may be posted on only one of the two
  (#198's field fixture is exactly this shape — the decision on the issue, no PR comment). This is
  different from "neither side has one" (below) — do not fall to ambiguous because of the empty
  side; **read the side that has one.**
- **If both exist and disagree, it is ambiguous** (do not tie-break by time — second granularity
  cannot separate them).
- **If neither exists** (the human removed labels without a comment) it is **ambiguous**.
- **If there is no linked issue**, judge on the PR side alone (no issue-side candidate). If that
  yields *correction*, there is no lane to bounce to, so send it to the human by the **same path as
  ambiguous** in 3) (see the correction row).

**Caution — a decision written on the PR without the marker stops this section from running at
all.** `closeout-eligible.sh`'s `unresolved` gate drops a PR from the candidate list if it has even
one comment without `<!-- bodat:worker -->` (#72). If a human writes the decision **on the PR**
directly, that PR never appears in the eligible list and ①-c never gets a chance to run — the
direction is fail-closed (no mis-merge) but it becomes a **silent stall** nobody picks up. That is
why the ①-b sweep, even on `done_verdict`, **does not skip when there is an unresolved hold and
routes it here instead** (see the `done_verdict` row above) — the sweep picking up the shape
eligible cannot emit is the point of this wiring.

**3) Split the direction.** Read the *conclusion* of the decision comment's body and end in
exactly one of these three:

| Direction | Signal read | Action |
|---|---|---|
| **Correction** | "the gate was right" · "narrow it / fix it / change it" · implementation instructions · a request for more tests — **any sentence telling you to change the code** | **Fixed order — the marker comes before the transition.** First leave `gh pr comment <pr> --repo <repo> --body "재디스패치: #<issue> — 사람 재심이 시정 방향(<one-line quote of the decision>)`⏎`<!-- bodat:worker -->"` on the PR, and only **after that posting succeeds** call `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`. That marker is in `BOUNCE_MARKERS`, so later ticks' `closeout-eligible.sh` excludes it automatically — putting the marker first removes the window where "the transition succeeded but the marker comment failed, leaving a stale `머지 판정: ✅` with no exclusion marker" (#198 bounce1: in that window the next tick behaves exactly as if the direction judgment had never run). **If the marker comment's posting fails, do not call the transition** — report `BLOCKED: transition failed re-dispatch-marker PR #<pr>(<repo_short>) — <one gh failure line>` in ④ Report, isomorphic to ①-c's other transition failures (leaving that PR's state unchanged for a next-tick retry — the unresolved `마감 검증: ⚠ 보류` is still there, so the `active`/`done_verdict` judgment routes it back into this section next tick, #198). **Do not ② Pick.** — **If there is no linked issue** this transition cannot be called (`closeout-redispatch` requires an issue number: there is no `agent-ready` to restore). With no lane to bounce to, take the **same action as the ambiguous row** below and put `시정 방향인데 연결 이슈가 없어 반송 불가` in `--note`. |
| **Rejection** | the conclusion **explicitly** says "the gate was wrong / false positive" · "merge as is" · "no code change needed", and **not one** correction signal above is present | **② Pick it.** But **do not re-run ③-1** — the code did not change, so the same `[P1]` comes back and this PR circles hold↔release forever (the spot #174's "infinite loop" section nailed down). Leave `마감 검증: ✅ 기각 승계 — 사람이 판정을 기각(<one-line quote>), ③-1 재실행 안 함`⏎`<!-- bodat:worker -->` on the PR as the **step-1 completion marker** and start ③ **at step 2 (merge)**. The existing `머지 판정: ✅` joins the step-2 merge gate unchanged. |
| **Ambiguous** | questions only with no conclusion · conditional · both directions mixed · no decision comment · comment lookup failed | Send it back to the human with `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<one line: is the conclusion rejection or correction?>"` (fail-closed — do not open what is not proven). **Do not ② Pick.** — this transition leaves a new `<!-- hold-note: policy -->` which advances the hold boundary, so it does not run away every tick (label re-attachment also drops it from eligible). But if the human **again** removes labels without a comment, the same ambiguity repeats — on a **second ambiguity for the same PR**, write `--note` as **options** rather than a question (`기각(원안 머지) / 시정(코드 수정) 중 하나로 답해 주세요`) and leave `방향 미판정 반복: PR #<pr>(<repo_short>)` on the ④ Report item line so the human sees the repetition. |

**Correction is the default.** A decision often carries both agreement ("the gate was right") and
instruction ("fix it like this") — the field re-review comment **upheld** the BLOCKER while also
writing four implementation instructions. If there is even one sentence telling you to change the
code, **do not read it as rejection.** The two misreadings cost asymmetrically: reading a
correction as a rejection merges code a human asked to be fixed and cannot be undone, while
reading a rejection as a correction costs one more worker tick.

**Quotation duty.** All three actions quote **one line of the decision verbatim** in their comment
— the point of this section is that "why was that merged / why was that bounced" can be answered
from the history alone. **Except that the *ambiguous* row's 'no decision comment' and 'comment
lookup failed' branches are exempt (#198 bounce3/P2)** — there is no sentence to quote in those
two cases, and forcing a quote makes an unattended worker invent one or skip the hold. In those
branches leave a diagnostic in place of the quote: `결정문 없음` when there is no decision comment
at all, `코멘트 조회 실패: <one error line>` when `pr-comments.sh` exits 1.

If a transition exits 1 (readback mismatch) or 2 (gh failure), do not change that PR's state;
report `BLOCKED: transition failed <transition> PR #<pr>(<repo_short>) — <one stderr line>` in
④ Report (isomorphic to ①-b). Tally into ④ Report's **existing counters** (do not invent a new
one) — *correction* into `재디스패치 N`, *ambiguous* into `검증보류 N`. State the judgment on the
item line: `방향 판정: PR #<pr>(<repo_short>, 시정|기각|모호)`.

**Fixtures — this section's judgment is checked against these three.** Being a SKILL change, no
script test reaches here (a script cannot judge the direction of human prose). Fixed examples for
review and regression:

| Fixture | Comment shape after the hold boundary | Expected |
|---|---|---|
| **Correction release** | `마감 검증: ⚠ 보류` on the PR, `재심: 좁힌다 — … 이렇게 고쳐라 <!-- policy-review: resumed --><!-- bodat:worker -->` on the issue, no new commit, no new `마감 검증: ✅` | **no ② Pick** · `closeout-redispatch` + `재디스패치:` marker comment |
| **Rejection release** | same shape but the decision reads `재심: 판정 기각 — 원안 그대로 머지, 코드 변경 없음` | **② Pick** · **no ③-1 re-run** (③ starts at step 2) · `마감 검증: ✅ 기각 승계` marker |
| **Ambiguous** | the decision reads `이거 왜 이렇게 짰나요?` (a question only), or there is no decision comment at all | `closeout-blocked --reason policy` · **no ② Pick** |

**Exhaustive grid — `want` column and the `origin/main` comparison.** This is a narrowing change,
so a green grid of one's own is not evidence (PR#296 lesson: feed the same inputs to the
`origin/main` judge side by side and nail every flipped cell into a `want` column). `origin/main`
has **no ①-c section at all**, so a PR whose hold labels were removed passes
`closeout-eligible.sh` and goes straight to ② Pick — hence the main column is `② Pick` on every
row. The `attempt5` column is the **previous round's design** (closed PR #203 / branch
`agent/issue-198`, head `683cdde2`), and axis④·axis⑤ in the `flipped` column are the cells this
round newly closes (the verifier's BLOCKER ①·②).

`h`=hold boundary · `r`=redispatch marker · `f`=completion-verdict comment (`머지 판정: ✅` ·
`마감 검증: ✅`) · `c`=head commit is later · `L`=the issue currently carries a **downstream active
lane label** (`agent-ready`∪`agent:claimed`∪`flow:verify`∪`flow:ready`∪`harvesting`) ·
`H`=`needs-human`·`hold:*` currently present on the issue or PR · `D`=a decision comment after the
window exists.

| # | Input | `origin/main` | `attempt5` | `want` | flipped |
|---|---|---|---|---|---|
| 1 | no `h` | ② Pick | ② Pick | ② Pick | — |
| 2 | `h`, `f > max(h,r)`, no `H` | ② Pick | ② Pick | ② Pick | — |
| 3 | `h`, only `c` (no `f`), no `r` | ② Pick | **② Pick** | **`active`** | ✅ axis① |
| 4 | `h`, `r > h`, `c` (new commit after the marker), no `f`, `L` present | ② Pick | **② Pick** (upstream fired first, never reached 'start ≠ finish') | **`active`, untouched** | ✅ axis① |
| 5 | `h`, `r > h`, no `c`, `L` present | ② Pick | `active`, untouched | `active`, untouched | — |
| 6 | `h`, `r > h`, no `f`, **no `c`**, **no `L`** (transition failed / lost) | ② Pick | **`active`, untouched → permanent stall** (no worker ever comes) | **re-call only the transition, no marker re-issue** · on another failure `BLOCKED: transition failed re-dispatch` | ✅ axis② |
| 7 | `h`, `r > h`, no `f`, **`c` present**, **no `L`** (transition failed ∧ a human committed directly) | ② Pick | `active`, untouched | `active`, untouched — the start-of-work test comes first (order contract); the stall is surfaced by the #265 warn | — |
| 8 | `h`, marker posting failed (transition not called) | ② Pick | `BLOCKED` · state unchanged · retried next tick | same | — |
| 9 | `h`, no `r`, `D` present, no `H` | ② Pick | 3) direction judgment | 3) direction judgment | — |
| 10 | `h`, no `r`, `D` present, **`H` present** (labels still there) | ② Pick | **proceeds to 3) direction judgment** (② Pick if rejection) | **hold stands · untouched** | ✅ axis③ |
| 11 | `h`, no `r`, **no `D`**, no `H` | ② Pick | ambiguous → `closeout-blocked` | same (= hold stands) · the stall is surfaced by the #265 warn | — |
| 12 | `h`, decision **only on the issue** | ② Pick | adopt the side that has one | same | — |
| 13 | `h`, PR and issue decisions **disagree** | ② Pick | ambiguous | same | — |
| 14 | `h`, `pr-comments.sh` lookup failed | ② Pick | ambiguous (quote exempt) | same | — |
| 15 | `h`, `f` exists but **`f < r`** (a ✅ earlier than the marker) | ② Pick | **resolved → ② Pick** | **`active`** (resolution requires being after `max(h,r)`) | ✅ axis① |
| 16 | release of a worker-posted `머지 판정: ⚠ 보류` | ② Pick | **not counted as a boundary → ② Pick** | counted as a boundary → 2) conjunction → 3) direction judgment | ✅ axis③ |
| 17 | `h`, only a `머지 판정: 🔄` (not an `f`) after it | ② Pick | **leaks through as a completion → resolved** | **not a completion** → `active` / idempotency branch | ✅ axis① |
| 18 | `h`, `r > h`, no `c`, no `f`, the two worker labels **absent** but the issue has **`flow:verify`** (`handoff-verify` landed, before the verifier's verdict) | ② Pick | **re-calls the transition → strips the live verify lane's `flow:verify`** | **untouched** (a downstream active lane owns it) | ✅ axis④ |
| 19 | `h`, `pr-head-at.sh` **exit 1** (no value), the issue has only `flow:verify` | ② Pick | **'read on' → readback branch → transition re-call** (fail-open) | **`BLOCKED: head lookup failed` · state unchanged · untouched** | ✅ axis④ |
| 20 | `h`, `f > max(h,r)`, **`H` present** (the human removed only `needs-human` and left `hold:policy`) | ② Pick | **resolved → ② Pick** (peels off a live human gate) | **hold stands · untouched** | ✅ axis⑤ |

## ② Pick — 1 PR at a time (MAX_CLOSEOUT=1, concurrency 1)

Take the **first candidate** (FIFO) from `$SCRIPTS/closeout-eligible.sh` output (✅-marked
normal candidates) merged with the **①-b sweep's adopt candidates** (`stale_inline` ·
CONFLICTING) — but only those that **passed ①-c's direction judgment** (#198 — if an
unresolved hold was released in the *correction* direction it is not a candidate but a
bounce, and if the direction is ambiguous it goes back to the human). One
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
`Closes #N` / `Refs #N` line (parse via `gh pr view <pr> --repo <repo> --json body`). **Obtain the
worktree (fetch·reset, #207).** Obtain `<worktree>` via `$SCRIPTS/make-worktree.sh <repo> <N>`
(`<N>` parsed from the PR head `agent/issue-N`, same as step 3), then immediately
`git -C <wt> fetch origin` followed by `git -C <wt> reset --hard origin/agent/issue-<N>` to align
the worktree HEAD to the PR's current head SHA (`make-worktree.sh` returns an existing worktree
as-is, so it may still have the pre-rebase/pre-force-push SHA checked out — the revalidate section
below applies the same two commands for the same reason. The plan-conformance prompt below
(`references/verifier-prompt.md`) asserts "this worktree is checked out at the HEAD of the PR
branch under review, so it is current" — without this sync that assertion is false, and a stale
commit gets reviewed while a newer pushed commit reaches merge unreviewed). Verification is
**two synchronous calls** of `$SCRIPTS/codex-review-gate.sh` (#134, Plans/codex-native-review-gate.md) —
no subagent spawn, polling, or `TaskStop` wiring:
1. correctness: `codex-review-gate.sh --base origin/<default> --cd <worktree> --out <scratch>/a` →
   last stdout line `verdict=… p1= p2=`, body in `a/review.md`. `[P1]` = BLOCKER.
2. plan conformance: `codex-review-gate.sh --base origin/<default> --prompt "<instructions>" --cd <worktree> --out <scratch>/b`
   (the helper prefixes the `--base` range to the prompt so the reviewer actually reads the committed diff — without it, only the working tree) —
   the instructions are `references/verifier-prompt.md` with placeholders filled: `<PR>`·`<REPO>`·`<BASE>`=the same
   origin-scoped ref passed to the `--base` flag right above (e.g. `origin/<default>` — not the bare local
   `<default>`; if they diverge and local is stale, the reviewer gets two conflicting range instructions, #207)·
   `<PLAN_REF>`=the issue's `## Plan` or the referenced `Plans/*.md` (empty string if none)·`<ISSUE_BODY>`=
   `gh issue view <issue> --repo <repo>` output (empty string if no linked issue)·`<LESSONS_OR_"없음">`=the contents
   of **`.loop/lessons-verifier.md`** (the verdict casebook — injects past misjudgment patterns; fall back to
   `.loop/lessons.md`, `없음` if both are missing or empty. `lessons.md` is for the **implementing worker** — do not
   mix it in, it dilutes the misjudgment-prevention signal) under the path from `$SCRIPTS/repo-dir.sh <repo>`.
   The diff is not embedded in the prompt — the template (`references/verifier-prompt.md`) states "your judgment
   basis is the `--base` range above; read it directly in this worktree (local git reads allowed, only
   gh/git fetch network commands are forbidden)", so the built-in reviewer reads the worktree itself (#207 — the
   old wording claiming "the embedded diff is the sole SSOT, no git reads" directly contradicted this
   not-embedded contract, so the reviewer saw nothing and reported zero findings — a CLEAN fail-open). The
   instructions state "judge only whether this change meets the plan / issue AC; unmet or out-of-scope = `[P1]`,
   minor deviation = `[P2]`".
   **Response contract (structural line) — `--prompt` calls only.** The helper appends a contract to the end of
   these instructions ("the last line of the review body must be `<key>: reviewed|no-basis`") and decides **on that
   line alone** (`reviewed` → by the finding counts · `no-basis`/line missing/format broken → `verdict=NONE`, no
   verdict). The format string's single definition site is the `STATUS_*` constants in `codex-review-gate.sh` — do
   not copy it into the template or this document (if the required format and the parser diverge, the very
   SKILL↔template mismatch this issue fixed reappears on the parser side, #207). So you never write the contract
   yourself when filling the prompt. Prose ("no basis to judge" wording) is **not** a decision input — enumerating
   its inflections does not converge and produced three consecutive fail-opens (#207 rounds 2-4).
The helper has its own timeout (`CODEX_GATE_TIMEOUT`, default 900s = in step with `VERIFIER_TIMEOUT_MIN`). If either
call returns **exit 2 (`verdict=NONE`) = no verdict** (codex missing · model error · timeout — and, on the plan
conformance call, the reviewer omitting the contract's structural line or answering `no-basis`, #207), only then use the
`VERIFIER` fallback from ## Constants (general-purpose). **The fallback prompt is
`references/verifier-prompt-fallback.md` — not the same file as the native templates above
(`references/verifier-prompt.md`, #207).** A `general-purpose` subagent has no Agent-tool equivalent of `--cd`, so it
is not scoped to a worktree — its cwd is the loop session's cwd, not the PR's worktree. Giving it the native
template's "this worktree is current" premise would be a false premise (demonstrated: a fallback call given that
premise asserted the wrong checkout was "current" while judging). `verifier-prompt-fallback.md` instead embeds the
diff, issue body, and lessons **directly** in the prompt: `<DIFF>` = the output of `gh pr diff <pr> --repo <repo>`,
`<ISSUE_BODY>`·`<PLAN_REF>`·`<LESSONS_OR_"없음">` are filled the same way as the native call. The response contract
(structural line) is not carried into the fallback — that line is appended automatically by `codex-review-gate.sh`
for `--prompt` calls only; the fallback instead follows the plain BLOCKER/WARN/NIT/CLEAN output contract from the
`VERIFIER` entry above (see Constants). Spawn with `run_in_background` + the `VERIFIER_TIMEOUT_MIN` deadline + `TaskStop` on
overrun. If the fallback also produces no verdict, exit on hold via the BLOCKER path below (fail-closed — never
proceed to merge, #96). A model error in the
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
  `$SCRIPTS/repo-dir.sh <repo>`, then trim to the cap — **call
  `$SCRIPTS/lessons-trim.sh append <file> 20 "<line>"` in one place** (create the
  file if absent — this is the verifier's casebook, kept separate from the
  worker's `lessons.md`). **Do not append by hand outside this call** — another
  tick may be trimming the same file concurrently, and an append done outside the
  lock can be lost if it lands in that trim's read→write window (#208
  re-verification BLOCKER②). **Cap: 20 entries** — on overflow, drop the oldest
  entries as whole units **until the entry count is at or below the cap**, not by
  line: this file mixes multi-line cases starting with `##`, and cutting by line
  tears the prose apart (an entry = one line starting with `- [`, or a `##`
  header through just before the next entry). #208: the old rule dropped only
  **one** oldest entry, so append(+1)/delete(-1) netted zero and overflow never
  shrank once past the cap. This record is fed back into
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

**Step 4 — deploy-lane hand-off (dry-run).** **closeout does not deploy for real; it
hands the deploy-wait issue to the deploy-cycle loop.** The reason is not human approval
but **lane separation** — deploying, promoting, real-device testing and closing are owned
by deploy-cycle's unattended cycle. Fill
`references/deploy-check-issue.md` (`<DEPLOY_CMD>`=the repo's deploy entrypoint, or
"the repo's deploy procedure" if unknown; `<VERIFY_URL>`=the production base URL the
step-5 smoke drives — leave it blank if unknown so step 5 falls back as URL-unreachable;
`<LIVE_CHECKS>`=carry over the items from the PR test plan·issue body marked
as **only performable after merge** — e.g. "post-deploy live verification",
hardware/real-device checks; this is the sole hand-off destination
for out-of-merge-scope verification the step-1 verifier excluded from the merge gate).

**`<LIVE_CHECKS>` must take one of two shapes — no free prose.**
- If there is **nothing at all** to step through after deploy, exactly the one word
  `없음`. Do not append an explanation after it.
- Otherwise a **`- [ ]` checkbox list**. One line = one action deploy-cycle ⑦ performs
  once (on real hardware, a TEST-worker profile #18 dry run).
  Background·rationale·caveats go in `## 변경 요약`; leave only the actions here.

Why the shape is enforced: the branch below reads this section to decide whether an issue
is filed at all, and free prose leaves that decision to per-tick interpretation, which
drifts (measured 2026-08-12~13: of 186 deploy-check issues, **zero** used checkboxes —
all prose). A sentence like "없음. 주석 13줄이 전부다 — 관찰 가능한 변화가 없다" is clear
to a human but is not `없음` to a machine branch.

**Before carrying an item over, closeout climbs the ladder once (an untried `[ ]` is not
carried over as-is).** Unfinished items the worker left as a bare `[ ]` **with no rung
attempt and no citation** (no attempted rung, no failure output in the PR test plan) must
not be copied into this section as-is — doing so shoves work nobody attempted straight
into the deploy lane. closeout attempts **rung ① (dev server — `bin/rails runner`·localhost) and
rung ② (`bin/dry-run`·the AdsPower relay)** of
`~/.claude/skills/issue-runner/references/live-verification-ladder.md`
**once each** first. **Rung ③ (the TEST worker) is deploy-cycle ⑦'s job** — that is why
the item moves into `<LIVE_CHECKS>` rather than being escalated into a human's lap, and
the ①② attempt results ride along so ⑦ does not repeat the same rungs.
- If rung ①② **yields a verdict**, **drop** the item from `<LIVE_CHECKS>` (it is not a
  deploy-lane action any more). Record the basis in a PR comment.
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
and that fact must be visible to a human.

- **Issuance command (required form — do not substitute prose).**

  ```
  gh issue create --repo <repo> --title "배포 대기: PR #<pr> — <summary>[ (승격만)]" \
    --body-file <body-file> --label deploy-wait [--label <P1|P2>]
  ```

  `deploy-wait` is the bucket label `loop-status.sh` uses to separate deploy-waiting from
  human-waiting, and it is **the lane mark the deploy-cycle loop picks this ticket up by** —
  that one label is required.
  **`needs-human` is deliberately not attached (#243, plan step 2) — do not revert it.**
  All three consumers of a deploy-pending issue ignore that label: ⑴ the dispatch gate
  **requires** `label:agent-ready` (`scripts/eligible-issues.sh`), which a deploy-pending
  issue never has, so it is not a candidate to begin with; ⑵ the bucket decision at
  `scripts/loop-status.sh:474` lets `deploy-wait` **win over** `needs-human`; ⑶ deploy-bodat
  collects by **title regex** (`배포 대기: PR #<M>`), not by label. All that was left was a
  duplicate mark that blurred what `needs-human` means (= a stop a human raised) (#190).
  After issuance leave the
  marker `gh pr comment <pr> --repo <repo> --body "배포 대기: #<created-number>"`, then
  **exit as approval-required**.
- **Missing label — fail closed, never lose the ticket (same shape as the step-6 spinoff
  rule).** `gh issue create` fails **without creating the issue** when any `--label` does not
  exist in the repo. Existing opted-in repos lack `deploy-wait` until `setup-labels.sh` is
  rerun, so without this rule the first closeout after upgrading ends with the PR merged but
  no ticket and no marker. On a `'deploy-wait' not found`-style failure, run
  `$SCRIPTS/setup-labels.sh <repo>` **once** and retry the same command **once**. If the
  retry also fails, do not loop — file it with **no `--label` at all** (no lost ticket —
  `loop-status.sh` still counts it as deploy-waiting via the `배포 대기:` title fallback).
  The result is an issue with **no labels whatsoever**, and that state is not normal — the
  deploy-cycle loop cannot find it by its lane mark — so
  report `BLOCKED: deploy-wait label attach failed on deploy issue — #<number>` in ④ Report
  and demand a **three-step human recovery** (skipping the second step leaves the ticket
  labelless even if the human does exactly what was asked — `setup-labels.sh` only recreates
  the label *definition*, it never attaches labels to an existing issue): ⑴
  **`$SCRIPTS/setup-labels.sh <repo>` rerun** to restore the `deploy-wait` label definition,
  ⑵ `gh issue edit <number> --repo <repo> --add-label deploy-wait` to attach it **to that
  issue**, then ⑶ `gh issue view <number> --repo <repo> --json labels` to confirm it landed.
  Never pass over it silently.
- **Verify right after issuance (same shape as step 6) — runs only when the issuance
  that carried `--label` succeeded.** Check with
  `gh issue view <number> --repo <repo> --json labels` that
  `deploy-wait` actually landed; if it is missing, top it up with
  `gh issue edit <number> --repo <repo> --add-label deploy-wait`
  (the 8/8 miss behind this fix was not only the command sitting mid-prose — step 4 never
  had this verify step at all, while step 6 did and did not leak).
  **An issue filed by the fallback above with no `--label` at all is excluded from this
  verify·top-up** (#223). On that path the issuance and its one retry both failed, so
  "this repo cannot take the label right now" is already settled — calling the same label
  edit again here just fails again, and that failure cuts off the PR marker
  `배포 대기: #N` and the ④ Report line `BLOCKED: deploy-wait label attach failed …`
  that follow (the ticket exists but nobody knows = exactly the loss the fallback exists
  to prevent). Recovery for a fallback ticket is owned by the three-step human recovery
  above — do not duplicate the attempt here.

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
  `✅ 스모크 0/0 통과` and reads as verified (false green). The deploy-cycle lane closes this
  issue once the promotion is done.

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
- **No items to step through — do not smoke.** Step 4 files a deploy issue for every
  merged PR, so `(승격만)` issues exist too — but if `## 라이브/하드웨어 검증 항목` holds
  no `- [ ]` at all, do not open Chrome; mark it complete. A smoke with zero items to
  compare has not passed anything, it **looked at nothing**, yet it prints as
  `✅ 스모크 0/0 통과` and reads as verified (a false green). Leave the reason as a
  comment instead: `스모크 생략: 밟을 항목 0`. That issue is a container the deploy-cycle
  lane closes once the promotion is done, not a verification subject.
- **Real-hardware items still open — do not close even on green (Chrome cannot step rung ③).**
  Among the `- [ ]` lines in `## 라이브/하드웨어 검증 항목`, a line **whose action is
  ladder rung ③ (a TEST-worker profile #18 dry run)** is a real-hardware item — step 4
  writes those lines exactly that way (the `<LIVE_CHECKS>` shape discipline above), so
  reuse that predicate here instead of inventing a second one. **Drop such lines from the
  `<n>/<n>` denominator** — pretending Chrome compared them makes both a pass and a fail
  a lie (the same false green as "no items" above). If dropping them leaves zero items to
  compare, do not open Chrome — skip the smoke exactly like the "no items" bullet above.
  And if **even one** such line remains, **do not close the deploy issue even when
  everything else passes** — rung ③ is deploy-cycle ⑦'s job, so closing here finalizes a
  ticket whose real-hardware items never met the TEST worker once. Leave the reason as a
  comment instead: `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑦`. That issue is a
  container the deploy-cycle lane's ⑦ closes after it steps rung ③.
- **Already-closed deploy issue — skip the smoke.** If the deploy issue is already
  CLOSED and has a verification/deploy-complete comment, treat step 5 as complete —
  do not re-smoke, proceed to the next step (the case where the deploy lane
  (deploy-cycle) finished verification and closed it — the standard finalization in a
  promotion-model repo).
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
  **Unless the real-hardware exception above applies** — if even one rung-③ item is
  still `- [ ]`, stop at the label cleanup, leave the issue open, and finish with the
  `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑦` comment (verification was not the only
  remaining gate — rung ③ is). Since #243 a step-4 issue
  never carries `needs-human` in the first place — this removal is harmless leftover
  cleanup for issues filed before that (`--remove-label` is a no-op for an absent label).
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
    separately from the publish path above, append and trim one line
    `- [YYYY-MM-DD PR#<pr>] <smoke-misjudgment pattern → recurrence-prevention action>`
    to **`.loop/lessons-verifier.md`** under the path output by `$SCRIPTS/repo-dir.sh <repo>`
    using the same call as step 1 — `$SCRIPTS/lessons-trim.sh append <file> 20 "<line>"`
    (same file and cap as step 1 — it is a verdict-misjudgment class, so it belongs in
    the verifier's casebook. Same loss risk here too — do not append by hand outside
    this call). A failure that turns out to be a code defect is not recorded
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
  the loop — while step 4, whose command literally carries the label (back then
  `--label needs-human`, today `--label deploy-wait`, #243), was
  correct on all 186. The step with a command did not leak; the prose-only step did).
  Attach a priority (`P1`/`P2`) too — without one it sorts last (`P0 > P1 > P2 > none`).
  Add the other axes per repo convention (BoDAT: `difficulty:*`·`frontend` (only when UI is
  touched)·`needs:hardware` — the repo CLAUDE.md label section is the SSOT), but **never let
  convention labels displace `agent-ready`** —
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
- **approval-required** — step 4 issued a deploy issue and handed it to the deploy-cycle lane.
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
- Deploy lane (deploy-cycle): closeout does not deploy to production or promote
  release — step 4 files a dry-run deploy-wait issue and hands it to the deploy-cycle
  loop, whose ⑦ owns deploying, promoting, real-device testing (rung ③, the TEST worker)
  and closing. The rest — merge, doc reconcile, follow-up issuance — closeout does
  unattended.
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
