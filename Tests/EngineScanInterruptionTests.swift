import XCTest
@testable import unison_ui_mac

/// Phase 1a (issue #24): deterministic coordinator coverage for the first-class
/// `.interruptingScan` / `.stopped` states — the production authority that
/// replaces the Phase 0 Debug spike driver. Pure reducer tests: no AppKit, no
/// bridge, no timing. This is the "complete deterministic race suite" the
/// reviewer requires for the Foundation PR.
@MainActor
final class EngineScanInterruptionTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect
    private typealias SID = EngineSessionCoordinator.SessionID
    private typealias OID = EngineSessionCoordinator.OperationID
    private typealias Dest = EngineSessionCoordinator.Destination
    private typealias Ident = EngineSessionCoordinator.TransportIdentity

    private let idA = Ident(pid: 4242, startSec: 100, startUsec: 200)

    /// Drive a fresh coordinator to `.scanning(s, scanOp)` over a live remote
    /// connection; return (coordinator, session, scanOp).
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

    private func has(_ es: [Effect], _ want: Effect) -> Bool { es.contains(want) }

    // MARK: - Request

    func test_request_fromScanning_entersSignalling_withEffects() {
        let (c, s, op) = scanning()
        let e = c.requestScanInterruption(s, destination: .stopInPlace)
        XCTAssertEqual(c.phase, .interruptingScan(s, op, .signalling(terminalObserved: false), .stopInPlace))
        XCTAssertTrue(has(e, .disarmScanStall(s, op)))
        XCTAssertTrue(has(e, .cancelSessionAuxWork(s)))
        XCTAssertTrue(has(e, .signalTransportChild(s, op)))
    }

    func test_request_fromNonScanning_isNoOp() {
        let c = C()
        XCTAssertTrue(c.requestScanInterruption(SID(raw: 9), destination: .stopInPlace).isEmpty)
        XCTAssertEqual(c.phase, .idle)
    }

    // Condition 3: a `.localOnly` scan has no transport child; interruption must
    // be refused at the authority (else `signal` → NO_CHILD → spurious restart).
    func test_request_fromLocalScanning_isNoOp_staysScanning() {
        let c = C()
        var s: SID?, connectOp: OID?
        for e in c.requestOpen(profile: "p") {
            if case .beginConnect(let ss, let oo, _) = e { s = ss; connectOp = oo }
        }
        _ = c.connectFinished(s!, connectOp!, result: .local)   // → .scanning over .localOnly
        let e = c.requestScanInterruption(s!, destination: .stopInPlace)
        XCTAssertTrue(e.isEmpty, "local scan interruption must be a no-op")
        guard case .scanning(s!, _) = c.phase else {
            return XCTFail("must stay scanning, got \(c.phase)")
        }
    }

    // MARK: - Blocker 1: a profile picked mid-scan folds into the destination

    /// A `requestOpen` during `.scanning` sets `queued` (default branch). A
    /// subsequent Stop must NOT strand it: a pending open outranks stopInPlace,
    /// so the interruption destination becomes `openQueued`, never `.stopped`.
    func test_request_foldsPreexistingQueued_overStopInPlace() {
        let (c, s, op) = scanning()
        var reqId: C.OpenRequestID?
        for e in c.requestOpen(profile: "q") { if case .showWaiting(let id, "q") = e { reqId = id } }
        XCTAssertNotNil(reqId, "mid-scan open should have queued a waiting request")
        _ = c.requestScanInterruption(s, destination: .stopInPlace)
        guard case .interruptingScan(s, op, .signalling(terminalObserved: false),
                                     .openQueued(reqId!, let p)) = c.phase else {
            return XCTFail("queued must fold into openQueued, got \(c.phase)")
        }
        XCTAssertEqual(p, "q")
    }

    /// A pending open also outranks returnToPicker.
    func test_request_foldsPreexistingQueued_overReturnToPicker() {
        let (c, s, _) = scanning()
        var reqId: C.OpenRequestID?
        for e in c.requestOpen(profile: "q") { if case .showWaiting(let id, _) = e { reqId = id } }
        _ = c.requestScanInterruption(s, destination: .returnToPicker)
        guard case .interruptingScan(_, _, _, .openQueued(reqId!, _)) = c.phase else {
            return XCTFail("queued must outrank returnToPicker, got \(c.phase)")
        }
    }

    /// End-to-end proof that the folded queued open cannot detonate later: with a
    /// queued open the cycle routes to the fresh session, never to `.stopped`
    /// (which is what would strand/detonate the pending open).
    func test_foldedQueued_routesToFreshSession_notStopped() {
        let (c, s, op) = scanning()
        for e in c.requestOpen(profile: "q") { _ = e }
        _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA)); _ = c.interruptTerminalObserved(s, op)
        _ = c.interruptReapClassified(s, op, .absent)
        guard case .interruptingScan(_, _, .closing(let closeOp), .openQueued) = c.phase else {
            return XCTFail("expected closing→openQueued, got \(c.phase)")
        }
        let e = c.closeCompleted(s, closeOp, status: 0)
        XCTAssertTrue(has(e, .closeWindow(s)))
        XCTAssertTrue(e.contains { if case .showSession(_, "q") = $0 { return true }; return false })
        if case .stopped = c.phase { XCTFail("must not land in .stopped with a pending open") }
    }

    // MARK: - Signal result table (conservative)

    func test_signalled_noTerminalYet_awaitsTerminal() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        let e = c.transportSignalCompleted(s, op, .signalled(idA))
        XCTAssertEqual(c.phase, .interruptingScan(s, op, .awaitingTerminal(idA), .stopInPlace))
        XCTAssertTrue(e.isEmpty)
    }

    func test_terminalBeforeSignalResult_thenSignalled_awaitsReap() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        XCTAssertTrue(c.interruptTerminalObserved(s, op).isEmpty)     // remembered
        XCTAssertEqual(c.phase, .interruptingScan(s, op, .signalling(terminalObserved: true), .stopInPlace))
        let e = c.transportSignalCompleted(s, op, .signalled(idA))
        XCTAssertEqual(c.phase, .interruptingScan(s, op, .awaitingReap(idA), .stopInPlace))
        XCTAssertTrue(has(e, .pollReap(s, op, idA)))
    }

    func test_signalled_thenTerminal_awaitsReap() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA))       // → awaitingTerminal
        let e = c.interruptTerminalObserved(s, op)
        XCTAssertEqual(c.phase, .interruptingScan(s, op, .awaitingReap(idA), .stopInPlace))
        XCTAssertTrue(has(e, .pollReap(s, op, idA)))
    }

    func test_alreadyDeadWithIdentity_behavesLikeSignalled() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .alreadyDeadWithIdentity(idA))
        XCTAssertEqual(c.phase, .interruptingScan(s, op, .awaitingTerminal(idA), .stopInPlace))
    }

    func test_noChild_restartRequired_evenIfTerminalRaced() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.interruptTerminalObserved(s, op)                       // terminal seen
        let e = c.transportSignalCompleted(s, op, .noChild)
        XCTAssertTrue(c.isRestartRequired)
        XCTAssertTrue(e.contains { if case .restartRequired = $0 { return true }; return false })
    }

    func test_refusals_restartRequired() {
        for r: EngineSessionCoordinator.SignalResult in
            [.alreadyDeadNoIdentity, .multipleChildren, .signalFailed, .unprovableIdentity] {
            let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
            _ = c.transportSignalCompleted(s, op, r)
            XCTAssertTrue(c.isRestartRequired, "\(r) must be restart-required")
        }
    }

    // MARK: - Reap

    func test_reap_absentOrReused_closes() {
        for reap: EngineSessionCoordinator.ReapState in [.absent, .reused] {
            let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
            _ = c.transportSignalCompleted(s, op, .signalled(idA)); _ = c.interruptTerminalObserved(s, op)
            let e = c.interruptReapClassified(s, op, reap)
            guard case .interruptingScan(s, op, .closing(let closeOp), .stopInPlace) = c.phase else {
                return XCTFail("expected closing, got \(c.phase)")
            }
            XCTAssertTrue(has(e, .closeConnection(s, closeOp)))
        }
    }

    func test_reap_ambiguous_restartRequired() {
        for reap: EngineSessionCoordinator.ReapState in [.zombie, .live, .unknown] {
            let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
            _ = c.transportSignalCompleted(s, op, .signalled(idA)); _ = c.interruptTerminalObserved(s, op)
            _ = c.interruptReapClassified(s, op, reap)
            XCTAssertTrue(c.isRestartRequired, "\(reap) must be restart-required")
        }
    }

    // MARK: - Close → destination routing

    /// Drive to `.interruptingScan(.closing(closeOp))` for a destination.
    private func closing(_ dest: Dest) -> (C, SID, OID, OID) {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: dest)
        _ = c.transportSignalCompleted(s, op, .signalled(idA)); _ = c.interruptTerminalObserved(s, op)
        _ = c.interruptReapClassified(s, op, .absent)
        guard case .interruptingScan(_, _, .closing(let closeOp), _) = c.phase else {
            fatalError("not closing")
        }
        return (c, s, op, closeOp)
    }

    func test_close_stopInPlace_reachesStopped() {
        let (c, s, _, closeOp) = closing(.stopInPlace)
        let e = c.closeCompleted(s, closeOp, status: 0)
        XCTAssertEqual(c.phase, .stopped(s))
        XCTAssertTrue(has(e, .presentStopped(s)))
        XCTAssertFalse(e.contains { if case .closeWindow = $0 { return true }; return false })
    }

    func test_close_returnToPicker_idlesAndShowsPicker() {
        let (c, s, _, closeOp) = closing(.returnToPicker)
        let e = c.closeCompleted(s, closeOp, status: 0)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertTrue(has(e, .closeWindow(s)))
        XCTAssertTrue(has(e, .showPicker))
    }

    func test_close_openQueued_closesWindowThenOpensNewSession() {
        let reqId = C.OpenRequestID(raw: 77)
        let (c, s, _, closeOp) = closing(.openQueued(reqId, profile: "q"))
        let e = c.closeCompleted(s, closeOp, status: 0)
        XCTAssertTrue(has(e, .closeWindow(s)))
        var newSession: SID?
        for x in e { if case .showSession(let ss, let p) = x { newSession = ss; XCTAssertEqual(p, "q") } }
        XCTAssertNotNil(newSession)
        XCTAssertNotEqual(newSession, s)                 // fresh session for the queued profile
        if case .opening(newSession!, _) = c.phase {} else { XCTFail("expected opening, got \(c.phase)") }
    }

    /// The driver executes effects in order, and the design mandates the
    /// interrupted window is disposed BEFORE the queued session is shown.
    func test_close_openQueued_closeWindowPrecedesShowSession() {
        let (c, s, _, closeOp) = closing(.openQueued(C.OpenRequestID(raw: 77), profile: "q"))
        let e = c.closeCompleted(s, closeOp, status: 0)
        let closeIdx = e.firstIndex { if case .closeWindow = $0 { return true }; return false }
        let showIdx = e.firstIndex { if case .showSession = $0 { return true }; return false }
        XCTAssertNotNil(closeIdx); XCTAssertNotNil(showIdx)
        XCTAssertLessThan(closeIdx!, showIdx!, "closeWindow must precede showSession")
    }

    func test_close_nonZero_restartRequired() {
        let (c, s, _, closeOp) = closing(.stopInPlace)
        _ = c.closeCompleted(s, closeOp, status: 5)
        XCTAssertTrue(c.isRestartRequired)
    }

    // MARK: - .stopped spec

    func test_stopped_rescan_reusesSessionAndWindow() {
        let (c, s, _, closeOp) = closing(.stopInPlace)
        _ = c.closeCompleted(s, closeOp, status: 0)          // → .stopped(s)
        let e = c.requestRescan()
        // Same session; only a connect op; NO showSession (window reused).
        guard case .opening(s, _) = c.phase else { return XCTFail("expected opening(\(s)), got \(c.phase)") }
        XCTAssertTrue(e.contains { if case .beginConnect(s, _, _) = $0 { return true }; return false })
        XCTAssertFalse(e.contains { if case .showSession = $0 { return true }; return false })
    }

    func test_stopped_allowsDestructiveArchiveMutation() {
        let (c, s, _, closeOp) = closing(.stopInPlace)
        _ = c.closeCompleted(s, closeOp, status: 0)
        XCTAssertTrue(c.allowsDestructiveArchiveMutation)    // quiescent, no connection
        XCTAssertFalse(c.isIdle)                             // but a window is present
        XCTAssertEqual(c.currentSession, s)
    }

    func test_stopped_openOther_closesWindowAndOpensFresh() {
        let (c, s, _, closeOp) = closing(.stopInPlace)
        _ = c.closeCompleted(s, closeOp, status: 0)
        let e = c.requestOpen(profile: "other")
        XCTAssertTrue(has(e, .closeWindow(s)))
        XCTAssertTrue(e.contains { if case .showSession(_, "other") = $0 { return true }; return false })
    }

    func test_interruptingScan_forbidsDestructiveArchiveMutation() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = op
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)
    }

    // MARK: - Monotonic destination

    func test_destination_upgradeNotDowngrade() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.updateInterruptDestination(s, .returnToPicker)   // upgrade 0→1
        guard case .interruptingScan(_, _, _, .returnToPicker) = c.phase else { return XCTFail() }
        _ = c.updateInterruptDestination(s, .stopInPlace)      // downgrade refused
        guard case .interruptingScan(_, _, _, .returnToPicker) = c.phase else { return XCTFail("downgraded!") }
        _ = op
    }

    func test_windowDismissalDuringStopInPlace_upgradesToPicker() {
        let (c, s, _) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.abandon(reason: "window closed")                // generic leave during interrupt
        guard case .interruptingScan(_, _, _, .returnToPicker) = c.phase else {
            return XCTFail("abandon should upgrade to returnToPicker, got \(c.phase)")
        }
    }

    func test_cancelQueuedOpen_duringInterrupt_downgradesToPicker() {
        let reqId = C.OpenRequestID(raw: 5)
        let (c, s, _) = scanning()
        _ = c.requestScanInterruption(s, destination: .openQueued(reqId, profile: "q"))
        _ = c.cancelQueuedOpen(reqId)
        guard case .interruptingScan(_, _, _, .returnToPicker) = c.phase else {
            return XCTFail("cancel should downgrade to returnToPicker, got \(c.phase)")
        }
    }

    func test_cancelQueuedOpen_staleId_ignored() {
        let reqId = C.OpenRequestID(raw: 5)
        let (c, s, _) = scanning()
        _ = c.requestScanInterruption(s, destination: .openQueued(reqId, profile: "q"))
        _ = c.cancelQueuedOpen(C.OpenRequestID(raw: 999))     // stale
        guard case .interruptingScan(_, _, _, .openQueued(reqId, _)) = c.phase else {
            return XCTFail("stale cancel must be ignored, got \(c.phase)")
        }
    }

    // MARK: - Deadline exact-stage binding

    func test_deadline_matchingStage_restartRequired() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA))   // .awaitingTerminal(idA)
        _ = c.interruptDeadlineElapsed(s, op, .awaitingTerminal(idA))
        XCTAssertTrue(c.isRestartRequired)
    }

    func test_deadline_staleStage_isNoOp() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA))   // now awaitingTerminal
        // A stale timer for the earlier signalling stage must not fire.
        _ = c.interruptDeadlineElapsed(s, op, .signalling(terminalObserved: false))
        XCTAssertFalse(c.isRestartRequired)
        guard case .interruptingScan(_, _, .awaitingTerminal, _) = c.phase else { return XCTFail() }
    }

    /// Blocker 2: the signalling deadline is armed at `.signalling(false)`. An
    /// early worker terminal flips the flag to `.signalling(true)` in place
    /// (no re-arm). The still-pending deadline must STILL bound the stage — else
    /// a never-arriving signal result would hang the cycle forever.
    func test_deadline_signallingClass_firesAfterEarlyTerminalFlip() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.interruptTerminalObserved(s, op)                   // flag flips false→true
        guard case .interruptingScan(_, _, .signalling(terminalObserved: true), _) = c.phase else {
            return XCTFail("expected signalling(true) after early terminal, got \(c.phase)")
        }
        _ = c.interruptDeadlineElapsed(s, op, .signalling(terminalObserved: false))  // armed value
        XCTAssertTrue(c.isRestartRequired, "signalling deadline must still fire after the flag flip")
    }

    /// Once we progress OUT of signalling, the old signalling deadline no-ops
    /// (the class match only covers signalling↔signalling, not signalling→later).
    func test_deadline_signallingClass_doesNotFireOnceAwaitingReap() {
        let (c, s, op) = scanning(); _ = c.requestScanInterruption(s, destination: .stopInPlace)
        _ = c.transportSignalCompleted(s, op, .signalled(idA)); _ = c.interruptTerminalObserved(s, op)
        guard case .interruptingScan(_, _, .awaitingReap, _) = c.phase else { return XCTFail() }
        _ = c.interruptDeadlineElapsed(s, op, .signalling(terminalObserved: false))
        XCTAssertFalse(c.isRestartRequired, "signalling deadline must not fire in awaitingReap")
    }

    // MARK: - Stale terminal after destination reached

    func test_staleTerminalAfterStopped_isNoOp() {
        let (c, s, op) = closingClosed(.stopInPlace)             // now .stopped
        _ = c.interruptTerminalObserved(s, op)                  // stale
        XCTAssertEqual(c.phase, .stopped(s))
    }

    private func closingClosed(_ dest: Dest) -> (C, SID, OID) {
        let (c, s, op, closeOp) = closing(dest)
        _ = c.closeCompleted(s, closeOp, status: 0)
        return (c, s, op)
    }

    // MARK: - §12 race matrix (deterministic proof layer)

    /// Scan completes just before the interruption request: the request from
    /// `.ready` is a clean no-op (never enters `.interruptingScan`).
    func test_scanCompletesJustBeforeRequest_interruptionIsNoOp() {
        let (c, s, op) = scanning()
        _ = c.scanCompleted(s, op)                       // → .ready(s)
        guard case .ready(s) = c.phase else { return XCTFail("precondition .ready") }
        let e = c.requestScanInterruption(s, destination: .stopInPlace)
        XCTAssertTrue(e.isEmpty, "interruption after scan completion must be a no-op")
        guard case .ready(s) = c.phase else { return XCTFail("must stay ready, got \(c.phase)") }
    }

    /// A second interruption request (double Stop) is a no-op — the first cycle
    /// owns the op and is left untouched.
    func test_doubleInterruptionRequest_secondIsNoOp() {
        let (c, s, op) = scanning()
        XCTAssertFalse(c.requestScanInterruption(s, destination: .stopInPlace).isEmpty)
        let e2 = c.requestScanInterruption(s, destination: .stopInPlace)
        XCTAssertTrue(e2.isEmpty, "second interruption request must be a no-op")
        guard case .interruptingScan(s, op, .signalling(terminalObserved: false), .stopInPlace) = c.phase
        else { return XCTFail("cycle must be unaffected, got \(c.phase)") }
    }

    /// The 120s scan-stall detector races through despite disarm and delivers
    /// the exact scan op's failure while interruption owns it. Exactly-one-
    /// terminal-authority (§13): the coordinator ignores it — no restart, cycle
    /// intact.
    func test_concurrentStallDuringInterruption_isNoOp() {
        let (c, s, op) = scanning()
        _ = c.requestScanInterruption(s, destination: .stopInPlace)
        let e = c.operationFailed(s, op, reason: "scan stalled", engineIsQuiescent: false)
        XCTAssertTrue(e.isEmpty, "a stall terminal must not touch an interruption in flight")
        XCTAssertFalse(c.isRestartRequired)
        guard case .interruptingScan(s, op, .signalling(terminalObserved: false), .stopInPlace) = c.phase
        else { return XCTFail("interruption cycle must be intact, got \(c.phase)") }
    }

    /// Every interruption event referencing the (now-consumed) interrupted op is
    /// inert once the cycle has reached a terminal destination — proven for ALL
    /// THREE destinations, not only `.stopped`.
    private func assertStaleInterruptEventsInert(_ c: C, _ s: SID, _ op: OID,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let before = c.phase
        XCTAssertTrue(c.interruptTerminalObserved(s, op).isEmpty, file: file, line: line)
        XCTAssertTrue(c.transportSignalCompleted(s, op, .signalled(idA)).isEmpty, file: file, line: line)
        XCTAssertTrue(c.interruptReapClassified(s, op, .absent).isEmpty, file: file, line: line)
        XCTAssertTrue(c.interruptDeadlineElapsed(s, op, .signalling(terminalObserved: false)).isEmpty,
                      file: file, line: line)
        XCTAssertTrue(c.interruptDeadlineElapsed(s, op, .awaitingReap(idA)).isEmpty, file: file, line: line)
        XCTAssertEqual(c.phase, before, "stale interruption events must not change phase",
                       file: file, line: line)
        XCTAssertFalse(c.isRestartRequired, "stale interruption events must not restart",
                       file: file, line: line)
    }

    func test_staleInterruptEvents_afterStopInPlace_areInert() {
        let (c, s, op) = closingClosed(.stopInPlace)         // → .stopped(s)
        guard case .stopped = c.phase else { return XCTFail() }
        assertStaleInterruptEventsInert(c, s, op)
    }

    func test_staleInterruptEvents_afterReturnToPicker_areInert() {
        let (c, s, op, closeOp) = closing(.returnToPicker)
        _ = c.closeCompleted(s, closeOp, status: 0)          // → .idle
        XCTAssertEqual(c.phase, .idle)
        assertStaleInterruptEventsInert(c, s, op)
    }

    func test_staleInterruptEvents_afterOpenQueued_areInert() {
        let (c, s, op, closeOp) = closing(.openQueued(C.OpenRequestID(raw: 77), profile: "q"))
        _ = c.closeCompleted(s, closeOp, status: 0)          // → .opening(newSession)
        guard case .opening = c.phase else { return XCTFail("expected opening, got \(c.phase)") }
        // Old (s, op) are the interrupted identifiers — every stale interrupt
        // event referencing them must be inert against the fresh session.
        assertStaleInterruptEventsInert(c, s, op)
    }

    /// A stale cancellation of the queued open arriving AFTER teardown already
    /// consumed it must not disturb the fresh session.
    func test_staleCancelQueuedOpen_afterOpenQueuedTeardown_isNoOp() {
        let reqId = C.OpenRequestID(raw: 77)
        let (c, s, _, closeOp) = closing(.openQueued(reqId, profile: "q"))
        _ = c.closeCompleted(s, closeOp, status: 0)          // → .opening(newSession)
        let before = c.phase
        let e = c.cancelQueuedOpen(reqId)                    // stale: already consumed
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(c.phase, before, "stale cancel must not touch the fresh session")
    }
}
