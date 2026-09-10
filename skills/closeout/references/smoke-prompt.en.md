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

**The control socket path does not rely on variable handoff — copy the path printed in the
output, verbatim.** The snippet that opens the tunnel and the "clean up after the smoke"
snippet are **separate Bash calls**, so a shell variable (`CTL`) does not survive between
them. So the success line prints **the path itself** —
`tunnel ok on <port>, control socket <path>` — and the cleanup snippet copies that path
**verbatim** (it does not re-derive it from the port).

⚠️ **Mix a per-attempt random token into the path —
`/tmp/smoke-tun-<port>-<random>.sock` (8 bytes of `/dev/urandom` = 16 hex chars).**
Deriving the path from the port alone
(`/tmp/smoke-tun-<port>.sock`) makes it **predictable**, with no guarantee it belongs to
this invocation: a prior tick may have died before cleanup and left the socket file
behind, or a concurrent invocation may have drawn the same port and created a master at
that path. OpenSSH then prints `ControlSocket ... already exists, disabling multiplexing`
and still **succeeds at the forwarding**, non-multiplexed. Taking that as `PORT=$P;
CTL=$C` means the cleanup step's `-O exit` **kills someone else's live master**, while the
tunnel we actually just opened has no `CTL` to hold onto and leaks (#170).

**Do not try to prevent that with `-O check` — it does not prove ownership.** It says only
"a master is alive at that path"; it says *nothing about who created it.* If another
invocation creates a master at the same path between the pre-check and `ssh -M`, this
`ssh` falls back to non-multiplexed and succeeds while that `-O check` **attaches to the
foreign master and succeeds** — the exact accident we meant to prevent. So ownership is
established by the **path**, not by a check. A path with a random token in it cannot be
predicted and claimed by another invocation (you would have to guess 64 random bits); two
more problems disappear with it:

- Paths that aren't ours are **never touched** — no `rm -f` of someone else's `/tmp`
  socket on the assumption that a failed `-O check` means "our own dead leftover" (that
  check also fails when a live master fails to answer, or when a *different* socket owned
  by the same account happens to sit at that predictable path).
- The path is fresh, so the `disabling multiplexing` fallback never happens in the first
  place.

**`$$` (the shell PID) is not enough — this was measured.** In bash, `$$` stays the
**parent shell's PID** inside subshells, pipelines, and backgrounded subshells (measured on
bash 3.2: `parent=72353 subshell=72353 pipeline=72353 bg-subshell=72353`). If one shell
runs this snippet in two branches at once, both invocations get the **same path**, and the
moment they draw the same port (the draw is only 1000 wide, so this is not rare) the
accident above happens exactly as described — reproduced with a stub `ssh`. `$RANDOM` is
not relied on either: 15 bits (0–32767), and its subshell reseeding is implementation
specific. So each attempt reads 8 bytes from `/dev/urandom` (all four contexts of the same
shell yield different values).

**Be precise about what this guarantees and what it does not.** The random path guarantees
*we never adopt someone else's master as `CTL` through a path collision* — that far. What
it does not guarantee: if the master dies instantly after the bind, neither `-O check` nor
`-O exit` has anything to attach to, so the forwarder `ssh -f` already started **cannot be
stopped** (`pkill` is forbidden). All this recipe does in that branch is **print that it
could not stop it** (see "Left out of scope" below).

**The `-O check` right after binding stays — but as a liveness check, not an ownership
check.** On a unique path, no master found means "something went wrong on our side," not
"someone else's master." Don't count that attempt as a success (never carry that socket as
`CTL`) — and don't just drop the forwarder `ssh -f` **may already have backgrounded**:
tear it down best-effort with `ssh -S "$C" -O exit`, then move to the next port. If that
teardown fails too, **say so in the output** (never swallow it with `|| true` — it is the
only trace that a forwarder may still hold that port). Even if all five tries land here it
is still a local problem, so it folds into the same `tunnel port exhausted` as bind
collisions — the three-way verdict below is unchanged.

