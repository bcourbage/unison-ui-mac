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
    /// A backup already exists at the destination name (`<newName>.prf.bak`).
    /// A rename would otherwise silently destroy it, so we refuse up front.
    case destinationBackupExists(name: String)
    /// Backing up the existing profile failed — nothing was overwritten (or,
    /// on a rename, the newly-written file was rolled back). Pre-save state.
    case backupFailed(String)
    /// Writing the new content failed — the original is intact.
    case writeFailed(String)
    /// A rename couldn't be completed and was rolled back to the pre-save state.
    case renameCleanupFailed(String)
    /// A rename failed AND the rollback itself failed, so the on-disk state is
    /// NOT the clean pre-save state. The message describes the actual residue
    /// (e.g. both the original and the new file present). Deliberately distinct
    /// so we never falsely claim a clean rollback.
    case rollbackFailed(String)
}

/// A low-level filesystem-op failure carrying `errno`, thrown by `SystemFileOps`
/// where the operation is a raw syscall (e.g. `rename`).
struct ProfileFileOpsError: Error, Equatable {
    let operation: String
    let from: String
    let to: String
    let code: Int32
    var localizedMessage: String {
        "\(operation) \(from) -> \(to) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// A failure-safe, retry-consistent profile save/rename.
///
/// Invariants (Finding #11):
/// - The original profile stays recoverable until the replacement is durably
///   written (writes are atomic; a rename writes the new file BEFORE removing
///   the old one).
/// - A failed write / rename / backup leaves a coherent filesystem state — on a
///   rename failure the transaction rolls back to exactly the pre-save state,
///   or, if the rollback itself fails, reports the true residue via
///   `.rollbackFailed` (it never claims a clean pre-save state it didn't reach).
/// - Because a failure leaves the pre-save state intact, the caller's identity
///   (`initialProfileName`) stays correct and a retry behaves correctly.
/// - Each single-file commit is atomic: `writeAtomic` and `move` (POSIX
///   `rename`) each leave their target holding either the old or the new bytes,
///   never a partial or absent file. Backups are committed by an atomic move
///   over `<name>.prf.bak`, so a backup failure never destroys the existing one.
/// - A rename backs up the immediately-pre-save SOURCE content under the new
///   name, and refuses up front if `<newName>.prf.bak` already exists rather
///   than clobbering an unrelated backup.
///
/// CRASH SCOPE (be precise): each INDIVIDUAL step is crash-atomic, but the
/// multi-step rename (write new, back up, remove old) is NOT one crash-atomic
/// transaction. A crash BETWEEN steps leaves a well-defined, recoverable
/// intermediate (e.g. both files present, or new + its backup present) with no
/// data loss — not all-or-nothing atomicity. In-process failures ARE handled
/// all-or-nothing via the rollbacks above; only a hard crash mid-sequence can
/// leave the recoverable intermediate.
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
            try commitRename(oldName: oldName!, newName: newName, dest: dest, content: content)
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

    /// Rename: write the new-named file, back up the immediately-pre-save
    /// source content under the new name, then remove the old file. The
    /// original stays fully recoverable until the replacement is durable; any
    /// failure rolls back to EXACTLY the pre-save state (or, if the rollback
    /// itself fails, reports the true residue via `.rollbackFailed`).
    private func commitRename(oldName: String, newName: String,
                              dest: String, content: String) throws {
        let old = prf(oldName)
        let oldBak = old + ".bak"
        let newBak = dest + ".bak"
        let tmpBak = dest + ".bak.tmp"

        // 0. Refuse to clobber an existing backup at the destination name. The
        //    destinationExists check in `commit` only covers `<newName>.prf`;
        //    a stray `<newName>.prf.bak` must not be silently destroyed.
        if ops.exists(newBak) {
            throw ProfileSaveError.destinationBackupExists(name: newName)
        }

        // 1. Durably write the NEW file. The old file is untouched here, so on
        //    failure nothing needs undoing and the original is fully intact.
        do {
            try ops.writeAtomic(content, to: dest)
        } catch {
            throw ProfileSaveError.writeFailed(describe(error))
        }

        // 2. Back up the IMMEDIATELY-PRE-SAVE current source profile as the
        //    renamed profile's backup — matching in-place-overwrite semantics
        //    (`<name>.prf.bak` holds what was there before this save). This is
        //    NOT the old profile's prior `.bak`; it is `old`'s current content.
        //    On failure, roll the new file back to the exact pre-save state.
        try? ops.remove(tmpBak)
        do {
            try ops.copy(from: old, to: tmpBak)
            try ops.move(from: tmpBak, to: newBak)
        } catch let backupError {
            try? ops.remove(tmpBak)
            do {
                try ops.remove(dest)                    // roll back the new file
            } catch let rollbackError {
                throw ProfileSaveError.rollbackFailed(
                    "backup of \(old) failed (\(describe(backupError))) and rolling " +
                    "back the new file \(dest) also failed (\(describe(rollbackError))); " +
                    "disk now holds BOTH \(old) and \(dest).")
            }
            throw ProfileSaveError.backupFailed(describe(backupError))
        }

        // 3. Remove the OLD profile now that the new file AND its backup are
        //    durable. On failure, roll back BOTH the new file and the new backup
        //    to return to the exact pre-save state (old-only). If any part of
        //    that rollback fails, report the true residue rather than claiming a
        //    clean pre-save state.
        do {
            try ops.remove(old)
        } catch let removeError {
            var residue: [String] = []
            do { try ops.remove(dest) } catch { residue.append("new file \(dest): \(describe(error))") }
            do { try ops.remove(newBak) } catch { residue.append("new backup \(newBak): \(describe(error))") }
            if !residue.isEmpty {
                throw ProfileSaveError.rollbackFailed(
                    "removing old profile \(old) failed (\(describe(removeError))) and " +
                    "rollback left residue: " + residue.joined(separator: "; "))
            }
            throw ProfileSaveError.renameCleanupFailed(describe(removeError))
        }

        // 4. Best-effort cleanup of the now-orphaned OLD backup sidecar. The
        //    rename has already fully succeeded; a failure here is cosmetic and
        //    never destroys the new profile or its backup.
        if ops.exists(oldBak) {
            try? ops.remove(oldBak)
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
        // `to` is always a fresh temp path the transaction owns; clear a stale
        // one so copyItem (which fails if the destination exists) succeeds.
        // Copy need NOT be atomic — the caller atomically MOVES the temp into
        // place afterward.
        if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        try fm.copyItem(atPath: from, toPath: to)
    }

    func move(from: String, to: String) throws {
        // POSIX rename(2) atomically replaces `to` on the same filesystem in a
        // single step. The old delete-then-moveItem approach was NOT atomic: it
        // removed `to` first, so a crash (or failure) between the remove and the
        // move left `to` ABSENT — destroying an existing backup the transaction
        // was relying on. rename() never leaves `to` momentarily absent: after
        // it, `to` holds either the old bytes (on failure) or the new (on
        // success). Every path here is inside the Unison directory, so the
        // same-filesystem precondition (no EXDEV) holds.
        if rename(from, to) != 0 {
            throw ProfileFileOpsError(operation: "rename", from: from, to: to, code: errno)
        }
    }

    func remove(_ path: String) throws {
        try fm.removeItem(atPath: path)
    }
}
