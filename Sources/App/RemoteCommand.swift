import Foundation

/// Root parsing as `src/clroot.ml` does it (upstream v2.54.0, commit
/// 91421d0): `parseUri` splits `[protocol:]//[user@][host][:port][/path]`
/// with upstream's regular expressions, and `parseRoot` maps the parts to a
/// local, shell (ssh) or socket connection or raises upstream's error.
enum UnisonRoot: Equatable {
    /// `ConnectLocal`. A `file://host/path` root is local with a `//host/`
    /// prefix, as upstream builds it.
    case local(String?)
    /// `ConnectByShell (shell, host, user, port, path)`; `shell` is "ssh".
    case shell(shell: String, host: String, user: String?, port: String?, path: String?)
    /// `ConnectBySocket (host, port, path)`; `port` is "" for a Unix domain
    /// socket given as `{path}`.
    case socket(host: String, port: String, path: String?)

    var isRemote: Bool {
        if case .local = self { return false }
        return true
    }

    /// True only for an ssh (`ConnectByShell`) root. A socket root is remote but
    /// runs no ssh command, so the remote-command check does not apply to it.
    var isSSH: Bool {
        if case .shell = self { return true }
        return false
    }

    /// Upstream raises three exception types here; `uicommon.ml` catches all
    /// three and prefixes "There's a problem with one of the roots:\n".
    enum ParseError: Error, Equatable {
        case invalidArgument(String)
        case fatal(String)
        case illegalValue(String)

        var message: String {
            switch self {
            case .invalidArgument(let s), .fatal(let s), .illegalValue(let s): return s
            }
        }
    }

    private enum Transport { case file, socket, ssh }

    /// `Clroot.parseRoot`.
    static func parse(_ string: String) throws -> UnisonRoot {
        let (proto, user, host, port, path) = try parseUri(string)
        func illegal2(_ s: String) -> ParseError { .illegalValue("\"\(string)\": \(s)") }
        switch (proto, user, host, port) {
        case (_, _, nil, .some), (_, .some, nil, nil), (.socket, _, nil, nil), (.ssh, _, nil, _):
            throw illegal2("missing host")
        case (.file, _, _, .some):
            throw illegal2("ill-formed (cannot use a port number with file)")
        case (.file, _, .some(let h), nil):
            let prefix = "//\(h)/"
            return .local(path.map { prefix + $0 } ?? prefix)
        case (.file, nil, nil, nil):
            return .local(path)
        case (.socket, nil, .some(let h), .some(let p)) where !h.hasPrefix("{"):
            return .socket(host: h, port: p, path: path)
        case (.socket, nil, .some(let h), nil) where h.hasPrefix("{"):
            return .socket(host: h, port: "", path: path)
        case (.socket, .some, _, _):
            throw illegal2("ill-formed (cannot use a user with socket)")
        case (.socket, _, _, nil):
            throw illegal2("ill-formed (must give a port number with socket)")
        case (.socket, _, .some, .some):
            throw illegal2("ill-formed (must not give a port number with Unix domain socket)")
        case (.ssh, _, .some(let h), _):
            return .shell(shell: "ssh", host: h, user: user, port: port, path: path)
        }
    }

    // MARK: - parseUri

    private static func parseUri(_ raw: String)
        throws -> (Transport, String?, String?, String?, String?)
    {
        let s = EffectiveProfile.trimWhitespace(raw)
        guard let (proto, s0) = try protocolSlashSlash(s) else {
            return (.file, nil, nil, nil, s)
        }
        let (user, s1) = getUser(s0)
        let (host, s2) = getHost(s1)
        let (port, s3) = getPort(s2)
        let path: String?
        if s3.isEmpty {
            path = nil
        } else if s3.hasPrefix("/") {
            path = s3.count == 1 ? nil : String(s3.dropFirst())
        } else {
            throw ParseError.fatal("ill-formed root specification \(s)")
        }
        return (proto, user, host, port, path)
    }

