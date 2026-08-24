import Foundation

/// The single authority through which every destructive archive operation
/// (Clean Stale, Reset, delete-with-archives, fatal recovery) runs. It makes a
/// partial archive family impossible and is crash-safe.
///
/// Phase model (per the review):
/// 0. Write a DURABLE intent record (`phaseAcquiring`, hashes only) BEFORE the
///    first lock, so even a crash mid-acquisition is detectable on restart.
/// 1. Acquire the real per-archive locks a live Unison uses, derive the payload
///    plan UNDER the locks (so it captures the true family), then durably record
///    that plan (`phaseStaging`) before any move.
/// 2. Move every payload file with a real same-filesystem `rename(2)`.
/// 3. If any move fails, restore every staged file, then RELEASE the locks and
///    only afterwards remove the record — so an owned lock is never left without a
///    durable record. If a restore itself fails, the quarantine + manifest are
///    RETAINED and the locks kept held (rollbackIncomplete); if a lock cannot be
///    confirmed released, the record is retained and those hashes stay blocked
///    (lockRetainedAfterAbort). Recovery is always explicit, never automatic.
/// 4. Once all files are staged, the removal is LOGICALLY COMMITTED
///    (`phaseCommitted`): the complete family is absent from the active directory.
/// 5. Confirm each owned lock is released BEFORE Trashing. Move the entire
///    staging directory to Trash as ONE unit. If cleanup fails, retain the
///    complete quarantine directory and report it — never restore after commit.
///
/// The record is removed ONLY after every owned lock is confirmed released, on
/// every exit path. Owned locks are released on success and on ordinary abort;
/// an INCOMPLETE rollback keeps them held on purpose (the archive stays blocked
/// until explicit recovery). A pre-existing or foreign lock is never released.
/// `lk` is excluded from payloads by construction (it is the interprocess lock,
/// held across the mutation).

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
    static let phaseAcquiring = "acquiring"  // intent recorded, locks being acquired
    static let phaseStaging = "staging"      // pre-commit: locks held, payloads moving
    static let phaseCommitted = "committed"  // post-commit: removal done; release may still be pending
    static let phaseAborted = "aborted"      // rolled back: family restored + locks released;
                                             // only a lock-free quarantine folder remains

    var version: Int = StagingManifest.currentVersion
    let operation: String          // human label, e.g. "clean-stale", "reset"
    let hashes: [String]           // lk<hash> locks held by the interrupted op
    let payloadFiles: [String]     // payload basenames being staged
    let createdAtISO8601: String   // for reporting only
    /// The lifecycle of the record. `phaseAcquiring` is written BEFORE the first
    /// lock is taken, so a crash mid-acquisition is still detectable on restart
    /// (SF1). `phaseStaging` once the under-lock payload plan is recorded and the
    /// moves begin (pre-commit: the family may be split → fail closed). `phaseCommitted`
    /// once the whole family is staged out. `markCommitted()` intentionally PRECEDES
    /// lock release, so a committed record may still have a surviving lock: either
    /// the locks are released and only Trash cleanup remains, or a release could not
    /// be confirmed and the record is retained as a BLOCK. An acquiring or committed
    /// record blocks iff its `lk<hash>` is still present; a staging record always
    /// blocks (its family may be split).
    var phase: String = StagingManifest.phaseAcquiring

    /// A staging (pre-commit) record — its family may be split, so restore, not trash.
    var isPreCommit: Bool { phase == StagingManifest.phaseStaging }
    /// An intent record: locks were being acquired but no payload was moved.
    var isAcquiring: Bool { phase == StagingManifest.phaseAcquiring }

    static let knownPhases: Set<String> =
        [phaseAcquiring, phaseStaging, phaseCommitted, phaseAborted]

    /// A record this build fully understands. A FUTURE version (written by a newer
    /// app) or an unrecognized phase must be treated as fail-closed manual review —
    /// its quarantine may hold payload requiring restoration that this build cannot
    /// reason about, so it is never restored or Trashed automatically (SF3).
    var isRecognized: Bool {
        version >= 1 && version <= StagingManifest.currentVersion
            && StagingManifest.knownPhases.contains(phase)
    }
}

