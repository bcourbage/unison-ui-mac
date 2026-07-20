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
    private func showSession(_ e: [Effect]) -> C.SessionID? {
        for x in e { if case let .showSession(s, _) = x { return s } }; return nil
    }
    private func hasRestart(_ e: [Effect]) -> Bool {
        e.contains { if case .restartRequired = $0 { return true }; return false }
    }

    /// Open a profile through to `.ready`. Returns (session, scanOp).
    @discardableResult
    private func openToReady(_ c: C, profile: String = "A",
                             interactive: Bool = false) -> (C.SessionID, C.OperationID) {
        let (s, connectOp) = beginConnect(c.requestOpen(profile: profile))!
        let e1 = c.connectFinished(s, connectOp, result: .remote(interactive: interactive))
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
        let e = c.connectFinished(s, op, result: .remote(interactive: false))
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
        let scanOp = beginScan(c.connectFinished(s, connectOp, result: .remote(interactive: false)))!.1
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
        _ = c.connectFinished(s, connectOp, result: .remote(interactive: false))
        _ = c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")
        XCTAssertFalse(c.isIdle)                                 // stays busy; B never races
    }

    func test_cancelQueuedOpen_preventsHiddenStart() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, result: .remote(interactive: false)))!.1
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
        let e = c.syncCompleted(s, syncOp, results: .available([]))
        XCTAssertTrue(e.contains(.presentSyncResults(s, [])))
        let closed = closeOp(e)!
        XCTAssertEqual(c.closeCompleted(closed.0, closed.1, status: 0), [])
        XCTAssertEqual(c.phase, .ready(s))                      // window stays
        XCTAssertEqual(c.connection, .disconnected)            // remote closed on sync-end
    }

    // MARK: - Finding #10: available / unavailable sync results

    func test_syncAvailable_carriesSnapshot() {
        let c = C()
        let (s, _) = openToReady(c, interactive: true)
        let syncOp = beginSync(c.requestSync())!.1
        let snap = [SyncSnapshotRow(progress: "done", details: "d", bytesTransferred: 1)]
        XCTAssertEqual(c.syncCompleted(s, syncOp, results: .available(snap)),
                       [.presentSyncResults(s, snap)])
        XCTAssertEqual(c.phase, .ready(s))
    }

    func test_syncUnavailable_presentsUnavailable_notRestartRequired() {
        let c = C()
        let (s, _) = openToReady(c, interactive: true)
        let syncOp = beginSync(c.requestSync())!.1
        let e = c.syncCompleted(s, syncOp, results: .unavailable(reason: "marshalling failed"))
        XCTAssertEqual(e, [.presentSyncUnavailable(s, reason: "marshalling failed")])
        XCTAssertEqual(c.phase, .ready(s), "engine is quiescent — ready, not restart")
        XCTAssertFalse(e.contains { if case .restartRequired = $0 { return true } else { return false } },
                       "read-only results failure must NOT force a restart")
    }

    func test_syncUnavailable_nonInteractive_followsClosePolicy() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let e = c.syncCompleted(s, syncOp, results: .unavailable(reason: "x"))
        XCTAssertTrue(e.contains(.presentSyncUnavailable(s, reason: "x")))
        XCTAssertNotNil(closeOp(e), "same non-interactive close policy as available")
    }

    func test_syncUnavailable_abandoned_closesNoPresent() {
        let c = C()
        let (s, _) = openToReady(c, interactive: true)
        let syncOp = beginSync(c.requestSync())!.1
        _ = c.abandon(reason: "left")
        let e = c.syncCompleted(s, syncOp, results: .unavailable(reason: "x"))
        XCTAssertNotNil(closeOp(e), "abandoned → close")
        XCTAssertFalse(e.contains { if case .presentSyncUnavailable = $0 { return true } else { return false } })
    }

    func test_syncResults_duplicateRejected() {
        let c = C()
        let (s, _) = openToReady(c, interactive: true)
        let syncOp = beginSync(c.requestSync())!.1
        _ = c.syncCompleted(s, syncOp, results: .available([]))     // → ready
        // A duplicate / stale / wrong-operation completion no longer matches
        // .syncing(s,op) and is dropped (lease already released).
        XCTAssertEqual(c.syncCompleted(s, syncOp, results: .available([])), [])
        XCTAssertEqual(c.syncCompleted(s, syncOp, results: .unavailable(reason: "y")), [])
    }

    func test_syncCompleted_wrongOperationID_rejected_leaveRealOpPending() {
        let c = C()
        let (s, _) = openToReady(c, interactive: true)
        let syncOp = beginSync(c.requestSync())!.1           // the real sync op is pending
        // A completion carrying a DIFFERENT operation id than the pending sync
        // matches no `.syncing(s, op)` phase and is dropped.
        let wrongOp = C.OperationID(raw: 999_999)
        XCTAssertEqual(c.syncCompleted(s, wrongOp, results: .available([])), [])
        // The real op's phase/lease is untouched — still syncing, not released.
        XCTAssertEqual(c.phase, .syncing(s, syncOp))
        // ...and the genuine completion still lands normally afterward.
        XCTAssertEqual(c.syncCompleted(s, syncOp, results: .available([])),
                       [.presentSyncResults(s, [])])
        XCTAssertEqual(c.phase, .ready(s))
    }

    func test_interactive_holdsThroughSyncEnd_closesOnLeave() {
        let c = C()
        let (s, _) = openToReady(c, interactive: true)
        let syncOp = beginSync(c.requestSync())!.1
        XCTAssertEqual(c.syncCompleted(s, syncOp, results: .available([])), [.presentSyncResults(s, [])])  // held
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
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!
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
        _ = c.syncCompleted(s, syncOp, results: .available([]))                           // → ready (+ close)
        XCTAssertEqual(c.syncCompleted(s, syncOp, results: .available([])), [])           // duplicate → no second close
    }

    func test_lateConnectFinished_whileNotOpening_ignored() {
        let c = C()
        let (s, _) = openToReady(c)                             // ready
        XCTAssertEqual(c.connectFinished(s, C.OperationID(raw: 999),
                                         result: .remote(interactive: true)), [])
        XCTAssertEqual(c.connection, .open(interactive: false)) // not overwritten
    }

    // MARK: - Failure terminals (finding 5)

    func test_scanFailure_quiescent_closesAndIdles() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, result: .remote(interactive: false)))!.1
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

    func test_engineBecameUncertain_fromReady_requiresRestart() {
        // Blocker 4: a per-row mutation that failed after mutating engine state
        // (reported while the session sits in .ready) must move the coordinator
        // to restart-required and refuse further engine work.
        let c = C()
        _ = openToReady(c)
        let e = c.engineBecameUncertain(reason: "ignore failed after mutating engine state")
        XCTAssertTrue(hasRestart(e))
        XCTAssertNil(beginConnect(c.requestOpen(profile: "B")))  // refused after restart
    }

    func test_engineBecameUncertain_ignoredWhenNotReady() {
        // A stale mutation result arriving while a scan/sync is in flight (not
        // .ready) must be a no-op — it must not clobber an active phase.
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, result: .remote(interactive: false)))!.1
        let e = c.engineBecameUncertain(reason: "stale")
        XCTAssertFalse(hasRestart(e))
        XCTAssertEqual(c.phase, .scanning(s, scanOp))   // unchanged
    }

    func test_failureAfterAbandon_stillReleasesLease() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, connectOp, result: .remote(interactive: false)))!.1
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
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!       // close started while window "ready"
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

    // MARK: - Abandonment during a sync-end close (review round 3 blocker)

    func test_leaveWhileSyncEndCloseInFlight_finishesToIdle() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!   // .closing(.backToReady) in flight
        _ = c.abandon(reason: "closed window during sync-end close")
        let e = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertEqual(e, [])
        XCTAssertTrue(c.isIdle)                             // idles, not stranded ownerless .ready
    }

    /// A queued open starts as a DISTINCT fresh session, carrying its own
    /// `.showSession` — never the abandoned session's id. This is the
    /// coordinator-side guarantee the driver relies on to build a fresh,
    /// fully-wired reconcile window instead of promoting the inert "waiting"
    /// controller (the promotion bug fixed in driveShowSession). Covers the
    /// leave-remote-then-pick-another race and the remote fatal-recovery reopen.
    func test_queuedOpen_startsAsDistinctFreshSession() {
        let c = C()
        let (a, _) = openToReady(c, interactive: true)          // A: open, connection held
        let closed = closeOp(c.abandon(reason: "leave"))!       // leaving A begins the close
        XCTAssertNotNil(waitingID(c.requestOpen(profile: "B"))) // B queued behind the close
        let e = c.closeCompleted(closed.0, closed.1, status: 0) // close done → B starts
        let started = showSession(e)
        XCTAssertNotNil(started)                                // B gets its own showSession…
        XCTAssertNotEqual(started, a)                           // …with a NEW session id, not A's
        XCTAssertEqual(beginConnect(e)?.0, started)             // and its connect is bound to it
    }

    func test_openRequestedDuringSyncEndClose_startsAfterClose() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!   // .closing(.backToReady)
        XCTAssertNotNil(waitingID(c.requestOpen(profile: "B")))   // queued + outcome upgraded
        let e = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertNotNil(beginConnect(e))                    // B starts after the close idles
    }

    // MARK: - Coordinator-authorized sync exit (review round 3 authority gap)

    func test_syncExit_stopAndKeepWindow_abortsAndKeepsSession() {
        let c = C()
        let (s, _) = openToReady(c)
        let syncOp = beginSync(c.requestSync())!.1
        XCTAssertEqual(c.requestSyncExit(.stopAndKeepWindow), [.abortSync(s, syncOp)])
        XCTAssertEqual(c.phase, .syncing(s, syncOp))        // still syncing until completion
        XCTAssertTrue(c.syncCompleted(s, syncOp, results: .available([])).contains(.presentSyncResults(s, [])))  // window kept
    }

    func test_syncExit_abortAndClose_abortsAndClosesAfterCompletion() {
        let c = C()
        let (s, _) = openToReady(c)
        let syncOp = beginSync(c.requestSync())!.1
        XCTAssertEqual(c.requestSyncExit(.abortAndClose), [.abortSync(s, syncOp)])
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!   // abandoned → close, no present
        _ = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertTrue(c.isIdle)
    }

    func test_syncExit_closeAndLetRun_noAbort_closesAfterCompletion() {
        let c = C()
        let (s, _) = openToReady(c)
        let syncOp = beginSync(c.requestSync())!.1
        XCTAssertEqual(c.requestSyncExit(.closeAndLetRun), [])   // no abort effect
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!       // abandoned → close after done
        _ = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertTrue(c.isIdle)
    }

    // MARK: - Local profile has no connection to close

    func test_local_neverClosesConnection() {
        let c = C()
        let (s, op) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, op, result: .local))!.1
        XCTAssertEqual(c.connection, .localOnly)
        _ = c.scanCompleted(s, scanOp)
        let syncOp = beginSync(c.requestSync())!.1
        XCTAssertEqual(c.syncCompleted(s, syncOp, results: .available([])), [.presentSyncResults(s, [])])  // no close for local
        XCTAssertEqual(c.abandon(reason: "leave"), [])          // none → straight idle
        XCTAssertTrue(c.isIdle)
    }

    // MARK: - Rescan requested during a sync-end close (finding 4)

    /// A Rescan clicked while a non-interactive sync-end close is still in
    /// flight must be deferred, not discarded, and start the reconnect the
    /// instant the close completes successfully.
    func test_rescanDuringBackToReadyClose_reconnectsAfterSuccessfulClose() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)         // non-interactive
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!       // phase = .closing(.backToReady)
        // Rescan while the close is in flight: deferred (no effect now), NOT discarded.
        XCTAssertEqual(c.requestRescan(), [])
        // Close returns 0 → the deferred rescan reconnects the same session now.
        let e = c.closeCompleted(closed.0, closed.1, status: 0)
        let recon = beginConnect(e)
        XCTAssertNotNil(recon, "deferred rescan must reconnect after the close")
        XCTAssertEqual(recon?.0, s)
        if case .opening(s, _) = c.phase {} else { XCTFail("must be reconnecting (.opening)") }
    }

    /// A close FAILURE while a rescan is queued still transitions to
    /// restartRequired (the queued rescan is dropped).
    func test_rescanDuringBackToReadyClose_closeFailureStillRestarts() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!
        XCTAssertEqual(c.requestRescan(), [])                   // deferred
        let e = c.closeCompleted(closed.0, closed.1, status: 2) // close fails
        XCTAssertTrue(hasRestart(e))
        if case .restartRequired = c.phase {} else { XCTFail("close failure must restart") }
    }

    // MARK: - Connection contract: no sync over a closed remote (finding 5)

    /// After a non-interactive sync-end close the remote connection is
    /// `.disconnected`; Go must NOT authorize a sync over it.
    func test_sync_refusedWhenRemoteDisconnected() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!
        XCTAssertEqual(c.closeCompleted(closed.0, closed.1, status: 0), [])
        XCTAssertEqual(c.phase, .ready(s))
        XCTAssertEqual(c.connection, .disconnected)
        XCTAssertEqual(c.requestSync(), [], "no sync may be authorized over a closed connection")
        if case .ready(s) = c.phase {} else { XCTFail("phase must stay .ready") }
    }

    /// Sync IS allowed over a live remote (`.open`) and a local session
    /// (`.localOnly`).
    func test_sync_allowedWhenOpenOrLocal() {
        let c1 = C(); _ = openToReady(c1, interactive: true)
        XCTAssertNotNil(beginSync(c1.requestSync()), "open remote can sync")

        let c2 = C()
        let (s2, op2) = beginConnect(c2.requestOpen(profile: "L"))!
        let scanOp = beginScan(c2.connectFinished(s2, op2, result: .local))!.1
        _ = c2.scanCompleted(s2, scanOp)
        XCTAssertNotNil(beginSync(c2.requestSync()), "local session can sync")
    }

    /// Rescan over a `.disconnected` remote reconnects (beginConnect), never a
    /// bare beginScan over a dead connection.
    func test_rescan_reconnectsWhenRemoteDisconnected() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!
        _ = c.closeCompleted(closed.0, closed.1, status: 0)     // .ready + .disconnected
        let e = c.requestRescan()
        XCTAssertNotNil(beginConnect(e), "rescan over a disconnected remote must reconnect")
        XCTAssertNil(beginScan(e))
    }

    /// Local Rescan is a direct scan (init2) — it must NOT rerun init1/connect.
    func test_localRescan_directScan_noInit1Rerun() {
        let c = C()
        let (s, op) = beginConnect(c.requestOpen(profile: "L"))!
        let scanOp = beginScan(c.connectFinished(s, op, result: .local))!.1
        _ = c.scanCompleted(s, scanOp)                          // .ready + .localOnly
        let e = c.requestRescan()
        XCTAssertNotNil(beginScan(e), "local rescan must be a direct scan")
        XCTAssertNil(beginConnect(e), "local rescan must NOT rerun init1/connect")
        if case .scanning(s, _) = c.phase {} else { XCTFail("phase must be .scanning") }
    }

    /// Orphan-connection cleanup after a watchdog-invalidated connect is
    /// authorized ONLY in `restartRequired`, not in ordinary idle or a live
    /// session — even though idle also has `currentSession == nil` (the reason
    /// the guard uses `isRestartRequired`, not that proxy).
    func test_orphanCleanupAuthorization_restartRequiredOnly() {
        let c = C()
        // idle: currentSession == nil BUT not restartRequired → NOT authorized
        XCTAssertNil(c.currentSession)
        XCTAssertFalse(c.isRestartRequired)

        // live .ready session: currentSession != nil, not restartRequired
        let (s, op) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, op, result: .remote(interactive: false)))!.1
        _ = c.scanCompleted(s, scanOp)
        XCTAssertNotNil(c.currentSession)
        XCTAssertFalse(c.isRestartRequired)

        // a non-quiescent failure of an in-flight op (watchdog-style) → restartRequired
        let syncOp = beginSync(c.requestSync())!.1
        XCTAssertTrue(hasRestart(c.operationFailed(s, syncOp, reason: "watchdog",
                                                   engineIsQuiescent: false)))
        XCTAssertTrue(c.isRestartRequired, "cleanup authorized in restartRequired")
        XCTAssertNil(c.currentSession, "restartRequired also has currentSession==nil — isRestartRequired disambiguates it from idle")
    }

    // MARK: - Callback-identity invariant: stale / duplicate terminal events (finding 5)

    /// A duplicate delivery of the SAME connect op must not re-transition.
    func test_duplicateConnectFinished_isNoOp() {
        let c = C()
        let (s, op) = beginConnect(c.requestOpen(profile: "A"))!
        _ = c.connectFinished(s, op, result: .remote(interactive: false))   // → .scanning
        XCTAssertEqual(c.connectFinished(s, op, result: .remote(interactive: false)), [])
    }

    /// A completion carrying a stale/wrong op token is a no-op; the real op
    /// still completes.
    func test_staleScanCompleted_wrongOp_isNoOp() {
        let c = C()
        let (s, op) = beginConnect(c.requestOpen(profile: "A"))!
        let scanOp = beginScan(c.connectFinished(s, op, result: .remote(interactive: false)))!.1
        let bogus = C.OperationID(raw: 999_999)
        XCTAssertEqual(c.scanCompleted(s, bogus), [])          // wrong op → dropped
        XCTAssertEqual(c.scanCompleted(s, scanOp), [.presentScanResults(s)])  // real op wins
    }

    /// A stale close completion (wrong op) must not touch the current
    /// connection.
    func test_staleCloseCompleted_wrongOp_isNoOp() {
        let c = C()
        let (s, _) = openToReady(c, interactive: false)
        let syncOp = beginSync(c.requestSync())!.1
        let closed = closeOp(c.syncCompleted(s, syncOp, results: .available([])))!
        let bogus = C.OperationID(raw: 888_888)
        XCTAssertEqual(c.closeCompleted(s, bogus, status: 0), [])   // wrong op → dropped
        // the real close still completes
        XCTAssertEqual(c.closeCompleted(closed.0, closed.1, status: 0), [])
        XCTAssertEqual(c.phase, .ready(s))
    }

    // MARK: - Destructive archive-mutation policy (PR #7 review finding 1)
    //
    // `allowsDestructiveArchiveMutation` is the single coordinator-owned
    // authority for Clean Stale Archives / Reset Archives / delete-with-
    // archives. It must be true in exactly `.idle` and false in every other
    // phase — a background scan/sync can still be reading archive files, a
    // close is still tearing down, and `.restartRequired` is an uncertain
    // runtime state a restart must clear first.

    func test_archivePolicy_idle_allows() {
        let c = C()
        XCTAssertTrue(c.isIdle)
        XCTAssertTrue(c.allowsDestructiveArchiveMutation)
    }

    func test_archivePolicy_opening_forbids() {
        let c = C()
        _ = c.requestOpen(profile: "A")                         // .opening
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)
    }

    func test_archivePolicy_scanning_forbids() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        _ = c.connectFinished(s, connectOp, result: .remote(interactive: false)) // .scanning
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)
    }

    func test_archivePolicy_ready_forbids() {
        let c = C()
        openToReady(c)                                          // .ready
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)
    }

    func test_archivePolicy_syncing_forbids() {
        let c = C()
        openToReady(c)
        _ = beginSync(c.requestSync())!                         // .syncing
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)
    }

    func test_archivePolicy_closing_forbids_thenIdleAllows() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let e1 = c.connectFinished(s, connectOp, result: .remote(interactive: false))
        let (_, scanOp) = beginScan(e1)!
        // A quiescent scan failure closes the connection → .closing.
        let closed = closeOp(c.operationFailed(s, scanOp, reason: "x",
                                               engineIsQuiescent: true))!
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)      // .closing forbids
        _ = c.closeCompleted(closed.0, closed.1, status: 0)
        XCTAssertTrue(c.isIdle)
        XCTAssertTrue(c.allowsDestructiveArchiveMutation)       // back to allowed
    }

    func test_archivePolicy_restartRequired_forbids() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "A"))!
        let e1 = c.connectFinished(s, connectOp, result: .remote(interactive: false))
        let (_, scanOp) = beginScan(e1)!
        // A non-quiescent failure can't prove the runtime unwound → restart.
        _ = c.operationFailed(s, scanOp, reason: "wedged", engineIsQuiescent: false)
        XCTAssertTrue(c.isRestartRequired)
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)
    }

    /// The confirmation-sheet TOCTOU case: the policy says yes when the sheet
    /// opens (idle), a background operation starts before the user confirms,
    /// and the recheck at mutation time must now refuse. This is why the final
    /// handler rechecks the live policy rather than trusting a snapshot.
    func test_archivePolicy_TOCTOU_busyBeforeConfirm_refuses() {
        let c = C()
        let snapshotAtSheetOpen = c.allowsDestructiveArchiveMutation
        XCTAssertTrue(snapshotAtSheetOpen)                      // idle when sheet opened
        _ = c.requestOpen(profile: "A")                        // engine becomes busy
        XCTAssertFalse(c.allowsDestructiveArchiveMutation)      // live recheck refuses
    }

    /// The app-side gate helper fails safe: no provider (no authority to
    /// confirm idle) → refuse; a busy provider → refuse; an idle provider →
    /// allow. Mirrors what every final destructive handler evaluates.
    func test_archiveMutationGate_providerContract() {
        final class Stub: EngineActivityProviding {
            var allowsDestructiveArchiveMutation: Bool
            init(_ v: Bool) { allowsDestructiveArchiveMutation = v }
        }
        XCTAssertFalse(ArchiveMutationGate.isAllowed(nil))
        XCTAssertFalse(ArchiveMutationGate.isAllowed(Stub(false)))
        XCTAssertTrue(ArchiveMutationGate.isAllowed(Stub(true)))
    }

    // MARK: - Clean Stale snapshot invalidation (PR #7 review round 2, finding 1)

    /// The exact scenario: scan while idle → engine activity occurs → return
    /// idle → the pre-operation snapshot cannot be trashed until re-scanned.
    func test_staleSnapshotGuard_activityInvalidatesPreOpSnapshot() {
        var g = StaleSnapshotGuard()
        g.didScan(engineIdle: true)                     // scanned while idle
        XCTAssertTrue(g.mayTrash(engineIdle: true))     // trustworthy
        XCTAssertFalse(g.shouldReload(engineIdle: true))
        g.observedActivity(engineIdle: false)           // engine became busy
        XCTAssertFalse(g.mayTrash(engineIdle: true))    // old snapshot NOT trashable, even back at idle
        XCTAssertTrue(g.shouldReload(engineIdle: true)) // must re-scan first
        g.didScan(engineIdle: true)                     // re-scan at idle
        XCTAssertTrue(g.mayTrash(engineIdle: true))     // fresh snapshot trustworthy again
        XCTAssertFalse(g.shouldReload(engineIdle: true))
    }

    /// A snapshot scanned while the engine is busy is immediately untrusted.
    func test_staleSnapshotGuard_scanDuringBusyIsImmediatelyDirty() {
        var g = StaleSnapshotGuard()
        g.didScan(engineIdle: false)                    // opened/scanned while busy
        XCTAssertFalse(g.mayTrash(engineIdle: true))    // not trustworthy even once idle
        XCTAssertTrue(g.shouldReload(engineIdle: true)) // reload when idle returns
    }

    // MARK: - Every mutation notifies (PR #7 review round 2, finding 2)

    /// An abandoned local-only scan transitions straight to idle returning NO
    /// effects. That path runs through `runScanEffects`, so it must still fire
    /// the engine-activity notification (the driver now routes the empty
    /// remainder through `run`), else maintenance windows never re-enable.
    func test_abandonedLocalOnlyScan_reachesIdle_withNoEffects() {
        let c = C()
        let (s, connectOp) = beginConnect(c.requestOpen(profile: "L"))!
        let scanE = c.connectFinished(s, connectOp, result: .local)   // localOnly → .scanning
        let (_, scanOp) = beginScan(scanE)!
        _ = c.abandon(reason: "window closed")                        // abandoned mid-scan
        let eff = c.scanCompleted(s, scanOp)
        XCTAssertTrue(eff.isEmpty)                       // no effects — notification must not depend on them
        XCTAssertTrue(c.isIdle)
        XCTAssertTrue(c.allowsDestructiveArchiveMutation)
    }
}
