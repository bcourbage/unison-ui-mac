import XCTest
@testable import unison_ui_mac

/// Proves the reconcile-window action gate — the single predicate the action
/// METHODS and menu/toolbar validation both consult. The load-bearing case is
/// the Ignore publication gap (`mutationInFlight`): every engine-reaching action
/// must be blocked, while navigation stays available.
final class ReconcileActionGateTests: XCTestCase {
    private typealias Gate = ReconcileActionGate

    /// Idle-ready: rows loaded, engine quiescent, nothing pending.
    private func ready() -> Gate {
        Gate(restartRequired: false, mutationInFlight: false,
             isSyncing: false, isScanning: false, phase: .ready, hasItems: true)
    }

    /// The six actions that reach the OCaml engine by row index or start work.
    private let engineActions: [Gate.Action] =
        [.direction, .ignore, .diff, .details, .sync, .rescan]

    func test_ready_allowsEngineActions() {
        let g = ready()
        for a in engineActions {
            XCTAssertTrue(g.allows(a), "\(a) should be allowed when idle-ready")
        }
        XCTAssertTrue(g.allows(.profiles))
        XCTAssertTrue(g.allows(.quit))
    }

    func test_ignoreGap_blocksEveryEngineAction_butKeepsNavigation() {
        var g = ready()
        g.mutationInFlight = true   // successful Ignore, completion not yet landed
        for a in engineActions {
            XCTAssertFalse(g.allows(a),
                "\(a) MUST be blocked during an Ignore publication gap")
        }
        // Navigation out (Profiles/close) and Quit remain available.
        XCTAssertTrue(g.allows(.profiles), "Profiles/close must remain available")
        XCTAssertTrue(g.allows(.quit), "Quit must remain available")
        // Nothing to stop in the gap (no sync/scan running).
        XCTAssertFalse(g.allows(.stop))
    }

    func test_restartRequired_blocksEverythingButNavigation() {
        var g = ready()
        g.restartRequired = true
        for a in engineActions {
            XCTAssertFalse(g.allows(a), "\(a) must be blocked when restart is required")
        }
        XCTAssertFalse(g.allows(.stop))
        XCTAssertTrue(g.allows(.profiles))
        XCTAssertTrue(g.allows(.quit))
    }

    func test_syncing_blocksRowActionsAndRescan_allowsStopAndDetails() {
        var g = ready()
        g.isSyncing = true
        g.phase = .syncing
        // Row mutations, Diff, Go, and Rescan are all blocked during a sync.
        for a in [Gate.Action.direction, .ignore, .diff, .sync, .rescan] {
            XCTAssertFalse(g.allows(a), "\(a) must be blocked during a sync")
        }
        // Stop is the whole point mid-sync; Details is a read-only view of valid
        // rows (roots are stable during a sync) and stays available.
        XCTAssertTrue(g.allows(.stop), "Stop must be available during a sync")
        XCTAssertTrue(g.allows(.details), "Details (read-only) stays available during a sync")
        XCTAssertTrue(g.allows(.profiles))
        XCTAssertTrue(g.allows(.quit))
    }

    func test_done_allowsRescan_butNotRowActions() {
        var g = ready()
        g.phase = .done
        // Post-sync: rescan is the way back to ready; row actions are not.
        XCTAssertTrue(g.allows(.rescan))
        XCTAssertFalse(g.allows(.direction))
        XCTAssertFalse(g.allows(.sync))
        XCTAssertTrue(g.allows(.profiles))
    }

    func test_scanning_allowsStop_blocksRowActions() {
        var g = ready()
        g.isScanning = true
        g.hasItems = false   // rows cleared while a (re)scan runs
        // Row mutations, Diff, and Go require a stable ready row set — blocked.
        for a in [Gate.Action.direction, .ignore, .diff, .sync] {
            XCTAssertFalse(g.allows(a), "\(a) must be blocked mid-scan")
        }
        // Stop cancels the scan; Rescan (scan ≠ sync) and Details are not blocked
        // by a scan alone — matching prior behavior. The ignore-gap test proves
        // they ARE blocked when it matters (mutationInFlight).
        XCTAssertTrue(g.allows(.stop), "Stop must be available mid-scan")
    }

    func test_details_needsNoItems_butBlockedInGap() {
        // Details tolerates an empty selection (placeholder), so it is allowed
        // when idle even with no items — but still blocked during the Ignore gap.
        var g = ready()
        g.hasItems = false
        XCTAssertTrue(g.allows(.details))
        g.mutationInFlight = true
        XCTAssertFalse(g.allows(.details))
    }

    // PR-4 round 2 (blocker): while a diff occupies the OCaml worker, EVERY
    // engine-reaching action is refused — each would call the bridge on the main
    // thread and block behind the wedged diff. Only navigation/Quit stay; Stop is
    // naturally false (no sync/scan runs during a diff).
    func test_diffInFlight_blocksEveryEngineAction_keepsNavAndQuit() {
        var g = ready()
        g.diffInFlight = true
        for a in engineActions {
            XCTAssertFalse(g.allows(a), "\(a) must be refused while a diff is in flight")
        }
        XCTAssertFalse(g.isActionable)
        XCTAssertTrue(g.allows(.profiles), "navigation stays available during a diff")
        XCTAssertTrue(g.allows(.quit), "Quit stays available during a diff")
        XCTAssertFalse(g.allows(.stop), "Stop is off — no safe cancellation of a diff")
    }

    func test_diffInFlight_blocksDetails_evenWithNoItems() {
        var g = ready()
        g.hasItems = false
        g.diffInFlight = true
        XCTAssertFalse(g.allows(.details),
                       "no ri_get_details bridge call may run while diffing")
    }
}
