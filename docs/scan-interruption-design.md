# Scan-phase interruption: decision record (issue #53 / #24 follow-up)

**Repo:** unison-ui-mac  ·  **Status:** DECISION RECORD (supersedes the
implementation proposal preserved below). Pinned upstream: `bcpierce00/unison`
v2.54.0, commit `91421d0` (see `vendor/README.md`).

## Decision

Downstream in-place scan cancellation is **not planned**. The application will
not stop an in-flight update-detection scan and then reuse the same embedded
Unison engine, because no available downstream mechanism can prove the engine's
state is consistent for that reuse. This is a safety decision, not a statement
that cancellation is impossible or unwanted; the user-visible limitation is
real and accepted. Sync-time Stop is a separate, supported feature and is
unaffected (see the last section).

## Safety invariant

An active scan owns the engine lease until the scan's own genuine terminal
callback fires. Nothing — not a user leave, not a window close, not a queued
profile — may release or reuse that engine before then. Presentation may be
abandoned; the engine may not.

## Current application behavior and its limitations

**Version status.** This describes `main` at and after PR #92 (commit
`27a1ddb`), which is the baseline for this decision record and ships in
**v0.5.1**. The currently released **v0.5.0 still contains the superseded
mechanism**: with a qualified direct-SSH scan past remote-wait, v0.5.0 can enter
`.interruptingScan` from Stop Scan / Profiles / window close, SIGKILL the
transport, accept any matching terminal, and reuse the embedded engine. Do not
read the guarantees below as true of v0.5.0. On v0.5.0, if a remote scan hangs,
quit and relaunch rather than Stop Scan followed by Rescan. See issue #94.

On `main` after PR #92, in-place interruption is disabled at the shared policy
gate (`ScanInterruptPolicy.stopInPlaceEnabled == false`,
`ScanInterruptPolicy.swift:45`, folded into `interruptReady` at `:22`). Stop
Scan, Show/Return to Profiles, and window close therefore cannot enter
`.interruptingScan`; every leave takes the Return-to-Profiles fallback:

- It abandons **presentation only** — detaches the reconcile window and shows
  the picker (`AppDelegate.leaveSession` → `engine.abandon` at
  `AppDelegate.swift:595`, `showProfilePicker` at `:596`) — and marks the op
  abandoned without claiming the OCaml scan stopped
  (`EngineSessionCoordinator.abandon`, the `.opening/.scanning/.syncing` case at
  `EngineSessionCoordinator.swift:465`).
- The engine lease is retained while the original scan continues; a
  later-selected profile is **queued**, not started
  (`requestOpen` queue path, `EngineSessionCoordinator.swift:353`/`365`/`381`).
- Destructive archive maintenance stays forbidden while the abandoned scan owns
  the engine (`allowsDestructiveArchiveMutation` is true only for `.idle` /
  `.stopped`, `EngineSessionCoordinator.swift:326`/`331`).
- Queued work starts only after the scan's genuine terminal and, **for a remote
  session, a successful connection close**; a local-only session has no
  connection to close. Abandoned `scanCompleted` → `beginClose` (`:704`); for a
  remote (`.open`) connection that closes and `closeCompleted(status: 0)` →
  `finishToIdle` → queued open (`:751`), while for `.localOnly` / `.disconnected`
  `beginClose` goes straight to `finishToIdle` (`:832`–`:835`, no close); a
  failed remote close → restart-required (`:775`).

Accepted costs of this fallback:

- **Leaving does not cancel the scan.** The local traversal or remote wait keeps
  running (CPU, disk, and for remote the ssh connection and remote
  `unison -server`) until it finishes on its own.
- **Another profile may wait** until that scan terminates and its close
  succeeds.
