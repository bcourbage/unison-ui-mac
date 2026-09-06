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

    /// The flags upstream's `Main.init` handles before any UI exists. Their
    /// presence means the caller is a shell, not a graphical launcher.
    static let engineStartupFlags: Set<String> = [
        "-server", "-socket", "-ui", "-version", "-doc", "-help",
    ]

    /// Decide the invocation from the raw process arguments.
    ///
    /// - `arguments`: `CommandLine.arguments`, argv[0] included.
    /// - `hasWindowServerSession`: whether a graphical session exists for this
    ///   process. False under ssh, cron and launchd daemons.
    /// - `isTestHost`: XCTest or the launch smoke. Both are graphical launches
    ///   whatever the arguments or session say.
    static func classify(arguments: [String],
                         hasWindowServerSession: Bool,
                         isTestHost: Bool) -> CommandLineInvocation {
        if isTestHost { return .gui }

        let argv0 = arguments.first ?? "unison-ui-mac"
        let rest = Array(arguments.dropFirst())

        if rest.contains(where: engineStartupFlags.contains) {
            // A graphical interface cannot be shown without a session. Mirror
            // the GTK build, which warns and starts the text interface.
            if !hasWindowServerSession,
               let i = rest.firstIndex(of: "-ui"), i + 1 < rest.count, rest[i + 1] == "graphic" {
                var adjusted = rest
                adjusted[i + 1] = "text"
                return .commandLine(
                    arguments: [argv0] + adjusted,
                    notice: "unison-ui-mac: no graphical session is available; starting the text interface instead of -ui graphic")
            }
            return .commandLine(arguments: [argv0] + rest, notice: nil)
        }

        let userArguments = stripHostInjected(rest)
        if userArguments.isEmpty { return .gui }

        // Arguments but no engine flag and no session: an automation caller
        // such as `unison -batch myprofile` from launchd. Upstream's macOS app
        // attempts a GUI here and fails; run the text interface instead.
        if !hasWindowServerSession {
            return .commandLine(arguments: [argv0, "-ui", "text"] + userArguments, notice: nil)
        }

        return .unsupported(message:
            "unison-ui-mac: profiles and roots given on the command line are not supported by the graphical interface. "
            + "Choose the profile in the profile picker, or add -ui text to run in the terminal. "
            + "Arguments: " + userArguments.joined(separator: " "))
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
/// Returns only when OCaml returned, which means the caller asked for `-ui
/// graphic` and the graphical interface should now start with the runtime
/// already up. Every other startup flag ends the process inside OCaml.
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
