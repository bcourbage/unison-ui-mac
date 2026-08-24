import XCTest
@testable import unison_ui_mac

/// Explicit recovery for an abandoned staging. The exclusion barrier is never
/// dropped and re-taken (Blocker 1): an existing `lk<hash>` is RETAINED as the
/// barrier and only unlinked after a successful, confirmed file operation; a
/// missing lock is acquired fresh atomically before any file is touched. Any
/// unsuccessful recovery leaves every affected family physically locked and the
/// record intact. Plus the pure profile-open block policy.
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
        let m = StagingManifest(operation: "test", hashes: hashes, payloadFiles: payloads,
                                createdAtISO8601: "2026-08-23T00:00:00Z")
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
        var releaseConfirmed = true
        private(set) var acquired: [String] = []
        private(set) var released: [String] = []
        func acquire(hash: String) -> ArchiveLock.AcquireResult {
            if heldByOthers.contains(hash) { return .alreadyHeld }
            acquired.append(hash); return .acquired
        }
        @discardableResult func release(hash: String) -> Bool {
            released.append(hash); return releaseConfirmed
        }
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
            preCommit(q, hashes: [h], payloads: ["ar"+h, "fp"+h]), activeDir: active, locking: lk)

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
            committed(q, hashes: [h], payloads: ["ar"+h]), activeDir: active, locking: lk)

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
            preCommit(q, hashes: [h], payloads: ["ar"+h, "fp"+h]), activeDir: active, locking: lk)

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
            preCommit(q, hashes: [h1, h2], payloads: ["ar"+h1, "ar"+h2]), activeDir: active, locking: lk)

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
        chmod(active, 0o500)                  // read-only active dir → moveItem into it fails

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            preCommit(q, hashes: [h], payloads: ["ar"+h]), activeDir: active, locking: lk)

        guard case .needsManualReview = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(exists(q, "ar"+h), "staged copy still present after failed move")
        XCTAssertTrue(exists(active, "lk"+h), "barrier retained — family stays physically locked")
    }
}
