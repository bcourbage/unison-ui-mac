import Foundation

// The two outside-world checks the editable-file bound needs: a `-n` syntax parse
// (a subprocess) and rule 6's metadata clone test. Kept apart from the pure
// evaluator (CommandLineSetupBound) so its logic stays testable without a shell
// or a real file. See docs/command-line-setup-design.md, "Editable-file bound",
// rules 2 and 6.

enum CommandLineSetupEffects {

    /// Whether `text` parses under `shellPath -n` (exit 0). Used for the whole
    /// file and for the text before the begin marker. Neither check understands
    /// shell semantics; together they refuse the constructs the design knows
    /// about. The text is written to a temporary file the shell reads by path.
    /// A shell that cannot be run, or that does not finish within `timeout`, is
    /// treated as a parse failure (fail closed).
    static func parses(text: String, shellPath: String, timeout: TimeInterval = 5) -> Bool {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unison-ui-mac-parse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try text.write(to: tmp, atomically: true, encoding: .utf8) } catch { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-n", tmp.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// Rule 6: the file at `resolvedPath` is a regular file owned by this account,
    /// without an immutable flag, and `copyfile(3)` with SECURITY | XATTR | STAT
    /// can clone its metadata onto a sibling temporary file. Fails closed on any
    /// error. `resolvedPath` is expected to have symlinks already followed.
    static func metadataOK(resolvedPath: String) -> Bool {
        var st = stat()
        guard stat(resolvedPath, &st) == 0 else { return false }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        guard st.st_uid == getuid() else { return false }
        let immutable = UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)
        guard (st.st_flags & immutable) == 0 else { return false }

        let parent = (resolvedPath as NSString).deletingLastPathComponent
        let tempPath = (parent as NSString).appendingPathComponent(".unison-ui-mac.meta.\(UUID().uuidString)")
        // Create an empty sibling and try to clone metadata onto it.
        guard FileManager.default.createFile(atPath: tempPath, contents: Data(), attributes: nil) else { return false }
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        let flags = copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT)
        return copyfile(resolvedPath, tempPath, nil, flags) == 0
    }
}
