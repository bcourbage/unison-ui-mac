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

    private func req(given: String, dir: String, args: [String] = []) -> CommandLineHandoff.Request {
        CommandLineHandoff.Request(given: given, rootsSet: 0, unisonDirectory: dir,
                                   installationPath: Bundle.main.bundlePath, sessionArgs: args)
    }

    /// A temp Unison directory with one profile file, so the handler's launch
    /// resolution and listedProfiles both accept the profile name.
    private func makeUnisonDir(profile: String) -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clihandoff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("\(profile).prf"),
                                       contents: Data("root = \(dir)/r1\nroot = \(dir)/r2\n".utf8))
        return dir
    }

    /// The reviewer's carry-over: exercise the REAL handler (not the teardown
    /// helper directly). A request during scan is accepted through the handler,
    /// which must tear down the outgoing session's window. Removing the teardown
    /// invocation from the handler's takeover path fails this.
    func test_p1_handler_tearsDownOutgoingWindow_onAcceptedTakeover() {
        let d = AppDelegate()
        let dir = makeUnisonDir(profile: "B")
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting

        // Outgoing session A, scanning, with a real window installed.
        let (aS, aOp) = connect(e.requestOpen(profile: "A"))!
        _ = e.connectFinished(aS, aOp, result: .remote(interactive: false))   // .scanning(A)
        let aWindow = ReconcileWindowController(
            profile: "A", mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onSyncStart: {}, onSyncExit: { _ in },
            onEngineUncertain: { _ in }, onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
        d.installWindowForTesting(aS, aWindow)
        XCTAssertTrue(d.hasWindowForTesting(aS))

        let resp = d.handleCommandLineHandoffForTesting(
            req(given: "B", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))

        guard case .reply(.acceptedWaiting) = resp else {
            return XCTFail("expected accepted-and-waiting through the handler, got \(resp)")
        }
        XCTAssertFalse(d.hasWindowForTesting(aS),
                       "the handler's takeover must tear down the outgoing session's window")
        XCTAssertTrue(e.commandLineRequestPending, "B is the pending command-line request")
    }

    // MARK: PR-B — sync-decision arming, single-pending, expiry, admission

    private func syncOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginSync(_, op) = x { return op } }; return nil
    }

    /// Drive `engine` to `.syncing` for a fresh remote session and return its id.
    @discardableResult
    private func driveToSyncing(_ e: C, profile: String) -> C.SessionID {
        driveToSyncingWithOp(e, profile: profile).session
    }

    private func driveToSyncingWithOp(_ e: C, profile: String) -> (session: C.SessionID, syncOp: C.OperationID) {
        let (s, op) = connect(e.requestOpen(profile: profile))!
        let scanning = e.connectFinished(s, op, result: .remote(interactive: false))
        _ = e.scanCompleted(s, scanOp(scanning)!)   // .ready, connection open
        return (s, syncOp(e.requestSync())!)         // .syncing
    }

    /// Install a real window for `session` (so an active sync has a decision surface).
    private func installWindow(_ d: AppDelegate, _ session: C.SessionID, profile: String) {
        let w = ReconcileWindowController(
            profile: profile, mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onSyncStart: {}, onSyncExit: { _ in },
            onEngineUncertain: { _ in }, onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
        d.installWindowForTesting(session, w)
    }

    func test_syncDecision_armsDecision_andSecondRequestIsRefused() {
        let d = AppDelegate()
        AppDelegate.testSyncDecisionSheetSuppressed = true
        defer { AppDelegate.testSyncDecisionSheetSuppressed = false }
        let dir = makeUnisonDir(profile: "B")
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("C.prf"),
                                       contents: Data("root = \(dir)/r1\nroot = \(dir)/r2\n".utf8))
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting
        let aS = driveToSyncing(e, profile: "A")
        installWindow(d, aS, profile: "A")   // an active sync the user is watching

        // A request during an active sync defers (two-phase): the handler returns
        // an interim, keeping the caller waiting for the decision.
        let resp = d.handleCommandLineHandoffForTesting(
            req(given: "B", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .awaitDecision(let interim, _, _) = resp else {
            return XCTFail("expected a deferred (await-decision) serve, got \(resp)")
        }
        XCTAssertTrue(interim.message.contains("synchronizing"))
        XCTAssertTrue(d.hasPendingSyncDecisionForTesting)

        // A second request while one is awaiting the decision replies immediately,
        // refused as already-pending; it does not arm a second decision.
        let resp2 = d.handleCommandLineHandoffForTesting(
            req(given: "C", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .reply(.refused(let m2)) = resp2 else { return XCTFail("expected already-pending refusal") }
        XCTAssertTrue(m2.contains("already handling another command-line request"))
    }

    func test_backgroundSyncWithoutWindow_acceptsAndWaits_noDecision() {
        // After Close (let it run), the syncing session has no window; a new request
        // must accept-and-wait (drains when the sync finishes), not claim a decision.
        let d = AppDelegate()
        let dir = makeUnisonDir(profile: "B")
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting
        driveToSyncing(e, profile: "A")   // syncing, but NO window installed

        let resp = d.handleCommandLineHandoffForTesting(
            req(given: "B", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .reply(.acceptedWaiting) = resp else {
            return XCTFail("a windowless background sync should accept-and-wait, got \(resp)")
        }
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting, "no sync decision is raised without a window")
        XCTAssertTrue(e.commandLineRequestPending)
    }

    func test_syncDecision_keepSyncing_refusesCaller_opensNothing() {
        let d = AppDelegate()
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x"), session: C.SessionID(raw: 1), expired: false)
        d.applySyncDecisionForTesting(.keepSyncing)
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        XCTAssertFalse(d.engineForTesting.openRequestPending, "Keep Syncing opens nothing")
        guard case .refused = ticket.wait(seconds: 1) else { return XCTFail("caller should be refused") }
    }

    func test_syncDecision_expired_doesNotAdmit_norTouchTheSync() {
        // Engine actually syncing the originating session; the request is expired.
        // An expired request-specific choice is wholly inactive: it must not open the
        // request AND must not half-perform a sync exit (#5).
        let d = AppDelegate()
        let e = d.engineForTesting
        let aS = driveToSyncing(e, profile: "A")
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x"), session: aS, expired: true)
        d.applySyncDecisionForTesting(.closeAndLetRun)
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        XCTAssertFalse(e.commandLineRequestPending, "an expired request must not open")
        guard case .syncing = e.phase else {
            return XCTFail("an expired request-specific choice must leave the sync untouched")
        }
        guard case .refused = ticket.wait(seconds: 1) else { return XCTFail("expired caller should be refused") }
    }

    func test_syncDecision_lateCallbackForExpiredRequest_doesNotResolveNewer() {
        // A's decision expires and B occupies the released slot; A's delayed sheet
        // dismissal callback must not resolve B (identity binding, #2).
        let d = AppDelegate()
        let aS = driveToSyncing(d.engineForTesting, profile: "A")
        let (oldTicket, fireOldStaleCallback) =
            d.armSyncDecisionForTesting(request: req(given: "Bold", dir: "/x"), session: aS)
        d.expireSyncDecisionForTesting()                 // A expires and releases the slot
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        guard case .refused = oldTicket.wait(seconds: 1) else { return XCTFail("old caller should be refused") }

        // B arms into the released slot.
        let newTicket = d.setPendingSyncDecisionForTesting(
            request: req(given: "Bnew", dir: "/x"), session: aS, expired: false)
        XCTAssertTrue(d.hasPendingSyncDecisionForTesting)

        // A's late callback fires now; it must be a no-op for B.
        fireOldStaleCallback()
        XCTAssertTrue(d.hasPendingSyncDecisionForTesting, "a stale callback must not resolve the newer request")
        XCTAssertNil(newTicket.wait(seconds: 0.1), "the newer request's caller must remain unresolved")
    }

    func test_syncDecision_transportLostBeforeInterim_invalidatesPending() {
        // The caller went away before the interim could be sent: the serving thread
        // abandons the ticket, which must invalidate the still-armed decision (#3).
        let d = AppDelegate()
        AppDelegate.testSyncDecisionSheetSuppressed = true
        defer { AppDelegate.testSyncDecisionSheetSuppressed = false }
        let e = d.engineForTesting
        let aS = driveToSyncing(e, profile: "A")
        let dir = makeUnisonDir(profile: "B")
        d.setUnisonDirectoryForTesting(dir)
        installWindow(d, aS, profile: "A")

        let serve = d.handleCommandLineHandoffForTesting(
            req(given: "B", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .awaitDecision(_, let ticket, _) = serve else { return XCTFail("expected deferred serve") }
        XCTAssertTrue(d.hasPendingSyncDecisionForTesting)

        ticket.abandon()   // serving thread: interim write failed
        // The abandon hook hops to main; drain the main queue, then assert.
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting,
                       "transport loss before admission invalidates the pending decision")
    }

    func test_syncDecision_abandonBeatsLeaveChoice_noExitNoAdmission() {
        // The race the async invalidation could lose: the caller went away (ticket
        // abandoned) but the leave-choice callback runs BEFORE the queued
        // invalidation. The atomic claim must make the choice inactive — no sync
        // exit, no admission — because abandonment already won the ticket.
        let d = AppDelegate()
        let e = d.engineForTesting
        let aS = driveToSyncing(e, profile: "A")
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x", args: ["-path", "B"]), session: aS, expired: false)

        ticket.abandon()   // transport gone; abandonment wins the ticket synchronously

        // The user-choice callback runs before any queued invalidation drains.
        d.applySyncDecisionForTesting(.closeAndLetRun)

        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        XCTAssertFalse(e.commandLineRequestPending, "an abandoned request must not be admitted by a later choice")
        guard case .syncing = e.phase else {
            return XCTFail("an abandoned request's choice must not exit the sync")
        }
    }

    func test_syncDecision_resolvedWhenSyncEndsWhilePending() {
        // The sync finishes on its own while the decision is open (no user choice):
        // the caller must be resolved rather than left waiting to the deadline (#4).
        let d = AppDelegate()
        let e = d.engineForTesting
        let (aS, syncO) = driveToSyncingWithOp(e, profile: "A")
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x"), session: aS, expired: false)
        XCTAssertTrue(d.hasPendingSyncDecisionForTesting)

        _ = e.syncCompleted(aS, syncO, results: .available([]))   // phase leaves .syncing
        d.resolvePendingSyncDecisionIfStaleForTesting()           // what run() does after a transition
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting, "a real sync end resolves the pending decision")
        guard case .refused = ticket.wait(seconds: 1) else { return XCTFail("caller should be refused, not left waiting") }
    }

    func test_syncDecision_leave_admitsRequest_andTearsDownOutgoing() {
        // Engine syncing the originating session, with its window on screen.
        // Close (let it run): no bridge abort, so engine-safe; the not-expired
        // request is admitted via the takeover and the syncing window is torn down.
        let d = AppDelegate()
        let e = d.engineForTesting
        let aS = driveToSyncing(e, profile: "A")
        installWindow(d, aS, profile: "A")
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x", args: ["-path", "B"]), session: aS, expired: false)
        d.applySyncDecisionForTesting(.closeAndLetRun)

        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        XCTAssertTrue(e.commandLineRequestPending, "the request is admitted as a pending command-line open")
        XCTAssertFalse(d.hasWindowForTesting(aS), "the outgoing session's window is torn down")
        guard case .acceptedWaiting = ticket.wait(seconds: 1) else {
            return XCTFail("admitted caller should get accepted-and-waiting")
        }
    }

    func test_syncDecision_phaseChanged_refusesInsteadOfTakeover() {
        // The sync failed/ended (or the session changed) while the sheet was open:
        // a leave choice must not queue a takeover into a phase that cannot drain.
        let d = AppDelegate()
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x"),
            session: C.SessionID(raw: 99),   // not the engine's current (idle) session
            expired: false)
        d.applySyncDecisionForTesting(.closeAndLetRun)
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        XCTAssertFalse(d.engineForTesting.openRequestPending,
                       "a phase change must yield an explicit refusal, never a stuck takeover")
        guard case .refused = ticket.wait(seconds: 1) else { return XCTFail("expected refusal on a phase change") }
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
