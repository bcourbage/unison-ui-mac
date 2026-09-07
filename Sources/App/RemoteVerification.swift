import Foundation

/// Step 4 of the guided remote-profile check: run the exact remote command
/// Unison would send, with ` -version` in place of ` -server __new-rpc-mode`,
/// behind a start marker, and classify what came back by observation only.
enum RemoteVerification {

    static let markerPrefix = "unison-ui-mac-check"

    /// The remote command for the verification session: the marker is
    /// printed by the remote shell before the command line, so its presence
    /// in stdout shows the shell ran the `printf`; it says nothing about the
    /// executable that follows.
    static func remoteCommand(marker: String, versionCommand: String) -> String {
        precondition(marker.unicodeScalars.allSatisfy(ServercmdProposal.isSafe))
        return "printf '\(marker)'; \(versionCommand)"
    }

    /// The facts one session yielded, each stated separately.
    struct Observation: Equatable {
        enum Termination: Equatable {
            case exited(status: Int32)
            case deadlineExpired(seconds: Int)
            case cancelled
            /// The local ssh process could not be started.
            case launchFailed(String)
        }
        let markerReceived: Bool
        let termination: Termination
        /// Stdout after the marker (marker stripped); the whole stdout when
        /// the marker was not received.
        let stdoutAfterMarker: String
        let firstStderrLine: String?

        var firstStdoutLine: String? {
            stdoutAfterMarker.split(whereSeparator: \.isNewline).first.map(String.init)
        }
    }

    static func observe(raw: VersionCheck.RawExecResult, marker: String, deadline: TimeInterval) -> Observation {
        func split(_ stdout: String) -> (Bool, String) {
            if let range = stdout.range(of: marker) {
                return (true, String(stdout[range.upperBound...]))
            }
            return (false, stdout)
        }
        func firstLine(_ s: String) -> String? {
            s.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        switch raw {
        case .exited(let status, let stdout, let stderr):
            let (seen, rest) = split(stdout)
            return Observation(markerReceived: seen, termination: .exited(status: status),
                               stdoutAfterMarker: rest, firstStderrLine: firstLine(stderr))
        case .timedOut(let stdout, let stderr):
            let (seen, rest) = split(stdout)
            return Observation(markerReceived: seen, termination: .deadlineExpired(seconds: Int(deadline.rounded())),
                               stdoutAfterMarker: rest, firstStderrLine: firstLine(stderr))
        case .cancelled:
            return Observation(markerReceived: false, termination: .cancelled, stdoutAfterMarker: "", firstStderrLine: nil)
        case .launchFailed(let message):
            return Observation(markerReceived: false, termination: .launchFailed(message), stdoutAfterMarker: "", firstStderrLine: nil)
        }
    }

    enum Verdict: Equatable {
        /// The marker was received, the command line exited 0, and the first
        /// line after the marker is a Unison version line.
        case verified(version: String, firstLine: String)
        case notVerified
        case cancelled
    }

    static func verdict(_ o: Observation) -> Verdict {
        if case .cancelled = o.termination { return .cancelled }
        guard o.markerReceived, case .exited(0) = o.termination,
              let first = o.firstStdoutLine,
              let version = VersionCheck.parseVersionString(first) else { return .notVerified }
        return .verified(version: version, firstLine: first)
    }
}

/// Every sentence the check shows names an observation (design, Step 5).
/// The functions here are the only source of that copy.
enum RemoteCheckWording {

    static func connection(host: String, user: String?) -> String {
        if let user {
            return "ssh connected to \(host) as \(user) without prompting."
        }
        return "ssh connected to \(host) without prompting."
    }

    static func executable(_ c: RemoteDiscovery.Candidate, host: String) -> [String] {
        var out: [String] = []
        switch c.kind {
        case .symlink(let target):
            out.append("\(c.path) on \(host) is a symlink whose stored target is \(target).")
        case .regular:
            out.append("\(c.path) on \(host) is a regular file.")
        case .directory:
            out.append("\(c.path) on \(host) is a directory.")
        case .other:
            out.append("\(c.path) on \(host) exists and is neither a regular file nor a symlink.")
        }
        if let real = c.resolvedPath, real != c.path {
            out.append("Fully resolved by the remote: \(real).")
        }
        return out
    }

