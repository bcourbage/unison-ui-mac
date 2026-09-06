import Foundation

// What the `unison` command on PATH is, in two named PATH contexts, and what
// the app may do about it. Everything here is computed from the filesystem each
// time it is asked for; nothing about the disk is remembered across launches.
// Only the "Do not ask again" bit of the first-launch prompt is persisted, and
// that is a decision about prompting, which the app does control.
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

/// What one `unison` entry on PATH is. Every case that names a target carries
/// the resolved or stored path so the Settings panel can show it.
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
    /// Broken link whose stored target ends in
    /// `/unison-ui-mac.app/Contents/MacOS/cltool`. A pathname, not proof of
    /// ownership; it says what the link was for.
    case danglingLauncherPath(target: String)
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
}

/// The status of the `unison` name in one PATH context.
struct CommandLineToolContextStatus: Equatable, Sendable {
    /// Short name for the panel ("Terminal", "Remote command").
    let label: String
    /// One sentence saying how this PATH was obtained and what it can miss.
    let caveat: String
    let searchPath: [String]
    /// The first entry of any kind, dangling links included. `which` skips
    /// dangling links and must not be used for this.
    let first: CommandLineToolEntry?
    /// The first entry that actually executes, when it differs from `first`
    /// (a dangling link ahead of a working command). Nil when the same, or none.
    let executingWhenDifferent: CommandLineToolEntry?
}

enum CommandLineToolStatus {

