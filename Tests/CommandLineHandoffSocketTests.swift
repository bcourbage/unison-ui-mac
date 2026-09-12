import XCTest
import Darwin
@testable import unison_ui_mac

/// The Unix-domain-socket transport for running-instance routing: a real server
/// and client over a throwaway per-test socket, covering the accept/refuse path
/// and the awkward cases the design must survive — no primary, a stale endpoint,
/// a paused election, a contended lock, a slow reply, replacement, and restart.
final class CommandLineHandoffSocketTests: XCTestCase {

    private typealias Req = CommandLineHandoff.Request
    private typealias Resp = CommandLineHandoff.Response

    private func req(_ name: String = "work") -> Req {
        Req(given: name, rootsSet: 0, unisonDirectory: "/tmp/u",
            installationPath: "/Applications/unison-ui-mac.app", sessionArgs: [])
    }

    /// Thread-safe capture (handlers and helpers run off-main).
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
    }

    private var path = ""
    private var servers: [CommandLineHandoffServer] = []

    override func setUp() {
        super.setUp()
        path = CommandLineHandoffSocket.path(bundleID: "uht.\(UInt32.random(in: 0..<1_000_000))")!
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        unlink(path)
        unlink(path + ".lock")
        super.tearDown()
    }

    private typealias Deadline = CommandLineHandoffSocket.Deadline

    /// Wrap an immediate-reply handler as a `HandoffServe` handler, so the existing
    /// tests keep returning a plain `Response`.
    @discardableResult
    private func startServer(_ handler: @escaping @Sendable (Req, Deadline) -> Resp) -> CommandLineHandoffServer {
        guard case .listening(let server) = CommandLineHandoffServer.start(
            path: path, handler: { req, dl in .reply(handler(req, dl)) }) else {
            fatalError("server did not start")
        }
        servers.append(server)
        return server
    }

    /// Start a server with a full `HandoffServe` handler (for the two-phase cases).
    @discardableResult
    private func startServeServer(_ handler: @escaping @Sendable (Req, Deadline) -> HandoffServe) -> CommandLineHandoffServer {
        guard case .listening(let server) = CommandLineHandoffServer.start(path: path, handler: handler) else {
            fatalError("server did not start")
        }
        servers.append(server)
        return server
    }

    // MARK: two-phase (deferred) reply — a decision pending in the app

    func test_twoPhase_interimThenFinalVerdict() {
        let ticket = HandoffDecisionTicket()
        startServeServer { r, _ in
            r.given == "defer"
                ? .awaitDecision(interim: CommandLineHandoff.Interim(timeoutSeconds: 30, message: "decide in app"),
                                 ticket: ticket, waitSeconds: 30)
                : .reply(.refused(message: "unexpected"))
        }
        // The app resolves the decision shortly after the interim is sent.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            ticket.complete(.acceptedWaiting(message: "will open work"))
        }
        let interim = Box<CommandLineHandoff.Interim?>(nil)
        let result = CommandLineHandoffClient.handOff(
            req("defer"), path: path, timeout: 3, onPending: { interim.set($0) })
        XCTAssertEqual(interim.value?.message, "decide in app", "the caller sees the interim notice")
        XCTAssertEqual(result, .reply(.acceptedWaiting(message: "will open work")),
                       "the caller then receives the final verdict on the same connection")
    }

    func test_twoPhase_secondRequestIsServedWhileTheFirstWaits() {
        let ticket = HandoffDecisionTicket()
        startServeServer { r, _ in
            r.given == "defer"
                ? .awaitDecision(interim: CommandLineHandoff.Interim(timeoutSeconds: 30, message: "decide"),
                                 ticket: ticket, waitSeconds: 30)
                : .reply(.refused(message: "already pending"))
        }
        // Fire the deferred request; it blocks awaiting the decision.
        let firstDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [path] in
            _ = CommandLineHandoffClient.handOff(self.req("defer"), path: path, timeout: 30, onPending: { _ in })
            firstDone.signal()
        }
        // While the first waits, a second request must still be served promptly
        // (concurrent serving), not blocked behind the deferred one.
        var second: CommandLineHandoffClient.Result = .unavailable
        let deadline = Date().addingTimeInterval(3)
        repeat {
            second = CommandLineHandoffClient.handOff(req("other"), path: path, timeout: 1)
            if case .reply = second { break }
            usleep(50_000)
        } while Date() < deadline
        XCTAssertEqual(second, .reply(.refused(message: "already pending")),
                       "a second request is served while the first is still awaiting its decision")
        ticket.complete(.started)   // release the first
        XCTAssertEqual(firstDone.wait(timeout: .now() + 3), .success)
    }

    private func fileExists(_ p: String) -> Bool { access(p, F_OK) == 0 }

    // MARK: path / address bounds

    func test_path_isUnderTemporaryDirectory() {
        let p = CommandLineHandoffSocket.path(bundleID: "net.courbage.unison-ui-mac", temporaryDirectory: "/tmp/")
        XCTAssertEqual(p, "/tmp/net.courbage.unison-ui-mac.cli.sock")
    }

    func test_path_nilWhenTooLongForSunPath() {
        let longDir = "/" + String(repeating: "a", count: 200) + "/"
        XCTAssertNil(CommandLineHandoffSocket.path(bundleID: "x", temporaryDirectory: longDir))
        XCTAssertNil(CommandLineHandoffSocket.makeAddress(String(repeating: "b", count: 200)))
    }

    // MARK: happy path

    func test_client_handsOff_andServerReceivesTheRequest() {
        let recorder = Box<Req?>(nil)
        startServer { r, _ in recorder.set(r); return .started }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("work"), path: path, timeout: 3), .reply(.started))
        XCTAssertEqual(recorder.value, req("work"))
    }

    func test_refusalAndInvalid_propagateToClient() {
        startServer { _, _ in .refused(message: "busy: scanning") }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 3),
                       .reply(.refused(message: "busy: scanning")))
    }

    // MARK: no primary

    func test_noListener_isNoPrimary() {
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 2), .noPrimary)
    }

    // MARK: election decision (finding 2: reclaim only proven-stale endpoints)

    func test_electionDecision_reclaimsOnlyProvenStale() {
        typealias S = CommandLineHandoffServer
        XCTAssertEqual(S.electionDecision(for: .connected(3)), .lostElection)
        XCTAssertEqual(S.electionDecision(for: .noFile), .bindFresh)
        XCTAssertEqual(S.electionDecision(for: .refused), .reclaimThenBind)
        XCTAssertEqual(S.electionDecision(for: .timedOut), .couldNotElect)   // inconclusive: keep the file
        XCTAssertEqual(S.electionDecision(for: .failed), .couldNotElect)     // inconclusive: keep the file
    }

    func test_secondServer_losesTheElection() {
        startServer { _, _ in .started }
        guard case .lostElection = CommandLineHandoffServer.start(path: path, handler: { _, _ in .reply(.started) }) else {
            return XCTFail("second server should lose the election")
        }
    }

    /// Finding 2, round 1: even if the first instance pauses between bind and
    /// listen, the election lock keeps the second out until the first is listening,
    /// so only one becomes primary. Every step is acknowledged by a semaphore with
    /// bounded waits: A signals when it reaches the pause (holding the lock), B
    /// signals when it is actually contending for that lock, and only then is A
    /// released — so B is proven to have contended while A was paused.
    func test_pausedBindBeforeListen_stillElectsOnlyOnePrimary() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let bContending = DispatchSemaphore(value: 0)
        let serverA = Box<CommandLineHandoffServer?>(nil)
        let resultB = Box<CommandLineHandoffServer.StartResult?>(nil)
        let doneA = DispatchSemaphore(value: 0)
        let doneB = DispatchSemaphore(value: 0)

        Thread.detachNewThread { [path] in
            let result = CommandLineHandoffServer.start(
                path: path, handler: { _, _ in .reply(.started) },
                afterBind: { entered.signal(); _ = release.wait(timeout: .now() + 3) })
            if case .listening(let s) = result { serverA.set(s) }
            doneA.signal()
        }
        // A is now inside afterBind, holding the election lock (deterministic).
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success, "A did not reach afterBind")

        Thread.detachNewThread { [path] in
            let r = CommandLineHandoffServer.start(
                path: path, handler: { _, _ in .reply(.started) }, lockTimeout: 5,
                onContended: { bContending.signal() })
            resultB.set(r); doneB.signal()
        }
        // B is proven to be contending for the lock while A holds it, paused.
        XCTAssertEqual(bContending.wait(timeout: .now() + 3), .success, "B did not contend for the lock")

        release.signal()   // now let A finish listen and release the lock
        XCTAssertEqual(doneA.wait(timeout: .now() + 4), .success)
        XCTAssertEqual(doneB.wait(timeout: .now() + 4), .success)

        XCTAssertNotNil(serverA.value, "A should be the primary")
        if let a = serverA.value { servers.append(a) }
        guard case .lostElection = resultB.value else {
            return XCTFail("B must lose the election, not bind a second endpoint")
        }
    }

    // MARK: contended lock (finding 3: bounded, non-blocking)

    func test_acquireLock_isBoundedWhenHeld() {
        let held = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(held, LOCK_EX), 0)
        defer { close(held); unlink(path + ".lock") }
        let other = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        defer { close(other) }
        let start = Date()
        XCTAssertFalse(CommandLineHandoffSocket.acquireLock(other, deadline: .init(seconds: 0.3)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "must not block indefinitely")
    }

    func test_start_couldNotElect_whenLockIsHeld() {
        let held = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(held, LOCK_EX), 0)
        defer { close(held); unlink(path + ".lock") }
        guard case .couldNotElect = CommandLineHandoffServer.start(
            path: path, handler: { _, _ in .reply(.started) }, lockTimeout: 0.3) else {
            return XCTFail("a held election lock must report couldNotElect, not start a second instance")
        }
    }

    // MARK: the caller's deadline gates admission (findings, rounds 3 & 4)

    /// Round 3: the handler is given the caller's deadline; if the main thread is
    /// held past it (modelled by a handler that sleeps beyond the caller's short
    /// timeout), the handler must see it expired and not open. The server's own I/O
    /// bound is large, so it is not what expires.
    func test_handlerHeldPastCallerDeadline_doesNotOpen() {
        let opened = Box<Bool?>(nil)
        let handled = DispatchSemaphore(value: 0)
        guard case .listening(let server) = CommandLineHandoffServer.start(
            path: path,
            handler: { _, callerDeadline in
                Thread.sleep(forTimeInterval: 0.5)   // main thread busy past the caller's deadline
                opened.set(!callerDeadline.hasExpired)
                handled.signal()
                return .reply(callerDeadline.hasExpired ? .refused(message: "expired") : .started)
            }, connectionTimeout: 10) else { return XCTFail("server did not start") }
        servers.append(server)
        Thread.detachNewThread { [path] in
            _ = CommandLineHandoffClient.handOff(self.req("work"), path: path, timeout: 0.2)
        }
        XCTAssertEqual(handled.wait(timeout: .now() + 3), .success, "handler never ran")
        XCTAssertEqual(opened.value, false, "a request whose caller deadline passed must not open")
    }

    /// Round 4: the primary must honor the CALLER's deadline (from the request
    /// envelope), not one that restarts when the request is accepted. Sending an
    /// envelope whose deadline is already in the past proves this deterministically:
    /// the server's own I/O deadline is fresh (`connectionTimeout: 10`), yet the
    /// handler must see the caller's deadline expired. This models a request that
    /// waited past the caller's timeout before being admitted, without depending on
    /// wall-clock scheduling.
    func test_callerDeadline_fromEnvelope_notServerDeadline_gatesAdmission() {
        let sawExpired = Box<Bool?>(nil)
        let handled = DispatchSemaphore(value: 0)
        guard case .listening(let server) = CommandLineHandoffServer.start(
            path: path,
            handler: { _, callerDeadline in
                sawExpired.set(callerDeadline.hasExpired)
                handled.signal()
                return .reply(callerDeadline.hasExpired ? .refused(message: "expired") : .started)
            }, connectionTimeout: 10) else { return XCTFail("server did not start") }
        servers.append(server)

        // A raw envelope whose caller deadline is a full second in the past.
        let past = DispatchTime.now().uptimeNanoseconds &- 1_000_000_000
        let line = CommandLineHandoff.encodeEnvelope(req("victim"), deadlineUptimeNanos: past)!
        guard case .connected(let conn) = CommandLineHandoffSocket.connect(
            path: path, deadline: .init(seconds: 3)) else { return XCTFail("could not connect") }
        defer { close(conn) }
        XCTAssertTrue(CommandLineHandoffSocket.writeAll(conn, line, deadline: .init(seconds: 3)))
        shutdown(conn, SHUT_WR)

        XCTAssertEqual(handled.wait(timeout: .now() + 3), .success, "server never handled the request")
        XCTAssertEqual(sawExpired.value, true,
                       "the caller's (past) deadline, not the server's fresh one, must gate admission")
    }

    // MARK: stale endpoint

    func test_staleSocketFile_isReclaimed() {
        makeStaleSocketFile(at: path)
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 2), .noPrimary,
                       "a stale file has no live listener")
        let recorder = Box<Req?>(nil)
        startServer { r, _ in recorder.set(r); return .started }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("work"), path: path, timeout: 3), .reply(.started))
        XCTAssertEqual(recorder.value, req("work"))
    }

    // MARK: lost / slow reply (finding 3, round 1)

    func test_serverThatClosesWithoutReplying_isLostReply() {
        let fd = makeRawListener(at: path) { conn in close(conn) }
        defer { close(fd); unlink(path) }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 2), .lostReply)
    }

    func test_slowPartialReply_hitsTheDeadline_asLostReply() {
        let fd = makeRawListener(at: path) { conn in
            _ = "o".withCString { Darwin.write(conn, $0, 1) }
            Thread.sleep(forTimeInterval: 2.5)
            close(conn)
        }
        defer { close(fd); unlink(path) }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 1), .lostReply)
    }

    // MARK: shutdown, replacement, restart (findings 4 & 5)

    func test_stop_isIdempotent_andRemovesTheEndpoint() {
        let server = startServer { _, _ in .started }
        server.stop()
        server.stop()   // no-op, not a second close of a reused descriptor
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 1), .noPrimary)
        servers.removeAll()
    }

    /// Finding 4: a shutdown must remove only its own endpoint. If a newer instance
    /// has rebound the path, the old stop() must not unlink the new endpoint.
    func test_stop_doesNotRemoveAReplacedEndpoint() {
        let server = startServer { _, _ in .started }
        // Simulate a newer instance replacing the endpoint (a different inode).
        unlink(path)
        makeStaleSocketFile(at: path)
        XCTAssertTrue(fileExists(path))
        server.stop()
        XCTAssertTrue(fileExists(path), "stop() must not unlink an endpoint it no longer owns")
        servers.removeAll()
    }

    func test_restart_afterStop_bindsAndServesAgain() {
        let a = startServer { _, _ in .refused(message: "old") }
        a.stop()
        let recorder = Box<Req?>(nil)
        guard case .listening(let b) = CommandLineHandoffServer.start(
            path: path, handler: { r, _ in recorder.set(r); return .reply(.started) }) else {
            return XCTFail("a fresh instance should bind after the old one stopped")
        }
        servers.append(b)
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("work"), path: path, timeout: 3), .reply(.started))
        XCTAssertEqual(recorder.value, req("work"))
    }

    // MARK: raw-socket helpers

    /// Bind a socket to `path` and close it without listening, leaving the file.
    private func makeStaleSocketFile(at path: String) {
        var addr = CommandLineHandoffSocket.makeAddress(path)!
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
    }

    /// A listener that accepts one connection and hands it to `serve` on a
    /// background thread. Returns the listening fd for teardown.
    private func makeRawListener(at path: String,
                                 serve: @escaping @Sendable (Int32) -> Void) -> Int32 {
        var addr = CommandLineHandoffSocket.makeAddress(path)!
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        listen(fd, 4)
        Thread.detachNewThread {
            let conn = accept(fd, nil, nil)
            if conn >= 0 { serve(conn) }
        }
        return fd
    }
}
