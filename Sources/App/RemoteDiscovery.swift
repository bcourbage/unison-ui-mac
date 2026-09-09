import Foundation

/// Step 2 of the guided remote-profile check: one ssh session that runs a
/// single POSIX `sh` command and prints, between unique markers, the remote
/// OS name, what exists at each candidate path (stored link target, resolved
/// path when the remote can resolve it, first `-version` line), and what the
/// discovery script's `sh` resolves through `command -v unison` (not what the
/// remote login shell would, which may use aliases or functions). Nothing is written on
/// the remote.
enum RemoteDiscovery {

    /// Paths probed on every remote in addition to the profile's effective
    /// executable.
    static let wellKnownCandidates = [
        "/opt/homebrew/bin/unison",
        "/usr/local/bin/unison",
        "/Applications/unison-ui-mac.app/Contents/SharedSupport/bin/unison",
        "/Applications/unison-ui-mac.app/Contents/MacOS/cltool",
        "/Applications/Unison.app/Contents/MacOS/cltool",
        "/usr/bin/unison",
    ]

    /// Which paths the discovery session will probe, and which effective
    /// executable it could not include.
    struct Plan: Equatable {
        /// Absolute, safe-character paths in probe order, de-duplicated.
        let candidatePaths: [String]
        /// The effective executable word when it is not probed: a bare name
        /// (resolved by the remote PATH, reported through `command -v`) or a
        /// path with characters outside the safe set.
        let unprobedExecutable: Unprobed?

        enum Unprobed: Equatable {
            case bareName(String)
            case unsafePath(String)
        }
    }

    /// Decide what to probe for the profile's effective executable word (the
    /// first word of the remote command, `servercmd` or `unison`, with any
    /// `-<major>` suffix applied).
    static func plan(effectiveExecutable: String) -> Plan {
        var paths: [String] = []
        var unprobed: Plan.Unprobed?
        if !effectiveExecutable.hasPrefix("/") {
            unprobed = .bareName(effectiveExecutable)
        } else if effectiveExecutable.unicodeScalars.allSatisfy(ServercmdProposal.isSafe) {
            paths.append(effectiveExecutable)
        } else {
            unprobed = .unsafePath(effectiveExecutable)
        }
        for p in wellKnownCandidates where !paths.contains(p) { paths.append(p) }
        return Plan(candidatePaths: paths, unprobedExecutable: unprobed)
    }

    /// The remote command: `sh -c '<script>'`. The script contains no single
    /// quote, so the remote login shell (sh, bash, zsh, csh, fish) hands it
    /// to `sh` unchanged. Candidate paths contain safe characters only and
    /// are embedded unquoted in the `for` list; the marker likewise.
    static func remoteCommand(marker: String, plan: Plan) -> String {
        precondition(marker.unicodeScalars.allSatisfy(ServercmdProposal.isSafe))
        precondition(plan.candidatePaths.allSatisfy { $0.unicodeScalars.allSatisfy(ServercmdProposal.isSafe) })
        let list = plan.candidatePaths.joined(separator: " ")
        // The reporting body, as a function so both the fixed-candidate loop and
        // the PATH scan use it. `$p` present → path/kind/real/version; absent →
        // one `absent:` line.
        let probe = [
            "probe() { p=\"$1\"",
            "if [ -e \"$p\" ] || [ -L \"$p\" ]; then echo \"path: $p\"",
            "if [ -L \"$p\" ]; then echo \"link: $(readlink \"$p\")\"; elif [ -f \"$p\" ]; then echo \"kind: regular\"; elif [ -d \"$p\" ]; then echo \"kind: directory\"; else echo \"kind: other\"; fi",
            "if command -v realpath >/dev/null 2>&1; then echo \"real: $(realpath \"$p\" 2>/dev/null)\"; elif readlink -f \"$p\" >/dev/null 2>&1; then echo \"real: $(readlink -f \"$p\")\"; fi",
            "if [ -x \"$p\" ] && [ ! -d \"$p\" ]; then echo \"version: $(\"$p\" -version 2>&1 | head -n 1)\"; fi",
            "else echo \"absent: $p\"; fi; }",
        ].joined(separator: "; ")
        // The PATH scan finds a `unison` in any directory of the non-interactive
        // shell's PATH — the same environment Unison's own remote `unison`
        // resolves in — that the fixed list missed. `seen` (the fixed paths,
        // then each PATH hit) keeps a path from being reported twice. `$q` is a
        // runtime value, always quoted, so a PATH directory with a space is safe.
        let pathScan = [
            "seen=\" \(list) \"",
            // `set -f` keeps a PATH directory spelled with glob characters (e.g.
            // `[ab]`) literal instead of expanding it to sibling names; an empty
            // PATH component means the current directory, as `command -v` reads it.
            "oldIFS=$IFS; IFS=:; set -f",
            "for d in $PATH; do case \"$d\" in \"\") dd=. ;; *) dd=\"$d\" ;; esac; q=\"$dd/unison\"; case \"$seen\" in *\" $q \"*) ;; *) if [ -x \"$q\" ] && [ ! -d \"$q\" ]; then probe \"$q\"; seen=\"$seen$q \"; fi ;; esac; done",
            // Word splitting drops a trailing empty field, so a PATH ending in
            // `:` (a trailing current-directory component, which command -v honors)
            // is never seen by the loop; probe the current directory for it.
            "case \"$PATH\" in *:) q=\"./unison\"; case \"$seen\" in *\" $q \"*) ;; *) if [ -x \"$q\" ] && [ ! -d \"$q\" ]; then probe \"$q\"; seen=\"$seen$q \"; fi ;; esac ;; esac",
            "IFS=$oldIFS; set +f",
        ].joined(separator: "; ")
        let script = [
            "M=\(marker)",
            "echo \"$M BEGIN\"",
            "echo \"uname: $(uname -s 2>/dev/null)\"",
            probe,
            "for p in \(list); do probe \"$p\"; done",
            pathScan,
            "echo \"commandv: $(command -v unison 2>/dev/null)\"",
            "echo \"$M END\"",
        ].joined(separator: "; ")
        return "sh -c '\(script)'"
    }

