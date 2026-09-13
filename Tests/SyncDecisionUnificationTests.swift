import XCTest
import AppKit
@testable import unison_ui_mac

/// Regression coverage for the three #174 P2 findings on the unified sync
/// decision, exercised through the PRODUCTION handlers via `#if DEBUG` seams and
/// with controlled ordering (never timing assumptions):
///
///   P2#1 — a stale window-close callback delivered after the sync finished must
///          perform NO stop, window close, or open (the token is invalidated).
///   P2#2 — only one sync decision may be open app-wide: an ordinary window close
///          and a command-line request are mutually exclusive in both orders.
///   P2#3 — Escape scoping is a keyboard-context concern verified live; here the
///          content/choice mapping is covered by SyncDecisionSheetTests.
///
/// Plus the explicit acceptance requirement: when the sync finishes (or fails)
/// while a command-line decision is open, the caller is resolved with an accurate
/// FINAL message that distinguishes a clean completion from a failure/restart.
@MainActor
final class SyncDecisionUnificationTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    // MARK: shared engine-driving helpers (mirror the takeover-driver tests)

    private func connect(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginConnect(s, op, _, _) = x { return (s, op) } }
        return nil
    }
    private func scanOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginScan(_, op) = x { return op } }; return nil
    }
    private func syncOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginSync(_, op) = x { return op } }; return nil
    }

    private func driveToSyncingWithOp(_ e: C, profile: String,
                                      interactive: Bool = false) -> (session: C.SessionID, syncOp: C.OperationID) {
        let (s, op) = connect(e.requestOpen(profile: profile))!
        let scanning = e.connectFinished(s, op, result: .remote(interactive: interactive))
        _ = e.scanCompleted(s, scanOp(scanning)!)
        return (s, syncOp(e.requestSync())!)
    }
    @discardableResult
    private func driveToSyncing(_ e: C, profile: String) -> C.SessionID {
        driveToSyncingWithOp(e, profile: profile).session
    }

    private func installWindow(_ d: AppDelegate, _ session: C.SessionID, profile: String) {
        let w = ReconcileWindowController(
            profile: profile, mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onSyncStart: {}, onSyncExit: { _ in },
            onEngineUncertain: { _ in }, onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
        d.installWindowForTesting(session, w)
    }

    private func req(given: String, dir: String, args: [String] = []) -> CommandLineHandoff.Request {
        CommandLineHandoff.Request(given: given, rootsSet: 0, unisonDirectory: dir,
                                   installationPath: Bundle.main.bundlePath, sessionArgs: args)
    }
    private func makeUnisonDir(profile: String) -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clihandoff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("\(profile).prf"),
                                       contents: Data("root = \(dir)/r1\nroot = \(dir)/r2\n".utf8))
        return dir
    }

    private func makeWindowController(
        profile: String = "A",
        onSyncExit: @escaping @MainActor (EngineSessionCoordinator.SyncExitIntent) -> Void = { _ in },
        onEndDecision: @escaping @MainActor () -> Void = {}
    ) -> ReconcileWindowController {
        ReconcileWindowController(
            profile: profile, mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onSyncStart: {}, onSyncExit: onSyncExit,
            onBeginSyncCloseDecision: { true }, onEndSyncCloseDecision: onEndDecision,
            onEngineUncertain: { _ in }, onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
    }

    // MARK: P2#1 — a stale window-close callback after completion does nothing

    func test_windowClose_staleCallbackAfterCompletion_noStopNoClose() {
        var exits: [EngineSessionCoordinator.SyncExitIntent] = []
        let w = makeWindowController(onSyncExit: { exits.append($0) })
        w.setSyncingForTesting(true)

        // The sheet is up: a decision token is armed.
        let token = w.armWindowCloseDecisionTokenForTesting()
        // The sync finishes on its own; dismissSyncCloseSheetIfPresent invalidates the
        // token before ending the sheet. Model that invalidation.
        w.invalidateWindowCloseDecisionForTesting()

        // The sheet's completion fires afterwards with the user's (now stale) Stop.
        var closed = false
        w.resolveWindowCloseChoice(.stop, token: token, closeWindow: { closed = true })

        XCTAssertTrue(exits.isEmpty, "a stale Stop must not drive a sync exit")
        XCTAssertFalse(closed, "a stale Stop must not close the window")
        XCTAssertFalse(w.userRequestedStopForTesting, "a stale Stop must not flag a user stop")
    }

    func test_windowClose_staleBackgroundAfterCompletion_noExitNoClose() {
        var exits: [EngineSessionCoordinator.SyncExitIntent] = []
        let w = makeWindowController(onSyncExit: { exits.append($0) })
        w.setSyncingForTesting(true)
        let token = w.armWindowCloseDecisionTokenForTesting()
        w.invalidateWindowCloseDecisionForTesting()

        var closed = false
        w.resolveWindowCloseChoice(.background, token: token, closeWindow: { closed = true })

        XCTAssertTrue(exits.isEmpty, "a stale Background must not drive a sync exit")
        XCTAssertFalse(closed, "a stale Background must not close the window")
    }

    // MARK: valid window-close callbacks still act (control cases)

    func test_windowClose_stop_actsAndCloses() {
        var exits: [EngineSessionCoordinator.SyncExitIntent] = []
        var ended = false
        let w = makeWindowController(onSyncExit: { exits.append($0) }, onEndDecision: { ended = true })
        w.setSyncingForTesting(true)
        let token = w.armWindowCloseDecisionTokenForTesting()

        var closed = false
        w.resolveWindowCloseChoice(.stop, token: token, closeWindow: { closed = true })

        XCTAssertEqual(exits, [.abortAndClose], "Stop drives an abort-and-close exit")
        XCTAssertTrue(w.userRequestedStopForTesting, "Stop flags a user stop")
        XCTAssertTrue(closed, "Stop closes the window")
        XCTAssertTrue(ended, "the decision slot is released on resolve")
    }

    func test_windowClose_background_actsAndCloses() {
        var exits: [EngineSessionCoordinator.SyncExitIntent] = []
        let w = makeWindowController(onSyncExit: { exits.append($0) })
        w.setSyncingForTesting(true)
        let token = w.armWindowCloseDecisionTokenForTesting()

        var closed = false
        w.resolveWindowCloseChoice(.background, token: token, closeWindow: { closed = true })

        XCTAssertEqual(exits, [.closeAndLetRun], "Background lets the sync run on")
        XCTAssertFalse(w.userRequestedStopForTesting, "Background is not a user stop")
        XCTAssertTrue(closed, "Background closes the window")
    }

    func test_windowClose_keep_noExitNoClose() {
        var exits: [EngineSessionCoordinator.SyncExitIntent] = []
        var ended = false
        let w = makeWindowController(onSyncExit: { exits.append($0) }, onEndDecision: { ended = true })
        w.setSyncingForTesting(true)
        let token = w.armWindowCloseDecisionTokenForTesting()

        var closed = false
        w.resolveWindowCloseChoice(.keep, token: token, closeWindow: { closed = true })

        XCTAssertTrue(exits.isEmpty, "Keep leaves the sync untouched")
        XCTAssertFalse(closed, "Keep keeps the window open")
        XCTAssertTrue(ended, "Keep still releases the decision slot")
    }

    // MARK: P2#2 — one decision app-wide, both orderings, through the arbiter

    func test_mutualExclusion_windowCloseThenCLIRequest_refusesBusy() {
        let d = AppDelegate()
        AppDelegate.testSyncDecisionSheetSuppressed = true
        defer { AppDelegate.testSyncDecisionSheetSuppressed = false }
        let dir = makeUnisonDir(profile: "B")
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting
        let aS = driveToSyncing(e, profile: "A")
        installWindow(d, aS, profile: "A")

        // An ordinary window-close decision opens first, taking the single slot.
        XCTAssertTrue(d.beginWindowCloseDecisionForTesting())
        XCTAssertEqual(d.activeSyncDecisionKindForTesting, "windowClose")

        // A command-line request during the same sync must be refused (no second
        // sheet), with the busy explanation — not left awaiting a decision.
        let resp = d.handleCommandLineHandoffForTesting(
            req(given: "B", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .reply(.refused(let m)) = resp else {
            return XCTFail("a CLI request while a window-close decision is open must be refused, got \(resp)")
        }
        XCTAssertTrue(m.contains("already has a sync decision open"),
                      "the refusal must explain a decision is already open: \(m)")
        XCTAssertFalse(d.hasPendingSyncDecisionForTesting, "no CLI decision is armed while the slot is held")
        XCTAssertEqual(d.activeSyncDecisionKindForTesting, "windowClose", "the window-close decision is preserved")
    }

    func test_mutualExclusion_cliRequestThenWindowClose_preservesCLI() {
        let d = AppDelegate()
        AppDelegate.testSyncDecisionSheetSuppressed = true
        defer { AppDelegate.testSyncDecisionSheetSuppressed = false }
        let dir = makeUnisonDir(profile: "B")
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting
        let aS = driveToSyncing(e, profile: "A")
        installWindow(d, aS, profile: "A")

        // A command-line request opens the decision first (takes the slot).
        let resp = d.handleCommandLineHandoffForTesting(
            req(given: "B", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .awaitDecision = resp else { return XCTFail("expected the CLI request to arm a decision, got \(resp)") }
        XCTAssertEqual(d.activeSyncDecisionKindForTesting, "commandLine")

        // An ordinary window close arriving now must NOT raise a second sheet: the
        // arbiter refuses the acquisition, so windowShouldClose returns false and the
        // command-line decision is preserved.
        XCTAssertFalse(d.beginWindowCloseDecisionForTesting(),
                       "a window close must not open a second decision while a CLI decision is up")
        XCTAssertEqual(d.activeSyncDecisionKindForTesting, "commandLine", "the CLI decision is preserved")
        XCTAssertTrue(d.hasPendingSyncDecisionForTesting)
    }

    func test_windowCloseSlot_releasedOnEnd_allowsReacquire() {
        let d = AppDelegate()
        XCTAssertTrue(d.beginWindowCloseDecisionForTesting())
        XCTAssertFalse(d.beginWindowCloseDecisionForTesting(), "a repeated close while one is open is refused")
        d.endWindowCloseDecisionForTesting()
        XCTAssertNil(d.activeSyncDecisionKindForTesting, "ending frees the slot")
        XCTAssertTrue(d.beginWindowCloseDecisionForTesting(), "the slot can be re-acquired after release")
    }

    // MARK: explicit acceptance — accurate FINAL CLI message on completion vs failure

    func test_cliDecision_syncCompletesWhileOpen_refusesWithCompletedMessage() {
        let d = AppDelegate()
        let e = d.engineForTesting
        // Interactive so the completed sync rests at .ready (results shown, window
        // stays) rather than auto-closing back through the connection.
        let (aS, syncO) = driveToSyncingWithOp(e, profile: "A", interactive: true)
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x"), session: aS, expired: false)

        // The sync finishes cleanly: phase → .ready(aS). The post-transition hook
        // resolves the pending decision.
        _ = e.syncCompleted(aS, syncO, results: .available([]))
        guard case .ready(aS) = e.phase else {
            return XCTFail("expected the completed sync to rest at .ready, got \(e.phase)")
        }
        d.resolvePendingSyncDecisionIfStaleForTesting()

        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        guard case .refused(let m) = ticket.wait(seconds: 1) else {
            return XCTFail("a completed sync must resolve the caller, not leave it waiting")
        }
        XCTAssertTrue(m.contains("finished the synchronization"),
                      "a clean completion must read as a completion, not a failure: \(m)")
        XCTAssertFalse(m.contains("quit and reopen"), "a clean completion must not read as a restart: \(m)")
    }

    func test_cliDecision_syncFailsWhileOpen_refusesWithRestartMessage() {
        let d = AppDelegate()
        let e = d.engineForTesting
        let (aS, syncO) = driveToSyncingWithOp(e, profile: "A")
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req(given: "B", dir: "/x"), session: aS, expired: false)

        // The sync fails without a quiescent engine: phase → .restartRequired.
        _ = e.operationFailed(aS, syncO, reason: "bridge lost", engineIsQuiescent: false)
        guard case .restartRequired = e.phase else {
            return XCTFail("expected the engine to require a restart after a non-quiescent failure")
        }
        d.resolvePendingSyncDecisionIfStaleForTesting()

        XCTAssertFalse(d.hasPendingSyncDecisionForTesting)
        guard case .refused(let m) = ticket.wait(seconds: 1) else {
            return XCTFail("a failed sync must resolve the caller")
        }
        XCTAssertTrue(m.contains("quit and reopen"),
                      "a failure/restart must read as a restart, not a clean completion: \(m)")
        XCTAssertFalse(m.contains("finished the synchronization"),
                       "a failure must not read as a clean completion: \(m)")
    }
}
