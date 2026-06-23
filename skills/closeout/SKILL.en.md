---
name: closeout
description: Loop that auto-closes the green PRs issue-runner opened — merge, doc reconcile, deploy prep, and follow-up issuance. Use with /loop (e.g. /loop 20m /closeout). Each tick performs Reconcile → Pick → pipeline → Report.
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

- `MAX_CLOSEOUT = 1` — close out 1 PR to completion per tick (a serialization
  throttle, not a backlog cap). Pace is tuned by the `/loop` interval — one tick
  runs all of steps 1–6 for one PR.
- `REPAIR_RECUR_LIMIT = 2` — if the same post-deploy failure recurs N times,
  escalate to `needs:human` instead of re-issuing agent-ready (step-5 circuit
  breaker).
- `QUIET_TICKS = 3` — if there are no candidates/events for N consecutive ticks,
  report stagnated and do only reconcile from the next tick on.
- `SCRIPTS = ~/.claude/skills/issue-runner/scripts`
- `VERIFIER = codex:codex-rescue` — verifier subagent type for the step-1 plan-
  conformance check.
  **Output contract (SSOT — everywhere else refers to this entry)**: calls are
  read-only (no code changes), classify each finding as BLOCKER/WARN/NIT, output
  'CLEAN' if there are no findings, and BLOCKERs are a hard gate (no finishing
  before they are resolved). The verifier does not read this SKILL.md, so the
  call's prompt string must carry this contract verbatim — the prompt is the only
  delivery path.
  **Fallback**: in environments without the codex plugin (the type above is
  missing from the Agent tool's subagent_type list, or the call fails with an
  unknown subagent type error), use `general-purpose` as the verifier — it is
  invoked with the same prompt, so the same contract applies.
- Absolutely forbidden: unattended production deploys (step 4 is a human gate — no
  real deploy) · pushing directly to main (doc reconcile also goes through the PR
  branch) · merging without `harvesting` occupation · touching worktrees/branches
  that issue-runner created · breaking issue-runner's "never merges" invariant.

## ① Reconcile

Run `$SCRIPTS/closeout-reconcile.sh` and handle each event:

- `merged_cleanup` — the merge and label cleanup are done. But if the marker table
  below shows an incomplete step-4 or step-6 marker, resume from that step
  (idempotent resume).
- `resume` — the PR is OPEN and still holds `harvesting`. Skip the steps the
  marker table shows as finished and resume the pipeline from where it stopped.
- `stale` — report only.

Idempotent marker table (for re-judging finished steps — prevents duplicate work on
resume):

| Step | Marker | Resume judgment |
|---|---|---|
| 1 verify | PR comment `마감 검증:` | if present, skip step 1 |
| 2 merge | PR `MERGED` | if MERGED, merge is done |
| 3 reconcile | plan-doc diff (merge commit) + epic comment | if in the merge, done |
| 4 deploy | `배포 대기:` comment / `deployed:<sha>` | if present, do not re-request |
| 5 post | issued-issue number comment | if present, do not re-issue |
| 6 spinoff | created-issue number comment | if present, do not re-issue |

## ② Pick — 1 PR per tick (MAX_CLOSEOUT=1)

Take **only the first candidate** from `$SCRIPTS/closeout-eligible.sh` output. With
1 per tick there is no module-overlap judgment to make (serial closeout). Once
picked, immediately declare occupation with
`gh issue edit <pr> --repo <repo> --add-label harvesting` — this label is what keeps
issue-runner ② Maintain from touching this PR. If there are 0 candidates, skip the
③ pipeline and report a clean no-op in ④ Report.

## ③ Pipeline — steps 1–6

For the picked PR, perform the 6 steps below in order. At the end of each step, plant
the marker command (① Reconcile marker table) so the next tick can resume idempotently.