- **Archive maintenance stays blocked** meanwhile.
- **A pre-remote-wait stall may require quit/relaunch.** A wedge *after* Unison
  reports it is waiting on the remote is bounded by the 120-second watchdog and
  becomes restart-required (`ScanStallPolicy.actionOnStall`, consumed at
  `AppDelegate.swift:1975`; the remote-wait branch at `:1987`). Silence
  *before* the remote-wait phase — local traversal, hashing, or a macOS TCC
  pause — is deliberately **unbounded** (`.keepWaiting` re-arms, `:1999`),
  because it cannot be safely distinguished from a legitimate local delay.
  Quit/relaunch is the escape.

## Why PR #92 disabled the previous mechanism

The earlier design SIGKILLed the scan's transport child and then reused the
engine as `.stopped`. Its safety depended on recognizing the interrupted scan's
own terminal, but no terminal event carries a structurally authenticated cause:
a `scanFailed`, or an unrelated fatal racing the kill, is indistinguishable on
the wire from the kill's own transport EOF. Accepting such a terminal as the
expected one laundered a normally restart-required engine into reusable state.
PR #92 closed that fail-open path with a typed callback→event→cause mapping
(`EngineSessionCoordinator.cause(for:)`) that **centrally classifies the
reported callback source and fails closed for `scanFailed` and generic-fatal
events**, so only a clean completion may wind the engine down. This is
classification, not causal authentication: it does not prove a terminal was
*our* interruption (the final bridge-handler → named-registrar-method hop is
intentionally not covered end-to-end), only that the reported callback kind is
handled fail-closed.

That classification is **necessary but not sufficient** for safe reuse, and it
is not a re-enable recipe. Even a terminal proven to be a clean cancellation
would still not show that Unison's global caches, Fpcache state,
archive state, RPC channel, update-traversal state, and repeated embedded
invocation are internally consistent afterward. PR #92 makes the app safe (on
`main`, shipping in v0.5.1) by *disabling* reuse, not by making it provable.

## Rejected approaches

- **Transport SIGKILL as cancellation.** Killing the ssh child does not
  cooperatively unwind the OCaml scan; the terminal it produces is
  unauthenticated (above), and a CPU-bound local walk is not on the transport at
  all, so the kill does not reach it.
- **Killing shared / non-direct SSH transports** (ControlMaster, ProxyCommand,
  ProxyJump, custom `sshcmd`). A transport-ownership problem: killing a shared
  master or a proxy with descendant processes is unsafe and out of the app's
  control.
- **Reusing the propagation-global `Abort` during scanning.** `Abort` is a
  propagation checkpoint (consulted in `copy.ml` / `files.ml`); update traversal
  (`update.ml`) does not consult it and has no equivalent supported checkpoint.
- **Treating terminal causality as proof of complete engine consistency.** The
  PR #92 cause mapping classifies the reported callback source and fails closed;
  it neither authenticates that a terminal was our interruption nor speaks to the
  aggregate engine state.
- **A downstream OCaml cancellation patch** (safe points + exception-safe
  unwinding in `update.ml`) without upstream-supported invariants. This would
  fork engine-internal control flow with no supported contract for archive
  commit/rollback or global-cache consistency, exactly the guarantees the app
  cannot provide from outside.

## Upstream requirements for reconsideration

The narrow, defensible reading of the pinned upstream source and the cited
issues:

- Upstream provides cooperative cancellation during **propagation** via `Abort`
  (`abort.mli`, checked in `copy.ml`/`files.ml`); **scan / update traversal
  exposes no equivalent supported cancellation contract** (no `Abort` reference
  in `update.ml`).
