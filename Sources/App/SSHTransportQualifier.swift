import Foundation

/// Effective SSH configuration relevant to whether the transport is a direct,
/// single-child connection whose child we can safely SIGKILL for an in-process
/// scan interruption (Phase 1a, issue #24). Populated from `ssh -G` output, NOT
/// from naive `sshargs` string inspection (which misses ~/.ssh/config, Include,
/// and Match).
struct SSHEffectiveConfig: Equatable {
    // Witness fields — a genuine, complete `ssh -G` invocation always resolves
    // all four (host/user default to the argument and the login name; port and
    // controlmaster always have canonical values). Their presence is our proof
    // that the output is a real, non-truncated dump (see `isComplete`).
    var hostname: String?
    var user: String?
    var port: String?
    var controlMaster: String?
    // Transport-shape fields. Absent values may be trusted to mean "none/unset"
    // ONLY once `isComplete` confirms a genuine result.
    var controlPath: String?
    var proxyCommand: String?
    var proxyJump: String?

    /// Whether this looks like a genuine, complete `ssh -G` result rather than
    /// empty, truncated, or garbage output. A real `ssh -G` always resolves a
    /// hostname, a user, a numeric port, and a controlmaster value; if any is
    /// missing we must NOT infer "no proxy/multiplexing" from absent optional
    /// fields — the safe reading is "we don't actually know". Fail closed
    /// (Finding, round 2): uncertainty is never `.supportedDirect`.
    var isComplete: Bool {
        func present(_ v: String?) -> Bool {
            guard let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return false }
            return true
        }
        guard present(hostname), present(user), present(controlMaster) else { return false }
        // Port must be present AND numeric — a resolved `ssh -G` prints e.g.
        // "port 22"; a non-numeric or missing port means the dump is not the
        // real thing.
        guard let p = port?.trimmingCharacters(in: .whitespaces), Int(p) != nil else { return false }
        return true
    }

    /// Parse `ssh -G` output. Each line is `key value` with ssh lowercasing the
    /// key. Unknown keys are ignored. A key with no value (no space) is skipped,
    /// so a truncated/garbage line cannot masquerade as a resolved field.
    static func parse(_ output: String) -> SSHEffectiveConfig {
        var cfg = SSHEffectiveConfig()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let sp = line.firstIndex(of: " ") else { continue }
            let key = line[..<sp].lowercased()
            let value = String(line[line.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "hostname":      cfg.hostname = value
            case "user":          cfg.user = value
            case "port":          cfg.port = value
            case "controlmaster": cfg.controlMaster = value
            case "controlpath":   cfg.controlPath = value
            case "proxycommand":  cfg.proxyCommand = value
            case "proxyjump":     cfg.proxyJump = value
            default: break
            }
        }
        return cfg
    }
}

enum SSHTransportQualification: Equatable {
    case supportedDirect
    case unsupported(reason: String)
    var isSupported: Bool { self == .supportedDirect }
}

// MARK: - Subprocess execution (lifecycle-owned)

/// Everything needed to launch the `ssh -G` qualification subprocess. Built
/// purely so argument construction is testable, then handed to an executor.
struct SSHProbeConfig: Equatable {
    let executable: String
    let arguments: [String]
    /// The host argument, for logging (already reflected in `arguments`).
    let host: String
}

/// Raw result of running the qualification subprocess. The executor is
/// responsible ONLY for launching, applying the wall-clock deadline, honoring
/// cancellation, and terminating+reaping the exact child — never for
/// interpreting `ssh -G`'s output.
enum SSHConfigResult: Equatable {
    /// Process exited on its own within the deadline.
    case exited(status: Int32, stdout: String)
    /// The wall-clock deadline elapsed; the child was SIGTERM'd, then SIGKILL'd,
    /// and best-effort reaped (ProxyCommand descendants not guaranteed reaped).
    case timedOut
    /// Cancellation was requested; same teardown + descendant caveat.
    case cancelled
    /// The process could not be launched at all.
    case launchFailed(String)
}

