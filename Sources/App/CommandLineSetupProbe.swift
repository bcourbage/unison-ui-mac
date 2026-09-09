import Foundation

// The account record and the outside-world probes the state table is built from:
// what `unison` resolves to in a non-interactive login shell, the zsh-bound
// inputs, and the fish configuration directory. See docs/command-line-setup-
// design.md, "The probe" and "Selecting the file".
//
// The login shell and home directory come from the account record (getpwuid),
// never from $SHELL or the launching environment. The classification of a
// resolved path is pure and tested; the subprocess and /etc reads are thin.

enum CommandLineSetupProbe {

    struct AccountRecord: Equatable {
        let loginShellPath: String
        let homeDirectory: String
    }

    /// The current account's login shell and home directory from `getpwuid`.
    static func accountRecord(uid: uid_t = getuid()) -> AccountRecord? {
        guard let pw = getpwuid(uid) else { return nil }
        let shell = pw.pointee.pw_shell.map { String(cString: $0) } ?? ""
        let home = pw.pointee.pw_dir.map { String(cString: $0) } ?? ""
        guard !shell.isEmpty, !home.isEmpty else { return nil }
        return AccountRecord(loginShellPath: shell, homeDirectory: home)
    }

    // MARK: Resolution

    /// The raw result of asking the login shell what `unison` resolves to.
    enum ProbeOutput: Equatable {
        case failed        // the shell could not be run or timed out
        case empty         // the shell ran; `unison` resolves to nothing
        case path(String)  // the shell printed this resolved path
    }

    /// Classify a probe output into a resolution, comparing the resolved path to
    /// this bundle's launcher. Pure; `realPathOf` resolves symlinks.
    static func classify(_ output: ProbeOutput,
                         thisLauncherPath: String,
                         realPathOf: (String) -> String?) -> CommandLineSetupResolution {
        switch output {
        case .failed: return .couldNotCheck
        case .empty: return .none
        case .path(let p):
            let resolved = realPathOf(p) ?? p
            if let launcher = realPathOf(thisLauncherPath), resolved == launcher { return .thisApp }
            return .anotherUnison(path: resolved)
        }
    }

    /// Run a local command through the hardened subprocess executor and return its
    /// stdout on a clean exit, or nil on a timeout, a launch failure, or (when
    /// `requireZeroExit`) a non-zero exit. The executor applies a true wall-clock
    /// deadline and signals the DIRECT child SIGTERM then SIGKILL, best-effort
    /// reaping it, so the probe returns within a bounded time even when a shell
    /// ignores SIGTERM. It does NOT guarantee termination or reaping of every
    /// descendant: a process that inherited stdout can outlive the probe. The
    /// guarantee is bounded return, not a fully drained process tree.
    private static func runLocal(_ executable: String, _ arguments: [String],
                                 timeout: TimeInterval, requireZeroExit: Bool) -> String? {
        let result = VersionCheck.SubprocessProbeExecutor().execute(
            VersionCheck.ProbeConfig(executable: executable, arguments: arguments, host: "local"),
            deadline: timeout, canceller: VersionCheck.ProbeCanceller())
        guard case .exited(let status, let stdout, _) = result else { return nil }
        if requireZeroExit, status != 0 { return nil }
        return stdout
    }

    /// Run the login shell and report what `unison` resolves to. zsh and bash use
    /// `command -v`; fish uses `type -p`. Output is bracketed with markers so a
    /// banner printed by a login file is not mistaken for the answer. The script's
    /// own exit status is the trailing `printf`'s (zero), so the marker text, not
    /// the status, decides the result.
    static func resolvedUnison(shellPath: String,
                               kind: CommandLineSetupShellKind,
                               timeout: TimeInterval = 5) -> ProbeOutput {
        let lookup = (kind == .fish) ? "type -p unison" : "command -v unison"
        let start = CommandLineToolStatus.pathMarkerStart
        let end = CommandLineToolStatus.pathMarkerEnd
        let script = "printf '%s' '\(start)'; \(lookup) 2>/dev/null; printf '%s' '\(end)'"

        guard let stdout = runLocal(shellPath, ["-l", "-c", script], timeout: timeout, requireZeroExit: false),
              let marked = CommandLineToolStatus.extractMarkedPath(from: stdout)
        else { return .failed }
        let trimmed = marked.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? .empty : .path(trimmed)
    }

