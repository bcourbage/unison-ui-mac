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
            installationPath: "/Applications/unison-ui-mac.app", plainRequest: true)
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

    @discardableResult
    private func startServer(_ handler: @escaping @Sendable (Req) -> Resp) -> CommandLineHandoffServer {
        guard case .listening(let server) = CommandLineHandoffServer.start(path: path, handler: handler) else {
            fatalError("server did not start")
        }
        servers.append(server)
        return server
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
        startServer { r in recorder.set(r); return .started }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("work"), path: path, timeout: 3), .reply(.started))
        XCTAssertEqual(recorder.value, req("work"))
    }

    func test_refusalAndInvalid_propagateToClient() {
        startServer { _ in .refused(message: "busy: scanning") }
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
        startServer { _ in .started }
        guard case .lostElection = CommandLineHandoffServer.start(path: path, handler: { _ in .started }) else {
            return XCTFail("second server should lose the election")
        }
    }

    /// Finding 2, round 1: even if the first instance pauses between bind and
    /// listen, the election lock keeps the second out until the first is listening,
    /// so only one becomes primary. Entry into the pause is acknowledged by a
    /// semaphore rather than a sleep, and the release is guaranteed.
    func test_pausedBindBeforeListen_stillElectsOnlyOnePrimary() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let serverA = Box<CommandLineHandoffServer?>(nil)
        let doneA = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [path] in
            let result = CommandLineHandoffServer.start(
                path: path, handler: { _ in .started },
                afterBind: { entered.signal(); _ = release.wait(timeout: .now() + 3) })
            if case .listening(let s) = result { serverA.set(s) }
            doneA.signal()
        }
        // A is now inside afterBind, holding the election lock (deterministic).
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success, "A did not reach afterBind")

        // B races in on its own thread; it must block on the lock, then lose.
        let resultB = Box<CommandLineHandoffServer.StartResult?>(nil)
        let doneB = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [path] in
            resultB.set(CommandLineHandoffServer.start(path: path, handler: { _ in .started }, lockTimeout: 5))
            doneB.signal()
        }
        release.signal()   // let A finish listen and release the lock
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
            path: path, handler: { _ in .started }, lockTimeout: 0.3) else {
            return XCTFail("a held election lock must report couldNotElect, not start a second instance")
        }
    }

    // MARK: stale endpoint

    func test_staleSocketFile_isReclaimed() {
        makeStaleSocketFile(at: path)
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 2), .noPrimary,
                       "a stale file has no live listener")
        let recorder = Box<Req?>(nil)
        startServer { r in recorder.set(r); return .started }
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
        let server = startServer { _ in .started }
        server.stop()
        server.stop()   // no-op, not a second close of a reused descriptor
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 1), .noPrimary)
        servers.removeAll()
    }

    /// Finding 4: a shutdown must remove only its own endpoint. If a newer instance
    /// has rebound the path, the old stop() must not unlink the new endpoint.
    func test_stop_doesNotRemoveAReplacedEndpoint() {
        let server = startServer { _ in .started }
        // Simulate a newer instance replacing the endpoint (a different inode).
        unlink(path)
        makeStaleSocketFile(at: path)
        XCTAssertTrue(fileExists(path))
        server.stop()
        XCTAssertTrue(fileExists(path), "stop() must not unlink an endpoint it no longer owns")
        servers.removeAll()
    }

    func test_restart_afterStop_bindsAndServesAgain() {
        let a = startServer { _ in .refused(message: "old") }
        a.stop()
        let recorder = Box<Req?>(nil)
        guard case .listening(let b) = CommandLineHandoffServer.start(
            path: path, handler: { r in recorder.set(r); return .started }) else {
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
