import Foundation

/// The line protocol and the accept/refuse decision for routing a graphical
/// profile request to an already-running instance (req 5 of #122). Everything
/// here is pure and I/O-free; `CommandLineHandoffSocket` carries it over a
/// per-user Unix-domain socket, and `AppDelegate` supplies the live activity
/// state. Only graphical profile requests use this path: `-ui text` and
/// `-server` run in the engine and exit before ever reaching it.
///
/// Wire format is one newline-terminated line each way, so a partial read is
/// always detectable (no terminating newline means a lost or truncated reply):
///
///   request:   `open\t<rootsSet>\t<sessionArgs>\t<unisonDir b64>\t<install b64>\t<given b64>\n`
///   response:  `ok\n` | `refuse\t<message>\n` | `invalid\t<message>\n`
///
/// The variable-length fields are base64, so a directory, path or profile name
/// with a tab or other whitespace round-trips unambiguously. They carry supported
/// UTF-8 strings; a decoded field containing a NUL is rejected (it would truncate
/// at the C string boundary the args and profile name cross). `sessionArgs` is a
/// comma-separated list of base64-encoded tokens (empty when the request carried
/// no session options); comma is not in the base64 alphabet, so each token
/// round-trips unambiguously.
enum CommandLineHandoff {

    /// A client's request to open a profile in the running instance. It carries
    /// enough context for the primary to confirm the request would open the same
    /// thing the caller meant, and to refuse rather than silently do something
    /// different (finding 1): the caller's Unison directory, the app installation
    /// it came from, and whether the invocation was a plain profile open.
    struct Request: Equatable {
        /// The profile string exactly as the engine parsed it (upstream has
        /// already checked the named file exists); the primary re-validates it
        /// against its own directory so validation happens where the open does.
        var given: String
        /// `unison_bridge_command_line_roots_set()`: 0 none, 1 present, else
        /// undetermined. Forwarded so the primary applies the same refusal for
        /// roots as a fresh launch would.
        var rootsSet: Int
        /// The caller's resolved Unison directory. The primary refuses when it
        /// differs from its own, so `UNISON=/other unison work` cannot open the
        /// running app's unrelated `work`.
        var unisonDirectory: String
        /// The caller's app bundle path. The primary refuses when it differs from
        /// its own, so a request from a separate copy of the app is not served by
        /// an unrelated installation.
        var installationPath: String
        /// The caller's own session-scoped command-line options (`-path`,
        /// `-ignore`, `-include`, …), extracted by the engine on the caller side
        /// (patch 0009) in order. Empty for a plain profile open. The primary
        /// applies these to the opened session as explicit overrides, exactly as
        /// a fresh launch of the same command line would (they no longer force a
        /// refusal).
        var sessionArgs: [String]

        static let verb = "open"

        private static func encodeArgs(_ args: [String]) -> String {
            args.map { Data($0.utf8).base64EncodedString() }.joined(separator: ",")
        }
        private static func decodeArgs(_ field: String) -> [String]? {
            if field.isEmpty { return [] }
            var out: [String] = []
            for tok in field.split(separator: ",", omittingEmptySubsequences: false) {
                guard let s = decodeBase64(String(tok)) else { return nil }
                out.append(s)
            }
            return out
        }

        func encoded() -> String? {
            let dir = Data(unisonDirectory.utf8).base64EncodedString()
            let install = Data(installationPath.utf8).base64EncodedString()
            let name = Data(given.utf8).base64EncodedString()
            let args = Request.encodeArgs(sessionArgs)
            return "\(Request.verb)\t\(rootsSet)\t\(args)\t\(dir)\t\(install)\t\(name)\n"
        }

        /// Parse a request line (with or without the trailing newline). nil on
        /// any malformed line, so the primary refuses rather than guesses.
        init?(line: String) {
            let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let parts = body.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 6, parts[0] == Request.verb,
                  let roots = Int(parts[1]),
                  let args = Self.decodeArgs(String(parts[2])),
                  let dir = Self.decodeBase64(String(parts[3])),
                  let install = Self.decodeBase64(String(parts[4])),
                  let name = Self.decodeBase64(String(parts[5]))
            else { return nil }
            self.given = name
            self.rootsSet = roots
            self.unisonDirectory = dir
            self.installationPath = install
            self.sessionArgs = args
        }

        init(given: String, rootsSet: Int, unisonDirectory: String,
             installationPath: String, sessionArgs: [String]) {
            self.given = given
            self.rootsSet = rootsSet
            self.unisonDirectory = unisonDirectory
            self.installationPath = installationPath
            self.sessionArgs = sessionArgs
        }

