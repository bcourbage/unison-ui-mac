import Foundation

// Ties the probe, file selection, editable bound, writer and ownership record
// into the read path the pane shows and the Add / Remove / Use This Copy /
// startup-rewrite operations. The outside-world calls are injected through
// CommandLineSetupEnvironment so the read path and the operations are testable
// against temp files and fakes. See docs/command-line-setup-design.md.

/// The outside-world operations the coordinator needs, injected for testing.
/// Immutable and made of pure closures, so it is `Sendable` and can cross the
/// off-main hop the status computation runs on.
struct CommandLineSetupEnvironment: Sendable {
    var accountRecord: @Sendable () -> CommandLineSetupProbe.AccountRecord?
    var resolvedUnison: @Sendable (_ shellPath: String, _ kind: CommandLineSetupShellKind) -> CommandLineSetupProbe.ProbeOutput
    var fishConfigDirectory: @Sendable (_ fishPath: String) -> String?
    var etcZshenvExists: @Sendable () -> Bool
    var homeZshenvExists: @Sendable (_ home: String) -> Bool
    var etcZprofileContents: @Sendable () -> String?
    var zdotdirLaunchd: @Sendable () -> CommandLineSetupZDOTDIRState
    var zdotdirAppEnvironment: @Sendable () -> Bool
    /// (text, shellPath) -> whether `shellPath -n` accepts it.
    var parses: @Sendable (_ text: String, _ shellPath: String) -> Bool
    var metadataOK: @Sendable (_ resolvedPath: String) -> Bool

    static let real = CommandLineSetupEnvironment(
        accountRecord: { CommandLineSetupProbe.accountRecord() },
        resolvedUnison: { CommandLineSetupProbe.resolvedUnison(shellPath: $0, kind: $1) },
        fishConfigDirectory: { CommandLineSetupProbe.fishConfigDirectory(fishPath: $0) },
        etcZshenvExists: { CommandLineSetupProbe.etcZshenvExists() },
        homeZshenvExists: { CommandLineSetupProbe.homeZshenvExists(homeDirectory: $0) },
        etcZprofileContents: { CommandLineSetupProbe.etcZprofileContents() },
        zdotdirLaunchd: { CommandLineSetupProbe.zdotdirFromLaunchd() },
        zdotdirAppEnvironment: { CommandLineSetupProbe.zdotdirInAppEnvironment() },
        parses: { CommandLineSetupEffects.parses(text: $0, shellPath: $1) },
        metadataOK: { CommandLineSetupEffects.metadataOK(resolvedPath: $0) })
}

/// The read-path result: everything the pane and the startup check need.
struct CommandLineSetupStatusReport: Sendable {
    let state: CommandLineSetupState
    let resolution: CommandLineSetupResolution
    let fileChoice: CommandLineSetupFileChoice
    let thisBinDirectory: String
    let thisCommandPath: String
    let viewModel: CommandLineSetupRowViewModel
}

enum CommandLineSetupCoordinator {

    // MARK: Read path

    /// Compute the full status. Blocks on subprocesses; call off the main thread.
    static func status(bundleURL: URL,
                       environment env: CommandLineSetupEnvironment = .real,
                       fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem(),
                       defaults: UserDefaults = .standard) -> CommandLineSetupStatusReport {
        let thisBinDirectory = CommandLineSetupBundle.binDirectory(bundleURL: bundleURL)
        let thisCommandPath = CommandLineSetupBundle.commandPath(bundleURL: bundleURL)
        let launcherPath = CommandLineSetupBundle.launcherPath(bundleURL: bundleURL)
        let preconditionOK = CommandLineSetupBundle.preconditionSatisfied(bundleURL: bundleURL, fs: fs)

        guard let account = env.accountRecord() else {
            let facts = CommandLineSetupFacts(resolution: .couldNotCheck, manualSetupReason: nil,
                                              bundlePreconditionOK: preconditionOK, block: .none)
            return report(facts: facts, resolution: .couldNotCheck,
                          fileChoice: CommandLineSetupFileSelection.otherChoice(),
                          thisBinDirectory: thisBinDirectory, thisCommandPath: thisCommandPath)
        }

        let kind = CommandLineSetupShellKind.of(loginShellPath: account.loginShellPath)
        let resolution = CommandLineSetupProbe.classify(
            env.resolvedUnison(account.loginShellPath, kind),
            thisLauncherPath: launcherPath, realPathOf: { fs.realPath(ofPath: $0) })

        // If our own bin directory cannot be represented in a PATH entry, no shell
        // can be set up automatically: Manual setup.
        if !CommandLineSetupBlock.isRepresentable(directory: thisBinDirectory) {
            let facts = CommandLineSetupFacts(resolution: resolution,
                                              manualSetupReason: "the app's path contains a character that cannot be written to a PATH entry, so setup is manual",
                                              bundlePreconditionOK: preconditionOK, block: .none)
            return report(facts: facts, resolution: resolution,
                          fileChoice: fileChoice(kind: kind, account: account, env: env, fs: fs),
                          thisBinDirectory: thisBinDirectory, thisCommandPath: thisCommandPath)
        }

        let choice = fileChoice(kind: kind, account: account, env: env, fs: fs)
        let evaluation = boundEvaluation(kind: kind, choice: choice, thisBinDirectory: thisBinDirectory,
                                         account: account, env: env, fs: fs, defaults: defaults)
        let facts = CommandLineSetupFactsBuilder.build(
            resolution: resolution, bundlePreconditionOK: preconditionOK, fileChoice: choice,
            boundEvaluation: evaluation, thisBinDirectory: thisBinDirectory, fs: fs)
        return report(facts: facts, resolution: resolution, fileChoice: choice,
                      thisBinDirectory: thisBinDirectory, thisCommandPath: thisCommandPath)
    }

