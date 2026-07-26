# SSH keepalive — Phase-0 spike results (issue #55)

Status: **INCONCLUSIVE.** No runtime change, no `patches/` change, no blob rebuild.
An instrumented re-run destabilized the first pass's conclusions and surfaced a
methodology confound, so the earlier "proven" verdict is **withdrawn**. Do **not**
merge, do **not** begin production implementation. A final bounded, deterministic
transport-level diagnostic (no GUI automation, direct SSH evidence) is required before
#55 can be decided. See "Current status" and "What the re-run changed" below.

## Current status (accurate)

- **`ConnectTimeout`**: works in the isolated initial-connect test (ssh stuck
  `SYN_SENT`, exits at ~7.2s honoring `ConnectTimeout=8`). This is a separate
  mechanism from `ServerAlive*`.
- **Keepalive on an idle/quiescent SSH control**: reliably terminates the connection.
  Isolated controls (a `sleep` remote command over the exact Unison arg layout, and a
  plain idle ssh) disconnected at ~16–17s under the blackhole.
- **Keepalive behavior during an *active* Unison session**: **UNRESOLVED.** The app's
  `unison -server` transport did **not** terminate within the observation window in
  the re-run, but those runs were partly confounded (below) and the evidence was
  time-based, not keepalive-protocol-based. Neither "reliably fires" nor "never fires"
  is established.
- **External cleanup** (remote `Unison -server` exit, child reap, no orphan): observed
  **only in runs where the SSH transport actually exited.** Not established for the
  active-session case where SSH did not exit.
- **Same-process engine reuse**: **UNPROVEN.** No clean `restartRequired` was reached
  in the re-run, so the coordinator's in-process reopen behavior was never tested.
- **Fresh-process recovery** (quit + relaunch): observed in the first pass, but this is
  **not** same-process reuse and must not be counted as such.

Explicitly **withdrawn** claims (previously asserted, now unsupported):
1. that the design's central claim is *proven*;
2. that established scan/sync loss *reliably* triggers keepalive;
3. that the app is *quiescent* or *same-process reusable* after a loss;
4. that a full TCP send buffer *prevented keepalives from being counted* — this was an
   unverified hypothesis and is retracted; the active-session mechanism is unknown
   pending direct SSH (`-vvv`) evidence.

## What the re-run changed

A second, instrumented pass could **not reproduce** the first pass's clean
"keepalive kills the transport at 15.33s during scan" result. Instead:

- A `sleep`-remote-command control over the **exact** Unison arg layout (all `-o` after
  the host) disconnected cleanly at **16.35s** — so post-host `ServerAlive*` is honored
  and keepalive works on an idle channel.
- The app's active `unison -server` transport **survived 40–150s** under a bidirectional
  blackhole across multiple runs, including at least one clean first-sync run.
- The distinction (idle dies / active survives) is real, but the *reason* is not
  established, and several later runs were confounded (below), so this pass yields a
  **question, not a verdict**.

### Methodology confound: archive-state contamination

During the re-run, local Unison archive files (`ar*`/`fp*` in the throwaway `UNISON`
dir) were deleted between runs while the **remote** side kept its archives. Unison then
detected an archive mismatch (confirmed by a CLI sync that erred with
*"Archive … on host Heracles is MISSING / … on host Demeter should be DELETED"*). In
that state the app was not cleanly scanning, so any run after the first archive deletion
cannot be read as a clean "loss during active scan." This is a **rig methodology bug**,
not an app defect, and it must be eliminated structurally in the next pass (unique
per-run archive dirs on **both** sides; never delete one side only).

Other confounds in the re-run: GUI/AX-driven timing was fragile, injection was not
always confirmed to land in the intended phase, and classification relied on elapsed
time rather than SSH keepalive request/timeout evidence.

## Superseded first-pass evidence (retained, NOT relied upon)

The following is the original first-pass record. It is preserved as historical evidence
only; its "proven" conclusions are **withdrawn** per the re-run above.

> **Fault A — ConnectTimeout**: ssh `SYN_SENT`, died ~7.2s; clean *"Couldn't connect …
> Operation timed out"* modal; app alive, no hang. (This one still stands — it is the
> `ConnectTimeout` path, not keepalive.)
>
> **Fault B — loss during SCAN**: reported transport self-exit at 15.33s (= 5×3),
> *"Lost connection with the server"*, "quiescent" (no locks/half-open fds/orphan),
> reuse via fresh launch. **Not reproduced in the instrumented re-run; withdrawn.**
>
> **Fault C — frozen server** (SIGSTOP): transport stayed alive 25s → keepalive blind to
> a frozen server; 120s watchdog is the backstop. (Consistent with keepalive being a
> dead-socket-only signal.)
>
> **Loss during SYNC** (mid 1.5 GB transfer): reported transport death at 18.4s,
> partial `.unison.*.tmp` retained (final absent, no corruption), reuse resumed the
> partial. **Not cleanly reproduced; the sync re-run was truncated/confounded;
> withdrawn.**
>
> **Qualification-refusal** (`ssh -G`): ControlMaster / ProxyJump / ProxyCommand /
> custom `sshcmd` each surface the disqualifying signal; direct SSH the only qualified
> case. (This stands — it is a `ssh -G` classification fact.)

## Rig notes (for the next pass)

- Client Heracles (192.168.2.31); server Demeter (192.168.2.35), a **non-root** temp
  `sshd` on port 45872; unison 2.54.0. `UNISON=<dir>` isolates profiles + archives (the
  GUI app inherits it only when the binary is launched directly, not via `open`).
- Fault injector: a PF anchor `com.apple/u55`, **dst-port-scoped** to 45871/45872 only
  (never :22, never host-wide); a bidirectional drop is a truer blackhole than
  outbound-only. PF initial state (Disabled) is captured and restored.
- macOS 26.5 does **not** expose `log config --mode private_data`, and `TraceLog`
  messages are `%{private}@`, so unified logging cannot reveal app internals — a
  temporary Debug-only file/event sink (reverted after) is required to read phase /
  bridge-return / fatal-routing / coordinator state.
- Enabling PF triggers a transient macOS *"Private Relay Unavailable"* notice (rig
  artifact, clears on restore).

## Required next diagnostic (bounded, deterministic; not yet run)

Transport-level, no GUI automation, no production change. Gate order: idle SSH control →
controlled backpressured channel → clean Unison scan → clean Unison sync with completed
output/hash verification; apply the network fault **only after** the intended phase is
positively identified; observation window long enough to distinguish a **delayed**
keepalive from **no** keepalive. Capture direct SSH evidence: `ssh -G`, `ssh -vvv`
stderr (look for keepalive request/timeout messages, not elapsed time), exact child PID
+ 5-tuple, installed PF rules at fault time, packet capture + socket Recv-Q/Send-Q.
Eliminate archive contamination structurally (unique per-run archive dirs on both sides;
fresh roots; record paths per result). **Require repeatability** in both clean scan and
clean sync before any app-reuse conclusion.

**Decision rule:** if keepalive remains unreliable during active Unison work, #55 is
**not** viable as a production "bounded failure during active scan/sync" feature — record
it as useful for idle/dead-socket detection only, and do not build a profile UI around
an unreliable guarantee.

## Recommendation

Treat #55 as **open pending the diagnostic above**. No production mechanism, no profile
UI, no blob work until the transport gate passes with repeatable evidence. `#33`/`#34`
and the 120s watchdog remain the current recovery path and are unchanged.
