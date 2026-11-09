import XCTest
@testable import unison_ui_mac

/// A recovery reopen is the same session recovering, so it keeps the options the
/// session was opened with, exactly. A picker-opened session has none and
/// reopens with none. Only the Ignoring Archives actions force `ignorearchives`
/// on, as a first-load argument that belongs to that request alone; it is never
/// part of the options a later reconnect replays, and the profile file is not
/// edited.
@MainActor
final class RecoveryReopenArgsTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    private struct SetupFailure: Error, CustomStringConvertible { let description: String }

    private func makeDelegate() throws -> AppDelegate {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }
        dir = NSTemporaryDirectory() + "rra-" + UUID().uuidString
        let dir = self.dir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        try "root = \(dir)/a\nroot = \(dir)/b\n".write(toFile: dir + "/P.prf", atomically: true, encoding: .utf8)
        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        d.suppressEngineEffectsForTesting = true
        return d
    }

    /// Open `P` with `args` through the real driver and bring it to `.ready`.
    private func openReady(_ d: AppDelegate, args: [String]) throws {
        let e = d.engineForTesting
        _ = d.runForTesting(e.requestOpen(profile: "P", args: args))
        guard case .opening(let s, let op) = e.phase else {
            throw SetupFailure(description: "expected opening, got \(e.phase)")
        }
        _ = d.runForTesting(e.connectFinished(s, op, result: .local))
        guard case .scanning(_, let scan) = e.phase else {
            throw SetupFailure(description: "expected scanning, got \(e.phase)")
        }
        _ = d.runForTesting(e.scanCompleted(s, scan))
        guard e.phase == .ready(s) else { throw SetupFailure(description: "expected ready, got \(e.phase)") }
    }

    /// Like `openReady`, with a live remote connection so a recovery must wait for
    /// the close.
    private func openRemoteReady(_ d: AppDelegate, args: [String]) throws {
        let e = d.engineForTesting
        _ = d.runForTesting(e.requestOpen(profile: "P", args: args))
        guard case .opening(let s, let op) = e.phase else {
            throw SetupFailure(description: "expected opening, got \(e.phase)")
        }
        _ = d.runForTesting(e.connectFinished(s, op, result: .remote(interactive: false)))
        guard case .scanning(_, let scan) = e.phase else {
            throw SetupFailure(description: "expected scanning, got \(e.phase)")
        }
        _ = d.runForTesting(e.scanCompleted(s, scan))
        guard e.phase == .ready(s) else { throw SetupFailure(description: "expected ready, got \(e.phase)") }
    }

    private var dir = ""
    private func prf(_ d: AppDelegate) throws -> String {
        try String(contentsOfFile: dir + "/P.prf", encoding: .utf8)
    }

    /// The args of the last `.beginConnect` that reached the driver.
    private func lastConnectArgs(_ d: AppDelegate) -> [String]? {
        for effect in d.effectsReachedForTesting.reversed() {
            if case .beginConnect(_, _, _, let args) = effect { return args }
        }
        return nil
    }

    func test_recoveryReopen_carriesTheSessionsOptions() throws {
        let d = try makeDelegate()
        try openReady(d, args: ["-path", "a"])

        d.reopenCurrentProfileFreshForTesting("P")

        XCTAssertEqual(lastConnectArgs(d), ["-path", "a"], "the recovered load keeps the selected path")
    }

    func test_control_pickerSession_recoversWithNoOptions() throws {
        let d = try makeDelegate()
        try openReady(d, args: [])

        d.reopenCurrentProfileFreshForTesting("P")

        XCTAssertEqual(lastConnectArgs(d), [])
    }

    /// Ordinary recovery (delete orphans and retry) forces nothing, so it keeps the
    /// vector as it is, including an explicit ignorearchives option either way.
    func test_ordinaryRecovery_keepsExplicitIgnoreArchivesOptionsUnchanged() throws {
        for original in [["-path", "a", "-ignorearchives=false"], ["-path", "a", "-ignorearchives=true"]] {
            let d = try makeDelegate()
            try openReady(d, args: original)

            d.reopenCurrentProfileFreshForTesting("P")

            XCTAssertEqual(lastConnectArgs(d), original)
        }
    }

    /// An Ignoring Archives action: the session's vector is the original, exactly;
    /// this request's first load adds the override last, so it beats an explicit
    /// disable. The profile file is not edited.
    func test_ignoringArchivesAction_putsTheOverrideOnItsOwnFirstLoad() throws {
        let original = ["-path", "a", "-ignorearchives=false"]
        let d = try makeDelegate()
        try openReady(d, args: original)
        let before = try prf(d)

        d.rescanIgnoringArchivesForTesting("P")

        XCTAssertEqual(lastConnectArgs(d), original + ["-ignorearchives=true"])
        XCTAssertEqual(d.engineForTesting.sessionArgs, original, "the override is not a session option")
        XCTAssertEqual(try prf(d), before, "the profile file is not edited")
    }

    /// The override belongs to the request that asked for it. A queued recovery
    /// that is cancelled or replaced leaves nothing behind: a later ordinary open
    /// of the same profile gets its own options only, with no forced override and
    /// no edited profile.
    func test_cancelledOrReplacedRecovery_leavesNothingForALaterOrdinaryOpen() throws {
        let original = ["-path", "a", "-ignorearchives=false"]
        for replace in [false, true] {
            let d = try makeDelegate()
            let e = d.engineForTesting
            try openRemoteReady(d, args: original)
            let before = try prf(d)

            d.rescanIgnoringArchivesForTesting("P")   // queued behind the connection close
            guard let id = d.effectsReachedForTesting.compactMap({ x -> C.OpenRequestID? in
                if case .showWaiting(let i, _) = x { return i }; return nil }).last else {
                return XCTFail("the recovery should be waiting behind the close")
            }
            if replace {
                _ = d.runForTesting(e.requestOpen(profile: "P", args: ["-path", "b"]))   // last pick wins
            } else {
                _ = d.runForTesting(e.cancelQueuedOpen(id))
            }
            guard case .closing(let s, let op, _) = e.phase else { return XCTFail("expected the close, got \(e.phase)") }
            _ = d.runForTesting(e.closeCompleted(s, op, status: 0))
            if replace {
                XCTAssertEqual(lastConnectArgs(d), ["-path", "b"], "the replacement carries its own options only")
                XCTAssertFalse((lastConnectArgs(d) ?? []).contains("-ignorearchives=true"))
                guard case .opening(let s2, let op2) = e.phase else { return XCTFail("replacement not opening: \(e.phase)") }
                _ = d.runForTesting(e.operationFailed(s2, op2, reason: "test", engineIsQuiescent: true))
            }
            XCTAssertEqual(e.phase, .idle)

            // An ordinary open of P later: its own options, nothing forced.
            let effects = e.requestOpen(profile: "P", args: original)
            _ = d.runForTesting(effects)
            XCTAssertEqual(lastConnectArgs(d), original, "no forced override")
            XCTAssertEqual(try prf(d), before, "no leftover profile edit")
        }
    }

    /// A recovery request promoted after a remote close: its first connect carries
    /// the override, and the same recovered session's later reconnect replays the
    /// original vector exactly. This also shows the override survives the queue.
    func test_recoveryPromotedAfterAClose_overridesOnce_thenReconnectReplaysTheOriginal() {
        let original = ["-path", "a", "-ignorearchives=false"]
        let e = C()
        // A remote session, ready with its connection open.
        guard let (s0, op0) = connect(e.requestOpen(profile: "P", args: original)) else {
            return XCTFail("no connect after the open")
        }
        guard let scan0 = scanOp(e.connectFinished(s0, op0, result: .remote(interactive: false))) else {
            return XCTFail("no scan after the connect")
        }
        _ = e.scanCompleted(s0, scan0)

        // The recovery: abandon it, then request the reopen with the override. It
        // queues behind the close.
        let abandon = e.abandon(reason: "test recovery")
        guard let close0 = abandon.compactMap({ x -> C.OperationID? in
            if case .closeConnection(_, let o) = x { return o }; return nil }).first else {
            return XCTFail("the abandon should close the connection")
        }
        let queuedEffects = e.requestOpen(profile: "P", args: e.sessionArgs, firstLoadArgs: ["-ignorearchives=true"])
        XCTAssertTrue(queuedEffects.contains { if case .showWaiting = $0 { return true }; return false },
                      "the recovery waits behind the close")

        // The close completes and the queue promotes the recovery.
        let promoted = e.closeCompleted(s0, close0, status: 0)
        guard let (s1, op1) = connect(promoted) else { return XCTFail("the recovery should start") }
        let firstLoad = promoted.compactMap { x -> [String]? in
            if case .beginConnect(_, _, _, let args) = x { return args }; return nil }.first
        XCTAssertEqual(firstLoad, original + ["-ignorearchives=true"], "the first connect carries the override, last")
        XCTAssertEqual(e.sessionArgs, original, "the override is not a session option")

        // The recovered session syncs, closes its connection, and reconnects.
        guard let scan1 = scanOp(e.connectFinished(s1, op1, result: .remote(interactive: false))) else {
            return XCTFail("no scan after the recovered connect")
        }
        _ = e.scanCompleted(s1, scan1)
        guard let sync = e.requestSync().compactMap({ x -> C.OperationID? in
            if case .beginSync(_, let o) = x { return o }; return nil }).first else { return XCTFail("no sync") }
        guard let close1 = e.syncCompleted(s1, sync, results: .unavailable(reason: "x")).compactMap({ x -> C.OperationID? in
            if case .closeConnection(_, let o) = x { return o }; return nil }).first else { return XCTFail("no close") }
        _ = e.closeCompleted(s1, close1, status: 0)

        let reconnect = e.requestRescan().compactMap { x -> [String]? in
            if case .beginConnect(_, _, _, let args) = x { return args }; return nil }.first
        XCTAssertEqual(reconnect, original, "the reconnect replays the original vector exactly")
    }

    private func connect(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginConnect(s, op, _, _) = x { return (s, op) } }
        return nil
    }
    private func scanOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginScan(_, op) = x { return op } }; return nil
    }
}
