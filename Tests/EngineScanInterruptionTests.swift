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
}
