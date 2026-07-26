import XCTest
@testable import unison_ui_mac

/// Issue #38: the Action ▸ Show Profile Picker command is validated by
/// `AppDelegate` (explicit target) via this pure policy, so a first-menu-open
/// responder-chain race can never grey it. Authoritative rule: navigation is
/// available whenever a reconcile session exists and the coordinator is not
/// `.syncing`; with no reconcile session (already at the picker) it is disabled.
final class ShowProfilePickerMenuPolicyTests: XCTestCase {

    private typealias P = ShowProfilePickerMenuPolicy
    private typealias Phase = EngineSessionCoordinator.Phase
    private let s = EngineSessionCoordinator.SessionID(raw: 1)
    private let op = EngineSessionCoordinator.OperationID(raw: 2)

    // Enabled during the connect phase — the exact case #38 is about.
    func test_enabled_duringOpening() {
        XCTAssertTrue(P.enabled(hasReconcileSession: true, phase: .opening(s, op)))
    }

    // Disabled during a running sync — the menu shortcut must not bypass the
    // window's three-way sync-confirmation prompt.
    func test_disabled_duringSyncing() {
        XCTAssertFalse(P.enabled(hasReconcileSession: true, phase: .syncing(s, op)))
    }

    // Disabled with no reconcile session (already at the picker), regardless of
    // phase — there is nothing to navigate.
    func test_disabled_noReconcileSession() {
        XCTAssertFalse(P.enabled(hasReconcileSession: false, phase: .opening(s, op)))
        XCTAssertFalse(P.enabled(hasReconcileSession: false, phase: .idle))
        XCTAssertFalse(P.enabled(hasReconcileSession: false, phase: .ready(s)))
    }

    // Enabled in the other permitted phases (navigation always available except
    // during a running sync).
    func test_enabled_otherPermittedPhases() {
        XCTAssertTrue(P.enabled(hasReconcileSession: true, phase: .scanning(s, op)))
        XCTAssertTrue(P.enabled(hasReconcileSession: true, phase: .ready(s)))
        XCTAssertTrue(P.enabled(hasReconcileSession: true, phase: .stopped(s)))
        XCTAssertTrue(P.enabled(hasReconcileSession: true, phase: .restartRequired("x")))
    }

    // The gate is (session AND not-syncing): a session that is syncing is the
    // only session-present case that disables it.
    func test_syncingIsTheOnlySessionPresentDisable() {
        XCTAssertFalse(P.enabled(hasReconcileSession: true, phase: .syncing(s, op)))
        XCTAssertTrue(P.enabled(hasReconcileSession: true, phase: .opening(s, op)))
    }
}
