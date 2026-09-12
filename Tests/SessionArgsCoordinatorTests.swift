import XCTest
@testable import unison_ui_mac

/// Session-scoped CLI options at the coordinator layer (the production reducer,
/// not a model of it). These prove the control-flow guarantees the engine
/// integration rests on:
///  - a session's own overrides travel with its `.beginConnect` (the only effect
///    that drives `unison_bridge_set_session_args` + `init1`);
///  - an ordinary picker selection carries none;
///  - a request that must wait STORES its overrides and produces NO
///    `.beginConnect` — hence no preference-touching bridge call — until the
///    active session's operation AND its cleanup have finished;
///  - a reconnect re-applies exactly the SAME session's overrides (so the scope
///    survives a reconnect and does not accumulate or leak).
@MainActor
final class SessionArgsCoordinatorTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    /// Full `.beginConnect` payload, including the session's override source.
    private func connect(_ e: [Effect]) -> (C.SessionID, C.OperationID, String, SessionOverrides)? {
        for x in e { if case let .beginConnect(s, op, p, ov) = x { return (s, op, p, ov) } }
        return nil
    }
    private func scanOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginScan(_, op) = x { return op } }; return nil
    }
    private func closeOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .closeConnection(_, op) = x { return op } }; return nil
    }
    private func hasWaiting(_ e: [Effect]) -> Bool {
        e.contains { if case .showWaiting = $0 { return true }; return false }
    }

    // MARK: - Overrides travel with the open

    func test_open_carriesItsOwnArgs_pickerCarriesExplicitEmpty() {
        let c = C()
        let a = connect(c.requestOpen(profile: "A", overrides: .explicit(["-path", "Documents"])))
        XCTAssertEqual(a?.2, "A")
        XCTAssertEqual(a?.3, .explicit(["-path", "Documents"]),
                       "a CLI open must hand its overrides to the driver on the first connect")

        // A fresh coordinator: an ordinary picker selection is an explicit empty
        // request (which the driver applies as Some [], suppressing inheritance),
        // NOT legacy launch inheritance.
        let d = C()
        let o = connect(d.requestOpen(profile: "P"))
        XCTAssertEqual(o?.3, .explicit([]), "a picker selection is explicitly unscoped")
    }

    // MARK: - A queued request cannot alter an active session

    func test_queuedRequest_appliesNothingWhileActive_thenOnlyItsOwnArgs() {
        let c = C()
        // A opens with its own scope and becomes active (scanning, then ready).
        let a = connect(c.requestOpen(profile: "A", overrides: .explicit(["-path", "Documents"])))!
        XCTAssertEqual(a.3, .explicit(["-path", "Documents"]))
        let e1 = c.connectFinished(a.0, a.1, result: .remote(interactive: false))
        let aScan = scanOp(e1)!

        // B requested while A is active: it must WAIT and drive no connect. No
        // `.beginConnect(B)` means the driver issues no set_session_args / init1
        // for B — A's engine preferences cannot be touched by B.
        let bWhileScanning = c.requestOpen(profile: "B", overrides: .explicit(["-path", "Other"]))
        XCTAssertTrue(hasWaiting(bWhileScanning), "B queues behind active A")
        XCTAssertNil(connect(bWhileScanning), "no connect for B while A is scanning")

        // A finishes scanning → ready. B still must not start (A still owns the
        // engine and its connection is not yet cleaned up).
        let ready = c.scanCompleted(a.0, aScan)
        XCTAssertNil(connect(ready), "no connect for B while A sits ready")

        // A is left (leave → close). Only after the close COMPLETES (cleanup
        // done) does B start — and it carries ONLY its own overrides.
        let closing = c.abandon(reason: "user left A")
        let aClose = closeOp(closing)!
        XCTAssertNil(connect(closing), "B does not start until A's close completes")
        let bStart = c.closeCompleted(a.0, aClose, status: 0)
        let b = connect(bStart)
        XCTAssertEqual(b?.2, "B")
        XCTAssertEqual(b?.3, .explicit(["-path", "Other"]),
                       "B opens with only its own overrides, none inherited from A")
        XCTAssertNotEqual(b?.0, a.0, "B is a new session")
    }

    // MARK: - Reconnect re-applies the same session's overrides

    func test_reconnectAfterSyncEndClose_reappliesSameArgs_noAccumulation() {
        let c = C()
        let a = connect(c.requestOpen(profile: "A", overrides: .explicit(["-path", "Documents"])))!
        let e1 = c.connectFinished(a.0, a.1, result: .remote(interactive: false))
        _ = c.scanCompleted(a.0, scanOp(e1)!)                 // ready, connection open

        // A non-interactive sync ends: the coordinator presents results and
        // begins a back-to-ready close (the connection is torn down).
        let sync = c.requestSync()
        let syncO = { () -> C.OperationID in
            for x in sync { if case let .beginSync(_, op) = x { return op } }
            fatalError("no beginSync")
        }()
        let ended = c.syncCompleted(a.0, syncO, results: .available([]))
        let close = closeOp(ended)!
        _ = c.closeCompleted(a.0, close, status: 0)          // now .ready + .disconnected

        // A rescan must reconnect (init1 again) and re-apply THIS session's own
        // overrides — the same vector, so the scope persists across the reconnect
        // and is not appended to or dropped.
        let rescan = c.requestRescan()
        let re = connect(rescan)
        XCTAssertEqual(re?.0, a.0, "same session across the reconnect")
        XCTAssertEqual(re?.2, "A")
        XCTAssertEqual(re?.3, .explicit(["-path", "Documents"]),
                       "reconnect re-applies exactly the session's own overrides")
    }
}

