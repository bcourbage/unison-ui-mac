import Foundation

/// Pure decisions for the scan-interruption WIRING (issue #24), extracted so the
/// driver's phase-binding, reap-poll, and leave-routing logic is unit-tested
/// without an AppKit/bridge harness. The coordinator still owns all lifecycle
/// transitions; these only shape how the driver drives it.
enum ScanInterruptPolicy {

    /// Whether a qualified session's scan can actually be interrupted IN PLACE
    /// right now (live-matrix finding #3). SIGKILLing the transport only unwinds
    /// the engine PROMPTLY when it is BLOCKED ON THE TRANSPORT; while it is
    /// CPU-bound in the local-replica walk (hashing a large tree) it does not
    /// notice the dead socket, so the interrupt reap deadline elapses →
    /// restart-required. The engine signals transport-blocked by emitting
    /// "Waiting for changes from server" (`ScanStallPolicy.marksRemoteWait`),
    /// latched into `sawRemoteWait`. Before that marker a qualified session must
    /// present the neutral, honest Return-to-Profiles (which abandons and winds
    /// down in the background) rather than the in-place Stop Scan / interruption
    /// teardown. The `qualified:` inputs below are therefore fed this predicate,
    /// NOT bare transport qualification.
    static func interruptReady(qualified: Bool, sawRemoteWait: Bool) -> Bool {
        stopInPlaceEnabled && qualified && sawRemoteWait
    }

    /// Master switch for genuine in-place scan interruption, held OFF.
    ///
    /// An in-place interruption ends the running scan by SIGKILLing its
    /// transport child and then reuses the engine (`.stopped`, Rescan reuses the
    /// session). Its safety rests on recognizing the interrupted scan's own
    /// terminal, but no terminal event carries a STRUCTURALLY AUTHENTICATED
    /// cause: the SIGKILL's transport EOF is indistinguishable on the wire from
    /// an unrelated `scanFailed` or fatal racing the interruption, so such a
    /// terminal could launder a normally restart-required engine into a reusable
    /// one. Until a typed, cause-bound bridge contract exists (a separate,
    /// separately-reviewed change), stop-in-place stays disabled and every leave
    /// takes the honest Return-to-Profiles path: abandon the presentation,
    /// retain the scan lease, and close on the scan's own terminal.
    ///
    /// This flag is the SINGLE policy boundary. Stop Scan, Profiles, and
    /// window-close all consult `interruptReady` (Stop directly; Profiles and
    /// window-close through `leaveRouting`/`stopScanAvailable`), so forcing it
    /// false disables entry to `.interruptingScan` for all three at once — it
    /// does not merely hide the toolbar button while leaving the other routes
    /// able to start an interruption.
    static let stopInPlaceEnabled = false

    /// Authorization for the IRREVERSIBLE transport SIGKILL at the signal driver
    /// (acceptance point 1 — the second, authoritative checkpoint immediately
    /// before the kill). The signal proceeds ONLY when the session is
    /// interruptible in place RIGHT NOW (`interruptReady`: qualified AND
    /// transport-blocked, finding #3) AND the signal targets the EXACT pending
    /// scan op. A qualified-but-pre-remote-wait session (where the SIGKILL could
    /// not unwind a CPU-bound local walk in time), or a stale / superseded /
    /// wrong-op signal, is REFUSED here → conservative restart, never a SIGKILL.
    /// Belt-and-suspenders behind the affordance/leave gates, but this is the
    /// last line before the kill so it enforces the boundary itself.
    static func signalAuthorized(interruptReady: Bool, pendingScanMatches: Bool) -> Bool {
        interruptReady && pendingScanMatches
    }

    /// The genuine "Stop Scan" affordance is active ONLY in the exact
    /// `.scanning` phase AND when the session's scan is interruptible in place
    /// (`qualified` here = `interruptReady`: transport qualified AND engine
    /// transport-blocked, finding #3). It must be inactive during `.opening`
    /// (connect — qualification can resolve while still connecting), the
    /// pre-remote-wait local walk, `.interruptingScan`, `.stopped`, `.ready`,
    /// etc., so a click can never set "Stopping scan…" while
    /// `requestScanInterruption` would reject it or the reap would time out
    /// (Blocker 1 + finding #3).
    static func stopScanAvailable(phase: EngineSessionCoordinator.Phase,
                                  qualified: Bool) -> Bool {
        if case .scanning = phase { return qualified }
        return false
    }

