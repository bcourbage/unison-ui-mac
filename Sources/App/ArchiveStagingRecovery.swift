import Foundation

/// Explicit recovery for an abandoned staging (an interrupted archive mutation,
/// detected by `AbandonedStagingScan`). `recover(_:activeDir:locking:)` is the
/// authoritative entry point; the other functions are its building blocks.
///
/// Recovery direction depends on phase. PRE-COMMIT, the quarantine holds the
/// only copy of some files, so the safe direction is to RESTORE them back into
/// the active directory (never overwriting a collision, never deleting). COMMITTED,
/// the removal was intended and the family is already staged out, so recovery
/// completes it by Trashing the whole quarantine. In both cases the recorded
/// stale locks are removed and re-acquired FRESH first, so no file is touched
/// unless this process holds exclusive ownership (Blocker 1). The caller must
/// obtain the user's stale-lock authorization before calling `recover`.
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

    /// Profile-open gate: a profile whose any archive hash is blocked by an
    /// abandoned staging must not be opened until recovery. Pure.
    static func isProfileBlocked(profileHashes: [String], blocked: Set<String>) -> Bool {
        !Set(profileHashes).isDisjoint(with: blocked)
    }

    enum RecoverOutcome: Equatable {
        case recovered                    // fully resolved; record removed; locks released
        case aborted(String)              // could not take exclusive ownership; record retained
        case needsManualReview(String)    // collisions/failures; record retained
    }

    /// Recover ONE abandoned staging as an authority-controlled transaction. The
    /// CALLER must have the user's authorization first (they attested no other
    /// Unison is running), because this removes and re-acquires locks. Order
    /// (Blocker 1): remove the recorded stale locks → acquire every affected
    /// archive lock FRESH → abort without touching files if any acquisition fails
    /// → only then, under our own locks, restore (pre-commit) or complete the
    /// intended removal (committed) → release our locks. The manifest is removed
    /// ONLY on full success, so a failure leaves the staging detectable and
    /// recoverable (SF2).
    static func recover(_ a: AbandonedStaging,
                        activeDir: String,
                        locking: ArchiveLocking,
                        fileManager fm: FileManager = .default) -> RecoverOutcome {
        // 1. Remove the recorded (authorized) stale locks so we can re-acquire.
        _ = removeLocks(a, activeDir: activeDir, fileManager: fm)

        // 2. Acquire exclusive ownership of every affected archive, FRESH.
        var owned: [String] = []
        func releaseOwned() { for h in owned.reversed() { _ = locking.release(hash: h) } }
        for hash in a.manifest.hashes.sorted() {
            if locking.acquire(hash: hash) == .acquired {
                owned.append(hash)
            } else {
                // 4. Abort WITHOUT touching files. Release any we grabbed; leave
                //    the manifest so this is detected and retried next time.
                releaseOwned()
                return .aborted("another Unison is using archive \(hash); recovery deferred")
            }
        }
        // 6. Release our acquired locks on exit (archive usable again).
        defer { releaseOwned() }

        // 5. Handle files under our locks, by phase.
        if a.manifest.isPreCommit {
            let r = restore(a, activeDir: activeDir, fileManager: fm)
            guard r.isComplete else {
                return .needsManualReview(
                    "\(a.quarantineDir): \(r.collided.count) already present, "
                    + "\(r.failed.count) could not be moved")
            }
            guard finalize(a, fileManager: fm) else {
                return .needsManualReview("\(a.quarantineDir): could not remove the quarantine")
            }
        } else {
            // Committed: the removal was intended and completed (family already
            // staged out); complete it by Trashing the whole quarantine.
            do {
                var out: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: a.quarantineDir), resultingItemURL: &out)
            } catch {
                return .needsManualReview("\(a.quarantineDir): could not move to Trash")
            }
        }
        return .recovered
    }
}
