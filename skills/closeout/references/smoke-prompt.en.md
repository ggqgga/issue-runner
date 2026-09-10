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

**A local port collision is not remote unreachability — the axis that splits them is not
"how many failures" but "which side has the problem."** If the chosen port is already
held (a bind collision), `ExitOnForwardFailure=yes` kills ssh — that's a **local
problem**. Retry on another port when the bind fails, and if all five collide on a bind,
report a dedicated string (below, `tunnel port exhausted` — **a local problem, not
unreachable**). If instead ssh fails for a **non-bind reason** (host down, auth failure,
DNS, routing), that's a **remote/path problem** — retrying is pointless, so report
`tunnel unreachable` right away (don't invent a new string; it folds into the same verdict
as "bound fine but the probe never answered / timed out," since both are remote-side
problems). Clean up through **the control socket this invocation created**, never a
broad `pkill` (which would cut someone else's tunnel on the same port).

**The control socket path does not rely on variable handoff — derive it from the port,
fixed.** The snippet that opens the tunnel and the "clean up after the smoke" snippet are
**separate Bash calls**, so a shell variable (`CTL`) does not survive between them. So the
socket path is derived, fixed, from the port that bound successfully
(`/tmp/smoke-tun-<port>.sock`) instead of a random `mktemp` value — the port is printed
verbatim in the tunnel snippet's output, so the cleanup snippet can reconstruct the same
path from just that number:

```bash
ERR=$(mktemp); PORT=""; CTL=""; ALL_BIND=1
for _try in 1 2 3 4 5; do
  P=$(( 39000 + RANDOM % 1000 ))
  C="/tmp/smoke-tun-$P.sock"          # socket path = derived fixed from port (no variable handoff)
  if ssh -f -N -M -S "$C" -o ExitOnForwardFailure=yes \
       -L "127.0.0.1:$P:127.0.0.1:<remote port>" <ssh host alias> 2>"$ERR"; then
    PORT=$P; CTL=$C; break            # bound successfully
  fi
  # The stderr ExitOnForwardFailure=yes produces on a bind failure is "bind: Address
  # already in use" (or similar) — that's what this grep matches. Non-bind failures it
  # does NOT match: "Could not resolve hostname" (DNS) · "Connection refused"/"No route
  # to host" (host down, routing) · "Permission denied" (auth failure). Those are
  # pointless to retry on another port, so break immediately.
  grep -qi 'bind\|address already in use' "$ERR" || { ALL_BIND=0; break; }   # remote/path problem
done
if [ -z "$PORT" ] && [ "$ALL_BIND" = 1 ]; then
  echo "tunnel port exhausted"        # five bind collisions — a local problem, not unreachable
elif [ -z "$PORT" ]; then
  echo "tunnel unreachable"           # non-bind ssh failure (host down/auth/DNS/routing) — remote/path problem
elif curl -fsS --connect-timeout 3 --max-time 10 \
     "http://127.0.0.1:$PORT/up" -o /dev/null; then
  echo "tunnel ok on $PORT, control socket $CTL"   # ← smoke URL is http://127.0.0.1:$PORT
else
  echo "tunnel unreachable"           # bound fine, but remote silent · response too slow (>10s)
  ssh -S "$CTL" -O exit <ssh host alias> 2>/dev/null || echo "control socket teardown failed: $CTL"
fi
rm -f "$ERR"
```

**On `tunnel ok`, leave the tunnel up and run the whole Chrome smoke through it** — tearing
it down right after the probe means you never see the screen you came to check (all you
verified is `/up`). Clean up after the smoke finishes, once, on **every** path — pass,
fail, or abort — by reconstructing the same path from the port number printed above
(carry over the digits, not a variable):

```bash
CTL="/tmp/smoke-tun-<PORT>.sock"   # <PORT> = the port number from the tunnel snippet's output (e.g. "tunnel ok on 39441" → 39441)
if [ -S "$CTL" ]; then
  ssh -S "$CTL" -O exit <ssh host alias> 2>/dev/null || echo "control socket teardown failed: $CTL"
else
  echo "control socket not found (path mismatch or already cleaned up): $CTL"   # never swallow this silently
fi
```

Only `tunnel unreachable` means unreachable — the loop above already filtered five bind
collisions into their own `tunnel port exhausted` verdict (classified as a local problem —
a skip reason, not counted toward unreachable), and the other two failure paths — ① ssh
failing for a non-bind reason, ② bound fine but the remote is silent or too slow
(`--max-time` cuts it off after 10s so closeout never hangs) — both fold into the same
string, since both are remote/path problems. Clean up through the
control socket (`-O exit`) only — a broad `pkill` on the port string cuts other people's
tunnels using that port. If the socket can't be found (`-S` fails), don't swallow it with
`|| true` — say so. Find `<ssh host alias>`/`<remote port>` in that repo's deploy docs
(BoDAT: `bodat-mini` on the office LAN, `bodat-remote` from outside, port 3000). If you
cannot find them, do not invent them — report `스모크 skip: tunnel route unknown (<repo>)`.

**Output contract.** One line per check item with `pass`/`fail`/`skip` and a rationale,
then a final summary `스모크: <passed>/<total> 통과` (or `스모크 skip: <reason>`).
Read-only — make no direct changes.

--- verify URL ---
<VERIFY_URL>

--- check items (deploy issue `## 라이브/하드웨어 검증 항목`) ---
<LIVE_CHECKS>
