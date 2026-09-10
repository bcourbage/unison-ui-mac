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
///   request:   `open\t<rootsSet>\t<given>\n`   (given is the rest of the line)
///   response:  `ok\n` | `refuse\t<message>\n` | `invalid\t<message>\n`
///
/// `given` is placed last and read up to the newline, so a profile name may
/// contain tabs or spaces; only a newline is disallowed (unrepresentable, and
/// not a valid Unison profile name).
enum CommandLineHandoff {

    /// A client's request to open a profile in the running instance.
    struct Request: Equatable {
        /// The profile string exactly as the engine parsed it (upstream has
        /// already checked the named file exists); the primary re-validates it
        /// against its own directory so validation happens where the open does.
        var given: String
        /// `unison_bridge_command_line_roots_set()`: 0 none, 1 present, else
        /// undetermined. Forwarded so the primary applies the same refusal for
        /// roots as a fresh launch would.
        var rootsSet: Int

        static let verb = "open"

        /// nil when `given` cannot be represented on one line.
        func encoded() -> String? {
            guard !given.contains("\n") else { return nil }
            return "\(Request.verb)\t\(rootsSet)\t\(given)\n"
        }

        /// Parse a request line (with or without the trailing newline). nil on
        /// any malformed line, so the primary refuses rather than guesses.
        init?(line: String) {
            let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
            // Split into at most three parts so the profile keeps any tabs.
            let parts = body.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == Request.verb, let roots = Int(parts[1]) else { return nil }
            self.given = String(parts[2])
            self.rootsSet = roots
        }

        init(given: String, rootsSet: Int) {
            self.given = given
            self.rootsSet = rootsSet
        }
    }

    /// The primary's verdict, sent back to the client.
    enum Response: Equatable {
        /// Accepted: the primary is opening the profile and starting its scan.
        case started
        /// The instance is busy (a scan, reconciliation, sync, or an open
        /// profile edit); the existing work is preserved and this request is not.
        case refused(message: String)
        /// The request itself is not valid here (roots, or a hidden or ambiguous
        /// profile); it would not start a different profile.
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

    /// The running instance's activity, as the primary reports it at the moment
    /// a request arrives. Idle means idle at the picker; every busy variant
    /// carries the reason shown to the caller.
    enum Activity: Equatable {
        case idleAtPicker
        case busy(reason: String)
    }

    /// What the primary should do with a request: reply only, or open a profile
    /// (which implies a `.started` reply) and then honor it.
    enum Outcome: Equatable {
        case reply(Response)
        case open(name: String)
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
            case .busy(let reason):
                return .reply(.refused(message:
                    "unison-ui-mac is \(reason), so it kept that and did not start \(name). "
                    + "Open the running app and choose \(name) when it is free, or add -ui text to run it in the terminal."))
            }
        }
    }
}
