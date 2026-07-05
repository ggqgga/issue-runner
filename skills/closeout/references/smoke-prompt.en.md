Smoke-check for UI regressions after a production deploy with Chrome. Drive production
directly via the chrome-devtools MCP and judge each check item in the deploy issue body
pass/fail.

**Drive procedure** — after loading the chrome-devtools MCP tools via ToolSearch:
0. **Entry cleanup (idempotent — crash-resume defense):** via `list_pages`, if a prior
   tick died before cleanup and left a smoke page, `close_page` it first.
1. `navigate_page` to the base URL `<VERIFY_URL>`.
2. For each check item below, compare the screen via `take_snapshot`/`evaluate_script`
   and produce a per-item pass/fail. If the item is prose ("top Infra tab → /infra
   renders"), use LLM interpretation to resolve the target path/element and confirm the
   actual render.
3. A data-zero screen can only be demonstrated up to the empty state — distinguish
   "structure/empty-state confirmed" from "real-data render confirmed" in the result.
4. **Cleanup (common exit — leak prevention):** after producing the verdict, always
   `close_page` the page this smoke opened (pass·fail, no exception on either path).
   Production pages keep client pollers alive, so a stranded tab spins CPU and accumulates
   — do not leave it. If no browser was opened at all (degrade), nothing to clean up.

**Degrade — no silent skip.** If the chrome-devtools MCP tools are absent from the
session (headless/cron environment) or `<VERIFY_URL>` is unreachable, skip the smoke and
report `스모크 skip: <reason>` (no hiding the gap — hand off to the human-report fallback
path).

**Output contract.** One line per check item with `pass`/`fail`/`skip` and a rationale,
then a final summary `스모크: <passed>/<total> 통과` (or `스모크 skip: <reason>`).
Read-only — make no direct changes.

--- verify URL ---
<VERIFY_URL>

--- check items (deploy issue `## 라이브/하드웨어 검증 항목`) ---
<LIVE_CHECKS>
