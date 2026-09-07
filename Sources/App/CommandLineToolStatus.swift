import Foundation

// What the `unison` command on PATH is, in two named PATH contexts, and what
// the app may do about it. Everything here is computed from the filesystem each
// time it is asked for; nothing about the disk is remembered across launches.
// Only the "Do not ask again" bit of the first-launch prompt is persisted, and
// that is a decision about prompting, which the app does control.
//
// Every mutation re-checks its precondition at execution time, inside the
// privileged shell command itself: the state seen at classification is only a
// proposal, and the filesystem may have changed by the time the user has typed
// an administrator password.
//
// See docs/cli-launcher-design.md, "Detection, Settings panel, first-launch
// prompt", for the classification table and the action gates.

// MARK: - Filesystem abstraction

/// The few filesystem questions the classifier asks, behind a protocol so the
/// classifier can be tested against fixture directories and against fakes.
protocol CommandLineToolFileSystem {
    /// True for a regular file, directory, or symlink (dangling included).
    func entryExists(atPath path: String) -> Bool
    /// True if the entry is a symlink (whether or not its target exists).
    func isSymlink(atPath path: String) -> Bool
    /// The link's target as stored (relative or absolute); nil for a non-link.
    func linkTarget(atPath path: String) -> String?
    /// The canonical path with every symlink resolved; nil when any component
    /// does not exist (a dangling link).
    func realPath(ofPath path: String) -> String?
    func isExecutableFile(atPath path: String) -> Bool
    /// `CFBundleIdentifier` of the bundle at `bundlePath`, nil if unreadable.
    func bundleIdentifier(ofBundleAtPath bundlePath: String) -> String?
    func isDirectory(atPath path: String) -> Bool
    func contentsOfDirectory(atPath path: String) -> [String]
    func contentsOfFile(atPath path: String) -> String?
}

struct RealCommandLineToolFileSystem: CommandLineToolFileSystem {
    private let fm = FileManager.default

