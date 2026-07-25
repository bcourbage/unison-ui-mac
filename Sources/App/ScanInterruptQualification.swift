import Foundation

/// Pure planning for the per-session scan-interruption qualification (issue #24,
/// Wiring PR). Decides — from a profile's `.prf` alone — whether an in-flight
/// scan over that profile's transport is even a CANDIDATE for in-process
/// interruption, and if so how to run the `ssh -G` probe that confirms it is a
/// direct single-child ssh transport.
///
/// Kept pure (no subprocess, no AppKit) so the profile→plan mapping is unit
/// tested; the AppDelegate driver runs `SSHTransportQualifier.qualify` off the
/// main thread using the returned plan and caches the verdict per session.
///
/// Interruption is a candidate ONLY for an ssh:// remote root. A local-only or
/// socket:// profile has no transport child to signal — the honest
/// Return-to-Profiles fallback is used, and no probe is run.
enum ScanInterruptQualification {

    enum Plan: Equatable {
        /// Not a candidate — never offer Stop Scan, never probe. `reason` is for
        /// logging only. This is the FAIL-CLOSED result for any uncertainty.
        case skip(reason: String)
        /// Run `ssh -G host <extraArgs>`; `customSshCmd` forces unsupported
        /// (we can only reason about the system ssh's single child). `extraArgs`
        /// already carries the resolved port (`-p <port>`) and the profile's
        /// `sshargs`, so `ssh -G` resolves the SAME transport Unison launches.
        case qualify(host: String, extraArgs: [String], customSshCmd: Bool)
    }

    /// Build the plan for `profile`. Mirrors `VersionCheck`'s SSH-root and
    /// sshargs/sshcmd handling so qualification reasons about the SAME transport
    /// the real connection uses (notably an `-i <key>` in `sshargs`).
    static func plan(profile: String, unisonDirectory: String) -> Plan {
        let url = URL(fileURLWithPath: unisonDirectory)
            .appendingPathComponent("\(profile).prf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .skip(reason: "couldn't read .prf at \(url.path)")
        }
        return plan(profileText: text)
    }

    /// Testable core: build the plan from raw `.prf` text. FAILS CLOSED on any
    /// uncertainty (Blocker 4): an included/sourced file may supply effective
    /// `sshargs`/`sshcmd` we cannot see here, and multiple ssh roots are an
    /// ambiguous transport — either would let `ssh -G` describe a DIFFERENT
    /// transport than the one Unison launched, so we skip rather than risk a
    /// mis-classification as direct.
    static func plan(profileText text: String) -> Plan {
        let doc = ProfileDocument.parse(text)
        // include / include? / source / source? may inject sshargs/sshcmd/host
        // aliases we can't resolve here. Do not attempt a partial resolution —
        // fail closed.
        if !doc.includes.isEmpty || doc.hasPassThroughDirectives {
            return .skip(reason: "profile has include/source directives (effective config unresolved)")
        }
        let sshRoots = doc.values(forKey: "root").compactMap(VersionCheck.SSHRoot.parse)
        // Exactly one ssh root is required. Zero → no remote transport; two or
        // more → ambiguous (remote↔remote or misconfigured), which we cannot
        // signal safely.
        guard sshRoots.count == 1, let sshRoot = sshRoots.first else {
            return .skip(reason: sshRoots.isEmpty
                         ? "no ssh:// remote root"
                         : "ambiguous transport (\(sshRoots.count) ssh roots)")
        }
        // A bare (non-absolute) sshcmd falls back to /usr/bin/ssh in the real
        // connection AND in the probe; an ABSOLUTE custom sshcmd means we are
        // not driving the system ssh, so we cannot reason about its child.
        let sshcmd = doc.firstValue(forKey: "sshcmd")
        let customSshCmd = (sshcmd?.hasPrefix("/") == true)
        // Carry the resolved PORT (dropped before would let a port-sensitive
        // `Match`/`Match exec` rule resolve to a different transport) and the
        // profile's sshargs, so `ssh -G` sees the SAME effective config the sync
        // uses. Port first, then sshargs, then the host (ssh option order).
        var extraArgs: [String] = []
        if let port = sshRoot.port { extraArgs += ["-p", String(port)] }
        extraArgs += VersionCheck.tokenizeSSHArgs(doc.firstValue(forKey: "sshargs"))
        let hostArg = sshRoot.user.map { "\($0)@\(sshRoot.host)" } ?? sshRoot.host
        return .qualify(host: hostArg, extraArgs: extraArgs, customSshCmd: customSshCmd)
    }
}
