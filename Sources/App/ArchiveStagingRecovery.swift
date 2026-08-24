import Foundation

/// Explicit recovery for an abandoned staging (an interrupted archive mutation,
/// detected by `AbandonedStagingScan`). `recover(_:activeDir:locking:)` is the
/// authoritative entry point; `finalize` and `isProfileBlocked` are helpers.
///
/// The exclusion barrier is NEVER dropped and re-taken. An abandoned mutation
/// leaves an `lk<hash>` file that already excludes every other Unison; recovery
/// RETAINS that file as its barrier for the whole operation (Blocker 1 — deleting
/// it first, even under user authorization, opens a window for a CLI/cron/incoming
/// Unison to grab the freed lock and operate on the still-split family). Only a
/// hash whose lock is somehow absent is acquired FRESH — atomically, before any
/// file is touched. The two kinds are tracked so the final step is correct:
/// an existing (authorized) lock is unlinked, a freshly-acquired one is released.
///
/// Recovery direction depends on phase. Only a STAGING (pre-commit) record holds
/// staged payload: the quarantine has the only copy of some files, so the safe
/// direction is to RESTORE them into the active directory — after a full preflight
/// (nothing moves unless every file can be restored) with rollback if a move still
/// fails. Every OTHER record — COMMITTED (removal finished, family already staged
/// out), ACQUIRING (locks were being taken, nothing moved), and ABORTED (rolled
/// back, family already restored) — carries NO staged payload, so recovery takes
/// the cleanup branch: release the lock and retire the intent/leftover folder,
/// restoring nothing. In BOTH branches locks are released only after the file
/// operation (or the no-op) succeeds and every release is confirmed, and the
/// record is retired only then (mirrors `ArchiveMutation.execute`, SF2). Any
/// unsuccessful recovery leaves every affected family PHYSICALLY LOCKED and the
/// record intact.
/// The caller must obtain the user's stale-lock authorization before calling.
enum ArchiveStagingRecovery {

    /// After a COMPLETE restore (no payload files remain) remove the quarantine
    /// directory + manifest. Returns whether it was removed. Refuses if any
    /// payload file still remains (an incomplete restore — keep for review).
    @discardableResult
    static func finalize(_ abandoned: AbandonedStaging,
                         fileManager fm: FileManager = .default) -> Bool {
        let remaining = abandoned.manifest.payloadFiles.filter {
            fm.fileExists(atPath: (abandoned.quarantineDir as NSString).appendingPathComponent($0))
        }
        guard remaining.isEmpty else { return false }
        do { try fm.removeItem(atPath: abandoned.quarantineDir); return true }
        catch { return false }
    }

    /// Profile-open gate: a profile whose any archive hash is blocked by an
    /// abandoned staging must not be opened until recovery. Pure.
    static func isProfileBlocked(profileHashes: [String], blocked: Set<String>) -> Bool {
        !Set(profileHashes).isDisjoint(with: blocked)
    }

    enum RecoverOutcome: Equatable {
        case recovered                    // fully resolved; record retired; locks released
        case aborted(String)              // a lock couldn't be secured; nothing touched; all locked
        case needsManualReview(String)    // collision/move/release issue; record retained; STILL LOCKED
        case cleanupOnly(String)          // file op done AND all locks released; only quarantine
                                          // cleanup failed → NOT blocking, safe to delete by hand
    }

    /// How this recovery came to hold each hash's lock — decides the final step.
    private enum Barrier { case existing, fresh }