    static func versionPrinted(remoteCommand: String, line: String) -> String {
        "\(remoteCommand) printed \(line)."
    }

    static func identityByPath(_ path: String) -> String? {
        switch RemoteDiscovery.PathIdentity.classify(path) {
        case .unisonUIMacBundle: return "That path is inside a unison-ui-mac.app bundle (by path)."
        case .homebrewCellar: return "That path is in Homebrew's Cellar (by path)."
        case .upstreamUnisonApp: return "That path is upstream Unison.app's launcher (by path)."
        case .unknown: return nil
        }
    }

    static func pathDecidedByRemote(host: String) -> String {
        "This profile does not set servercmd, so the remote machine's PATH decides which unison runs; the check cannot see that PATH."
    }

    static func commandV(_ value: String?, host: String) -> String {
        guard let value, !value.isEmpty else {
            return "The login shell on \(host) resolved no unison on its own PATH through command -v; Unison's ssh command may resolve differently."
        }
        return "The login shell on \(host) resolves unison to \(value) through command -v; Unison's ssh command may resolve differently."
    }

    static func protocolBoundary(local: String, remote: String, host: String) -> String {
        switch VersionCheck.classify(local: local, remote: remote) {
        case .exactMatch, .compatibleNewProtocol, .compatibleOldProtocol:
            return "\(local) (this Mac) and \(remote) (\(host)) are on the same side of the 2.52 boundary."
        case .incompatibleAcrossBoundary:
            return "\(local) (this Mac) and \(remote) (\(host)) are on opposite sides of the 2.52 boundary and cannot connect."
        }
    }

    static let executionStatusUnknown = "Execution status is unknown."
    static let promptNote = "A synchronization may still connect if it can answer a prompt; this check cannot."
    static let closingAfterVersion = "The command started over ssh and reported its version. Only a synchronization confirms the server protocol; run the profile to test that."
    static let closingAfterFailure = "This check did not verify the remote command. What it observed is above."
    static let cancelled = "The check was cancelled before the session finished."

    /// The sentences for a session that did not verify the command, from the
    /// observation alone plus, for status 127, what discovery recorded about
    /// the effective executable path.
    static func failure(_ o: RemoteVerification.Observation,
                        executablePath: String?,
                        discovery: RemoteDiscovery.Record?) -> [String] {
        var out: [String] = []
        let stderr = o.firstStderrLine.map { "\($0)" } ?? "no stderr"
        switch (o.markerReceived, o.termination) {
        case (_, .cancelled):
            out.append(cancelled)
            return out
        case (_, .launchFailed(let message)):
            out.append("The local ssh command could not be started: \(message).")
            out.append(executionStatusUnknown)
        case (false, .exited(let status)):
            out.append("No start marker was received before ssh exited (status \(status), \(stderr)).")
            out.append(executionStatusUnknown)
            out.append(promptNote)
        case (false, .deadlineExpired(let t)):
            out.append("No start marker was received before the \(t)-second deadline.")
            out.append(executionStatusUnknown)
            out.append(promptNote)
        case (true, .deadlineExpired(let t)):
            out.append("The remote shell emitted the start marker; the \(t)-second deadline expired. Output received so far: \(o.stdoutAfterMarker.isEmpty ? "nothing" : o.stdoutAfterMarker.trimmingCharacters(in: .whitespacesAndNewlines)). Whether the executable started is not established.")
        case (true, .exited(let status)) where status != 0:
            out.append("The remote shell emitted the start marker; the command line then exited with status \(status); stderr: \(stderr).")
            if status == 127, let path = executablePath, let discovery {
                if discovery.candidate(at: path) != nil {
                    out.append("During discovery a file was found at \(path); status 127 with this stderr can also mean a dependency of that file is missing.")
                } else if discovery.wasAbsent(path) {
                    out.append("During discovery no file was found at \(path).")
                }
            }
        case (true, .exited):
            let first = o.firstStdoutLine ?? ""
            out.append("The remote shell emitted the start marker; the command line printed \(first.isEmpty ? "nothing" : first), which is not a Unison version line.")
        }
        out.append(closingAfterFailure)
        return out
    }
}
