import Foundation

// The filesystem operations that place a startup file's new contents: replace an
// existing file with an identity re-check at the seam, or create an absent one
// with RENAME_EXCL. The rename that commits the change goes through an open
// descriptor on the parent directory, so an ancestor rename during the operation
// cannot redirect it. See docs/command-line-setup-design.md, "Write procedure:
// replacement" and "Write procedure: creation".
//
// The writer never chooses a file or decides ownership; it is handed a resolved
// path and the exact bytes to write, and reports what happened so the caller can
// keep or discard the pending ownership record.

/// A file's identity and content at a moment, for detecting a change at the seam.
struct CommandLineSetupFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mtimeSec: Int
    let mtimeNsec: Int
    let contentHash: String
}

/// What a write did to the file. The caller maps this to the ownership record and
/// the status line.
enum CommandLineSetupWriteOutcome: Equatable {
    /// The rename succeeded and the read-back matched. Promote pending.
    case mutated
    /// The rename succeeded but the read-back failed. Keep pending; report "the
    /// result could not be read back".
    case mutatedReadBackFailed
    /// Refused before the rename, or the rename failed with a no-change errno.
    /// Nothing changed; delete pending.
    case notMutated(reason: String)
    /// The rename failed with an errno outside the no-change list. Keep pending;
    /// the app does not claim the entry was written.
    case uncertain(reason: String)
}

enum CommandLineSetupWriter {

    /// RENAME_EXCL: fail rather than overwrite an existing name. Mirrors
    /// <sys/stat.h>; named locally so the build does not depend on the overlay
    /// exposing the macro.
    private static let renameExcl: UInt32 = 0x0000_0004

