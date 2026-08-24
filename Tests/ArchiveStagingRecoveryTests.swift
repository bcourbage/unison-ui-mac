import XCTest
@testable import unison_ui_mac

/// Explicit recovery for an abandoned staging. The exclusion barrier is never
/// dropped and re-taken: an existing `lk<hash>` is adopted only when its recorded
/// identity matches (else fail closed), and unlinked only after a successful,
/// confirmed file operation; a missing lock is acquired fresh atomically before
/// any file is touched. An unsuccessful recovery keeps the record intact (stays
/// blocked); adopted barriers stay held, while fresh barriers are released on
/// abort (only a release we couldn't confirm may remain), and a hash whose
/// acquisition failed with an unknown result may be left physically unprotected.
/// Plus the pure profile-open block policy.
final class ArchiveStagingRecoveryTests: XCTestCase {

    private let h  = "abcdef0123456789abcdef0123456789"
    private let h1 = "11111111111111111111111111111111"
    private let h2 = "22222222222222222222222222222222"

    private func tempDir() throws -> String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("recov-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private func write(_ dir: String, _ name: String) {
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name), contents: Data("x".utf8))
    }
    private func exists(_ dir: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name))
    }
    private func preCommit(_ q: String, hashes: [String], payloads: [String]) -> AbandonedStaging {
        var m = StagingManifest(operation: "test", hashes: hashes, payloadFiles: payloads,
                                createdAtISO8601: "2026-08-23T00:00:00Z")
        m.phase = StagingManifest.phaseStaging
        return AbandonedStaging(quarantineDir: q, manifest: m)
    }
    private func committed(_ q: String, hashes: [String], payloads: [String]) -> AbandonedStaging {
        var m = StagingManifest(operation: "test", hashes: hashes, payloadFiles: payloads,
                                createdAtISO8601: "2026-08-23T00:00:00Z")
        m.phase = StagingManifest.phaseCommitted
        return AbandonedStaging(quarantineDir: q, manifest: m)
    }

    /// Injectable locking. `heldByOthers` makes `acquire` fail (an external
    /// process holds it); `releaseConfirmed` controls whether `release` reports
    /// the lock gone. Fresh-acquire is modelled here (no real file created).
    private final class FakeLocking: ArchiveLocking {
        var heldByOthers: Set<String> = []
        var failWith: [String: ArchiveLock.AcquireResult] = [:]   // force a reason
        var releaseConfirmed = true
        private(set) var acquired: [String] = []
        private(set) var released: [String] = []
        func acquire(hash: String) -> ArchiveLock.AcquireResult {
            if let forced = failWith[hash] { return forced }
            if heldByOthers.contains(hash) { return .alreadyHeld }
            acquired.append(hash); return .acquired
        }
        @discardableResult func release(hash: String) -> Bool {
            released.append(hash); return releaseConfirmed
        }
        // recover() verifies an existing lock via LockIdentity(path:) on the real
        // file, not through this method, so a nil here is never consulted.
        func identity(hash: String) -> LockIdentity? { nil }
    }

    /// Return a copy of `a` whose manifest records the real on-disk identity of each
    /// hash's `lk` file in `activeDir` — i.e. the record an interrupted transaction
    /// would have written. Recovery adopts an existing lock only when it matches this.
    private func adopting(_ a: AbandonedStaging, in activeDir: String) -> AbandonedStaging {
        var m = a.manifest
        var ids: [String: LockIdentity] = [:]
        for h in m.hashes {
            if let id = LockIdentity(path: (activeDir as NSString).appendingPathComponent("lk" + h)) {
                ids[h] = id
            }
        }
        m.lockIdentities = ids
        return AbandonedStaging(quarantineDir: a.quarantineDir, manifest: m)
    }

    // MARK: - finalize / isProfileBlocked (helpers)

    func test_finalize_removesQuarantineWhenEmpty_keepsWhenPayloadRemains() throws {
        let q = try tempDir()
        write(q, "ar"+h)
        XCTAssertFalse(ArchiveStagingRecovery.finalize(preCommit(q, hashes: [h], payloads: ["ar"+h])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q))
        try FileManager.default.removeItem(atPath: (q as NSString).appendingPathComponent("ar"+h))
        XCTAssertTrue(ArchiveStagingRecovery.finalize(preCommit(q, hashes: [h], payloads: ["ar"+h])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q))
    }

    func test_isProfileBlocked() {
        XCTAssertTrue(ArchiveStagingRecovery.isProfileBlocked(profileHashes: [h, "other"], blocked: [h]))
        XCTAssertFalse(ArchiveStagingRecovery.isProfileBlocked(profileHashes: ["x", "y"], blocked: [h]))
        XCTAssertFalse(ArchiveStagingRecovery.isProfileBlocked(profileHashes: [h], blocked: []))
    }

    // MARK: - recover() success paths

    /// Existing lock is RETAINED as the barrier (never re-acquired), files are
    /// restored, and only then is the lock unlinked and the quarantine removed.
    func test_recover_preCommit_retainsExistingLockAsBarrier_thenUnlinks() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)                 // the abandoned lock (barrier)
        write(q, "ar"+h); write(q, "fp"+h)

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            adopting(preCommit(q, hashes: [h], payloads: ["ar"+h, "fp"+h]), in: active),
            activeDir: active, locking: lk)

        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(lk.acquired, [], "existing lock retained — never deleted and re-acquired")
        XCTAssertEqual(lk.released, [], "existing lock is unlinked directly, not released via the lock API")
        XCTAssertTrue(exists(active, "ar"+h)); XCTAssertTrue(exists(active, "fp"+h))
        XCTAssertFalse(exists(active, "lk"+h), "barrier unlinked only after full restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: q), "quarantine removed after restore")
    }

    /// A missing lock is acquired fresh (atomic) and released on success.
    func test_recover_preCommit_missingLock_acquiresFreshAndReleases() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h)                      // no lk on disk

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            preCommit(q, hashes: [h], payloads: ["ar"+h]), activeDir: active, locking: lk)

        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(lk.acquired, [h], "missing lock acquired fresh before any file touched")
        XCTAssertEqual(lk.released, [h], "freshly-acquired lock released on success")
        XCTAssertTrue(exists(active, "ar"+h))
    }

    func test_recover_committed_unlinksExistingLock_thenTrashes() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)
        write(q, "ar"+h)

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            adopting(committed(q, hashes: [h], payloads: ["ar"+h]), in: active),
            activeDir: active, locking: lk)

        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(lk.acquired, [], "committed staging with a surviving lock retains it as barrier")
        XCTAssertFalse(exists(active, "lk"+h), "barrier unlinked before Trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: q), "committed quarantine moved to Trash")
    }

    // MARK: - recover() adversarial / failure paths (must leave families locked)

    /// External acquisition during recovery: the recorded lock is missing and an
    /// external process holds it, so recovery cannot secure it — it aborts without
    /// touching files. (With an EXISTING lock this window does not exist at all,
    /// because the barrier is never dropped.)
    func test_recover_missingLock_heldByExternal_aborts_touchesNothing() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h)                      // the ONLY copy
        let lk = FakeLocking(); lk.heldByOthers = [h]

        let outcome = ArchiveStagingRecovery.recover(
            preCommit(q, hashes: [h], payloads: ["ar"+h]), activeDir: active, locking: lk)

        guard case .aborted = outcome else { return XCTFail("expected .aborted, got \(outcome)") }
        XCTAssertTrue(exists(q, "ar"+h), "no restore attempted — staged file untouched")
        XCTAssertFalse(exists(active, "ar"+h))
        XCTAssertEqual(lk.released, [], "released nothing")
    }

    /// Preflight: a single collision blocks the WHOLE restore — not even the
    /// non-colliding sibling is moved, and the barrier is never released.
    func test_recover_preCommit_anyCollision_movesNothing_leavesLocked() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)
        write(q, "ar"+h); write(q, "fp"+h)
        write(active, "fp"+h)                 // collision on fp only

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            adopting(preCommit(q, hashes: [h], payloads: ["ar"+h, "fp"+h]), in: active),
            activeDir: active, locking: lk)

        guard case .needsManualReview = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(exists(q, "ar"+h), "non-colliding sibling NOT moved (preflight aborts before any move)")
        XCTAssertTrue(exists(q, "fp"+h), "colliding file kept, never deleted")
        XCTAssertTrue(exists(active, "lk"+h), "barrier remains — family stays physically locked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: q), "record retained")
    }

    /// Multi-hash recovery where a later hash cannot be secured: recovery aborts,
    /// no payloads move, and the earlier hash stays physically locked.
    func test_recover_multiHash_laterHashUnsecurable_earlierStaysLocked() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h1)                // h1 has an existing barrier
        write(q, "ar"+h1); write(q, "ar"+h2) // h2 has no lock on disk
        let lk = FakeLocking(); lk.heldByOthers = [h2]   // h2 held by an external process

        let outcome = ArchiveStagingRecovery.recover(
            adopting(preCommit(q, hashes: [h1, h2], payloads: ["ar"+h1, "ar"+h2]), in: active),
            activeDir: active, locking: lk)

        guard case .aborted = outcome else { return XCTFail("expected .aborted, got \(outcome)") }
        XCTAssertTrue(exists(q, "ar"+h1), "no payload moved for the secured hash")
        XCTAssertTrue(exists(q, "ar"+h2), "no payload moved for the unsecurable hash")
        XCTAssertTrue(exists(active, "lk"+h1), "earlier hash's barrier retained — stays physically locked")
        XCTAssertEqual(lk.released, [], "nothing released on abort")
    }

    /// SF2: on a successful restore, if a freshly-acquired lock's release cannot be
    /// confirmed, the record is retained and the outcome is non-success.
    func test_recover_preCommit_releaseUnconfirmed_retainsRecord() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h)                      // no lk on disk → fresh acquire
        let lk = FakeLocking(); lk.releaseConfirmed = false

        let outcome = ArchiveStagingRecovery.recover(
            preCommit(q, hashes: [h], payloads: ["ar"+h]), activeDir: active, locking: lk)

        guard case .needsManualReview = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(lk.acquired, [h]); XCTAssertEqual(lk.released, [h], "release attempted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: q),
                      "manifest/quarantine retained because release was not confirmed")
    }

    // MARK: - Round-11 Blocker: an existing lock is adopted ONLY if it is OURS

    /// The recorded lock is replaced with a different inode before recovery (a
    /// DIFFERENT process acquired lk<hash> after the crash). Recovery must NOT adopt
    /// or delete it, must acquire nothing, and must leave the lock, payload, and
    /// record untouched.
    func test_recover_existingLock_identityMismatch_failsClosed_touchesNothing() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)                                   // the original transaction's lock
        write(q, "ar"+h)
        let rec = adopting(preCommit(q, hashes: [h], payloads: ["ar"+h]), in: active)
        // A different process replaces the lock (new inode / change time).
        try FileManager.default.removeItem(atPath: (active as NSString).appendingPathComponent("lk"+h))
        write(active, "lk"+h)

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(rec, activeDir: active, locking: lk)

        guard case .needsManualReview = outcome else { return XCTFail("expected .needsManualReview, got \(outcome)") }
        XCTAssertEqual(lk.acquired, [], "did not acquire anything")
        XCTAssertEqual(lk.released, [], "did NOT delete the other process's lock")
        XCTAssertTrue(exists(active, "lk"+h), "the foreign lock is left in place")
        XCTAssertTrue(exists(q, "ar"+h), "payload untouched")
        XCTAssertFalse(exists(active, "ar"+h), "nothing restored")
    }

    /// SF1: recovery acquires h1 fresh, then h2 can't be secured; releasing its own
    /// fresh h1 lock also FAILS. Recovery must surface that retained lock (its
    /// identity isn't recorded, so a later recovery can't adopt it — otherwise a
    /// dead end) rather than reporting only the h2 problem.
    func test_recover_abortReleaseFailure_reportsRetainedFreshLock() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h1); write(q, "ar"+h2)      // no lk on disk for either → fresh path
        let lk = FakeLocking()
        lk.heldByOthers = [h2]                     // h2 can't be acquired
        lk.releaseConfirmed = false               // releasing our fresh h1 lock fails

        let outcome = ArchiveStagingRecovery.recover(
            preCommit(q, hashes: [h1, h2], payloads: ["ar"+h1, "ar"+h2]), activeDir: active, locking: lk)

        guard case .needsManualReview(let why) = outcome else {
            return XCTFail("expected .needsManualReview, got \(outcome)")
        }
        XCTAssertTrue(why.contains(h1), "names the fresh lock it could not release")
        XCTAssertEqual(lk.acquired, [h1], "acquired h1 fresh before h2 failed")
        XCTAssertEqual(lk.released, [h1], "attempted to release the fresh h1 lock")
    }

    /// A legacy/acquiring record with NO recorded identity must never adopt (and
    /// delete) an existing lock, even though the lock happens to be present.
    func test_recover_existingLock_noRecordedIdentity_failsClosed() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h); write(q, "ar"+h)
        // preCommit() without adopting() → manifest has no lockIdentities.
        let outcome = ArchiveStagingRecovery.recover(
            preCommit(q, hashes: [h], payloads: ["ar"+h]), activeDir: active, locking: FakeLocking())
        guard case .needsManualReview = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(exists(active, "lk"+h), "lock left untouched (no identity to prove it is ours)")
        XCTAssertTrue(exists(q, "ar"+h), "payload untouched")
    }

    /// A move failure leaves the family physically locked and the record intact.
    func test_recover_preCommit_moveFailure_leavesLocked() throws {
        let active = try tempDir(); let q = try tempDir()
        defer {
            chmod(active, 0o755)              // restore perms so cleanup can proceed
            try? FileManager.default.removeItem(atPath: active)
            try? FileManager.default.removeItem(atPath: q)
        }
        write(active, "lk"+h)
        write(q, "ar"+h)
        let rec = adopting(preCommit(q, hashes: [h], payloads: ["ar"+h]), in: active)
        chmod(active, 0o500)                  // read-only active dir → moveItem into it fails

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(rec, activeDir: active, locking: lk)

        guard case .needsManualReview = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(exists(q, "ar"+h), "staged copy still present after failed move")
        XCTAssertTrue(exists(active, "lk"+h), "barrier retained — family stays physically locked")
    }

    // MARK: - SF2 — cleanup failures after a successful, fully-released recovery
    //         are NOT blocking (.cleanupOnly), unlike a genuine still-locked failure.

    /// Fails removeItem for DIRECTORIES only (the quarantine) — a file unlink (lk)
    /// still succeeds, so the lock is genuinely released.
    private final class FailDirRemoveFM: FileManager {
        override func removeItem(atPath path: String) throws {
            var isDir: ObjCBool = false
            if super.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                throw CocoaError(.fileWriteUnknown)
            }
            try super.removeItem(atPath: path)
        }
    }
    private final class FailTrashFM: FileManager {
        override func trashItem(at url: URL,
                                resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func test_recover_preCommit_finalizeFailure_afterRelease_isCleanupOnly() throws {
        let fm = FailDirRemoveFM()
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)                 // existing barrier — released via file unlink (allowed)
        write(q, "ar"+h)

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            adopting(preCommit(q, hashes: [h], payloads: ["ar"+h]), in: active),
            activeDir: active, locking: lk, fileManager: fm)

        guard case .cleanupOnly = outcome else { return XCTFail("expected .cleanupOnly, got \(outcome)") }
        XCTAssertTrue(exists(active, "ar"+h), "family restored")
        XCTAssertFalse(exists(active, "lk"+h), "lock genuinely released — not blocking")
    }

    func test_recover_committed_trashFailure_afterRelease_isCleanupOnly() throws {
        let fm = FailTrashFM()
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)
        write(q, "ar"+h)

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            adopting(committed(q, hashes: [h], payloads: ["ar"+h]), in: active),
            activeDir: active, locking: lk, fileManager: fm)

        guard case .cleanupOnly = outcome else { return XCTFail("expected .cleanupOnly, got \(outcome)") }
        XCTAssertFalse(exists(active, "lk"+h), "lock genuinely released — profile not blocked")
    }

    // MARK: - Blocker: overlapping records must not be auto-recovered

    func test_overlapGroups_partitionsBySharedHashes() {
        let r1 = preCommit("/q1", hashes: [h1], payloads: [])
        let r2 = committed("/q2", hashes: [h1], payloads: [])        // shares h1 with r1
        let r3 = preCommit("/q3", hashes: [h2], payloads: [])        // disjoint
        let groups = ArchiveStagingRecovery.overlapGroups([r1, r2, r3])
        XCTAssertEqual(groups.count, 2, "one overlap group {r1,r2}, one singleton {r3}")
        XCTAssertTrue(groups.contains { $0.count == 2 })
        XCTAssertTrue(groups.contains { $0.count == 1 && $0.first?.quarantineDir == "/q3" })
    }

    /// Round-10 Blocker: a profile-filtered request must still be grouped against
    /// the COMPLETE universe. A = staging{h1,h2}, B = staging{h2}; the profile only
    /// intersects h1 so only A is requested — but A and B share h2, so the relevant
    /// global group is {A,B} (size 2) and auto-recovery is refused, leaving B's
    /// lk<h2> untouched. Grouping the requested subset alone would wrongly authorize A.
    func test_recoveryGroups_profileFilteredRequest_groupsAgainstGlobalUniverse() {
        let a = preCommit("/qA", hashes: [h1, h2], payloads: [])
        let b = preCommit("/qB", hashes: [h2], payloads: [])
        let groups = ArchiveStagingRecovery.recoveryGroups(
            universe: [a, b], requestedDirectories: ["/qA"])   // only A requested
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2,
                       "A and B share h2 → relevant group includes the omitted B; size 2 → refuse")
        // The mutation this guards against: grouping only the requested subset would
        // yield a singleton and wrongly authorize A (and unlink B's lk<h2>).
        XCTAssertEqual(ArchiveStagingRecovery.overlapGroups([a]).first?.count, 1,
                       "requested-only grouping is the DEFECT — a singleton — this test rejects")
    }

    /// A truly independent requested record (no global overlap) is a singleton and
    /// remains auto-recoverable.
    func test_recoveryGroups_independentRequest_isSingleton() {
        let a = preCommit("/qA", hashes: [h1], payloads: [])
        let b = preCommit("/qB", hashes: [h2], payloads: [])   // disjoint
        let groups = ArchiveStagingRecovery.recoveryGroups(
            universe: [a, b], requestedDirectories: ["/qA"])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 1)
        XCTAssertEqual(groups.first?.first?.quarantineDir, "/qA")
    }

    /// The exact Blocker scenario: an aborted lock-free leftover and a LATER staging
    /// record share a hash whose `lk` protects the staging record's split family.
    /// Recovering the aborted record must NOT run — its cleanup branch would unlink
    /// the staging record's barrier. The overlap grouping refuses the whole group.
    func test_overlap_abortedLeftoverPlusLaterStaging_refusesGroup_barrierUntouched() throws {
        let active = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "lk"+h)                        // the staging record's live barrier
        var aborted = committed("/old-aborted-q", hashes: [h], payloads: [])
        aborted = AbandonedStaging(quarantineDir: "/old-aborted-q",
                                   manifest: { var m = aborted.manifest; m.phase = StagingManifest.phaseAborted; return m }())
        let staging = preCommit("/new-staging-q", hashes: [h], payloads: ["ar"+h])

        // Both records share hash h → a single overlap group of size 2 → refused.
        let groups = ArchiveStagingRecovery.overlapGroups([aborted, staging])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2, "shared hash → one group; caller must refuse it")
        // The barrier is never touched by a grouping decision.
        XCTAssertTrue(exists(active, "lk"+h), "the staging record's lock is untouched")
    }

    // MARK: - SF2: unknown lock state is not "another Unison holds it"

    func test_recover_missingLock_acquireException_warnsUnprotected_notForeignHeld() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h)                             // split family, NO lk on disk
        let lk = FakeLocking(); lk.failWith = [h: .exception]   // acquire raises → unknown

        let outcome = ArchiveStagingRecovery.recover(
            preCommit(q, hashes: [h], payloads: ["ar"+h]), activeDir: active, locking: lk)

        guard case .aborted(let why) = outcome else { return XCTFail("expected .aborted, got \(outcome)") }
        XCTAssertTrue(why.contains("UNPROTECTED"), "unknown lock state warns of an unprotected archive")
        XCTAssertFalse(why.contains("another Unison holds"), "must not claim a foreign lock is held")
        XCTAssertTrue(exists(q, "ar"+h), "nothing restored — family untouched")
    }

    // MARK: - SF3: unrecognized records are fail-closed manual review

    func test_recover_unknownPhase_isManualReview_touchesNothing() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h); write(q, "ar"+h)
        var m = StagingManifest(operation: "test", hashes: [h], payloadFiles: ["ar"+h],
                                createdAtISO8601: "2026-08-23T00:00:00Z")
        m.phase = "frobnicate"                        // unknown phase
        let rec = AbandonedStaging(quarantineDir: q, manifest: m)

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(rec, activeDir: active, locking: lk)

        guard case .needsManualReview = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(lk.acquired, [], "no lock touched for an unrecognized record")
        XCTAssertTrue(exists(active, "lk"+h)); XCTAssertTrue(exists(q, "ar"+h), "nothing moved")
    }

    func test_recover_futureVersion_isManualReview() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h)
        var m = StagingManifest(operation: "test", hashes: [h], payloadFiles: ["ar"+h],
                                createdAtISO8601: "2026-08-23T00:00:00Z")
        m.version = StagingManifest.currentVersion + 1   // written by a newer app
        m.phase = StagingManifest.phaseStaging
        let rec = AbandonedStaging(quarantineDir: q, manifest: m)

        let outcome = ArchiveStagingRecovery.recover(rec, activeDir: active, locking: FakeLocking())
        guard case .needsManualReview = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(exists(q, "ar"+h), "a future-version record is never restored or trashed")
    }
}
