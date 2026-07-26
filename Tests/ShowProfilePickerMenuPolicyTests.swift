import XCTest
@testable import unison_ui_mac

/// Issue #38: Action ▸ Show Profile Picker is owned by `AppDelegate` (explicit
/// target) and validated + dispatched via this single routing decision, so an
/// intermittent responder-chain/validation failure can't grey it. Enabled iff
/// the route is not `.unavailable`.
final class ShowProfilePickerMenuPolicyTests: XCTestCase {

    private typealias P = ShowProfilePickerMenuPolicy
    private typealias Target = ShowProfilePickerMenuTarget
    private typealias Phase = EngineSessionCoordinator.Phase
    private let s = EngineSessionCoordinator.SessionID(raw: 1)
    private let op = EngineSessionCoordinator.OperationID(raw: 2)

    // MARK: current reconcile session

    func test_currentSession_opening_routesToCurrentSession() {
        XCTAssertEqual(P.route(hasCurrentSession: true, phase: .opening(s, op),
                               hasWaitingWindow: false), .currentSession)
    }

    func test_currentSession_syncing_unavailable() {
        // Disabled during a running sync — must not bypass the window's
        // three-way sync-confirmation prompt.
        XCTAssertEqual(P.route(hasCurrentSession: true, phase: .syncing(s, op),
                               hasWaitingWindow: false), .unavailable)
    }

    func test_currentSession_otherPermittedPhases_routesToCurrentSession() {
        for phase: Phase in [.scanning(s, op), .ready(s), .stopped(s),
                             .restartRequired("x")] {
            XCTAssertEqual(P.route(hasCurrentSession: true, phase: phase,
                                   hasWaitingWindow: false), .currentSession)
        }
    }

    // MARK: picker-only

    func test_noSessionNoWaiting_unavailable() {
        XCTAssertEqual(P.route(hasCurrentSession: false, phase: .idle,
                               hasWaitingWindow: false), .unavailable)
        XCTAssertEqual(P.route(hasCurrentSession: false, phase: .opening(s, op),
                               hasWaitingWindow: false), .unavailable)
    }

    // MARK: waiting window (queued replacement)

    func test_waitingWindow_routesToWaitingRequest() {
        // A waiting window is navigable back to the picker (cancels its queued
        // request) even with no current session.
        XCTAssertEqual(P.route(hasCurrentSession: false, phase: .idle,
                               hasWaitingWindow: true), .waitingRequest)
    }

    func test_waitingWindow_enabledEvenIfAbandonedOpSyncing() {
        // The abandoned engine op may be `.syncing`, but that op is not this
        // queued request — so the waiting window stays navigable.
        XCTAssertEqual(P.route(hasCurrentSession: false, phase: .syncing(s, op),
                               hasWaitingWindow: true), .waitingRequest)
    }

    func test_waitingWindow_takesPrecedenceOverCurrentSession() {
        XCTAssertEqual(P.route(hasCurrentSession: true, phase: .syncing(s, op),
                               hasWaitingWindow: true), .waitingRequest)
        XCTAssertEqual(P.route(hasCurrentSession: true, phase: .opening(s, op),
                               hasWaitingWindow: true), .waitingRequest)
    }

    // MARK: enablement (route != .unavailable)

    func test_enablement() {
        XCTAssertNotEqual(P.route(hasCurrentSession: true, phase: .opening(s, op),
                                  hasWaitingWindow: false), .unavailable)  // enabled
        XCTAssertNotEqual(P.route(hasCurrentSession: false, phase: .idle,
                                  hasWaitingWindow: true), .unavailable)   // enabled
        XCTAssertEqual(P.route(hasCurrentSession: true, phase: .syncing(s, op),
                               hasWaitingWindow: false), .unavailable)     // disabled
        XCTAssertEqual(P.route(hasCurrentSession: false, phase: .ready(s),
                               hasWaitingWindow: false), .unavailable)     // disabled
    }
}
