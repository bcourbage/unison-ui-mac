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
    /// `sun_path` (a `.lock` sibling must fit too).
    static func path(bundleID: String, temporaryDirectory: String = NSTemporaryDirectory()) -> String? {
        let candidate = (temporaryDirectory as NSString).appendingPathComponent(bundleID + ".cli.sock")
        return (candidate + ".lock").utf8.count < sunPathCapacity ? candidate : nil
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

    // MARK: - Deadlines (finding 3: one elapsed-time bound over connect + I/O)

    /// A single wall-clock budget shared across connect, send and receive, so the
    /// whole exchange is bounded no matter how the bytes are paced.
    struct Deadline {
        private let end: DispatchTime
        init(seconds: TimeInterval) { end = .now() + seconds }
        /// Seconds left, never negative.
        var remaining: TimeInterval {
            let now = DispatchTime.now().uptimeNanoseconds
            let e = end.uptimeNanoseconds
            return e > now ? Double(e - now) / 1_000_000_000 : 0
        }
    }

    /// Wait until `fd` is ready for `events`, bounded by the deadline. false on
    /// timeout or error.
    static func waitReady(_ fd: Int32, events: Int16, deadline: Deadline) -> Bool {
        while true {
            let ms = deadline.remaining * 1000
            guard ms > 0 else { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let capped = Int32(min(ms, Double(Int32.max)))
            let rc = poll(&pfd, 1, capped)
            if rc > 0 { return (pfd.revents & events) != 0 }
            if rc < 0 && errno == EINTR { continue }
            return false   // 0 = timeout, <0 = error
        }
    }

    /// Put `fd` into non-blocking mode so every read/write is paired with `poll`
    /// under the deadline rather than blocking indefinitely.
    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    enum ConnectResult {
        case connected(Int32)
        case noListener   // ENOENT (no file) or ECONNREFUSED (stale, no listener)
        case timedOut     // the deadline elapsed before the connection completed
    }

    /// Non-blocking connect(2) bounded by the deadline. Distinguishes "nothing is
    /// listening" from "a connection could not complete in time".
    static func connect(path: String, deadline: Deadline) -> ConnectResult {
        guard var addr = makeAddress(path) else { return .noListener }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noListener }
        setNonBlocking(fd)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { return .connected(fd) }
        if errno != EINPROGRESS { close(fd); return .noListener }
        if !waitReady(fd, events: Int16(POLLOUT), deadline: deadline) { close(fd); return .timedOut }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        if soErr != 0 { close(fd); return soErr == ETIMEDOUT ? .timedOut : .noListener }
        return .connected(fd)
    }

    /// Write every byte of `string` within the deadline. false on timeout or a
    /// hard error. `fd` is expected to be non-blocking.
    static func writeAll(_ fd: Int32, _ string: String, deadline: Deadline) -> Bool {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            guard waitReady(fd, events: Int16(POLLOUT), deadline: deadline) else { return false }
            let n = bytes[offset...].withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
            if n > 0 { offset += n; continue }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            return false
        }
        return true
    }

    /// Read one newline-terminated line (newline included) within the deadline, or
    /// nil on timeout, EOF before a newline, or the size cap. A missing newline is
    /// how a truncated, slow, or lost reply is detected. `fd` is non-blocking.
    static func readLine(_ fd: Int32, deadline: Deadline) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        while buffer.count < maxLineBytes {
            guard waitReady(fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            let want = min(chunk.count, maxLineBytes - buffer.count)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
            if n > 0 {
                for i in 0..<n {
                    buffer.append(chunk[i])
                    if chunk[i] == UInt8(ascii: "\n") { return String(decoding: buffer, as: UTF8.self) }
                }
                continue
            }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            return nil   // 0 = EOF before newline; <0 = hard error
        }
        return nil
    }
}

/// The client half: hand a request to a listening instance and read its verdict,
/// all within one deadline.
enum CommandLineHandoffClient {

    enum Result: Equatable {
        /// The primary answered.
        case reply(CommandLineHandoff.Response)
        /// Nothing is listening; the caller should become the primary.
        case noPrimary
        /// Connected but no complete reply came back in time (the primary died
        /// mid-reply, was too slow, or the request could not be sent). Reported to
        /// the caller; never retried silently.
        case lostReply
        /// The socket could not be used at all (path too long, no fd); the launch
        /// proceeds without handoff.
        case unavailable
    }