    func entryExists(atPath path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path)) != nil
    }
    func isSymlink(atPath path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
    func linkTarget(atPath path: String) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: path)
    }
    func realPath(ofPath path: String) -> String? {
        guard let cstr = realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }
    func isExecutableFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: path)
    }
    func bundleIdentifier(ofBundleAtPath bundlePath: String) -> String? {
        Bundle(path: bundlePath)?.bundleIdentifier
    }
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
    func contentsOfDirectory(atPath path: String) -> [String] {
        (try? fm.contentsOfDirectory(atPath: path)) ?? []
    }
    func contentsOfFile(atPath path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Classification

/// What one `unison` entry on PATH is. Cases that name a target carry the
/// resolved or stored path so the Settings panel can show it.
enum CommandLineToolClassification: Equatable, Sendable {
    /// Resolves to `cltool` inside the bundle this process runs from.
    case thisInstallation
    /// Resolves to `cltool` inside a different bundle carrying our identifier
    /// (a Debug build, a second copy). Same product, not this installation.
    case otherCopyOfThisApp(bundlePath: String)
    /// `thisInstallation` or `otherCopyOfThisApp`, the link lives under the
    /// Homebrew prefix's `bin`, and the Caskroom holds our install receipt.
    case homebrewManaged(bundlePath: String)
    /// Resolves into the Homebrew Cellar.
    case brewFormula(resolvedPath: String)
    /// Resolves into a bundle with identifier `edu.upenn.cis.Unison`.
    case upstreamApp(bundlePath: String)
    /// Broken link whose target ends in `/unison-ui-mac.app/Contents/MacOS/
    /// cltool`. A pathname, not proof of ownership; it says what the link was
    /// for. `storedTarget` is the link's content as stored (what `readlink`
    /// returns); `resolvedTarget` is that made absolute against the link's
    /// directory, for display.
    case danglingLauncherPath(storedTarget: String, resolvedTarget: String)
    /// Broken link pointing anywhere else.
    case danglingOther(target: String)
    /// Anything else.
    case other(resolvedPath: String)
}

/// One PATH entry holding a `unison` name, classified.
struct CommandLineToolEntry: Equatable, Sendable {
    /// The path of the entry itself (`<dir>/unison`).
    let path: String
    let classification: CommandLineToolClassification
    /// The link's stored target when the entry is a symlink, else nil. Every
    /// mutation re-verifies this at execution time.
    let storedLinkTarget: String?
}

/// The status of the `unison` name in one PATH context.
struct CommandLineToolContextStatus: Equatable, Sendable {
    /// Short name for the panel ("Terminal", "Remote command").
    let label: String
    /// One sentence saying how this PATH was obtained and what it can miss.
    let caveat: String
    /// The PATH that was searched, or nil when it could not be obtained. An
    /// unknown PATH is not an empty one: nothing can be concluded from it.
    let searchPath: [String]?
    /// The first entry of any kind, dangling links included. `which` skips
    /// dangling links and must not be used for this.
    let first: CommandLineToolEntry?
    /// The first entry that actually executes, when it differs from `first`
    /// (a dangling link ahead of a working command). Nil when the same, or none.
    let executingWhenDifferent: CommandLineToolEntry?

    /// True only when the PATH was obtained and holds no `unison` entry.
    var isKnownEmpty: Bool { searchPath != nil && first == nil }
}

enum CommandLineToolStatus {

    static let commandName = "unison"
    static let ourBundleIdentifier = "net.courbage.unison-ui-mac"
    static let upstreamBundleIdentifier = "edu.upenn.cis.Unison"
    static let launcherSuffix = "/Contents/MacOS/cltool"
    static let launcherBundleSuffix = "/unison-ui-mac.app" + launcherSuffix
    /// Where Install creates the link. Whether a given shell finds it depends on
    /// that shell's PATH; remote peers should name it in `servercmd` rather than
    /// rely on any PATH.
    static let installLinkPath = "/usr/local/bin/unison"

    /// Facts about the machine the classifier needs besides the filesystem.
    struct Environment: Sendable {
        /// Real path of the bundle this process runs from.
        let thisBundlePath: String
        /// `/opt/homebrew` or `/usr/local` when brew is installed there, else nil.
        let brewPrefix: String?
        /// `<brewPrefix>/Caskroom/unison-ui-mac` exists.
        let caskroomReceiptExists: Bool
    }

    // MARK: Classify one entry

    static func classify(entryAtPath path: String,
                         environment env: Environment,
                         fs: CommandLineToolFileSystem) -> CommandLineToolEntry? {
        guard fs.entryExists(atPath: path) else { return nil }
        let stored = fs.isSymlink(atPath: path) ? fs.linkTarget(atPath: path) : nil
        return CommandLineToolEntry(
            path: path,
            classification: classification(entryAtPath: path, storedLinkTarget: stored, environment: env, fs: fs),
            storedLinkTarget: stored)
    }

    private static func classification(entryAtPath path: String,
                                       storedLinkTarget stored: String?,
                                       environment env: Environment,
                                       fs: CommandLineToolFileSystem) -> CommandLineToolClassification {
        let resolved = fs.realPath(ofPath: path)
        if let stored, resolved == nil {
            let absolute = stored.hasPrefix("/")
                ? stored
                : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(stored)
            return absolute.hasSuffix(launcherBundleSuffix)
                ? .danglingLauncherPath(storedTarget: stored, resolvedTarget: absolute)
                : .danglingOther(target: absolute)
        }
        guard let real = resolved else { return .other(resolvedPath: path) }

        // Compare resolved paths with a resolved prefix: /var is a link to
        // /private/var, /tmp to /private/tmp, and a user's brew prefix can be
        // a link too. Mixing resolved and unresolved forms would miss matches.
        let brewPrefixReal = env.brewPrefix.map { fs.realPath(ofPath: $0) ?? $0 }
        let entryDirReal = fs.realPath(ofPath: (path as NSString).deletingLastPathComponent)

        if real.hasSuffix(launcherSuffix) {
            let bundlePath = String(real.dropLast(launcherSuffix.count))
            if fs.bundleIdentifier(ofBundleAtPath: bundlePath) == ourBundleIdentifier {
                let isThis = fs.realPath(ofPath: env.thisBundlePath) == fs.realPath(ofPath: bundlePath)
                if let prefix = brewPrefixReal,
                   entryDirReal == prefix + "/bin",
                   env.caskroomReceiptExists {
                    return .homebrewManaged(bundlePath: bundlePath)
                }
                return isThis ? .thisInstallation : .otherCopyOfThisApp(bundlePath: bundlePath)
            }
        }
        if let prefix = brewPrefixReal, real.hasPrefix(prefix + "/Cellar/") {
            return .brewFormula(resolvedPath: real)
        }
        if let range = real.range(of: "/Contents/MacOS/") {
            let bundlePath = String(real[real.startIndex..<range.lowerBound])
            if fs.bundleIdentifier(ofBundleAtPath: bundlePath) == upstreamBundleIdentifier {
                return .upstreamApp(bundlePath: bundlePath)
            }
        }
        return .other(resolvedPath: real)
    }

    // MARK: Scan one PATH

    /// `searchPath` nil means the PATH could not be obtained; the result then
    /// carries no entries and `isKnownEmpty` is false.
    static func scan(searchPath: [String]?,
                     label: String,
                     caveat: String,
                     environment env: Environment,
                     fs: CommandLineToolFileSystem) -> CommandLineToolContextStatus {
        var first: CommandLineToolEntry?
        var executing: CommandLineToolEntry?
        for dir in searchPath ?? [] where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(commandName)
            guard let entry = classify(entryAtPath: candidate, environment: env, fs: fs) else { continue }
            if first == nil { first = entry }
            if executing == nil, let real = fs.realPath(ofPath: candidate), fs.isExecutableFile(atPath: real) {
                executing = entry
            }
            if first != nil && executing != nil { break }
        }
        return CommandLineToolContextStatus(
            label: label, caveat: caveat, searchPath: searchPath,
            first: first,
            executingWhenDifferent: (executing != nil && executing != first) ? executing : nil)
    }

    // MARK: PATH reconstructions

    /// The remote-SSH-command context is not determined locally, by design.
    /// The PATH an incoming `ssh host unison -server` receives is decided by the
    /// SSH server's configuration (`SetEnv`, `PermitUserEnvironment`), by the
    /// login shell's non-interactive startup files (`~/.zshenv`, `/etc/zshenv`),
    /// and by the invoking peer, none of which this process can evaluate from
    /// inside a GUI session. One measurement exists (Demeter, macOS 26.6.2,
    /// zsh, no zshenv files: `ssh demeter 'echo $PATH'` printed
    /// `/usr/bin:/bin:/usr/sbin:/sbin`), and it is recorded in the manual as
    /// that machine's observation, not as a rule. The status therefore carries
    /// no search path and can never be "known empty": it can neither enable nor
    /// satisfy any gate. The advice that does not depend on remote PATH at all
    /// is an absolute `servercmd` in the peer's profile.
    static let remoteCommandLabel = "Remote SSH command"
    static let remoteCommandCaveat =
        "Not determined locally. The PATH an incoming ssh command receives depends on the SSH server " +
        "configuration and on the login shell's startup files on this Mac, which this app does not " +
        "evaluate. Set servercmd in the peer's profile to the link's full path so the peer does not " +
        "rely on remote PATH at all."

    static func remoteCommandStatus() -> CommandLineToolContextStatus {
        CommandLineToolContextStatus(label: remoteCommandLabel, caveat: remoteCommandCaveat,
                                     searchPath: nil, first: nil, executingWhenDifferent: nil)
    }

    static func splitSearchPath(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }

    /// The PATH of a non-interactive login shell: `$SHELL -l -c 'printf %s "$PATH"'`.
    /// Reads `/etc/zprofile` and `~/.zprofile` (or the bash equivalents) but not
    /// `~/.zshrc`, so a PATH change made only there is not seen.
    ///
    /// Bounded by `timeout`: the pipe is read on a background thread while this
    /// thread waits on the timeout, so a login script that stalls, or a
    /// descendant that keeps stdout open, makes this return nil after `timeout`
    /// rather than hang. The child is terminated on timeout; a descendant that
    /// survives it keeps the reader thread parked until it closes stdout, which
    /// leaks that one thread but never blocks the caller.
    static func loginShellSearchPath(shell: String? = ProcessInfo.processInfo.environment["SHELL"],
                                     timeout: TimeInterval = 5) -> [String]? {
        let exe = (shell?.isEmpty == false ? shell! : "/bin/zsh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        // Login startup files can print banners or anything else to stdout
        // before the command runs, so the PATH is bracketed with markers and
        // only the bracketed text is read (see `extractMarkedPath`).
        process.arguments = ["-l", "-c", "printf '%s%s%s' '\(pathMarkerStart)' \"$PATH\" '\(pathMarkerEnd)'"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0, let text = String(data: box.data, encoding: .utf8) else { return nil }
        return extractMarkedPath(from: text).map(splitSearchPath)
    }

    static let pathMarkerStart = "@@UNISON_UI_MAC_PATH_START@@"
    static let pathMarkerEnd = "@@UNISON_UI_MAC_PATH_END@@"

    /// The text between the two markers, or nil when the markers are absent or
    /// out of order. Only that text is the PATH; a banner printed by a login
    /// script before it is ignored rather than parsed into a first directory.
    static func extractMarkedPath(from output: String) -> String? {
        guard let start = output.range(of: pathMarkerStart),
              let end = output.range(of: pathMarkerEnd, range: start.upperBound..<output.endIndex)
        else { return nil }
        return String(output[start.upperBound..<end.lowerBound])
    }

    // MARK: Environment discovery

    static func discoverEnvironment(fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem()) -> Environment {
        let bundle = fs.realPath(ofPath: Bundle.main.bundlePath) ?? Bundle.main.bundlePath
        let prefix: String? = ["/opt/homebrew", "/usr/local"].first { fs.isExecutableFile(atPath: $0 + "/bin/brew") }
        let receipt = prefix.map { fs.isDirectory(atPath: $0 + "/Caskroom/unison-ui-mac") } ?? false
        return Environment(thisBundlePath: bundle, brewPrefix: prefix, caskroomReceiptExists: receipt)
    }

    /// Both contexts, computed on a GCD utility queue. The login-shell probe
    /// blocks (a child process and a pipe read), so it must never run on
    /// Swift's cooperative thread pool: a blocked pool thread starves every
    /// other Task in the process, which surfaced as timeouts in unrelated
    /// async tests on a small CI runner.
    static func currentStatusAsync() async -> [CommandLineToolContextStatus] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: currentStatus())
            }
        }
    }

    /// Both contexts, computed now. Runs the login shell and blocks; call it
    /// from a GCD queue, never from the main thread or a Task.
    static func currentStatus(fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem()) -> [CommandLineToolContextStatus] {
        let env = discoverEnvironment(fs: fs)
        let login = loginShellSearchPath()
        let loginStatus = scan(
            searchPath: login,
            label: "Terminal",
            caveat: login == nil
                ? "The login-shell probe did not report a PATH, so nothing is known about this context."
                : "PATH obtained by running the login shell non-interactively. An interactive Terminal also reads .zshrc, which can change what unison resolves to there.",
            environment: env, fs: fs)
        return [loginStatus, remoteCommandStatus()]
    }
}

