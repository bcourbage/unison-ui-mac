import XCTest
@testable import unison_ui_mac

/// Blocker B7: **Action ▸ Rescan Ignoring Archives…** must be non-actionable
/// outside `.ready`. It routes through `reopenCurrentProfileFresh`, which
/// asserts `engineIsQuiescent: true` — sound only when no op is in flight.
/// This gate drives BOTH menu validation and the action's own authority guard.
///
/// (Verified red on 4359c7a: before this gate, validation enabled the item
/// whenever a reconcile window + profile existed — including `.opening`,
/// `.scanning`, and `.syncing` — and the action ran unconditionally.)
final class RescanIgnoringArchivesGateTests: XCTestCase {

    private typealias Gate = RescanIgnoringArchivesGate
    private typealias Phase = EngineSessionCoordinator.Phase
    private let s = EngineSessionCoordinator.SessionID(raw: 1)
    private let op = EngineSessionCoordinator.OperationID(raw: 2)

    // MARK: only .ready is actionable

    func test_ready_withWindowAndProfile_isAllowed() {
        XCTAssertTrue(Gate.isAllowed(phase: .ready(s),
                                     hasReconcileWindow: true, hasProfile: true))
    }

    func test_everyNonReadyPhase_isBlocked_evenWithWindowAndProfile() {
        let nonReady: [Phase] = [
            .idle,
            .opening(s, op),
            .scanning(s, op),
            .syncing(s, op),
            .restartRequired("x"),
        ]
        for phase in nonReady {
            XCTAssertFalse(Gate.isAllowed(phase: phase,
                                          hasReconcileWindow: true, hasProfile: true),
                           "phase \(phase) must be non-actionable")
        }
    }

    // MARK: .ready still requires a window and a target profile

    func test_ready_missingWindowOrProfile_isBlocked() {
        XCTAssertFalse(Gate.isAllowed(phase: .ready(s),
                                      hasReconcileWindow: false, hasProfile: true))
        XCTAssertFalse(Gate.isAllowed(phase: .ready(s),
                                      hasReconcileWindow: true, hasProfile: false))
        XCTAssertFalse(Gate.isAllowed(phase: .ready(s),
                                      hasReconcileWindow: false, hasProfile: false))
    }
}
