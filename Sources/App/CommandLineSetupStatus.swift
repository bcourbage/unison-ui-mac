import Foundation

// Assembling the state-table facts from the probe, file selection and bound, and
// the words for the last write's outcome and the Refresh age. See
// docs/command-line-setup-design.md, "State table" and "Outcomes". Pure.

enum CommandLineSetupFactsBuilder {

    /// Build the state-table facts. `boundEvaluation` is nil when the selected file
    /// is Manual setup for a reason the shell/layout already decided (an
    /// unsupported shell, the zsh bound, an unreadable bash file), in which case
    /// that reason drives row 2. When the file is editable, the bound's result
    /// decides the block presence, and a foreign or unparsable file is row 2 too.
    static func build(resolution: CommandLineSetupResolution,
                      bundlePreconditionOK: Bool,
                      fileChoice: CommandLineSetupFileChoice,
                      boundEvaluation: CommandLineSetupBound.Evaluation?,
                      thisBinDirectory: String,
                      fs: CommandLineToolFileSystem) -> CommandLineSetupFacts {
        var manual: String?
        var block: CommandLineSetupBlockPresence = .none

        if !fileChoice.automatic {
            manual = fileChoice.manualReason
        } else if let evaluation = boundEvaluation {
            switch evaluation {
            case .appendable:
                block = .none
            case .foreignBlock(let reason):
                manual = reason
            case .manualSetup(let reason):
                manual = reason
            case .rewritable(_, _, let currentDirectory):
                if currentDirectory == thisBinDirectory {
                    block = .ownedCurrent
                } else {
                    block = .ownedElsewhere(inspectRecorded(binDirectory: currentDirectory, fs: fs))
                }
            }
        }

        return CommandLineSetupFacts(resolution: resolution, manualSetupReason: manual,
                                     bundlePreconditionOK: bundlePreconditionOK, block: block)
    }

    /// Classify the location a non-current owned block records, from its `bin`
    /// directory. Absence or a non-copy is `absentOrNotThisApp`; a readable copy
    /// of this app is `otherExistingCopy`; a directory whose identifier cannot be
    /// read is `cannotInspect`.
    static func inspectRecorded(binDirectory: String,
                                fs: CommandLineToolFileSystem) -> CommandLineSetupBlockPresence.RecordedLocation {
        // The bundle is the bin directory with /Contents/SharedSupport/bin removed.
        let suffix = "/Contents/SharedSupport/bin"
        guard binDirectory.hasSuffix(suffix) else { return .absentOrNotThisApp }
        let bundlePath = String(binDirectory.dropLast(suffix.count))
        guard fs.entryExists(atPath: bundlePath) else { return .absentOrNotThisApp }
        guard let id = fs.bundleIdentifier(ofBundleAtPath: bundlePath) else { return .cannotInspect }
        if id == CommandLineToolStatus.ourBundleIdentifier,
           fs.isExecutableFile(atPath: bundlePath + "/Contents/MacOS/cltool") {
            return .otherExistingCopy
        }
        return .absentOrNotThisApp
    }
}

enum CommandLineSetupStatusLine {

    /// The status line after an Add, Use This Copy, or a startup offer's write.
    /// `postResolution` is the login-shell probe run again after the write.
    static func afterWrite(_ outcome: CommandLineSetupWriteOutcome,
                           postResolution: CommandLineSetupResolution) -> String {
        switch outcome {
        case .mutated:
            switch postResolution {
            case .thisApp: return "Entry written and selected."
            case .anotherUnison: return "Entry written; your shell still selects another unison."
            case .none: return "Entry written; your shell selects no unison."
            case .couldNotCheck: return "Entry written; command selection could not be checked."
            }
        case .mutatedReadBackFailed:
            return "Entry written; the result could not be read back."
        case .uncertain:
            return "The file operation's result could not be established."
        case .notMutated(let reason):
            return reason
        }
    }

    /// The status line after a startup rewrite in row 6 (the app moved and the
    /// recorded path is gone). Success is stated as an update to this location.
    static func afterRewrite(_ outcome: CommandLineSetupWriteOutcome) -> String {
        switch outcome {
        case .mutated, .mutatedReadBackFailed:
            return "PATH entry updated to this app's location."
        case .uncertain:
            return "The file operation's result could not be established."
        case .notMutated(let reason):
            return reason
        }
    }

    /// The two lines after a Remove: the removal result, then the subsequent
    /// resolution reported separately. Returns nil second line when the removal
    /// itself did not succeed.
    static func afterRemove(_ outcome: CommandLineSetupWriteOutcome,
                            postResolution: CommandLineSetupResolution) -> (String, String?) {
        switch outcome {
        case .mutated, .mutatedReadBackFailed:
            let second: String
            switch postResolution {
            case .thisApp: second = "Your shell now selects this app."
            case .anotherUnison(let path): second = "Your shell now selects \(path)."
            case .none: second = "Your shell now selects no unison."
            case .couldNotCheck: second = "Command selection could not be checked."
            }
            return ("PATH entry removed.", second)
        case .uncertain:
            return ("The file operation's result could not be established.", nil)
        case .notMutated(let reason):
            return (reason, nil)
        }
    }

    /// The refusal when the pending ownership record could not be written.
    static let recordFailed = "The entry could not be recorded. Nothing was written."
}

enum CommandLineSetupAging {

    /// "Not checked yet" before the first check, else "Checked N minutes ago"
    /// (or "just now" under a minute). `now` and `lastChecked` are injected.
    static func checkedText(lastChecked: Date?, now: Date) -> String {
        guard let lastChecked else { return "Not checked yet" }
        let seconds = Int(now.timeIntervalSince(lastChecked))
        if seconds < 60 { return "Checked just now" }
        let minutes = seconds / 60
        if minutes == 1 { return "Checked 1 minute ago" }
        if minutes < 60 { return "Checked \(minutes) minutes ago" }
        let hours = minutes / 60
        if hours == 1 { return "Checked 1 hour ago" }
        return "Checked \(hours) hours ago"
    }
}
