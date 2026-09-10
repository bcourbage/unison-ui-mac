import Foundation
import Darwin

/// The Unix-domain-socket transport for `CommandLineHandoff`. A running instance
/// binds a per-user socket and listens; a graphical `unison <profile>` launch
/// connects, sends its request, and reads one reply. There is no daemon: the
/// socket lives only as long as the app, and a crash leaves at most a stale file
/// that the next election reclaims. Only graphical profile requests ever reach
/// here — `-ui text` and `-server` exit in the engine first.
enum CommandLineHandoffSocket {

    /// `sizeof(sockaddr_un.sun_path)` on Darwin. A path that does not fit cannot
    /// be a socket, so the handoff is skipped and the launch proceeds normally.
    static let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// The socket path for a bundle id, under the per-user temporary directory
    /// (`$TMPDIR`, e.g. /var/folders/…/T/). Keyed by bundle id so several copies
    /// of the same app coordinate on one endpoint (the primary then checks that a
    /// handoff's installation matches). nil when it would not fit in `sun_path`
    /// (a `.lock` sibling must fit too).
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

    // MARK: - Deadlines (finding 3, round 1: one elapsed-time bound over connect + I/O)

    /// A single wall-clock budget shared across connect, send and receive, so the
    /// whole exchange is bounded no matter how the bytes are paced. It is an
    /// absolute instant, so it stays meaningful after crossing a thread boundary —
    /// the handler checks it on the main thread to catch a request whose deadline
    /// already passed while the main thread was busy (finding 1, round 3).
    struct Deadline: Sendable {
        private let end: DispatchTime
        init(seconds: TimeInterval) { end = .now() + seconds }
        /// Seconds left, never negative.
        var remaining: TimeInterval {
            let now = DispatchTime.now().uptimeNanoseconds
            let e = end.uptimeNanoseconds
            return e > now ? Double(e - now) / 1_000_000_000 : 0
        }
        /// Whether the budget is spent.
        var hasExpired: Bool { remaining <= 0 }
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

    /// The outcome of a connect attempt, distinguishing outcomes that prove there
    /// is no listener (safe to reclaim) from ones that do not (finding 2).
    enum ConnectResult: Equatable {
        case connected(Int32)
        case refused   // ECONNREFUSED: a socket file exists but nothing is listening
        case noFile    // ENOENT: no socket file at all
        case timedOut  // the deadline elapsed before the connection completed
        case failed    // any other error (EACCES, EMFILE, …): inconclusive
    }

    /// Non-blocking connect(2) bounded by the deadline. On `.connected` the fd is
    /// open and left non-blocking for the caller; every other case has closed it.
    static func connect(path: String, deadline: Deadline) -> ConnectResult {
        guard var addr = makeAddress(path) else { return .failed }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed }
        setNonBlocking(fd)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { return .connected(fd) }
        if errno == EINPROGRESS {
            guard waitReady(fd, events: Int16(POLLOUT), deadline: deadline) else { close(fd); return .timedOut }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr == 0 { return .connected(fd) }
            close(fd)
            return classify(errno: soErr)
        }
        let e = errno
        close(fd)
        return classify(errno: e)
    }

    private static func classify(errno e: Int32) -> ConnectResult {
        switch e {
        case ECONNREFUSED: return .refused
        case ENOENT: return .noFile
        case ETIMEDOUT: return .timedOut
        default: return .failed
        }
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

    /// Acquire an advisory lock without blocking, retrying under a deadline
    /// (finding 3): a suspended or hung holder must not stall the caller's main
    /// thread. false when the deadline elapses or the lock cannot be taken.
    static func acquireLock(_ fd: Int32, deadline: Deadline, onContended: () -> Void = {}) -> Bool {
        var announced = false
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            if errno == EINTR { continue }
            if errno != EWOULDBLOCK { return false }
            if !announced { announced = true; onContended() }   // proven to be contending
            guard deadline.remaining > 0 else { return false }
            usleep(20_000)   // 20 ms
        }
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
        /// Connected but no complete reply came back in time, or the connection
        /// could not complete. Reported to the caller; never retried silently.
        case lostReply
        /// The socket could not be used at all (path too long, resource failure);
        /// the launch proceeds without handoff.
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
        case .refused, .noFile: return .noPrimary
        case .timedOut: return .lostReply
        case .failed: return .unavailable
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
        /// The socket path cannot be used at all; run without a listener.
        case unavailable
        /// The election could not be completed (its lock is held by a suspended or
        /// hung holder, or a probe was inconclusive). The caller must not start a
        /// second instance; it should report failure (finding 3).
        case couldNotElect
    }