    // MARK: zsh bound inputs

    static func etcZshenvExists(fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem()) -> Bool {
        fs.entryExists(atPath: "/etc/zshenv")
    }

    static func homeZshenvExists(homeDirectory: String,
                                 fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem()) -> Bool {
        fs.entryExists(atPath: (homeDirectory as NSString).appendingPathComponent(".zshenv"))
    }

    static func etcZprofileContents(fs: CommandLineToolFileSystem = RealCommandLineToolFileSystem()) -> String? {
        fs.contentsOfFile(atPath: "/etc/zprofile")
    }

    static func zdotdirInAppEnvironment() -> Bool {
        ProcessInfo.processInfo.environment["ZDOTDIR"] != nil
    }

    /// Whether `ZDOTDIR` is set in the launchd user environment, from
    /// `launchctl print gui/<uid>`. A set variable (empty included) is listed in
    /// the environment section; an unset one is omitted. A failed or unparsable
    /// query is uncertainty, never absence.
    static func zdotdirFromLaunchd(uid: uid_t = getuid(), timeout: TimeInterval = 5) -> CommandLineSetupZDOTDIRState {
        guard let stdout = runLocal("/bin/launchctl", ["print", "gui/\(uid)"],
                                    timeout: timeout, requireZeroExit: true) else { return .uncertain }
        return parseLaunchctlZDOTDIR(stdout)
    }

    /// Whether the `environment = { … }` section of `launchctl print` output lists
    /// a `ZDOTDIR` key. Absence of the whole section is uncertainty; the section
    /// present without the key is absence.
    static func parseLaunchctlZDOTDIR(_ text: String) -> CommandLineSetupZDOTDIRState {
        guard let envRange = text.range(of: "environment = {") else { return .uncertain }
        guard let closeRange = text.range(of: "}", range: envRange.upperBound..<text.endIndex) else { return .uncertain }
        let section = text[envRange.upperBound..<closeRange.lowerBound]
        for rawLine in section.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Lines look like `ZDOTDIR => /some/dir`.
            if line == "ZDOTDIR" || line.hasPrefix("ZDOTDIR =") || line.hasPrefix("ZDOTDIR=>") || line.hasPrefix("ZDOTDIR =>") {
                return .present
            }
        }
        return .absent
    }

    // MARK: fish

    /// The `$__fish_config_dir` a non-login `fish -c` reports, marker-bracketed so
    /// startup output cannot contaminate it, or nil when the probe fails or reports
    /// nothing. This establishes only what fish printed; whether that names an
    /// absolute, existing directory is decided by `CommandLineSetupFileSelection.
    /// fishChoice`, which the design requires before permitting automatic setup.
    static func fishConfigDirectory(fishPath: String, timeout: TimeInterval = 5) -> String? {
        let start = CommandLineToolStatus.pathMarkerStart
        let end = CommandLineToolStatus.pathMarkerEnd
        let script = "printf '%s%s%s' '\(start)' $__fish_config_dir '\(end)'"
        return fishConfigDirectory(fromProbeStdout: runLocal(fishPath, ["-c", script],
                                                             timeout: timeout, requireZeroExit: true))
    }

    /// The directory between the markers in a fish probe's stdout, PRESERVED
    /// EXACTLY. `printf '%s%s%s'` adds no whitespace, so any leading or trailing
    /// space is part of the directory fish reported; trimming it could point setup
    /// at a different, existing directory. nil when the probe failed, the markers
    /// are absent, or the reported directory is empty.
    static func fishConfigDirectory(fromProbeStdout stdout: String?) -> String? {
        guard let stdout, let marked = CommandLineToolStatus.extractMarkedPath(from: stdout) else { return nil }
        return marked.isEmpty ? nil : marked
    }
}
