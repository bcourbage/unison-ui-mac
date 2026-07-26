# Design Proposal: Transport-liveness heartbeat (issue #41)

Status: draft for review. Post-0.3.x; requires a vendored-blob / `patches/` change and the full vendor-bump checklist.

Related: #33 (scan-stall status-string proxy, merged), #34 (sync-stall advisory, merged), #53 (in-process interruption residual for non-direct transports), #24 (closed). See also `docs/scan-interruption-design.md`.

## 1. Purpose

Give the app an **authoritative** signal of remote-transport liveness, so "is the peer alive?" is answered by evidence from the RPC transport rather than by proxies inferred without it. This lets the two existing stall detectors escalate from *advisory / marker-coupled* to *confident*, and is a prerequisite for interrupting non-direct transports (#53).

## 2. Baseline: what ships today

Two detectors both **infer** liveness from blob-free signals:

- **Scan-stall (#33/#24, `ScanStallTimer`).** Fatal → `.restartRequired` after 120 s of no scan-status **once** the engine emitted `"Waiting for changes from server"` (`ScanStallPolicy.marksRemoteWait` latches `sawRemoteWait`). Before that marker a stall is `keepWaiting` (a local/TCC pause, not a remote wedge).
- **Sync-stall (#34).** Downgraded to a **non-fatal advisory** notice, because callback silence during propagation ≠ death (sparse-callback / throttled / callback-less sub-phases all look identical to a wedge).

Both are safe but limited: #33 is coupled to a status **string** (silent loss on a vendor bump would drop the #24 escalation — guarded only by the vendor-bump checklist + a pre-release attended frozen-server test), and #34 cannot be made actionable without false positives.

## 3. The gap

Neither signal is liveness:
- "No scan-status for 120 s" conflates a dead peer with a healthy-but-slow remote walk (see `scan-interruption-design.md` §3 and the #51 live matrix: a healthy 1M-file remote-wait can sit silent for tens of seconds).
- "No progress callback" during propagation conflates a dead transfer with a large-file / throttled transfer.

The missing primitive is a **transport-level "still receiving from the peer" tick** that is independent of application-layer progress.

## 4. Proposal

Add a small **engine → bridge heartbeat**: the OCaml RPC transport records last-inbound-activity and surfaces it to Swift through a registered callback.

Two candidate shapes (pick during the spike, §7):

- **(H1) Last-activity timestamp (pull).** The transport stamps a monotonic "last byte received from peer" on every inbound RPC frame. A new bridge accessor `unison_bridge_transport_last_rx_age()` returns the age. Swift's timers compare age to a threshold. *Pro:* no new callback cadence, cheapest patch. *Con:* pull cadence still lives in Swift.
- **(H2) Liveness tick (push).** The transport fires a registered callback (`installTransportLivenessHandler`) on each inbound frame (coalesced to ≤1/s). Swift resets a liveness deadline on each tick. *Pro:* symmetric with the existing status/progress handlers; naturally coalesced. *Con:* one more always-live callback on the hot path.

Both are strictly **inbound** (bytes *from* the peer). Outbound activity (us sending) is not liveness — a wedged peer still accepts our writes into the socket buffer.

## 5. Where it lives (OCaml side)

The RPC receive path in `remote.ml` is the single choke point where inbound frames are decoded (the same layer whose `at_conn_close` / `lostConnection` handling the lock-release analysis in `scan-interruption-design.md` already touches). The patch stamps/ticks there, behind the existing `patches/` (uimacbridge / remote) mechanism, so it is:
- **transport-generic** — covers both `init2` scan and propagation, direct and non-direct transports (it observes the socket, not the ssh process topology);
- **phase-agnostic** — one signal the Swift detectors consume in whichever phase they are armed.

Swift consumes it in `AppDelegate` alongside `noteScanProgress()` / `noteConnectProgress()`; the existing `ScanStallTimer` / sync-stall timer keep their arming/gating and simply gain a second, authoritative reset source.

## 6. What it unlocks

- **#33 → robust.** Arm the fatal remote-stall on *heartbeat age*, not the status string. Removes the marker-drift coupling; the string becomes a supplement, not the trigger.
- **#34 → actionable.** A propagation stall with a stale heartbeat is a *confident* wedge → can become fatal/restart-required without false-positiving on callback-sparse transfers. (Keep a generous threshold; §9.)
- **#53 → feasible for non-direct transports.** Interrupting a ControlMaster/ProxyCommand/custom-`sshcmd` transport can't rely on the single-tracked-child SIGKILL (#51's mechanism). A liveness signal lets the app *know* the transport is dead and route a confident teardown/restart there too.

## 7. Spike before commit

Timeboxed Phase-0-style spike (Debug-only), mirroring the scan-interruption approach:
1. Instrument the actual inbound cadence on the retained datasets (large-sync + many-small-file) to pick the threshold: categorize sparse-healthy vs throttled vs callback-less sub-phase vs real inactivity (this is the "#34 silent interval" instrumentation already noted on #41).
2. Prototype H1 and H2 behind `#if UNISON_DEBUG_HOOKS`; confirm both reset correctly on a healthy long remote-wait (no false fatal at 120 s+) and go stale within threshold on a frozen server.
3. Decide H1 vs H2 on cost/observability.

## 8. Test matrix

- **True positive:** frozen `Unison -server` past remote-wait → heartbeat stale within threshold → fatal fires (matches #51 case #5, but on the heartbeat rather than the 120 s status-silence proxy).
- **No false positive:** healthy scan/transfer that legitimately exceeds the threshold-window (large local walk with status; large remote walk; throttled transfer) → heartbeat keeps ticking → no fatal (matches #51 case #6, extended to the >120 s remote-wait that today's proxy can't distinguish).
- **Non-direct transport:** ControlMaster profile, frozen peer → stale heartbeat → confident restart (today: no signal).
- **Vendor-bump resilience:** the trigger no longer depends on the status string; a marker rename degrades gracefully to the string-supplement path, not a silent loss.
- Deterministic unit tests for the pure threshold/decision (as with `ScanStallPolicy`).

## 9. Risks / invariants

- **Threshold conservatism.** Set the liveness threshold well above the worst observed healthy silent interval (from §7 instrumentation) plus margin. False fatals on healthy-but-slow links are the cardinal risk; prefer a late-but-correct fatal.
- **Inbound-only.** Never treat outbound activity as liveness.
- **Coalesce (H2).** Cap tick rate so the hot path isn't flooded.
- **Blob discipline.** New patch + blob rebuild + full re-validation + vendor `README` provenance update (per the vendor-bump checklist). The heartbeat must be inert/absent when the callback isn't registered (older call sites keep compiling).
- **No behavior change without the signal.** If the heartbeat is unavailable (e.g., a build without the patch), the detectors fall back to today's proxies unchanged.

## 10. Open questions

- H1 (pull) vs H2 (push) — decide from the spike.
- Does `remote.ml` already expose a natural inbound-frame hook, or does the patch need a new interception point? (Confirm against the pinned commit.)
- Should the threshold be adaptive (scale with observed round-trip variance) or a fixed conservative constant? Start fixed.
- Interaction with keepalive (#55): ssh `ServerAliveInterval` detects a *dead socket*; the heartbeat detects a *silent-but-open* transport. Complementary; the spike should note whether keepalive's socket close already surfaces as an inbound EOF the heartbeat would catch.

## 11. Recommendation

Sequence #41 as the 0.4.0 flagship **paired with the next blob bump** (amortize the vendor-bump cost). Spike H1/H2 + threshold first (§7); ship the heartbeat; then, in order of value, (a) upgrade #33 to trigger on it, (b) make #34 actionable, (c) extend interruption to non-direct transports (#53). Do **not** ship any escalation on the heartbeat until the no-false-positive matrix (§8) passes on the retained datasets.