    /// What to do with the socket file given the election probe (finding 2):
    /// reclaim only when a stale file is proven, never on an inconclusive result.
    enum ElectionDecision: Equatable {
        case lostElection    // a live primary answered
        case bindFresh       // no file present; bind directly
        case reclaimThenBind // a stale file (connection refused); unlink then bind
        case couldNotElect   // timed out or failed; do not touch the file
    }

    static func electionDecision(for probe: CommandLineHandoffSocket.ConnectResult) -> ElectionDecision {
        switch probe {
        case .connected: return .lostElection
        case .noFile: return .bindFresh
        case .refused: return .reclaimThenBind
        case .timedOut, .failed: return .couldNotElect
        }
    }

    private let listenFD: Int32
    private let wakeWriteFD: Int32
    private let path: String
    private let ownDevice: dev_t
    private let ownInode: ino_t
    /// The handler is given the connection's deadline so it can decline to act on a
    /// request whose budget already elapsed while the main thread was busy.
    private let handler: @Sendable (CommandLineHandoff.Request, CommandLineHandoffSocket.Deadline)
        -> CommandLineHandoff.Response
    private let connectionTimeout: TimeInterval
    private let queue = DispatchQueue(label: "net.courbage.unison-ui-mac.handoff")
    /// Makes stop() idempotent; the accept loop owns and closes `listenFD`.
    private let lifecycle = NSLock()
    private var stopped = false

    private init(listenFD: Int32, wakeReadFD: Int32, wakeWriteFD: Int32, path: String,
                 device: dev_t, inode: ino_t, connectionTimeout: TimeInterval,
                 handler: @escaping @Sendable (CommandLineHandoff.Request, CommandLineHandoffSocket.Deadline)
                     -> CommandLineHandoff.Response) {
        self.listenFD = listenFD
        self.wakeWriteFD = wakeWriteFD
        self.path = path
        self.ownDevice = device
        self.ownInode = inode
        self.connectionTimeout = connectionTimeout
        self.handler = handler
        startAccepting(listenFD: listenFD, wakeReadFD: wakeReadFD)
    }

    /// The overall budget for reading a request and writing its reply on one
    /// connection, so a peer that dribbles bytes cannot hold the accept loop.
    static let connectionTimeout: TimeInterval = 5
    /// How long to wait for the election lock before giving up (finding 3).
    static let electionLockTimeout: TimeInterval = 2

    private static func lockPath(_ path: String) -> String { path + ".lock" }

