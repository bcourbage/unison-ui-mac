import Foundation

/// Effective SSH configuration relevant to whether the transport is a direct,
/// single-child connection whose child we can safely SIGKILL for an in-process
/// scan interruption (Phase 1a, issue #24). Populated from `ssh -G` output, NOT
/// from naive `sshargs` string inspection (which misses ~/.ssh/config, Include,
/// and Match).
struct SSHEffectiveConfig: Equatable {
    var controlMaster: String?
    var controlPath: String?
    var proxyCommand: String?
    var proxyJump: String?

    /// Parse `ssh -G` output. Each line is `key value` with ssh lowercasing the
    /// key. Unknown keys are ignored.
    static func parse(_ output: String) -> SSHEffectiveConfig {
        var cfg = SSHEffectiveConfig()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let sp = line.firstIndex(of: " ") else { continue }
            let key = line[..<sp].lowercased()
            let value = String(line[line.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            switch key {
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

/// Decides whether a profile's SSH transport is a direct, single-child
/// connection that scan interruption may signal, or must be refused (multiplexed
/// / proxied / custom / uncertain → keep the honest Return-to-Profiles / quit).
///
/// Phase 1a Foundation: this component is implemented and TESTED, but is NOT yet
/// invoked on every open (that wiring lands in the Wiring PR, session-bound and
/// cached). The pure `parse`/`classify` are fully unit-tested; the `qualify`
/// runner is a thin, deadline-bounded shell.
enum SSHTransportQualifier {

    /// Pure classification. Unsupported when the transport is multiplexed
    /// (ControlMaster/ControlPath), proxied (ProxyCommand/ProxyJump), or driven
    /// by a custom ssh binary (we can only reason about the system ssh's single
    /// child). "none"/"no"/empty are treated as direct.
    static func classify(_ cfg: SSHEffectiveConfig, customSshCmd: Bool) -> SSHTransportQualification {
        func isSet(_ v: String?) -> Bool {
            guard let t = v?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty
            else { return false }
            return t != "none" && t != "no" && t != "false"
        }
        if customSshCmd            { return .unsupported(reason: "custom sshcmd") }
        if isSet(cfg.controlMaster){ return .unsupported(reason: "ControlMaster \(cfg.controlMaster ?? "")") }
        if isSet(cfg.controlPath)  { return .unsupported(reason: "ControlPath set") }
        if isSet(cfg.proxyCommand) { return .unsupported(reason: "ProxyCommand set") }
        if isSet(cfg.proxyJump)    { return .unsupported(reason: "ProxyJump set") }
        return .supportedDirect
    }

    /// Run `ssh -G <host>` (deadline-bounded) and classify. Any failure,
    /// timeout, or uncertainty → `.unsupported` (never falsely "supported").
    ///
    /// NOTE: `ssh -G` evaluates `Match exec` blocks, which run shell commands,
    /// so this is potentially side-effecting; the deadline bounds it and a
    /// timeout is treated as unsupported. A custom `sshcmd` short-circuits to
    /// unsupported without running anything (we would not be driving /usr/bin/ssh).
    ///
    /// Wiring-PR obligations (this runner is NOT invoked in the Foundation PR):
    ///  - This polls `isRunning` and reads stdout only after exit. `ssh -G`
    ///    output is small (tens of lines, far under the ~64KB pipe buffer), so
    ///    it cannot deadlock today — but if this is ever pointed at a command
    ///    with large output, drain the pipe incrementally (readabilityHandler)
    ///    rather than after `waitUntilExit`.
    ///  - The poll loop busy-waits the calling thread; the Wiring PR MUST run
    ///    `qualify` off the main thread (session-bound, cached), never on the
    ///    main-actor open path.
    static func qualify(host: String, extraArgs: [String] = [],
                        customSshCmd: Bool, deadline: TimeInterval = 5) -> SSHTransportQualification {
        if customSshCmd { return .unsupported(reason: "custom sshcmd") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-G"] + extraArgs + [host]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return .unsupported(reason: "ssh -G launch failed") }
        let end = Date().addingTimeInterval(deadline)
        while proc.isRunning && Date() < end { usleep(20_000) }
        if proc.isRunning {
            proc.terminate()
            return .unsupported(reason: "ssh -G timed out")
        }
        guard proc.terminationStatus == 0 else {
            return .unsupported(reason: "ssh -G exited \(proc.terminationStatus)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return .unsupported(reason: "ssh -G output unreadable")
        }
        return classify(SSHEffectiveConfig.parse(text), customSshCmd: false)
    }
}
