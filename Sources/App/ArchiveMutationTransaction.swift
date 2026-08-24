import Foundation

/// The single authority through which every destructive archive operation
/// (Clean Stale, Reset, delete-with-archives, fatal recovery) runs. It makes a
/// partial archive family impossible and is crash-safe.
///
/// Phase model (per the review):
/// 1. Acquire the real per-archive locks a live Unison uses, then write a
///    DURABLE staging manifest recording the plan + the locks held. The payload
///    plan is derived AFTER the locks are held, so it captures the true family.
/// 2. Move every payload file with a real same-filesystem `rename(2)`.
/// 3. If any rename fails, restore every staged file and remove the manifest,
///    then release locks — the original family is intact. If a restore itself
///    fails, the quarantine + manifest are RETAINED and the locks are kept held
///    (rollbackIncomplete); recovery is explicit, never automatic.
/// 4. Once all files are staged, the removal is LOGICALLY COMMITTED: the
///    complete family is absent from Unison's active directory.
/// 5. Confirm each owned lock is released BEFORE Trashing. Move the entire
///    staging directory to Trash as ONE unit. If cleanup fails, retain the
///    complete quarantine directory and report it — never restore after commit.
///
/// Owned locks are released on success and on ordinary rollback; an INCOMPLETE
/// rollback keeps them held on purpose (the archive stays blocked until explicit
/// recovery). A pre-existing or foreign lock is never released. `lk` is excluded
/// from payloads by construction (it is the interprocess lock, held across the
/// mutation).

/// Immutable set of archives to mutate. Payload files are derived under the held
/// locks (see `ArchiveMaintenance`), so the set reflects the family as it exists
/// once no other process can change it. `lk` is excluded.
struct ArchiveMutationPlan: Equatable {
    let hashes: [String]        // 32-char lowercase-hex, deterministically ordered
    let payloadFiles: [String]  // ar/fp/sc/tm<hash> that exist; never lk; ordered

    static let payloadPrefixes = ["ar", "fp", "sc", "tm"]

    init(hashes: [String], fileExists: (String) -> Bool) {
        let sorted = hashes.sorted()
        self.hashes = sorted
        var files: [String] = []
        for h in sorted {
            for p in ArchiveMutationPlan.payloadPrefixes {   // already sorted
                let name = p + h
                if fileExists(name) { files.append(name) }
            }
        }
        self.payloadFiles = files
    }

    init(hashes: [String], payloadFiles: [String]) {
        self.hashes = hashes
        self.payloadFiles = payloadFiles
    }
}

/// Durable record written before any payload is moved, so an interrupted
/// mutation is detectable on restart. It deliberately records NO claim that
/// could authorize automatic lock deletion — ownership of the raw upstream
/// `lk` files (which carry no owner metadata) cannot be proven across a crash,
/// so an abandoned manifest requires explicit recovery, never silent cleanup.
struct StagingManifest: Codable, Equatable {
    static let currentVersion = 1
    static let phaseStaging = "staging"      // pre-commit: locks held, fail closed
    static let phaseCommitted = "committed"  // post-commit: removal done; release may still be pending

    var version: Int = StagingManifest.currentVersion
    let operation: String          // human label, e.g. "clean-stale", "reset"
    let hashes: [String]           // lk<hash> locks held by the interrupted op
    let payloadFiles: [String]     // payload basenames being staged
    let createdAtISO8601: String   // for reporting only
    /// `phaseStaging` until the logical-commit point; `phaseCommitted` once the
    /// whole family is staged (removed from the active dir). `markCommitted()`
    /// intentionally PRECEDES lock release, so a committed record may still have a
    /// surviving lock: after commit, either the locks are released and only the
    /// Trash cleanup remains, or a release could not be confirmed and the record
    /// is retained as a BLOCK until explicit recovery. A committed leftover thus
    /// blocks iff its `lk<hash>` is still present.
    var phase: String = StagingManifest.phaseStaging

    var isPreCommit: Bool { phase == StagingManifest.phaseStaging }
}