extension StagingManifest {
    /// True for the terminal states that block ONLY when a lock survives on disk
    /// (acquiring: nothing moved; committed: removal done; aborted: family
    /// restored + locks released — only a lock-free folder remains). A staging
    /// record is deliberately excluded: its family may be split, so it always
    /// blocks regardless of the lock.
    var blocksOnlyIfLocked: Bool { !isPreCommit }
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
    /// Phase 0: create the quarantine dir and write the durable INTENT manifest
    /// (`phaseAcquiring`, no payloads) BEFORE any lock is acquired, so a crash
    /// mid-acquisition is detectable on restart (SF1).
    func beginIntent(_ manifest: StagingManifest) throws
    /// Phase 1: durably rewrite the manifest with the under-lock payload plan and
    /// flip it to `phaseStaging`, BEFORE the first payload move.
    func recordPlan(_ manifest: StagingManifest) throws
    /// Phase 2: `rename(2)` one payload basename from the active dir into the
    /// quarantine dir.
    func stage(_ name: String) throws
    /// Phase 3: restore every staged file to the active dir. Does NOT remove the
    /// record (removal is gated on confirmed lock release — see `discardRecord`).
    /// Throws if any restore fails, retaining the quarantine.
    func rollback() throws
    /// Remove the quarantine dir + manifest. Call ONLY after every owned lock has
    /// been confirmed released AND the payloads are restored/absent — so no owned
    /// lock is ever left without a durable record (SF1). THROWS if the removal
    /// fails, retaining the in-memory path/state (never reports false success);
    /// implementations must first make any leftover non-blocking.
    func discardRecord() throws
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
    /// An early exit (abort) released the family but could NOT confirm every
    /// lock this app acquired was released. The intent record is RETAINED and
    /// those hashes stay blocked; the caller must refresh the in-session block
    /// (SF2). Nothing was changed on disk beyond the surviving lock.
    case lockRetainedAfterAbort(hashes: [String], quarantine: String)
    /// An abort released every lock and left the family intact, but the quarantine
    /// record could not be removed. It is a lock-free leftover folder (safe to
    /// delete), NOT a block (SF1). Only thrown when no lock — app-owned OR foreign
    /// — remains; a foreign lock preserves the `lockUnavailable` primary instead.
    case abortedCleanupIncomplete(quarantine: String)

    /// True when this failure left (or left in place) a lock that blocks the
    /// affected profiles, so the caller must refresh `blockedArchiveHashes` to gate
    /// the profile in-session (not only after restart):
    ///  - `rollbackIncomplete`: staging record retained, app locks kept HELD.
    ///  - `lockRetainedAfterAbort`: app lock could not be confirmed released.
    ///  - `lockUnavailable`: `.alreadyHeld` proves a foreign lock (blocks); the
    ///    other reasons (exception/invalidHash/bridgeMissing) leave the lock state
    ///    UNKNOWN — refresh conservatively rather than assuming unlocked. Only a
    ///    result that proves the lock ABSENT would skip the refresh.
    var requiresArchiveBlockRefresh: Bool {
        switch self {
        case .rollbackIncomplete, .lockRetainedAfterAbort: return true
        case .lockUnavailable(_, let reason): return reason.lockEvidence != .absent
        default: return false
        }
    }
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
        var owned: [String] = []

        // How releasing the owned locks + settling the record turned out on an
        // abort path. `.discarded` — every lock released, record removed.
        // `.lockFree(q)` — every lock released but the record could not be removed
        // (non-blocking leftover, SF1). `.locked(hashes,q)` — a lock could not be
        // confirmed released; record RETAINED and those hashes stay blocked (SF2).
        enum Settled { case discarded; case lockFree(String); case locked([String], String) }
        func releaseOwnedAndSettleRecord() -> Settled {
            var unreleased: [String] = []
            for h in owned.reversed() where !locking.release(hash: h) { unreleased.append(h) }
            owned.removeAll()
            if !unreleased.isEmpty {
                return .locked(unreleased.sorted(), store.quarantinePath ?? "?")
            }
            do { try store.discardRecord(); return .discarded }
            catch { return .lockFree(store.quarantinePath ?? "?") }
        }
        // Translate a settle result into the thrown error for an abort, defaulting
        // to `primary` when the record was cleanly discarded.
        func throwSettled(primary: ArchiveMutationError) throws -> Never {
            switch releaseOwnedAndSettleRecord() {
            case .discarded:
                throw primary
            case .lockFree(let q):
                // Every APP-owned lock was released, but the record could not be
                // removed. Any `lockUnavailable` primary keeps precedence: whether
                // a foreign lock is proven (`.alreadyHeld`) or the lock state is
                // UNKNOWN (exception/bridge/invalidHash), we must NOT claim the
                // archive is unlocked — the acquisition failure is the truthful
                // headline and the retained record is recovered on restart (SF2).
                // Only a genuinely lock-free abort (revalidation/staging failure,
                // which released every acquired lock) reports the leftover folder.
                if case .lockUnavailable = primary { throw primary }
                throw ArchiveMutationError.abortedCleanupIncomplete(quarantine: q)
            case .locked(let hs, let q):
                throw ArchiveMutationError.lockRetainedAfterAbort(hashes: hs, quarantine: q)
            }
        }

