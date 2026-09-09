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

    /// Run the login shell and report what `unison` resolves to. zsh and bash use
    /// `command -v`; fish uses `type -p`. Output is bracketed with markers so a
    /// banner printed by a login file is not mistaken for the answer.
    static func resolvedUnison(shellPath: String,
                               kind: CommandLineSetupShellKind,
                               timeout: TimeInterval = 5) -> ProbeOutput {
        let lookup = (kind == .fish) ? "type -p unison" : "command -v unison"
        let start = CommandLineToolStatus.pathMarkerStart
        let end = CommandLineToolStatus.pathMarkerEnd
        let script = "printf '%s' '\(start)'; \(lookup) 2>/dev/null; printf '%s' '\(end)'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed }

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
            return .failed
        }
        guard process.terminationStatus >= 0,
              let text = String(data: box.data, encoding: .utf8),
              let marked = CommandLineToolStatus.extractMarkedPath(from: text)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(uid)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .uncertain }

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
            return .uncertain
        }
        guard process.terminationStatus == 0,
              let text = String(data: box.data, encoding: .utf8) else { return .uncertain }
        return parseLaunchctlZDOTDIR(text)
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

    /// The fish configuration directory from a non-login `fish -c`, or nil when it
    /// cannot be determined.
    static func fishConfigDirectory(fishPath: String, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fishPath)
        process.arguments = ["-c", "printf '%s' $__fish_config_dir"]
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
        guard process.terminationStatus == 0,
              let text = String(data: box.data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
