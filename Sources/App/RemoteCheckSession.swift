import Foundation

/// One non-interactive ssh session of the guided remote-profile check, run
/// through the version probe's executor contract: a wall-clock deadline,
/// cancellation at any time, SIGTERM then SIGKILL of the exact child with
/// reaping, output collected even when the deadline expires. The blocking
/// wait runs on a GCD queue behind a continuation, never on Swift's
/// cooperative pool.
enum RemoteCheckSession {

    /// Design defaults: the session deadline and ssh's `ConnectTimeout`.
    static let defaultDeadline: TimeInterval = 10
    static let connectTimeout: Int = 5

    /// Directories searched for a bare `sshcmd` name. A GUI app's PATH does
    /// not include Homebrew, and upstream resolves `sshcmd` through the
    /// caller's PATH, so the check names the directories it tries.
    static let bareCommandDirectories = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/bin"]

    enum ShellCommandResolution: Equatable {
        case resolved(String)
        /// A bare name found in none of `bareCommandDirectories`.
        case notFound(name: String, searched: [String])
    }

    /// The executable to launch for `sshcmd`: an absolute value is used as
    /// written; a bare name is looked up in `bareCommandDirectories`.
    static func resolveShellCommand(_ sshcmd: String,
                                    fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> ShellCommandResolution
    {
        if sshcmd.hasPrefix("/") { return .resolved(sshcmd) }
        if sshcmd.contains("/") { return .resolved(sshcmd) }   // relative: as written
        for dir in bareCommandDirectories {
            let candidate = dir + "/" + sshcmd
            if fileExists(candidate) { return .resolved(candidate) }
        }
        return .notFound(name: sshcmd, searched: bareCommandDirectories)
    }

    /// The launch configuration for one session: the resolved ssh executable
    /// and the check's argument vector (`RemoteCommand.checkArguments`) with
    /// `remoteCommand` as the final argument.
    static func probeConfig(command: RemoteCommand,
                            executable: String,
                            remoteCommand: String,
                            connectTimeout: Int = RemoteCheckSession.connectTimeout) -> VersionCheck.ProbeConfig {
        VersionCheck.ProbeConfig(
            executable: executable,
            arguments: command.checkArguments(connectTimeout: connectTimeout, remoteCommand: remoteCommand),
            host: command.host)
    }

    /// A session in flight: cancel from any thread; the child pid once the
    /// process has been launched.
    final class Handle: @unchecked Sendable {
        let canceller = VersionCheck.ProbeCanceller()
        private let lock = NSLock()
        private var _pid: pid_t?

        var childPID: pid_t? { lock.lock(); defer { lock.unlock() }; return _pid }
        func recordLaunch(_ pid: pid_t) { lock.lock(); _pid = pid; lock.unlock() }
        func cancel() { canceller.cancel() }
        var isCancelled: Bool { canceller.isCancelled }
    }

    /// Run one session. The executor's blocking `execute` runs on a global
    /// GCD queue; the continuation resumes with its result. Cancellation
    /// through `handle` tears the child down synchronously at cancel time.
    static func run(config: VersionCheck.ProbeConfig,
                    deadline: TimeInterval = RemoteCheckSession.defaultDeadline,
                    handle: Handle,
                    makeExecutor: (@escaping @Sendable (pid_t) -> Void) -> VersionCheck.VersionProbeExecutor = {
                        VersionCheck.SubprocessProbeExecutor(onLaunch: $0)
                    }) async -> VersionCheck.RawExecResult
    {
        let executor = makeExecutor { pid in handle.recordLaunch(pid) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = executor.execute(config, deadline: deadline, canceller: handle.canceller)
                continuation.resume(returning: result)
            }
        }
    }

    /// A unique marker for one session: safe characters only, so it can be
    /// embedded in a remote command without quoting.
    static func makeMarker(prefix: String) -> String {
        prefix + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
