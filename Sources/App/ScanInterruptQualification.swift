import Foundation

/// Pure planning for the per-CONNECTION scan-interruption qualification (issue
/// #24, Wiring PR). Decides — from a profile's `.prf` alone — whether an
/// in-flight scan over that profile's transport is even a CANDIDATE for
/// in-process interruption, and if so how to run the `ssh -G` probe that
/// confirms it is a direct single-child OpenSSH transport we can SIGKILL.
///
/// Kept pure (no subprocess, no AppKit) so the profile→plan mapping is unit
/// tested; the AppDelegate driver runs `SSHTransportQualifier.qualify` off the
/// main thread using the returned plan, bound to the connect operation.
///
/// FAILS CLOSED on any uncertainty: interruption is a candidate ONLY for a
/// single, direct `ssh://` transport driven by the SYSTEM OpenSSH we can probe.
enum ScanInterruptQualification {

    enum Plan: Equatable {
        /// Not a candidate — never offer Stop Scan, never probe. The fail-closed
        /// result for any uncertainty. `reason` is for logging only.
        case skip(reason: String)
        /// Run `ssh -G host <extraArgs>` against the SYSTEM `/usr/bin/ssh`.
        /// `extraArgs` already carries the resolved port (`-p <port>`) and the
        /// profile's `sshargs`, so `ssh -G` resolves the SAME transport Unison
        /// launches. Only produced when the command is provably the system ssh.
        case qualify(host: String, extraArgs: [String])
    }

    /// Build the plan for `profile`.
    static func plan(profile: String, unisonDirectory: String) -> Plan {
        let url = URL(fileURLWithPath: unisonDirectory)
            .appendingPathComponent("\(profile).prf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .skip(reason: "couldn't read .prf at \(url.path)")
        }
        return plan(profileText: text)
    }

    /// Testable core: build the plan from raw `.prf` text. FAILS CLOSED on any
    /// uncertainty (review Blocker 4 + round 2 Finding 2): included/sourced
    /// files may inject sshargs/sshcmd we can't see; multiple ssh roots are an
    /// ambiguous transport; a `sshcmd` that is not provably the system OpenSSH
    /// (Unison executes the configured value DIRECTLY — a bare `plink`/wrapper
    /// is NOT `/usr/bin/ssh`) means the real transport differs from what we
    /// would probe; and duplicate `sshcmd`/`sshargs` entries have
    /// implementation-defined precedence we do not reproduce.
    static func plan(profileText text: String) -> Plan {
        let doc = ProfileDocument.parse(text)
        // include / include? / source / source? may inject sshargs/sshcmd/host
        // aliases we can't resolve here.
        if !doc.includes.isEmpty || doc.hasPassThroughDirectives {
            return .skip(reason: "profile has include/source directives (effective config unresolved)")
        }
        // Exactly one ssh root.
        let sshRoots = doc.values(forKey: "root").compactMap(VersionCheck.SSHRoot.parse)
        guard sshRoots.count == 1, let sshRoot = sshRoots.first else {
            return .skip(reason: sshRoots.isEmpty
                         ? "no ssh:// remote root"
                         : "ambiguous transport (\(sshRoots.count) ssh roots)")
        }
        // sshcmd: Unison runs the configured value directly (PATH/shell), NOT
        // necessarily /usr/bin/ssh. We can only reason about the system OpenSSH
        // we drive for `ssh -G`, so accept ONLY an absent sshcmd (default) or an
        // exact `/usr/bin/ssh`; anything else (bare wrapper, plink, other
        // absolute path) fails closed. Duplicate sshcmd → ambiguous.
        let sshcmds = doc.values(forKey: "sshcmd")
        if sshcmds.count > 1 { return .skip(reason: "duplicate sshcmd (precedence unresolved)") }
        if let cmd = sshcmds.first, cmd != "/usr/bin/ssh" {
            return .skip(reason: "sshcmd '\(cmd)' is not provably the system OpenSSH")
        }
        // Duplicate sshargs → concatenation/precedence we don't reproduce.
        let sshargsAll = doc.values(forKey: "sshargs")
        if sshargsAll.count > 1 { return .skip(reason: "duplicate sshargs (precedence unresolved)") }
        // Carry the resolved PORT (a dropped port could flip a port-sensitive
        // `Match`/`Match exec` rule to a different transport) and the sshargs.
        var extraArgs: [String] = []
        if let port = sshRoot.port { extraArgs += ["-p", String(port)] }
        extraArgs += VersionCheck.tokenizeSSHArgs(sshargsAll.first)
        let hostArg = sshRoot.user.map { "\($0)@\(sshRoot.host)" } ?? sshRoot.host
        return .qualify(host: hostArg, extraArgs: extraArgs)
    }
}

/// Connection-bound qualification cache (round 2 Finding 3). A session survives
/// `.stopped → Rescan`, but that reconnect creates a NEW ssh transport (and may
/// pick up an edited `.prf`/`~/.ssh/config`), so a verdict MUST NOT outlive the
/// connection that produced it. Each `beginConnect` opens a new GENERATION
/// (keyed off the connect op) that invalidates the cached verdict; a probe
/// result applies only if it belongs to the current generation, so an older
/// probe can never overwrite a newer one.
struct ScanInterruptQualCache {
    private var generation: [EngineSessionCoordinator.SessionID: UInt64] = [:]
    private var verdict: [EngineSessionCoordinator.SessionID: SSHTransportQualification] = [:]

    /// Open a new connection generation; invalidates the cached verdict so
    /// interruption is not offered again until the fresh probe resolves.
    mutating func beginGeneration(session s: EngineSessionCoordinator.SessionID,
                                  generation g: UInt64) {
        generation[s] = g
        verdict[s] = nil
    }

    /// Apply a probe result iff it belongs to the session's CURRENT generation.
    /// Returns true when applied; a stale/superseded result is dropped.
    @discardableResult
    mutating func apply(session s: EngineSessionCoordinator.SessionID,
                        generation g: UInt64,
                        _ v: SSHTransportQualification) -> Bool {
        guard generation[s] == g else { return false }
        verdict[s] = v
        return true
    }

    /// Only a resolved `.supportedDirect` for the current generation authorizes
    /// interruption. An unresolved (invalidated) or non-direct verdict is false.
    func supported(session s: EngineSessionCoordinator.SessionID) -> Bool {
        verdict[s] == .supportedDirect
    }

    func resolved(session s: EngineSessionCoordinator.SessionID) -> SSHTransportQualification? {
        verdict[s]
    }

    mutating func clear(session s: EngineSessionCoordinator.SessionID) {
        generation[s] = nil
        verdict[s] = nil
    }
}