/// Executes an `ssh -G` subprocess. Injectable so tests can drive launch
/// failure, timeout, non-zero exit, empty output, and success deterministically
/// without spawning `ssh`.
protocol SSHConfigExecutor: Sendable {
    func run(_ config: SSHProbeConfig,
             deadline: TimeInterval,
             canceller: VersionCheck.ProbeCanceller) -> SSHConfigResult
}

/// The real executor: mirrors `VersionCheck.SubprocessProbeExecutor` — a
/// `Process` with a TRUE MONOTONIC wall-clock deadline and a
/// terminate-then-kill teardown that reaps the exact child, so a wedged `ssh -G`
/// (e.g. a hung `Match exec`) can't outlive the supposedly-bounded call. The
/// deadline is measured with `DispatchTime` (monotonic), never `Date` (which a
/// wall-clock adjustment could skew).
struct SubprocessSSHConfigExecutor: SSHConfigExecutor {
    var deadlinePollInterval: TimeInterval = 0.05
    var grace: TimeInterval = VersionCheck.terminateGrace

    func run(_ config: SSHProbeConfig,
             deadline: TimeInterval,
             canceller: VersionCheck.ProbeCanceller) -> SSHConfigResult {
        if canceller.isCancelled { return .cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = config.arguments
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            return .launchFailed(error.localizedDescription)
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }

        func reapExactChild() {
            // SIGTERM, then SIGKILL after a bounded grace, waiting so the child
            // itself is best-effort reaped (no zombie). Reaps ONLY the direct
            // child; a ProxyCommand/`Match exec` descendant is ssh's own child
            // and is not guaranteed reaped here. The final wait result is not
            // asserted: if even SIGKILL+grace hasn't reaped, we return rather
            // than block forever.
            process.terminate()
            if exited.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + grace)
            }
        }
        func closePipes() {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }

        // Deterministic teardown: the instant cancel() runs the child is
        // SIGTERM'd synchronously, not on a later poll tick. A cancel that
        // raced run() fires here immediately.
        canceller.registerTeardown { process.terminate() }
        if canceller.isCancelled {
            reapExactChild(); canceller.clearTeardown(); closePipes(); return .cancelled
        }

        // Monotonic deadline, measured from just after the (fast, synchronous)
        // local spawn returned.
        let deadlineAt = DispatchTime.now() + deadline
        while true {
            if canceller.isCancelled {
                reapExactChild(); canceller.clearTeardown(); closePipes(); return .cancelled
            }
            if exited.wait(timeout: .now() + deadlinePollInterval) == .success {
                canceller.clearTeardown()
                // We only reach here AFTER the child exited, so both pipes can
                // be drained without deadlock. Note: reading post-exit does NOT
                // prevent a pre-exit pipe stall — a child that fills stdout or
                // stderr before exiting would block on write. What safely bounds
                // that case is the deadline (a stalled child never signals
                // `exited`, so we time out and tear it down → unsupported).
                // `ssh -G` output is tiny (tens of lines, far under the pipe
                // buffer) so a pre-exit stall is not a real risk; concurrent
                // draining would be optional hardening, not required for this
                // fail-closed use. stderr is drained and discarded here.
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                _ = try? errPipe.fileHandleForReading.readToEnd()
                closePipes()
                return .exited(status: process.terminationStatus,
                               stdout: String(data: outData, encoding: .utf8) ?? "")
            }
            if DispatchTime.now() >= deadlineAt {
                reapExactChild(); canceller.clearTeardown(); closePipes(); return .timedOut
            }
        }
    }
}

/// Decides whether a profile's SSH transport is a direct, single-child
/// connection that scan interruption may signal, or must be refused (multiplexed
/// / proxied / custom / uncertain → keep the honest Return-to-Profiles / quit).
///
/// Phase 1a Foundation: this component is implemented and TESTED, but is NOT yet
/// invoked on every open (that wiring lands in the Wiring PR, session-bound,
/// cached, and run OFF the main thread). Both the pure `parse`/`classify`
/// decision logic and the subprocess executor's teardown are unit-tested here.
enum SSHTransportQualifier {

