import XCTest
@testable import unison_ui_mac

/// Session-scoped CLI options at the coordinator layer (the production reducer,
/// not a model of it): overrides travel with the open, a queued request applies
/// nothing while a session is active and then only its own args, and a reconnect
/// re-applies the same args.
@MainActor
final class SessionArgsCoordinatorTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    /// Full `.beginConnect` payload, including the session's args.
    private func connect(_ e: [Effect]) -> (C.SessionID, C.OperationID, String, [String])? {
        for x in e { if case let .beginConnect(s, op, p, a) = x { return (s, op, p, a) } }
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

    func test_open_carriesItsOwnArgs_pickerCarriesEmpty() {
        let c = C()
        let a = connect(c.requestOpen(profile: "A", args: ["-path", "Documents"]))
        XCTAssertEqual(a?.2, "A")
        XCTAssertEqual(a?.3, ["-path", "Documents"],
                       "a CLI open hands its overrides to the driver on the first connect")
        let d = C()
        let o = connect(d.requestOpen(profile: "P"))
        XCTAssertEqual(o?.3, [], "a picker selection carries no overrides")
    }

    func test_queuedRequest_appliesNothingWhileActive_thenOnlyItsOwnArgs() {
        let c = C()
        let a = connect(c.requestOpen(profile: "A", args: ["-path", "Documents"]))!
        XCTAssertEqual(a.3, ["-path", "Documents"])
        let e1 = c.connectFinished(a.0, a.1, result: .remote(interactive: false))
        let aScan = scanOp(e1)!

        let bWhileScanning = c.requestOpen(profile: "B", args: ["-path", "Other"])
        XCTAssertTrue(hasWaiting(bWhileScanning), "B queues behind active A")
        XCTAssertNil(connect(bWhileScanning), "no connect for B while A is scanning")

        let ready = c.scanCompleted(a.0, aScan)
        XCTAssertNil(connect(ready), "no connect for B while A sits ready")

        let closing = c.abandon(reason: "user left A")
        let aClose = closeOp(closing)!
        XCTAssertNil(connect(closing), "B does not start until A's close completes")
        let bStart = c.closeCompleted(a.0, aClose, status: 0)
        let b = connect(bStart)
        XCTAssertEqual(b?.2, "B")
        XCTAssertEqual(b?.3, ["-path", "Other"],
                       "B opens with only its own overrides, none inherited from A")
        XCTAssertNotEqual(b?.0, a.0, "B is a new session")
    }

    func test_reconnectAfterSyncEndClose_reappliesSameArgs_noAccumulation() {
        let c = C()
        let a = connect(c.requestOpen(profile: "A", args: ["-path", "Documents"]))!
        let e1 = c.connectFinished(a.0, a.1, result: .remote(interactive: false))
        _ = c.scanCompleted(a.0, scanOp(e1)!)                 // ready, connection open

        let sync = c.requestSync()
        let syncO = { () -> C.OperationID in
            for x in sync { if case let .beginSync(_, op) = x { return op } }
            fatalError("no beginSync")
        }()
        let ended = c.syncCompleted(a.0, syncO, results: .available([]))
        let close = closeOp(ended)!
        _ = c.closeCompleted(a.0, close, status: 0)          // now .ready + .disconnected

        let rescan = c.requestRescan()
        let re = connect(rescan)
        XCTAssertEqual(re?.0, a.0, "same session across the reconnect")
        XCTAssertEqual(re?.2, "A")
        XCTAssertEqual(re?.3, ["-path", "Documents"],
                       "reconnect re-applies exactly the session's own overrides")
    }
}

/// The driver's apply-or-fail decision (the exact function `driveBeginConnect`
/// calls). Every session carries an explicit vector, so the setter is ALWAYS
/// called (even empty); a failed setter must STOP the open before init1 (P1).
final class SessionArgsApplyTests: XCTestCase {

    func test_emptyArgs_callsSetterWithEmpty_proceeds() {
        var calls: [[String]] = []
        let d = SessionArgsApply.decide([], setter: { calls.append($0); return UNISON_BRIDGE_OK })
        XCTAssertEqual(d, .proceed)
        XCTAssertEqual(calls, [[]], "an unscoped session still sets (suppresses any inherited scope)")
    }

    func test_vector_callsSetterWithVector_proceeds() {
        var calls: [[String]] = []
        let d = SessionArgsApply.decide(["-path", "X"], setter: { calls.append($0); return UNISON_BRIDGE_OK })
        XCTAssertEqual(d, .proceed)
        XCTAssertEqual(calls, [["-path", "X"]])
    }

    func test_setterFailure_stopsTheOpen() {
        var called = false
        let d = SessionArgsApply.decide([], setter: { _ in called = true; return UNISON_BRIDGE_ERR_MISSING })
        XCTAssertTrue(called)
        XCTAssertEqual(d, .fail(status: UNISON_BRIDGE_ERR_MISSING),
                       "a failed setter must stop the open (no init1 with a stale/omitted scope)")
    }

    func test_vector_setterFailure_stopsTheOpen() {
        let d = SessionArgsApply.decide(["-path", "X"], setter: { _ in UNISON_BRIDGE_ERR_EXN })
        XCTAssertEqual(d, .fail(status: UNISON_BRIDGE_ERR_EXN))
    }
}