    private static func report(facts: CommandLineSetupFacts,
                               resolution: CommandLineSetupResolution,
                               fileChoice: CommandLineSetupFileChoice,
                               thisBinDirectory: String,
                               thisCommandPath: String) -> CommandLineSetupStatusReport {
        let state = CommandLineSetupStateTable.evaluate(facts)
        return CommandLineSetupStatusReport(
            state: state, resolution: resolution, fileChoice: fileChoice,
            thisBinDirectory: thisBinDirectory, thisCommandPath: thisCommandPath,
            viewModel: CommandLineSetupViewModel.rowViewModel(state: state, resolution: resolution,
                                                              thisCommandPath: thisCommandPath))
    }

    static func fileChoice(kind: CommandLineSetupShellKind,
                           account: CommandLineSetupProbe.AccountRecord,
                           env: CommandLineSetupEnvironment,
                           fs: CommandLineToolFileSystem) -> CommandLineSetupFileChoice {
        switch kind {
        case .zsh:
            return CommandLineSetupFileSelection.zshChoice(
                homeDirectory: account.homeDirectory,
                etcZshenvExists: env.etcZshenvExists(),
                homeZshenvExists: env.homeZshenvExists(account.homeDirectory),
                etcZprofileContents: env.etcZprofileContents(),
                zdotdir: env.zdotdirLaunchd(),
                zdotdirInAppEnvironment: env.zdotdirAppEnvironment())
        case .bash:
            return CommandLineSetupFileSelection.bashChoice(
                homeDirectory: account.homeDirectory,
                existing: { fs.entryExists(atPath: $0) },
                readable: { fs.contentsOfFile(atPath: $0) != nil })
        case .fish:
            return CommandLineSetupFileSelection.fishChoice(
                configDirectory: env.fishConfigDirectory(account.loginShellPath),
                directoryExists: { fs.isDirectory(atPath: $0) })
        case .other:
            return CommandLineSetupFileSelection.otherChoice()
        }
    }

    /// The bound evaluation for the selected file, or nil when the file is Manual
    /// setup for a shell/layout reason. fish uses its whole-file template rather
    /// than the zsh/bash bound.
    static func boundEvaluation(kind: CommandLineSetupShellKind,
                                choice: CommandLineSetupFileChoice,
                                thisBinDirectory: String,
                                account: CommandLineSetupProbe.AccountRecord,
                                env: CommandLineSetupEnvironment,
                                fs: CommandLineToolFileSystem,
                                defaults: UserDefaults) -> CommandLineSetupBound.Evaluation? {
        guard choice.automatic, let file = choice.file else { return nil }

        if kind == .fish {
            return fishEvaluation(file: file, fs: fs, defaults: defaults)
        }

        guard let contents = fs.contentsOfFile(atPath: file) else {
            // Automatic and the file does not exist yet: a creation appends.
            return .appendable
        }
        let resolved = fs.realPath(ofPath: file) ?? file
        let wholeParses = env.parses(contents, account.loginShellPath)
        let prefixText: String
        if case .single(let beginLine, _) = CommandLineSetupBlock.markerArrangement(inContents: contents) {
            prefixText = contents.components(separatedBy: "\n")[0..<beginLine].joined(separator: "\n")
        } else {
            prefixText = ""
        }
        let prefixParses = prefixText.isEmpty ? true : env.parses(prefixText, account.loginShellPath)
        let metadataOK = env.metadataOK(resolved)
        return CommandLineSetupBound.evaluateExistingFile(
            contents: contents, wholeFileParses: wholeParses, prefixParses: prefixParses,
            metadataOK: metadataOK,
            ownershipMatches: { blockText in
                CommandLineSetupRecordStore.isOwned(path: resolved,
                                                    blockHash: CommandLineSetupBlock.hash(ofBlockText: blockText),
                                                    defaults: defaults)
            })
    }