    /// Pure classification. FAILS CLOSED: only a genuine, COMPLETE `ssh -G`
    /// result (see `SSHEffectiveConfig.isComplete`) can authorize signalling.
    /// Unsupported when the output is empty/truncated/garbage, when the
    /// transport is multiplexed (ControlMaster/ControlPath), proxied
    /// (ProxyCommand/ProxyJump), or driven by a custom ssh binary (we can only
    /// reason about the system ssh's single child). Once complete, "none"/"no"/
    /// empty optional fields are treated as direct.
    static func classify(_ cfg: SSHEffectiveConfig, customSshCmd: Bool) -> SSHTransportQualification {
        func isSet(_ v: String?) -> Bool {
            guard let t = v?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty
            else { return false }
            return t != "none" && t != "no" && t != "false"
        }
        if customSshCmd { return .unsupported(reason: "custom sshcmd") }
        // Finding (round 2): an incomplete/empty result must never qualify. We
        // cannot conclude "no proxy, no multiplexing" from absent fields unless
        // the dump is provably a real, resolved `ssh -G`.
        guard cfg.isComplete else {
            return .unsupported(reason: "incomplete or unparseable ssh -G output")
        }
        if isSet(cfg.controlMaster){ return .unsupported(reason: "ControlMaster \(cfg.controlMaster ?? "")") }
        if isSet(cfg.controlPath)  { return .unsupported(reason: "ControlPath set") }
        if isSet(cfg.proxyCommand) { return .unsupported(reason: "ProxyCommand set") }
        if isSet(cfg.proxyJump)    { return .unsupported(reason: "ProxyJump set") }
        return .supportedDirect
    }

    /// Build the `ssh -G <host>` argv. Pure + tested.
    static func buildConfig(host: String, extraArgs: [String]) -> SSHProbeConfig {
        SSHProbeConfig(executable: "/usr/bin/ssh",
                       arguments: ["-G"] + extraArgs + [host],
                       host: host)
    }

    /// Run `ssh -G <host>` (deadline-bounded, teardown-owned) and classify. Any
    /// launch failure, timeout, cancellation, non-zero exit, or incomplete
    /// output → `.unsupported` (never falsely "supported").
    ///
    /// NOTE: `ssh -G` evaluates `Match exec` blocks, which run shell commands,
    /// so this is potentially side-effecting; the executor's monotonic deadline
    /// bounds it and a timeout tears the child down (SIGTERM → grace → SIGKILL →
    /// reap). A custom `sshcmd` short-circuits to unsupported without running
    /// anything (we would not be driving /usr/bin/ssh).
    ///
    /// Wiring-PR obligation: this runner MUST be invoked OFF the main thread
    /// (session-bound, cached), never on the main-actor open path — the executor
    /// blocks the calling thread for up to `deadline`.
    static func qualify(host: String, extraArgs: [String] = [],
                        customSshCmd: Bool, deadline: TimeInterval = 5,
                        executor: SSHConfigExecutor = SubprocessSSHConfigExecutor(),
                        canceller: VersionCheck.ProbeCanceller = .init()) -> SSHTransportQualification {
        if customSshCmd { return .unsupported(reason: "custom sshcmd") }
        let config = buildConfig(host: host, extraArgs: extraArgs)
        switch executor.run(config, deadline: deadline, canceller: canceller) {
        case .launchFailed(let m):
            return .unsupported(reason: "ssh -G launch failed: \(m)")
        case .timedOut:
            return .unsupported(reason: "ssh -G timed out")
        case .cancelled:
            return .unsupported(reason: "ssh -G cancelled")
        case .exited(let status, _) where status != 0:
            return .unsupported(reason: "ssh -G exited \(status)")
        case .exited(_, let stdout):
            return classify(SSHEffectiveConfig.parse(stdout), customSshCmd: false)
        }
    }
}
