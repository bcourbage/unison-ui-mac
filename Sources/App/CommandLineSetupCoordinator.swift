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

    /// Record the pending ownership, then replace `resolvedPath` with `newContents`
    /// guarded by `expected` — the identity from the SAME read that produced the
    /// text, so an intervening save is refused at the seam rather than overwritten
    /// with text derived from the older file.
    private static func writeReplace(resolvedPath: String, newContents: String,
                                     blockHash: String, binDirectory: String,
                                     expected: CommandLineSetupFileIdentity,
                                     now: Date, defaults: UserDefaults) -> CommandLineSetupWriteOutcome {
        let record = CommandLineSetupOwnership(path: resolvedPath, hash: blockHash,
                                               bundlePath: binDirectory, date: now)
        guard CommandLineSetupRecordStore.writePending(record, defaults: defaults) else {
            return .notMutated(reason: CommandLineSetupStatusLine.recordFailed)
        }
        let outcome = CommandLineSetupWriter.replace(resolvedPath: resolvedPath,
                                                     newContents: newContents, expected: expected)
        applyRecordOutcome(outcome, defaults: defaults)
        return outcome
    }

    /// Record the pending ownership, then create `resolvedPath` (RENAME_EXCL).
    private static func writeCreate(resolvedPath: String, contents: String,
                                    blockHash: String, binDirectory: String,
                                    ensureParent: Bool, now: Date,
                                    defaults: UserDefaults) -> CommandLineSetupWriteOutcome {
        let record = CommandLineSetupOwnership(path: resolvedPath, hash: blockHash,
                                               bundlePath: binDirectory, date: now)
        guard CommandLineSetupRecordStore.writePending(record, defaults: defaults) else {
            return .notMutated(reason: CommandLineSetupStatusLine.recordFailed)
        }
        let outcome = CommandLineSetupWriter.create(resolvedPath: resolvedPath, contents: contents,
                                                    ensuringParentDirectory: ensureParent)
        applyRecordOutcome(outcome, defaults: defaults)
        return outcome
    }

    private static func applyRecordOutcome(_ outcome: CommandLineSetupWriteOutcome, defaults: UserDefaults) {
        switch outcome {
        case .mutated: CommandLineSetupRecordStore.promote(defaults: defaults)
        case .mutatedReadBackFailed, .uncertain: break  // keep pending
        case .notMutated: CommandLineSetupRecordStore.deletePending(defaults: defaults)
        }
    }

    /// Whether the write appends a new block or rewrites an existing owned one.
    private enum WriteIntent { case append, rewrite }

    /// Whether `contents` (the guarding read) is still this app's OWNED entry for
    /// `resolvedPath`, validated on the SAME bytes that will guard the mutation, so
    /// ownership and the seam guard never describe different reads. zsh/bash require
    /// a single block matching the template and the ownership record; fish requires
    /// the whole file to match.
    private static func isOwnedEntry(shell: CommandLineSetupShellKind, resolvedPath: String,
                                     contents: String, defaults: UserDefaults) -> Bool {
        if shell == .fish {
            guard CommandLineSetupBlock.fishTemplateDirectory(ofFileContents: contents) != nil else { return false }
            return CommandLineSetupRecordStore.isOwned(
                path: resolvedPath, blockHash: CommandLineSetupBlock.hash(ofBlockText: contents), defaults: defaults)
        }
        guard case .single(let b, let e) = CommandLineSetupBlock.markerArrangement(inContents: contents) else { return false }
        let block = CommandLineSetupBlock.blockText(inContents: contents, beginLine: b, endLine: e)
        guard CommandLineSetupBlock.templateDirectory(ofBlockText: block) != nil else { return false }
        return CommandLineSetupRecordStore.isOwned(
            path: resolvedPath, blockHash: CommandLineSetupBlock.hash(ofBlockText: block), defaults: defaults)
    }

    /// Write this app's entry into `file`, reading the content and the snapshot that
    /// guards it in ONE read, and validating ownership on THAT content: an append
    /// refuses if a block has appeared, a rewrite refuses if the block is no longer
    /// this app's owned block. Shared by Add, Use This Copy and the startup rewrite.
    private static func writeEntry(shell: CommandLineSetupShellKind, file: String,
                                   binDirectory: String, intent: WriteIntent,
                                   fs: CommandLineToolFileSystem, now: Date,
                                   defaults: UserDefaults) -> CommandLineSetupWriteOutcome {
        let resolved = fs.realPath(ofPath: file) ?? file
        if shell == .fish {
            let text = CommandLineSetupBlock.fishFileText(directory: binDirectory) ?? ""
            let hash = CommandLineSetupBlock.hash(ofBlockText: text)
            if fs.entryExists(atPath: file) {
                guard let snap = CommandLineSetupWriter.snapshotWithContents(atPath: resolved) else {
                    return .notMutated(reason: "the file could not be read before writing")
                }
                guard intent == .rewrite,
                      isOwnedEntry(shell: .fish, resolvedPath: resolved, contents: snap.contents, defaults: defaults) else {
                    return .notMutated(reason: situationChanged)
                }
                return writeReplace(resolvedPath: resolved, newContents: text, blockHash: hash,
                                    binDirectory: binDirectory, expected: snap.identity, now: now, defaults: defaults)
            }
            guard intent == .append else { return .notMutated(reason: situationChanged) }
            return writeCreate(resolvedPath: file, contents: text, blockHash: hash,
                               binDirectory: binDirectory, ensureParent: true, now: now, defaults: defaults)
        }
        let blockText = CommandLineSetupBlock.blockText(directory: binDirectory) ?? ""
        let hash = CommandLineSetupBlock.hash(ofBlockText: blockText)
        if fs.entryExists(atPath: file) {
            guard let snap = CommandLineSetupWriter.snapshotWithContents(atPath: resolved) else {
                return .notMutated(reason: "the file could not be read before writing")
            }
            switch (intent, CommandLineSetupBlock.markerArrangement(inContents: snap.contents)) {
            case (.append, .none):
                return writeReplace(resolvedPath: resolved,
                                    newContents: CommandLineSetupEdit.appended(to: snap.contents, blockText: blockText),
                                    blockHash: hash, binDirectory: binDirectory, expected: snap.identity,
                                    now: now, defaults: defaults)
            case (.rewrite, .single(let b, let e)):
                guard isOwnedEntry(shell: shell, resolvedPath: resolved, contents: snap.contents, defaults: defaults) else {
                    return .notMutated(reason: situationChanged)
                }
                return writeReplace(resolvedPath: resolved,
                                    newContents: CommandLineSetupEdit.rewritten(snap.contents, beginLine: b, endLine: e,
                                                                                newBlockText: blockText),
                                    blockHash: hash, binDirectory: binDirectory, expected: snap.identity,
                                    now: now, defaults: defaults)
            default:
                // A block appeared where an append was approved, or the block is
                // gone/malformed where a rewrite was approved: refuse.
                return .notMutated(reason: situationChanged)
            }
        }
        guard intent == .append else { return .notMutated(reason: situationChanged) }
        return writeCreate(resolvedPath: file, contents: blockText + "\n", blockHash: hash,
                           binDirectory: binDirectory, ensureParent: false, now: now, defaults: defaults)
    }

    // MARK: High-level actions

    /// The result of an action: the transient status line, the removal's second
    /// line, and the refreshed status the pane redraws from.
    struct ActionResult: Sendable {
        let statusLine: String
        let secondLine: String?
        let refreshed: CommandLineSetupStatusReport
    }

    /// Shown when the situation changed between the confirmation and the write, so
    /// the action no longer applies. The refreshed status accompanies it.
    static let situationChanged = "The setup changed since this was shown; nothing was written."

    /// Add or update this app's entry, then re-probe. Turns the preference on.
    /// Re-establishes the whole status at execution time AND requires the fresh
    /// state to still match the APPROVED proposal (same action, same file, same app
    /// location the user was shown); any divergence refuses rather than silently
    /// writing a different operation or destination.
    static func performAdd(approved: CommandLineSetupStatusReport,
                           bundleURL: URL,
                           environment env: CommandLineSetupEnvironment = .real,
                           fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem(),
                           defaults: UserDefaults = .standard,
                           now: Date = Date()) -> ActionResult {
        let fresh = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
        guard (fresh.state.action == .add || fresh.state.action == .useThisCopy),
              fresh.state.action == approved.state.action,
              fresh.fileChoice.file == approved.fileChoice.file,
              fresh.thisBinDirectory == approved.thisBinDirectory,
              fresh.fileChoice.automatic, let file = fresh.fileChoice.file else {
            return ActionResult(statusLine: situationChanged, secondLine: nil, refreshed: fresh)
        }
        let intent: WriteIntent = fresh.state.action == .useThisCopy ? .rewrite : .append
        let outcome = writeEntry(shell: fresh.fileChoice.shell, file: file, binDirectory: fresh.thisBinDirectory,
                                 intent: intent, fs: fs, now: now, defaults: defaults)
        CommandLineSetupPreference.setKeepInTerminal(true, defaults: defaults)
        let refreshed = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
        return ActionResult(statusLine: CommandLineSetupStatusLine.afterWrite(outcome, postResolution: refreshed.resolution),
                            secondLine: nil, refreshed: refreshed)
    }

    /// Row 6 at launch: rewrite an owned block that records a stale location with
    /// this app's CURRENT path. Revalidates; acts only while the state still asks
    /// for it and the block is still owned (validated by writeEntry on the guarding
    /// read). Silent; the caller reports.
    static func performStartupRewrite(bundleURL: URL,
                                      environment env: CommandLineSetupEnvironment = .real,
                                      fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem(),
                                      defaults: UserDefaults = .standard,
                                      now: Date = Date()) -> ActionResult {
        let fresh = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
        guard fresh.state.startup == .rewriteToCurrent,
              fresh.fileChoice.automatic, let file = fresh.fileChoice.file else {
            return ActionResult(statusLine: "", secondLine: nil, refreshed: fresh)
        }
        let outcome = writeEntry(shell: fresh.fileChoice.shell, file: file, binDirectory: fresh.thisBinDirectory,
                                 intent: .rewrite, fs: fs, now: now, defaults: defaults)
        let refreshed = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
        return ActionResult(statusLine: CommandLineSetupStatusLine.afterRewrite(outcome),
                            secondLine: nil, refreshed: refreshed)
    }

    /// Remove this app's entry, then re-probe. Turns the preference off. Requires
    /// the fresh state to still be Remove on the APPROVED file, reads content and
    /// snapshot together, and validates ownership on that same read, so a file that
    /// became foreign or changed since the confirmation is not deleted.
    static func performRemove(approved: CommandLineSetupStatusReport,
                              bundleURL: URL,
                              environment env: CommandLineSetupEnvironment = .real,
                              fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem(),
                              defaults: UserDefaults = .standard) -> ActionResult {
        let fresh = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
        guard fresh.state.action == .remove,
              approved.state.action == .remove,
              fresh.fileChoice.file == approved.fileChoice.file,
              let file = fresh.fileChoice.file else {
            return ActionResult(statusLine: situationChanged, secondLine: nil, refreshed: fresh)
        }
        let resolved = fs.realPath(ofPath: file) ?? file
        guard let snap = CommandLineSetupWriter.snapshotWithContents(atPath: resolved) else {
            let refreshed = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
            return ActionResult(statusLine: "the file could not be read before writing", secondLine: nil, refreshed: refreshed)
        }
        guard isOwnedEntry(shell: fresh.fileChoice.shell, resolvedPath: resolved,
                           contents: snap.contents, defaults: defaults) else {
            let refreshed = status(bundleURL: bundleURL, environment: env, fs: fs, defaults: defaults)
            return ActionResult(statusLine: situationChanged, secondLine: nil, refreshed: refreshed)
        }
        let outcome: CommandLineSetupWriteOutcome
        if fresh.fileChoice.shell == .fish {
            outcome = CommandLineSetupWriter.removeFile(resolvedPath: resolved, expected: snap.identity)
        } else if case .single(let b, let e) = CommandLineSetupBlock.markerArrangement(inContents: snap.contents) {
            outcome = CommandLineSetupWriter.replace(
                resolvedPath: resolved,
                newContents: CommandLineSetupEdit.removed(snap.contents, beginLine: b, endLine: e),
                expected: snap.identity)
        } else {
            outcome = .notMutated(reason: "no entry from this app was found to remove")
        }
        if case .mutated = outcome { CommandLineSetupRecordStore.deleteBoth(defaults: defaults) }
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

    static func performAddAsync(approved: CommandLineSetupStatusReport, bundleURL: URL,
                                defaults: UserDefaults = .standard) async -> ActionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: performAdd(approved: approved, bundleURL: bundleURL, defaults: defaults))
            }
        }
    }

    static func performRemoveAsync(approved: CommandLineSetupStatusReport, bundleURL: URL,
                                   defaults: UserDefaults = .standard) async -> ActionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: performRemove(approved: approved, bundleURL: bundleURL, defaults: defaults))
            }
        }
    }

    static func performStartupRewriteAsync(bundleURL: URL,
                                           defaults: UserDefaults = .standard) async -> ActionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: performStartupRewrite(bundleURL: bundleURL, defaults: defaults))
            }
        }
    }
}
