import Foundation

/// How this process was invoked. Decided in `main.swift` before AppKit starts,
/// because two of the three outcomes never start AppKit at all.
///
/// The app is reached in two ways. Finder, `open`, Xcode and the XCTest host
/// launch it graphically; the `unison` launcher (`Sources/CLTool/cltool.c`) and
/// a remote peer's `ssh host unison -server` reach the same executable from a
/// shell. Upstream Unison's macOS app makes the same split in `uimac/main.m`:
/// when argv carries one of the engine's startup flags it calls the OCaml
/// `unisonNonGuiStartup` first, which exits for the headless roles and returns
/// only when the graphical interface was asked for.
enum CommandLineInvocation: Equatable {
    /// Graphical launch. The engine receives argv[0] only, because the host
    /// injects flags (`-NSTreatUnknownArgumentsAsOpen`, …) that Unison's
    /// preference parser rejects, and the profile picker selects the profile.
    case gui

    /// Shell launch. The engine receives `arguments` and `unisonNonGuiStartup`
    /// runs before AppKit. The caller's tokens are never edited or reordered;
    /// the only change the policy ever makes is prepending `-ui text`.
    case commandLine(arguments: [String])

    /// A shell launch that cannot be honored. `message` goes to stderr and the
    /// process exits 1. Silently opening the picker and dropping the arguments
    /// is the one behavior this type forbids.
    case unsupported(message: String)
}

enum CommandLineInvocationPolicy {

    /// The options upstream's `Main.init` handles before any UI exists. Their
    /// presence means the caller is a shell, not a graphical launcher. Compared
    /// by option *name* under `Uarg`'s grammar (see `optionName`).
    static let engineStartupOptions: Set<String> = [
        "server", "socket", "ui", "version", "doc", "help",
    ]

    /// Decide the invocation from the raw process arguments.
    ///
    /// - `arguments`: `CommandLine.arguments`, argv[0] included.
    /// - `hasWindowServerSession`: whether this process belongs to a graphical
    ///   session (`CGSessionCopyCurrentDictionary() != nil`). False under ssh,
    ///   cron and launchd daemons; true for a LaunchAgent in a logged-in
    ///   session, which is why it is not the only automation signal.
    /// - `stdinIsTerminal`: `isatty(STDIN_FILENO)`. This is a policy input, not
    ///   proof of a person: a script started from Terminal inherits the
    ///   terminal, and a person can redirect stdin. Scripts say `-batch` or
    ///   `-ui text`, both of which route to the text interface regardless.
    /// - `isTestHost`: XCTest or the launch smoke. Both are graphical launches
    ///   whatever the arguments or session say, and both must reach
    ///   `applicationDidFinishLaunching` before the runtime starts, because that
    ///   is where the test host redirects `UNISON` to a throwaway directory.
    ///
    /// The policy classifies tokens but does not parse them: which token is an
    /// option's value is `Uarg`'s knowledge (a `-label` value may start with
    /// `-`). So the tokens handed to the engine are always the caller's own,
    /// in order, and host-injected flags are only *ignored for the decision*,
    /// never removed from what the engine sees. Where the engine gets them it
    /// rejects them itself with usage and exit 2, as upstream would.
    static func classify(arguments: [String],
                         hasWindowServerSession: Bool,
                         stdinIsTerminal: Bool,
                         isTestHost: Bool) -> CommandLineInvocation {
        if isTestHost { return .gui }

        let argv0 = arguments.first ?? "unison-ui-mac"
        let rest = Array(arguments.dropFirst())
        let userArguments = withoutHostInjected(rest)
        let names = Set(rest.compactMap(optionName))

        if userArguments.isEmpty {
            // A bare launch with no session cannot show a window. Hand it to the
            // text interface, which behaves exactly like upstream's `unison` with
            // no arguments: it uses the `default` profile if one exists and prints
            // usage otherwise.
            return hasWindowServerSession
                ? .gui
                : .commandLine(arguments: [argv0, "-ui", "text"])
        }

        if !names.isDisjoint(with: engineStartupOptions) {
            // A graphical interface cannot be shown without a session. Refuse
            // rather than rewrite the request: editing `graphic` into `text`
            // would require knowing which token is the value of `-ui`.
            if !hasWindowServerSession, selectsGraphicUI(rest) {
                return .unsupported(message:
                    "unison-ui-mac: no graphical session is available for -ui graphic. Use -ui text to run in the terminal.")
            }
            return .commandLine(arguments: [argv0] + rest)
        }

        // Arguments, but no engine option. Automation gets the text interface,
        // which is what upstream's `unison` would have run. Automation is
        // recognized by any of: `-batch` (the caller said so), no graphical
        // session, or no terminal on stdin (launchd, cron, ssh commands).
        if names.contains("batch") || !hasWindowServerSession || !stdinIsTerminal {
            return .commandLine(arguments: [argv0, "-ui", "text"] + rest)
        }

        // A person in Terminal with a graphical session. The graphical interface
        // cannot take a profile, roots or other options yet; say so.
        return .unsupported(message:
            "unison-ui-mac: these arguments are not supported by the graphical interface: "
            + rest.joined(separator: " ")
            + ". Choose the profile in the profile picker, or add -ui text to run in the terminal.")
    }

