import XCTest
@testable import unison_ui_mac

/// Terminal-causality integrity fix (supersedes PR #51's reuse conclusion): an
/// interruption must NEVER upgrade a terminal that is normally restart-required
/// into a reusable `.stopped`. Terminal CAUSE — not merely a matching session/op
/// and timing — controls reuse.
///
/// These drive the coordinator directly (the coordinator machinery is retained
/// even though `ScanInterruptPolicy.stopInPlaceEnabled` disables entry to
/// `.interruptingScan` in production) to prove the fail-closed classification:
///   - the `EngineSessionCoordinator.cause(for:)` event→cause mapping — the
///     security-critical decision — is asserted exhaustively, so relabelling a
///     `.scanFailed`/`.genericFatal` as clean fails a test (the invariant that
///     guards any future reconsideration of stop-in-place);
///   - `.scanFailed` / `.genericFatal` source events → restart-required from ANY
///     interrupt stage, never `.stopped`;
///   - `.init2Completed` → safe wind-down, applied exactly once.
/// Callers pass a typed source EVENT, never a verdict, so a caller cannot select
/// "safe". It also proves the honest Return-to-Profiles abandon path retains the
/// scan lease: a second profile stays queued and archive maintenance stays
/// forbidden until the abandoned scan's own terminal and a successful close.
@MainActor
final class EngineScanInterruptTerminalCauseTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect
    private typealias SID = EngineSessionCoordinator.SessionID
    private typealias OID = EngineSessionCoordinator.OperationID
    private typealias Ident = EngineSessionCoordinator.TransportIdentity

    private let idA = Ident(pid: 4242, startSec: 100, startUsec: 200)

    /// Fresh coordinator driven to `.scanning(s, scanOp)` over a live REMOTE
    /// connection; returns (coordinator, session, scanOp).
    private func scanning() -> (C, SID, OID) {
        let c = C()
        var s: SID?, connectOp: OID?
        for e in c.requestOpen(profile: "p") {
            if case .beginConnect(let ss, let oo, _) = e { s = ss; connectOp = oo }
        }
        var scanOp: OID?
        for e in c.connectFinished(s!, connectOp!, result: .remote(interactive: false)) {
            if case .beginScan(let ss, let oo) = e { XCTAssertEqual(ss, s!); scanOp = oo }
        }
        return (c, s!, scanOp!)
    }

    private func isRestart(_ es: [Effect]) -> Bool {
        es.contains { if case .restartRequired = $0 { return true }; return false }
    }
    private func assertNotStopped(_ c: C, _ where_: String) {
        if case .stopped = c.phase { XCTFail("must never reach .stopped (\(where_)), got \(c.phase)") }
    }

    // MARK: - (0) the event→cause mapping (the security-critical decision)

    /// Locks the classification the callbacks depend on. If a future edit maps a
    /// failure/fatal event to `.cleanCompletion`, this fails — which is the whole
    /// point: the AppDelegate callbacks pass a source event and the coordinator,
    /// not the caller, decides safe vs unsafe here.
    func test_causeForEvent_mapping_isExhaustiveAndFailClosed() {
        // init2-complete is the ONLY clean terminal.
        XCTAssertEqual(C.cause(for: .init2Completed), .cleanCompletion)
        // A failure or an unauthenticated fatal is unsafe (payload string is
        // incidental — the variant is what matters).
        for event: C.InterruptTerminalEvent in [.scanFailed, .genericFatal] {
            guard case .unsafe = C.cause(for: event) else {
                return XCTFail("\(event) must map to .unsafe, got \(C.cause(for: event))")
            }
        }
    }

    /// End-to-end of the mapping through the reducer: the same source events the
    /// AppDelegate callbacks pass drive the coordinator to the right outcome, so
    /// the test bites on the event, not a hand-picked cause.
    func test_eventDrivesOutcome_failuresRestart_cleanAdvances() {
        // .scanFailed → restart.
        do {
            let (c, s, op) = scanning()
            _ = c.requestScanInterruption(s, destination: .stopInPlace)
            _ = c.transportSignalCompleted(s, op, .signalled(idA))
            _ = c.interruptTerminalObserved(s, op, event: .scanFailed)
            XCTAssertTrue(c.isRestartRequired); assertNotStopped(c, "event=.scanFailed")
        }
        // .genericFatal → restart.
        do {
            let (c, s, op) = scanning()
            _ = c.requestScanInterruption(s, destination: .stopInPlace)
            _ = c.interruptTerminalObserved(s, op, event: .genericFatal)
            XCTAssertTrue(c.isRestartRequired); assertNotStopped(c, "event=.genericFatal")
        }
        // .init2Completed → advances (no restart).
        do {
            let (c, s, op) = scanning()
            _ = c.requestScanInterruption(s, destination: .stopInPlace)
            _ = c.transportSignalCompleted(s, op, .signalled(idA))
            let e = c.interruptTerminalObserved(s, op, event: .init2Completed)
            XCTAssertFalse(c.isRestartRequired)
            XCTAssertTrue(e.contains { if case .pollReap = $0 { return true }; return false })
        }
    }

    // MARK: - (1) scanFailed racing the interruption cannot reach .stopped

    func test_scanFailedDuringInterruption_restartRequired_neverStopped() {
        let (c, s, op) = scanning()
        _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA))      // → awaitingTerminal(idA)
        let e = c.interruptTerminalObserved(s, op, event: .scanFailed)
        XCTAssertTrue(c.isRestartRequired, "a scanFailed terminal is not provably safe")
        XCTAssertTrue(isRestart(e))
        assertNotStopped(c, "scanFailed")
    }

    // MARK: - (2) a generic fatal pending BEFORE the signal result cannot reach .stopped

    func test_fatalBeforeSignalResult_restartRequired_fromSignallingStage() {
        let (c, s, op) = scanning()
        _ = c.requestScanInterruption(s, destination: .stopInPlace)  // stage .signalling(false)
        // The fatal arrives before the synchronous signal result — the earliest
        // stage. Fail-closed must fire here too (from ANY stage).
        let e = c.interruptTerminalObserved(s, op, event: .genericFatal)
        XCTAssertTrue(c.isRestartRequired)
        XCTAssertTrue(isRestart(e))
        assertNotStopped(c, "fatal@signalling")
    }

    // MARK: - (3) a fatal AFTER the signal, without an authenticated cause, cannot reach .stopped

    func test_fatalAfterSignal_withoutAuthenticatedCause_restartRequired() {
        let (c, s, op) = scanning()
        _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA))      // → awaitingTerminal(idA)
        // Even though the SIGKILL was issued and the child was signalled, the
        // fatal that follows is NOT authenticated as the kill's own EOF — a
        // "SIGKILL was issued" assumption is exactly what must not license reuse.
        let e = c.interruptTerminalObserved(s, op, event: .genericFatal)
        XCTAssertTrue(c.isRestartRequired)
        XCTAssertTrue(isRestart(e))
        assertNotStopped(c, "fatal@awaitingTerminal")
    }

    // Belt-and-suspenders: an unsafe terminal arriving even at the LATE
    // awaitingReap stage (after a prior clean terminal was recorded) still fails
    // closed — the cause check precedes any stage handling.
    func test_unsafeTerminal_atAwaitingReap_restartRequired() {
        let (c, s, op) = scanning()
        _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA))
        _ = c.interruptTerminalObserved(s, op, event: .init2Completed)  // → awaitingReap(idA)
        guard case .interruptingScan(_, _, .awaitingReap, _) = c.phase else {
            return XCTFail("precondition awaitingReap, got \(c.phase)")
        }
        _ = c.interruptTerminalObserved(s, op, event: .genericFatal)
        XCTAssertTrue(c.isRestartRequired)
        assertNotStopped(c, "unsafe@awaitingReap")
    }

    // MARK: - (4) a clean completion racing a user action is safe and applied exactly once

    func test_cleanCompletion_safe_andExactlyOnce() {
        let (c, s, op) = scanning()
        _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA))      // → awaitingTerminal(idA)
        // First clean terminal advances the cycle (→ awaitingReap, poll effect).
        let e1 = c.interruptTerminalObserved(s, op, event: .init2Completed)
        XCTAssertTrue(e1.contains { if case .pollReap = $0 { return true }; return false })
        guard case .interruptingScan(_, _, .awaitingReap, _) = c.phase else {
            return XCTFail("expected awaitingReap after clean terminal, got \(c.phase)")
        }
        // A duplicate/stale clean terminal (the race with a user action / retry) is
        // inert — exactly-once, no double transition.
        let e2 = c.interruptTerminalObserved(s, op, event: .init2Completed)
        XCTAssertTrue(e2.isEmpty, "second terminal must be inert (exactly-once)")
        // A genuinely clean terminal is safe to wind down to a reusable .stopped.
        _ = c.interruptReapClassified(s, op, .absent)
        guard case .interruptingScan(_, _, .closing(let closeOp), _) = c.phase else {
            return XCTFail("expected closing, got \(c.phase)")
        }
        _ = c.closeCompleted(s, closeOp, status: 0)
        XCTAssertEqual(c.phase, .stopped(s))
        XCTAssertFalse(c.isRestartRequired)
    }

    // MARK: - (6) Return to Profiles: a second profile stays queued until the
    //            abandoned scan's own terminal AND a successful close

    func test_returnToProfiles_secondProfileQueuedUntilAbandonedScanTerminalAndClose() {
        let (c, s, op) = scanning()
        // Return to Profiles on a (non-interruptible, production) scan → abandon
        // presentation, RETAIN the scan lease. Phase stays `.scanning`.
        _ = c.abandon(reason: "Return to Profiles")
        guard case .scanning(s, op) = c.phase else {
            return XCTFail("abandon must retain the scan lease in .scanning, got \(c.phase)")
        }
        // Pick a second profile: it QUEUES, it does not start anything.
        let eq = c.requestOpen(profile: "q2")
        XCTAssertTrue(eq.contains { if case .showWaiting(_, "q2") = $0 { return true }; return false },
                      "second profile must show a waiting window")
        XCTAssertFalse(eq.contains { if case .beginConnect = $0 { return true }; return false },
                       "second profile must not start while the abandoned scan owns the engine")
        XCTAssertFalse(eq.contains { if case .showSession(_, "q2") = $0 { return true }; return false })
        guard case .scanning(s, op) = c.phase else { return XCTFail("still the abandoned scan") }

        // The abandoned scan finally terminates → deferred close begins; the
        // queued open still has NOT started (connection is being torn down).
        let eDone = c.scanCompleted(s, op)
        var closeOp: OID?
        for e in eDone { if case .closeConnection(s, let o) = e { closeOp = o } }
        XCTAssertNotNil(closeOp, "abandoned scan terminal must begin the deferred close")
        XCTAssertFalse(eDone.contains { if case .showSession(_, "q2") = $0 { return true }; return false },
                       "queued open must not start until the close succeeds")

        // Only after a SUCCESSFUL close does the queued profile start.
        let eClosed = c.closeCompleted(s, closeOp!, status: 0)
        XCTAssertTrue(eClosed.contains { if case .showSession(_, "q2") = $0 { return true }; return false },
                      "queued profile starts only after abandoned-scan terminal + successful close")
    }

    // A close FAILURE after the abandoned scan terminal must not start the queued
    // open — it enters restart-required (engine unsafe), never a surprise open.
    func test_returnToProfiles_closeFailure_doesNotStartQueued_restartRequired() {
        let (c, s, op) = scanning()
        _ = c.abandon(reason: "Return to Profiles")
        _ = c.requestOpen(profile: "q2")
        let eDone = c.scanCompleted(s, op)
        var closeOp: OID?
        for e in eDone { if case .closeConnection(s, let o) = e { closeOp = o } }
        let e = c.closeCompleted(s, closeOp!, status: 7)
        XCTAssertTrue(c.isRestartRequired)
        XCTAssertFalse(e.contains { if case .showSession(_, "q2") = $0 { return true }; return false })
    }

    // MARK: - (7) archive maintenance is forbidden while an abandoned scan owns the engine

    func test_archiveMaintenanceForbidden_whileAbandonedScanOwnsEngine() {
        let (c, s, op) = scanning()
        _ = c.abandon(reason: "Return to Profiles")
        guard case .scanning(s, op) = c.phase else { return XCTFail() }
        XCTAssertFalse(c.allowsDestructiveArchiveMutation,
                       "an abandoned-but-live scan still reads/writes archives → maintenance forbidden")
        XCTAssertFalse(c.isIdle)
        // Only once the scan terminal + close complete (→ .idle) is it allowed.
        let eDone = c.scanCompleted(s, op)
        var closeOp: OID?
        for e in eDone { if case .closeConnection(s, let o) = e { closeOp = o } }
        _ = c.closeCompleted(s, closeOp!, status: 0)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertTrue(c.allowsDestructiveArchiveMutation)
    }
}
