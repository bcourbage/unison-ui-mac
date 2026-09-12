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

    // MARK: - Overrides travel with the open

    func test_open_carriesItsOwnArgs_pickerCarriesNone() {
        let c = C()
        let a = connect(c.requestOpen(profile: "A", args: ["-path", "Documents"]))
        XCTAssertEqual(a?.2, "A")
        XCTAssertEqual(a?.3, ["-path", "Documents"],
                       "a CLI open must hand its overrides to the driver on the first connect")

        // A fresh coordinator: an ordinary picker selection supplies no overrides.
        let d = C()
        let o = connect(d.requestOpen(profile: "P"))
        XCTAssertEqual(o?.3, [], "a picker selection carries no overrides")
    }

    // MARK: - A queued request cannot alter an active session

    func test_queuedRequest_appliesNothingWhileActive_thenOnlyItsOwnArgs() {
        let c = C()
        // A opens with its own scope and becomes active (scanning, then ready).
        let a = connect(c.requestOpen(profile: "A", args: ["-path", "Documents"]))!
        XCTAssertEqual(a.3, ["-path", "Documents"])
        let e1 = c.connectFinished(a.0, a.1, result: .remote(interactive: false))
        let aScan = scanOp(e1)!

        // B requested while A is active: it must WAIT and drive no connect. No
        // `.beginConnect(B)` means the driver issues no set_session_args / init1
        // for B — A's engine preferences cannot be touched by B.
        let bWhileScanning = c.requestOpen(profile: "B", args: ["-path", "Other"])
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
        XCTAssertEqual(b?.3, ["-path", "Other"],
                       "B opens with only its own overrides, none inherited from A")
        XCTAssertNotEqual(b?.0, a.0, "B is a new session")
    }

    // MARK: - Reconnect re-applies the same session's overrides

    func test_reconnectAfterSyncEndClose_reappliesSameArgs_noAccumulation() {
        let c = C()
        let a = connect(c.requestOpen(profile: "A", args: ["-path", "Documents"]))!
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
        XCTAssertEqual(re?.3, ["-path", "Documents"],
                       "reconnect re-applies exactly the session's own overrides")
    }
}
