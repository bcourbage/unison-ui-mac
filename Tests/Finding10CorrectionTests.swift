import XCTest
@testable import unison_ui_mac

/// Finding #10 correction pass — the results-unavailable action gate and its
/// distinct (non-success) presentation.
final class Finding10CorrectionTests: XCTestCase {

    private func gate(resultsUnavailable: Bool, phase: ReconcileActionGate.Phase = .done)
        -> ReconcileActionGate {
        ReconcileActionGate(restartRequired: false, mutationInFlight: false,
                            isSyncing: false, isScanning: false, phase: phase,
                            hasItems: true, resultsUnavailable: resultsUnavailable)
    }

    // MARK: - Gate matrix

    func test_resultsUnavailable_blocksEveryEngineAction_allowsRescanAndNav() {
        let g = gate(resultsUnavailable: true)
        XCTAssertFalse(g.isActionable)
        // Every engine-reaching action is blocked (incl. Details and the
        // phase-independent Ignore path — the previously-leaky cases).
        for a in [ReconcileActionGate.Action.direction, .sync, .diff, .details, .ignore] {
            XCTAssertFalse(g.allows(a), "\(a) must be blocked when results are unavailable")
        }
        // Only recovery/navigation remain.
        for a in [ReconcileActionGate.Action.rescan, .profiles, .quit] {
            XCTAssertTrue(g.allows(a), "\(a) must stay available")
        }
    }

    func test_normalDone_stillPermitsDetailsIgnoreRescan() {
        // Control: with results available, .done keeps its existing affordances
        // (this PR only changes the unavailable case).
        let g = gate(resultsUnavailable: false)
        XCTAssertTrue(g.allows(.rescan))
        XCTAssertTrue(g.allows(.details))
        XCTAssertTrue(g.allows(.ignore))
        XCTAssertTrue(g.allows(.profiles))
    }

    // MARK: - Presentation descriptor

    func test_resultsUnavailableEmphasis_isWarning_notGreenSuccess() {
        let u = ReconcileSummary.completionEmphasis(failures: 0, resultsUnavailable: true)
        XCTAssertNotEqual(u.symbolName, "checkmark.circle.fill", "must not show the success check")
        XCTAssertEqual(u.tint, .systemOrange)
        XCTAssertTrue(u.accessibilityLabel.lowercased().contains("unavailable"),
                      "accessibility describes the unavailable state")
    }

    func test_successEmphasis_regressionStillGreenCheck() {
        let ok = ReconcileSummary.completionEmphasis(failures: 0)
        XCTAssertEqual(ok.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(ok.tint, .systemGreen)
        XCTAssertEqual(ok.accessibilityLabel, "Synchronization completed")
    }

    // MARK: - Swift malformed-success guard (ABI)

    func test_convertSyncCompletion_rejectsMalformedSuccessShapes() {
        // Positive count with a NULL rows pointer is NOT an empty success —
        // it's unavailable results.
        XCTAssertFalse(UnisonBridge.convertSyncCompletion(ok: true, count: 3, rows: nil).ok)
        // Negative count is also malformed → unavailable.
        XCTAssertFalse(UnisonBridge.convertSyncCompletion(ok: true, count: -1, rows: nil).ok)
        // ok=false is unavailable regardless of count.
        XCTAssertFalse(UnisonBridge.convertSyncCompletion(ok: false, count: 5, rows: nil).ok)
        // A genuine empty success (ok=true, count 0, null rows) stays ok=true.
        let empty = UnisonBridge.convertSyncCompletion(ok: true, count: 0, rows: nil)
        XCTAssertTrue(empty.ok)
        XCTAssertTrue(empty.rows.isEmpty)
    }
}