/// Interprocess archive locking (injectable for tests).
protocol ArchiveLocking {
    func acquire(hash: String) -> ArchiveLock.AcquireResult
    /// Release the lock and CONFIRM it is gone. Returns false if a lock for this
    /// hash still exists afterward (the release failed, or another process
    /// re-acquired) — the caller must then treat it as NOT safely released and
    /// retain a blocking recovery record.
    @discardableResult func release(hash: String) -> Bool
}

struct SystemArchiveLocking: ArchiveLocking {
    func acquire(hash: String) -> ArchiveLock.AcquireResult { ArchiveLock.acquire(hash: hash) }
    @discardableResult func release(hash: String) -> Bool {
        ArchiveLock.release(hash: hash)
        return ArchiveLock.isLocked(hash: hash) == .unlocked
    }
}

/// Staging-based payload store (injectable for tests). Implements the phase
/// model above; `commit` moves the WHOLE quarantine directory as one unit.
protocol ArchivePayloadStore {
    /// Phase 1: create the quarantine dir and write the durable manifest.
    func beginStaging(_ manifest: StagingManifest) throws
    /// Phase 2: `rename(2)` one payload basename from the active dir into the
    /// quarantine dir.
    func stage(_ name: String) throws
    /// Phase 3: restore every staged file to the active dir and remove the
    /// quarantine dir + manifest. Called only on a staging failure.
    func rollback() throws
    /// Phase 4: durably mark the manifest committed (the whole family is now
    /// staged out of the active dir). The logical commit point.
    func markCommitted() throws
    /// Phase 6: move the ENTIRE quarantine dir to Trash as one unit and clear
    /// state. Throws on cleanup failure, RETAINING the complete quarantine dir.
    /// Call ONLY after every owned lock has been confirmed released.
    func trashQuarantine() throws
    /// The quarantine directory path (for reporting a retained quarantine).
    var quarantinePath: String? { get }
}

enum ArchiveMutationError: Error, Equatable {
    case engineNotIdle
    case lockUnavailable(hash: String, reason: ArchiveLock.AcquireResult)
    case revalidationFailed
    case beginStagingFailed
    case stagingFailed(file: String)   // rolled back; original family intact
    /// A stage failed AND restoring an already-staged file also failed. The
    /// quarantine + manifest are RETAINED and the locks are kept HELD (Unison
    /// stays blocked) — nothing is deleted, but the family is split until an
    /// explicit recovery. The most serious outcome; surface loudly.
    case rollbackIncomplete(quarantine: String)
}

struct ArchiveMutationOutcome: Equatable {
    let hashes: [String]                 // families removed from the active dir
    /// Non-nil iff the quarantine was retained rather than Trashed — either the
    /// Trash cleanup failed (locks already released → non-blocking leftover), or
    /// a lock could not be confirmed released (see `locksNotReleased` → blocking).
    let quarantineRetained: String?
    /// Hashes whose lock could NOT be confirmed released after the commit. The
    /// committed-manifest quarantine is retained and these profiles stay blocked
    /// (lock present) until explicit recovery. Empty on the normal path.
    var locksNotReleased: [String] = []

    /// The two retained states are NOT the same and must be surfaced differently.
    enum Disposition: Equatable {
        /// Quarantine Trashed, locks released — nothing left to do.
        case clean
        /// Committed, lock-free leftover: Trash cleanup failed but every lock was
        /// released. Safe to delete manually; does NOT block any profile.
        case lockFreeLeftover(quarantine: String)
        /// Committed record RETAINED because a lock could not be confirmed
        /// released. These hashes stay blocked; the record is the only recovery
        /// handle and must NOT be deleted; fatal recovery must not retry.
        case blockedByLock(quarantine: String, hashes: [String])
    }

    var disposition: Disposition {
        guard let q = quarantineRetained else { return .clean }
        return locksNotReleased.isEmpty
            ? .lockFreeLeftover(quarantine: q)
            : .blockedByLock(quarantine: q, hashes: locksNotReleased)
    }