    /// Recover ONE abandoned staging as an authority-controlled transaction. The
    /// CALLER must have obtained the user's authorization first (they attested no
    /// other Unison is running). See the type doc for the ordering rationale.
    static func recover(_ a: AbandonedStaging,
                        activeDir: String,
                        locking: ArchiveLocking,
                        fileManager fm: FileManager = .default) -> RecoverOutcome {
        let hashes = a.manifest.hashes.sorted()
        func lkPath(_ h: String) -> String {
            (activeDir as NSString).appendingPathComponent("lk" + h)
        }

        // 1. Secure EVERY affected archive without ever unlinking an existing
        //    barrier. Retain a recorded lock as-is; acquire a missing one FRESH
        //    (atomic). If any hash cannot be secured, abort WITHOUT touching files
        //    and WITHOUT releasing anything — every family stays physically locked.
        var barrier: [String: Barrier] = [:]
        for h in hashes {
            if fm.fileExists(atPath: lkPath(h)) {
                barrier[h] = .existing
            } else if locking.acquire(hash: h) == .acquired {
                barrier[h] = .fresh
            } else {
                return .aborted("another Unison holds archive \(h); recovery deferred — "
                    + "all affected archives remain locked")
            }
        }

        // 2. The file operation, under the held locks.
        if a.manifest.isPreCommit {
            let payloads = a.manifest.payloadFiles.sorted().filter {
                fm.fileExists(atPath: (a.quarantineDir as NSString).appendingPathComponent($0))
            }
            // 2a. Preflight: nothing moves unless EVERY payload can be restored.
            let collisions = payloads.filter {
                fm.fileExists(atPath: (activeDir as NSString).appendingPathComponent($0))
            }
            guard collisions.isEmpty else {
                return .needsManualReview("\(a.quarantineDir): \(collisions.count) file(s) "
                    + "already present in the active directory; nothing moved, archives remain locked")
            }
            // 2b. Move every payload; on any failure, roll back what we restored.
            var restored: [String] = []
            for name in payloads {
                let src = (a.quarantineDir as NSString).appendingPathComponent(name)
                let dst = (activeDir as NSString).appendingPathComponent(name)
                do { try fm.moveItem(atPath: src, toPath: dst); restored.append(name) }
                catch {
                    var rollbackComplete = true
                    for n in restored.reversed() {
                        let rsrc = (activeDir as NSString).appendingPathComponent(n)
                        let rdst = (a.quarantineDir as NSString).appendingPathComponent(n)
                        if (try? fm.moveItem(atPath: rsrc, toPath: rdst)) == nil { rollbackComplete = false }
                    }
                    return .needsManualReview("\(a.quarantineDir): a file could not be restored; "
                        + (rollbackComplete ? "rolled back" : "rollback INCOMPLETE") + ", archives remain locked")
                }
            }
            // 2c. Full restore done. Confirm releases BEFORE retiring the manifest.
            let unreleased = releaseAll(hashes: hashes, barrier: barrier,
                                        activeDir: activeDir, locking: locking, fm: fm)
            guard unreleased.isEmpty else {
                return .needsManualReview("\(a.quarantineDir): restored, but \(unreleased.count) "
                    + "lock(s) could not be released; record retained and archives remain locked")
            }
            guard finalize(a, fileManager: fm) else {
                // Files are restored and every lock is released — the archives are
                // usable. Only the empty quarantine could not be removed: a benign
                // leftover, NOT a block (SF2).
                return .cleanupOnly("\(a.quarantineDir): restored and unlocked, but the empty "
                    + "quarantine folder could not be removed; delete it manually")
            }
            return .recovered
        } else {
            // Cleanup branch for every non-staging record — committed (removal
            // finished), acquiring (nothing moved), or aborted (already restored).
            // None carries staged payload, so there is nothing to restore: confirm
            // the lock releases first (mirror ArchiveMutation.execute), then retire
            // the intent/leftover folder by Trashing it.
            let unreleased = releaseAll(hashes: hashes, barrier: barrier,
                                        activeDir: activeDir, locking: locking, fm: fm)
            guard unreleased.isEmpty else {
                return .needsManualReview("\(a.quarantineDir): \(unreleased.count) lock(s) could "
                    + "not be released; record retained and archives remain locked")
            }
            do {
                var out: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: a.quarantineDir), resultingItemURL: &out)
            } catch {
                // Every lock is released and the removal is committed — the folder
                // is a lock-free leftover, NOT a block (SF2).
                return .cleanupOnly("\(a.quarantineDir): unlocked, but the quarantine could not be "
                    + "moved to Trash; delete it manually")
            }
            return .recovered
        }
    }

    /// Release/remove every established lock and CONFIRM each is gone. An existing
    /// (authorized) barrier is unlinked; a freshly-acquired one goes through
    /// `locking.release`. Returns, sorted, the hashes whose lock could NOT be
    /// confirmed gone — the caller must then retain the record and stay blocked.
    private static func releaseAll(hashes: [String],
                                   barrier: [String: Barrier],
                                   activeDir: String,
                                   locking: ArchiveLocking,
                                   fm: FileManager) -> [String] {
        var unreleased: [String] = []
        for h in hashes.reversed() {
            switch barrier[h] {
            case .existing:
                let lk = (activeDir as NSString).appendingPathComponent("lk" + h)
                try? fm.removeItem(atPath: lk)
                if fm.fileExists(atPath: lk) { unreleased.append(h) }
            case .fresh:
                if !locking.release(hash: h) { unreleased.append(h) }
            case .none:
                break
            }
        }
        return unreleased.sorted()
    }
}