        private static func decodeBase64(_ s: String) -> String? {
            guard let data = Data(base64Encoded: s),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            // An embedded NUL survives Swift decoding but truncates at the C
            // string boundary (the engine args and profile name cross it), so the
            // receiver would act on a different value than it accepted. Reject the
            // whole line rather than open something the caller did not send.
            if str.utf8.contains(0) { return nil }
            return str
        }
    }

    /// The wire line is the request preceded by the caller's absolute deadline
    /// (`mach_absolute_time` nanoseconds), so the primary checks the CALLER's
    /// expiry — not a deadline that would restart when the request is finally
    /// accepted. The deadline is transport metadata, kept out of `Request` so the
    /// request's identity does not depend on when it was sent.
    static func encodeEnvelope(_ request: Request, deadlineUptimeNanos: UInt64) -> String? {
        guard let body = request.encoded() else { return nil }
        return "\(deadlineUptimeNanos)\t" + body
    }

    /// Parse a wire line into the caller's deadline and the request. nil on any
    /// malformed line, so the primary drops it rather than guessing.
    static func decodeEnvelope(_ line: String) -> (deadlineUptimeNanos: UInt64, request: Request)? {
        guard let tab = line.firstIndex(of: "\t"),
              let nanos = UInt64(line[line.startIndex..<tab]) else { return nil }
        let rest = String(line[line.index(after: tab)...])
        guard let request = Request(line: rest) else { return nil }
        return (nanos, request)
    }

    /// The primary's verdict, sent back to the client.
    enum Response: Equatable {
        /// Accepted: the primary is opening the profile and starting its scan.
        case started
        /// The instance is busy (a scan, reconciliation, sync, or an open
        /// profile edit); the existing work is preserved and this request is not.
        case refused(message: String)
        /// The request itself is not valid or transferable here (roots, a hidden
        /// or ambiguous profile, or a different app installation / Unison
        /// directory); it would not start a different profile.
        case invalid(message: String)

        func encoded() -> String {
            switch self {
            case .started: return "ok\n"
            case .refused(let m): return "refuse\t\(m)\n"
            case .invalid(let m): return "invalid\t\(m)\n"
            }
        }

        /// Parse a response line. nil on a malformed or truncated line (no
        /// newline, unknown verb), which the client reports as a lost reply.
        init?(line: String) {
            guard line.hasSuffix("\n") else { return nil }
            let body = String(line.dropLast())
            if body == "ok" { self = .started; return }
            let parts = body.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "refuse": self = .refused(message: String(parts[1]))
            case "invalid": self = .invalid(message: String(parts[1]))
            default: return nil
            }
        }

        /// Success maps to exit 0; both refusals map to a non-zero exit.
        var isSuccess: Bool { if case .started = self { return true }; return false }

