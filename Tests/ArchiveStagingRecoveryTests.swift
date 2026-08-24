import XCTest
@testable import unison_ui_mac

/// Blocker 3 — explicit recovery for a pre-commit abandoned staging RESTORES
/// staged files (never trashes them), never overwrites a collision, removes the
/// quarantine only when fully restored, and removes locks only on demand. Plus
/// the pure profile-open block policy.
final class ArchiveStagingRecoveryTests: XCTestCase {

    private let h = "abcdef0123456789abcdef0123456789"

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
    private func abandoned(quarantine: String, payloads: [String]) -> AbandonedStaging {
        let m = StagingManifest(operation: "test", hashes: [h], payloadFiles: payloads,
                                createdAtISO8601: "2026-08-23T00:00:00Z")
        return AbandonedStaging(quarantineDir: quarantine, manifest: m)
    }

    func test_restore_movesStagedBack_skipsCollisions() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h); write(q, "fp"+h)   // staged copies
        write(active, "fp"+h)                 // a collision already present in active

        let r = ArchiveStagingRecovery.restore(abandoned(quarantine: q, payloads: ["ar"+h, "fp"+h]),
                                               activeDir: active)
        XCTAssertEqual(r.restored, ["ar"+h])
        XCTAssertEqual(r.collided, ["fp"+h])
        XCTAssertFalse(r.isComplete)
        XCTAssertTrue(exists(active, "ar"+h), "non-colliding file restored")
        XCTAssertTrue(exists(q, "fp"+h), "colliding staged file kept in quarantine, never deleted")
    }

    func test_finalize_removesQuarantineWhenEmpty_keepsWhenPayloadRemains() throws {
        let q = try tempDir()
        // A payload still present → finalize refuses and keeps the quarantine.
        write(q, "ar"+h)
        XCTAssertFalse(ArchiveStagingRecovery.finalize(abandoned(quarantine: q, payloads: ["ar"+h])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q))
        // No payloads remain → finalize removes the quarantine.
        try FileManager.default.removeItem(atPath: (q as NSString).appendingPathComponent("ar"+h))
        XCTAssertTrue(ArchiveStagingRecovery.finalize(abandoned(quarantine: q, payloads: ["ar"+h])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q))
    }

    func test_removeLocks_removesRecordedLocks() throws {
        let active = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "lk"+h)
        let removed = ArchiveStagingRecovery.removeLocks(abandoned(quarantine: "/x", payloads: []),
                                                         activeDir: active)
        XCTAssertEqual(removed, [h])
        XCTAssertFalse(exists(active, "lk"+h))
    }

    func test_isProfileBlocked() {
        XCTAssertTrue(ArchiveStagingRecovery.isProfileBlocked(profileHashes: [h, "other"], blocked: [h]))
        XCTAssertFalse(ArchiveStagingRecovery.isProfileBlocked(profileHashes: ["x", "y"], blocked: [h]))
        XCTAssertFalse(ArchiveStagingRecovery.isProfileBlocked(profileHashes: [h], blocked: []))
    }

    // MARK: - recover() — Blocker 1 + SF2 (authority-controlled transaction)

    /// Injectable locking that tracks calls and can simulate a lock held by
    /// another process. Operates purely in-memory (recover() removes the on-disk
    /// lk file via removeLocks first; acquisition is modelled here).
    private final class FakeLocking: ArchiveLocking {
        var heldByOthers: Set<String> = []
        private(set) var acquired: [String] = []
        private(set) var released: [String] = []
        func acquire(hash: String) -> ArchiveLock.AcquireResult {
            if heldByOthers.contains(hash) { return .alreadyHeld }
            acquired.append(hash); return .acquired
        }
        @discardableResult func release(hash: String) -> Bool {
            released.append(hash); return true
        }
    }

    private func committedManifest(quarantine: String, payloads: [String]) -> AbandonedStaging {
        var m = StagingManifest(operation: "test", hashes: [h], payloadFiles: payloads,
                                createdAtISO8601: "2026-08-23T00:00:00Z")
        m.phase = StagingManifest.phaseCommitted
        return AbandonedStaging(quarantineDir: quarantine, manifest: m)
    }

    func test_recover_preCommit_restoresUnderFreshLock_removesQuarantine() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)          // recorded stale lock
        write(q, "ar"+h); write(q, "fp"+h)

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            abandoned(quarantine: q, payloads: ["ar"+h, "fp"+h]), activeDir: active, locking: lk)

        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(lk.acquired, [h], "acquired the archive lock fresh")
        XCTAssertEqual(lk.released, [h], "released only the lock it acquired")
        XCTAssertFalse(exists(active, "lk"+h), "recorded stale lock removed")
        XCTAssertTrue(exists(active, "ar"+h)); XCTAssertTrue(exists(active, "fp"+h))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q), "quarantine removed after full restore")
    }

    func test_recover_abortsWithoutTouchingFiles_whenLockHeldByOther() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(q, "ar"+h)               // staged copy — the ONLY copy
        let lk = FakeLocking(); lk.heldByOthers = [h]

        let outcome = ArchiveStagingRecovery.recover(
            abandoned(quarantine: q, payloads: ["ar"+h]), activeDir: active, locking: lk)

        guard case .aborted = outcome else { return XCTFail("expected .aborted, got \(outcome)") }
        XCTAssertTrue(exists(q, "ar"+h), "no restore attempted — staged file untouched")
        XCTAssertFalse(exists(active, "ar"+h), "nothing restored into the active dir")
        XCTAssertEqual(lk.released, [], "released nothing (acquired nothing)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: q), "manifest/quarantine retained for retry")
    }

    func test_recover_committed_trashesWholeQuarantine() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)
        write(q, "ar"+h)               // already-staged-out family

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            committedManifest(quarantine: q, payloads: ["ar"+h]), activeDir: active, locking: lk)

        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(lk.acquired, [h]); XCTAssertEqual(lk.released, [h])
        XCTAssertFalse(FileManager.default.fileExists(atPath: q), "committed quarantine moved to Trash")
    }

    func test_recover_preCommit_needsManualReview_onCollision_retainsQuarantine() throws {
        let active = try tempDir(); let q = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: active); try? FileManager.default.removeItem(atPath: q) }
        write(active, "lk"+h)
        write(q, "ar"+h)
        write(active, "ar"+h)          // collision: engine re-created it

        let lk = FakeLocking()
        let outcome = ArchiveStagingRecovery.recover(
            abandoned(quarantine: q, payloads: ["ar"+h]), activeDir: active, locking: lk)

        guard case .needsManualReview = outcome else {
            return XCTFail("expected .needsManualReview, got \(outcome)")
        }
        XCTAssertTrue(exists(q, "ar"+h), "colliding staged file kept, never deleted")
        XCTAssertEqual(lk.released, [h], "the acquired lock is still released on exit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: q), "quarantine retained for manual review")
    }
}