```bash
ERR=$(mktemp); PORT=""; CTL=""; ALL_BIND=1
for _try in 1 2 3 4 5; do
  P=$(( 39000 + RANDOM % 1000 ))
  U=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')   # per-attempt random (16 hex)
  if [ -z "$U" ]; then
    # No token, no predictable path — that predictability is the very defect this recipe removes.
    echo "unique token generation failed (/dev/urandom) — refusing a predictable path"
    continue                          # local problem → folds into tunnel port exhausted after 5
  fi
  C="/tmp/smoke-tun-$P-$U.sock"       # port + this attempt's random = a path no one can predict
  if [ -e "$C" ]; then
    # Practically unreachable on a random path (needs the same port AND the same 16 hex
    # digits). If it happens anyway it still isn't provably ours — don't remove it, redraw.
    continue
  fi
  if ssh -f -N -M -S "$C" -o ExitOnForwardFailure=yes \
       -L "127.0.0.1:$P:127.0.0.1:<remote port>" <ssh host alias> 2>"$ERR"; then
    # The path carries this attempt's random token, so a master found here is practically
    # never someone else's. Still confirm it is alive — on a random path a failed -O check
    # means "something wrong on our side," not "a foreign master."
    if ssh -S "$C" -O check <ssh host alias> >/dev/null 2>&1; then
      PORT=$P; CTL=$C; break          # healthy — the live master this invocation created
    fi
    # ssh -f may already have backgrounded a forwarder — don't drop it, tear it down
    # best-effort. If that fails too, don't swallow it: print why (the only trace that
    # this port may still be held).
    ssh -S "$C" -O exit <ssh host alias> >/dev/null 2>&1 \
      || echo "control socket teardown failed (a forwarder may remain on port $P): $C"
    continue                          # this attempt does not count as success — next port
  fi
  # The stderr ExitOnForwardFailure=yes produces on a bind failure is "bind: Address
  # already in use" (or similar) — that's what this grep matches. Non-bind failures it
  # does NOT match: "Could not resolve hostname" (DNS) · "Connection refused"/"No route
  # to host" (host down, routing) · "Permission denied" (auth failure). Those are
  # pointless to retry on another port, so break immediately.
  grep -qi 'bind\|address already in use' "$ERR" || { ALL_BIND=0; break; }   # remote/path problem
done
if [ -z "$PORT" ] && [ "$ALL_BIND" = 1 ]; then
  echo "tunnel port exhausted"        # five bind collisions (or no live master / no token) — a local problem, not unreachable
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

The `-O check` above judges only **whether the master this invocation created is alive** —
no socket at all (proceed normally) and a failed check (something wrong on our side →
best-effort `-O exit`, then next port) are distinct meanings, so their exit codes are
never collapsed into a single `|| true`. Ownership itself is established by the random
token in the path, not by this check.

**Left out of scope — the already-backgrounded forwarding process when both `-O check` and
`-O exit` fail.** On a random path a foreign master is practically never involved, so anything landing
in this branch is our own anomaly (e.g. the master died instantly). The forwarder `ssh -f`
already backgrounded then has no control socket, so it can't be stopped via `-O exit`, and
`pkill` is forbidden (see above) — which is why **printing that we could not stop it** is
part of the contract. This is rare and its blast radius is a single occupied local port.
Tracking the child's PID to also kill this residual process is left out of scope.

**On `tunnel ok`, leave the tunnel up and run the whole Chrome smoke through it** — tearing
it down right after the probe means you never see the screen you came to check (all you
verified is `/up`). `CTL` is a path stamped with that attempt's random token, so for `-O exit` at cleanup time
to reach someone else's master another invocation would have to guess those 16 hex digits —
that low a risk, not "no risk." The master could also have died in the meantime (normal
exit or crash) while the smoke ran long, so the `-S` existence check below stays in place.
Clean up after the smoke finishes, once, on **every** path — pass,
fail, or abort — by copying the path printed above **verbatim** (don't re-derive it from
the port; the random token **cannot be regenerated** — the printed string is its only
source):

```bash
CTL="<control socket path from the tunnel snippet's output>"   # e.g. "tunnel ok on 39441, control socket /tmp/smoke-tun-39441-9f3c1a7b2d5e4068.sock" → /tmp/smoke-tun-39441-9f3c1a7b2d5e4068.sock
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