    /// Elect a primary and start listening. The whole election — probe for a live
    /// primary, reclaim a *proven* stale file, bind, listen — runs under an
    /// advisory lock acquired without blocking under a deadline, so a suspended
    /// holder cannot stall the launch and two concurrent launches cannot both
    /// bind. `afterBind` is a test seam to force a pause between bind and listen.
    static func start(path: String,
                      handler: @escaping @Sendable (CommandLineHandoff.Request, CommandLineHandoffSocket.Deadline)
                          -> CommandLineHandoff.Response,
                      lockTimeout: TimeInterval = electionLockTimeout,
                      connectionTimeout: TimeInterval = connectionTimeout,
                      afterBind: () -> Void = {},
                      onContended: () -> Void = {}) -> StartResult {
        guard CommandLineHandoffSocket.makeAddress(path) != nil else { return .unavailable }

        let lockFD = open(lockPath(path), O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { return .unavailable }
        defer { close(lockFD) }
        guard CommandLineHandoffSocket.acquireLock(
            lockFD, deadline: .init(seconds: lockTimeout), onContended: onContended) else { return .couldNotElect }

        let probe = CommandLineHandoffSocket.connect(path: path, deadline: .init(seconds: 1))
        if case .connected(let live) = probe { close(live) }
        switch electionDecision(for: probe) {
        case .lostElection: return .lostElection
        case .couldNotElect: return .couldNotElect
        case .bindFresh: break
        case .reclaimThenBind: unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable }
        var addr = CommandLineHandoffSocket.makeAddress(path)!
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return .unavailable }
        afterBind()
        guard listen(fd, 8) == 0 else { close(fd); unlink(path); return .unavailable }

        // Record the bound file's identity so shutdown removes only this endpoint,
        // never one a later instance rebound (finding 4).
        var st = Darwin.stat()
        let haveStat = stat(path, &st) == 0

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { close(fd); unlink(path); return .unavailable }

        let server = CommandLineHandoffServer(
            listenFD: fd, wakeReadFD: pipeFDs[0], wakeWriteFD: pipeFDs[1], path: path,
            device: haveStat ? st.st_dev : 0, inode: haveStat ? st.st_ino : 0,
            connectionTimeout: connectionTimeout, handler: handler)
        return .listening(server)
    }

    /// The accept loop waits on both the listen socket and a wake pipe, so stop()
    /// never has to close a descriptor the loop is about to use: the loop owns
    /// `listenFD` and `wakeReadFD` and closes them itself on exit (finding 4).
    private func startAccepting(listenFD: Int32, wakeReadFD: Int32) {
        let handler = self.handler
        let connectionTimeout = self.connectionTimeout
        queue.async {
            defer { close(listenFD); close(wakeReadFD) }
            while true {
                var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0)]
                let rc = poll(&fds, 2, -1)
                if rc < 0 { if errno == EINTR { continue }; break }
                if fds[1].revents != 0 { break }               // stop() signalled
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let conn = accept(listenFD, nil, nil)
                if conn < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; break }
                CommandLineHandoffSocket.setNonBlocking(conn)
                let deadline = CommandLineHandoffSocket.Deadline(seconds: connectionTimeout)
                // A probe connection (election race detection) sends nothing and
                // closes; readLine returns nil within the deadline and we drop it.
                if let line = CommandLineHandoffSocket.readLine(conn, deadline: deadline),
                   let request = CommandLineHandoff.Request(line: line) {
                    // The handler gets the deadline: if the main thread was busy
                    // past it, the request must not start (finding 1, round 3).
                    let response = handler(request, deadline)
                    _ = CommandLineHandoffSocket.writeAll(conn, response.encoded(), deadline: deadline)
                }
                close(conn)
            }
        }
    }

    /// Stop listening and remove this listener's socket file. Idempotent and
    /// synchronized (finding 5, round 1). Cleanup is coordinated with election:
    /// the file is unlinked under the election lock and only when it is still this
    /// listener's endpoint, so a shutdown cannot remove an endpoint a newer
    /// instance rebound (finding 4).
    func stop() {
        lifecycle.lock()
        let already = stopped
        stopped = true
        lifecycle.unlock()
        guard !already else { return }

        // Wake the accept loop; it owns and closes listenFD/wakeReadFD.
        var byte: UInt8 = 0
        _ = withUnsafePointer(to: &byte) { Darwin.write(wakeWriteFD, $0, 1) }
        close(wakeWriteFD)

        let lockFD = open(Self.lockPath(path), O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 {
            if CommandLineHandoffSocket.acquireLock(lockFD, deadline: .init(seconds: 0.5)) {
                var st = Darwin.stat()
                if stat(path, &st) == 0, st.st_dev == ownDevice, st.st_ino == ownInode {
                    unlink(path)
                }
            }
            close(lockFD)
        }
    }
}