    /// `getProtocolSlashSlash`: `[a-zA-Z]+://` → protocol and remainder;
    /// `//` → file; `[a-zA-Z]+:` without `//` → fatal for the three known
    /// protocol names, otherwise not a URI.
    private static func protocolSlashSlash(_ s: String) throws -> (Transport, String)? {
        let letters = s.unicodeScalars.prefix { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") }
        let rest = s.unicodeScalars.dropFirst(letters.count)
        if !letters.isEmpty, String(rest).hasPrefix("://") {
            let name = String(letters)
            let remainder = String(String.UnicodeScalarView(rest.dropFirst(3)))
            switch name {
            case "file": return (.file, remainder)
            case "socket": return (.socket, remainder)
            case "ssh": return (.ssh, remainder)
            case "rsh":
                throw ParseError.invalidArgument(
                    "protocol rsh has been deprecated, use ssh instead (optionally specifying a different sshcmd preference)")
            case "unison":
                throw ParseError.invalidArgument(
                    "protocol unison has been deprecated, use file, ssh, or socket instead")
            default:
                throw ParseError.invalidArgument("\"\(s)\": unrecognized protocol \(name)")
            }
        }
        if s.hasPrefix("//") {
            return (.file, String(s.dropFirst(2)))
        }
        if !letters.isEmpty, String(rest).hasPrefix(":") {
            let matched = String(letters) + ":"
            if ["file:", "ssh:", "socket:"].contains(matched) {
                throw ParseError.fatal(
                    "ill-formed root specification \"\(s)\" (\(matched) must be followed by //)")
            }
        }
        return nil
    }

    /// `userAtRegexp = "[-_a-zA-Z0-9.%@]+@"`, matched at the start. The class
    /// contains `@`, so the greedy match ends at the LAST `@` preceded only by
    /// class characters.
    private static func getUser(_ s: String) -> (String?, String) {
        let userClass: (Unicode.Scalar) -> Bool = {
            $0 == "-" || $0 == "_" || $0 == "." || $0 == "%" || $0 == "@"
                || ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
        }
        let run = s.unicodeScalars.prefix(while: userClass)
        // Backtrack to the last `@` inside the run; at least one class char
        // must precede it.
        guard let at = Array(run).lastIndex(of: "@"), at >= 1 else { return (nil, s) }
        let runArray = Array(run)
        let user = String(String.UnicodeScalarView(runArray[..<at]))
        let after = String(String.UnicodeScalarView(s.unicodeScalars.dropFirst(at + 1)))
        return (user, after)
    }

    /// `hostRegexp = "[-_a-zA-Z0-9%.]+\|{[^}]+}\|\[\(ipv6\)\]"`, matched at
    /// the start; for the bracketed IPv6 form the host is the inside.
    private static func getHost(_ s: String) -> (String?, String) {
        let scalars = Array(s.unicodeScalars)
        let plain: (Unicode.Scalar) -> Bool = {
            $0 == "-" || $0 == "_" || $0 == "%" || $0 == "."
                || ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
        }
        if let first = scalars.first, plain(first) {
            let run = scalars.prefix(while: plain)
            return (String(String.UnicodeScalarView(run)),
                    String(String.UnicodeScalarView(scalars[run.count...])))
        }
        if scalars.first == "{", let close = scalars.firstIndex(of: "}"), close > 1 {
            return (String(String.UnicodeScalarView(scalars[...close])),
                    String(String.UnicodeScalarView(scalars[(close + 1)...])))
        }
        if scalars.first == "[" {
            // [a-f0-9:.]+ optionally followed by %zone, then `]`.
            let ipv6: (Unicode.Scalar) -> Bool = {
                $0 == ":" || $0 == "." || ($0 >= "a" && $0 <= "f") || ($0 >= "0" && $0 <= "9")
            }
            var i = 1
            while i < scalars.count, ipv6(scalars[i]) { i += 1 }
            guard i > 1 else { return (nil, s) }
            if i < scalars.count, scalars[i] == "%" {
                let zone: (Unicode.Scalar) -> Bool = {
                    $0 == "-" || $0 == "_" || $0 == "~" || $0 == "%" || $0 == "."
                        || ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
                }
                var j = i + 1
                while j < scalars.count, zone(scalars[j]) { j += 1 }
                if j > i + 1 { i = j }
            }
            guard i < scalars.count, scalars[i] == "]" else { return (nil, s) }
            return (String(String.UnicodeScalarView(scalars[1..<i])),
                    String(String.UnicodeScalarView(scalars[(i + 1)...])))
        }
        return (nil, s)
    }

    /// `colonPortRegexp = ":[^/]+"`, matched at the start.
    private static func getPort(_ s: String) -> (String?, String) {
        guard s.hasPrefix(":") else { return (nil, s) }
        let after = s.unicodeScalars.dropFirst()
        let run = after.prefix { $0 != "/" }
        guard !run.isEmpty else { return (nil, s) }
        return (String(String.UnicodeScalarView(run)),
                String(String.UnicodeScalarView(after.dropFirst(run.count))))
    }
}

/// Upstream's rules about how many roots a profile may have and how many of
/// them may be remote, applied before any ssh session (`src/globals.ml`
/// `wrongNumRootsExn`; `src/uicommon.ml` lines 1100 ff.).
enum RootRules {