    static func handOff(_ request: CommandLineHandoff.Request,
                        path: String,
                        timeout: TimeInterval = 5) -> Result {
        guard let line = request.encoded() else { return .unavailable }
        let deadline = CommandLineHandoffSocket.Deadline(seconds: timeout)
        let fd: Int32
        switch CommandLineHandoffSocket.connect(path: path, deadline: deadline) {
        case .connected(let c): fd = c
        case .noListener: return .noPrimary
        case .timedOut: return .lostReply
        }
        defer { close(fd) }
        guard CommandLineHandoffSocket.writeAll(fd, line, deadline: deadline) else { return .lostReply }
        shutdown(fd, SHUT_WR)
        guard let replyLine = CommandLineHandoffSocket.readLine(fd, deadline: deadline),
              let response = CommandLineHandoff.Response(line: replyLine) else {
            return .lostReply
        }
        return .reply(response)
    }
}

/// The server half: bind the per-user socket, win or lose the election against
/// other instances, and serve one request per connection. The request handler
/// runs off the main thread; the caller wraps it to hop to the main actor.
final class CommandLineHandoffServer: @unchecked Sendable {

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
    /// Serializes shutdown with itself and the accept loop (finding 5).
    private let lifecycle = NSLock()
    private var stopped = false

    private init(listenFD: Int32, path: String,
                 handler: @escaping @Sendable (CommandLineHandoff.Request) -> CommandLineHandoff.Response) {
        self.listenFD = listenFD
        self.path = path
        self.handler = handler
    }

    /// The overall budget for reading a request and writing its reply on one
    /// connection, so a peer that dribbles bytes cannot hold the accept loop.
    static let connectionTimeout: TimeInterval = 5

    /// Elect a primary and start listening. The whole election — is a live primary
    /// already there, reclaim a stale file, bind, listen — runs under an exclusive
    /// file lock (finding 2), so two concurrent launches cannot both bind: the
    /// second blocks on the lock until the first is listening, then observes it and
    /// loses. `afterBind` is a test seam to force a pause between bind and listen.
    static func start(path: String,
                      handler: @escaping @Sendable (CommandLineHandoff.Request) -> CommandLineHandoff.Response,
                      afterBind: () -> Void = {}) -> StartResult {
        guard CommandLineHandoffSocket.makeAddress(path) != nil else { return .unavailable }

        // Cross-process election lock. Held only for the election; released (by
        // closing the fd) once we are listening or have lost. A crashed holder
        // releases it automatically, so this cannot deadlock.
        let lockFD = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { return .unavailable }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { return .unavailable }

        // A live primary already listening? (connect succeeds against a bound,
        // listening socket even before it calls accept.)
        if case .connected(let live) = CommandLineHandoffSocket.connect(
            path: path, deadline: .init(seconds: 1)) {
            close(live)
            return .lostElection
        }
        // No live primary. Any file here is stale; reclaim it and bind.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable }
        var addr = CommandLineHandoffSocket.makeAddress(path)!
        unlink(path)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return .unavailable }
        afterBind()
        guard listen(fd, 8) == 0 else { close(fd); unlink(path); return .unavailable }

        let server = CommandLineHandoffServer(listenFD: fd, path: path, handler: handler)
        server.startAccepting()
        return .listening(server)
    }

    private func isRunning() -> Bool {
        lifecycle.lock(); defer { lifecycle.unlock() }
        return !stopped
    }

    private func startAccepting() {
        let fd = listenFD
        let handler = self.handler
        queue.async { [weak self] in
            while self?.isRunning() ?? false {
                let conn = accept(fd, nil, nil)
                if conn < 0 {
                    if errno == EINTR { continue }
                    break   // listen fd closed by stop()
                }
                CommandLineHandoffSocket.setNonBlocking(conn)
                let deadline = CommandLineHandoffSocket.Deadline(
                    seconds: CommandLineHandoffServer.connectionTimeout)
                // A probe connection (election race detection) sends nothing and
                // closes; readLine returns nil within the deadline and we drop it.
                if let line = CommandLineHandoffSocket.readLine(conn, deadline: deadline),
                   let request = CommandLineHandoff.Request(line: line) {
                    let response = handler(request)
                    _ = CommandLineHandoffSocket.writeAll(conn, response.encoded(), deadline: deadline)
                }
                close(conn)
            }
        }
    }

    /// Stop listening and remove this listener's socket file. Idempotent and
    /// synchronized: the descriptor is closed exactly once, so a second call
    /// cannot close a reused descriptor (finding 5).
    func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard !stopped else { return }
        stopped = true
        close(listenFD)
        unlink(path)
    }
}
