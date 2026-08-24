import Foundation

/// Explicit recovery for a PRE-COMMIT abandoned staging (an interrupted archive
/// mutation, detected by `AbandonedStagingScan`). The safe direction is to
/// RESTORE the staged files back into the active directory — NEVER to trash the
/// quarantine, which pre-commit holds the only copy of some files. Restoration
/// never overwrites a collision (e.g. a file the engine re-created), never
/// deletes anything, and the recorded lock is removed only after the caller has
/// established exclusive ownership (the user attests no other Unison is running).
enum ArchiveStagingRecovery {

    struct RestoreResult: Equatable {
        /// Files moved back from the quarantine to the active directory.
        let restored: [String]
        /// Files NOT restored because the active directory already has that name
        /// (a collision) — left in the quarantine, untouched, for manual review.
        let collided: [String]
        /// Files whose restore move failed for another reason — left in the
        /// quarantine, untouched.
        let failed: [String]

        var isComplete: Bool { collided.isEmpty && failed.isEmpty }
    }

    /// Restore every staged payload file back into `activeDir`, skipping any that
    /// would overwrite an existing file. Never deletes anything.
    @discardableResult
    static func restore(_ abandoned: AbandonedStaging,
                        activeDir: String,
                        fileManager fm: FileManager = .default) -> RestoreResult {
        var restored: [String] = []
        var collided: [String] = []
        var failed: [String] = []
        for name in abandoned.manifest.payloadFiles.sorted() {
            let src = (abandoned.quarantineDir as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: src) else { continue }  // already restored / absent
            let dst = (activeDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: dst) { collided.append(name); continue }
            do { try fm.moveItem(atPath: src, toPath: dst); restored.append(name) }
            catch { failed.append(name) }
        }
        return RestoreResult(restored: restored, collided: collided, failed: failed)
    }

    /// After a COMPLETE restore (no collisions/failures) and no remaining payload
    /// files, remove the quarantine directory + manifest. Returns whether it was
    /// removed. Refuses if any payload file still remains in the quarantine.
    @discardableResult
    static func finalize(_ abandoned: AbandonedStaging,
                         fileManager fm: FileManager = .default) -> Bool {
        // Only remove the quarantine if it holds no payload files any more (the
        // manifest itself may remain). A lingering payload means an incomplete
        // restore — keep everything for manual review.
        let remaining = abandoned.manifest.payloadFiles.filter {
            fm.fileExists(atPath: (abandoned.quarantineDir as NSString).appendingPathComponent($0))
        }
        guard remaining.isEmpty else { return false }
        do { try fm.removeItem(atPath: abandoned.quarantineDir); return true }
        catch { return false }
    }

    /// Remove the recorded `lk` locks. Call ONLY after exclusive ownership is
    /// established (the user has confirmed no other Unison is running) — the raw
    /// upstream lock carries no owner metadata, so it can never be removed
    /// automatically. Returns the hashes whose lock was removed.
    @discardableResult
    static func removeLocks(_ abandoned: AbandonedStaging,
                            activeDir: String,
                            fileManager fm: FileManager = .default) -> [String] {
        var removed: [String] = []
        for hash in abandoned.manifest.hashes {
            let lk = (activeDir as NSString).appendingPathComponent("lk" + hash)
            if fm.fileExists(atPath: lk) {
                if (try? fm.removeItem(atPath: lk)) != nil { removed.append(hash) }
            }
        }
        return removed
    }

    /// Profile-open gate: a profile whose any archive hash is blocked by a
    /// pre-commit abandoned staging must not be opened until recovery. Pure.
    static func isProfileBlocked(profileHashes: [String], blocked: Set<String>) -> Bool {
        !Set(profileHashes).isDisjoint(with: blocked)
    }
}