    enum NotApplicable: Equatable {
        /// Both roots are local; there is no remote command to check.
        case noRemoteRoot
        /// The single remote root uses `socket://`; Unison runs no remote
        /// command for it.
        case socketRoot
    }

    enum Outcome: Equatable {
        /// Exactly one ssh root; the check applies to it.
        case ssh(remote: UnisonRoot, local: UnisonRoot)
        case notApplicable(NotApplicable)
    }

    enum Failure: Error, Equatable {
        /// Unison would stop with this message.
        case fatal(String)
    }

    /// `Wrong number of roots` text, exactly as `globals.ml` formats it.
    static func wrongNumberOfRoots(_ roots: [String]) -> String {
        "Wrong number of roots: 2 expected, but \(roots.count) provided (\(roots.joined(separator: ", ")))\n"
        + "(Maybe you specified roots both on the command line and in the profile?)"
    }

    static let moreThanOneRemote = "cannot synchronize more than one remote root"

    /// Evaluate the raw `root` values in profile order, in upstream's order
    /// of checks: every root is parsed first (`Globals.parsedClRawRoots`; a
    /// failure carries `uicommon.ml`'s prefix), then the number of remote
    /// roots is checked (`uicommon.ml`), then the count
    /// (`Recon.checkThatPreferredRootIsValid` → `Globals.rawRootPair`). A
    /// profile with three roots of which two are remote therefore stops with
    /// "cannot synchronize more than one remote root", not "Wrong number of
    /// roots".
    static func evaluate(roots: [String]) -> Result<Outcome, Failure> {
        var parsed: [UnisonRoot] = []
        for r in roots {
            do {
                parsed.append(try UnisonRoot.parse(r))
            } catch let e as UnisonRoot.ParseError {
                return .failure(.fatal("There's a problem with one of the roots:\n\(e.message)"))
            } catch {
                return .failure(.fatal("There's a problem with one of the roots:\n\(error)"))
            }
        }
        let remote = parsed.filter(\.isRemote)
        if remote.count > 1 {
            return .failure(.fatal(moreThanOneRemote))
        }
        guard parsed.count == 2 else {
            return .failure(.fatal(wrongNumberOfRoots(roots)))
        }
        guard let theRemote = remote.first else {
            return .success(.notApplicable(.noRemoteRoot))
        }
        let local = parsed.first { !$0.isRemote }!
        switch theRemote {
        case .socket:
            return .success(.notApplicable(.socketRoot))
        case .shell:
            return .success(.ssh(remote: theRemote, local: local))
        case .local:
            return .success(.notApplicable(.noRemoteRoot))
        }
    }
}

/// The settings `buildShellConnection` reads, with upstream's defaults.
struct RemoteSettings: Equatable {
    var servercmd: String = ""
    var sshcmd: String = "ssh"
    var sshargs: String = ""
    var addversionno: Bool = false

