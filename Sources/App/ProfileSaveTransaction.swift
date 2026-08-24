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
    /// Install `content` at `path` with NO-REPLACE semantics, atomically at the
    /// commit point. Stage into a UNIQUE, PRIVATE same-directory file (so
    /// concurrent callers never share a staging path and cannot cross-write),
    /// then install it ONLY if `path` still does not exist. If `path` was
    /// created between the caller's earlier `exists` check and this call (the
    /// TOCTOU race), this MUST fail rather than overwrite — throwing a
    /// `ProfileFileOpsError` whose `code == EEXIST`. Implementations must never
    /// remove or overwrite another caller's staging file. If installation fails
    /// AND the implementation's own private staging file cannot be cleaned up,
    /// it throws `ProfileSaveError.cleanupFailed` naming both the primary
    /// failure and the residual temp (not reduced to `.destinationExists` /
    /// `.writeFailed`). Used for new profiles and renames, where clobbering an
    /// unrelated file that appeared mid-flight would be data loss.
    ///
    /// A conforming implementation MUST also verify the write completed fully
    /// (every byte; a positive-length `write` returning 0 is a failure) and make
    /// the installed content durable (fsync) BEFORE the atomic install — a
    /// staging file whose write/fsync/close did not succeed is never renamed
    /// into place. `SystemFileOps` does exactly this.
    func installExclusive(_ content: String, to path: String) throws
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
    /// The primary operation was undone/never applied, but a temp-file cleanup
    /// failed, leaving a stray residue (e.g. a `<name>.prf.bak.tmp`). The
    /// profile itself is intact; the message names the residue precisely rather
    /// than claiming "nothing changed". Distinct from `backupFailed` (which
    /// asserts a fully clean state).
    case cleanupFailed(String)
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

    /// Remove each path that exists; return a description of every removal that
    /// FAILED (empty ⇒ all clean). Used for rollback and temp cleanup so a
    /// failure is reported honestly rather than swallowed with `try?`.
    private func rollback(_ paths: [String]) -> [String] {
        var residue: [String] = []
        for p in paths where ops.exists(p) {
            do { try ops.remove(p) } catch { residue.append("\(p): \(describe(error))") }
        }
        return residue
    }

    /// Clear a temp file we own. Returns nil if it was absent or removed;
    /// otherwise a description of the removal failure (a stray-temp residue).
    private func clearTemp(_ path: String) -> String? {
        guard ops.exists(path) else { return nil }
        do { try ops.remove(path); return nil }
        catch { return "stale temp \(path) could not be removed: \(describe(error))" }
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
        // This is a fast, friendly PRE-check; it is NOT the race guard — that
        // is the exclusive install at the actual commit point below, which
        // catches a destination created between here and the write.
        if (isNew || isRename), ops.exists(dest) {
            throw ProfileSaveError.destinationExists(name: newName)
        }

        if isRename {
            try commitRename(oldName: oldName!, newName: newName, dest: dest, content: content)
        } else if isNew {
            try commitNew(dest: dest, newName: newName, content: content)
        } else {
            try commitInPlace(dest: dest, content: content)
        }
    }

    /// Install a NEW profile exclusively, so a destination that appeared after
    /// the pre-check (another actor, another window) is never overwritten.
    private func commitNew(dest: String, newName: String, content: String) throws {
        try exclusiveInstall(content, to: dest, newName: newName)
    }

    /// Exclusive (no-replace) install with `ProfileSaveError` mapping shared by
    /// the new-profile and rename paths. An `EEXIST` (the destination appeared
    /// mid-flight) is surfaced as `.destinationExists`, exactly like the
    /// pre-check, so the caller's identity stays correct and a retry is clean.
    private func exclusiveInstall(_ content: String, to dest: String, newName: String) throws {
        do {
            try ops.installExclusive(content, to: dest)
        } catch let e as ProfileFileOpsError where e.code == EEXIST {
            throw ProfileSaveError.destinationExists(name: newName)
        } catch let e as ProfileSaveError {
            throw e
        } catch {
            throw ProfileSaveError.writeFailed(describe(error))
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
            // Clear a stale temp from a prior crash. If it can't be removed,
            // that is a residue we must report — not silently proceed or claim
            // "nothing changed". The original is still intact (untouched).
            if let residue = clearTemp(tmpBak) {
                throw ProfileSaveError.cleanupFailed(
                    "\(residue); the original \(dest) is unchanged — remove the stale temp and retry")
            }
            do {
                try ops.copy(from: dest, to: tmpBak)
                try ops.move(from: tmpBak, to: bak)
            } catch let backupError {
                // Best-effort clean the temp; if it lingers, report the residue.
                if let residue = clearTemp(tmpBak) {
                    throw ProfileSaveError.cleanupFailed(
                        "backup failed (\(describe(backupError))) and then \(residue); " +
                        "the original \(dest) is unchanged")
                }
                throw ProfileSaveError.backupFailed(describe(backupError))
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

        // 1. Install the NEW file EXCLUSIVELY (no-replace) at the commit point.
        //    The old file is untouched here, so on failure nothing needs
        //    undoing and the original is fully intact. Exclusive install also
        //    closes the TOCTOU race: a `<newName>.prf` that appeared after the
        //    step-0 pre-check is surfaced as `.destinationExists`, never
        //    clobbered.
        try exclusiveInstall(content, to: dest, newName: newName)

        // 2. Back up the IMMEDIATELY-PRE-SAVE current source profile as the
        //    renamed profile's backup — matching in-place-overwrite semantics
        //    (`<name>.prf.bak` holds what was there before this save). This is
        //    NOT the old profile's prior `.bak`; it is `old`'s current content.
        //    On failure, roll the new file back to the exact pre-save state.
        if let residue = clearTemp(tmpBak) {         // stale temp blocks the backup
            let rb = rollback([dest])                // undo the new file
            throw ProfileSaveError.rollbackFailed(rb.isEmpty
                ? "\(residue); the new file \(dest) was rolled back (original intact), but the stale temp remains"
                : "\(residue); AND rolling back the new file left residue: \(rb.joined(separator: "; "))")
        }
        do {
            try ops.copy(from: old, to: tmpBak)
            try ops.move(from: tmpBak, to: newBak)
        } catch let backupError {
            // Roll back the new file AND any leftover temp. If that rollback
            // fully succeeds the disk is at the exact pre-save state; otherwise
            // report the true residue rather than claiming a clean rollback.
            let rb = rollback([dest, tmpBak])
            if rb.isEmpty {
                throw ProfileSaveError.backupFailed(describe(backupError))
            }
            throw ProfileSaveError.rollbackFailed(
                "backup of \(old) failed (\(describe(backupError))) and rollback left " +
                "residue: " + rb.joined(separator: "; "))
        }

        // 3. Remove the OLD profile now that the new file AND its backup are
        //    durable. On failure, roll back BOTH the new file and the new backup
        //    to return to the exact pre-save state (old-only). If any part of
        //    that rollback fails, report the true residue rather than claiming a
        //    clean pre-save state.
        do {
            try ops.remove(old)
        } catch let removeError {
            let rb = rollback([dest, newBak])
            if rb.isEmpty {
                throw ProfileSaveError.renameCleanupFailed(describe(removeError))
            }
            throw ProfileSaveError.rollbackFailed(
                "removing old profile \(old) failed (\(describe(removeError))) and " +
                "rollback left residue: " + rb.joined(separator: "; "))
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
        // commit the transaction relies on. This REPLACES an existing file
        // (intentional for an in-place overwrite).
        //
        // SF15: if `path` is a symlink (e.g. ~/.unison/foo.prf → a dotfiles repo),
        // resolve it and write to the REAL target, so the temp+rename replaces the
        // target and the symlink is preserved — a deliberate write-through, rather
        // than replacing the symlink with a regular file and orphaning the linked
        // copy. The temp lands in the target's own directory, keeping the rename
        // atomic on the target's filesystem.
        try content.write(toFile: realTarget(path), atomically: true, encoding: .utf8)
    }

    /// Fully resolve a leaf symlink to the real file it points at (following the
    /// whole chain). A non-symlink is returned unchanged. A dangling link resolves
    /// to its intended target (so a write creates it and the link stops dangling).
    private func realTarget(_ path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return path }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil { return String(cString: buf) }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
            return (dest as NSString).isAbsolutePath
                ? dest
                : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        }
        return path
    }

    func installExclusive(_ content: String, to path: String) throws {
        // Stage into a UNIQUE, PRIVATE file in the same directory via mkstemp
        // (which opens O_CREAT|O_EXCL, so every caller gets its own name), then
        // install with an atomic no-replace rename. A shared fixed staging path
        // like `<dest>.new.tmp` would let concurrent callers delete, truncate,
        // or write through one another's staging file — so a "successful"
        // install could carry another caller's bytes. A per-call mkstemp name
        // makes that impossible: we write to our own fd and NEVER touch another
        // caller's staging file. `renamex_np(..., RENAME_EXCL)` then fails with
        // EEXIST if `path` already exists — so a destination created between the
        // caller's `exists` pre-check and here is never overwritten (the TOCTOU
        // race), and the install itself is atomic.
        let dir = (path as NSString).deletingLastPathComponent
        let template = (dir as NSString).appendingPathComponent(".unison-ui-save.XXXXXX")
        var tmplBytes = Array(template.utf8CString)
        let fd = tmplBytes.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else {
            throw ProfileFileOpsError(operation: "mkstemp", from: template, to: path, code: errno)
        }
        let tmp = String(cString: tmplBytes)

        // Write the full content to THIS exact fd, verify EVERY byte landed, set
        // its mode, fsync for durability, and close — surfacing every failure.
        // Profiles are config files; 0644 matches typical .prf perms (mkstemp
        // opens 0600). A positive-length write returning 0, or a fchmod/fsync/
        // close failure, is a hard failure: we must NEVER rename a staging file
        // whose write did not fully complete and durably land.
        if let werr = StagingFileWriter.writeAllAndFinalize(
            fd: fd, data: Data(content.utf8), mode: 0o644) {
            // Remove OUR OWN private staging file; the destination is untouched.
            try removePrivateStagingOrThrow(
                tmp, primary: "staging \(path) failed: \(werr.message)", dest: path)
            throw ProfileFileOpsError(operation: werr.operation, from: tmp, to: path, code: werr.code)
        }

        if renamex_np(tmp, path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            // Remove OUR OWN private staging file (never another caller's). If
            // that removal ALSO fails, surface an explicit cleanup error naming
            // both the primary failure and the residual temp — do NOT reduce it
            // to destinationExists/writeFailed and claim a clean state.
            try removePrivateStagingOrThrow(
                tmp, primary: "exclusive install of \(path) failed: \(String(cString: strerror(code)))",
                dest: path)
            throw ProfileFileOpsError(operation: "renamex_np(RENAME_EXCL)",
                                      from: tmp, to: path, code: code)
        }

        // Make the new directory entry durable too: the file content was already
        // fsync'd before the rename, and fsyncing the containing directory
        // persists the rename itself so the committed profile survives a crash.
        // Best-effort — the rename has already succeeded atomically, so a
        // directory-fsync failure does not invalidate the (committed) install.
        let dfd = open(dir, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }

    /// Remove our own private staging file. On a removal failure, throw an
    /// explicit `.cleanupFailed` naming the primary failure and the residual
    /// temp — never swallow it with `try?`.
    private func removePrivateStagingOrThrow(_ tmp: String, primary: String, dest: String) throws {
        guard fm.fileExists(atPath: tmp) else { return }
        do { try fm.removeItem(atPath: tmp) }
        catch {
            throw ProfileSaveError.cleanupFailed(
                "\(primary); AND its private staging file \(tmp) could not be removed " +
                "(\(error.localizedDescription)); the staging file remains and \(dest) is unchanged")
        }
    }

    func copy(from: String, to: String) throws {
        // `to` is always a fresh temp path the transaction owns; clear a stale
        // one so copyItem (which fails if the destination exists) succeeds.
        // Copy need NOT be atomic — the caller atomically MOVES the temp into
        // place afterward.
        if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        // SF15: back up the real CONTENT, not the symlink — `copyItem` would
        // otherwise copy a link, giving a ".bak" that tracks the target instead of
        // preserving the pre-save bytes. Resolving a non-symlink is a no-op.
        try fm.copyItem(atPath: realTarget(from), toPath: to)
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
