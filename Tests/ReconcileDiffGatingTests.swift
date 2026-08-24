import XCTest
@testable import unison_ui_mac

/// PR-4 round 2 (blocker): the REAL reconcile controller, once the driver marks a
/// diff in flight, produces an action gate that refuses every engine-reaching
/// action — so no bridge call runs on the main thread behind the wedged diff.
/// (The per-method boundary guards all consult this same gate.)
@MainActor
final class ReconcileDiffGatingTests: XCTestCase {

    private func makeController() -> ReconcileWindowController {
        ReconcileWindowController(
            profile: "T", mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onCancelScan: {},
            onSyncStart: {}, onSyncExit: { _ in }, onEngineUncertain: { _ in },
            onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
    }

    func test_setDiffInFlight_makesEveryEngineActionRefused() {
        let c = makeController()
        // Baseline: no assertion on the pre-diff gate (phase/items aren't set up);
        // the point is the diff flag flips every engine action OFF.
        c.setDiffInFlight(true)
        XCTAssertTrue(c.diffInFlight)
        let g = c.actionGateForTesting
        for a in [ReconcileActionGate.Action.direction, .ignore, .diff, .details, .sync, .rescan] {
            XCTAssertFalse(g.allows(a), "\(a) must be refused by the real controller while diffing")
        }
        XCTAssertTrue(g.allows(.profiles), "navigation stays available")
        XCTAssertTrue(g.allows(.quit), "Quit stays available")

        c.setDiffInFlight(false)
        XCTAssertFalse(c.diffInFlight)
        XCTAssertFalse(c.actionGateForTesting.diffInFlight, "the gate clears with the flag")
    }
}
