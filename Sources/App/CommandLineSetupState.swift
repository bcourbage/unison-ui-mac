import Foundation

// The state table from docs/command-line-setup-design.md, "State table": from
// what `unison` resolves to, the block's state, the editable bound and the bundle
// precondition, decide the badge, the note, the single action, and what a startup
// check with the preference on would do. Pure; the controller supplies the facts
// and applies the preference and the once-per-launch rule.

/// What `unison` resolves to in this account's login shell (the probe).
enum CommandLineSetupResolution: Equatable, Sendable {
    /// Resolves to this running bundle's command (by any route).
    case thisApp
    /// Resolves to some other unison.
    case anotherUnison(path: String)
    /// Resolves to nothing.
    case none
    /// The probe did not complete.
    case couldNotCheck
}

/// The block's presence and, when it records a location other than this bundle,
/// what that location is.
enum CommandLineSetupBlockPresence: Equatable {
    /// No block with the app's markers in the selected file.
    case none
    /// An owned block recording this bundle's present path.
    case ownedCurrent
    /// An owned block recording a different location.
    case ownedElsewhere(RecordedLocation)

    enum RecordedLocation: Equatable {
        /// An existing copy of this app other than the running one (rows 4).
        case otherExistingCopy
        /// The recorded location could not be inspected (row 5).
        case cannotInspect
        /// Absent (`ENOENT`), or present but not a copy of this app (row 6).
        case absentOrNotThisApp
    }
}

enum CommandLineSetupBadge: Equatable, Sendable {
    case thisApp, notThisApp, notInstalled, unknown, manualSetup
}

enum CommandLineSetupAction: Equatable, Sendable {
    case none, add, remove, useThisCopy
}

/// What a startup check would do in this state when the preference is on. The
/// controller still gates this on the preference, the once-per-launch rule, and
/// headless/server/test-host launches.
enum CommandLineSetupStartupBehavior: Equatable, Sendable {
    case none
    /// Show the offer; on Add, write and report the outcome (rows 11, 12).
    case offer
    /// Rewrite the block with this app's current path (row 6).
    case rewriteToCurrent
}

struct CommandLineSetupState: Equatable, Sendable {
    let row: Int
    let badge: CommandLineSetupBadge
    let note: String?
    let action: CommandLineSetupAction
    let startup: CommandLineSetupStartupBehavior
}

/// The facts the state table is evaluated from. `manualSetupReason`, when set,
/// means the shell is unsupported, the file is outside the editable bound, the
/// path is unrepresentable, or the block is foreign: row 2.
struct CommandLineSetupFacts: Equatable {
    let resolution: CommandLineSetupResolution
    let manualSetupReason: String?
    let bundlePreconditionOK: Bool
    let block: CommandLineSetupBlockPresence
}

enum CommandLineSetupStateTable {

    static func badge(for resolution: CommandLineSetupResolution) -> CommandLineSetupBadge {
        switch resolution {
        case .thisApp: return .thisApp
        case .anotherUnison: return .notThisApp
        case .none: return .notInstalled
        case .couldNotCheck: return .unknown
        }
    }

    /// The first matching row of the state table.
    static func evaluate(_ facts: CommandLineSetupFacts) -> CommandLineSetupState {
        // Row 1: the probe failed.
        if facts.resolution == .couldNotCheck {
            return CommandLineSetupState(row: 1, badge: .unknown,
                                         note: "Your shell's PATH could not be read.",
                                         action: .none, startup: .none)
        }
        // Row 2: Manual setup.
        if let reason = facts.manualSetupReason {
            return CommandLineSetupState(row: 2, badge: .manualSetup, note: reason,
                                         action: .none, startup: .none)
        }
        // Row 3: the bundle precondition failed. Remove is still permitted for an
        // owned block; nothing else, and no startup write.
        if !facts.bundlePreconditionOK {
            let removable: CommandLineSetupAction
            switch facts.block {
            case .none: removable = .none
            case .ownedCurrent, .ownedElsewhere: removable = .remove
            }
            return CommandLineSetupState(row: 3, badge: badge(for: facts.resolution),
                                         note: CommandLineSetupBundle.missingCommandNote,
                                         action: removable, startup: .none)
        }
        let b = badge(for: facts.resolution)
        switch facts.block {
        case .ownedElsewhere(.otherExistingCopy):
            return CommandLineSetupState(row: 4, badge: b,
                                         note: "Another copy of this app owns the PATH entry.",
                                         action: .useThisCopy, startup: .none)
        case .ownedElsewhere(.cannotInspect):
            return CommandLineSetupState(row: 5, badge: b,
                                         note: "The previous app location could not be checked.",
                                         action: .useThisCopy, startup: .none)
        case .ownedElsewhere(.absentOrNotThisApp):
            return CommandLineSetupState(row: 6, badge: b, note: nil,
                                         action: .remove, startup: .rewriteToCurrent)
        case .ownedCurrent:
            switch facts.resolution {
            case .thisApp:
                return CommandLineSetupState(row: 7, badge: .thisApp, note: nil, action: .remove, startup: .none)
            case .anotherUnison:
                return CommandLineSetupState(row: 8, badge: .notThisApp,
                                             note: "Your shell still selects another unison.",
                                             action: .remove, startup: .none)
            case .none:
                return CommandLineSetupState(row: 9, badge: .notInstalled,
                                             note: "Your shell still selects no unison.",
                                             action: .remove, startup: .none)
            case .couldNotCheck:
                return CommandLineSetupState(row: 1, badge: .unknown,
                                             note: "Your shell's PATH could not be read.",
                                             action: .none, startup: .none)
            }
        case .none:
            switch facts.resolution {
            case .thisApp:
                return CommandLineSetupState(row: 10, badge: .thisApp, note: nil, action: .add, startup: .none)
            case .anotherUnison:
                return CommandLineSetupState(row: 11, badge: .notThisApp,
                                             note: "Another unison comes first on your PATH.",
                                             action: .add, startup: .offer)
            case .none:
                return CommandLineSetupState(row: 12, badge: .notInstalled, note: nil, action: .add, startup: .offer)
            case .couldNotCheck:
                return CommandLineSetupState(row: 1, badge: .unknown,
                                             note: "Your shell's PATH could not be read.",
                                             action: .none, startup: .none)
            }
        }
    }
}
