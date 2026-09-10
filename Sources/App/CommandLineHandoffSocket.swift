import Foundation
import Darwin

/// The Unix-domain-socket transport for `CommandLineHandoff`. A running instance
/// binds a per-user socket and listens; a graphical `unison <profile>` launch
/// connects, sends its request, and reads one reply. There is no daemon: the
/// socket lives only as long as the app, and a crash leaves at most a stale file
/// that the next election detects and removes. Only graphical profile requests
/// ever reach here — `-ui text` and `-server` exit in the engine first.
enum CommandLineHandoffSocket {

    /// `sizeof(sockaddr_un.sun_path)` on Darwin. A path that does not fit cannot
    /// be a socket, so the handoff is skipped and the launch proceeds normally.
    static let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// The socket path for a bundle id, under the per-user temporary directory
    /// (`$TMPDIR`, e.g. /var/folders/…/T/). Keyed by bundle id so several copies
    /// of the same app coordinate on one endpoint. nil when it would not fit in
    /// `sun_path`.
    static func path(bundleID: String, temporaryDirectory: String = NSTemporaryDirectory()) -> String? {
        let candidate = (temporaryDirectory as NSString).appendingPathComponent(bundleID + ".cli.sock")
        return candidate.utf8.count < sunPathCapacity ? candidate : nil
    }

    /// Build a `sockaddr_un` for `path`, or nil when it does not fit.
    static func makeAddress(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count < sunPathCapacity else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    /// A response line is short; cap the read so a misbehaving peer cannot make
    /// us buffer without bound.
    static let maxLineBytes = 8192

    /// connect(2) to `path`. Returns the connected fd, or nil when nothing is
    /// listening (ENOENT for no file, ECONNREFUSED for a stale one).
    static func connect(path: String) -> Int32? {
        guard var addr = makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    /// Write every byte of `string`, retrying short writes and EINTR. false on
    /// any hard error.
    static func writeAll(_ fd: Int32, _ string: String) -> Bool {
        var bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Read one newline-terminated line (newline included), or nil on timeout,
    /// EOF before a newline, or the size cap. A missing newline is how a
    /// truncated or lost reply is detected.
    static func readLine(_ fd: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while buffer.count < maxLineBytes {
            let n = withUnsafeMutablePointer(to: &byte) { Darwin.read(fd, $0, 1) }
            if n == 1 {
                buffer.append(byte)
                if byte == UInt8(ascii: "\n") { return String(decoding: buffer, as: UTF8.self) }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            return nil   // 0 = EOF before newline; <0 = timeout/error
        }
        return nil
    }

    /// Set send and receive timeouts so no I/O blocks indefinitely.
    static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// The client half: hand a request to a listening instance and read its verdict.
enum CommandLineHandoffClient {

    enum Result: Equatable {
        /// The primary answered.
        case reply(CommandLineHandoff.Response)
        /// Nothing is listening; the caller should become the primary.
        case noPrimary
        /// Connected, but no complete reply came back (the primary died mid-reply
        /// or the request could not be sent). Reported to the caller; never
        /// retried silently.
        case lostReply
        /// The socket could not be used at all (path too long, no fd); the launch
        /// proceeds without handoff.
        case unavailable
    }

    static func handOff(_ request: CommandLineHandoff.Request,
                        path: String,
                        timeout: TimeInterval = 5) -> Result {
        guard let line = request.encoded() else { return .unavailable }
        guard let fd = CommandLineHandoffSocket.connect(path: path) else { return .noPrimary }
        defer { close(fd) }
        CommandLineHandoffSocket.setTimeouts(fd, seconds: timeout)
        guard CommandLineHandoffSocket.writeAll(fd, line) else { return .lostReply }
        shutdown(fd, SHUT_WR)
        guard let replyLine = CommandLineHandoffSocket.readLine(fd),
              let response = CommandLineHandoff.Response(line: replyLine) else {
            return .lostReply
        }
        return .reply(response)
    }
}

/// The server half: bind the per-user socket, win or lose the election against
/// other instances, and serve one request per connection. The request handler
/// runs off the main thread; the caller wraps it to hop to the main actor.
final class CommandLineHandoffServer {

    /// The outcome of trying to become the primary.
    enum StartResult {
        case listening(CommandLineHandoffServer)
        /// Another instance won the election; this one should hand off instead.
        case lostElection
        /// The socket could not be used; run without a listener.
        case unavailable
    }

    private let listenFD: Int32
    private let path: String
    private let handler: @Sendable (CommandLineHandoff.Request) -> CommandLineHandoff.Response
    private let queue = DispatchQueue(label: "net.courbage.unison-ui-mac.handoff")
    /// Read on the accept thread, set on stop(); a benign race at most costs one
    /// extra accept() that then fails because the fd is closed.
    nonisolated(unsafe) private var running = true

    private init(listenFD: Int32, path: String,
                 handler: @escaping @Sendable (CommandLineHandoff.Request) -> CommandLineHandoff.Response) {
        self.listenFD = listenFD
        self.path = path
        self.handler = handler
    }

    /// Bind, handling a stale file (unlink and rebind) and a live peer (lose the
    /// election). On success the accept loop is already running.
    static func start(path: String,
                      handler: @escaping @Sendable (CommandLineHandoff.Request) -> CommandLineHandoff.Response)
        -> StartResult {
        guard var addr = CommandLineHandoffSocket.makeAddress(path) else { return .unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable }

        func bindOnce() -> Int32 {
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }

        if bindOnce() != 0 {
            guard errno == EADDRINUSE else { close(fd); return .unavailable }
            // A file is already there. If a live instance answers, it won the
            // election; otherwise the file is stale — remove it and rebind.
            if let live = CommandLineHandoffSocket.connect(path: path) {
                close(live); close(fd); return .lostElection
            }
            unlink(path)
            if bindOnce() != 0 { close(fd); return .unavailable }
        }
        if listen(fd, 8) != 0 { close(fd); unlink(path); return .unavailable }

        let server = CommandLineHandoffServer(listenFD: fd, path: path, handler: handler)
        server.startAccepting()
        return .listening(server)
    }

    private func startAccepting() {
        let fd = listenFD
        let handler = self.handler
        queue.async { [weak self] in
            while self?.running ?? false {
                let conn = accept(fd, nil, nil)
                if conn < 0 {
                    if errno == EINTR { continue }
                    break   // listen fd closed by stop()
                }
                CommandLineHandoffSocket.setTimeouts(conn, seconds: 5)
                // A probe connection (election race detection) sends nothing and
                // closes; readLine returns nil and we simply drop it.
                if let line = CommandLineHandoffSocket.readLine(conn),
                   let request = CommandLineHandoff.Request(line: line) {
                    let response = handler(request)
                    _ = CommandLineHandoffSocket.writeAll(conn, response.encoded())
                }
                close(conn)
            }
        }
    }

    /// Stop listening and remove the socket file. Idempotent.
    func stop() {
        running = false
        close(listenFD)
        unlink(path)
    }
}
