# SSH keepalive — Phase-0 spike results (issue #55)

Status: **feasibility spike results, for review.** No runtime change, no `patches/`
change, no blob rebuild. The reduced live matrix from
`docs/ssh-keepalive-qualification-design.md` §7 was executed against an isolated
throwaway rig. This document is the retained evidence + verdict. **Stop here for
review before choosing any production mechanism** (design §8).

## Rig (all throwaway, torn down after)

- **Client** Heracles (192.168.2.31), Debug app, launched with
  `UNISON=<throwaway dir>` + `UNISON_AUTOTEST_PROFILE` (never touched the real
  `~/.unison`).
- **Server** Demeter (192.168.2.35): a **non-root** `sshd` on a dedicated high port
  **45872** (dedicated hostkey + throwaway key, isolated `/tmp` roots), remote
  unison 2.54.0. No sudo was needed for the endpoint.
- **Fault injector** a PF anchor `com.apple/u55`, **dst-port-scoped** to 45871/45872
  only (never port 22 / never host-wide); PF initial state (Disabled) captured and
  restored; every run trap-flushed the anchor. Selectivity was verified live: :45871
  dropped, :45872 open, **:22 (manual SSH) untouched**.
- **Keepalive under test** `ServerAliveInterval=5 ServerAliveCountMax=3` (≈15s
  threshold), supplied as **explicit `sshargs`** in the throwaway profile (no
  injection — there is no session-scoped injection point; design §5).
- **Evidence** process/5-tuple timing (`lsof`/`ps`), filesystem (locks/partials),
  AX window text, and screenshots. macOS 26.5.2 does not expose the
  `log config private_data` toggle, so the app's `%{private}@` logs were not read;
  classification is from observable process/UI/filesystem state.

## Results (raw)

### Fault A — ConnectTimeout (initial-connect, :45871 silently dropped)
- ssh child spawned, stuck **SYN_SENT** (silent drop confirmed), **died at ~7.2s**
  (honoring `ConnectTimeout=8`).
- Coordinator outcome: modal **"Couldn't connect to 'spike-ct'. ssh: connect to host
  192.168.2.35 port 45871: Operation timed out. The connection closed before it
  could be established."**
- App alive, 0% CPU (no hang). Child gone, no leftover.
- **Verdict: ConnectTimeout bounds the initial-connect blackhole cleanly**; distinct
  from keepalive (design §6). This is the `ConnectTimeout` path, not `ServerAlive*`.

### Fault B — established-session loss during SCAN (:45872 dropped mid-scan)
- Transport child (`Unison -server`) ESTABLISHED, tuple `…:52713 → …:45872`.
- PF armed mid-scan; **transport child self-exited at arm→death = 15.33s = exactly
  5 × 3**. Keepalive fired precisely on schedule.
- App CPU **67.5% → 0.0** (engine stopped, no spin/deadlock).
- Coordinator outcome: modal **"Unison error — Lost connection with the server"**.
- **Quiescence**: no lock files, **no app fds to :45872** (no half-open socket),
  **no orphaned remote `Unison -server`**, child fully reaped.
- **Reuse**: a fresh launch on the same profile re-established and scanned cleanly.
- **Verdict: EOF → clean unwind → quiescence → reuse — PROVEN for direct SSH.**

### Fault C — frozen `unison -server` (negative control; SIGSTOP, socket alive)
- SIGSTOP'd the remote server; **transport child stayed ALIVE 25s** (well past the
  15s keepalive threshold). Keepalive is **blind to a frozen server** (sshd answers
  independently of the frozen app) — the disjoint-failure-class claim, confirmed.
- The 120s scan watchdog remains the backstop for this class (prior-validated, #51).

### Established-loss during CONNECT
- The connect/opening phase is sub-second for a healthy SSH + fast `init2`, so a 15s
  keepalive cannot act strictly *within* it; injecting at establishment yields the
  same clean "Lost connection" outcome (resolving in early scan). No distinct
  failure mode.

### Established-loss during SYNC (mid 1.5 GB transfer)
- Transfer reached ~87 MB; PF armed; **transport died at 18.4s** (slightly longer
  than 15s — in-flight data delays the idle timer).
- Coordinator outcome: **"Lost connection with the server"**; reconcile showed
  "Synchronizing · 1.57 GB".
- **Partial written to `.unison.<name>.<hash>.unison.tmp`; final `bigxfer.bin`
  ABSENT** — Unison's temp-then-atomic-rename, so **no corrupt final file**. No locks,
  no half-open fds.
- **Reuse + resume**: a fresh launch resumed from the retained partial
  (**87 MB → 578 MB in 10s**) — the interrupted transfer continues, temp consumed on
  completion. No corruption, no manual cleanup needed.

### Qualification-refusal (deterministic, via `ssh -G`)
The exact disqualifying signals `SSHTransportQualifier.classify()` keys on all
surface deterministically:
- ControlMaster → `controlmaster auto` + `controlpath …`
- ProxyJump → `proxyjump jumpuser@[…]`
- ProxyCommand → `proxycommand /usr/bin/nc %h %p`
- custom `sshcmd` → profile-level short-circuit (no `ssh -G` spawn)
- plain direct SSH → `controlmaster false`, no proxy → **the only qualified case**.
(These are also asserted by the existing `SSHTransportQualifierTests`.)

## Verdict

The design's central **unproven** claim is now **proven for the qualified
direct-SSH transport**: an established-session network loss with keepalive set makes
ssh self-exit at exactly `interval × countmax`, the engine observes EOF and surfaces
**"Lost connection with the server"**, and the app reaches a **quiescent, reusable**
state — no locks, no half-open sockets, no orphaned remote server, no corrupt files;
reuse (and mid-transfer resume) works. Keepalive is confirmed to be a **dead-socket
detector only**: it is precise on real network loss and **blind to a frozen server**
(that class stays on the 120s watchdog). Unsupported transports refuse
deterministically.

**Coordinator-outcome classification** (design §7): every keepalive-fired cell landed
as **"engine unwinds cleanly → 'Lost connection' → re-open"** (a clean terminal
error + restart/reopen), with reuse proven by fresh launch. In-process auto-recovery
was not exercised; it is not required.

## Caveats / notes

- **`ConnectTimeout` and `ServerAlive*` are complementary and were validated
  separately** (Fault A vs B/sync), as designed.
- Enabling PF made macOS report **"Private Relay Unavailable"** for the rig's
  duration (Apple disables Private Relay under an active firewall); it cleared when PF
  was restored to Disabled. This is a **rig artifact**, not product behavior.
- Demeter's `unison` re-execs the GUI app bundle (`/Applications/Unison.app/.../Unison
  -server`); server mode still works headless. Environment quirk only.
- Raw evidence (timelines, screenshots) lived under the throwaway `/tmp` rig and was
  removed with teardown; the raw timings/outcomes are transcribed above.
- `SSHTransportQualifier` is not yet wired into the open path; refusal was shown at
  the `ssh -G` decision level it consumes, plus its existing unit tests.

## Recommendation (unchanged from design §8 — for review, not yet implemented)

The spike **supports** adopting keepalive as a **bounded, direct-SSH-only** optimization
for the dead-socket class, gated by `SSHTransportQualifier`, with the frozen-server
class staying on the 120s watchdog and #33/#34 unchanged. The remaining decision is the
**production mechanism** — an explicit per-profile keepalive setting that visibly
updates `sshargs`, **or** a separate bridge/blob session-override proposal. **No
automatic invisible injection.** Stopping here for that decision.
