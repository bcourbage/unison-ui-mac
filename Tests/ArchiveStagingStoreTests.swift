import XCTest
@testable import unison_ui_mac

/// Crash-safe production staging store + restart detection (the review's
/// required production tests): real POSIX rename, whole-directory Trash as one
/// unit, abandoned pre-commit detection, post-commit cleanup-failure retention,
/// and no automatic stale-lock removal. Uses isolated temp directories so no
/// real Trash or real unison archives are touched.
final class ArchiveStagingStoreTests: XCTestCase {

    private let h = "abcdef0123456789abcdef0123456789"   // 32 lowercase hex

    // FileManager that records trashItem calls and simulates the trash by
    // removing the item — so we can prove "one call, with the DIRECTORY" without
    // polluting the real Trash.
    private final class RecordingTrashFM: FileManager {
        var trashed: [URL] = []
        override func trashItem(at url: URL,
                                resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            trashed.append(url)
            try removeItem(at: url)
        }
    }
    private final class FailingTrashFM: FileManager {
        override func trashItem(at url: URL,
                                resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func makeTempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("stagingtest-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ dir: String, _ name: String, _ body: String = "x") {
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name),
                                       contents: Data(body.utf8))
    }
    private func exists(_ dir: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name))
    }
    private func manifest(_ files: [String], phase: String = StagingManifest.phaseStaging) -> StagingManifest {
        var m = StagingManifest(operation: "test", hashes: [h], payloadFiles: files,
                                createdAtISO8601: "2026-08-23T00:00:00Z")
        m.phase = phase
        return m
    }

    // MARK: real POSIX rename

    func test_stage_usesRealRename_thenRollbackRestores() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h); write(active, "fp"+h)
        let store = POSIXStagingStore(unisonDir: active)
        try store.beginStaging(manifest(["ar"+h, "fp"+h]))
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h)
        try store.stage("fp"+h)
        XCTAssertFalse(exists(active, "ar"+h), "rename moved it out of the active dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (q as NSString).appendingPathComponent("ar"+h)),
                      "rename moved it into the quarantine dir")
        // Rollback restores both to the active dir and removes the quarantine.
        try store.rollback()
        XCTAssertTrue(exists(active, "ar"+h)); XCTAssertTrue(exists(active, "fp"+h))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q), "quarantine removed on rollback")
    }

    // MARK: whole-directory Trash, one unit

    func test_commit_trashesWholeDirectory_asOneUnit() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h); write(active, "fp"+h)
        let fm = RecordingTrashFM()
        let store = POSIXStagingStore(unisonDir: active, fileManager: fm)
        try store.beginStaging(manifest(["ar"+h, "fp"+h]))
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h); try store.stage("fp"+h)
        try store.commit()
        XCTAssertEqual(fm.trashed.count, 1, "exactly ONE trash call — the whole dir, not per-file")
        XCTAssertEqual(fm.trashed.first?.path, q, "trashed the quarantine DIRECTORY")
        XCTAssertFalse(FileManager.default.fileExists(atPath: q), "quarantine gone from active dir")
        XCTAssertFalse(exists(active, "ar"+h)); XCTAssertFalse(exists(active, "fp"+h))
        XCTAssertNil(store.quarantinePath)
    }

    // MARK: post-commit Trash cleanup failure → retain complete quarantine

    func test_commitCleanupFailure_retainsQuarantine_withCommittedManifest() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h)
        let store = POSIXStagingStore(unisonDir: active, fileManager: FailingTrashFM())
        try store.beginStaging(manifest(["ar"+h]))
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h)
        XCTAssertThrowsError(try store.commit()) {
            XCTAssertEqual($0 as? ArchiveStoreError, .trashFailed(q))
        }
        XCTAssertEqual(store.quarantinePath, q, "quarantine retained + reported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (q as NSString).appendingPathComponent("ar"+h)),
                      "the whole family is safe in the retained quarantine")
        XCTAssertFalse(exists(active, "ar"+h), "no partial family at the original location")
        // The retained manifest is marked committed → restart treats it as a
        // post-commit leftover, not a pre-commit block.
        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(abandoned.first?.manifest.phase, StagingManifest.phaseCommitted)
        XCTAssertTrue(AbandonedStagingScan.blockedHashes(abandoned).isEmpty,
                      "a committed leftover does not block any profile")
    }

    // MARK: abandoned PRE-COMMIT detection blocks the affected hashes

    func test_abandonedPreCommitStaging_isDetected_andBlocks() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h)
        let store = POSIXStagingStore(unisonDir: active)
        try store.beginStaging(manifest(["ar"+h]))   // manifest written…
        try store.stage("ar"+h)                       // …and staging begun, but NOT committed
        // (simulate process death here — no commit/rollback)

        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(abandoned.first?.manifest.phase, StagingManifest.phaseStaging)
        XCTAssertEqual(AbandonedStagingScan.blockedHashes(abandoned), [h],
                       "a pre-commit abandoned mutation blocks its hashes (fail closed)")
    }

    // MARK: scan never removes locks (no automatic stale-lock removal)

    func test_scan_neverRemovesLocks() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        // A lock left by an interrupted op, plus its abandoned staging.
        write(active, "lk"+h)
        let store = POSIXStagingStore(unisonDir: active)
        try store.beginStaging(manifest(["ar"+h]))

        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        _ = AbandonedStagingScan.blockedHashes(abandoned)
        XCTAssertTrue(exists(active, "lk"+h),
                      "detection must never delete the lock — recovery is explicit")
    }

    // MARK: integration — real store through the transaction

    func test_integration_transactionWithRealStore_removesFamily_oneDirTrash() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h); write(active, "fp"+h)
        let fm = RecordingTrashFM()
        let store = POSIXStagingStore(unisonDir: active, fileManager: fm)

        final class NoopLocking: ArchiveLocking {
            func acquire(hash: String) -> ArchiveLock.AcquireResult { .acquired }
            func release(hash: String) {}
        }
        let plan = ArchiveMutationPlan(hashes: [h],
                                       fileExists: { self.exists(active, $0) })
        XCTAssertEqual(Set(plan.payloadFiles), Set(["ar"+h, "fp"+h]))
        let out = try ArchiveMutation.execute(
            operation: "clean-stale", plan: plan, nowISO8601: "2026-08-23T00:00:00Z",
            isEngineIdle: { true }, revalidate: { true },
            locking: NoopLocking(), store: store)

        XCTAssertNil(out.quarantineRetained)
        XCTAssertEqual(fm.trashed.count, 1, "one whole-dir Trash")
        XCTAssertFalse(exists(active, "ar"+h)); XCTAssertFalse(exists(active, "fp"+h))
        XCTAssertTrue(AbandonedStagingScan.find(inUnisonDir: active).isEmpty,
                      "no abandoned staging remains after a clean commit")
    }
}