    init(servercmd: String = "", sshcmd: String = "ssh", sshargs: String = "", addversionno: Bool = false) {
        self.servercmd = servercmd
        self.sshcmd = sshcmd
        self.sshargs = sshargs
        self.addversionno = addversionno
    }

    /// Effective values from a loaded profile (last assignment wins).
    init(profile: EffectiveProfile) {
        servercmd = profile.scalar("servercmd")?.value ?? ""
        sshcmd = profile.scalar("sshcmd")?.value ?? "ssh"
        sshargs = profile.scalar("sshargs")?.value ?? ""
        addversionno = profile.bool("addversionno") ?? false
    }
}

/// The command line Unison builds for an ssh root, as `buildShellConnection`
/// in `src/remote.ml` (lines 1811 ff.) builds it:
///
///     <sshcmd> [-l user] [-p port] <host> -e none <sshargs…> <servercmd|unison>[-<major>] -server __new-rpc-mode
///
/// Every piece after the ssh command is split into words with
/// `PrefsTokenizer` before becoming a separate `execv` argument. OpenSSH then
/// joins everything after the destination with single spaces and hands that
/// string to the remote login shell.
struct RemoteCommand: Equatable {

    static let rpcServerCmdlineOverride = "__new-rpc-mode"
    static let defaultServerName = "unison"

    /// The ssh executable (the `sshcmd` setting).
    let shellCommand: String
    /// The `execv` arguments after the ssh command, exactly as upstream
    /// builds them.
    let upstreamArguments: [String]
    /// The words of `<servercmd>[-<major>] -server __new-rpc-mode` after
    /// tokenizing. The remote shell receives them joined by single spaces.
    let remoteCommandWords: [String]
    /// The words that name the remote executable (the remote command without
    /// `-server __new-rpc-mode`); `-version` appended is what the check runs.
    let remoteExecutableWords: [String]
    let host: String
    let user: String?
    let port: String?
    let sshargsWords: [String]

    /// The string Unison's `-server` request becomes on the remote shell.
    var remoteCommandString: String { PrefsTokenizer.joinedForRemoteShell(remoteCommandWords) }

    /// The remote command the check runs instead: the same executable words
    /// with ` -version` in place of ` -server __new-rpc-mode`.
    var versionCommandString: String {
        PrefsTokenizer.joinedForRemoteShell(remoteExecutableWords + ["-version"])
    }

    /// Compose for one ssh root. `majorVersion` is the engine's
    /// `Uutil.myMajorVersion` ("2.54").
    static func compose(settings: RemoteSettings, root: UnisonRoot, majorVersion: String) -> RemoteCommand? {
        guard case let .shell(shell, host, user, port, _) = root else { return nil }
        let serverName = settings.servercmd.isEmpty ? defaultServerName : settings.servercmd
        let remoteCmd = serverName
            + (settings.addversionno ? "-" + majorVersion : "")
            + " -server " + rpcServerCmdlineOverride
        let shellCmd = shell == "ssh" ? settings.sshcmd : shell
        let shellCmdArgs = shell == "ssh" ? settings.sshargs : ""
        var preargs: [String] = []
        if let user { preargs += ["-l", user] }
        if let port { preargs += ["-p", port] }
        preargs.append(host)
        if shell == "ssh" { preargs.append("-e none") }
        preargs += [shellCmdArgs, remoteCmd]
        let args = preargs.flatMap { PrefsTokenizer.splitIntoWords($0) }
        let executableWords = PrefsTokenizer.splitIntoWords(
            serverName + (settings.addversionno ? "-" + majorVersion : ""))
        return RemoteCommand(shellCommand: shellCmd,
                             upstreamArguments: args,
                             remoteCommandWords: PrefsTokenizer.splitIntoWords(remoteCmd),
                             remoteExecutableWords: executableWords,
                             host: host, user: user, port: port,
                             sshargsWords: PrefsTokenizer.splitIntoWords(shellCmdArgs))
    }