    /// The option name of a token in `Uarg`'s grammar. Upstream registers every
    /// option as `"-" ^ name` and looks tokens up exactly after splitting at the
    /// first `=`, so `-ui` and `-ui=text` name the option `ui`, while `--ui` is
    /// a different, unknown option and `-` alone is nothing. Returns nil for a
    /// value or positional token, and for anything upstream would not match.
    static func optionName(_ token: String) -> String? {
        guard token.hasPrefix("-"), token.count > 1 else { return nil }
        let afterDash = token.dropFirst()
        guard !afterDash.hasPrefix("-") else { return nil }
        let name = afterDash.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return name.isEmpty ? nil : String(name)
    }

    /// True when the tokens ask for the graphical interface: `-ui graphic` or
    /// `-ui=graphic`. Token-level, so a value that merely looks like `-ui` can
    /// make this true; the only consequence is a refusal that names the
    /// request, never a silent change.
    static func selectsGraphicUI(_ arguments: [String]) -> Bool {
        for (i, token) in arguments.enumerated() where optionName(token) == "ui" {
            if token.contains("=") {
                if token.hasSuffix("=graphic") { return true }
            } else if i + 1 < arguments.count, arguments[i + 1] == "graphic" {
                return true
            }
        }
        return false
    }

    /// Flags macOS itself, Xcode or the test runner add to a graphical launch.
    /// `-NS…` and `-Apple…` are NSArgumentDomain defaults (`-NSDocumentRevisions
    /// DebugMode YES`, `-NSTreatUnknownArgumentsAsOpen NO`, `-ApplePersistence
    /// IgnoreState YES`, `-AppleLanguages (fr)`) and carry one value; `-psn_…` is
    /// Launch Services' legacy process serial number and carries none. Unison
    /// registers no option with either prefix.
    static func isHostInjectedFlag(_ argument: String) -> Bool {
        argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") || argument.hasPrefix("-psn_")
    }

    /// The tokens a person or script passed, for the purpose of deciding whether
    /// any exist. A `-NS…`/`-Apple…` flag's value is the following token,
    /// skipped only when it does not itself start with `-`. Used for the
    /// decision only; the engine always receives the caller's tokens intact.
    static func withoutHostInjected(_ arguments: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            if isHostInjectedFlag(argument) {
                if !argument.hasPrefix("-psn_"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") {
                    i += 1
                }
                i += 1
                continue
            }
            out.append(argument)
            i += 1
        }
        return out
    }
}

/// Starts the embedded engine for a shell launch and runs `unisonNonGuiStartup`.
/// Returns only when OCaml returned normally, which means the caller asked for
/// `-ui graphic` and the graphical interface should now start with the runtime
/// already up. Every other startup option ends the process inside OCaml; an
/// OCaml exception is reported by the bridge and ends the process here with
/// exit status 1.
enum CommandLineEngineLaunch {
    static func startEngine(arguments: [String]) {
        // The OCaml runtime keeps Sys.argv pointing into this array for the
        // life of the process, so it is allocated once and never freed.
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        for (i, argument) in arguments.enumerated() { argv[i] = strdup(argument) }
        argv[arguments.count] = nil

        let status = unison_bridge_cli_startup(Int32(arguments.count), argv)
        if status != UNISON_BRIDGE_OK {
            writeStderr("unison-ui-mac: the embedded Unison engine failed to start (code \(status))")
            exit(1)
        }
    }

    static func writeStderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
