import XCTest
import Darwin
@testable import unison_ui_mac

/// The Unix-domain-socket transport for running-instance routing: a real server
/// and client over a throwaway per-test socket, covering the accept/refuse path
/// and the awkward cases the design must survive — no primary, a stale endpoint,
/// a simultaneous election, and a lost reply.
final class CommandLineHandoffSocketTests: XCTestCase {

    private typealias Req = CommandLineHandoff.Request
    private typealias Resp = CommandLineHandoff.Response

    /// Thread-safe capture of what the server handler saw (it runs off-main).
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: Req?
        var request: Req? { lock.lock(); defer { lock.unlock() }; return _request }
        func record(_ r: Req) { lock.lock(); _request = r; lock.unlock() }
    }

    private var path = ""
    private var servers: [CommandLineHandoffServer] = []

    override func setUp() {
        super.setUp()
        // Short unique name so the full socket path stays within sun_path.
        path = CommandLineHandoffSocket.path(bundleID: "uht.\(UInt32.random(in: 0..<1_000_000))")!
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        unlink(path)
        super.tearDown()
    }

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
        let recorder = Recorder()
        _ = startServer { req in recorder.record(req); return .started }

        let result = CommandLineHandoffClient.handOff(Req(given: "work", rootsSet: 0), path: path, timeout: 3)
        XCTAssertEqual(result, .reply(.started))
        XCTAssertEqual(recorder.request, Req(given: "work", rootsSet: 0))
    }

    func test_refusalAndInvalid_propagateToClient() {
        _ = startServer { _ in .refused(message: "busy: scanning") }
        XCTAssertEqual(CommandLineHandoffClient.handOff(Req(given: "p", rootsSet: 0), path: path, timeout: 3),
                       .reply(.refused(message: "busy: scanning")))

        // A second server on a different path returning invalid.
        let path2 = CommandLineHandoffSocket.path(bundleID: "uht.\(UInt32.random(in: 0..<1_000_000))")!
        defer { unlink(path2) }
        guard case .listening(let s2) = CommandLineHandoffServer.start(path: path2, handler: { _ in
            .invalid(message: "no such profile")
        }) else { return XCTFail("server 2 did not start") }
        defer { s2.stop() }
        XCTAssertEqual(CommandLineHandoffClient.handOff(Req(given: "p", rootsSet: 0), path: path2, timeout: 3),
                       .reply(.invalid(message: "no such profile")))
    }

    // MARK: no primary

    func test_noListener_isNoPrimary() {
        // Nothing bound at this path.
        XCTAssertEqual(CommandLineHandoffClient.handOff(Req(given: "p", rootsSet: 0), path: path, timeout: 2),
                       .noPrimary)
    }

    // MARK: election

    func test_secondServer_losesTheElection() {
        _ = startServer { _ in .started }
        guard case .lostElection = CommandLineHandoffServer.start(path: path, handler: { _ in .started }) else {
            return XCTFail("second server should lose the election")
        }
    }

    // MARK: stale endpoint

    func test_staleSocketFile_isReclaimed() {
        // Leave a bound-but-not-listening socket file behind, as a crashed
        // primary would. connect() to it gives ECONNREFUSED (no listener).
        makeStaleSocketFile(at: path)
        XCTAssertEqual(CommandLineHandoffClient.handOff(Req(given: "p", rootsSet: 0), path: path, timeout: 2),
                       .noPrimary, "a stale file has no live listener")

        // start() must detect the stale file, remove it, and bind.
        let recorder = Recorder()
        _ = startServer { req in recorder.record(req); return .started }
        XCTAssertEqual(CommandLineHandoffClient.handOff(Req(given: "work", rootsSet: 1), path: path, timeout: 3),
                       .reply(.started))
        XCTAssertEqual(recorder.request, Req(given: "work", rootsSet: 1))
    }

    // MARK: lost reply

    func test_serverThatClosesWithoutReplying_isLostReply() {
        let listenFD = makeSilentListener(at: path)
        defer { close(listenFD); unlink(path) }
        XCTAssertEqual(CommandLineHandoffClient.handOff(Req(given: "p", rootsSet: 0), path: path, timeout: 2),
                       .lostReply)
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

    /// A listener that accepts one connection and closes it without replying,
    /// on a background thread. Returns the listening fd for teardown.
    private func makeSilentListener(at path: String) -> Int32 {
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
            if conn >= 0 { close(conn) }   // accept, then close without a reply
        }
        return fd
    }
}
