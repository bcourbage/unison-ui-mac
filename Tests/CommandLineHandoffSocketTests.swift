import XCTest
import Darwin
@testable import unison_ui_mac

/// The Unix-domain-socket transport for running-instance routing: a real server
/// and client over a throwaway per-test socket, covering the accept/refuse path
/// and the awkward cases the design must survive — no primary, a stale endpoint,
/// a paused election, a slow reply, and a repeated shutdown.
final class CommandLineHandoffSocketTests: XCTestCase {

    private typealias Req = CommandLineHandoff.Request
    private typealias Resp = CommandLineHandoff.Response

    private func req(_ name: String = "work", plain: Bool = true) -> Req {
        Req(given: name, rootsSet: 0, unisonDirectory: "/tmp/u", plainRequest: plain)
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

    // MARK: election

    func test_secondServer_losesTheElection() {
        startServer { _ in .started }
        guard case .lostElection = CommandLineHandoffServer.start(path: path, handler: { _ in .started }) else {
            return XCTFail("second server should lose the election")
        }
    }

    /// Finding 2: even if the first instance pauses between bind and listen, the
    /// election lock keeps the second out until the first is listening, so only one
    /// becomes primary. Without serialization the second would unlink the first's
    /// half-bound socket and both would succeed.
    func test_pausedBindBeforeListen_stillElectsOnlyOnePrimary() {
        let serverA = Box<CommandLineHandoffServer?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [path] in
            let result = CommandLineHandoffServer.start(
                path: path, handler: { _ in .started },
                afterBind: { Thread.sleep(forTimeInterval: 0.5) })   // pause bind → listen
            if case .listening(let s) = result { serverA.set(s) }
            done.signal()
        }
        // Let A acquire the lock and enter its pause, then race B in.
        Thread.sleep(forTimeInterval: 0.1)
        let resultB = CommandLineHandoffServer.start(path: path, handler: { _ in .started })
        done.wait()

        XCTAssertNotNil(serverA.value, "A should be the primary")
        if let a = serverA.value { servers.append(a) }
        guard case .lostElection = resultB else {
            return XCTFail("B must lose the election, not bind a second endpoint")
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

    // MARK: lost / slow reply (finding 3)

    func test_serverThatClosesWithoutReplying_isLostReply() {
        let fd = makeRawListener(at: path) { conn in close(conn) }   // accept, reply nothing
        defer { close(fd); unlink(path) }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 2), .lostReply)
    }

    func test_slowPartialReply_hitsTheDeadline_asLostReply() {
        // One byte, then a stall longer than the client's deadline: no newline
        // arrives in time, so the bounded read reports a lost reply rather than
        // waiting indefinitely.
        let fd = makeRawListener(at: path) { conn in
            _ = "o".withCString { Darwin.write(conn, $0, 1) }
            Thread.sleep(forTimeInterval: 2.5)
            close(conn)
        }
        defer { close(fd); unlink(path) }
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 1), .lostReply)
    }

    // MARK: idempotent shutdown (finding 5)

    func test_stop_isIdempotent_andRemovesTheEndpoint() {
        let server = startServer { _ in .started }
        server.stop()
        server.stop()   // must be a no-op, not a second close of a reused descriptor
        // Endpoint gone: a later client finds no primary.
        XCTAssertEqual(CommandLineHandoffClient.handOff(req("p"), path: path, timeout: 1), .noPrimary)
        servers.removeAll()   // already stopped
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