    /// Body text for a lock-free leftover: the removal succeeded and no lock
    /// remains, so the folder is safe to delete by hand whenever convenient.
    static func lockFreeLeftoverBody(_ q: String) -> String {
        "The archives were removed from Unison's active directory and no lock remains. "
        + "Moving the leftover quarantine folder to the Trash failed, but the files are "
        + "safe here — delete this folder manually when convenient:\n\n\(q)"
    }

    /// Body text for a retained, still-locked record: it is the only recovery
    /// handle, so the user must NOT delete it; recovery happens on next launch.
    static func blockedByLockBody(_ q: String) -> String {
        "The archives were removed, but a lock could not be released, so the affected "
        + "profile(s) stay blocked until recovery. Do NOT delete this folder — it is the "
        + "record needed to recover safely. Quit and reopen the app to recover:\n\n\(q)"
    }
}

enum ArchiveMutation {

    /// Execute a mutation over `hashes`. The payload set is derived UNDER the
    /// acquired locks (Blocker 2): the caller passes only the hashes and a
    /// `fileExists` probe, and the exact ar/fp/tm/sc family is frozen only after
    /// every lock is held, so an external Unison that added a sibling between the
    /// caller's review and lock acquisition cannot cause a partial-family move.
    /// `revalidate` receives that under-lock plan and can refuse (e.g. Clean
    /// Stale refuses if the family differs from what the user reviewed).
    @discardableResult
    static func execute(
        operation: String,
        hashes: [String],
        nowISO8601: String,
        isEngineIdle: () -> Bool,
        fileExists: (String) -> Bool,
        revalidate: (ArchiveMutationPlan) -> Bool,
        locking: ArchiveLocking,
        store: ArchivePayloadStore
    ) throws -> ArchiveMutationOutcome {

        guard isEngineIdle() else { throw ArchiveMutationError.engineNotIdle }

        let sortedHashes = hashes.sorted()

        // Release ONLY acquired locks, reverse order, on EVERY exit.
        var owned: [String] = []
        // Release owned locks on exit — EXCEPT when an incomplete rollback left
        // the family split: then the locks stay HELD so Unison remains blocked
        // until an explicit recovery.
        var releaseLocks = true
        defer { if releaseLocks { for h in owned.reversed() { locking.release(hash: h) } } }

        // 1. Acquire all locks in deterministic order, before any payload touch.
        for h in sortedHashes {
            let r = locking.acquire(hash: h)
            guard r == .acquired else {
                throw ArchiveMutationError.lockUnavailable(hash: h, reason: r)
            }
            owned.append(h)
        }

        // 2. Derive + freeze the exact payload set UNDER the locks (Blocker 2).
        let plan = ArchiveMutationPlan(hashes: sortedHashes, fileExists: fileExists)

        // 3. Revalidate the under-lock plan; still nothing touched.
        guard revalidate(plan) else { throw ArchiveMutationError.revalidationFailed }

        // 3b. Durable manifest BEFORE moving any payload (crash detectable now).
        let manifest = StagingManifest(operation: operation, hashes: plan.hashes,
                                       payloadFiles: plan.payloadFiles,
                                       createdAtISO8601: nowISO8601)
        do { try store.beginStaging(manifest) }
        catch { throw ArchiveMutationError.beginStagingFailed }

        // 2. Stage every payload via rename(2) (atomic removal-or-nothing).
        do {
            for f in plan.payloadFiles { try store.stage(f) }
        } catch {
            // 3. Rollback: restore every staged file + remove the manifest. If
            //    restoration is INCOMPLETE, the store retains the quarantine +
            //    manifest and throws — we keep the locks held (Unison stays
            //    blocked) and surface the most serious error.
            do {
                try store.rollback()
            } catch {
                releaseLocks = false
                throw ArchiveMutationError.rollbackIncomplete(quarantine: store.quarantinePath ?? "?")
            }
            throw ArchiveMutationError.stagingFailed(file: "\(error)")
        }

        // 4. Logical commit: durably mark the manifest committed (family absent
        //    from the active dir). If even marking fails, roll back.
        do { try store.markCommitted() }
        catch {
            do { try store.rollback() }
            catch {
                releaseLocks = false
                throw ArchiveMutationError.rollbackIncomplete(quarantine: store.quarantinePath ?? "?")
            }
            throw ArchiveMutationError.stagingFailed(file: "markCommitted: \(error)")
        }

        // 5. Release every owned lock and CONFIRM it is gone, BEFORE Trashing —
        //    so a committed record is never retired while a lock might survive.
        //    We handle release here (not via defer) to observe status.
        releaseLocks = false
        var unreleased: [String] = []
        for h in owned.reversed() where !locking.release(hash: h) { unreleased.append(h) }
        owned.removeAll()

        guard unreleased.isEmpty else {
            // A lock could not be confirmed released. RETAIN the committed
            // quarantine (still detectable) — those hashes stay blocked (lock
            // present) until explicit recovery. Never Trash in this state.
            return ArchiveMutationOutcome(hashes: plan.hashes,
                                          quarantineRetained: store.quarantinePath,
                                          locksNotReleased: unreleased.sorted())
        }

        // 6. All locks released — now it is safe to Trash the quarantine. A Trash
        //    failure leaves a committed-manifest, lock-free leftover (recoverable,
        //    non-blocking).
        do {
            try store.trashQuarantine()
            return ArchiveMutationOutcome(hashes: plan.hashes, quarantineRetained: nil)
        } catch {
            return ArchiveMutationOutcome(hashes: plan.hashes,
                                          quarantineRetained: store.quarantinePath)
        }
    }
}