    private static let metadataCloneFlags = copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT)

    // MARK: Snapshot

    /// The identity and content hash of the file at `path`, or nil when it cannot
    /// be read. `path` is expected to be already resolved (symlinks followed).
    static func snapshot(atPath path: String) -> CommandLineSetupFileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return identity(stat: st, content: data)
    }

    /// The snapshot AND the file's contents from a SINGLE read, so the text used
    /// to build a replacement and the identity that guards the seam describe the
    /// same bytes. Reading the content separately from the snapshot would let an
    /// intervening save be accepted by the seam check and then overwritten with
    /// text derived from the older file.
    static func snapshotWithContents(atPath path: String)
        -> (identity: CommandLineSetupFileIdentity, contents: String)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (identity(stat: st, content: data), String(decoding: data, as: UTF8.self))
    }

    // MARK: Replacement

    /// Replace the regular file at `resolvedPath` with `newContents`, cloning the
    /// original's metadata onto the replacement and re-checking identity and
    /// content immediately before the rename. `expected` is the snapshot taken
    /// when the change was prepared; any difference at the seam refuses.
    static func replace(resolvedPath: String,
                        newContents: String,
                        expected: CommandLineSetupFileIdentity) -> CommandLineSetupWriteOutcome {
        let parent = (resolvedPath as NSString).deletingLastPathComponent
        let name = (resolvedPath as NSString).lastPathComponent

        let dirfd = open(parent, O_RDONLY | O_DIRECTORY)
        guard dirfd >= 0 else {
            return .notMutated(reason: "the file's directory could not be opened")
        }
        defer { close(dirfd) }

        // Re-read identity and content through the directory descriptor and refuse
        // on any difference from the snapshot.
        guard let current = identity(dirfd: dirfd, name: name, fullPath: resolvedPath), current == expected else {
            return .notMutated(reason: "The file changed while the entry was being prepared. Nothing was written.")
        }

        let tempName = ".unison-ui-mac.tmp.\(UUID().uuidString)"
        let tempPath = (parent as NSString).appendingPathComponent(tempName)
        let tempfd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard tempfd >= 0 else {
            return .notMutated(reason: "a temporary file could not be created next to the target")
        }
        var placed = false
        func cleanup() { if !placed { unlinkat(dirfd, tempName, 0) } }
        guard writeAll(fd: tempfd, string: newContents) else {
            close(tempfd); cleanup()
            return .notMutated(reason: "the replacement could not be written")
        }
        close(tempfd)

        guard copyfile(resolvedPath, tempPath, nil, metadataCloneFlags) == 0 else {
            cleanup()
            return .notMutated(reason: "the file's metadata could not be preserved")
        }

        // Final seam check, then the atomic replace within the directory.
        guard let atSeam = identity(dirfd: dirfd, name: name, fullPath: resolvedPath), atSeam == expected else {
            cleanup()
            return .notMutated(reason: "The file changed while the entry was being prepared. Nothing was written.")
        }
        if renameat(dirfd, tempName, dirfd, name) != 0 {
            let e = errno
            cleanup()
            switch CommandLineSetupRecordStore.classify(renameSucceeded: false, errnoValue: e) {
            case .notMutated: return .notMutated(reason: "the file could not be replaced (\(String(cString: strerror(e))))")
            default: return .uncertain(reason: "The file operation's result could not be established.")
            }
        }
        placed = true  // the temp name is now the target; nothing to unlink

        return readBackMatches(path: resolvedPath, expected: newContents)
            ? .mutated : .mutatedReadBackFailed
    }

    // MARK: Creation

    /// Create `resolvedPath` with `contents` only if the name is absent, placing it
    /// with RENAME_EXCL so a name that appears in the meantime is not overwritten.
    /// When `ensuringParentDirectory` is set (fish's `conf.d`), an absent parent is
    /// created with mode `0777 & ~umask`.
    static func create(resolvedPath: String,
                       contents: String,
                       ensuringParentDirectory: Bool) -> CommandLineSetupWriteOutcome {
        let parent = (resolvedPath as NSString).deletingLastPathComponent
        let name = (resolvedPath as NSString).lastPathComponent

        var dirfd = open(parent, O_RDONLY | O_DIRECTORY)
        if dirfd < 0, ensuringParentDirectory, errno == ENOENT {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            dirfd = open(parent, O_RDONLY | O_DIRECTORY)
        }
        guard dirfd >= 0 else {
            return .notMutated(reason: "the file's directory could not be created or opened")
        }
        defer { close(dirfd) }

        // Snapshot absence through the directory descriptor: only ENOENT is
        // absence; a dangling symlink or a permission error is not.
        var st = stat()
        if fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            return .notMutated(reason: "a file already exists at the target; nothing was written")
        }
        guard errno == ENOENT else {
            return .notMutated(reason: "the target's absence could not be confirmed")
        }

        let tempName = ".unison-ui-mac.tmp.\(UUID().uuidString)"
        let tempPath = (parent as NSString).appendingPathComponent(tempName)
        let tempfd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, 0o666)
        guard tempfd >= 0 else {
            return .notMutated(reason: "a temporary file could not be created")
        }
        var placed = false
        func cleanup() { if !placed { unlinkat(dirfd, tempName, 0) } }
        guard writeAll(fd: tempfd, string: contents) else {
            close(tempfd); cleanup()
            return .notMutated(reason: "the file could not be written")
        }
        close(tempfd)

        if renameatx_np(dirfd, tempName, dirfd, name, renameExcl) != 0 {
            let e = errno
            cleanup()
            switch CommandLineSetupRecordStore.classify(renameSucceeded: false, errnoValue: e) {
            case .notMutated: return .notMutated(reason: "the file could not be created (\(String(cString: strerror(e))))")
            default: return .uncertain(reason: "The file operation's result could not be established.")
            }
        }
        placed = true

        return readBackMatches(path: resolvedPath, expected: contents)
            ? .mutated : .mutatedReadBackFailed
    }

    // MARK: Removal

    /// Delete the file at `resolvedPath` (the fish case) through the directory
    /// descriptor, but only if it still matches `expected` — the identity and
    /// content snapshotted when it was inspected. A file changed or replaced since
    /// then is refused, so removal never deletes another writer's content. zsh/bash
    /// removal is a `replace` with the block-removed contents.
    static func removeFile(resolvedPath: String,
                           expected: CommandLineSetupFileIdentity) -> CommandLineSetupWriteOutcome {
        let parent = (resolvedPath as NSString).deletingLastPathComponent
        let name = (resolvedPath as NSString).lastPathComponent
        let dirfd = open(parent, O_RDONLY | O_DIRECTORY)
        guard dirfd >= 0 else {
            return .notMutated(reason: "the file's directory could not be opened")
        }
        defer { close(dirfd) }
        // Re-check identity and content through the directory descriptor before
        // deleting; the design requires this re-check.
        guard let current = identity(dirfd: dirfd, name: name, fullPath: resolvedPath), current == expected else {
            return .notMutated(reason: "The file changed while the entry was being prepared. Nothing was written.")
        }
        if unlinkat(dirfd, name, 0) != 0 {
            let e = errno
            switch CommandLineSetupRecordStore.classify(renameSucceeded: false, errnoValue: e) {
            case .notMutated: return .notMutated(reason: "the file could not be removed (\(String(cString: strerror(e))))")
            default: return .uncertain(reason: "The file operation's result could not be established.")
            }
        }
        return .mutated
    }

    // MARK: Helpers

    private static func identity(stat st: stat, content data: Data) -> CommandLineSetupFileIdentity {
        CommandLineSetupFileIdentity(
            device: st.st_dev, inode: st.st_ino, size: st.st_size,
            mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec,
            contentHash: CommandLineSetupBlock.hash(ofBlockText: String(decoding: data, as: UTF8.self)))
    }

    /// Stat the directory ENTRY through the descriptor (safe against an ancestor
    /// rename) and read the content by path. `AT_SYMLINK_NOFOLLOW` stats the entry
    /// itself, and the entry must be a regular file, so a symlink introduced at the
    /// name since the snapshot — even one that resolves to the same bytes — is
    /// detected rather than followed. A concurrent writer, a vanished file, or a
    /// substituted symlink yields nil, which the caller treats as a refusal.
    private static func identity(dirfd: Int32, name: String, fullPath: String) -> CommandLineSetupFileIdentity? {
        var st = stat()
        guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        guard let data = FileManager.default.contents(atPath: fullPath) else { return nil }
        return identity(stat: st, content: data)
    }

    private static func readBackMatches(path: String, expected: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return String(decoding: data, as: UTF8.self) == expected
    }

    private static func writeAll(fd: Int32, string: String) -> Bool {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
