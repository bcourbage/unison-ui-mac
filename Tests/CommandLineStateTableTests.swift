import XCTest
@testable import unison_ui_mac

/// The running-instance state table at the coordinator layer (#162): a
/// command-line request accepted while the app is busy with leavable work
/// abandons the current view and opens once cleanup finishes, and a pending
/// command-line request is never silently replaced by a picker selection.
@MainActor
final class CommandLineStateTableTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

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
    private func hasPickBlocked(_ e: [Effect]) -> Bool {
        e.contains { if case .pickBlockedByCommandLineRequest = $0 { return true }; return false }
    }

    /// Drive a session to `.scanning` and return its ids.
    private func openAndScan(_ c: C, profile: String, args: [String] = [],
                             connection: C.ConnectResult = .remote(interactive: false))
        -> (session: C.SessionID, scanOp: C.OperationID) {
        let a = connect(c.requestOpen(profile: profile, args: args))!
        let e1 = c.connectFinished(a.0, a.1, result: connection)
        return (a.0, scanOp(e1)!)
    }

    // MARK: accepted-and-waiting (busy, leavable) → opens after cleanup

    func test_admitDuringScanning_acceptsWaiting_thenOpensAfterCleanup() {
        let c = C()
        let a = openAndScan(c, profile: "A", args: ["-path", "Docs"])

        let (started, effects) = c.admitCommandLineOpen(profile: "B", args: ["-path", "Other"])
        XCTAssertFalse(started, "a scan in flight cannot open B synchronously")
        XCTAssertTrue(hasWaiting(effects), "the accepted request shows a waiting window")
        XCTAssertNil(connect(effects), "B does not connect while A is still scanning")
        XCTAssertTrue(c.openRequestPending)
        XCTAssertTrue(c.commandLineRequestPending)

        // A's scan completes; since it was abandoned, its connection closes.
        let closing = c.scanCompleted(a.session, a.scanOp)
        let aClose = closeOp(closing)!
        XCTAssertNil(connect(closing), "B waits for A's close to finish")

        let bStart = c.closeCompleted(a.session, aClose, status: 0)
        let b = connect(bStart)
        XCTAssertEqual(b?.2, "B")
        XCTAssertEqual(b?.3, ["-path", "Other"], "B opens with only its own overrides")
        XCTAssertNotEqual(b?.0, a.session, "B is a new session")
        XCTAssertFalse(c.openRequestPending, "the request was consumed when it opened")
    }

    func test_admitDuringReady_openConnection_acceptsWaiting_thenOpensAfterClose() {
        let c = C()
        let a = openAndScan(c, profile: "A")
        _ = c.scanCompleted(a.session, a.scanOp)     // .ready, connection .open

        let (started, effects) = c.admitCommandLineOpen(profile: "B", args: [])
        XCTAssertFalse(started, "a live remote connection must be closed before B opens")
        XCTAssertTrue(hasWaiting(effects))
        let aClose = closeOp(effects)!               // abandon → beginClose on the ready session
        let bStart = c.closeCompleted(a.session, aClose, status: 0)
        XCTAssertEqual(connect(bStart)?.2, "B")
    }

    func test_admitDuringReady_localOnly_opensImmediately() {
        let c = C()
        let a = openAndScan(c, profile: "A", connection: .local)
        _ = c.scanCompleted(a.session, a.scanOp)     // .ready, connection .localOnly

        let (started, effects) = c.admitCommandLineOpen(profile: "B", args: ["-path", "X"])
        XCTAssertTrue(started, "a local session has no connection to tear down, so B starts now")
        XCTAssertFalse(hasWaiting(effects), "no waiting window when the open starts immediately")
        let b = connect(effects)
        XCTAssertEqual(b?.2, "B")
        XCTAssertEqual(b?.3, ["-path", "X"])
        XCTAssertFalse(c.openRequestPending)
    }

    // MARK: single pending request, and picker must not replace it

    func test_pickerSelection_doesNotReplaceAPendingCommandLineRequest() {
        let c = C()
        let a = openAndScan(c, profile: "A")
        _ = c.admitCommandLineOpen(profile: "B", args: ["-path", "B"])   // CLI request pending
        XCTAssertTrue(c.commandLineRequestPending)

        // A user picks C from the picker while B is waiting: rejected, B preserved.
        let pick = c.requestOpen(profile: "C", args: [])
        XCTAssertTrue(hasPickBlocked(pick), "the picker selection is surfaced as blocked")
        XCTAssertFalse(hasWaiting(pick), "the picker selection does not queue")
        XCTAssertTrue(c.commandLineRequestPending, "the pending command-line request is preserved")

        // Cleanup drains B, not C.
        let closing = c.scanCompleted(a.session, a.scanOp)
        let bStart = c.closeCompleted(a.session, closeOp(closing)!, status: 0)
        XCTAssertEqual(connect(bStart)?.2, "B", "the command-line request opens, not the rejected pick")
    }

    func test_pickerSelection_stillReplacesAnotherPickerSelection() {
        let c = C()
        let a = openAndScan(c, profile: "A")
        _ = c.requestOpen(profile: "B")     // picker-origin queued
        XCTAssertTrue(c.openRequestPending)
        XCTAssertFalse(c.commandLineRequestPending)

        let pick = c.requestOpen(profile: "C")   // last pick wins among picker requests
        XCTAssertTrue(hasWaiting(pick))
        XCTAssertFalse(hasPickBlocked(pick))

        let closing = c.scanCompleted(a.session, a.scanOp)
        // A ready session is abandoned by the queued pick's arrival? No: the picker
        // queue drains on finishToIdle. Abandon A to reach idle and drain.
        let aClose = closeOp(c.abandon(reason: "leave A"))
        if let aClose {
            let start = c.closeCompleted(a.session, aClose, status: 0)
            XCTAssertEqual(connect(start)?.2, "C", "the later picker selection wins")
        } else {
            XCTFail("expected a close for the abandoned ready session")
        }
    }
}