        /// What the client writes to stderr (nothing extra on success — the app
        /// window is the feedback).
        var clientMessage: String? {
            switch self {
            case .started: return nil
            case .refused(let m), .invalid(let m): return m
            }
        }
    }

    /// How the caller can let a refused request proceed. `waitForCompletion` for
    /// engine work that will finish on its own; `closeEditor` for an open profile
    /// edit, which the user resolves by closing the editor.
    enum Resolution: Equatable {
        case waitForCompletion
        case closeEditor
    }

    /// The running instance's activity, as the primary reports it at the moment
    /// a request arrives. Idle means idle at the picker; every busy variant
    /// carries the reason shown to the caller and how to let the request proceed.
    enum Activity: Equatable {
        case idleAtPicker
        case busy(reason: String, resolution: Resolution)
    }

    /// What the primary should do with a request: reply only, or open a profile
    /// (which the caller then attempts) and report the outcome.
    enum Outcome: Equatable {
        case reply(Response)
        case open(name: String)
    }

    /// Whether the request can be faithfully transferred to this instance. Returns
    /// a refusal when it cannot, or nil when the request is safe to act on.
    ///
    /// The caller's own options are no longer a reason to refuse: the primary
    /// applies them to the opened session as explicit overrides (patch 0009 +
    /// session-args delivery), exactly as a fresh launch would. Remaining reasons
    /// a handoff would not be faithful:
    ///
    /// - The receiving instance was itself launched with options. This refusal is
    ///   now CONSERVATIVE rather than required: a launch's options are delivered
    ///   only to that launch's first session and are not re-parsed for later
    ///   sessions, so a handoff would not inherit them. It is kept for this slice
    ///   (delivery mechanism) and slated for removal in the refusal redesign.
    /// - The caller came from a different app installation.
    /// - The caller uses a different Unison directory.
    static func contextCheck(request: Request,
                             localUnisonDirectory: String,
                             localInstallationPath: String,
                             receiverLaunchWasClean: Bool) -> Response? {
        if !receiverLaunchWasClean {
            return .invalid(message:
                "unison-ui-mac is already running with command-line options that would affect other profiles. "
                + "Quit it and run again, or add -ui text to run it in the terminal.")
        }
        if request.installationPath != localInstallationPath {
            return .invalid(message:
                "unison-ui-mac is already running from a different copy of the app (\(localInstallationPath)); "
                + "it did not open \(request.given). Quit the running copy, or add -ui text to run it in the terminal.")
        }
        let requested = (request.unisonDirectory as NSString).standardizingPath
        let local = (localUnisonDirectory as NSString).standardizingPath
        if requested != local {
            return .invalid(message:
                "unison-ui-mac is already running with a different Unison directory (\(local)); "
                + "it did not open \(request.given). Quit the running app, or add -ui text to run it in the terminal.")
        }
        return nil
    }

    /// The pure decision. `launch` is the same disposition a fresh graphical
    /// launch computes (so roots and hidden/ambiguous profiles refuse
    /// identically, preserving the validation safeguards of req 6); `activity`
    /// is the live state. A valid profile opens only when idle; otherwise the
    /// existing work is preserved and the request is refused with a clear reason.
    static func decide(launch: CommandLineGraphicalLaunch, activity: Activity) -> Outcome {
        switch launch {
        case .refuse(let message):
            return .reply(.invalid(message: message))
        case .showPicker:
            // The client only hands off when a profile was named, so this is a
            // malformed request rather than a real "no profile" launch.
            return .reply(.invalid(message: "unison-ui-mac: no profile was named in the request."))
        case .openProfile(let name):
            switch activity {
            case .idleAtPicker:
                return .open(name: name)
            case .busy(let reason, let resolution):
                let howToProceed: String
                switch resolution {
                case .waitForCompletion:
                    howToProceed = "Wait for it to finish and choose \(name) in the app"
                case .closeEditor:
                    howToProceed = "Close the profile editor, then run the command again"
                }
                return .reply(.refused(message:
                    "unison-ui-mac is \(reason), so it did not start \(name). "
                    + "\(howToProceed), or add -ui text to run it in the terminal."))
            }
        }
    }

    /// The reply when the request's deadline elapsed before the app could act on
    /// it — the caller has already given up, so nothing must be opened (finding 1,
    /// round 3). The message is for completeness; the caller is no longer reading.
    static func expiredResponse(name: String) -> Response {
        .refused(message: "unison-ui-mac did not start \(name): the request expired before it was handled. "
            + "Run the command again.")
    }

    /// The reply after the primary attempts the open. `.started` only when the
    /// engine actually entered opening; otherwise the caller must not be told the
    /// scan began (finding 4).
    static func responseForOpenAttempt(enteredOpening: Bool, name: String) -> Response {
        enteredOpening
            ? .started
            : .refused(message:
                "unison-ui-mac did not start \(name); it needs attention in the app first. "
                + "Open the running app and choose \(name), or add -ui text to run it in the terminal.")
    }

    /// Whether a graphical launch was a clean profile open — nothing beyond a
    /// `-ui` selector and, at most, the profile name. Anything else (roots,
    /// `-path`, `-batch`, `-servercmd`, …) is not clean, because upstream reparses
    /// the command line on every profile load: a fresh launch would honor those,
    /// but they must not leak into a handoff (as the caller's request, or as the
    /// receiving instance's own launch context). `arguments` is
    /// `CommandLine.arguments` (argv[0] included); `launchProfile` is the profile
    /// the launch named, or nil (e.g. a Finder launch).
    static func isCleanGraphicalLaunch(arguments: [String], launchProfile: String?) -> Bool {
        let tokens = CommandLineInvocationPolicy.withoutHostInjected(Array(arguments.dropFirst()))
        var pruned: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "-ui" { i += 2; continue }        // flag plus its value
            if t.hasPrefix("-ui=") { i += 1; continue }
            pruned.append(t); i += 1
        }
        if let launchProfile { return pruned == [launchProfile] }
        return pruned.isEmpty
    }
}