// MARK: - Actions

/// What the panel and the first-launch offer may propose. Every case carries
/// what its privileged command re-verifies at execution time.
enum CommandLineToolAction: Equatable, Sendable {
    /// Create `/usr/local/bin/unison` pointing at this installation's launcher.
    /// Fails if anything appeared there since the check.
    case install
    /// Replace the dangling link at `linkPath` whose stored target is still
    /// `oldTarget`. `displacing`, when set, is the path of the command that
    /// currently executes and that the repaired link will take precedence over.
    case repair(linkPath: String, oldTarget: String, displacing: String?)
    /// Delete the link at `linkPath`, but only if it still stores
    /// `expectedTarget`, the target seen when it classified as this installation.
    case remove(linkPath: String, expectedTarget: String)
}

enum CommandLineToolActionPolicy {
    /// - `contexts`: Terminal first, then Remote SSH command.
    ///
    /// Every gate is decided from the Terminal context alone. The remote
    /// context is informational: it is never determined locally, so it can
    /// neither satisfy a gate that requires known absence nor block one. An
    /// earlier revision required the remote context to be "known empty" too,
    /// which only held because a guessed PATH was standing in for a
    /// measurement; nothing is guessed now.
    static func availableAction(contexts: [CommandLineToolContextStatus]) -> CommandLineToolAction? {
        guard let terminal = contexts.first else { return nil }
        switch terminal.first?.classification {
        case .none:
            // Install only when the Terminal PATH was obtained and holds no
            // `unison`. An unobtained PATH is not an absence.
            return terminal.isKnownEmpty ? .install : nil
        case .some(.danglingLauncherPath(let stored, _)):
            return .repair(linkPath: terminal.first!.path, oldTarget: stored,
                           displacing: terminal.executingWhenDifferent?.path)
        case .some(.thisInstallation):
            guard let target = terminal.first!.storedLinkTarget else { return nil }
            return .remove(linkPath: terminal.first!.path, expectedTarget: target)
        default:
            return nil
        }
    }