    /// What discovery observed about one candidate path.
    struct Candidate: Equatable {
        enum Kind: Equatable {
            case symlink(storedTarget: String)
            case regular
            case directory
            case other
        }
        let path: String
        let kind: Kind
        /// `realpath`/`readlink -f` output when the remote had one of them.
        let resolvedPath: String?
        /// First line of `<path> -version` (stdout and stderr merged), when
        /// the path was executable and not a directory.
        let versionLine: String?
    }

    /// The parsed record of one discovery session.
    struct Record: Equatable {
        /// Both markers were seen; the record is complete.
        let complete: Bool
        let uname: String?
        let present: [Candidate]
        let absent: [String]
        /// What `command -v unison` printed inside the discovery `sh` (empty
        /// when nothing), or nil when the line was not received.
        let commandV: String?

        func candidate(at path: String) -> Candidate? { present.first { $0.path == path } }
        func wasAbsent(_ path: String) -> Bool { absent.contains(path) }
    }

    /// Parse stdout of the discovery session. Lines outside the markers
    /// (login banners, MOTD) are ignored.
    static func parse(stdout: String, marker: String) -> Record {
        var inside = false
        var complete = false
        var uname: String?
        var present: [Candidate] = []
        var absent: [String] = []
        var commandV: String?
        var current: (path: String, kind: Candidate.Kind?, real: String?, version: String?)?

        func flush() {
            if let c = current {
                present.append(Candidate(path: c.path, kind: c.kind ?? .other,
                                         resolvedPath: c.real, versionLine: c.version))
            }
            current = nil
        }
        // Scalar-level split: Swift folds CR LF into one Character, so a
        // Character split on "\n" would keep CRLF lines unbroken.
        for rawLine in EffectiveProfile.rawLines(of: stdout) {
            let line = EffectiveProfile.removeTrailingCR(rawLine)
            if line == "\(marker) BEGIN" { inside = true; continue }
            if line == "\(marker) END" { flush(); complete = inside; inside = false; continue }
            guard inside else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch key {
            case "uname": uname = value
            case "path": flush(); current = (value, nil, nil, nil)
            case "link": current?.kind = .symlink(storedTarget: value)
            case "kind":
                switch value {
                case "regular": current?.kind = .regular
                case "directory": current?.kind = .directory
                default: current?.kind = .other
                }
            case "real": current?.real = value.isEmpty ? nil : value
            case "version": current?.version = value
            case "absent": flush(); absent.append(value)
            case "commandv": flush(); commandV = value
            default: break
            }
        }
        if inside { flush() }
        return Record(complete: complete, uname: uname, present: present, absent: absent, commandV: commandV)
    }

    /// Identity of an executable by the text of its path alone (the remote
    /// bundle is not inspected).
    enum PathIdentity: Equatable {
        case unisonUIMacBundle
        case homebrewCellar
        case upstreamUnisonApp
        case unknown

        static func classify(_ path: String) -> PathIdentity {
            if path.contains("/unison-ui-mac.app/") { return .unisonUIMacBundle }
            if path.contains("/Cellar/") { return .homebrewCellar }
            if path.contains("/Unison.app/") { return .upstreamUnisonApp }
            return .unknown
        }
    }
}
