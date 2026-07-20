import Foundation

/// Pure, unit-testable predicate for whether a reconcile-window action may
/// proceed. Extracted so the action METHODS (not just menu/toolbar validation)
/// share one authority, and so the Ignore-publication gap is provable by test:
/// while `mutationInFlight` is set — the window of time between a successful
/// Ignore and its dedicated asynchronous completion landing, during which the
/// published OCaml roots are the post-Ignore set but the displayed rows are
/// still the pre-Ignore set — NO engine-reaching action may run (any of them
/// would address a row index against the wrong roots or start new engine work),
/// while navigation (Profiles / close, Quit) stays available.
struct ReconcileActionGate: Equatable {
    /// Coarse phase mirroring `ReconcileSummary.Phase` for gating purposes.
    enum Phase: Equatable { case ready, syncing, done }

    var restartRequired: Bool
    var mutationInFlight: Bool
    var isSyncing: Bool
    var isScanning: Bool
    var phase: Phase
    var hasItems: Bool

    enum Action: CaseIterable {
        case direction    // apply a direction override (ri_set_*)
        case ignore       // apply an Ignore (ignore_*)
        case diff         // canDiff / run_show_diffs
        case details      // ri_get_details for the selection
        case sync         // Go
        case rescan       // Rescan (init2)
        case stop         // Stop (abort sync / cancel scan)
        case profiles     // navigate back to picker / close window
        case quit         // quit the app
    }

    /// The row set is stable and the engine is idle-ready — the precondition for
    /// any per-row or start-sync action.
    var isActionable: Bool {
        !restartRequired && !mutationInFlight && hasItems && phase == .ready
    }

    func allows(_ action: Action) -> Bool {
        switch action {
        case .profiles, .quit:
            // Navigation is always available — never blocked by a mutation gap,
            // a restart, or an in-flight sync.
            return true
        case .stop:
            // Meaningful only while a sync or scan is actually running; disabled
            // once a restart is required. (No sync/scan runs during an Ignore
            // gap, so this is naturally false then.)
            return !restartRequired && (isSyncing || isScanning)
        case .direction, .sync, .diff:
            return isActionable
        case .ignore:
            // Same envelope as the other row mutations, but permitted outside
            // strict .ready too as long as no sync is running — matching the
            // pre-existing Ignore availability, plus the mutation/restart gate.
            return !restartRequired && !mutationInFlight && !isSyncing && hasItems
        case .details:
            // Read-only, but reads ri_get_details BY ROW INDEX against the
            // published roots, so it must not run while rows are stale against
            // new roots. No items/phase requirement (a placeholder is shown).
            return !restartRequired && !mutationInFlight
        case .rescan:
            // Allowed post-sync (.done) too, but never during a sync, a restart,
            // or an Ignore publication gap.
            return !restartRequired && !mutationInFlight && !isSyncing
        }
    }
}