/// The driver's apply-or-fail decision (the exact function `driveBeginConnect`
/// calls). Only `.inheritLaunch` skips the setter; an `.explicit` vector always
/// calls it (even when empty), so an explicitly unscoped session suppresses the
/// process argv rather than inheriting it — the finding this round. A failed
/// setter must STOP the open before init1 (finding P1).
final class SessionArgsApplyTests: XCTestCase {

    func test_inheritLaunch_doesNotCallSetter_proceeds() {
        var calls: [[String]] = []
        let d = SessionArgsApply.decide(.inheritLaunch,
                                        setter: { calls.append($0); return UNISON_BRIDGE_OK })
        XCTAssertEqual(d, .proceed)
        XCTAssertTrue(calls.isEmpty,
                      ".inheritLaunch must leave sessionArgs unset so the engine parses the launch argv")
    }

    func test_explicitEmpty_callsSetterWithEmpty_proceeds() {
        // The crux of the finding: an EXPLICIT empty vector must still call the
        // setter (Some []), so the process argv is suppressed — it must NOT be
        // conflated with legacy inheritance.
        var calls: [[String]] = []
        let d = SessionArgsApply.decide(.explicit([]),
                                        setter: { calls.append($0); return UNISON_BRIDGE_OK })
        XCTAssertEqual(d, .proceed)
        XCTAssertEqual(calls, [[]],
                       "an explicit empty request must set (suppressing any inherited scope)")
    }

    func test_explicitVector_callsSetterWithVector_proceeds() {
        var calls: [[String]] = []
        let d = SessionArgsApply.decide(.explicit(["-path", "X"]),
                                        setter: { calls.append($0); return UNISON_BRIDGE_OK })
        XCTAssertEqual(d, .proceed)
        XCTAssertEqual(calls, [["-path", "X"]])
    }

    func test_explicitEmpty_setterFailure_stopsTheOpen() {
        // A non-OK setter result → .fail, so the driver never reaches init1.
        var called = false
        let d = SessionArgsApply.decide(.explicit([]),
                                        setter: { _ in called = true; return UNISON_BRIDGE_ERR_MISSING })
        XCTAssertTrue(called)
        XCTAssertEqual(d, .fail(status: UNISON_BRIDGE_ERR_MISSING),
                       "a failed setter must stop the open (no init1 with a stale/omitted scope)")
    }

    func test_explicitVector_setterFailure_stopsTheOpen() {
        let d = SessionArgsApply.decide(.explicit(["-path", "X"]),
                                        setter: { _ in UNISON_BRIDGE_ERR_EXN })
        XCTAssertEqual(d, .fail(status: UNISON_BRIDGE_ERR_EXN))
    }

    func test_inheritLaunch_setterNotCalled_soCannotFail() {
        // .inheritLaunch never calls the setter, so a setter that WOULD fail is
        // irrelevant — the open proceeds (legacy parse), no failure surfaced.
        let d = SessionArgsApply.decide(.inheritLaunch, setter: { _ in UNISON_BRIDGE_ERR_MISSING })
        XCTAssertEqual(d, .proceed)
    }
}