**Step 1 — plan-conformance verification.** Fill `references/verifier-prompt.md`'s
placeholders (`<PR>`·`<REPO>`·`<BASE>`=default branch·`<PLAN_REF>`=the issue's
`## Plan` or the referenced `Plans/*.md`, empty string if none) and synchronously
invoke `VERIFIER` (following the VERIFIER contract and fallback in ## Constants).
- BLOCKER → `gh pr comment <pr> --repo <repo> --body "마감 검증: ⚠ 보류 — <reason>"`
  + `gh issue edit <issue> --repo <repo> --add-label needs-human`
  + `gh issue edit <pr> --repo <repo> --remove-label harvesting` →
  **blocked exit** (do not merge).
- CLEAN/WARN → `gh pr comment <pr> --repo <repo> --body "마감 검증: ✅ <CLEAN or WARN n>"`
  (this comment is the step-1 completion marker).

**Step 2 — merge gate.** The merge command **must pass `--repo <repo>`** — closeout
merges PRs in repos outside cwd, so the ci-gate hook must query that repo via
`--repo` to not hit fail-closed (the hook's `--repo` recognition is #47; demonstrated
2026-06-24: in a BoDAT cwd session, merging an issue-runner PR was blocked because the
hook queried the cwd repo). Gate conditions: `$SCRIPTS/closeout-ci-pass.sh <repo> <pr>`
(exit 0) + the worker's `검증자 리뷰:` comment shows BLOCKER 0 + recheck
`gh pr view <pr> --repo <repo> --json mergeable` ≠ CONFLICTING. If all pass, **push the
step-3 commit first**, then `gh pr merge <pr> --repo <repo> --squash` (the ci-gate hook
judges once more). If CONFLICTING, remove `harvesting` and skip (issue-runner Maintain
rebases).

**Step 3 — doc reconcile (before merge, PR-branch commit).** Change the `- [ ]` to
`- [x]` in the plan-doc section that step 1 confirmed implemented. Commit and push
from the PR-branch worktree so it is included in the squash merge (no direct push to
main). If there is an epic, leave a progress rollup comment.
- **single-issue degrade**: if there is no `Plans/*.md`·`## Plan`, skip the doc edit.
  If there is no epic, skip the rollup. Reconcile only the issue's own checkboxes. If
  neither exists, this step is a no-op.

**Step 4 — deploy (human gate, dry-run).** **Do not deploy for real.** Fill
`references/deploy-check-issue.md` (`<DEPLOY_CMD>`=the repo's deploy entrypoint, or
"the repo's deploy procedure" if unknown), issue a deploy-request issue with
`gh issue create --repo <repo> --label needs-human`, leave the marker
`gh pr comment <pr> --repo <repo> --body "배포 대기: #<created-number>"`, then
**exit as approval-required**.

**Step 5 — post-deploy handling.** This Phase has no automatic smoke — only the path
where a human reports after deploying. If a problem is reported, do not fix it directly;
issue an issue instead: an agent-ready issue via `references/spinoff-issue.md` if it is
auto-fixable, a `needs:human` issue if live verification is needed. If the same failure
recurs `REPAIR_RECUR_LIMIT` times, escalate to `needs:human` (**exhausted exit**).

**Step 6 — spinoff issues.** Fill `references/spinoff-issue.md` with the worker PR
body's `follow-up:` items + adjacent work the step-1 diff review flagged, and issue an
agent-ready issue. Link it as a sub-issue if there is an epic, or as a standalone
issue if not. Record the created number in a comment on the original PR (a
duplicate-issuance marker).

## ④ Report

One-line summary: `closed N · verify-hold N · deploy-wait N · spinoff N · stale N`.

State the 6 exit states:
- **success** — ran steps 1–6, merged the PR, and issued follow-ups.
- **clean no-op** — ② Pick had 0 candidates, so there was no PR to close.
- **blocked** — step-1 verification was a BLOCKER, so it is on hold (no merge).
- **approval-required** — step 4 issued a deploy issue and is awaiting the human gate.
- **exhausted** — the same step-5 failure recurred `REPAIR_RECUR_LIMIT` times,
  escalated to needs:human.
- **stagnated** — quiet for `QUIET_TICKS` consecutive ticks.

After `QUIET_TICKS` consecutive quiet ticks, do only reconcile from the next tick on.

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
  `closeout-eligible.sh`·`closeout-ci-pass.sh`) and the 3 references
  (`verifier-prompt.md`·`deploy-check-issue.md`·`spinoff-issue.md`) live under the
  same `skills/closeout/`.