    /// Reap polling (Phase 0 design §8): a freshly-SIGKILLed child passes
    /// through LIVE → ZOMBIE → ABSENT as the kernel reaps it. LIVE, ZOMBIE, and
    /// UNKNOWN are all INCONCLUSIVE and must be polled until the grace expires;
    /// only ABSENT/REUSED prove the original child is gone and resolve
    /// immediately (Blocker 3). After the grace, whatever remains is resolved to
    /// the coordinator (an unresolved ZOMBIE/UNKNOWN → ambiguous → restart).
    static func reapShouldKeepPolling(_ reap: EngineSessionCoordinator.ReapState,
                                      elapsed: TimeInterval, grace: TimeInterval) -> Bool {
        switch reap {
        case .absent, .reused:          return false
        case .live, .zombie, .unknown:  return elapsed < grace
        }
    }

    /// What a Profiles-button / window-close during a session must do. Genuine
    /// presentation (showing the picker) has to wait for engine quiescence, so a
    /// qualified scan is routed through the coordinator's interruption instead of
    /// an immediate leave-to-picker (Blocker 2).
    enum LeaveRouting: Equatable {
        /// Qualified `.scanning`: start a `.returnToPicker` interruption; the
        /// coordinator closes the window + shows the picker on quiescence.
        case interruptReturnToPicker
        /// Already `.interruptingScan`: `abandon()` upgrades the destination
        /// (monotonic) to returnToPicker; NO early presentation here.
        case abandonUpgrade
        /// Not interruptible (unqualified scan, connect, ready, …): the existing
        /// honest immediate leave-to-picker fallback.
        case leaveImmediately
    }

    /// `qualified` here = `interruptReady` (transport qualified AND engine
    /// transport-blocked, finding #3): a qualified scan still in its CPU-bound
    /// local walk routes `.leaveImmediately` (honest background wind-down),
    /// exactly like an unqualified scan, because the SIGKILL interruption would
    /// otherwise time out its reap.
    static func leaveRouting(phase: EngineSessionCoordinator.Phase,
                             qualified: Bool) -> LeaveRouting {
        if case .scanning = phase, qualified { return .interruptReturnToPicker }
        if case .interruptingScan = phase { return .abandonUpgrade }
        return .leaveImmediately
    }

    /// `windowShouldClose` verdict (round 2 Finding 1): the actual window close
    /// is ALLOWED only in the leave-immediately case; interrupt/abandon routings
    /// VETO the close so the window (and its cached qualification) is retained
    /// until the coordinator's later `.closeWindow` effect performs the real
    /// close on quiescence. Returns true to allow the close.
    static func allowWindowClose(phase: EngineSessionCoordinator.Phase,
                                 qualified: Bool) -> Bool {
        leaveRouting(phase: phase, qualified: qualified) == .leaveImmediately
    }

    /// Whether the Profiles action is HANDLED by the interruption path (round 3
    /// correction 1). True → the driver started/upgraded a `.returnToPicker`
    /// interruption, so the controller must NOT also `performClose`. False → not
    /// handled, so `returnToPicker` falls back to `window.performClose`, which
    /// routes through `windowShouldClose` and therefore CANNOT bypass the
    /// three-way sync-confirmation alert during a running sync.
    static func profilesHandledByInterruption(phase: EngineSessionCoordinator.Phase,
                                              qualified: Bool) -> Bool {
        leaveRouting(phase: phase, qualified: qualified) != .leaveImmediately
    }

    /// Recognize Unison's "archives are locked" fatal (live-matrix finding). A
    /// Stop Scan SIGKILLs the transport, orphaning the remote `unison -server`
    /// which then releases its (empty, owner-less) lock file only when it
    /// finally notices the dropped socket — asynchronously, and per upstream
    /// "not reliably run in all cases." A reconnect that beats that release hits
    /// this fatal. It is TRANSIENT for a post-interruption reconnect (the lock is
    /// our own orphan and will clear), so the driver retries the reconnect a
    /// bounded number of times rather than surfacing a restart. Platform-
    /// agnostic: the reconnect attempt itself is the only reliable "is the lock
    /// gone yet" signal.
    static func isArchiveLockFatal(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("archives are locked") || m.contains("locks should be removed")
    }
}
