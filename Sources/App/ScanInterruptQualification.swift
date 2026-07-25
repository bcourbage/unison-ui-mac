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
        /// logging only.
        case skip(reason: String)
        /// Run `ssh -G host <extraArgs>`; `customSshCmd` forces unsupported
        /// (we can only reason about the system ssh's single child).
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

    /// Testable core: build the plan from raw `.prf` text.
    static func plan(profileText text: String) -> Plan {
        let doc = ProfileDocument.parse(text)
        let roots = doc.values(forKey: "root")
        guard let sshRoot = roots.compactMap(VersionCheck.SSHRoot.parse).first else {
            return .skip(reason: "no ssh:// remote root")
        }
        // A bare (non-absolute) sshcmd falls back to /usr/bin/ssh in the real
        // connection AND in the probe; an ABSOLUTE custom sshcmd means we are
        // not driving the system ssh, so we cannot reason about its child.
        let sshcmd = doc.firstValue(forKey: "sshcmd")
        let customSshCmd = (sshcmd?.hasPrefix("/") == true)
        // Pass the profile's sshargs through so `ssh -G` resolves the same
        // effective config (host aliases, -i, -o overrides) the sync will use.
        let extraArgs = VersionCheck.tokenizeSSHArgs(doc.firstValue(forKey: "sshargs"))
        let hostArg = sshRoot.user.map { "\($0)@\(sshRoot.host)" } ?? sshRoot.host
        return .qualify(host: hostArg, extraArgs: extraArgs, customSshCmd: customSshCmd)
    }
}