    private static func fishEvaluation(file: String, fs: CommandLineToolFileSystem,
                                       defaults: UserDefaults) -> CommandLineSetupBound.Evaluation {
        guard let contents = fs.contentsOfFile(atPath: file) else { return .appendable }
        guard let directory = CommandLineSetupBlock.fishTemplateDirectory(ofFileContents: contents) else {
            return .foreignBlock(reason: "a fish file with this app's name exists whose content the app did not write")
        }
        let resolved = fs.realPath(ofPath: file) ?? file
        let owned = CommandLineSetupRecordStore.isOwned(
            path: resolved, blockHash: CommandLineSetupBlock.hash(ofBlockText: contents), defaults: defaults)
        guard owned else {
            return .foreignBlock(reason: "a fish file with this app's name exists that this app did not write, or that was edited")
        }
        return .rewritable(beginLine: 0, endLine: 0, currentDirectory: directory)
    }

    // MARK: Write operations

    /// Add or rewrite this app's entry in `resolvedPath` (or create it), recording
    /// ownership. `newContents` is the file's whole new text; `blockHash` is the
    /// hash to record. `create` chooses creation vs replacement; `ensureParent` is
    /// for fish's conf.d.
    static func write(resolvedPath: String,
                      newContents: String,
                      blockHash: String,
                      binDirectory: String,
                      create: Bool,
                      ensureParent: Bool,
                      now: Date = Date(),
                      defaults: UserDefaults = .standard) -> CommandLineSetupWriteOutcome {
        let record = CommandLineSetupOwnership(path: resolvedPath, hash: blockHash,
                                               bundlePath: binDirectory, date: now)
        guard CommandLineSetupRecordStore.writePending(record, defaults: defaults) else {
            return .notMutated(reason: CommandLineSetupStatusLine.recordFailed)
        }
        let outcome: CommandLineSetupWriteOutcome
        if create {
            outcome = CommandLineSetupWriter.create(resolvedPath: resolvedPath, contents: newContents,
                                                    ensuringParentDirectory: ensureParent)
        } else {
            guard let snapshot = CommandLineSetupWriter.snapshot(atPath: resolvedPath) else {
                CommandLineSetupRecordStore.deletePending(defaults: defaults)
                return .notMutated(reason: "the file could not be read before writing")
            }
            outcome = CommandLineSetupWriter.replace(resolvedPath: resolvedPath, newContents: newContents,
                                                     expected: snapshot)
        }
        applyRecordOutcome(outcome, defaults: defaults)
        return outcome
    }

    /// Remove this app's entry: delete the fish file, or rewrite a zsh/bash file
    /// with the block gone. `fishFile` true deletes the whole file.
    static func remove(resolvedPath: String,
                       newContents: String?,
                       fishFile: Bool,
                       defaults: UserDefaults = .standard) -> CommandLineSetupWriteOutcome {
        let outcome: CommandLineSetupWriteOutcome
        if fishFile {
            guard let snapshot = CommandLineSetupWriter.snapshot(atPath: resolvedPath) else {
                return .notMutated(reason: "the file could not be read before writing")
            }
            outcome = CommandLineSetupWriter.removeFile(resolvedPath: resolvedPath, expected: snapshot)
        } else {
            guard let newContents,
                  let snapshot = CommandLineSetupWriter.snapshot(atPath: resolvedPath) else {
                return .notMutated(reason: "the file could not be read before writing")
            }
            outcome = CommandLineSetupWriter.replace(resolvedPath: resolvedPath, newContents: newContents,
                                                     expected: snapshot)
        }
        if case .mutated = outcome { CommandLineSetupRecordStore.deleteBoth(defaults: defaults) }
        return outcome
    }

    private static func applyRecordOutcome(_ outcome: CommandLineSetupWriteOutcome, defaults: UserDefaults) {
        switch outcome {
        case .mutated: CommandLineSetupRecordStore.promote(defaults: defaults)
        case .mutatedReadBackFailed, .uncertain: break  // keep pending
        case .notMutated: CommandLineSetupRecordStore.deletePending(defaults: defaults)
        }
    }

    // MARK: High-level actions

    /// The result of an action: the transient status line, the removal's second
    /// line, and the refreshed status the pane redraws from.
    struct ActionResult: Sendable {
        let statusLine: String
        let secondLine: String?
        let refreshed: CommandLineSetupStatusReport
    }