    /// The `/bin/sh` command run with administrator privileges for an action.
    /// Each command re-checks its precondition at execution time; if the
    /// filesystem changed since the panel was shown, the command fails and
    /// changes nothing. `launcherPath` is this installation's `cltool`.
    static func adminShellCommand(for action: CommandLineToolAction, launcherPath: String,
                                  installLinkPath: String = CommandLineToolStatus.installLinkPath) -> String {
        let launcher = shellQuoted(launcherPath)
        switch action {
        case .install:
            let link = shellQuoted(installLinkPath)
            let dir = shellQuoted((installLinkPath as NSString).deletingLastPathComponent)
            // Nothing may exist at the destination: not a file, not a dangling
            // link (-e is false for those), and not a directory, into which
            // `ln -s` would otherwise create `unison/cltool` and report success.
            return "/bin/mkdir -p \(dir) && ! [ -e \(link) ] && ! [ -L \(link) ] && /bin/ln -s \(launcher) \(link)"
        case .repair(let linkPath, let oldTarget, _):
            let link = shellQuoted(linkPath)
            // Still a link, still dangling, still storing the disclosed target.
            return "[ -L \(link) ] && ! [ -e \(link) ] && [ \"$(/usr/bin/readlink \(link))\" = \(shellQuoted(oldTarget)) ] && /bin/ln -sfn \(launcher) \(link)"
        case .remove(let linkPath, let expectedTarget):
            let link = shellQuoted(linkPath)
            // Still a link, still storing the target that classified it as ours.
            return "[ -L \(link) ] && [ \"$(/usr/bin/readlink \(link))\" = \(shellQuoted(expectedTarget)) ] && /bin/rm \(link)"
        }
    }