- Ctrl-C outside supported propagation cancellation **terminates the process**
  rather than promising the embedded engine remains reusable (upstream
  [PR #810](https://github.com/bcpierce00/unison/pull/810)). The defensible
  statement is that safe in-process scan cancellation is **unsupported and its
  cleanup/reuse guarantees are unspecified** — not that upstream is deliberately
  protecting a specific invariant, which maintainers have not stated.
- Upstream [issue #1148](https://github.com/bcpierce00/unison/issues/1148) is
  **corroborating evidence** that global-state integrity is a real concern in
  the macOS-GUI (embedded, multi-invocation) class; it is not, on its own, proof
  of a particular concurrency mechanism absent maintainer analysis.

A bare upstream "cancel requested" primitive would **not** by itself make reuse
safe. Reconsideration requires an upstream contract that defines and enforces
**all** of:

1. safe cancellation checkpoints in update detection;
2. exception-safe unwinding;
3. archive commit / rollback guarantees;
4. Fpcache and other global-cache consistency after cancellation;
5. RPC-channel teardown or reuse guarantees;
6. worker quiescence;
7. supported repeated same-process invocation after a cancellation.

If upstream provides that complete contract, the app would still need UI and
lifecycle coordination, but it could become much smaller — relying on the
supported primitive instead of transport or process manipulation. Only then
should this be revisited, in a **new** issue, not by reopening the design below.

## Supported alternative: sync-time `Abort.all`

This decision concerns **scan / update-detection** cancellation only. Cancelling
an in-flight **propagation** is supported and unchanged: the coordinator routes
Stop during a running sync to `.abortSync` (`EngineSessionCoordinator.swift:499`),
which drives Unison's `Abort.all` propagation checkpoints. That path leaves both
sides consistent (temp files may remain, harmless) and is not affected by
anything above.

---

# Historical design material (superseded)

Everything below is the original stop-in-place implementation proposal,
preserved for its empirical evidence (the Phase-1a experiments, the process-
identity classification work, the live matrix). Its **reuse conclusion is
superseded** by the decision record above; do not treat the stop-in-place
outcome it specifies as supported or as a re-enable plan.

**Round-3 changes.** Per the round-2 review: (B1) consolidated into one
standalone document, v1's incorrect "synchronous blocking init2" statement
replaced and the Ctrl-C/`select()` explanation softened; (B2) rung-4
verification replaced with post-terminal OS process-identity classification
(retire-tracing proves retirement, not reaping — confirmed: every patched call
site runs `!retireTransportChild pid` before `waitpid`/`close_session`, whose
failures are swallowed; there is no `end_ssh` external); (B3) added the
Debug-only, operation- and PID-bound "expected scan interruption" state — the
existing fatal routing terminates in `.restartRequired` and cannot drive the
reopen experiment; (B4) quarantine stated as a one-way process state — with the
verification that the coordinator **already refuses** `requestOpen` in
`.restartRequired`, so this is asserted, not built; terminology corrected
(process exit resolves the zombie via OS reparent-and-reap, not the shutdown
reaper). Refinements adopted: no premature ssh-configuration refusal (if ever
needed, derive effective config via `ssh -G`); gate reworded to "zero
unexplained failures"; honesty copy is "Return to Profiles"; keepalive testing
isolated to the throwaway test VM. New this round: (C1) the expected-
interruption state must define precedence with the armed `ScanStallTimer` for
the same operation.

---

## 1. Purpose

Decide, on evidence rather than assertion, whether the GUI can stop a wedged or
slow in-flight `init2` scan **without quitting the app**, and if so, specify
the implementation. Structured as a feasibility spike first (Phase 0) and a
product change second (Phase 1a/1b), because the cost/risk profile turns on
empirical unknowns.

## 2. Baseline: what 0.3.0 ships

- **Automatic bound:** `AppDelegate.ScanStallTimer` (Swift-only, remote-only,
  operation-bound, 120 s, reset on OCaml scan-status, retained across UI
  abandonment; fatal only after the engine emits "Waiting for changes from
  server") carries a post-authentication transport wedge to
  `operationFailed(engineIsQuiescent:false)` → the coordinator's
  `.restartRequired`.
- **Escape hatches:** credential-sheet **Cancel** exits credential entry; in
  the no-sheet connect/scan phase, **Stop** performs `onCancelScan` →
  `leaveSession` → `engine.abandon()` → picker.
- **Recovery from a wedge:** quit and reopen.

## 3. The residual gap (corrected from v1)

None of Cancel / Stop / the detector unwinds the already-issued OCaml scan.
`unison_bridge_init2()` **launches** the asynchronous scan worker
(`unisonInit2` → `doInOtherThread (do_unisonInit2)`; `uimacbridge.ml:405`) and
returns after the synchronous dispatch — `_ocaml_init2`'s comment: "Scan runs
async; this covers the synchronous dispatch" (`UnisonBridgeC.c:1684`).
`abandon()` detaches only the UI. For a remote profile the in-flight update
detection therefore keeps running in the background: a lingering remote
`unison` child and wasted bandwidth until it finishes on its own or the app
quits. The scan is not interruptible via the propagation `Abort` mechanism:
`Abort.check`/`checkAll` are consulted only in `copy.ml`/`files.ml`, never in
`update.ml`, so `Abort.all()` cannot cancel update detection — it stays gated on
`isSyncing`. (An earlier draft claimed setting the flag during a scan trips
`update.ml:1027 Assertion failed`. That line is `assert (!locked = false)` inside
`lockArchives` and is unrelated to `Abort`; the causal claim was never
established and is withdrawn.)

## 4. Upstream CLI evidence (softened per B1)

Checked against the vendored 2.54.0 source. Ctrl-C is two phase-dependent
behaviors, and neither is a graceful in-process scan cancel:

- **During propagation:** the SIGINT handler calls `Abort.all()`
  (`uitext.ml:921`); the transport honors the flag and stops with proper
  cleanup; the process survives. The GUI already has this (Stop during sync).
- **During the scan (`Update.findUpdates`, `uitext.ml:1312`):** there is no
  abort path. `Sys.catch_break true` converts SIGINT into a `Sys.Break`
  exception, which unwinds to `terminate ()` (`uitext.ml:1734`) and **exits
  the process**.
- **When wedged:** interruption may not take effect promptly; the manual's own
  guidance is to press Ctrl-C repeatedly to force termination
  (`intrcount >= 3 → raise Sys.Break`, `uitext.ml:920–927`), likened to
  SIGKILL, with a warning about inconsistent archives/replicas.

**Defensible conclusion (no stronger claim made):** upstream has no graceful
scan-cancellation-and-reuse primitive comparable to propagation abort. On the
CLI, interrupting a scan means terminating the process; the single-process-GUI
equivalent is quitting the app, which is what 0.3.0 ships. The CLI also kills
the ssh transport child on the way out (process group delivery plus the
`at_exit` SIGTERM→SIGKILL at `remote.ml:1940`) — which motivates the
hypothesis below.

## 5. Hypothesis

> **H1.** If, during a wedged or slow remote `init2`, the local ssh transport
> child is SIGKILLed, its pipe endpoints close, the blocked read inside the
> **async scan worker** observes EOF/EPIPE promptly as a terminal exception,
> the worker unwinds exactly once through terminal routing, and the in-process
> engine can then be closed, drained, and reopened cleanly.

Independently falsifiable sub-questions:

- **H1a (wake):** does the parked operation actually observe the closed fd
  promptly? Unproven for the frozen-peer case; the core question.
- **H1b (unwind):** exactly one terminal event, no duplicate or stale
  completion.
- **H1c (reuse):** engine reusable across repeated same-process cycles.

**Why the earlier experiment doesn't settle this:** the prior test froze the
*remote* server (SIGSTOP), leaving the local ssh child and pipes fully alive —
nothing closed locally. Killing the *local* child closes the local fds
directly; a materially different trigger.

**Scope:** Phase 0 tests **direct ssh only**. ControlMaster/ProxyCommand are
out of the spike: under ControlMaster the launched process is the mux client,
which owns the Unison-facing descriptors, so the mechanism plausibly still
works — but that is untested, and ProxyCommand helpers may inherit descriptors.
Neither a support claim nor a refusal is made now. If production ever needs
configuration detection, it must derive **effective** configuration via
`ssh -G` (profile-string inspection also misses `~/.ssh/config`, `Include`,
`Match`) and fail conservatively when effective configuration cannot be
established. Testing CM/PC happens after direct ssh succeeds, not before.

## 6. Debug-only primitive

`unison_bridge_reap_transport_children()` must not be called in-process: it
latches `g_children_closing`, which SIGKILLs every future tracked child at
registration (`UnisonBridgeC.c:1013`) — it would kill the reopen this
experiment exists to test.

New `UNISON_DEBUG_HOOKS`-gated primitive:

```
unison_bridge_signal_scan_transport(void) -> struct:
    outcome ∈ { SIGNALLED, NO_CHILD, MULTIPLE_CHILDREN, ALREADY_DEAD, SIGNAL_FAILED }
    pid, start_identity   (captured under the mutex when SIGNALLED)
```

- Requires **exactly one** tracked live child; structured refusal otherwise.
- SIGKILLs under `g_child_mutex`; leaves the pid **registered**; does not set
  `g_children_closing`; never `waitpid`s. OCaml remains the owner of
  retirement and reaping.
- Captures the child's **process start identity** (pid + `kp_proc.p_starttime`
  from the same `sysctl KERN_PROC_PID` record the bridge already uses,
  `UnisonBridgeC.c:1052`) before signalling, for §8 rung-4 classification.

**Quarantine (worker never unwinds).** If the terminal event does not arrive
within the teardown deadline (proposed 10 s for the spike):

- The operation routes to `.restartRequired` (unchanged user outcome).
- The SIGKILLed child remains a registry-retained zombie **by design**. No
  interim reap is attempted — an independent `waitpid` would race OCaml's
  ownership. The zombie's pid cannot be reused before reaping, and the
  registry entry is freed only by OCaml cleanup or process exit, so the
  pid-reuse race stays closed.
- **Resolution is process exit:** the OS reparents and reaps the zombie when
  the app terminates. (The shutdown reaper signals and clears the registry; it
  does not `waitpid`. It plays no reaping role here.)
- **One-way state, already enforced:** a quarantined outcome leaves the
  coordinator in `.restartRequired`, which refuses every subsequent open —
  `requestOpen` returns `[.restartRequired(reason:)]`
  (`EngineSessionCoordinator.swift:220`) — and has no exit transition. The
  user may defer the restart dialog but cannot start any engine operation
  until quit. The spike **asserts** this (quarantine + attempted reopen →
  refused) rather than building it.

## 7. Spike harness: the "expected scan interruption" state (B3, new)

The existing terminal routing cannot perform the reopen experiment: a
transport EOF during `do_unisonInit2` reaches the fatal/scan-failed routing,
which ends in `.restartRequired` (`AppDelegate.swift:936`, `:786`) — terminal,
no close/reopen. Phase 0 therefore adds a Debug-only, spike-scoped state:

- **Armed** immediately before invoking the primitive, bound to the exact
  `(SessionID, OperationID)` and the signalled pid + start identity. An
  unrelated fatal (different op, different session) is never reclassified.
- On the **matching** terminal callback: record the event (rung 3), run the
  §8 classification (rung 4), then — and only then — drive the verification /
  close-drain / reopen sequence (rungs 5–6).
- On deadline expiry with no matching terminal: disarm, route to
  `.restartRequired`, assert quarantine (§6).
- **Detector precedence (C1):** arming the state **disarms the
  `ScanStallTimer` for that exact operation**. Both authorities are
  op-bound; leaving both armed lets the 120 s detector and the spike deadline
  race to fire terminal decisions for one op, corrupting the exactly-once
  accounting the spike must measure. Debug-only, so production arming is
  untouched.

Ordering constraint (non-negotiable): the issue-#8 close/drain drives
`Lwt_unix.run` and is legal only from quiescence — "no `doInOtherThread`
worker is inside the scheduler while this drains" (`uimacbridge.ml:747`). The
sequence is always:

```
arm state → signal child → await matching terminal (deadline-bounded)
→ classify child identity → close/drain if still needed → reopen
```

`signal → immediate drain` is forbidden in every branch including error
handling.

## 8. Observability ladder

Every rung has a defined observation mechanism; a rung without one is dropped,
not assumed.

| Rung | Question | Observed via |
|---|---|---|
| 1 | Exact child SIGKILLed? | primitive's structured result (pid + start identity) |
| 2 | Blocked I/O woke? | timestamp delta: signal → rung-3 event (inferred from promptness) |
| 3 | Async worker terminal, exactly once? | §7 state: matching init2-complete / scan-failed / fatal callback, `TraceLog`-stamped, duplicate counter |
| 4 | Child actually reaped? | **post-terminal OS identity classification** (B2): re-query `sysctl` for the captured pid and compare start identity — (a) pid absent → reaped; (b) pid present, different start identity → reaped and pid reused; (c) same identity, `SZOMB` → not reaped; (d) same identity, live → teardown failed. Retire-tracing is NOT sufficient: retirement fires before `waitpid`/`close_session`, whose failures are swallowed. If classification proves insufficient and a true post-`waitpid` OCaml hook is needed, that is a vendored patch → **stop for approval**. |
| 5 | Engine + archive state reusable? | §9 acceptance checks |
| 6 | Repeated cycles survive? | §10 cycle matrix |

`unison_bridge_transport_child_terminated()` serves none of these rungs: it
returns "no evidence" once the registry entry is gone and reports a zombie as
terminated.

## 9. Archive integrity is an acceptance result

`Update.findUpdates` is not read-only: it runs crash recovery before loading
archives (`update.ml:1081`), acquires archive locks (`heldLocks`,
`update.ml:944–968`), and can write archive state. Every passing cycle must
independently verify:

- no replica file was propagated;
- no archive lock file remains (`lk` archive-name class);
- no unexpected scratch/temporary archive remains;
- the next scan loads archives cleanly (no recovery prompt, no
  `DANGER.README`-class state);
- a subsequent real sync completes and verifies.

Primary tests use profiles with **established** archives; first-run/no-archive
interruption is a separate row (crash recovery differs there).

## 10. Test matrix

The child-kill mechanism is peer-independent: a local SIGKILL closes the local
fds identically whether the peer is frozen, dead, or slow — the local child is
always healthy and killable. Frozen-peer and dead-host are therefore one case
for child-kill; dead-host remains distinct only for keepalive.

| # | Case | Repro | Trigger | Proves |
|---|---|---|---|---|
| 1 | Wedged worker | SIGSTOP remote `unison` server mid-`init2` | primitive | H1a/H1b for the wedge (core unknown) |
| 2 | Slow-but-progressing worker | force hashing (touch multi-GB synced files) | primitive | interruption of a healthy scan + archive acceptance |
| 3 | Control | case-1 setup, no trigger | none | wedge is real; detector fires at 120 s as today |
| 4 | Quarantine | case 1 if H1a false (or forced) | primitive | deadline → `.restartRequired`; reopen refused; zombie quarantined; app exit clears |
| 5 | First-run/no-archive | case-2 variant, fresh archives | primitive | crash-recovery path acceptance |
| 6 | Keepalive (separate; only if rungs 1–4 pass) | dead network/host, `ServerAliveInterval` set, **no manual kill** | ssh self-exit | whether ssh's own exit produces the same rung-3 unwind |

Repeated-cycle requirement: each passing case re-runs as interrupt→reopen
cycles — ≥10 same-profile, ≥5 alternating-profile, plus rescan-after-recovery
and full-sync-after-recovery (the issue-#8 validation bar). One clean reopen
proves nothing about residue accumulation.

**Isolation:** all cases run against the throwaway test VM (`.241`) with
disposable profiles/replicas — never against Demeter (live services, real sync
roots). Case 6's network disruption in particular must use a dedicated
host/path or isolated rule and must not disturb existing SSH sessions.

## 11. Decision gate: reliability, not existence

The failure fallback is `.restartRequired` — behaviorally identical to today
(user quits and reopens), and the user cannot tell in advance which case they
are in. A sometimes-works interruption therefore ships no improvement for the
wedge. The gate:

- **Adopt (Phase 1a)** only on **zero unexplained failures** across the full
  repeated-cycle matrix of cases 1, 2, and 5, with archive acceptance clean
  every time. A harness failure triggers diagnosis, not mechanical rejection;
  an *unexplained* failure fails the gate.
- **Case-2-only success** (healthy scans interruptible, wedges not) does
  **not** resolve #24 and does not clear this gate. It may justify a
  separately scoped "cancel a healthy slow scan" enhancement, to be proposed
  on its own merits with its own (lower) stakes.
- **Record-and-stop (Phase 1b)** on anything less.

**Phase 1a scope honesty:** productionizing is substantial — a
coordinator-authorized `.interruptingScan` teardown state (Stop today shows
the picker immediately, conflicting with proven-quiescence-before-picker); the
race matrix (scan completes just before Stop / just after signal; double Stop;
concurrent 120 s detector; window closed mid-interrupt; queued profile open;
stale completion afterward); CM/PC qualification or conservative detection per
§5; and the §6 quarantine machinery in production form. That cost is accepted
knowingly or Phase 1a is declined even on a passing spike.

**Phase 1b (unconditional, either branch):** the scan-phase Stop honesty
relabel. During a scan the affordance reads "Stop / Cancel the running
synchronization" with a "Cancelling…" summary, but no sync is running and the
scan is not aborted. Since the action merely detaches the UI, the copy must
not overstate even "stopping": action label **Return to Profiles**, temporary
summary **Returning to profiles…**. "Stop Scan" is reserved for a Phase 1a
that genuinely interrupts. Control stays enabled (it is the fast bail-out).
Low risk, correct regardless of H1, the item most likely to ship.

## 12. Keepalive: separate, gated, minimal

Keepalive (`ServerAliveInterval`/`ServerAliveCountMax`) is a distinct trigger
and policy, not a subset: it detects a dead network/host (it does nothing for
a frozen remote process behind a healthy `sshd`, which answers the probes),
and it carries its own configuration questions (ordering vs `sshargs`,
ControlMaster interaction, probe overhead). Phase 0 rungs 1–4 answer the
shared downstream question (does transport death produce a clean terminal
unwind); case 6 tests keepalive's trigger in isolation. Adoption is a
separate, later decision gated on both — never shipped on assumption.

## 13. Invariants

- A dialog never decides engine quiescence: terminal evidence → coordinator
  decision → presentation → destination (per #33/#35).
- Picker only after proven quiescence; unproven teardown → `.restartRequired`.
- Close/drain only from quiescence — never while a scan worker may be inside
  the scheduler (§7).
- OCaml owns child retirement and `waitpid`; the primitive never reaps, never
  latches shutdown; a quarantined zombie's registry entry is freed only by
  OCaml cleanup or process exit (§6).
- Blob and patches unchanged in Phase 0 and any Phase 1a. If rung-4
  classification proves insufficient and a post-`waitpid` OCaml hook is
  required, that is surfaced for approval first (§8), not folded in.
- Archive integrity is verified per cycle, not asserted (§9).
- Exactly one terminal authority per operation: arming the expected-
  interruption state disarms the stall detector for that op (§7).

## 14–16. Spike open questions, recommendation, and approval — REMOVED (superseded)

**DO NOT EXECUTE.** The original proposal ended here with Phase 0 spike
open-questions, a "Recommendation" to *execute Phase 0 as specified*, and a
"locked / approved after two review rounds / binding" Phase 0 approval block.
Those authorizations are **void**. In-place scan cancellation is **not planned**
(see the decision record at the top of this file); nothing in this document
authorizes implementing it. The imperative sections were removed so that a deep
link or search hit cannot be read as active authorization. Their original text
is preserved in git history.
