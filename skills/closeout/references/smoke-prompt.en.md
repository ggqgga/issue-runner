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
   — do not leave it. If no browser was opened at all (degrade), nothing to clean up (but
   if `navigate_page` was attempted to judge unreachability and opened an error tab,
   `close_page` that tab too).

**Degrade — no silent skip.** If the chrome-devtools MCP tools are absent from the
session (headless/cron environment) or `<VERIFY_URL>` is unreachable, skip the smoke and
report `스모크 skip: <reason>` (no hiding the gap — hand off to the human-report fallback
path).

**Suspect the address before you skip.** If Chrome reports `ERR_ADDRESS_UNREACHABLE`
while `curl` gets 200 from the same host, the server is not down — that *address* just
does not open in Chrome (measured 2026-09-10 on the BoDAT laptop's Chrome: the mini's LAN
IP and mDNS name fail in Chrome only, while the same box's Tailscale address and loopback
work, and that same Chrome opens the LAN router — so it is neither DNS nor macOS local
network permission). Retry on another address for the same box before declaring it
unreachable — (1) the repo's remote-access address (Tailscale for BoDAT), (2) an SSH
tunnel. Report unreachable only when both fail.

⚠️ **Verify the tunnel came up, or you will judge someone else's server.** A fixed port
may already be held by a dev server or another tunnel; the smoke would score that as a
pass and closeout closes the deploy issue on it (false green). Pick a fresh port, make
ssh die if forwarding fails, and probe it once:

```bash
PORT=$(( 39000 + RANDOM % 1000 ))
ssh -f -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$PORT:127.0.0.1:<remote port>" <ssh host alias> \
  && curl -fsS "http://127.0.0.1:$PORT/up" -o /dev/null && echo "tunnel ok on $PORT"
# when done: pkill -f "127.0.0.1:$PORT:127.0.0.1:"
```

No `tunnel ok` means unreachable, not a tunnel. Clean up by that port only — a broad
`pkill` cuts other people's tunnels. Find `<ssh host alias>`/`<remote port>` in that
repo's deploy docs (BoDAT: `bodat-mini` on the office LAN, `bodat-remote` from outside,
port 3000). If you cannot find them, do not invent them — report
`스모크 skip: tunnel route unknown (<repo>)`.

**Output contract.** One line per check item with `pass`/`fail`/`skip` and a rationale,
then a final summary `스모크: <passed>/<total> 통과` (or `스모크 skip: <reason>`).
Read-only — make no direct changes.

--- verify URL ---
<VERIFY_URL>

--- check items (deploy issue `## 라이브/하드웨어 검증 항목`) ---
<LIVE_CHECKS>