        // 0. Durable INTENT record BEFORE any lock (SF1): a crash between the first
        //    acquire and the payload plan is now detectable on restart.
        let intent = StagingManifest(operation: operation, hashes: sortedHashes,
                                     payloadFiles: [], createdAtISO8601: nowISO8601,
                                     phase: StagingManifest.phaseAcquiring)
        do { try store.beginIntent(intent) }
        catch { throw ArchiveMutationError.beginStagingFailed }

        // 1. Acquire all locks in deterministic order, before any payload touch.
        for h in sortedHashes {
            let r = locking.acquire(hash: h)
            guard r == .acquired else {
                try throwSettled(primary: .lockUnavailable(hash: h, reason: r))
            }
            owned.append(h)
        }

        // 2. Derive + freeze the exact payload set UNDER the locks (Blocker 2).
        let plan = ArchiveMutationPlan(hashes: sortedHashes, fileExists: fileExists)

        // 3. Revalidate the under-lock plan; still nothing touched.
        guard revalidate(plan) else {
            try throwSettled(primary: .revalidationFailed)
        }

        // 3b. Record the under-lock payload plan (flip acquiring → staging) BEFORE
        //     moving any payload — the pre-commit crash window is now covered.
        let staging = StagingManifest(operation: operation, hashes: plan.hashes,
                                      payloadFiles: plan.payloadFiles,
                                      createdAtISO8601: nowISO8601,
                                      phase: StagingManifest.phaseStaging)
        do { try store.recordPlan(staging) }
        catch { try throwSettled(primary: .beginStagingFailed) }

        // 4. Stage every payload via rename(2) (atomic removal-or-nothing).
        do {
            for f in plan.payloadFiles { try store.stage(f) }
        } catch {
            // Rollback restores every staged file (does NOT remove the record).
            // If restoration is INCOMPLETE, keep the locks HELD and the record —
            // the family is split until explicit recovery.
            do { try store.rollback() }
            catch { throw ArchiveMutationError.rollbackIncomplete(quarantine: store.quarantinePath ?? "?") }
            // Family restored. Release + settle the record BEFORE returning, so a
            // surviving lock never outlives its record.
            try throwSettled(primary: .stagingFailed(file: "\(error)"))
        }

        // 5. Logical commit: durably mark the manifest committed. If even marking
        //    fails, roll back with the same discipline.
        do { try store.markCommitted() }
        catch {
            do { try store.rollback() }
            catch { throw ArchiveMutationError.rollbackIncomplete(quarantine: store.quarantinePath ?? "?") }
            try throwSettled(primary: .stagingFailed(file: "markCommitted: \(error)"))
        }

        // 6. Release every owned lock and CONFIRM it is gone, BEFORE Trashing —
        //    so a committed record is never retired while a lock might survive.
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

        // 7. All locks released — now it is safe to Trash the quarantine. A Trash
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
    /// recovery. Cases:
    ///  - UNRECOGNIZED (future version or unknown phase): fail closed — always
    ///    block; this build can't reason about the record (SF3).
    ///  - PRE-COMMIT staging: the family may be split and the lock is held →
    ///    always block.
    ///  - ACQUIRING / COMMITTED / ABORTED whose `lk<hash>` still EXISTS on disk:
    ///    no family is split, but a lock survived → block until it is resolved.
    ///    Such a record whose lock is already gone does not block (orphan folder).
    /// This function NEVER removes a lock.
    static func blockedHashes(_ abandoned: [AbandonedStaging],
                              unisonDir: String,
                              fileManager fm: FileManager = .default) -> Set<String> {
        var blocked = Set<String>()
        for a in abandoned {
            for h in a.manifest.hashes {
                if !a.manifest.isRecognized {
                    blocked.insert(h)   // unknown version/phase → fail closed (SF3)
                } else if !a.manifest.blocksOnlyIfLocked {
                    blocked.insert(h)   // staging: family may be split → always block
                } else if fm.fileExists(
                    atPath: (unisonDir as NSString).appendingPathComponent("lk" + h)) {
                    blocked.insert(h)   // acquiring/committed/aborted: block iff lock survives
                }
            }
        }
        return blocked
    }
}
