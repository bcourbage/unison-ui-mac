import XCTest
@testable import unison_ui_mac

/// Issue #38: Action ▸ Show Profile Picker is owned by `AppDelegate` (explicit
/// target) and validated + dispatched via this single routing decision, so an
/// intermittent responder-chain/validation failure can't grey it. Enabled iff
/// the route is not `.unavailable`. `hasNavigableReconcileWindow` models the
/// driver's real states: it is true when a reconcile window is present AND
/// navigable — the engine-current session's window, OR the window retained &
/// visible during `.restartRequired` (where `engine.currentSession` is nil).
final class ShowProfilePickerMenuPolicyTests: XCTestCase {

    private typealias P = ShowProfilePickerMenuPolicy
    private typealias Target = ShowProfilePickerMenuTarget
    private typealias Phase = EngineSessionCoordinator.Phase
    private let s = EngineSessionCoordinator.SessionID(raw: 1)
    private let op = EngineSessionCoordinator.OperationID(raw: 2)

    // MARK: navigable reconcile window

    func test_reconcileWindow_opening() {
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: true, phase: .opening(s, op),
                               hasWaitingWindow: false), .reconcileWindow)
    }

    func test_reconcileWindow_syncing_unavailable() {
        // Disabled during a running sync — must not bypass the window's
        // three-way sync-confirmation prompt.
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: true, phase: .syncing(s, op),
                               hasWaitingWindow: false), .unavailable)
    }

    func test_reconcileWindow_otherPermittedPhases() {
        for phase: Phase in [.scanning(s, op), .ready(s)] {
            XCTAssertEqual(P.route(hasNavigableReconcileWindow: true, phase: phase,
                                   hasWaitingWindow: false), .reconcileWindow)
        }
    }

    // MARK: restart-required — the retained visible reconcile window (real state)

    // Driver-real: coordinator has NO current session (`.restartRequired`), but
    // `driveRestartRequired` keeps the reconcile window visible, so
    // `hasNavigableReconcileWindow` is true → navigable back to the picker.
    func test_restartRequired_withRetainedWindow_routesToReconcileWindow() {
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: true, phase: .restartRequired("x"),
                               hasWaitingWindow: false), .reconcileWindow)
    }

    // Restart-required with no reconcile window (picker-only) → nothing to navigate.
    func test_restartRequired_pickerOnly_unavailable() {
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: false, phase: .restartRequired("x"),
                               hasWaitingWindow: false), .unavailable)
    }

    // MARK: picker-only

    func test_noWindowNoWaiting_unavailable() {
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: false, phase: .idle,
                               hasWaitingWindow: false), .unavailable)
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: false, phase: .ready(s),
                               hasWaitingWindow: false), .unavailable)
    }

    // MARK: waiting window (queued replacement)

    func test_waitingWindow_routesToWaitingRequest() {
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: false, phase: .idle,
                               hasWaitingWindow: true), .waitingRequest)
    }

    func test_waitingWindow_enabledEvenIfAbandonedOpSyncing() {
        // The abandoned engine op may be `.syncing`, but that op is not this
        // queued request — so the waiting window stays navigable.
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: false, phase: .syncing(s, op),
                               hasWaitingWindow: true), .waitingRequest)
    }

    func test_waitingWindow_takesPrecedence() {
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: true, phase: .syncing(s, op),
                               hasWaitingWindow: true), .waitingRequest)
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: true, phase: .restartRequired("x"),
                               hasWaitingWindow: true), .waitingRequest)
    }

    // MARK: enablement (route != .unavailable)

    func test_enablement() {
        XCTAssertNotEqual(P.route(hasNavigableReconcileWindow: true, phase: .opening(s, op),
                                  hasWaitingWindow: false), .unavailable)             // enabled
        XCTAssertNotEqual(P.route(hasNavigableReconcileWindow: true, phase: .restartRequired("x"),
                                  hasWaitingWindow: false), .unavailable)             // enabled (regression fix)
        XCTAssertNotEqual(P.route(hasNavigableReconcileWindow: false, phase: .idle,
                                  hasWaitingWindow: true), .unavailable)              // enabled
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: true, phase: .syncing(s, op),
                               hasWaitingWindow: false), .unavailable)               // disabled
        XCTAssertEqual(P.route(hasNavigableReconcileWindow: false, phase: .ready(s),
                               hasWaitingWindow: false), .unavailable)               // disabled
    }
}
