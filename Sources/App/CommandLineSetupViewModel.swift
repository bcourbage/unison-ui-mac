import Foundation

// The words the Settings pane shows for a state: the verdict line qualified by
// the check, the short badge, the abbreviated path evidence, the note, and the
// single action's title. See docs/command-line-setup-design.md, "Three facts,
// kept separate" and "Settings > Command Line". Pure; the pane renders these.

struct CommandLineSetupRowViewModel: Equatable {
    let verdict: String
    let badgeText: String
    /// The abbreviated resolved path, or "No unison command".
    let pathLine: String
    let note: String?
    /// The single action's button title, or nil when there is no action.
    let actionTitle: String?
}

enum CommandLineSetupViewModel {

    static func verdict(for badge: CommandLineSetupBadge) -> String {
        switch badge {
        case .thisApp: return "This app selected by the check"
        case .notThisApp: return "Another unison selected by the check"
        case .notInstalled: return "No unison selected by the check"
        case .unknown: return "Could not be checked"
        case .manualSetup: return "Needs manual setup"
        }
    }

    static func badgeText(for badge: CommandLineSetupBadge) -> String {
        switch badge {
        case .thisApp: return "This app"
        case .notThisApp: return "Not this app"
        case .notInstalled: return "Not installed"
        case .unknown: return "Unknown"
        case .manualSetup: return "Manual setup"
        }
    }

    static func actionTitle(for action: CommandLineSetupAction) -> String? {
        switch action {
        case .none: return nil
        case .add: return "Add Terminal Setup…"
        case .remove: return "Remove Terminal Setup…"
        case .useThisCopy: return "Use This Copy…"
        }
    }

    /// Abbreviate a path inside an app bundle as `<App>.app › <tail after
    /// Contents/>`; other paths are shown in full.
    static func abbreviatedPath(_ path: String) -> String {
        guard let r = path.range(of: ".app/Contents/") else { return path }
        let beforeDotApp = String(path[..<r.lowerBound])
        let appName = (beforeDotApp as NSString).lastPathComponent + ".app"
        let tail = String(path[r.upperBound...])
        return "\(appName) › \(tail)"
    }

    /// The path evidence line for a resolution: the resolved command abbreviated,
    /// this app's own command for `thisApp`, or "No unison command".
    static func pathLine(resolution: CommandLineSetupResolution, thisCommandPath: String) -> String {
        switch resolution {
        case .thisApp: return abbreviatedPath(thisCommandPath)
        case .anotherUnison(let path): return abbreviatedPath(path)
        case .none, .couldNotCheck: return "No unison command"
        }
    }

    static func rowViewModel(state: CommandLineSetupState,
                             resolution: CommandLineSetupResolution,
                             thisCommandPath: String) -> CommandLineSetupRowViewModel {
        CommandLineSetupRowViewModel(
            verdict: verdict(for: state.badge),
            badgeText: badgeText(for: state.badge),
            pathLine: pathLine(resolution: resolution, thisCommandPath: thisCommandPath),
            note: state.note,
            actionTitle: actionTitle(for: state.action))
    }

    // MARK: Copy This App's Command Path

    /// Whether a command path holds characters outside `A–Z a–z 0–9 . _ / + -`,
    /// which need care in a profile's servercmd.
    static func commandPathNeedsCare(_ path: String) -> Bool {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/+-")
        return !path.allSatisfy { safe.contains($0) }
    }

    static let commandPathFootnote = "The full path, for servercmd in a profile on another machine."
    static let commandPathCareNote =
        "Contains characters that need care in a profile's servercmd; the remote check can assess it."
}