/// A pre-commit staging directory left by an interrupted mutation.
struct AbandonedStaging: Equatable {
    let quarantineDir: String
    let manifest: StagingManifest
}

/// Restart-time detection of interrupted mutations. Presence of any abandoned
/// staging means FAIL CLOSED: the affected profiles must not be started and the
/// recorded `lk` locks must NOT be auto-removed (ownership of the raw locks
/// cannot be proven across a crash). Recovery is an explicit user action.
enum AbandonedStagingScan {
    /// Prefix for per-operation quarantine directories inside the unison dir.
    static let quarantinePrefix = ".unison-mac-staging-"
    static let manifestName = "staging-manifest.json"

    /// Find abandoned staging dirs (each carrying a manifest) in `unisonDir`.
    /// Never deletes anything.
    static func find(inUnisonDir unisonDir: String,
                     fileManager fm: FileManager = .default) -> [AbandonedStaging] {
        guard let entries = try? fm.contentsOfDirectory(atPath: unisonDir) else { return [] }
        var found: [AbandonedStaging] = []
        for name in entries.sorted() where name.hasPrefix(quarantinePrefix) {
            let dir = (unisonDir as NSString).appendingPathComponent(name)
            let manifestPath = (dir as NSString).appendingPathComponent(manifestName)
            guard let data = fm.contents(atPath: manifestPath),
                  let manifest = try? JSONDecoder().decode(StagingManifest.self, from: data)
            else { continue }
            found.append(AbandonedStaging(quarantineDir: dir, manifest: manifest))
        }
        return found
    }

    /// Archive hashes that must block their profiles from opening until explicit
    /// recovery. Two cases:
    ///  - PRE-COMMIT staging: the family is split and the lock is held → always
    ///    block.
    ///  - COMMITTED staging whose `lk<hash>` still EXISTS on disk: the family was
    ///    removed but a lock survived (release failed, or was never confirmed) →
    ///    block until the lock is resolved. A committed leftover whose lock is
    ///    already gone does not block (just orphan files to clean up).
    /// This function NEVER removes a lock.
    static func blockedHashes(_ abandoned: [AbandonedStaging],
                              unisonDir: String,
                              fileManager fm: FileManager = .default) -> Set<String> {
        var blocked = Set<String>()
        for a in abandoned {
            for h in a.manifest.hashes {
                if a.manifest.isPreCommit {
                    blocked.insert(h)
                } else if fm.fileExists(
                    atPath: (unisonDir as NSString).appendingPathComponent("lk" + h)) {
                    blocked.insert(h)
                }
            }
        }
        return blocked
    }
}
