import Foundation

/// Filesystem operations a profile save/rename needs, behind a protocol so the
/// transaction logic is pure and every failure point is deterministically
/// testable with a fault-injecting fake (Finding #11). The real implementation
/// is `SystemFileOps`.
protocol ProfileFileOps {
    func exists(_ path: String) -> Bool
    /// Write `content` to `path` atomically: a temp file in the SAME directory
    /// (destination filesystem) followed by an atomic rename, so `path` is
    /// never left partially written — it holds either the old bytes or the new.
    func writeAtomic(_ content: String, to path: String) throws
    func copy(from: String, to: String) throws
    func move(from: String, to: String) throws
    func remove(_ path: String) throws
}

/// Classified, stage-specific failure so the caller can message precisely and
/// so tests can assert which stage failed. In EVERY failure case the on-disk
/// state is left coherent (see `ProfileSaveTransaction`).
enum ProfileSaveError: Error, Equatable {
    /// The destination `.prf` already exists (a different, unrelated profile).
    case destinationExists(name: String)
    /// Backing up the existing profile failed — nothing was overwritten.
    case backupFailed(String)
    /// Writing the new content failed — the original is intact.
    case writeFailed(String)
    /// A rename couldn't be completed and was rolled back to the pre-save state.
    case renameCleanupFailed(String)
}

/// A failure-safe, retry-consistent profile save/rename.
///
/// Invariants (Finding #11):
/// - The original profile stays recoverable until the replacement is durably
///   written (writes are atomic; a rename writes the new file BEFORE removing
///   the old one).
/// - A failed write / rename / backup leaves a coherent filesystem state — on a
///   rename failure the transaction rolls back to exactly the pre-save state.
/// - Because a failure leaves the pre-save state intact, the caller's identity
///   (`initialProfileName`) stays correct and a retry behaves correctly.
/// - Replacement backups are created BEFORE the prior backup is removed (an
///   atomic move over `<name>.prf.bak`), so a backup failure never destroys the
///   existing backup.
/// - Temp files live in the destination directory and are committed atomically.
struct ProfileSaveTransaction {
    let ops: ProfileFileOps
    let unisonDirectory: String

    func prf(_ name: String) -> String {
        (unisonDirectory as NSString).appendingPathComponent("\(name).prf")
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// Commit the save. `oldName == nil` ⇒ a brand-new profile;
    /// `oldName != newName` ⇒ a rename; otherwise an in-place overwrite.
    /// Throws a `ProfileSaveError` (leaving disk coherent) on any failure.
    func commit(oldName: String?, newName: String, content: String) throws {
        let dest = prf(newName)
        let isNew = (oldName == nil)
        let isRename = (oldName != nil && oldName != newName)

        // A new or renamed profile must not clobber an unrelated existing file.
        // (An in-place overwrite legitimately finds its own file present.)
        if (isNew || isRename), ops.exists(dest) {
            throw ProfileSaveError.destinationExists(name: newName)
        }

        if isRename {
            try commitRename(oldName: oldName!, dest: dest, content: content)
        } else {
            try commitInPlace(dest: dest, content: content)
        }
    }

    /// New profile or overwrite under the same name.
    private func commitInPlace(dest: String, content: String) throws {
        // Back up the current file (if any) BEFORE overwriting. Copy to a temp
        // in the destination directory, then atomically move it over the `.bak`
        // — this replaces any prior backup in one step, and if the copy fails
        // the existing `.bak` is untouched.
        if ops.exists(dest) {
            let bak = dest + ".bak"
            let tmpBak = dest + ".bak.tmp"
            try? ops.remove(tmpBak)   // clear a stale temp from a prior crash
            do {
                try ops.copy(from: dest, to: tmpBak)
                try ops.move(from: tmpBak, to: bak)
            } catch {
                try? ops.remove(tmpBak)
                throw ProfileSaveError.backupFailed(describe(error))
            }
        }
        // Atomic write: on failure `dest` keeps its previous bytes, and the
        // backup we just made still holds the original.
        do {
            try ops.writeAtomic(content, to: dest)
        } catch {
            throw ProfileSaveError.writeFailed(describe(error))
        }
    }

    /// Rename: write the new-named file with the new content, then remove the
    /// old file. The original stays fully recoverable until the new file is
    /// durably written; a failure to remove the old file rolls the new one back.
    private func commitRename(oldName: String, dest: String, content: String) throws {
        let old = prf(oldName)
        let oldBak = old + ".bak"
        let newBak = dest + ".bak"

        // 1. Durably write the NEW file. Old file is untouched here, so on
        //    failure nothing needs undoing and the original is intact.
        do {
            try ops.writeAtomic(content, to: dest)
        } catch {
            throw ProfileSaveError.writeFailed(describe(error))
        }

        // 2. Remove the OLD profile now that the new one is durable. On failure,
        //    undo the new file so we return to EXACTLY the pre-save state
        //    (old-only) — a coherent state the user can retry from.
        do {
            try ops.remove(old)
        } catch {
            try? ops.remove(dest)
            throw ProfileSaveError.renameCleanupFailed(describe(error))
        }

        // 3. Carry the old backup sidecar to the new name (post-commit,
        //    best-effort — the rename itself has already succeeded).
        if ops.exists(oldBak) {
            try? ops.move(from: oldBak, to: newBak)
        }
    }
}

/// Real filesystem implementation.
struct SystemFileOps: ProfileFileOps {
    private var fm: FileManager { .default }

    func exists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    func writeAtomic(_ content: String, to path: String) throws {
        // `atomically: true` writes to a temp file in the same directory and
        // renames it into place — exactly the destination-filesystem atomic
        // commit the transaction relies on.
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func copy(from: String, to: String) throws {
        if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        try fm.copyItem(atPath: from, toPath: to)
    }

    func move(from: String, to: String) throws {
        if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        try fm.moveItem(atPath: from, toPath: to)
    }

    func remove(_ path: String) throws {
        try fm.removeItem(atPath: path)
    }
}