    static let commandName = "unison"
    static let ourBundleIdentifier = "net.courbage.unison-ui-mac"
    static let upstreamBundleIdentifier = "edu.upenn.cis.Unison"
    static let launcherSuffix = "/Contents/MacOS/cltool"
    static let launcherBundleSuffix = "/unison-ui-mac.app" + launcherSuffix
    /// Where Install creates the link. On the PATH of both a login shell
    /// (`path_helper`) and a non-interactive remote command on a stock macOS.
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
                         fs: CommandLineToolFileSystem) -> CommandLineToolClassification? {
        guard fs.entryExists(atPath: path) else { return nil }

        let resolved = fs.realPath(ofPath: path)
        if fs.isSymlink(atPath: path), resolved == nil {
            let stored = fs.linkTarget(atPath: path) ?? ""
            let absolute = stored.hasPrefix("/")
                ? stored
                : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(stored)
            return absolute.hasSuffix(launcherBundleSuffix)
                ? .danglingLauncherPath(target: absolute)
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

    static func scan(searchPath: [String],
                     label: String,
                     caveat: String,
                     environment env: Environment,
                     fs: CommandLineToolFileSystem) -> CommandLineToolContextStatus {
        var first: CommandLineToolEntry?
        var executing: CommandLineToolEntry?
        for dir in searchPath where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(commandName)
            guard let c = classify(entryAtPath: candidate, environment: env, fs: fs) else { continue }
            let entry = CommandLineToolEntry(path: candidate, classification: c)
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

    /// The PATH `path_helper` builds: `/etc/paths` first, then every file in
    /// `/etc/paths.d` in name order. This is what a non-interactive remote
    /// command receives on a stock macOS. It is a reconstruction: an ssh
    /// command runs `$SHELL -c`, which reads neither `/etc/zprofile` nor
    /// `~/.zshrc`, so entries a user adds in those files are absent here by
    /// design, and `/etc/paths.d` entries appear here even where a remote
    /// command's own environment would not carry them.
    static func remoteCommandSearchPath(fs: CommandLineToolFileSystem,
                                        etcPaths: String = "/etc/paths",
                                        etcPathsD: String = "/etc/paths.d") -> [String] {
        var entries = parsePathsFile(fs.contentsOfFile(atPath: etcPaths) ?? "")
        if fs.isDirectory(atPath: etcPathsD) {
            for name in fs.contentsOfDirectory(atPath: etcPathsD).sorted() {
                let file = (etcPathsD as NSString).appendingPathComponent(name)
                entries += parsePathsFile(fs.contentsOfFile(atPath: file) ?? "")
            }
        }
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }

    /// One directory per line; blank lines ignored.
    static func parsePathsFile(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func splitSearchPath(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }

    /// The PATH of a non-interactive login shell: `$SHELL -l -c 'printf %s "$PATH"'`.
    /// Reads `/etc/zprofile` and `~/.zprofile` (or the bash equivalents) but not
    /// `~/.zshrc`, so a PATH change made only there is not seen. Bounded by a
    /// timeout; nil when the shell cannot be run or does not answer.
    static func loginShellSearchPath(shell: String? = ProcessInfo.processInfo.environment["SHELL"],
                                     timeout: TimeInterval = 5) -> [String]? {
        let exe = (shell?.isEmpty == false ? shell! : "/bin/zsh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        // A login shell can print banners or run tools; take only stdout.
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { process.waitUntilExit(); exited.signal() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return splitSearchPath(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
            searchPath: login ?? [],
            label: "Terminal",
            caveat: login == nil
                ? "The login shell did not report its PATH."
                : "PATH as a login shell builds it. Changes made only in .zshrc are not included.",
            environment: env, fs: fs)
        let remoteStatus = scan(
            searchPath: remoteCommandSearchPath(fs: fs),
            label: "Remote command",
            caveat: "PATH as macOS defines it for non-interactive commands (/etc/paths and /etc/paths.d). A remote command's own environment can differ; servercmd in the peer's profile is the reliable setting.",
            environment: env, fs: fs)
        return [loginStatus, remoteStatus]
    }
}

// MARK: - Actions

/// What the panel may offer, decided from the Terminal context's first entry
/// and from whether either context holds anything at all.
enum CommandLineToolAction: Equatable, Sendable {
    /// Create `/usr/local/bin/unison` pointing at this installation's launcher.
    case install
    /// Replace a dangling launcher link. Carries the old target for disclosure
    /// and, when a later PATH entry currently executes, that entry's path.
    case repair(oldTarget: String, displacing: String?)
    /// Delete a link that resolves into this installation.
    case remove(linkPath: String)
}

enum CommandLineToolActionPolicy {
    /// - `contexts`: Terminal first, then Remote command.
    static func availableAction(contexts: [CommandLineToolContextStatus]) -> CommandLineToolAction? {
        guard let terminal = contexts.first else { return nil }
        let remote = contexts.dropFirst().first
        switch terminal.first?.classification {
        case .none:
            // Nothing in Terminal's PATH. Offer Install only if the remote
            // context is empty too; otherwise something owns the name there.
            return (remote?.first == nil) ? .install : nil
        case .some(.danglingLauncherPath(let target)):
            return .repair(oldTarget: target, displacing: terminal.executingWhenDifferent?.path)
        case .some(.thisInstallation):
            return .remove(linkPath: terminal.first!.path)
        default:
            return nil
        }
    }

    /// The `/bin/sh` command run with administrator privileges for an action.
    /// `launcherPath` is this installation's `cltool`.
    static func adminShellCommand(for action: CommandLineToolAction, launcherPath: String) -> String {
        let link = shellQuoted(CommandLineToolStatus.installLinkPath)
        let dir = shellQuoted((CommandLineToolStatus.installLinkPath as NSString).deletingLastPathComponent)
        switch action {
        case .install:
            // `ln -s` without -f: if something appeared since the check, fail
            // rather than overwrite it.
            return "/bin/mkdir -p \(dir) && /bin/ln -s \(shellQuoted(launcherPath)) \(link)"
        case .repair:
            // Replace only a link that is still dangling at execution time.
            return "[ -L \(link) ] && ! [ -e \(link) ] && /bin/ln -sfn \(shellQuoted(launcherPath)) \(link)"
        case .remove(let linkPath):
            return "/bin/rm \(shellQuoted(linkPath))"
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

enum CommandLineToolPromptKind: Equatable, Sendable {
    case install
    case repair(oldTarget: String)
}

enum CommandLineToolPromptPolicy {
    static let doNotAskKey = "commandLineTool.doNotAsk"

    /// Whether to show the first-launch prompt, and which one. Nil means stay
    /// silent. Silent whenever anything else owns the name in either context:
    /// those users made a choice, or inherited a state, and the Settings panel
    /// shows it without nagging.
    static func prompt(contexts: [CommandLineToolContextStatus],
                       suppressed: Bool,
                       isTestHost: Bool) -> CommandLineToolPromptKind? {
        if isTestHost || suppressed { return nil }
        guard let terminal = contexts.first else { return nil }
        let remote = contexts.dropFirst().first
        func isEmptyOrDanglingLauncher(_ e: CommandLineToolEntry?) -> Bool {
            switch e?.classification {
            case .none, .some(.danglingLauncherPath): return true
            default: return false
            }
        }
        guard isEmptyOrDanglingLauncher(terminal.first), isEmptyOrDanglingLauncher(remote?.first) else { return nil }
        if case .some(.danglingLauncherPath(let target)) = terminal.first?.classification {
            return .repair(oldTarget: target)
        }
        if case .some(.danglingLauncherPath(let target)) = remote?.first?.classification {
            return .repair(oldTarget: target)
        }
        return .install
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
        case .danglingLauncherPath(let target):
            return "\(entry.path) is a broken link to a former copy of this app's command (\(target))."
        case .danglingOther(let target):
            return "\(entry.path) is a broken link to \(target)."
        case .other(let resolved):
            return "\(entry.path) is \(resolved)."
        }
    }
}
