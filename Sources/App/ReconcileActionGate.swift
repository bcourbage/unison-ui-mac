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
    /// PR-4: a diff is running on the single OCaml worker. Every engine-reaching
    /// action (Direction/Revert, Ignore, Diff incl. canDiff, Details/ri_get_details,
    /// Go/Sync, Rescan) would call the bridge on the MAIN thread and block behind
    /// the wedged diff — so all are refused at their method boundary while diffing.
    /// Only navigation (Profiles/close) and Quit remain; Stop is naturally false
    /// (no sync/scan runs during a diff), matching "no safe cancellation exists".
    var diffInFlight: Bool = false
    /// Finding #10: sync completed but its per-file results couldn't be shown
    /// (snapshot marshalling failure / row-count mismatch). The engine is
    /// quiescent (so NOT `restartRequired`), but the displayed rows are not
    /// trustworthy — so EVERY engine-reaching action (Direction/Revert, Ignore,
    /// Diff incl. canDiff, Details, Go/Sync) is blocked. Only Rescan (the way
    /// out), Profiles/close, and Quit remain. Pure selection helpers are not
    /// gated here.
    var resultsUnavailable: Bool = false

    enum Action: CaseIterable {
        case direction    // apply a direction override (ri_set_*)
        case ignore       // apply an Ignore (ignore_*)
        case diff         // canDiff / run_show_diffs
        case details      // ri_get_details for the selection
        case sync         // Go
        case rescan       // Rescan (init2)
        case stop         // Stop (abort a running sync; sync-only, issue #117)
        case profiles     // navigate back to picker / close window
        case quit         // quit the app
    }

    /// The row set is stable and the engine is idle-ready — the precondition for
    /// any per-row or start-sync action.
    var isActionable: Bool {
        !restartRequired && !mutationInFlight && !resultsUnavailable && !diffInFlight
            && hasItems && phase == .ready
    }

    func allows(_ action: Action) -> Bool {
        switch action {
        case .profiles, .quit:
            // Navigation is always available — never blocked by a mutation gap,
            // a restart, or an in-flight sync.
            return true
        case .stop:
            // Stop means exactly one thing: abort a running synchronization. It
            // is available only while a sync is in flight, and disabled once a
            // restart is required. Leaving during a connect/scan is the Profiles
            // control's job, not Stop's (issue #117), so `isScanning` does NOT
            // enable this. (No sync runs during an Ignore gap, so this is
            // naturally false then.)
            return !restartRequired && isSyncing
        case .direction, .sync, .diff:
            return isActionable
        case .ignore:
            // Same envelope as the other row mutations, but permitted outside
            // strict .ready too as long as no sync is running — matching the
            // pre-existing Ignore availability, plus the mutation/restart gate.
            // Also blocked when results are unavailable: the displayed rows are
            // stale, so an Ignore by row index would address the wrong root.
            return !restartRequired && !mutationInFlight && !resultsUnavailable
                && !diffInFlight && !isSyncing && hasItems
        case .details:
            // Read-only, but reads ri_get_details BY ROW INDEX against the
            // published roots, so it must not run while rows are stale against
            // new roots. No items/phase requirement (a placeholder is shown).
            // Blocked when results are unavailable for the same stale-row reason,
            // and while diffing (the bridge call would block the main thread).
            return !restartRequired && !mutationInFlight && !resultsUnavailable && !diffInFlight
        case .rescan:
            // Allowed post-sync (.done) too, but never while an operation is
            // already running: not during a connect/scan (a rescan would double-
            // drive the engine), not during a sync, a restart, an Ignore
            // publication gap, or a diff.
            return !restartRequired && !mutationInFlight
                && !isScanning && !isSyncing && !diffInFlight
        }
    }
}
