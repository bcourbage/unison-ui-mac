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
///   response:  `ok\n` | `waiting\t<message>\n` | `refuse\t<message>\n` | `invalid\t<message>\n`
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
        /// Accepted and waiting: the primary took responsibility for the request
        /// but the profile is not opening yet — it opens once the current work and
        /// its connection cleanup finish. The message tells the caller the app now
        /// owns the request and where to watch it.
        case acceptedWaiting(message: String)
        /// The instance is busy in a way the request must not disturb (an active
        /// synchronization, an open profile edit) or another request is already
        /// waiting; the existing work is preserved and this request is not.
        case refused(message: String)
        /// The request itself is not valid or transferable here (roots, a hidden
        /// or ambiguous profile, or a different app installation / Unison
        /// directory); it would not start a different profile.
        case invalid(message: String)

        func encoded() -> String {
            switch self {
            case .started: return "ok\n"
            case .acceptedWaiting(let m): return "waiting\t\(m)\n"
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
            case "waiting": self = .acceptedWaiting(message: String(parts[1]))
            case "refuse": self = .refused(message: String(parts[1]))
            case "invalid": self = .invalid(message: String(parts[1]))
            default: return nil
            }
        }

        /// Both accepted outcomes (opening now, or accepted and waiting) map to
        /// exit 0: the app took the request. Refusals map to a non-zero exit.
        var isSuccess: Bool {
            switch self {
            case .started, .acceptedWaiting: return true
            case .refused, .invalid: return false
            }
        }

        /// What the client writes to stderr. `.started` prints nothing (the app
        /// window is the feedback); accepted-and-waiting prints an informational
        /// line so the caller knows the app owns the request.
        var clientMessage: String? {
            switch self {
            case .started: return nil
            case .acceptedWaiting(let m), .refused(let m), .invalid(let m): return m
            }
        }
    }

    /// The running instance's activity, as the primary reports it at the moment a
    /// request arrives. It maps directly to the design's state table:
    ///  - `idleAtPicker`      → open the requested session now.
    ///  - `busyWillWait`      → accept the request and open it after the current
    ///                          operation and cleanup finish.
    ///  - `synchronizing`     → (this slice) refuse and point the caller at the
    ///                          app's sync decision; the dialog interaction is a
    ///                          separate follow-up.
    ///  - `editing`           → refuse; the profile editor is open and its edits
    ///                          are preserved.
    ///  - `restartRequired`   → refuse; a recovery restriction is in effect.
    ///  - `requestAlreadyPending` → refuse; one external request is already
    ///                          waiting and must not be replaced.
    enum Activity: Equatable {
        case idleAtPicker
        case busyWillWait(reason: String)
        case synchronizing(reason: String)
        case editing(profileDescription: String)
        case restartRequired(reason: String)
        case requestAlreadyPending
    }

    /// What the primary should do with a request: reply only, open a profile now
    /// (which the caller then attempts) and report the outcome, accept it to open
    /// after the current work finishes, or (during a synchronization) present the
    /// three-way sync decision to the user and let that decision govern the request.
    enum Outcome: Equatable {
        case reply(Response)
        case openNow(name: String)
        case acceptWaiting(name: String)
        case presentSyncDecision(name: String)
    }

    /// The user's choice in the three-way decision an incoming request raises while
    /// a synchronization is running (the app's existing Keep Syncing / Abort &
    /// Close / Close (let it run) prompt).
    enum SyncDecision: Equatable {
        case keepSyncing
        case abortAndClose
        case closeAndLetRun
    }

    /// What to do with the running sync and the waiting request after the user
    /// chooses. `admitRequest` is false when the request's bounded admission
    /// deadline already elapsed: the user's sync choice is still honored, but the
    /// expired request must not open (design: once a request expires, a later
    /// dialog response cannot start it).
    enum SyncDecisionResolution: Equatable {
        case keepSyncing
        case abortAndClose(admitRequest: Bool)
        case closeAndLetRun(admitRequest: Bool)
    }

    /// Map the user's choice + the request's expiry to the resolution. Keep Syncing
    /// preserves the sync and drops the request; the other two leave the sync and
    /// open the request only when it has not expired.
    static func resolveSyncDecision(_ decision: SyncDecision, requestExpired: Bool) -> SyncDecisionResolution {
        switch decision {
        case .keepSyncing:    return .keepSyncing
        case .abortAndClose:  return .abortAndClose(admitRequest: !requestExpired)
        case .closeAndLetRun: return .closeAndLetRun(admitRequest: !requestExpired)
        }
    }

    /// Whether the request can be faithfully transferred to this instance. Returns
    /// a refusal when it cannot, or nil when the request is safe to act on.
    ///
    /// The caller's own options are not a reason to refuse: the primary applies
    /// them to the opened session as explicit overrides (patch 0009 + session-args
    /// delivery), exactly as a fresh launch would. Nor is the receiving instance's
    /// own launch a reason: a launch's options scope only that launch's first
    /// session and are never re-parsed for a later session, so a request delivered
    /// here is scoped solely by its own options regardless of how the app started.
    /// The only remaining reasons a handoff would not be faithful:
    ///
    /// - The caller came from a different app installation.
    /// - The caller uses a different Unison directory.
    static func contextCheck(request: Request,
                             localUnisonDirectory: String,
                             localInstallationPath: String) -> Response? {
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
    /// is the live state. A valid profile opens now when idle, is accepted to
    /// open after cleanup when the app is busy with leavable work, and is refused
    /// (existing work preserved) when a synchronization, an open editor, a
    /// recovery restriction, or another pending request stands in the way.
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
                return .openNow(name: name)
            case .busyWillWait:
                return .acceptWaiting(name: name)
            case .synchronizing:
                // A synchronization is running: raise the app's three-way decision
                // (Keep Syncing / Abort & Close / Close (let it run)) and let the
                // user's choice govern this request. The reply to the caller is a
                // refusal (the request is NOT accepted while a decision is pending),
                // but the request is held to a bounded admission deadline so a
                // choice to leave the sync opens it (design).
                return .presentSyncDecision(name: name)
            case .editing(let profileDescription):
                return .reply(.refused(message:
                    "unison-ui-mac is \(profileDescription), so it did not start \(name). "
                    + "Close the profile editor, then run the command again, "
                    + "or add -ui text to run it in the terminal."))
            case .restartRequired(let reason):
                // No "-ui text" alternative: the runtime is in an uncertain state a
                // restart must clear first; starting another process is not the fix.
                return .reply(.refused(message:
                    "unison-ui-mac \(reason), so it did not start \(name). "
                    + "Quit and reopen it, then run the command again."))
            case .requestAlreadyPending:
                return .reply(.refused(message:
                    "unison-ui-mac is already handling another command-line request, so it did not start \(name). "
                    + "Wait for that one to open, then run the command again, "
                    + "or add -ui text to run it in the terminal."))
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

    /// The reply when the primary accepted the request but the profile will open
    /// only after the current work finishes. The app now owns the request and
    /// shows it waiting; the caller is not opening it and does not retry.
    static func acceptedWaitingResponse(name: String, reason: String) -> Response {
        .acceptedWaiting(message:
            "unison-ui-mac is \(reason). It will open \(name) once that finishes; "
            + "the request is waiting in the app.")
    }

    /// The interim message the primary sends FIRST when a request arrives during an
    /// active synchronization: it tells the caller a decision is required in the app
    /// and how long the caller will wait for it, then the caller waits on the same
    /// connection for the final verdict (two-phase reply). Wire line:
    /// `pending\t<timeoutSeconds>\t<message>\n` — the message is single-line text.
    struct Interim: Equatable {
        var timeoutSeconds: Int
        var message: String

        static let verb = "pending"

        func encoded() -> String { "\(Interim.verb)\t\(timeoutSeconds)\t\(message)\n" }

        init(timeoutSeconds: Int, message: String) {
            self.timeoutSeconds = timeoutSeconds
            self.message = message
        }

        /// Parse an interim line, or nil when the line is not an interim (so the
        /// client treats it as the final response instead).
        init?(line: String) {
            guard line.hasSuffix("\n") else { return nil }
            let body = String(line.dropLast())
            let parts = body.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == Interim.verb, let secs = Int(parts[1]) else { return nil }
            self.timeoutSeconds = secs
            self.message = String(parts[2])
        }
    }

    /// The interim notice for a request that arrived during a synchronization.
    static func syncDecisionInterim(name: String, timeoutSeconds: Int) -> Interim {
        Interim(timeoutSeconds: timeoutSeconds, message:
            "unison-ui-mac is synchronizing; it needs a decision in the app before it can start \(name). "
            + "Waiting up to \(timeoutSeconds)s for you to choose Keep Syncing, Abort & Close, or Close (let it run)…")
    }

    /// Final verdict: the user kept syncing, so the request was not started.
    static func syncKeptResponse(name: String) -> Response {
        .refused(message:
            "unison-ui-mac kept synchronizing, so it did not start \(name). "
            + "Run the command again when you're ready to open it.")
    }

    /// Final verdict: no choice was made before the admission deadline elapsed, so
    /// the request was not started and can no longer be started by a later choice.
    static func syncDecisionExpiredResponse(name: String) -> Response {
        .refused(message:
            "unison-ui-mac did not start \(name): no choice was made in time. Run the command again.")
    }

    /// Final verdict: by the time the user chose, the app was no longer able to open
    /// the request (the sync ended or the app entered recovery). An explicit refusal
    /// rather than opening into an unexpected state.
    static func syncDecisionUnavailableResponse(name: String) -> Response {
        .refused(message:
            "unison-ui-mac could not start \(name): the app's state changed while the decision was open. "
            + "Run the command again.")
    }
}
