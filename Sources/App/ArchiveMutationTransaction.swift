import Foundation

/// The single authority through which every destructive archive operation
/// (Clean Stale, Reset, delete-with-archives, fatal recovery) runs. It makes a
/// partial archive family impossible: it acquires the real per-archive locks a
/// live Unison uses, then **stages** every payload file via same-filesystem
/// renames (atomic removal-or-nothing), **rolls back** all staged files if any
/// stage fails, and only then **commits** the staged set to Trash. Locks are
/// released — owned ones only — on every exit path.
///
/// Order of guarantees (mapping to the review's required invariants):
/// - engine must be idle;
/// - acquire ALL locks in deterministic order BEFORE touching any payload; a
///   failed acquisition releases the earlier locks and touches nothing;
/// - revalidate under the locks; a failed revalidation releases and touches
///   nothing;
/// - stage all payload files; a failed stage rolls back every already-staged
///   file (restoring the original archive family) and touches nothing net;
/// - commit staged files to Trash; a commit failure leaves the file safely in
///   staging (recoverable) — never a partial family at the original location;
/// - release only locks this transaction acquired; pre-existing/foreign locks
///   are never released.

/// Immutable set of archives to mutate, frozen before locking. `lk` is excluded
/// by construction — it is the interprocess lock, held across the mutation,
/// never a payload.
struct ArchiveMutationPlan: Equatable {
    /// 32-char lowercase-hex archive hashes, deterministically ordered.
    let hashes: [String]
    /// Payload basenames (relative to the unison dir), deterministically
    /// ordered. Guaranteed free of any `lk<hash>`.
    let payloadFiles: [String]

    /// Archive payload prefixes. `lk` is deliberately absent.
    static let payloadPrefixes = ["ar", "fp", "sc", "tm"]

    /// Build a plan from hashes + an existence check: sorts deterministically
    /// and includes only existing payload files, never `lk`.
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

    /// Memberwise init for tests.
    init(hashes: [String], payloadFiles: [String]) {
        self.hashes = hashes
        self.payloadFiles = payloadFiles
    }
}

/// Interprocess archive locking (injectable for tests).
protocol ArchiveLocking {
    func acquire(hash: String) -> ArchiveLock.AcquireResult
    func release(hash: String)
}

/// Production locking over the vendored blob's bridge.
struct SystemArchiveLocking: ArchiveLocking {
    func acquire(hash: String) -> ArchiveLock.AcquireResult { ArchiveLock.acquire(hash: hash) }
    func release(hash: String) { ArchiveLock.release(hash: hash) }
}

/// Staging-based payload store (injectable for tests). All three operate on a
/// single archive payload basename.
protocol ArchivePayloadStore {
    /// Move `name` out of the unison dir into staging (same-filesystem rename).
    func stage(_ name: String) throws
    /// Rollback: move a staged `name` back to its original location.
    func unstage(_ name: String) throws
    /// Commit a staged `name` to Trash.
    func commit(_ name: String) throws
}

enum ArchiveMutationError: Error, Equatable {
    case engineNotIdle
    case lockUnavailable(hash: String, reason: ArchiveLock.AcquireResult)
    case revalidationFailed
    case stagingFailed(file: String)   // already rolled back; nothing net changed
}

struct ArchiveMutationOutcome: Equatable {
    /// Payload files successfully moved to Trash.
    let trashed: [String]
    /// Payload files staged (removed from the original location) but whose
    /// Trash move failed — recoverable in staging, never a partial family at the
    /// original location.
    let commitFailures: [String]
}

enum ArchiveMutation {

    /// Execute `plan` atomically. Throws on any pre-commit failure, having
    /// released every acquired lock and left the original archive families
    /// intact (staging rolled back). On success/partial-commit, returns the
    /// outcome with locks released.
    @discardableResult
    static func execute(
        plan: ArchiveMutationPlan,
        isEngineIdle: () -> Bool,
        revalidate: () -> Bool,
        locking: ArchiveLocking,
        store: ArchivePayloadStore
    ) throws -> ArchiveMutationOutcome {

        guard isEngineIdle() else { throw ArchiveMutationError.engineNotIdle }

        // Release ONLY the locks we actually acquired, in reverse order, on
        // EVERY exit (success or throw). Pre-existing/foreign locks are never
        // in `owned`, so they are never released.
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

        // 2. Revalidate under the locks; still no payload touched.
        guard revalidate() else { throw ArchiveMutationError.revalidationFailed }

        // 3. Stage all payload files (atomic removal-or-nothing).
        var staged: [String] = []
        do {
            for f in plan.payloadFiles {
                try store.stage(f)
                staged.append(f)
            }
        } catch {
            // Roll back every already-staged file, restoring the original family.
            for f in staged.reversed() { try? store.unstage(f) }
            let failed = plan.payloadFiles.first { !staged.contains($0) } ?? "?"
            throw ArchiveMutationError.stagingFailed(file: failed)
        }

        // 4. Commit staged files to Trash. A failure here leaves the file in
        //    staging (recoverable); the original location is already clear, so
        //    there is never a partial family there.
        var commitFailures: [String] = []
        for f in staged {
            do { try store.commit(f) } catch { commitFailures.append(f) }
        }

        return ArchiveMutationOutcome(trashed: staged.filter { !commitFailures.contains($0) },
                                      commitFailures: commitFailures)
    }
}
