import XCTest
@testable import unison_ui_mac

/// Deterministic lifecycle tests for the engine coordinator, asserting the
/// effects each transition returns — no AppKit, no bridge, no timing.
/// Covers the modeled happy paths plus the invalid/failure/stale/duplicate
/// transitions the contract must reject (issue #6, steps 4–5 review round 2).
@MainActor
final class EngineSessionCoordinatorTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    // MARK: effect extractors

    private func beginConnect(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginConnect(s, op, _) = x { return (s, op) } }; return nil
    }
    private func beginScan(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginScan(s, op) = x { return (s, op) } }; return nil
    }
    private func beginSync(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginSync(s, op) = x { return (s, op) } }; return nil
    }
    private func closeOp(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .closeConnection(s, op) = x { return (s, op) } }; return nil
    }
    private func waitingID(_ e: [Effect]) -> C.OpenRequestID? {
        for x in e { if case let .showWaiting(id, _) = x { return id } }; return nil
    }
    private func hasRestart(_ e: [Effect]) -> Bool {
        e.contains { if case .restartRequired = $0 { return true }; return false }
    }

    /// Open a profile through to `.ready`. Returns (session, scanOp).
    @discardableResult
    private func openToReady(_ c: C, profile: String = "A",
                             interactive: Bool = false) -> (C.SessionID, C.OperationID) {
        let (s, connectOp) = beginConnect(c.requestOpen(profile: profile))!
        let e1 = c.connectFinished(s, connectOp, connection: .open(interactive: interactive))
        let (_, scanOp) = beginScan(e1)!
        _ = c.scanCompleted(s, scanOp)
        return (s, scanOp)
    }

    // MARK: - Happy paths

    func test_open_emitsShowSessionThenConnect() {
        let c = C()
        let e = c.requestOpen(profile: "A")
        XCTAssertEqual(e.count, 2)
        if case .showSession = e[0] {} else { XCTFail("first effect should be showSession") }
        if case .beginConnect = e[1] {} else { XCTFail("second effect should be beginConnect") }
    }

    func test_connectFinished_authorizesScan() {
        let c = C()
        let (s, op) = beginConnect(c.requestOpen(profile: "A"))!
        let e = c.connectFinished(s, op, connection: .open(interactive: false))
        XCTAssertNotNil(beginScan(e))          // scan explicitly authorized via effect
    }

    func test_requestSync_authorizesSync() {
        let c = C()
        let (s, _) = openToReady(c)
        let e = c.requestSync()
        let sync = beginSync(e)
        XCTAssertNotNil(sync)
        XCTAssertEqual(sync?.0, s)
    }

    // MARK: - Abandonment (the core race)

    func test_abandonedScan_gatesQueuedOpen_untilScanAndCloseComplete() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, connection: .open(interactive: false)))!.1
        XCTAssertEqual(c.abandon(reason: "left"), [])          // deferred, no effect
        XCTAssertNotNil(waitingID(c.requestOpen(profile: "B")))  // queued
        // Abandoned scan finally completes → close first, B still not started.
        let closed = closeOp(c.scanCompleted(s, scanOp))
        XCTAssertNotNil(closed)
        // Close done → idle → B starts.
        let e = c.closeCompleted(closed!.0, closed!.1, status: 0)
        XCTAssertNotNil(beginConnect(e))
    }

    func test_abandonedScan_neverCompletes_neverStartsQueued() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        _ = c.connectFinished(s, connectOp, connection: .open(interactive: false))
        _ = c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")
        XCTAssertFalse(c.isIdle)                                 // stays busy; B never races
    }

    func test_cancelQueuedOpen_preventsHiddenStart() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, connection: .open(interactive: false)))!.1
        _ = c.abandon(reason: "left")
        let reqID = waitingID(c.requestOpen(profile: "B"))!
        _ = c.cancelQueuedOpen(reqID)                           // user closed the waiting window
        let closed = closeOp(c.scanCompleted(s, scanOp))!
        let e = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertEqual(e, [])                                    // B NOT started
        XCTAssertTrue(c.isIdle)
    }

    // MARK: - 2b auth-cost policy

    func test_nonInteractive_closesOnSyncEnd_backToReady() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let e = c.syncCompleted(s, syncOp)
        XCTAssertTrue(e.contains(.presentSyncResults(s)))
        let closed = closeOp(e)!
        XCTAssertEqual(c.closeCompleted(closed.0, closed.1, status: 0), [])
        XCTAssertEqual(c.phase, .ready(s))                      // window stays
        XCTAssertEqual(c.connection, .none)
    }

    func test_interactive_holdsThroughSyncEnd_closesOnLeave() {
        let c = C()
        let (s, _) = openToReady(c, interactive: true)
        let syncOp = beginSync(c.requestSync())!.1
        XCTAssertEqual(c.syncCompleted(s, syncOp), [.presentSyncResults(s)])  // held
        let closed = closeOp(c.abandon(reason: "leave"))!
        _ = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertTrue(c.isIdle)
    }

    // MARK: - Rescan

    func test_rescan_reusesLiveConnection() {
        let c = C()
        let (s, _) = openToReady(c)
        let e = c.requestRescan()
        XCTAssertEqual(beginScan(e)?.0, s)                      // reuse (beginScan), same session
        XCTAssertNil(beginConnect(e))
    }

    func test_rescan_reopensAfterNonInteractiveClose() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp))!
        _ = c.closeCompleted(closed.0, closed.1, status: 0)     // connection none, ready
        let e = c.requestRescan()
        XCTAssertEqual(beginConnect(e)?.0, s)                   // reopen, SAME session
        XCTAssertNil(beginScan(e))
    }

    // MARK: - Stale / duplicate callbacks (findings 1 & 2)

    func test_staleSuccessfulClose_ignored() {
        let c = C()
        let (s, _) = openToReady(c)                             // ready(s), open
        let bogusOp = C.OperationID(raw: 999)
        XCTAssertEqual(c.closeCompleted(s, bogusOp, status: 0), [])  // not .closing → ignored
        XCTAssertEqual(c.phase, .ready(s))
        XCTAssertEqual(c.connection, .open(interactive: false))
    }

    func test_staleFailedClose_ignored() {
        let c = C()
        let (s, _) = openToReady(c)
        let bogusOp = C.OperationID(raw: 999)
        XCTAssertEqual(c.closeCompleted(s, bogusOp, status: 2), [])  // no spurious restart
        XCTAssertEqual(c.phase, .ready(s))
    }

    func test_duplicateScanCompleted_duringSync_ignored() {
        let c = C()
        let (s, scanOp) = openToReady(c)
        let syncOp = beginSync(c.requestSync())!.1               // syncing(s, syncOp)
        XCTAssertEqual(c.scanCompleted(s, scanOp), [])           // stale scan op → no-op
        XCTAssertEqual(c.phase, .syncing(s, syncOp))             // NOT reverted to ready
    }

    func test_duplicateSyncCompleted_whileReady_ignored() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        _ = c.syncCompleted(s, syncOp)                           // → ready (+ close)
        XCTAssertEqual(c.syncCompleted(s, syncOp), [])           // duplicate → no second close
    }

    func test_lateConnectFinished_whileNotOpening_ignored() {
        let c = C()
        let (s, _) = openToReady(c)                             // ready
        XCTAssertEqual(c.connectFinished(s, C.OperationID(raw: 999),
                                         connection: .open(interactive: true)), [])
        XCTAssertEqual(c.connection, .open(interactive: false)) // not overwritten
    }

    // MARK: - Failure terminals (finding 5)

    func test_scanFailure_quiescent_closesAndIdles() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, connection: .open(interactive: false)))!.1
        let closed = closeOp(c.operationFailed(s, scanOp, reason: "scan failed", engineIsQuiescent: true))
        XCTAssertNotNil(closed)
        _ = c.closeCompleted(closed!.0, closed!.1, status: 0)
        XCTAssertTrue(c.isIdle)
    }

    func test_syncFailure_notQuiescent_requiresRestart() {
        let c = C()
        let (s, _) = openToReady(c)
        let syncOp = beginSync(c.requestSync())!.1
        let e = c.operationFailed(s, syncOp, reason: "lost connection", engineIsQuiescent: false)
        XCTAssertTrue(hasRestart(e))
        XCTAssertNil(beginConnect(c.requestOpen(profile: "B")))  // refused after restart
    }

    func test_failureAfterAbandon_stillReleasesLease() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, connection: .open(interactive: false)))!.1
        _ = c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")                          // queued
        let closed = closeOp(c.operationFailed(s, scanOp, reason: "scan failed", engineIsQuiescent: true))!
        let e = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertNotNil(beginConnect(e))                         // B starts after release
    }

    // MARK: - Sync-end close failure surfaces immediately (finding 8)

    func test_nonInteractiveSyncEndCloseFailure_requiresRestartImmediately() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp))!       // close started while window "ready"
        let e = c.closeCompleted(closed.0, closed.1, status: 2) // close FAILS
        XCTAssertTrue(hasRestart(e))                            // immediate, not deferred to next action
    }

    // MARK: - Restart is terminal for new work

    func test_restartRequired_refusesNewOpens() {
        let c = C()
        let (s, _) = openToReady(c)
        let syncOp = beginSync(c.requestSync())!.1
        _ = c.operationFailed(s, syncOp, reason: "wedged", engineIsQuiescent: false)
        XCTAssertTrue(hasRestart(c.requestOpen(profile: "X")))
    }
}
