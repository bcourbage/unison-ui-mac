import XCTest
import AppKit
@testable import unison_ui_mac

/// Driver-level (AppDelegate) coverage for the running-instance takeover findings
/// that the reducer tests cannot expose:
///   P1 — after a command-line request replaces the visible session, the old
///        window must not drive the engine against the replacement, and its
///        presentation is torn down.
///   P2 — a picker selection blocked by a pending command-line request must not
///        consume a launch's pending options.
/// These exercise the PRODUCTION coordinator and the real guarded methods through
/// `#if DEBUG` seams.
@MainActor
final class CommandLineTakeoverDriverTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    private func connect(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginConnect(s, op, _, _) = x { return (s, op) } }
        return nil
    }
    private func scanOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginScan(_, op) = x { return op } }; return nil
    }

    /// Drive `engine` (pure reducer, no driver effects run) to `.ready` for a
    /// fresh local session and return its id.
    @discardableResult
    private func openLocalToReady(_ e: C, profile: String) -> C.SessionID {
        let (s, op) = connect(e.requestOpen(profile: profile))!
        let scanning = e.connectFinished(s, op, result: .local)
        _ = e.scanCompleted(s, scanOp(scanning)!)
        return s
    }

    // MARK: P1 — a stale window cannot drive the engine after a takeover

    func test_p1_staleWindowSync_isIgnored_afterCommandLineTakeover() {
        let d = AppDelegate()
        let e = d.engineForTesting

        let a = openLocalToReady(e, profile: "A")     // .ready(A), local
        XCTAssertEqual(e.currentSession, a)

        // A command-line request takes over while A shows results. Local session,
        // so it starts immediately; drive B to ready.
        let (started, effects) = e.admitCommandLineOpen(profile: "B", args: [])
        XCTAssertTrue(started)
        let (bS, bOp) = connect(effects)!
        let bScanning = e.connectFinished(bS, bOp, result: .local)
        _ = e.scanCompleted(bS, scanOp(bScanning)!)
        XCTAssertEqual(e.currentSession, bS, "B is now the current session")
        XCTAssertNotEqual(bS, a)

        // A's window (session A) presses Go. The guard must make it a no-op; the
        // engine must NOT start a sync of B. (Without the guard, the unqualified
        // requestSync would sync the ready session B.)
        d.windowRequestedSyncForTesting(a)
        XCTAssertEqual(e.phase, .ready(bS), "a stale window's Go must not sync the replacement session")
    }

    func test_p1_takeoverTearsDownOutgoingWindowPresentation() {
        let d = AppDelegate()
        let s = C.SessionID(raw: 7)
        let w = ReconcileWindowController(
            profile: "A", mergeConfigured: false,
            onClose: {}, onRescanRequested: {},
            onSyncStart: {}, onSyncExit: { _ in }, onEngineUncertain: { _ in },
            onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
        d.installWindowForTesting(s, w)
        XCTAssertTrue(d.hasWindowForTesting(s))

        XCTAssertTrue(d.detachSessionPresentationForTesting(s), "the window was present and removed")
        XCTAssertFalse(d.hasWindowForTesting(s), "the outgoing session's window mapping is gone")
        XCTAssertNil(w.window?.delegate, "its delegate is detached so a later close can't re-enter")
    }

    // MARK: P2 — a blocked picker selection keeps the launch's pending options

    func test_p2_blockedPickerSelection_doesNotConsumeLaunchOptions() {
        let d = AppDelegate()
        AppDelegate.testPickBlockedModalSuppressed = true
        defer { AppDelegate.testPickBlockedModalSuppressed = false }
        // No Unison directory, so the abandoned-staging gate is inert in the test.
        d.setUnisonDirectoryForTesting("")
        d.launchOverridesForTesting = LaunchOverrideRouter(launchArgs: ["-path", "Documents"])

        // Make a command-line request pending: A scanning, B admitted (waiting).
        let e = d.engineForTesting
        let (aS, aOp) = connect(e.requestOpen(profile: "A"))!
        _ = e.connectFinished(aS, aOp, result: .remote(interactive: false))   // .scanning(A)
        let (started, _) = e.admitCommandLineOpen(profile: "B", args: ["-path", "B"])
        XCTAssertFalse(started)
        XCTAssertTrue(e.commandLineRequestPending)

        // The launch's first picker selection (C) is blocked by the pending
        // command-line request. It must report NOT admitted, and the launch router
        // must keep its options for the retry.
        let args = d.launchOverridesForTesting.argsForNextOpen()
        XCTAssertEqual(args, ["-path", "Documents"])
        let accepted = d.profileSelectedForTesting("C", args: args)
        XCTAssertFalse(accepted, "a blocked picker selection is not admitted")

        // Consume-on-accept: with accepted == false the options survive.
        var router = d.launchOverridesForTesting
        router.didOpen(accepted: accepted)
        d.launchOverridesForTesting = router
        XCTAssertEqual(d.launchOverridesForTesting.argsForNextOpen(), ["-path", "Documents"],
                       "the retry still receives the launch's -path Documents")
    }
}
