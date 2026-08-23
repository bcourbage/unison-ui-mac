import Foundation

/// The single authority through which every destructive archive operation
/// (Clean Stale, Reset, delete-with-archives, fatal recovery) runs. It makes a
/// partial archive family impossible and is crash-safe.
///
/// Phase model (per the review):
/// 1. Acquire the real per-archive locks a live Unison uses, then write a
///    DURABLE staging manifest recording the plan + the locks held.
/// 2. Move every payload file with a real same-filesystem `rename(2)`.
/// 3. If any rename fails, restore every staged file and remove the manifest,
///    before releasing locks — the original family is intact.
/// 4. Once all files are staged, the removal is LOGICALLY COMMITTED: the
///    complete family is absent from Unison's active directory.
/// 5. Move the entire staging directory to Trash as ONE unit. If that cleanup
///    fails, retain the complete quarantine directory and report it — never
///    restore it after locks have been released.
///
/// Locks are released — owned ones only — on every exit path. A pre-existing or
/// foreign lock is never released. `lk` is excluded from payloads by
/// construction (it is the interprocess lock, held across the mutation).

/// Immutable set of archives to mutate, frozen before locking. `lk` excluded.
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
    static let phaseCommitted = "committed"  // post-commit: removal done, locks released

    var version: Int = StagingManifest.currentVersion
    let operation: String          // human label, e.g. "clean-stale", "reset"
    let hashes: [String]           // lk<hash> locks held by the interrupted op
    let payloadFiles: [String]     // payload basenames being staged
    let createdAtISO8601: String   // for reporting only
    /// `phaseStaging` until the logical-commit point; `phaseCommitted` once the
    /// whole family is staged (removed from the active dir) and only the Trash
    /// cleanup remains. Distinguishes a pre-commit crash (fail closed) from a
    /// post-commit retained quarantine (leftover to report, not a block).
    var phase: String = StagingManifest.phaseStaging

    var isPreCommit: Bool { phase == StagingManifest.phaseStaging }
}

/// Interprocess archive locking (injectable for tests).
protocol ArchiveLocking {
    func acquire(hash: String) -> ArchiveLock.AcquireResult
    func release(hash: String)
}

struct SystemArchiveLocking: ArchiveLocking {
    func acquire(hash: String) -> ArchiveLock.AcquireResult { ArchiveLock.acquire(hash: hash) }
    func release(hash: String) { ArchiveLock.release(hash: hash) }
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
    /// Phase 5: move the ENTIRE quarantine dir to Trash as one unit and clear
    /// state. Throws on cleanup failure, having RETAINED the complete quarantine
    /// dir (never restored).
    func commit() throws
    /// The quarantine directory path (for reporting a retained quarantine).
    var quarantinePath: String? { get }
}

enum ArchiveMutationError: Error, Equatable {
    case engineNotIdle
    case lockUnavailable(hash: String, reason: ArchiveLock.AcquireResult)
    case revalidationFailed
    case beginStagingFailed
    case stagingFailed(file: String)   // rolled back; original family intact
}

struct ArchiveMutationOutcome: Equatable {
    let hashes: [String]                 // families removed from the active dir
    /// Non-nil iff the Trash cleanup (phase 5) failed: the complete family is
    /// safe in this retained quarantine dir. The removal still succeeded; the
    /// caller must report the path.
    let quarantineRetained: String?
}

enum ArchiveMutation {

    @discardableResult
    static func execute(
        operation: String,
        plan: ArchiveMutationPlan,
        nowISO8601: String,
        isEngineIdle: () -> Bool,
        revalidate: () -> Bool,
        locking: ArchiveLocking,
        store: ArchivePayloadStore
    ) throws -> ArchiveMutationOutcome {

        guard isEngineIdle() else { throw ArchiveMutationError.engineNotIdle }

        // Release ONLY acquired locks, reverse order, on EVERY exit.
        var owned: [String] = []
        defer { for h in owned.reversed() { locking.release(hash: h) } }

        // 1. Acquire all locks in deterministic order, before any payload touch.
        for h in plan.hashes {
            let r = locking.acquire(hash: h)
            guard r == .acquired else {
                throw ArchiveMutationError.lockUnavailable(hash: h, reason: r)
            }
            owned.append(h)
        }

        // 2. Revalidate under the locks; still nothing touched.
        guard revalidate() else { throw ArchiveMutationError.revalidationFailed }

        // 1b. Durable manifest BEFORE moving any payload (crash detectable now).
        let manifest = StagingManifest(operation: operation, hashes: plan.hashes,
                                       payloadFiles: plan.payloadFiles,
                                       createdAtISO8601: nowISO8601)
        do { try store.beginStaging(manifest) }
        catch { throw ArchiveMutationError.beginStagingFailed }

        // 2. Stage every payload via rename(2) (atomic removal-or-nothing).
        do {
            for f in plan.payloadFiles { try store.stage(f) }
        } catch {
            // 3. Rollback: restore every staged file + remove the manifest.
            try? store.rollback()
            throw ArchiveMutationError.stagingFailed(file: "\(error)")
        }

        // 4. Logical commit: the whole family is absent from the active dir.
        // 5. Move the entire quarantine dir to Trash as one unit.
        do {
            try store.commit()
            return ArchiveMutationOutcome(hashes: plan.hashes, quarantineRetained: nil)
        } catch {
            // Cleanup failed: retain the complete quarantine dir, report it.
            // Do NOT restore — the removal is already committed.
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

    /// Archive hashes locked by a PRE-COMMIT abandoned mutation — profiles whose
    /// archives intersect this set must be blocked from starting until explicit
    /// recovery (the `lk` locks are still held and ownership cannot be proven).
    /// A post-commit leftover does not block (its removal completed and its locks
    /// were released). This function NEVER removes a lock.
    static func blockedHashes(_ abandoned: [AbandonedStaging]) -> Set<String> {
        Set(abandoned.filter { $0.manifest.isPreCommit }.flatMap { $0.manifest.hashes })
    }
}
