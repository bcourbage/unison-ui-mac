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
    // Fails removeItem for DIRECTORIES only, so the low-level manifest rewrite
    // (POSIX open/write/rename) still works but the quarantine dir cannot be removed.
    private final class FailDirRemoveFM: FileManager {
        override func removeItem(atPath path: String) throws {
            var isDir: ObjCBool = false
            if super.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                throw CocoaError(.fileWriteUnknown)
            }
            try super.removeItem(atPath: path)
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
    /// Drive the store to the staging phase the way the transaction does: a durable
    /// intent record BEFORE locks, then the under-lock payload plan.
    private func begin(_ store: POSIXStagingStore, _ files: [String]) throws {
        try store.beginIntent(manifest([], phase: StagingManifest.phaseAcquiring))
        try store.recordPlan(manifest(files, phase: StagingManifest.phaseStaging))
    }

    // MARK: real POSIX rename

    func test_stage_usesRealRename_thenRollbackRestores() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h); write(active, "fp"+h)
        let store = POSIXStagingStore(unisonDir: active)
        try begin(store, ["ar"+h, "fp"+h])
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h)
        try store.stage("fp"+h)
        XCTAssertFalse(exists(active, "ar"+h), "rename moved it out of the active dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (q as NSString).appendingPathComponent("ar"+h)),
                      "rename moved it into the quarantine dir")
        // Rollback restores both to the active dir but KEEPS the record (removal is
        // gated on confirmed lock release, SF1).
        try store.rollback()
        XCTAssertTrue(exists(active, "ar"+h)); XCTAssertTrue(exists(active, "fp"+h))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q), "record retained until discardRecord")
        // discardRecord removes the now-empty quarantine + manifest.
        try store.discardRecord()
        XCTAssertFalse(FileManager.default.fileExists(atPath: q), "quarantine removed on discardRecord")
        XCTAssertNil(store.quarantinePath)
    }

    // MARK: rollback that cannot fully restore → retain, never delete

    func test_rollback_restoreFailure_retainsQuarantine_neverDeletes() throws {
        let active = try makeTempDir()
        defer { chmod(active, 0o700); try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h); write(active, "fp"+h)
        let store = POSIXStagingStore(unisonDir: active)
        try begin(store, ["ar"+h, "fp"+h])
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h); try store.stage("fp"+h)   // both moved into quarantine
        // Make the active dir read-only so restore rename() back into it fails.
        XCTAssertEqual(chmod(active, 0o500), 0)
        XCTAssertThrowsError(try store.rollback()) {
            XCTAssertEqual($0 as? ArchiveStoreError, .rollbackIncomplete(q))
        }
        chmod(active, 0o700)   // restore write to inspect + clean up
        XCTAssertTrue(FileManager.default.fileExists(atPath: q), "quarantine retained")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (q as NSString).appendingPathComponent("ar"+h)),
            "un-restored file kept in quarantine — never deleted")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (q as NSString).appendingPathComponent(AbandonedStagingScan.manifestName)),
            "manifest retained (still pre-commit → restart fails closed)")
    }

    // MARK: whole-directory Trash, one unit

    func test_commit_trashesWholeDirectory_asOneUnit() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h); write(active, "fp"+h)
        let fm = RecordingTrashFM()
        let store = POSIXStagingStore(unisonDir: active, fileManager: fm)
        try begin(store, ["ar"+h, "fp"+h])
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h); try store.stage("fp"+h)
        try store.markCommitted()
        try store.trashQuarantine()
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
        try begin(store, ["ar"+h])
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h)
        try store.markCommitted()
        XCTAssertThrowsError(try store.trashQuarantine()) {
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
        XCTAssertTrue(AbandonedStagingScan.blockedHashes(abandoned, unisonDir: active).isEmpty,
                      "a committed leftover does not block any profile")
    }

    // MARK: abandoned PRE-COMMIT detection blocks the affected hashes

    func test_abandonedPreCommitStaging_isDetected_andBlocks() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h)
        let store = POSIXStagingStore(unisonDir: active)
        try begin(store, ["ar"+h])   // manifest written…
        try store.stage("ar"+h)                       // …and staging begun, but NOT committed
        // (simulate process death here — no commit/rollback)

        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(abandoned.first?.manifest.phase, StagingManifest.phaseStaging)
        XCTAssertEqual(AbandonedStagingScan.blockedHashes(abandoned, unisonDir: active), [h],
                       "a pre-commit abandoned mutation blocks its hashes (fail closed)")
    }

    // MARK: scan never removes locks (no automatic stale-lock removal)

    func test_scan_neverRemovesLocks() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        // A lock left by an interrupted op, plus its abandoned staging.
        write(active, "lk"+h)
        let store = POSIXStagingStore(unisonDir: active)
        try begin(store, ["ar"+h])

        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        _ = AbandonedStagingScan.blockedHashes(abandoned, unisonDir: active)
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
             func release(hash: String) -> Bool { true }
            func identity(hash: String) -> LockIdentity? {
                LockIdentity(dev: 1, ino: 1, ctimeSec: 0, ctimeNsec: 0)
            }
        }
        let out = try ArchiveMutation.execute(
            operation: "clean-stale", hashes: [h], nowISO8601: "2026-08-23T00:00:00Z",
            isEngineIdle: { true },
            fileExists: { self.exists(active, $0) },
            revalidate: { XCTAssertEqual(Set($0.payloadFiles), Set(["ar"+h, "fp"+h])); return true },
            locking: NoopLocking(), store: store)

        XCTAssertNil(out.quarantineRetained)
        XCTAssertEqual(fm.trashed.count, 1, "one whole-dir Trash")
        XCTAssertFalse(exists(active, "ar"+h)); XCTAssertFalse(exists(active, "fp"+h))
        XCTAssertTrue(AbandonedStagingScan.find(inUnisonDir: active).isEmpty,
                      "no abandoned staging remains after a clean commit")
    }

    // Coverage: a selected Clean-Stale row whose family has an on-disk lock
    // (lk<hash>) while the engine is IDLE. A pre-existing lock means a live Unison
    // or a stale lock holds the family, so acquire returns .alreadyHeld and the
    // removal must REFUSE — trashing nothing and leaving the ENTIRE family (ar,
    // fp, AND lk) intact, not trashing ar/fp while retaining lk.
    func test_integration_foreignLockOnDisk_atIdle_refusesAndKeepsWholeFamily() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h); write(active, "fp"+h); write(active, "lk"+h)
        let fm = RecordingTrashFM()
        let store = POSIXStagingStore(unisonDir: active, fileManager: fm)

        // A pre-existing lock: real acquisition reports it held by another.
        final class ForeignLocking: ArchiveLocking {
            func acquire(hash: String) -> ArchiveLock.AcquireResult { .alreadyHeld }
            func release(hash: String) -> Bool { true }
            func identity(hash: String) -> LockIdentity? { nil }
        }
        XCTAssertThrowsError(try ArchiveMutation.execute(
            operation: "clean-stale", hashes: [h], nowISO8601: "2026-08-23T00:00:00Z",
            isEngineIdle: { true },
            fileExists: { self.exists(active, $0) },
            revalidate: { _ in XCTFail("must not stage while the lock is held"); return false },
            locking: ForeignLocking(), store: store)) { error in
            guard case ArchiveMutationError.lockUnavailable(_, let reason) = error else {
                return XCTFail("expected .lockUnavailable, got \(error)")
            }
            XCTAssertEqual(reason, .alreadyHeld)
        }

        XCTAssertEqual(fm.trashed.count, 0, "nothing is trashed when the lock is held")
        XCTAssertTrue(exists(active, "ar"+h)); XCTAssertTrue(exists(active, "fp"+h))
        XCTAssertTrue(exists(active, "lk"+h),
                      "the whole family, including the lock, is preserved")
    }

    // MARK: SF1 — an intent record written BEFORE locks is detectable on restart

    func test_abandonedAcquiringIntent_isDetected_blocksOnlyIfLocked() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        let store = POSIXStagingStore(unisonDir: active)
        // Intent recorded, but the process "dies" before recordPlan/staging.
        try store.beginIntent(manifest([], phase: StagingManifest.phaseAcquiring))

        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(abandoned.first?.manifest.phase, StagingManifest.phaseAcquiring)
        // No lock present yet → nothing to block (no family split, no lock held).
        XCTAssertTrue(AbandonedStagingScan.blockedHashes(abandoned, unisonDir: active).isEmpty)
        // A surviving lock from the interrupted acquisition → blocks that hash.
        write(active, "lk"+h)
        XCTAssertEqual(AbandonedStagingScan.blockedHashes(abandoned, unisonDir: active), [h],
                       "an acquiring record whose lock survived blocks its hash")
    }

    // SF3: an unrecognized record (unknown phase or future version) blocks its
    // hashes even with NO lock on disk — fail closed for manual review.
    func test_blockedHashes_unrecognizedRecord_alwaysBlocks_evenLockFree() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        // Unknown phase, no lk present.
        let store = POSIXStagingStore(unisonDir: active)
        try store.beginIntent(manifest([], phase: "frobnicate"))
        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(AbandonedStagingScan.blockedHashes(abandoned, unisonDir: active), [h],
                       "unknown phase blocks despite no lock (fail closed)")

        // A future version likewise blocks.
        let active2 = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active2) }
        var future = manifest([], phase: StagingManifest.phaseCommitted)
        future.version = StagingManifest.currentVersion + 1
        let store2 = POSIXStagingStore(unisonDir: active2)
        try store2.beginIntent(future)
        let ab2 = AbandonedStagingScan.find(inUnisonDir: active2)
        XCTAssertEqual(AbandonedStagingScan.blockedHashes(ab2, unisonDir: active2), [h],
                       "future version blocks despite no lock (fail closed)")
    }

    func test_discardRecord_removesQuarantine() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        let store = POSIXStagingStore(unisonDir: active)
        try store.beginIntent(manifest([], phase: StagingManifest.phaseAcquiring))
        let q = try XCTUnwrap(store.quarantinePath)
        try store.discardRecord()
        XCTAssertFalse(FileManager.default.fileExists(atPath: q))
        XCTAssertNil(store.quarantinePath)
    }

    // SF1: discardRecord failure PROPAGATES, RETAINS in-memory state, and flips the
    // on-disk staging record to a non-blocking phase so the leftover never blocks.
    func test_discardRecord_removalFailure_propagates_retains_andLeavesNonBlocking() throws {
        let active = try makeTempDir(); defer { try? FileManager.default.removeItem(atPath: active) }
        write(active, "ar"+h)
        let store = POSIXStagingStore(unisonDir: active, fileManager: FailDirRemoveFM())
        try begin(store, ["ar"+h])          // phase = staging
        let q = try XCTUnwrap(store.quarantinePath)
        try store.stage("ar"+h)
        try store.rollback()                // family restored; record kept
        XCTAssertThrowsError(try store.discardRecord()) {
            XCTAssertEqual($0 as? ArchiveStoreError, .discardFailed(q))
        }
        XCTAssertEqual(store.quarantinePath, q, "in-memory state retained — no false success")
        XCTAssertTrue(FileManager.default.fileExists(atPath: q), "undeletable quarantine remains")
        // The leftover is now a lock-free, non-blocking record.
        let abandoned = AbandonedStagingScan.find(inUnisonDir: active)
        XCTAssertEqual(abandoned.first?.manifest.phase, StagingManifest.phaseAborted)
        XCTAssertTrue(AbandonedStagingScan.blockedHashes(abandoned, unisonDir: active).isEmpty,
                      "an aborted, lock-free leftover does not permanently block")
    }
}
