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
///   request:   `open\t<rootsSet>\t<plain 0|1>\t<unisonDir b64>\t<given b64>\n`
///   response:  `ok\n` | `refuse\t<message>\n` | `invalid\t<message>\n`
///
/// The variable-length fields are base64, so a directory or profile name with a
/// tab or any other byte round-trips unambiguously.
enum CommandLineHandoff {

    /// A client's request to open a profile in the running instance. It carries
    /// enough context for the primary to confirm the request would open the same
    /// thing the caller meant, and to refuse rather than silently do something
    /// different (finding 1): the caller's Unison directory, and whether the
    /// invocation was a plain profile open (no extra options the primary could
    /// not reproduce).
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
        /// True when the caller's command line was a plain profile open. When
        /// false, the invocation carried options (`-path`, `-ignore`,
        /// `-servercmd`, …) that a fresh launch honors but the already-running
        /// instance cannot reproduce, so the primary refuses.
        var plainRequest: Bool

        static let verb = "open"

        func encoded() -> String? {
            let dir = Data(unisonDirectory.utf8).base64EncodedString()
            let name = Data(given.utf8).base64EncodedString()
            return "\(Request.verb)\t\(rootsSet)\t\(plainRequest ? 1 : 0)\t\(dir)\t\(name)\n"
        }

        /// Parse a request line (with or without the trailing newline). nil on
        /// any malformed line, so the primary refuses rather than guesses.
        init?(line: String) {
            let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let parts = body.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == Request.verb,
                  let roots = Int(parts[1]), let plain = Int(parts[2]), plain == 0 || plain == 1,
                  let dir = Self.decodeBase64(String(parts[3])),
                  let name = Self.decodeBase64(String(parts[4]))
            else { return nil }
            self.given = name
            self.rootsSet = roots
            self.unisonDirectory = dir
            self.plainRequest = plain == 1
        }

        init(given: String, rootsSet: Int, unisonDirectory: String, plainRequest: Bool) {
            self.given = given
            self.rootsSet = rootsSet
            self.unisonDirectory = unisonDirectory
            self.plainRequest = plainRequest
        }

        private static func decodeBase64(_ s: String) -> String? {
            Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// The primary's verdict, sent back to the client.
    enum Response: Equatable {
        /// Accepted: the primary is opening the profile and starting its scan.
        case started
        /// The instance is busy (a scan, reconciliation, sync, or an open
        /// profile edit); the existing work is preserved and this request is not.
        case refused(message: String)
        /// The request itself is not valid or transferable here (roots, a hidden
        /// or ambiguous profile, a different Unison directory, or extra options);
        /// it would not start a different profile.
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
    /// a refusal when it cannot (a different Unison directory, or extra options the
    /// primary cannot reproduce), or nil when the request is safe to act on.
    static func contextCheck(request: Request, localUnisonDirectory: String) -> Response? {
        if !request.plainRequest {
            return .invalid(message:
                "unison-ui-mac cannot apply the extra command-line options to the already-running app. "
                + "Quit it and run again, or add -ui text to run it in the terminal.")
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
                    howToProceed = "Close the profile editor to let the command proceed"
                }
                return .reply(.refused(message:
                    "unison-ui-mac is \(reason), so it did not start \(name). "
                    + "\(howToProceed), or add -ui text to run it in the terminal."))
            }
        }
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

    /// Whether the caller's command line was a plain profile open, so the handoff
    /// can carry it faithfully. Anything beyond the profile name and a `-ui`
    /// selector (roots, `-path`, `-batch`, `-servercmd`, …) makes it non-plain,
    /// because a fresh launch would honor those but the running instance cannot.
    /// `arguments` is `CommandLine.arguments` (argv[0] included).
    static func isPlainProfileRequest(arguments: [String], profile: String) -> Bool {
        var tokens = CommandLineInvocationPolicy.withoutHostInjected(Array(arguments.dropFirst()))
        // Drop a `-ui <value>` or `-ui=value` selector; the engine already used it.
        var pruned: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "-ui" { i += 2; continue }        // flag plus its value
            if t.hasPrefix("-ui=") { i += 1; continue }
            pruned.append(t); i += 1
        }
        tokens = pruned
        return tokens == [profile]
    }
}
