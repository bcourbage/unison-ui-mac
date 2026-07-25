# Design Proposal v2.1: Profiles / picker navigation during connect (issue #38)

Status: **approved for engineering** (accuracy corrections applied). 0.3.1 UX; **no vendored-blob change**. v2 corrected two incorrect assumptions in v1 (the leave path, and the root cause); v2.1 corrects two accounting errors per the approval review: (1) the connect watchdog does **not** terminate/reap the transport — it routes to `.restartRequired` with the child still live; (2) true connect cancellation is **not** gated on #41.

Related: #35 (fatal-ssh-as-prompt / `connection_cancel`, done), #51 (scan-interruption teardown, merged), #53 (true in-process interruption residual). Vocabulary: `docs/scan-interruption-design.md`.

## 1. Purpose and scope (corrected)

Make **navigation back to the profile picker reliably available during the connect phase (`.opening`)**, so a user can bail to the picker during a slow or stuck connect.

This is **navigation, not guaranteed immediate connect interruption.** #38 does *not* promise to kill the in-flight connect at click time. It shows the picker immediately, marks the connect operation abandoned, and lets it reach either a natural terminal or — if it stalls — the connect watchdog (→ restart-required; the watchdog does not itself reap the transport). True connect cancellation is a separate, larger product (§6, deferred to #53).

## 2. Motivating scenario

A **firewall that silently drops SYNs** (no RST) is the sharp case: ssh hangs — TCP retransmits with no peer response — so `.opening` persists for a long time (until ssh's own timeout or the app's connect watchdog). Also: wrong-profile-double-clicked, a remote that's currently down, VPN not up. In all of these the window sits on "Opening…" and the user wants to get back to the picker to do something else, not stare at a spinner or quit the app.

## 3. What is displayed during `.opening`

The session window ("Unison — <profile>") shows an **indeterminate animated progress bar**, the status **"Opening <profile>…"**, an empty results table, and a toolbar. For password auth, a credential sheet slides over once ssh asks. The toolbar's intent (`canPerformToolbarAction`, `ReconcileWindowController`) is: **Stop** and **Return to Profiles** enabled during connect, Quit enabled, Go/Diff/Rescan/direction disabled. Whether those intended-enabled controls are *actually* enabled during `.opening` is exactly what #38 is about (§4).

## 4. Root cause: UNCONFIRMED — pending instrumentation (corrected)

v1 asserted a responder-chain / first-responder-timing cause. That is **not supported** and is withdrawn. The toolbar path does **not** depend on the reconcile controller becoming first responder:

- The toolbar item's target is the permanent `ReconcileToolbarDelegate`, which implements `validateToolbarItem` ([ReconcileToolbar.swift:369](../Sources/App/ReconcileToolbar.swift)); `NSToolbarItem.autovalidates` defaults true.
- Validation runs on every phase transition via `validateVisibleItems()`, and delegates to the controller's `canPerformToolbarAction` ([ReconcileWindowController.swift:1862](../Sources/App/ReconcileWindowController.swift)), which returns `true` for `profilesIdentifier`.
- The reconcile window is made key before `beginInitialScan`.

The **menu** path is different routing: a responder-chain selector (`showProfilePickerMenuAction`) validated by `validateMenuItem`. The recorded #38 evidence measured the **menu** item (`enabled=false`, 12/12 during `.opening`, pre-sheet). The toolbar "whole row greyed" observation was eyeballed and may reflect the (correctly) disabled Go/Diff/Rescan, not Profiles/Stop.

**So the menu and toolbar can fail independently, and a single "make the controller first responder earlier" change may fix neither or only one.** The design therefore *requires a short diagnostic pass first*, recording:

- toolbar item target and `autovalidates`;
- whether `validateToolbarItem` is called during `.opening`, the value it returns, and the resulting `isEnabled`;
- menu item target resolution and whether `validateMenuItem` is called during `.opening`;
- key/main-window state during `.opening`;
- any toolbar-group/container-level disabling.

The fix follows the instrumentation, is scoped to whichever control(s) actually read disabled, and is validated on **menu and toolbar separately** (§7).

## 5. The teardown model (corrected)