    /// POSIX single-quote quoting.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The AppleScript that runs `command` with administrator privileges.
    static func appleScript(runningAsAdmin command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}

// MARK: - First-launch prompt policy

enum CommandLineToolPromptPolicy {
    static let doNotAskKey = "commandLineTool.doNotAsk"

    /// The action to offer at first launch, or nil to stay silent. Decided from
    /// the Terminal context alone (the remote context is never determined, see
    /// `remoteCommandStatus`). Silent when the Terminal PATH could not be
    /// obtained (unknown is not absence), when anything but a dangling launcher
    /// link owns the name there, when suppressed, and under the test host. A
    /// Repair offer carries the displaced command.
    static func offer(contexts: [CommandLineToolContextStatus],
                      suppressed: Bool,
                      isTestHost: Bool) -> CommandLineToolAction? {
        if isTestHost || suppressed { return nil }
        guard let terminal = contexts.first, terminal.searchPath != nil else { return nil }
        switch terminal.first?.classification {
        case .none:
            return .install
        case .some(.danglingLauncherPath(let stored, _)):
            return .repair(linkPath: terminal.first!.path, oldTarget: stored,
                           displacing: terminal.executingWhenDifferent?.path)
        default:
            return nil
        }
    }

    static func isSuppressed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: doNotAskKey)
    }

    static func suppress(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: doNotAskKey)
    }
}

// MARK: - Wording

enum CommandLineToolWording {
    /// One sentence for a classified entry.
    static func describe(_ entry: CommandLineToolEntry?) -> String {
        guard let entry else { return "No unison command on this PATH." }
        switch entry.classification {
        case .thisInstallation:
            return "\(entry.path) is this app's command."
        case .otherCopyOfThisApp(let bundle):
            return "\(entry.path) is another copy of this app, at \(bundle)."
        case .homebrewManaged(let bundle):
            return "\(entry.path) is this app's command, managed by Homebrew (\(bundle))."
        case .brewFormula(let resolved):
            return "\(entry.path) is the Homebrew unison formula (\(resolved))."
        case .upstreamApp(let bundle):
            return "\(entry.path) is upstream Unison.app's command (\(bundle))."
        case .danglingLauncherPath(_, let resolved):
            return "\(entry.path) is a broken link to a former copy of this app's command (\(resolved))."
        case .danglingOther(let target):
            return "\(entry.path) is a broken link to \(target)."
        case .other(let resolved):
            return "\(entry.path) is \(resolved)."
        }
    }

    /// The whole context in words: first entry, executing entry when different,
    /// then the caveat. An unobtained PATH is stated as unknown.
    static func describe(_ context: CommandLineToolContextStatus?) -> String {
        guard let context else { return "Not available." }
        if context.searchPath == nil { return context.caveat }
        var text = describe(context.first)
        if let executing = context.executingWhenDifferent {
            text += " The command that actually runs is " + describe(executing)
        }
        return text + " " + context.caveat
    }

    /// The disclosure a Repair confirmation makes.
    static func repairDetails(linkPath: String, oldTarget: String, displacing: String?) -> String {
        var text = "Replaces the broken link at \(linkPath), which pointed at \(oldTarget), " +
            "with a link to this app's command-line launcher."
        if let displacing {
            text += " The command that currently runs, \(displacing), comes later on the PATH " +
                "and will no longer be reached by the name unison."
        }
        return text
    }
}
