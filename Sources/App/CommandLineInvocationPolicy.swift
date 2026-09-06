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

    /// Shell launch. The engine receives `arguments` in full and
    /// `unisonNonGuiStartup` runs before AppKit. `notice`, when present, goes to
    /// stderr first.
    case commandLine(arguments: [String], notice: String?)

    /// A shell launch the graphical interface cannot honor. `message` goes to
    /// stderr and the process exits 1. Silently opening the picker and dropping
    /// the arguments is the one behavior this type forbids.
    case unsupported(message: String)
}

enum CommandLineInvocationPolicy {

    /// The options upstream's `Main.init` handles before any UI exists. Their
    /// presence means the caller is a shell, not a graphical launcher. Compared
    /// by option *name*, after `Uarg`'s grammar is applied: leading dashes are
    /// not significant and `-name=value` is one token.
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
    /// - `stdinIsTerminal`: `isatty(STDIN_FILENO)`. A person typing in Terminal
    ///   has one; launchd, cron and ssh commands do not.
    /// - `isTestHost`: XCTest or the launch smoke. Both are graphical launches
    ///   whatever the arguments or session say, and both must reach
    ///   `applicationDidFinishLaunching` before the runtime starts, because that
    ///   is where the test host redirects `UNISON` to a throwaway directory.
    static func classify(arguments: [String],
                         hasWindowServerSession: Bool,
                         stdinIsTerminal: Bool,
                         isTestHost: Bool) -> CommandLineInvocation {
        if isTestHost { return .gui }

        let argv0 = arguments.first ?? "unison-ui-mac"
        // Host-injected flags are never Unison's business, on any path: an Xcode
        // scheme that runs `-ui graphic` still carries -NSDocumentRevisionsDebugMode.
        let userArguments = stripHostInjected(Array(arguments.dropFirst()))

        if userArguments.isEmpty {
            // A bare launch with no session cannot show a window. Upstream's text
            // interface prints its usage and exits, which is the honest answer to
            // `ssh mac unison` with nothing else.
            return hasWindowServerSession
                ? .gui
                : .commandLine(arguments: [argv0, "-ui", "text"], notice: nil)
        }

        if userArguments.contains(where: { engineStartupOptions.contains(optionName($0) ?? "") }) {
            // A graphical interface cannot be shown without a session. Mirror
            // the GTK build, which warns and starts the text interface. This
            // takes precedence over anything else in the arguments: a profile
            // named here then runs in the text interface.
            if !hasWindowServerSession, let rewritten = replacingUIGraphicWithText(userArguments) {
                return .commandLine(
                    arguments: [argv0] + rewritten,
                    notice: "unison-ui-mac: no graphical session is available; starting the text interface instead of -ui graphic")
            }
            return .commandLine(arguments: [argv0] + userArguments, notice: nil)
        }

        // Arguments, but no engine option. Without a graphical session, or
        // without a terminal on stdin, the caller is automation such as
        // `unison -batch myprofile` from launchd or cron: run the text
        // interface, which is what upstream's `unison` would have done.
        if !hasWindowServerSession || !stdinIsTerminal {
            return .commandLine(arguments: [argv0, "-ui", "text"] + userArguments, notice: nil)
        }

        // A person in Terminal with a graphical session. The graphical interface
        // cannot take a profile, roots or other options yet; say so.
        return .unsupported(message:
            "unison-ui-mac: these arguments are not supported by the graphical interface: "
            + userArguments.joined(separator: " ")
            + ". Choose the profile in the profile picker, or add -ui text to run in the terminal.")
    }

    /// The option name of a token in `Uarg`'s grammar: a token starting with `-`
    /// is an option; leading dashes are stripped and an inline `=value` is
    /// removed. Returns nil for a value or positional token.
    static func optionName(_ token: String) -> String? {
        guard token.hasPrefix("-") else { return nil }
        let stripped = token.drop(while: { $0 == "-" })
        let name = stripped.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return name.isEmpty ? nil : String(name)
    }

    /// If the arguments select `-ui graphic` (separate or `=` form), return them
    /// with `text` in its place; otherwise nil.
    static func replacingUIGraphicWithText(_ arguments: [String]) -> [String]? {
        var out = arguments
        var changed = false
        var i = 0
        while i < out.count {
            if optionName(out[i]) == "ui" {
                if out[i].contains("=") {
                    if out[i].hasSuffix("=graphic") {
                        out[i] = String(out[i].dropLast("graphic".count)) + "text"
                        changed = true
                    }
                } else if i + 1 < out.count, out[i + 1] == "graphic" {
                    out[i + 1] = "text"
                    changed = true
                    i += 1
                }
            }
            i += 1
        }
        return changed ? out : nil
    }

    /// Flags macOS itself, Xcode or the test runner add to a graphical launch.
    /// `-NS…` and `-Apple…` are NSArgumentDomain defaults and take a value;
    /// `-psn_…` is Launch Services' legacy process serial number and does not.
    static func isHostInjectedFlag(_ argument: String) -> Bool {
        argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") || argument.hasPrefix("-psn_")
    }

    /// Remove host-injected flags, and the value that follows each `-NS…` or
    /// `-Apple…` flag, leaving only what a person or script passed.
    static func stripHostInjected(_ arguments: [String]) -> [String] {
        var out: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if isHostInjectedFlag(argument) {
                skipNext = !argument.hasPrefix("-psn_")
                continue
            }
            out.append(argument)
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