    /// Add or update this app's entry, then re-probe. Turns the preference on.
    /// `rewrite` true rewrites an existing owned block (Use This Copy / row 6);
    /// false appends a new one.
    static func performAdd(report: CommandLineSetupStatusReport,
                           bundleURL: URL,
                           rewrite: Bool,
                           environment env: CommandLineSetupEnvironment = .real,
                           fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem(),
                           defaults: UserDefaults = .standard,
                           now: Date = Date()) -> ActionResult {
        let choice = report.fileChoice
        let binDir = report.thisBinDirectory
        guard choice.automatic, let file = choice.file else {
            return ActionResult(statusLine: CommandLineSetupBundle.missingCommandNote, secondLine: nil, refreshed: report)
        }
        let outcome: CommandLineSetupWriteOutcome
        if choice.shell == .fish {
            let text = CommandLineSetupBlock.fishFileText(directory: binDir) ?? ""
            let exists = fs.entryExists(atPath: file)
            let resolved = fs.realPath(ofPath: file) ?? file
            outcome = write(resolvedPath: exists ? resolved : file, newContents: text,
                            blockHash: CommandLineSetupBlock.hash(ofBlockText: text), binDirectory: binDir,
                            create: !exists, ensureParent: true, now: now, defaults: defaults)
        } else {
            let blockText = CommandLineSetupBlock.blockText(directory: binDir) ?? ""
            let blockHash = CommandLineSetupBlock.hash(ofBlockText: blockText)
            if let contents = fs.contentsOfFile(atPath: file) {
                let resolved = fs.realPath(ofPath: file) ?? file
                let newContents: String
                if rewrite, case .single(let b, let e) = CommandLineSetupBlock.markerArrangement(inContents: contents) {
                    newContents = CommandLineSetupEdit.rewritten(contents, beginLine: b, endLine: e, newBlockText: blockText)
                } else {
                    newContents = CommandLineSetupEdit.appended(to: contents, blockText: blockText)
                }
                outcome = write(resolvedPath: resolved, newContents: newContents, blockHash: blockHash,
                                binDirectory: binDir, create: false, ensureParent: false, now: now, defaults: defaults)
            } else {
                outcome = write(resolvedPath: file, newContents: blockText + "\n", blockHash: blockHash,
                                binDirectory: binDir, create: true, ensureParent: false, now: now, defaults: defaults)
            }
        }
        CommandLineSetupPreference.setKeepInTerminal(true, defaults: defaults)
        let refreshed = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
        return ActionResult(statusLine: CommandLineSetupStatusLine.afterWrite(outcome, postResolution: refreshed.resolution),
                            secondLine: nil, refreshed: refreshed)
    }

    /// Remove this app's entry, then re-probe. Turns the preference off.
    static func performRemove(report: CommandLineSetupStatusReport,
                              bundleURL: URL,
                              environment env: CommandLineSetupEnvironment = .real,
                              fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem(),
                              defaults: UserDefaults = .standard) -> ActionResult {
        let choice = report.fileChoice
        guard let file = choice.file else {
            return ActionResult(statusLine: "There is no entry to remove.", secondLine: nil, refreshed: report)
        }
        let resolved = fs.realPath(ofPath: file) ?? file
        let outcome: CommandLineSetupWriteOutcome
        if choice.shell == .fish {
            outcome = remove(resolvedPath: resolved, newContents: nil, fishFile: true, defaults: defaults)
        } else if let contents = fs.contentsOfFile(atPath: file),
                  case .single(let b, let e) = CommandLineSetupBlock.markerArrangement(inContents: contents) {
            outcome = remove(resolvedPath: resolved,
                             newContents: CommandLineSetupEdit.removed(contents, beginLine: b, endLine: e),
                             fishFile: false, defaults: defaults)
        } else {
            outcome = .notMutated(reason: "no entry from this app was found to remove")
        }
        CommandLineSetupPreference.setKeepInTerminal(false, defaults: defaults)
        let refreshed = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
        let (first, second) = CommandLineSetupStatusLine.afterRemove(outcome, postResolution: refreshed.resolution)
        return ActionResult(statusLine: first, secondLine: second, refreshed: refreshed)
    }

    // MARK: Off-main wrappers

    /// The status, computed on a GCD utility queue so the login-shell probe never
    /// blocks the main thread or the cooperative pool.
    static func statusAsync(bundleURL: URL, defaults: UserDefaults = .standard) async -> CommandLineSetupStatusReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: status(bundleURL: bundleURL, defaults: defaults))
            }
        }
    }

    static func performAddAsync(report: CommandLineSetupStatusReport, bundleURL: URL, rewrite: Bool,
                                defaults: UserDefaults = .standard) async -> ActionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: performAdd(report: report, bundleURL: bundleURL, rewrite: rewrite,
                                                          defaults: defaults))
            }
        }
    }

    static func performRemoveAsync(report: CommandLineSetupStatusReport, bundleURL: URL,
                                   defaults: UserDefaults = .standard) async -> ActionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: performRemove(report: report, bundleURL: bundleURL, defaults: defaults))
            }
        }
    }
}
