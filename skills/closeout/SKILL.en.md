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
> where prose below restates a rule, the table wins (prose cleanup is plan stage 3).

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
- `VERIFIER = general-purpose` — verifier subagent type for the step-1 plan-conformance
  check. **Not codex** (#375, user decision 2026-09-13 — codex is called at most twice per PR,
  and both calls belong to verify-runner; the two extra closeout calls (correctness + plan
  conformance) that made it a third are gone). **The output contract's SSOT is the `VERIFIER` entry in
  issue-runner `SKILL.md`'s `## Constants`** (#427 — three SKILLs each claimed to be the SSOT;
  now there is one). It is not restated here: read-only, BLOCKER/WARN/NIT per finding, 'CLEAN'
  when there are none, BLOCKERs are a hard gate — all of it applies as written there. The
  verifier does not read this SKILL.md, so the call's prompt string must carry that contract
  verbatim — the prompt is the only delivery path, and
  that prompt is `references/verifier-prompt-fallback.md` (the variant that **embeds** the
  diff, issue body and lessons — `general-purpose` has no `--cd` equivalent in the Agent tool,
  so it is not scoped to the worktree and cannot be given the "this worktree is current"
  premise, #207). `references/verifier-prompt.md` is for the built-in reviewer (codex) only
  and is not used here.
- `VERIFIER_TIMEOUT_MIN` — wall-clock cap in minutes per `VERIFIER` (and
  fallback) spawn. Poll against a deadline of spawn time + this value; if the
  deadline is exceeded, cut it off with `TaskStop` and treat it as no verdict
  produced — the guard rail that stops an external-CLI stall from
  blocking the tick indefinitely (#96). **The value is `CODEX_GATE_TIMEOUT` (seconds) in
  `scripts/lib/constants.sh`, converted to minutes** (#427 — the old prose said
  "900s = 10 min", which was wrong).
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
- `lookup_failed` — the PR **state could not be read** (gh failure or empty reply, #433). That is not
  CLOSED — leave labels alone, **no-touch**, the next tick re-queries. ④ Report gets one line
  `보류: PR #<pr>(<repo_short>) — 상태 조회 실패`.
- `human_hold` — the PR is OPEN but carries `needs-human` (a human is investigating), or
  that label could not be read (`why` tells which). **Touch nothing** — leave one line in
  ④ Report, `보류: PR #<pr>(<repo_short>) — 사람 보류(<why>)`, and touch the PR no further
  this tick. Running it as `resume` would fall into the `bounced` resume procedure below and
  fire `closeout-redispatch`, and that transition **strips** the `needs-human`·`hold:*` a
  human just attached (exactly the risk ①-b excludes with its target filter, #151). An
  unreadable label goes the same way — treating a hold whose absence was never proven as a
  pass is fail-open. **Exit path**: when the human removes `needs-human`, the next tick comes
  back as `resume` (`harvesting` stays, so the PR never drifts out of the lane).
- `stale` — report only.

Idempotent marker table (for re-judging finished steps — prevents duplicate work on
resume):

| Step | Marker | Resume judgment |
|---|---|---|
| 1 verify | PR comment `마감 검증: ✅` | skip step 1 only when `$SCRIPTS/closeout-step1-marker.sh <repo> <pr>` says `skip` (section right below — `verify` and any non-zero exit both mean **run it**) |
| 2 merge | PR `MERGED` | if MERGED, merge is done (includes post-merge worktree cleanup) |
| 3 reconcile | plan-doc diff (merge commit) + epic comment | if in the merge, done |
| 4 deploy | `배포 대기:` comment / `deployed:<sha>` | if present, do not re-request |
| 5 post | `✅ 스모크` comment / deploy issue CLOSED + verification·deploy-complete comment | if present, do not re-smoke (including when the deploy lane (deploy-cycle) finished verification and closed it) |
| 6 spinoff | created-issue number comment | if present, do not re-issue |

**A step-1 marker is not "present, therefore done" — it counts only as a pass verdict on the
current head (#271).** The old table wrote step 1 as one line, "skip if a `마감 검증:` comment
exists", and that premise **can be false in three directions**. All three end the same way: an
unverified head reaches the step-2 merge gate, whose conditions (CI cache pass · zero
`검증자 리뷰:` BLOCKERs · MERGEABLE) are all still true, so **it gets merged**:

- (A) **The latest `마감 검증:` is `⚠ 보류`.** ③-1 ⓑ's hold comment shares the prefix, so the
  table catches it — but `⚠ 보류` records that step 1 was **not** passed. And it is the
  *latest* one that counts, not the mere existence of a ✅ (`✅ → ⚠` means the later ⚠
  overrode that ✅ — the same trap #218 attempt 3 hit in `bounce-state.sh`).
- (B) **The marker predates the current head commit.** If a rebase or a human push moved the
  head, that verdict judged the old code (the #171 rule applied to ✅, applied to the step-1
  marker too).
- (C) **The marker precedes the newest bounce marker.** If the replacement worker posted ✅
  after a bounce **without a new commit**, the head time is unchanged, so (B) never fires.

The three are **ANDed**, and the judgment lives in `$SCRIPTS/closeout-step1-marker.sh
<repo> <pr>`, **one place** (it gets the bounce marker set and ordering from
`bounce-state.sh --marker-index` inside — never a second copy of the marker matching, #171).
Skip step 1 **only when the output is exactly `skip`** — `verify` and a non-zero exit
(lookup/parse failure) both mean **run it**. Re-running costs one verifier call; skipping
costs an unverified merge, so the two are not symmetric.

**For `resume`, the bounce state decides the resume point before the marker table does
(#271).** The marker table's step-1 row ("skip step 1 if a `마감 검증:` comment exists")
rests on **a premise that can be false** — if a `마감 검증:` comment left by an earlier
round is already there (e.g. a PR whose ③-1 ⓑ `⚠ 보류` a human released so the next round
came back), the table skips step 1 and sends the PR straight to **the step-2 merge gate**.
That gate's conditions (CI cache pass · zero `검증자 리뷰:` BLOCKERs · MERGEABLE) are all
still true exactly as they were right before the bounce, so **the very head that just drew a
BLOCKER gets merged.** So `resume` runs `$SCRIPTS/bounce-state.sh <repo> <pr>` once
**before** it looks at the marker table and picks the resume point from that value (**the
same single place** ①-b uses — never a second copy of the judgment logic). That script can
emit four values and **all four have a destination**:

| `bounce-state.sh` | Meaning | `resume` point |
|---|---|---|
| `ok` | no bounce marker, or the last verdict after the newest bounce marker is `머지 판정: ✅` | **the marker table as-is** — skip the finished steps and resume where it stopped. The step-1 row's judgment is `closeout-step1-marker.sh`, one place, per the section above (bounce ordering (C), head freshness (B), and `⚠ 보류` (A) all live inside it — do not re-derive them here) |
| `bounced` | no verdict comment after the newest bounce marker, or the last one is `머지 판정: 🔄` | **do not look at the marker table**; resume at ③-1 ⓐ's `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` **retry point** (procedure right below) — never step-1 re-verification or the step-2 merge |
| `held` | the last verdict after the newest bounce marker is `머지 판정: ⚠ 보류` | **treat as `active`, touch nothing** — the worker raised that hold explicitly. Leave one line in ④ Report, `보류: PR #<pr>(<repo_short>) — 반송 뒤 워커 ⚠`, and touch the PR no further this tick (the same direction as ①-b — the sweep does not promote this value either, #218 second round) |
| no output (exit 1 — no judgment) | comment lookup/parse failure | **treat as `active`, touch nothing** + one line in ④ Report, `BLOCKED: 반송 판정 실패 PR #<pr>(<repo_short>)` — treating a state whose non-bounce was *never proven* as a pass is exactly fail-open (the same direction as ①-b) |

**`bounced` resume procedure — align the claim before re-running the transition.** Getting
here means ③-1 ⓐ's restore (`closeout-pick`) put `harvesting` back on both the PR and the
issue, but that restore may have landed on only one side. Read the issue side first with
`gh issue view <issue> --repo <repo> --json labels` and branch (the PR side must carry
`harvesting` or no `resume` would have fired at all):

- The issue has `agent:claimed` = **a replacement worker is alive** (the dispatcher got there
  first inside the restore window). Do not run the transition — the retry would strip that
  worker's `agent:claimed`. Treat as `active`, touch nothing, and leave one line in ④ Report:
  `보류: PR #<pr>(<repo_short>) — 교체 워커 점유(agent:claimed)`. When that worker finishes and
  posts `머지 판정: ✅`, the next tick's value flips to `ok` and the PR returns to the marker
  table path on its own.
- The issue has neither `harvesting` nor `agent:claimed` = **a half restore** (the issue side
  was left unoccupied — run the transition as-is and the dispatcher picks that issue up
  meanwhile). Run `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` once more to align
  both sides (idempotent, so the PR side is a no-op) and continue below. If it exits non-zero,
  report `BLOCKED: 전이 실패 closeout-pick PR #<pr>(<repo_short>) — <one stderr line>` in
  ④ Report and stop on that PR for this tick.
- Both sides have `harvesting` = a whole restore. Continue below.

Then re-run **only the transition call** from ③-1 ⓐ — **do not leave the bounce comment
again.** It is already in the ledger (that is why the value is `bounced`), and a second one
adds a round that never happened, making the next tick's judgment input false. If that retry
fails **again**, take ③-1 ⓐ's failure branch as written (one restore call +
`BLOCKED: 전이 실패 closeout-redispatch …`), leave it as that `BLOCKED:` line in ④ Report, and
**touch that PR no further this tick** (never loop it inside the same tick — no infinite
retries). The next tick's `resume` picks the same spot back up.

**Epic sweep (end of ①, every tick)** — an epic whose leaves are all closed is closed by
**no loop at all** (an epic is never picked up by a worker; it is a sub-issue rollup target).
Run `"$SCRIPTS/epic-sweep.sh"` with no `cd` (the scope auto-applies from the loop session
cwd's `.loop/repos`). It is a deterministic sweep that finds leaves by their dedicated
`Epic #N` body line and closes only epics with **at least one leaf, all CLOSED**. Handle each
event:

- `closed` — the epic was closed (rationale comment + `--reason completed`). Report it in
  ④ Report as `에픽 종료: #N(<repo short name>, leaf K)` (K = the length of `leaves`). When a
  deploy-wait candidate had neither a `PR #<pr>` nor a leaf mention and so could not count as
  evidence, `unlinked_deploy_wait` lists its numbers (the verdict is unchanged — it makes what
  dry-run skipped visible).
- `note` — a line that **touched nothing** and is a normal state (an old epic with no
  `Epic #N` lines · an epic carrying `deploy-wait` · an epic the sweep closed and a **human
  reopened** — marker present but open means never close it again, #377 · leaves all closed
  but the **epic body still has unchecked `- [ ]`** (`완료 기준 미체크 N개`) · a leaf's
  **deploy-wait issue is still open** (`leaf #N 의 배포 대기 이슈 #M 열림`, #343 — an epic
  not yet in production is not done. Deploy-wait issues are picked by the `deploy-wait`
  label **or** a title starting with `배포 대기`/`배포 검증` (stage 4's unlabeled fallback), and the link to a leaf is
  derived from the title's `PR #<pr>` → the issues that PR closed · its head branch — the
  issue template has no leaf placeholder). **Do not report it** — the same line every tick
  buries the real signals.
- `warn` — the judgment was **deferred** (the leaf search or the open-issue listing hit its
  cap) or a read/write failed (including a failed PR lookup for a deploy-wait issue). Copy
  `why` verbatim into ④ Report's warn lines. A deferral is not a failure, so exit 0 is
  possible alongside it.

exit 1 means this tick had a read/write **failure** — leave it alone, the next tick retries
(the `<!-- epic-sweep -->` marker in the rationale comment keeps it idempotent, so comments
never pile up). Two exceptions: the `에픽 close 실패(N회 시도)` warn and the `종료 근거 코멘트
실패 + 되읽기 실패` warn (#441 — the comment could not be re-read to see whether it landed) may
**not** be retried next tick (the marker stays and reads as a human revert) — copy their why into
Report verbatim so a human closes the epic or deletes the marker comment. `loop-status.sh`'s
`에픽 leaf 전부 종료` warn keeps showing that epic as `사람 몫(스윕 되돌림)`. exit 64 means no scope (`.loop/repos` missing): call it once more naming the
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
`agent/issue-*` and that is **not labeled `full-cycle`** (the human-session lane-ownership mark —
the head name is a convention, so the label is the explicit exclusion axis, #246), **not labeled `harvesting`**, **not labeled `flow:verify`**,
**not labeled `verifying`** (verify-runner's occupation label — set by `verify-pick` the moment it picks the PR,
replacing `flow:verify`; the `harvesting` twin, #275 — E2E/codex is running *right now*, so adopting or
re-dispatching it would void that verification; `closeout-eligible.sh` excludes the same label), **not
labeled `needs-human`**, and carries **no `hold:`-prefixed label**, judge it. The two are
**different stops** (#244): `needs-human` means a human set the stop by hand, while
`hold:<reason>` *is* the machine stop (verify-held · closeout-blocked · the dispatcher's
runner-held repair cap). The transition attaches **only** the reason label to a machine stop, so
watching `needs-human` alone lets a held PR (none of the three labels, only `hold:*` left) become
a target **again every tick** — re-posting the hold-note, and on the `stale_reverify` branch
letting `closeout-redispatch` strip a hold verify-runner just set (#151, reproduced). Either way,
adopting or re-dispatching it here would undo a stop that was just set, so never pick it until
that label comes off — released by a human (`hold:conflict` · `needs-human`) or by the resume
sweep (`hold:ladder`, and a `hold:policy` that passed re-review). The test is on the **prefix**, so
new reasons (`hold:<new>`) do not break it and `holding`/`on-hold`/`area:hold` do not match — the
same rule as the identical filter in `closeout-eligible.sh` (over-exclusion silently drops
mergeable PRs from the queue, which is worse than the original defect). This target filter runs
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
  - **The bounce marker's timestamp is part of the stale clock too (#308)** — the bounce
    transition strips `agent:claimed`, so in the **label gap right after a bounce, before the
    dispatcher re-attaches it**, all three progress-evidence axes read old/none. In that window
    `finish-classify.sh` returns `active`, so this branch never opens (marker detection is asked
    back to `bounce-state.sh`, the single place — never a second copy of the marker set).
  - Why that window was **harmless** (and why it was still fixed): `closeout-redispatch` works
    off a readback, so it is a no-op on an issue already at `agent-ready`, and the idempotency
    marker rule blocks a re-post — the worker never died. What remains is **one line in the
    ledger**. The ledger is the only place the next tick and a human read the *cause of death*,
    and a live bounce round labelled `완결 유실(검증 전 사망)` reads as a dead one.
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
posts `⚠ 보류` → `held` → `hold:policy` (before #244 this came paired with `needs-human`; now it
is the reason label alone) ⑶ **a human clears the hold and removes
the labels** ⑷ the replacement worker resumes with `🔄` ⑸ next tick: the stop labels are gone so
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
lanes** — closeout ①-b (bounce marker is latest), verify-runner (no `flow:verify`/`verifying`), issue-runner ②
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
| `done_verdict` | latest `머지 판정: ✅` **and it is proven to postdate the current head commit** (#171) | eligible.sh's normal path handles it — sweep skips |
| `stale_inline` | 🔄 + verifier CLEAN + past buffer (reached verification, only final verdict lost, #970-type) | **Adopt (merge)** — hand to ② Pick. ③ step 1 **re-verifies independently**, then closes out. **Do not create a new issue** (no redoing completed work). Except: a `stale_inline` coming out of the `bounced` branch in 1) is **re-dispatched, never adopted** (that CLEAN may predate the bounce). |
| `stale_reverify` | 🔄 + verifier absent / unresolved BLOCKER + past buffer + **no progress evidence** (#206) (died before verifying, implementation may be incomplete, #971-type). A CONFLICTING PR whose bounce marker is latest landing here *is* the "died just before ✅ after a bounce" class from 1) | **Re-dispatch** — do not merge unfinished work on codex re-verify alone (user decision). `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` (returns the linked issue to `agent-ready`, strips `agent:claimed` and the stage labels) → a fresh worker completes verifier→checkboxes→final verdict on the same branch. Idempotency marker (below). — if the head commit is fresh (#110, commit freshness folded into the stale clock), it falls back to `active` even when the verdict comment is stale, so a live attempt-N+1 worker isn't misclassified. |
| `no_verdict` | **zero** `머지 판정:` comments (no 🔄, ✅ or ⚠) + **green CI** (zero failing **and zero still-running** checks — one pending check disqualifies the class, #421) + past buffer + **no progress evidence** (#396). The worker died **before** step 10 (final verdict) — CI is green but there is no verdict, so until now no lane picked it up (issue-runner ② leaves "CI green, no review" alone; this table presumes 🔄/✅). A comment **lookup failure** is not this class (`active`) | **Re-dispatch** — the **same action** as the row above: `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` plus the idempotency marker below (same signature — it died before verification). Do not merge unverdicted code on codex re-verify alone. **With no linked issue, leave it** — there is nothing to return to `agent-ready`, so skip the transition and report one line in ④ Report for a human. |
| `held` | latest `머지 판정: ⚠ 보류` (worker's explicit hold) | **Stop (`hold:policy`)** — `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"` (attaches `hold:policy` to **both** the PR and the linked issue and clears the stage labels — the stop signal survives even with no linked issue. **`needs-human` is not attached** (#244): a machine stop carries only its reason label, and the human call is attached by `transition.sh policy-kept` only when the resume sweep's ③ re-review ends as "kept"), closeout leaves it (no auto-progress). |
| `active` | in progress · buffer not reached · not our shape, **or the ✅'s freshness could not be proven** (✅ predates the head commit, or either timestamp could not be obtained, #171), **or there is progress evidence** (commit within `STALL_MIN` · the head SHA's CI ticket alive in the queue · **the current round's `agent:claimed` was attached within the timebox** — or that judgment itself is unavailable: queue.log unreadable · head lookup failed · claim lookup failed (`unknown` ≠ `none`), #206 · `progress-evidence.sh`). A MERGEABLE bounce round is already filtered to leave-it by the 1) gate and never reaches here (#218) — the only bounce rounds that arrive here came through 1)'s **CONFLICTING exception branch** (#206), and an undecidable bounce state was filtered there as well (#196) | **Leave it** (next tick). |

**`flow:*` supplementary signal**: finish-classify judges by comments, but a stale PR with
`flow:codex`/`flow:ci` and no `flow:ready` is itself evidence of "worker died during verify"
(the labels are set outside this skill by the worker runtime — use as a supplement when
present; judge by finish-classify alone when absent).

**Re-dispatch idempotency marker (required)**: on a `stale_reverify` / `no_verdict` re-dispatch, leave the
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

## ② Pick — 1 PR at a time (MAX_CLOSEOUT=1, concurrency 1)

Take the **first candidate** (FIFO) from `$SCRIPTS/closeout-eligible.sh` output (✅-marked
normal candidates) merged with the **①-b sweep's adopt candidates** (`stale_inline` ·
CONFLICTING). One
at a time, there is no module-overlap judgment to make (serial closeout — only after this
PR is closed out to completion does ⑤ Drain pick the next candidate). Once
picked, immediately declare occupation with
`$SCRIPTS/transition.sh closeout-pick <repo> - <pr>` (the issue number is only parsed in
③-1, so pass `-` here). The transition attaches `harvesting` and strips the worker /
verify-runner stage labels (`flow:ready`·`flow:codex`·`flow:ci`·`flow:verify`·`verifying`) — `harvesting`
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
transition refuses with usage exit 64 — no reasonless stop can be created). A
rebase/semantic conflict is `conflict` (except a security-boundary or large-scope conflict,
which is `policy` — the step-2 CONFLICTING item's judgment, #344; `conflict`'s `--note` is
not a question but the one-line worker resume scope); anything else the loop cannot decide (spec·policy·
no verdict) is `policy`; `ladder` only when the rungs of
`~/.claude/skills/issue-runner/references/live-verification-ladder.md`
were actually climbed and the failure output cited.

**The stderr `blocked:` line from `$SCRIPTS/closeout-eligible.sh` is moved into ④ Report**
(same shape as issue-runner's `eligible-issues.sh` `blocked:` hand-off rule, #379). The
`✅ 이후 미해결 코멘트 N건` line (literally "N unresolved comments after ✅") means "a human review
remains after the boundary the verifier acknowledged (the ✅'s `코멘트 스냅샷 N`, or the ✅ itself
when absent), so it was not picked up, fail-closed" (the literal's "after ✅" refers to that boundary) — the loop does not resolve this on its own (a machine judging a
human comment "resolved" would be fail-open) — the only way it clears is **verify-runner
re-verifying and stamping a new ✅** (the confirmation step right before that ✅ is what
absorbs the human comments — see verify-runner ④). A human reply does not clear it (a reply
is itself an unmarked comment too); what a human needs to do is not leave a reply but send
the PR back to `flow:verify` (or re-pick it into `verifying`). Until then, the same line
repeating every tick is expected (never drop it silently). The counting boundary is the
`코멘트 스냅샷 N` snapshot token in the ✅ body when present (that N is the moment verify-runner
read the comments, so comments that slipped in between the read and the ✅ are caught too,
#384); for an older ✅ without the snapshot token it is that ✅'s index. Why not `warn`: warn is reserved for
invariant violations the loop can correct (`loop-status.sh` definition) — this is a legitimate
non-pick, so it belongs to the `막힘` (blocked) bucket.

## ③ Pipeline — steps 1–6

For the picked PR, perform the 6 steps below in order. At the end of each step, plant
the marker command (① Reconcile marker table) so the next tick can resume idempotently.

**Step 1 — plan-conformance verification — one `general-purpose` call, no codex (#375).** Get
`<issue>` from the PR body's `Closes #N` / `Refs #N` line (parse via `gh pr view <pr> --repo <repo>
--json body`). Correctness review is already done — verify-runner ran codex (`머지 판정: ✅` is the
premise of this step; its `검증자 리뷰:` comment carries BLOCKER 0 or `자체 리뷰(codex 2회 소진)`).
Here we check **plan conformance only**: does the change satisfy the issue AC/plan, is anything
out of scope. One call of the ## constant `VERIFIER` (general-purpose) with
`references/verifier-prompt-fallback.md` filled in — `<DIFF>`=output of `gh pr diff <pr> --repo
<repo>`, `<ISSUE_BODY>`=output of `gh issue view <issue> --repo <repo>` (empty string if no linked
issue), `<PLAN_REF>`=the issue's `## Plan` or the referenced `Plans/*.md` (empty string if none),
`<LESSONS_OR_"없음">`=**`.loop/lessons-verifier.md`** under the path resolved by `$SCRIPTS/repo-dir.sh
<repo>` (verification casebook — injects past misjudgment patterns; fall back to `.loop/lessons.md`,
and `없음` if both are missing or empty; `lessons.md` is for **implementation workers**, do not mix).
The instructions state "judge only whether the plan/issue AC is met; unmet or out-of-scope is
`[P1]`, minor deviation is `[P2]`". Spawn with `run_in_background` + a `VERIFIER_TIMEOUT_MIN` deadline
+ `TaskStop` on overrun. Deadline overrun or a verdict-less response is **no-verdict** — retry the
same prompt **once**, and if still no verdict, end in hold via ⓑ below (fail-closed — never proceed to
merge, #96). No worktree (`make-worktree.sh`) is needed in this step — step 3 obtains its own.
`codex-review-gate.sh` is not called in this step (bin/ci asserts this document has zero such calls).
- Verdict: BLOCKER → BLOCKER. CLEAN/NIT/WARN → pass (`[P3+]` = NIT is non-blocking).
  Machine-comment marker (required): the closeout-verification comment posted below via
  `gh pr comment` must include **a final line `<!-- bodat:worker -->`** — it is how
  closeout-eligible tells a machine comment from a human review (#72). Without it, on
  re-evaluation, the PR is mistaken for an unresolved human comment and drops out only when
  this comment comes after the latest `머지 판정: ✅` (a comment before that ✅ is treated as
  already seen by verify-runner, #379).
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
  (>VERIFIER_TIMEOUT_MIN분)`) → **there are two branches. The one-line test: if the defect
  closes with an implementation, take ⓐ (bounce to the worker lane); if a spec/policy call is
  still open, take ⓑ (hold for a human).** (With no linked issue — the PR body has no
  `Closes`/`Refs` so `<issue>` cannot be resolved — there is nothing to return to
  `agent-ready`, so ⓐ is unavailable and you take ⓑ.)
- ⓐ **Defect that closes with an implementation → bounce to the worker lane** (observed
  twice — with no comment channel for this branch the marker got hand-typed, #271).
  Leave the bounce comment with
  `$SCRIPTS/bounce-comment.sh closeout-blocker <repo> <pr> <issue> "<reason>"` — **never
  hand-type the wording** (a dropped colon or reordering makes the `bounce-state.sh` bounce
  safety net miss the PR, and `closeout-eligible` re-lists it as a merge candidate on the
  **stale ✅ that predates the bounce**, #212 · #171). Write `<reason>` so a worker can read
  it and fix it — what is blocked and why (do not borrow the `redispatch` channel's fixed
  wording: "lost finish" is false on this branch, and a false reason becomes the next tick's
  judgment input).
  **If that comment exited zero, then** `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>`
  returns the linked issue to `agent-ready` (stripping `agent:claimed`, the stage labels,
  `needs-human` and `hold:*` — do not hand-run `gh issue edit`) → **`blocked` exit** (no merge; do
  not invent a new exit state — also count it as `재디스패치 N` in ④ Report). Once the re-dispatch
  lands, issue-runner Dispatch reuses the same `agent/issue-N` worktree, so **the fix continues on
  the same PR branch** and no new PR appears.
  **On exit 1 (readback mismatch) or 2 (gh failure), do NOT change that PR's terminal state** —
  report `BLOCKED: transition failed closeout-redispatch PR #<pr>(<repo_short>) — <one stderr line>`
  in ④ Report, and **immediately re-run
  `$SCRIPTS/transition.sh closeout-pick <repo> <issue> <pr>` to restore the `harvesting` claim on
  BOTH the PR and the issue** (the same call ③-1 makes to mirror the source issue — idempotent, and
  it moves no label by hand). This branch **always** has a linked issue (without one you would have
  taken ⓑ), so do not call it in ② Pick's `<repo> - <pr>` shape: restoring **the PR only** leaves the
  issue side unoccupied in (b)·(c) below and the dispatcher picks that issue up. `agent-ready` left
  on the restored issue is harmless — `eligible-issues.sh` excludes the flow-label mirror
  (`harvesting`) **first**, so an `agent-ready` + `harvesting` issue is not dispatchable.
  `transition.sh` **finishes both edits before it reads either side back** (`run_edit` PR →
  `run_edit` issue → `verify_side` PR → `verify_side` issue). That makes three failure branches, and
  the one call above returns all three to the pre-transition state:
  - **(a) PR edit succeeds · issue edit fails (exit 2 — edit stage).** No `harvesting` on the PR;
    the issue is untouched and keeps `harvesting`. The dispatcher will not take the issue, but no
    lane recovers the PR — ①-b leaves it untouched because the bounce marker makes it `bounced`,
    and `closeout-eligible` excludes `bounced` too. The restore call re-attaches `harvesting` to
    the PR and is an idempotent no-op on the issue.
  - **(b) Both edits succeed · PR readback mismatch (exit 1).** The issue is **already**
    `agent-ready` + no `harvesting` + no `agent:claimed` — i.e. dispatchable. Left that way, the
    next tick hands that issue to a worker who holds the same branch closeout is holding, and the
    tick after that the retried `closeout-redispatch` **strips the live worker's `agent:claimed`**.
    The restore call re-attaches `harvesting` to both sides and closes that eligibility again.
  - **(c) Both edits succeed · issue readback fails (exit 1 mismatch · exit 2 lookup failure).**
    The labels are either as in (b) (mismatch) or unknown (lookup failure), so (b)'s race may be
    open. Attaching `harvesting` is idempotent, so **the same single call** as (b) closes it — do
    not branch on a state query first.
  Once all three have their occupation back to the pre-transition state, the next tick's ① Reconcile
  picks that PR up again as `resume`. **That resume point is set by the bounce marker, not by the
  marker table** — this branch leaves no step-1 `마감 검증: ✅` marker of its own, but **an earlier
  round may already have left one**, so going to the marker table would put the head that just drew a
  BLOCKER in front of the step-2 merge gate (whose conditions are all still true exactly as they were
  right before the bounce. The step-1 marker judgment (A)·(B)·(C) sends most of those back to ③-1,
  but here **not looking at the marker table at all** comes first — a bounce round belongs to the
  worker lane, not the closeout lane). So follow ① Reconcile's `resume` value table —
  as long as `bounce-state.sh` says `bounced`, ignore the marker table and resume at **the transition
  call right above**, re-running the same transition at the same spot — `closeout-redispatch` is idempotent, so
  re-running it is harmless (the same discipline #157 set for the `--note` transitions: a failure
  leaves the pre-transition state and the caller re-runs the same transition on the next tick — and
  if the restore fails too, the two `BLOCKED` lines in ④ Report are the human signal).
  **If that comment exits non-zero (gh failure / bad args), do NOT run `closeout-redispatch`** —
  the issue would go back to `agent-ready` while the PR carries no bounce marker, so the safety net
  misses the PR and `closeout-eligible` re-picks it on the stale ✅ (exactly the state this
  branch exists to prevent). **Fold this round into ⓑ instead.** The bounce never reached the
  ledger, so the PR cannot be handed back to the worker lane — and this tick's BLOCKER cannot be
  treated as if it never happened either:
  `$SCRIPTS/transition.sh closeout-blocked <repo> <issue> <pr> --reason policy --note "반송 코멘트 게시 실패 — <one stderr line>"`
  puts it on **human hold** → **`blocked` terminal state** (no new terminal state is created; the
  reason enum is only `conflict|policy|ladder` and a human has to decide, so it is `policy` — the
  real reason rides in `--note`). Report
  `BLOCKED: 반송 코멘트 실패 PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report.
  **Why a label and not a comment**: the comment channel just failed, so recording the state through
  that same channel fails for the same reason. `transition.sh` edits labels, an independent call, and
  `needs-human` closes **all three entrances at once** — `closeout-eligible`, ①-b's target filter,
  and ① Reconcile (`human_hold`) — removing the stale-✅ re-pick path.
  **If that transition also exits non-zero**, leave that PR's terminal state unchanged, add one more
  line, `BLOCKED: 전이 실패 closeout-blocked PR #<pr>(<repo_short>) — <one stderr line>`, to
  ④ Report, and **touch that PR no further this tick**. `harvesting` is still attached, so the next
  tick's ① Reconcile emits `resume` — and with no bounce trace in the ledger `bounce-state.sh` says
  `ok`, so that `resume` takes **the marker-table path**. What guarantees ③-1 runs again there is not
  the bounce marker but **the step-1 marker judgment** (see "A step-1 marker is not 'present,
  therefore done'" above — an earlier round's `⚠ 보류` is caught by (A), a stale marker behind a new
  commit by (B), a marker before the bounce by (C), and `closeout-step1-marker.sh` answers `verify`).
  **The remaining cell is not hidden**: after that double failure (comment post and label transition
  both failing in the same tick), if a `마감 검증: ✅` **for the current head** is still alive in the
  ledger, the step-1 judgment is `skip` and the step-2 gate judges that head again. Closing that cell
  too would need a **third channel** for this tick's BLOCKER, and with two channels already down
  there is no basis for expecting a third to succeed — so the two `BLOCKED:` lines in ④ Report are
  the human signal (the same discipline the (a)·(b)·(c) restore section set: "if the restore fails
  too, the two `BLOCKED` lines are the human signal").
- ⓑ **A spec/policy call is still open (no-verdict included — after the one retry) → hold for a human.**
  `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <reason>
  <!-- bodat:worker -->"`
  + `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
  (removes `harvesting` from the PR, attaches `hold:policy` to the PR and the linked
  issue and clears the stage labels — `needs-human` is not attached, #244) → **blocked exit**
  (do not merge). A BLOCKER or
  no-verdict that lands on this branch needs a spec/policy call, so the reason is `policy`
  (neither `conflict` nor `ladder`). A no-verdict is **always** this branch — with no verdict
  there is nothing to state as the reason a worker should fix.
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
  candidate ② Pick took has `revalidate` true (= `closeout-ci-pass.sh` exited 2 — the
  current HEAD's local-CI cache is empty due to a rebase etc., i.e. "not run, not fail"),
  then **before** evaluating the exit-0 gate above, revalidate the current HEAD: a single
  call to `$SCRIPTS/make-worktree.sh --sync <repo> <N>` obtains the worktree **and forces
  it to the rebased remote head** (`<N>` parsed from the PR head `agent/issue-N`, same as
  step 3;
  the `fetch` + `reset --hard origin/<branch>` procedure and the trap that "an existing
  worktree is returned as-is, so the pre-rebase SHA may still be checked out" are owned by
  that script's header comment — #445). Unlike step 3, this path makes no new commit, so
  **the sync is the only freshness guarantee**: the SHA it aligns to is exactly the one
  `closeout-ci-pass.sh` looks up via `gh pr view headRefOid`, and without it run-local-ci
  caches the old SHA and stays permanently exit 2. If `--sync` exits **3 (uncommitted
  changes in the worktree — it refused to overwrite)** or **4 (no such head branch on the
  remote)**, do not merge: skip this PR and report
  `BLOCKED: worktree 동기화 실패 PR #<pr>(<repo_short>) — <one stderr line>` in ④ Report.
  Then fill the **current HEAD** cache with
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
  **no merge commit**. **If you cannot resolve it, `git rebase --abort` and put in your exit
  report ⑴ the list of conflicting files (every path) ⑵ why it exceeds rebase scope — the
  additional work needed (e.g. a guard on the new branch + one test that bites)**", keeping
  push discipline and prohibitions. The agent's scope stays "the rebase and only the test
  alignment it breaks" — feature work belongs to a worker round, and those two exit-report
  items are the input to the hold-reason judgment below) → after the agent exits,
  run `$SCRIPTS/run-local-ci.sh <repo> <N>` to regenerate the rebased-HEAD cache. If nonzero
  (integration with the new base is broken), do not merge — **delegate fail-closed**:
  `$SCRIPTS/transition.sh closeout-redispatch <repo> <issue> <pr>` returns the linked issue
  to `agent-ready` (or spinoff), blocked exit. If 0,
  join the exit-0 merge gate above and squash-merge normally. If the agent **cannot resolve**
  the conflict (rebase abort / repeated failure), closeout does not resolve the semantic
  conflict itself (no unattended forced resolution) — instead it **splits the hold reason**
  (#344, human decision 2026-09-12: for a small conflict outside the security boundary the
  default answer is ⓐ one worker round — BoDAT #5103 ×2 and #185 all got that answer). The
  judgment is LLM work so it lives here; the resume itself is done by the follow-up
  resume-sweep (`hold:conflict` auto-resumed once):
  - **`--reason policy`** (human's call — not auto-resumed) — if either holds:
    ⓐ **security boundary** — a conflicting file touches auth·authorization·session·
    secrets (credential/secret)·external-input validation·trust-boundary paths. If the repo's
    `CLAUDE.md` names security-boundary paths use those; otherwise a file path/name containing
    `auth`·`session`·`secret`·`credential`·`permission`·`policy`, or the agent reported it would
    have to touch such code to resolve. ⓑ **large scope** — **4 or more** conflicting files, or
    **6 or more** PR-only commits (`git rev-list --count origin/<BASE>..HEAD`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason policy --note "<질문 한 줄>"`
    — `--note` stays a one-line question a human must answer, but it names which criterion
    (security boundary / scope) tripped (e.g. `security boundary — lib/auth/session.rb
    conflicts, which side of the session-expiry branch?`).
  - **`--reason conflict`** (the loop auto-resumes it once) — everything else. `--note` is
    not a question but **the one-line scope the resumed worker receives** (the worker resume
    scope form) — the follow-up dispatcher inlines this note verbatim into the resumed
    worker's prompt, so this one line is the worker's only instruction. The form is a
    machine contract and stays in Korean verbatim (the Korean SKILL is the SSOT; the
    English gloss below is for reading only). Form:
    `충돌 <상대 PR #M>·<파일 목록> — 워커 재개 범위: origin/<BASE> 위로 rebase 해 원안 의도대로 해소 + <에이전트가 보고한 추가 작업>`
    (i.e. `conflict <other PR #M>·<file list> — worker resume scope: rebase onto origin/<BASE> resolving per the original intent + <additional work the agent reported>`;
    e.g. `충돌 #5114·client.rb, client_test.rb — 워커 재개 범위: origin/main 위로 rebase 해 원안 의도대로 해소 + proxy_push 분기 before_send: guard + 무는 테스트 1건`).
    `$SCRIPTS/transition.sh closeout-blocked <repo> <issue|-> <pr> --reason conflict --note "<워커 재개 범위 한 줄>"`
    If the agent's exit report has no conflicting-file list (judgment input missing — the
    note cannot be filled), this is not "everything else" but **fail-closed to `policy`**
    (note: `판정 입력 부재 — 에이전트가 충돌 파일 목록을 보고하지 않음, 워커 재개인가 사람인가?`).
    **A PR with no open linked issue (`<issue>` slot `-`) is also `policy`, not `conflict`**
    (#345) — a resume worker is dispatched on an issue, so with no issue to dispatch on the
    "one resume" does not exist. Filing it as `conflict` does not lose it (the resume sweep's
    PR axis escalates it to `policy` after the window and hands it to the PR-only re-review)
    — filing `policy` from the start saves that window and puts the note in question form
    (what a human must answer: take over, or open an issue and reissue) right away.
  Either branch is a blocked exit (this path alone uses `conflict`). For both transitions
  (redispatch·blocked): **on exit 1 (readback mismatch) or
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
- Otherwise a **`- [ ]` checkbox list**. One line = one action `e2e-test` performs after the deploy (deploy-cycle ⑤ moves these lines into a `테스트` issue once the deploy is done — BoDAT #5197)
  once. Background·rationale·caveats go in `## 변경 요약`; leave only the actions here.
- **A real-hardware line REQUIRES the `[칸 ③]` prefix marker** — write it as
  `- [ ] [칸 ③] <action>`. Saying in prose that real hardware means an action only
  ladder rung ③ (a TEST-worker profile #18 dry run) can step **does not substitute for
  the marker**: the marker is **shape enforcement of the same grade** as `없음` and
  `- [ ]`. Step 5 identifies real-hardware items by this marker alone, so a line missing
  it is counted as an ordinary Chrome item, passed, and the ticket closes without the
  TEST worker ever running (#309). Even when rungs ①② failed and the carried-over line
  never says "TEST worker", **if the rung it steps is ③, attach the marker** — the basis
  for the decision is the marker, not the meaning of the sentence. The marker is a
  **literal**: write `[칸 ③]` exactly, never a translation ("[rung ③]" and the like) —
  step 5 and the `bin/ci` guard both match one fixed string.
- **An unmarked line must be one Chrome can step.** Step 5 steps unmarked lines with
  Chrome, and when the means lives outside the browser (a worker box · `ssh` · a server
  shell) so Chrome cannot even try, it prints no pass and **counts the line as held**
  (the fail-closed branch in step 5 below) — which keeps this ticket open. If a line is
  not rung ③ but still needs a means outside the browser, write that means into the line
  so ⑦ can step it directly.

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
**once each** first. **Rung ③ (the TEST worker) is `e2e-test`'s job after the deploy** — that is why
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

- **Issuance command (required form — do not substitute prose).** The whole issuance
  procedure — the title shape · the body sections · the labels · the missing-label
  three-rung ladder · the label readback right after issuance · the PR marker — is
  **a single call to `$SCRIPTS/deploy-wait-issue.sh`** (#446). Never assemble
  `gh issue create` by hand here: the 8/8 miss behind this fix was the command sitting
  mid-prose.

  ```
  $SCRIPTS/deploy-wait-issue.sh <repo> <pr> --sha <merge sha> \
    --title "<one-line summary>" --summary-file <change-summary file> --items-file <items file|없음> \
    [--verify-url <production base URL>] [--deploy-cmd <deploy entrypoint>] \
    [--parent-issue <parent issue#>] [--hardware]
  ```

  **The title regex (`배포 대기: PR #<M>`), the section names (`## 검증 URL` ·
  `## 라이브/하드웨어 검증 항목`), `없음` and `(승격만)` are a parsing contract read by
  deploy-cycle and deploy-bodat**, and its SSOT is now that script's header comment, not
  this prose (to change a literal, fix those consumers first). What it does: enforces the
  item shape (`없음` on its own, or **every line** a `- [ ] ` checkbox — one prose line → exit
  65 **before** issuing) → appends
  ` (승격만)` to the title when there are zero checkboxes → creates the issue with
  `--label deploy-wait` (plus the P inherited via `--parent-issue`, plus `needs:hardware`
  only when `--hardware` is given **and the label actually exists in the repo**) → on a
  missing label calls `setup-labels.sh` once and retries once → and if that still fails
  **creates the issue with no `--label` at all** so the ticket is never lost
  (`loop-status.sh` still counts it as deploy-waiting via the `배포 대기:` title fallback)
  → reads the labels back and tops them up → leaves the marker `배포 대기: #<number>` on
  the PR. stdout is the issue number, one line. Omit `--verify-url` when the production
  base URL is unknown (step 5 then falls back to "URL unreachable").
  - **exit 0** → the marker is in place: **exit as approval-required**.
  - **exit 65 (shape violation before issuance — no issue exists yet)** — `<LIVE_CHECKS>`
    was prose. Move the background/rationale into `## 변경 요약`, leave only `없음` or
    `- [ ]` lines in the items file, and **call it again**.
    **Never end step 4 on exit 65** — if it still exits 65 on the second call, move the
    prose into `## 변경 요약` and **issue it** with `--items-file 없음` (a `(승격만)`
    ticket). "A merged PR always gets a promotion ticket" outranks the shape discipline —
    withholding the ticket over a shape error returns us to the state where we cannot even
    tell whether there is anything to promote (2026-08-16). In that case also report
    `BLOCKED: 배포 대기 항목 형태 위반 — PR #<pr>` in ④ Report.
  - **exit 1 (no issue created)** — report
    `BLOCKED: 배포 대기 이슈 발행 실패 — PR #<pr>` in ④ Report. A merged PR that ends
    without a ticket makes the promotion scope invisible to humans.
  - **exit 2 (the issue exists — its number is on stdout)** — labels or the marker went
    wrong, and that state is not normal (deploy-cycle cannot find it by the lane mark).
    Report `BLOCKED: 배포 대기 이슈 deploy-wait 라벨 부착 실패 — #<번호>` in ④ Report and
    demand the **three-step human recovery** (skipping the second step leaves the ticket
    label-less forever — `setup-labels.sh` only creates the label *definition*, it does not
    attach it to an existing issue): ⑴ rerun `$SCRIPTS/setup-labels.sh <repo>`
    ⑵ `gh issue edit <number> --repo <repo> --add-label deploy-wait` to attach it **to that
    issue** ⑶ `gh issue view <number> --repo <repo> --json labels` to confirm. Do not
    duplicate that label edit here (#223) — it just fails again, and that failure cuts off
    the marker and the report (the ticket exists but nobody knows = exactly the loss the
    fallback exists to prevent). Never let it pass silently.

  `deploy-wait` is the bucket label `loop-status.sh` uses to separate deploy-waiting from
  needs-human, and it is **the lane mark the deploy-cycle loop picks this ticket up by** —
  that one label is mandatory.
  **closeout does not attach `needs-human` (#243, plan step 2) — do not revert this.**
  Nothing is a human's at issuance time: ⑴ the dispatch gate **requires**
  `label:agent-ready` (`scripts/eligible-issues.sh`) and a deploy-wait issue has none, so
  it is not a candidate at all, and ⑵ deploy-bodat collects by **title regex**
  (`배포 대기: PR #<M>`), not by label. Attaching it would blur what `needs-human` means
  (= a human's turn remains) into a duplicate mark (#190). **The one that attaches that
  label is deploy-cycle** — on a promotion/deploy/smoke failure, together with a reason
  comment (BoDAT #5197, hidden stop-files abolished). Hence the loop-status buckets put
  needs-human **before** deploy-waiting (2026-09-13), so that failure mark cannot hide in
  the deploy-waiting column.

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

**Step 5 — post-deploy handling (Chrome smoke).** For a deploy issue **reported deployed**
(it does not ask who reported it — in the new model the deploy-cycle lane leaves that
report), without any new detection mechanism (no polling/timing), actively run
a Chrome smoke to judge it. Parse `## 검증 URL` (`<VERIFY_URL>`) and
`## 라이브/하드웨어 검증 항목` (`<LIVE_CHECKS>`) from the deploy issue body, fill
`references/smoke-prompt.en.md`'s placeholders
(**substitute that section untouched — do not pre-filter the marked lines out.**
The prompt prints a `[칸 ③]` marked line as `보류` without stepping it, and **the counting
is done by `$SCRIPTS/smoke-tally.sh` alone** (#448) — filtering once more before
substitution creates a second calculator for real-hardware items), load the
chrome-devtools MCP tools via
ToolSearch, then **entry cleanup (idempotent — crash-resume defense): via `list_pages`,
if a prior tick died before cleanup and left a smoke page, `close_page` it first.** Then
`navigate_page` to `<VERIFY_URL>`, and compare each item via
`evaluate_script`/`take_snapshot` to produce a per-item pass/fail (distinguish
structure/empty-state confirmation from real-data render confirmation in the result).
- **The tally lives in `$SCRIPTS/smoke-tally.sh`, one place (#448).** The arithmetic —
  marker detection, denominator exclusion, held summation — is owned by that script's
  header comment, not by this SKILL and not by the prompt: the same rules used to sit in
  both as prose, which is exactly "two calculators for real-hardware items". Never count
  by hand here.
  - **Before the smoke — is there anything to step?** Write the deploy issue's
    `## 라이브/하드웨어 검증 항목` section to a file and call
    `$SCRIPTS/smoke-tally.sh --checks <section file>` (check-mode JSON: `open` ·
    `steppable` · `held_marked` · `skipped`). If `steppable` is 0, **do not open Chrome** —
    a smoke with zero items to compare has not passed anything, it **looked at nothing**,
    yet it prints as `✅ 스모크 0/0 통과` and reads as verified (a false green). But **how
    it ends splits in two**: treating a section left with marked lines only as "no items"
    finalizes a ticket carrying real-hardware items without ever taking the held path
    below — exactly what this section forbids.
    - **`open` is 0 (a `없음` section)** → leave the comment `스모크 생략: 밟을 항목 0` and
      mark it **complete**. That issue is a container the deploy-cycle lane closes once the
      promotion is done, not a verification subject.
    - **`steppable` is 0 but `held_marked` is not (marked lines only)** → do not open
      Chrome, and it is **not complete**. Finish exactly like the real-hardware branch
      below: leave
      `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다` (`<n>` = `held_marked`)
      plus `보류 내역: 표식 <a>건 · 표식 없는 미밟음 0건` (`<a>` = `held_marked`), and
      **do not close the issue** — rung ③ is `e2e-test`'s (deploy-cycle ⑦'s) job after the deploy.
  - **After the smoke — what did it see?** Collect **only the verdict lines** the prompt
    produced (`<verdict> <original item line>` — the vocabulary is `pass`·`fail`·`보류`,
    the grammar is in the script header) into a file, call
    `$SCRIPTS/smoke-tally.sh --checks <section file> <result file>` (the original checklist is
    **the truth about the denominator** — counting the result file alone makes an item the
    model omitted disappear into a `1/1 통과` false green, #467), and branch below on that JSON:
    `verdict` (`green`|`fail`|`held`|`skip`) · the denominator `denominator` · the held
    count `held` (broken down as `held_marked`·`held_unstepped`). **Do not read `verdict`
    alone** — fail and held can both be true, and even on the fail branch a non-zero
    `held` means the issue does not close. A non-zero `unparsed` means the prompt emitted
    a line outside the grammar **or omitted an item**, and a non-zero `duplicate` means one
    item got two verdicts — either way that item counts as held, so that tick cannot be
    green. Report it in one line in ④ Report. **On a degrade tick where the smoke never ran, do
    not make this call at all** — feeding a `스모크 skip: <reason>` line to the tally as a
    result file parses as a line outside the grammar, is counted as `보류`, and leaves a
    ticket that was never stepped sitting in "held". Degrade is owned by its own bullet below.
- **Real-hardware items still open — do not close even on green (Chrome cannot step rung ③).**
  Decide **by the `[칸 ③]` prefix marker alone** — step 4 enforces that marker as shape, of
  the same grade as `없음` and `- [ ]`, so never invent a second predicate here. The
  rationale (why such a line is real hardware) is that the action the marker points at is
  ladder rung ③ (a TEST-worker profile #18 dry run), which Chrome cannot step — keep the
  rationale as rationale and **decide by the marker**. Interpreting the sentence lets the
  same line read as real hardware in one tick and as an ordinary item in the next (#309).
  If `held` is non-zero, **do not close the deploy issue even when everything else
  passes**: finish with the comment
  `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다` (`<n>` = `held`).
  Rung ③ is `e2e-test`'s job after the deploy, so closing here finalizes a ticket whose
  real-hardware items never met the TEST worker once. That issue is a container the
  deploy-cycle lane's ⑦ closes after it steps rung ③.
  - **Holding an unmarked line is an observation, not an interpretation.** The prompt
    **steps unmarked lines first**: stepped and the value differed from the expectation →
    `fail` (Chrome actually saw the screen or the value, so it is a genuine defect → the
    fail branch below); the means of stepping it lives outside the browser (a worker box ·
    `ssh` · driving the AdsPower client · a server shell `bin/rails runner` · a
    `log/*.out` grep) so it **could not even try** → `보류` (= `held_unstepped`). Never
    promote a line to real hardware by reading its meaning — that is the moment a second
    calculator is born. **Never file a follow-up issue for such a held line** — it is not
    a defect, only a different lane, and dropping it into fail files a `needs-human`
    follow-up whose recorded reason is a false "smoke failure" (#309 attempt 1 leaked
    exactly this way). Deploy issues filed before this discipline carry no `[칸 ③]` at all,
    and **no fixed string exists** that picks the real-hardware lines out of that backlog
    (a full census of the 27 open `- [ ]` lines across the 10 open backlog tickets on
    2026-09-12: `TEST 워커 프로필 #18` matches 0 lines · `TEST 워커` matches 1 of 6
    real-hardware lines · `워커` drags in non-hardware lines while still missing the line
    stepped over `ssh test` — every candidate is wrong in **both directions**, and an
    approximation that errs toward erasing more is worse than the original bug). So decide
    by **what stepping it produced**, not by a string.
  - **Do not backfill the marker in its place.** Not every held line is rung ③ (some only
    need a server shell). Keep the marker string single, and print the breakdown from the
    numbers the script produced, in one comment line:
    `보류 내역: 표식 <a>건 · 표식 없는 미밟음 <b>건 — 재고 · 4단계 표식 누락 · 또는 4단계가 수단을 적어 보낸 비-칸③ 줄`
    (`<a>` = `held_marked` · `<b>` = `held_unstepped`). Why the **third category** stays: a
    line step 4 sent to ⑦ with the means written on it because it is not rung ③ yet needs
    a tool outside the browser obeys the discipline and still lands here, and recording it
    as a "missing marker" **misrecords** a step 4 that followed the rule as one that broke
    it (the verdict is the same; only the record is wrong). Once those two are set aside,
    anything left in this branch is the signal that the ticket is **backlog, or that the
    step-4 shape discipline was violated**.
- **Already-closed deploy issue — skip the smoke.** If the deploy issue is already
  CLOSED and has a verification/deploy-complete comment, treat step 5 as complete —
  do not re-smoke, proceed to the next step (the case where the deploy lane
  (deploy-cycle) finished verification and closed it — the standard finalization in a
  promotion-model repo).
- **Degrade — no silent skip.** If the chrome-devtools MCP is absent from the session
  (headless/cron — interactive-auth MCP may be missing) or `<VERIFY_URL>` is blank or
  unreachable, skip the smoke and fall back to the deploy-cycle lane's human-report path, but leave
  a `스모크 skip: <reason>` comment on the deploy issue (no hiding the gap).
  But **"unreachable" is the last word, not the first** (#153): some addresses open only
  outside Chrome, so before writing the skip, walk the retry ladder in smoke-prompt —
  ① the repo's remote-access address ② an SSH tunnel. Only when **both** fail is it
  unreachable. **Since no
  browser was started at all, there is nothing to clean up — the browser cleanup below
  is a no-op (not a leak).**
- **green (`verdict=green` — all pass, zero held)** → a `✅ 스모크: <n>/<n> 통과` (`<n>/<n>` = `pass`/`denominator`) comment on the deploy issue + the
  original PR (this comment is the step-5 completion marker — a resumed tick does not
  re-smoke). Then remove the `needs-human` label from the deploy issue and close the
  deploy issue (the only remaining gate was verification and it passed, so closeout
  finalizes — the recommended option of the open decision).
  **A non-zero `held` never reaches this branch** — `verdict` comes out `held` instead,
  and the real-hardware bullet above owns it: stop at the label cleanup, leave the issue
  open, and finish with the
  `종결 보류: 실장비 항목 <n>건 — deploy-cycle ⑤ 가 테스트 이슈로 옮긴다` comment (verification was not the only
  remaining gate — rung ③ is). Since #243 a step-4 issue
  never carries `needs-human` in the first place — this removal is harmless leftover
  cleanup for issues filed before that (`--remove-label` is a no-op for an absent label).
- **fail (any item fails)** — **only lines Chrome actually stepped reach here.** Lines
- **fail (`verdict=fail` — `fail` is one or more)** — **only lines Chrome actually stepped reach here.** Lines
  publish targets below (filing a follow-up with a "smoke failure" reason for a line that
  was never stepped records a non-defect as a defect — #309). → do not fix it directly; use the existing publish path: an
  agent-ready issue via `references/spinoff-issue.md` if auto-fixable (**the same single
  call as step 6** —
  `$SCRIPTS/spinoff-issue.sh <repo> <parent-issue#> <parent-pr#> --title "<title>" --body-file <body-file>`,
  which carries the inheritance, labels, readback and marker;
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
agent-ready issue. The whole issuance procedure — inheritance (#261) · the body's first
line `Epic #N` · labels · the missing-label fail-closed ladder · the readback right after
issuance · the parent-PR marker — is **a single call to `$SCRIPTS/spinoff-issue.sh`**
(#447). Never assemble `gh issue create` by hand here: the prose-only step leaks
(measured 2026-08-13 on BoDAT: step 6 attached only the convention labels and dropped
`agent-ready`, stranding 17 open issues outside the loop, while step 4 — whose command
literally carried the label — was correct on all 186).

- **Deciding the parent (the input to inheritance — this stays this step's judgment, not
  the script's).** The parent is, first and foremost, the **N in the closing PR's head
  branch `agent/issue-<N>`**. Use `closingIssuesReferences` only to **cross-check** that N
  appears in that list, or as a **fallback** when the head branch is not of the form
  `agent/issue-*` — `[0]` is not guaranteed to be the branch's issue (measured: `PR #113`
  had `head=agent/issue-109` but `closingIssuesReferences=[108, 109]`, so `[0]` was
  **#108**, the wrong issue. The same trap silently switched off an evidence source at
  `finish-classify.sh:317-318`). If neither source yields a parent, do not pass `-` to the
  script — **do not issue** and report `BLOCKED: spinoff parent unknown — PR #<pr>` in
  ④ Report (never issue without inheritance).
- **Issuance command (required form — do not substitute prose).** Write the filled
  `spinoff-issue.md` to a file and pass it via `--body-file` (the template is
  **body-only** — labels written there render into the issue body; the script passes
  labels on the command line):

  ```
  $SCRIPTS/spinoff-issue.sh <repo> <parent-issue#> <parent-pr#> \
    --title "<title>" --body-file <body-file> [--label <repo-convention label>...]
  ```

  That script's header comment is the SSOT for the rules. What it does: reads the parent
  **once** through `spinoff-inherit.sh` for `epic=`/`priority=` → fills the body's
  `<EPIC_LINE>` dedicated line with `Epic #N` (an empty line when there is no epic) and
  guarantees it is the **first line** (an epic is linked by that dedicated body line, not
  by a sub-issue link or a label — `loop-status.sh`'s epic section counts leaves by it) →
  creates the issue with `--label agent-ready --label spinoff --label "$priority"` plus the
  convention labels you passed → on a missing label, calls `setup-labels.sh` once and
  retries once, and if that still fails **creates the issue without labels** (never lose
  the issuance) → reads the labels and the `Epic #N` first line back and tops up what is
  missing → leaves the marker `파생: #<new number> (Epic #<N|없음> · <P>)` on the parent PR.
  stdout is the new issue number, one line.
  - **exit 0** — copy the `marker:` line from stderr into ④ Report's `파생` item verbatim
    (that is how spinoffs leaking outside their epic stay observable every tick).
  - **exit 1 (no issue was created; no output)** — unknown parent, inheritance failure, or
    issuance failure. Report `BLOCKED: spinoff parent unknown — PR #<pr>` or
    `BLOCKED: spinoff issuance failed — PR #<pr>` in ④ Report.
  - **exit 2 (the issue exists — its number is on stdout)** — labels, body or marker went
    wrong. Report `BLOCKED: spinoff issue labeling failed — #<number>` in ④ Report
    (recovery is a human's: rerun `setup-labels.sh`, then `gh issue edit --add-label`).
    Do not pile another attempt on top of it here.

  The only thing to pass with `--label` is the **repo convention axis** (BoDAT:
  `difficulty:*`·`frontend` (only when UI is touched)·`needs:hardware` — the repo
  CLAUDE.md label section is the SSOT). `agent-ready`, `spinoff` and P are attached by the
  script, so never repeat them — this is exactly where the observed failure shape
  (convention labels displacing `agent-ready`) is cut off at the source. Without
  `agent-ready` the dispatch gate (`eligible-issues.sh`: `open + agent-ready +
  ¬agent:claimed`) means the issue is created and **never picked up**; without `spinoff`,
  `loop-status.sh`'s `파생` line cannot see it in the inventory. Never raise `priority` by
  hand — bumping a spinoff to P1 because it "looks urgent" is exactly today's inflation;
  raising it is a human's call at the epic level (the helper carries a parent's `P0` and
  folds everything else into `P1`, #401).
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
`closed: PR #4795(bodat)←#4788 · spinoff: #4823(bodat)←PR #4788 (Epic #4968 · P1) · re-dispatched: #4770(bodat, stale_reverify)`.
Write the spinoff item in the **same shape** as step 6's PR marker comment —
`#<new number> (Epic #<N|없음> · <P>)` — so spinoffs that failed to inherit an epic
(`Epic 없음`) are visible as they accumulate, tick by tick.
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
