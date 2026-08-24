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
}
