import XCTest
import AppKit
@testable import unison_ui_mac

/// The staging gate at the fresh-open boundary: an open admitted earlier (queued
/// behind a close, decided moments before, or pending a sync decision) is
/// checked again against the profile's roots as they are when its effects are
/// due. A refused open dispatches nothing, fails its exact operation, and the
/// caller is told what happened to this request. A reconnect is left alone.
@MainActor
final class FreshOpenGateTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    /// A directory with an unresolvable profile "Broken" (blocked while anything
    /// is held) and a profile "Other" with resolvable roots (never blocked here).
    private func makeDirectory() throws -> String {
        let base = NSTemporaryDirectory() + "fog-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let dir = try XCTUnwrap(ArchiveMatcher.realpathResolve(base))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        try "include missing.inc\n".write(toFile: dir + "/Broken.prf", atomically: true, encoding: .utf8)
        for r in ["oa", "ob"] {
            try FileManager.default.createDirectory(atPath: dir + "/" + r, withIntermediateDirectories: true)
        }
        try "root = \(dir)/oa\nroot = \(dir)/ob\n".write(toFile: dir + "/Other.prf", atomically: true, encoding: .utf8)
        return dir
    }

    private func held() -> [AbandonedStaging] {
        var m = StagingManifest(operation: "reset", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
                                payloadFiles: [], createdAtISO8601: "2026-11-01T00:00:00Z")
        m.phase = StagingManifest.phaseStaging
        return [AbandonedStaging(quarantineDir: "/q/held", manifest: m)]
    }

    private func makeDelegate() throws -> (AppDelegate, String) {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }
        let d = AppDelegate()
        let dir = try makeDirectory()
        d.setUnisonDirectoryForTesting(dir)
        d.suppressEngineEffectsForTesting = true
        return (d, dir)
    }

    private func req(_ name: String, dir: String) -> CommandLineHandoff.Request {
        CommandLineHandoff.Request(given: name, rootsSet: 0, unisonDirectory: dir,
                                   installationPath: Bundle.main.bundlePath, sessionArgs: [])
    }

    private func connectOp(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginConnect(s, op, _, _) = x { return (s, op) } }
        return nil
    }
    private func scanOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginScan(_, op) = x { return op } }; return nil
    }
    private func reachedConnect(_ d: AppDelegate, for s: C.SessionID) -> Bool {
        d.effectsReachedForTesting.contains {
            if case .beginConnect(let x, _, _, _) = $0 { return x == s }; return false
        }
    }
    private func reachedShow(_ d: AppDelegate, for s: C.SessionID) -> Bool {
        d.effectsReachedForTesting.contains {
            if case .showSession(let x, _) = $0 { return x == s }; return false
        }
    }

    /// A remote session in `.ready` with an open connection, so a takeover must
    /// close it first and the request queues.
    private func readyRemote(_ e: C, _ d: AppDelegate, profile: String) -> C.SessionID {
        let (s, op) = connectOp(e.requestOpen(profile: profile))!
        let scanning = e.connectFinished(s, op, result: .remote(interactive: false))
        _ = e.scanCompleted(s, scanOp(scanning)!)
        let w = ReconcileWindowController(
            profile: profile, mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onSyncStart: {}, onSyncExit: { _ in },
            onEngineUncertain: { _ in }, onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
        d.installWindowForTesting(s, w)
        return s
    }

    // MARK: queued open

    func test_queuedOpen_becomesBlockedBeforeItDrains_dispatchesNothing_andEngineRecovers() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        let a = readyRemote(e, d, profile: "A")

        // Admitted while nothing is held: accepted behind the close.
        let resp = d.handleCommandLineHandoffForTesting(
            req("Broken", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .reply(.acceptedWaiting) = resp else { return XCTFail("expected accept-and-wait, got \(resp)") }
        XCTAssertTrue(e.commandLineRequestPending)
        XCTAssertTrue(d.hasWaitingWindowForTesting)

        // Its roots now overlap a held archive; the close completes and the queue drains.
        d.setAbandonedStagingForTesting(held())
        guard case .closing(let cs, let cop, _) = e.phase else { return XCTFail("expected the close in flight, got \(e.phase)") }
        let refused = d.runForTesting(e.closeCompleted(cs, cop, status: 0))

        XCTAssertTrue(refused, "the gate refuses the drained open")
        XCTAssertEqual(e.phase, .idle, "the refused operation is failed exactly; the engine returns to idle")
        XCTAssertFalse(d.hasWaitingWindowForTesting, "the waiting window is discarded")
        let next = d.effectsReachedForTesting.compactMap { x -> C.SessionID? in
            if case .showSession(let s, _) = x, s != a { return s }; return nil
        }
        XCTAssertTrue(next.isEmpty, "no session window was created")
        XCTAssertFalse(d.effectsReachedForTesting.contains {
            if case .beginConnect(let s, _, _, _) = $0 { return s != a }; return false
        }, "init1 is never dispatched for the blocked profile")

        // The engine is usable again: an unrelated profile opens.
        let started = d.runPickerOpenForTesting("Other")
        XCTAssertTrue(started)
        XCTAssertNotEqual(e.phase, .idle)
    }

    func test_queuedOpen_control_unchangedProfile_opensAfterTheClose() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        let a = readyRemote(e, d, profile: "A")
        let resp = d.handleCommandLineHandoffForTesting(
            req("Other", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .reply(.acceptedWaiting) = resp else { return XCTFail("got \(resp)") }

        guard case .closing(let cs, let cop, _) = e.phase else { return XCTFail("expected the close in flight, got \(e.phase)") }
        let refused = d.runForTesting(e.closeCompleted(cs, cop, status: 0))

        XCTAssertFalse(refused)
        XCTAssertNotEqual(e.phase, .idle)
        XCTAssertTrue(d.effectsReachedForTesting.contains {
            if case .beginConnect(let s, _, _, _) = $0 { return s != a }; return false
        }, "the unchanged profile reaches init1")
    }

    // MARK: immediate open

    func test_immediateOpen_blockedAtTheGate_reportsNotStarted_andEngineStaysIdle() throws {
        let (d, _) = try makeDelegate()
        let e = d.engineForTesting
        d.setAbandonedStagingForTesting(held())   // the request-time check is bypassed: edit landed after it

        let admitted = d.runPickerOpenForTesting("Broken")

        XCTAssertFalse(admitted, "a refused open is not reported as admitted")
        XCTAssertEqual(e.phase, .idle)
        XCTAssertFalse(d.effectsReachedForTesting.contains {
            switch $0 { case .showSession, .beginConnect: return true; default: return false }
        }, "no window and no bridge dispatch")
        XCTAssertTrue(d.runPickerOpenForTesting("Other"), "a subsequent valid open works")
    }

    func test_immediateOpen_control_unchangedProfile_isAdmitted() throws {
        let (d, _) = try makeDelegate()
        XCTAssertTrue(d.runPickerOpenForTesting("Other"))
        XCTAssertNotEqual(d.engineForTesting.phase, .idle)
    }

    // MARK: takeover promoted synchronously

    func test_takeover_promotedSynchronously_butRefused_reportsRefused_outgoingWindowGone() throws {
        let (d, _) = try makeDelegate()
        let e = d.engineForTesting
        // A local ready session has no connection to close, so the takeover promotes at once.
        let (s, op) = connectOp(e.requestOpen(profile: "A"))!
        _ = e.scanCompleted(s, scanOp(e.connectFinished(s, op, result: .local))!)
        let w = ReconcileWindowController(
            profile: "A", mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onSyncStart: {}, onSyncExit: { _ in },
            onEngineUncertain: { _ in }, onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
        d.installWindowForTesting(s, w)
        d.setAbandonedStagingForTesting(held())

        let out = d.commandLineTakeoverForTesting(name: "Broken")

        XCTAssertFalse(out.started)
        XCTAssertFalse(out.waiting)
        XCTAssertTrue(try XCTUnwrap(out.refusal).contains("Broken"), "the caller gets the gate's refusal")
        XCTAssertFalse(d.hasWindowForTesting(s), "the outgoing window is gone")
        XCTAssertEqual(e.phase, .idle)
        XCTAssertFalse(e.commandLineRequestPending)
        XCTAssertTrue(d.pickerStateForTesting.visible, "the picker is restored")
        XCTAssertEqual(d.pickerStateForTesting.selected, "Broken")
    }

    // MARK: pre-exit check on the sync decision

    func test_syncDecision_targetBecomesBlocked_refusesBeforeTouchingTheSync() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        let (s, op) = connectOp(e.requestOpen(profile: "A"))!
        let scanning = e.connectFinished(s, op, result: .remote(interactive: false))
        _ = e.scanCompleted(s, scanOp(scanning)!)
        guard let syncOp = e.requestSync().compactMap({ x -> C.OperationID? in
            if case .beginSync(_, let o) = x { return o }; return nil }).first else { return XCTFail("no sync") }
        let ticket = d.setPendingSyncDecisionForTesting(
            request: req("Broken", dir: dir), session: s, expired: false)
        d.setAbandonedStagingForTesting(held())   // blocked while the sheet was up

        d.applySyncDecisionForTesting(.abortAndClose)

        guard case .refused = ticket.wait(seconds: 1) else { return XCTFail("the caller should be refused") }
        XCTAssertEqual(e.phase, .syncing(s, syncOp), "the sync is untouched")
        XCTAssertFalse(e.commandLineRequestPending)
        XCTAssertFalse(d.effectsReachedForTesting.contains {
            if case .abortSync = $0 { return true }; return false
        }, "no abort was requested")
    }

    // MARK: a reconnect is not a fresh open

    func test_reconnectBatch_isLeftAlone() throws {
        let (d, _) = try makeDelegate()
        d.setAbandonedStagingForTesting(held())
        let s = C.SessionID(raw: 42), op = C.OperationID(raw: 43)

        let refused = d.runForTesting([.beginConnect(s, op, profile: "Broken", args: [])])

        XCTAssertFalse(refused, "only a batch with .showSession is a fresh open")
        XCTAssertTrue(reachedConnect(d, for: s))
    }

    // MARK: a retry's temporary profile edit

    private func suffixed(_ dir: String, _ profile: String) throws -> (url: URL, original: String) {
        let url = URL(fileURLWithPath: dir + "/" + profile + ".prf")
        return (url, try String(contentsOf: url, encoding: .utf8))
    }

    /// A prepared retry passes admission (the edit is injected, its reopen is
    /// queued behind the remote close), then the gate refuses it when it drains.
    /// No init1 will run to clean the edit up, so the refusal restores it.
    func test_retryRefusedAtTheFinalGate_leavesTheProfileUnchanged() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        _ = readyRemote(e, d, profile: "Broken")
        let (url, original) = try suffixed(dir, "Broken")

        d.rescanIgnoringArchivesForTesting("Broken")   // injects, closes, queues the reopen
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix(AppDelegate.ignoreArchivesInjectedSuffix),
                      "the temporary edit is in place while the retry waits")

        d.setAbandonedStagingForTesting(held())
        guard case .closing(let cs, let cop, _) = e.phase else { return XCTFail("expected the close, got \(e.phase)") }
        XCTAssertTrue(d.runForTesting(e.closeCompleted(cs, cop, status: 0)), "the gate refuses the drained retry")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "the profile file is back as it was")
        XCTAssertEqual(e.phase, .idle)
    }

    /// An edit owned by a different retry is not this open's to restore.
    func test_refusedOpen_doesNotRestoreAnUnrelatedRetrysEdit() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        _ = readyRemote(e, d, profile: "Other")
        d.rescanIgnoringArchivesForTesting("Other")   // Other's retry is waiting, its edit injected
        let (url, original) = try suffixed(dir, "Other")
        XCTAssertNotEqual(original, "")
        d.setAbandonedStagingForTesting(held())

        // A fresh open of a different profile is refused at the gate.
        let s = C.SessionID(raw: 900), op = C.OperationID(raw: 901)
        XCTAssertTrue(d.runForTesting([.showSession(s, profile: "Broken"),
                                       .beginConnect(s, op, profile: "Broken", args: [])]))

        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix(AppDelegate.ignoreArchivesInjectedSuffix),
                      "Other's temporary edit is untouched")
    }

    // MARK: the reply is tied to the request

    /// The coordinator's reply to a pick in `.restartRequired` is the restart
    /// effect. The effects are classified without running them: running one
    /// presents the restart notice, a real modal.
    func test_pickInRestartRequired_isNotReportedAsAdmitted() throws {
        let (d, _) = try makeDelegate()
        let e = d.engineForTesting
        let (s, op) = connectOp(e.requestOpen(profile: "A"))!
        _ = e.operationFailed(s, op, reason: "wedged", engineIsQuiescent: false)   // .restartRequired, effects not run
        XCTAssertNotEqual(e.phase, .idle, "a non-idle phase is not evidence the open was accepted")

        let effects = e.requestOpen(profile: "Other")
        XCTAssertTrue(d.admissionIsRefusedForTesting(effects: effects))
    }

    func test_startThatFailsBeforeInit1_isRefused_notReportedStarted() throws {
        let (d, _) = try makeDelegate()
        let e = d.engineForTesting
        let effects = e.requestOpen(profile: "Other")   // .showSession + .beginConnect
        let (s, op) = connectOp(effects)!
        _ = e.operationFailed(s, op, reason: "session args failed", engineIsQuiescent: true)   // back at idle
        XCTAssertEqual(e.phase, .idle)

        XCTAssertTrue(d.admissionIsRefusedForTesting(effects: effects),
                      "a start that ended before init1 is refused, whatever the coordinator reported earlier")
    }

    func test_startedOpen_isReportedStarted() throws {
        let (d, _) = try makeDelegate()
        let effects = d.engineForTesting.requestOpen(profile: "Other")
        XCTAssertFalse(d.admissionIsRefusedForTesting(effects: effects))
    }
}