v1 claimed a nav-during-`.opening` already flows through `connection_cancel` and waits for acknowledged quiescence. **It does not.** The current leave path, `leaveSession` ([AppDelegate.swift:552](../Sources/App/AppDelegate.swift)):

1. detaches the window delegate and drops the session/profile mapping,
2. calls `engine.abandon(reason:)`,
3. shows the picker **immediately**,
4. deliberately does **not** clear the pending connect/scan identity — the in-flight op keeps its engine lease and releases it only via its real terminal callback (guarded by the coordinator's phase-exact checks).

`connection_cancel` is a **separate** path, `cancelPreconnection` ([AppDelegate.swift:1372](../Sources/App/AppDelegate.swift)), used today for credential-cancel / fatal recovery — it retains the op lease + re-arms the watchdog until `unison_bridge_connection_cancel()` returns, and only an *acknowledged* cancel declares quiescence (a cancel failure or watchdog timeout → restart-required). Critically it runs on the **serial `connectQueue`**, so it **cannot pre-empt a connect bridge call that is already blocking that queue** — it waits behind it. "Reuse `connection_cancel` to bail immediately" is therefore not demonstrated and is not part of #38.

**#38 uses the existing abandoned-operation + queued-open authority, honestly.** Clicking Profiles during `.opening` → `leaveSession` → picker shown immediately; the abandoned connect still owns the engine lease. It then reaches one of two **distinct** outcomes:

- **Natural terminal.** The connect eventually finishes (success, failure, or `connection_end`). The coordinator accepts that **first valid terminal** and completes teardown — closing/reaping the transport if needed — and a queued replacement may then start. (A late `connection_end` success gets additional orphan close-and-drain handling.)
- **Watchdog.** The connect stalls. `handleConnectTimeout` ([AppDelegate.swift:1824](../Sources/App/AppDelegate.swift)) fails the op with **UNCERTAIN** quiescence (`engineIsQuiescent: false`) → the coordinator enters **`.restartRequired`** and **clears the queued replacement**. It does **not** kill or reap the transport child, so a firewall-hung ssh **remains until the app quits** (the shutdown reaper terminates registered children). App restart is required.

We do **not** claim an immediate reap on navigation, and **the watchdog does not terminate the connect** — it routes to restart-required with the transport still live.

A **replacement profile** selected after bailing enters the coordinator's existing engine-idle **queued-open** path: it starts only if the abandoned op reaches a **natural** terminal (which releases the lease). A **watchdog** outcome does **not** start the replacement — it clears it and requires a restart. So the honest navigation-only tradeoff is: the picker returns immediately, a replacement sync starts only on natural termination, and a genuinely stuck (e.g. firewall-hung) connect ends in restart-required, not an in-app recovery.

## 6. Two products (resolve the contradiction)

v1 contradicted itself: "picker appears only after cancellation is acknowledged" **and** "this makes the queued-replacement-around-fatal path GUI-reachable" cannot both hold — if presentation waits for quiescence, the user cannot queue a replacement during the connect.

The navigation-only model resolves it: **show the picker while the abandoned operation still owns the engine, and let a replacement selection enter the coordinator's existing waiting/queued-open path.** That is precisely what makes the queued-replacement-around-connect scenario GUI-reachable.

- **(A) Navigation-only — recommended for #38.** Show the picker immediately; mark the old op abandoned; preserve its engine lease; queue any replacement until it terminates. Already supported by the coordinator; keeps #38 small.
- **(B) True connect cancellation — deferred.** Hold presentation until cancellation/quiescence is proven. Needs a first-class cancellation design and a feasibility assessment of pre-empting a bridge call already occupying the serial worker, reaping the transport, and proving engine quiescence. Substantially larger; defer to #53 or a dedicated connect-cancellation design. **#41 is not a prerequisite:** a liveness/responsiveness signal can *detect* a stuck connect but cannot pre-empt the serial bridge call, reap the transport, or prove quiescence. Revisit any relationship if/when #41 is redesigned.

#38, titled "Profiles navigation during connect," is **(A)**.

## 7. Proposed approach

1. **Diagnose** (§4) — instrument toolbar vs menu validation during `.opening`; identify which control(s) actually read disabled and why.
2. **Fix the confirmed cause**, scoped to the actual defect (toolbar-validation return, menu responder/validation, or a container-disable) — not a speculative first-responder change.
3. **Rely on existing authority** — `leaveSession`'s abandon + immediate picker + the coordinator's queued-open path. No new teardown, no `connection_cancel` in the nav path, **no blob change**.
4. **Preserve sheet modality** — while a credential sheet is up, keep today's behavior; the sheet's **Cancel** is the in-sheet exit. #38 targets the pre-sheet `.opening` window.

## 8. Test matrix (menu and toolbar tested separately)

- **Pre-sheet navigation:** during `.opening`, before any sheet — **toolbar** Return-to-Profiles/Profiles enabled and returns to picker; **menu** `Show Profile Picker` enabled and returns to picker. (Invert the 12/12-disabled menu evidence; verify the toolbar independently.)
- **Sheet modality:** with the credential sheet up, nav behaves as today; the sheet's **Cancel** still exits credential entry.
- **Replacement queued behind the exact connect op:** after bailing, selecting another profile enters the queued-open path and starts only once the abandoned op terminates (bound to the exact `(session, op)`, not a blanket idle).
- **Natural terminal after abandonment:** the abandoned op's **first valid** terminal (connect success / failure / `connection_end`) is accepted by the coordinator's phase-exact checks and completes teardown (close/reap if needed); a queued replacement then starts. A late `connection_end` success gets orphan close-and-drain.
- **First-valid-terminal vs later stale/duplicate (preserve this exact distinction):** the coordinator accepts the FIRST valid terminal for the abandoned op and uses it to finish teardown; LATER duplicate/stale terminals for the same op are dropped (token/phase mismatch) and never resurrect UI or mis-release a replacement's lease. Cover both deterministically.
- **Watchdog / restart after abandonment:** a stalled abandoned connect → `handleConnectTimeout` → `.restartRequired`; the queued replacement is **cleared** and does **not** start; the transport child is **not** reaped (it remains until the quit-time shutdown reaper). Assert restart-required is surfaced.
- **Stale callbacks:** a late connect/scan callback for the abandoned op is dropped (token/phase mismatch), never applied to the picker or a replacement.
- **Double navigation / close:** a second Profiles/close for an already-torn-down session is a no-op (`windowBySession` guard).
- **No sync-confirmation bypass:** navigation during `.syncing` remains blocked (the three-way sync-confirmation alert is not bypassable via this path).

## 9. Invariants

- Navigation is available in every phase **except** `.syncing`, now genuinely including `.opening` pre-sheet.
- The nav path does **not** call `connection_cancel` and makes **no** claim of immediate reap; the abandoned op winds down in the background or via the watchdog.
- A replacement open is gated on the exact abandoned op's termination (existing queued-open authority), never started into a still-live engine.
- Credential-sheet modality unchanged. No vendored-blob change. No new cancellation mechanism.

## 10. Open questions

- Which control actually reads disabled during `.opening` — menu only, toolbar only, or both? (Resolved by §4 instrumentation; determines the fix's size and shape.)
- Is there container/group-level toolbar disabling during `.opening` that overrides per-item validation?
- Replacement latency is bounded by the abandoned op's **natural** termination; a **watchdog** outcome does not start the replacement — it clears it and requires a restart. So a firewall-hung connect ends in restart-required, not an automatic replacement. Is requiring a restart for a genuinely stuck connect acceptable for 0.3.1, or does it argue for accelerating (B)? (Recommend accept for 0.3.1; it is the motivation for (B)/#53.)

## 11. Recommendation

Ship **(A) navigation-only** in 0.3.1: instrument first (§4), fix the confirmed control(s), and lean on the existing abandon + queued-open authority — no blob, no new cancellation. State honestly that the abandoned connect either reaches a natural terminal (releasing the lease, allowing a queued replacement) or stalls to the watchdog → restart-required (transport lingering until the shutdown reaper). Defer **(B) true connect cancellation** to a first-class design (with #53, or a dedicated connect-cancellation design) — do **not** prescribe #41 as a prerequisite. Do not expand #35 / PR #37 for this.
