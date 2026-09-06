import Foundation

/// How this process was reached, decided in `main.swift` before AppKit starts.
///
/// The app is reached in two ways. Finder, `open`, Xcode and the XCTest host
/// launch it graphically. The `unison` launcher (`Sources/CLTool/cltool.c`) and
/// a remote peer's `ssh host unison -server` reach the same executable from a
/// shell. What a shell invocation *means* is not decided here: only Unison's
/// own preference parser knows which tokens are options and which are values
/// (`-label -server` is a label) and which `-ui` wins (the last one given). So
/// a shell launch hands the engine the caller's tokens unchanged, with one
/// default in front, `-ui text`, and lets upstream's `unisonNonGuiStartup`
/// interpret the result:
///
/// - `-server`, `-socket`, `-version`, `-doc`, `-help`: `Main.init` runs them
///   before looking at `-ui`, and exits.
/// - Effective `-ui text` (the default, unless the caller's own `-ui graphic`
///   comes later and wins): the text interface runs and exits.
/// - Effective `-ui graphic`: the callback returns, and the graphical launch
///   continues with the runtime already up, if a graphical session exists.
///
/// Consequences: `unison p` typed in Terminal runs the text interface, as the
/// `unison` command does everywhere; `-label -server -batch p` is a text sync
/// with the label "-server"; `-server -ui graphic` is a server; `--server` is
/// upstream's unknown-option error. Nothing is ever dropped or reordered.
enum LaunchKind: Equatable {
    /// Graphical launch. The engine receives argv[0] only, because the host
    /// injects flags (`-NSTreatUnknownArgumentsAsOpen`, …) that Unison's parser
    /// rejects, and the profile picker selects the profile.
    case gui
    /// Shell launch: the engine receives `-ui text` followed by the caller's
    /// tokens, and `unisonNonGuiStartup` decides.
    case shell
}

/// What to do when `unisonNonGuiStartup` returns, which happens only when the
/// effective interface is graphical.
enum GraphicalContinuation: Equatable {
    case proceed
    case refuse(message: String)
}

enum CommandLineInvocationPolicy {

    /// Set by the launcher (`cltool`) in the environment of the process it
    /// execs, and read then removed by `main.swift`. It identifies the launch
    /// path so that host-launch detection does not depend on interpreting
    /// Unison options; it is not a security boundary, and nothing that matters
    /// for safety hinges on it. Without it, a direct invocation of the bundle
    /// executable still counts as a shell launch when it carries arguments or
    /// runs without a graphical session, so `servercmd` pointing straight at
    /// the executable keeps working.
    static let launcherMarker = "UNISON_UI_MAC_LAUNCHER"

    /// - `arguments`: `CommandLine.arguments`, argv[0] included.
    /// - `launchedByLauncher`: the marker was present in the environment.
    /// - `hasWindowServerSession`: `CGSessionCopyCurrentDictionary() != nil`.
    ///   False under ssh, cron and launchd daemons.
    /// - `isTestHost`: XCTest or the launch smoke. Both are graphical launches
    ///   whatever the arguments say, and both must reach
    ///   `applicationDidFinishLaunching` before the runtime starts, because that
    ///   is where the test host redirects `UNISON` to a throwaway directory.
    static func launchKind(arguments: [String],
                           launchedByLauncher: Bool,
                           hasWindowServerSession: Bool,
                           isTestHost: Bool) -> LaunchKind {
        if isTestHost { return .gui }
        if launchedByLauncher { return .shell }
        // A bare launch with no session cannot show a window; only the engine's
        // text interface can run.
        if !hasWindowServerSession { return .shell }
        // Host flags are only *ignored* here, to see whether a person or script
        // passed anything. They are never removed from what the engine gets.
        return withoutHostInjected(Array(arguments.dropFirst())).isEmpty ? .gui : .shell
    }

    /// The argv handed to the engine for a shell launch: the caller's tokens in
    /// order, preceded by the `-ui text` default that a later `-ui graphic`
    /// overrides (upstream keeps the last value given).
    static func engineArguments(_ arguments: [String]) -> [String] {
        let argv0 = arguments.first ?? "unison-ui-mac"
        return [argv0, "-ui", "text"] + Array(arguments.dropFirst())
    }

    /// `unisonNonGuiStartup` returned, so the effective interface is graphical.
    static func graphicalContinuation(hasWindowServerSession: Bool) -> GraphicalContinuation {
        hasWindowServerSession
            ? .proceed
            : .refuse(message: "unison-ui-mac: no graphical session is available for -ui graphic. Use -ui text to run in the terminal.")
    }

    // MARK: Host-injected flags (launch-kind decision only)

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
    /// skipped only when it does not itself start with `-`.
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

/// The shell-launch driver. Starts the runtime with the engine argv and runs
/// `unisonNonGuiStartup`. Returns only when the effective interface is
/// graphical and a session exists; every other outcome ends the process here
/// or inside OCaml.
enum CommandLineEngineLaunch {
    static func run(arguments: [String], hasWindowServerSession: Bool) {
        let engineArguments = CommandLineInvocationPolicy.engineArguments(arguments)
        // The OCaml runtime keeps Sys.argv pointing into this array for the
        // life of the process, so it is allocated once and never freed.
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: engineArguments.count + 1)
        for (i, argument) in engineArguments.enumerated() { argv[i] = strdup(argument) }
        argv[engineArguments.count] = nil

        let status = unison_bridge_cli_startup(Int32(engineArguments.count), argv)
        if status != UNISON_BRIDGE_OK {
            writeStderr("unison-ui-mac: the embedded Unison engine failed to start (code \(status))")
            exit(1)
        }
        switch CommandLineInvocationPolicy.graphicalContinuation(hasWindowServerSession: hasWindowServerSession) {
        case .proceed:
            return
        case .refuse(let message):
            writeStderr(message)
            exit(1)
        }
    }

    static func writeStderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