    /// The check's own `ssh` argument vector: upstream's order with the
    /// non-interactive options inserted first, and `remoteCommand` (one
    /// string, already composed by the caller) as the final argument.
    ///
    ///     -o BatchMode=yes -o ConnectTimeout=<t> -o StrictHostKeyChecking=yes [-l user] [-p port] <host> -e none <sshargs…> <remoteCommand>
    func checkArguments(connectTimeout: Int, remoteCommand: String) -> [String] {
        var args = ["-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=\(connectTimeout)",
                    "-o", "StrictHostKeyChecking=yes"]
        if let user { args += ["-l", user] }
        if let port { args += ["-p", port] }
        args.append(host)
        args += ["-e", "none"]
        args += sshargsWords
        args.append(remoteCommand)
        return args
    }

    /// `Uutil.myMajorVersion` from the engine's version string
    /// ("2.54.0 (ocaml 5.5.0)" → "2.54"): the first two dotted components.
    static func majorVersion(fromEngineVersion version: String) -> String? {
        let firstToken = version.split(separator: " ").first.map(String.init) ?? version
        let parts = firstToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber),
              !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0]).\(parts[1])"
    }
}

/// Composition of a proposed `servercmd` from a selected remote executable.
enum ServercmdProposal {

    /// Characters a proposed path may contain: `A–Z a–z 0–9 . _ / + -`.
    /// Anything else, whitespace included, would need quoting that neither
    /// upstream's tokenizer nor ssh's single-space join can carry reliably
    /// to the remote shell.
    static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
            || (scalar >= "0" && scalar <= "9")
            || scalar == "." || scalar == "_" || scalar == "/" || scalar == "+" || scalar == "-"
    }

    struct Proposal: Equatable {
        /// The value to write for `servercmd`.
        let servercmd: String
        /// Whether `addversionno = false` must be written as well, because
        /// the effective value is `true` and the selected path does not end
        /// in `-<major>`.
        let setsAddversionnoFalse: Bool
    }

    enum Refusal: Error, Equatable {
        /// The path contains characters outside the safe set (listed, in
        /// order of first appearance, without duplicates).
        case unsafeCharacters([String])
        /// Candidates are absolute paths; anything else is not proposed.
        case notAbsolute
    }

    /// Compose a proposal for `selectedPath` given the profile's effective
    /// `addversionno` and the engine's major version.
    static func compose(selectedPath: String, addversionno: Bool, majorVersion: String) -> Result<Proposal, Refusal> {
        guard selectedPath.hasPrefix("/") else { return .failure(.notAbsolute) }
        var unsafe: [String] = []
        for scalar in selectedPath.unicodeScalars where !isSafe(scalar) {
            let s = String(scalar)
            if !unsafe.contains(s) { unsafe.append(s) }
        }
        guard unsafe.isEmpty else { return .failure(.unsafeCharacters(unsafe)) }
        guard addversionno else {
            return .success(Proposal(servercmd: selectedPath, setsAddversionnoFalse: false))
        }
        let suffix = "-" + majorVersion
        if selectedPath.hasSuffix(suffix), selectedPath.count > suffix.count {
            return .success(Proposal(servercmd: String(selectedPath.dropLast(suffix.count)),
                                     setsAddversionnoFalse: false))
        }
        return .success(Proposal(servercmd: selectedPath, setsAddversionnoFalse: true))
    }
}
