import XCTest
@testable import unison_ui_mac

/// Transaction integrity for the single archive-mutation authority (phase model:
/// acquire → durable manifest → stage via rename → rollback-on-failure →
/// whole-dir Trash, retain on cleanup failure). Logic is tested with fakes; one
/// case uses the REAL lock bridge for genuine on-disk contention. Crash-safe
/// production behavior (real rename, whole-dir Trash, restart detection) is in
/// ArchiveStagingStoreTests.
final class ArchiveMutationTransactionTests: XCTestCase {

    private final class FakeLocking: ArchiveLocking {
        var heldByOthers: Set<String> = []
        private(set) var acquired: [String] = []
        private(set) var released: [String] = []
        var releaseConfirmed = true   // whether release() reports the lock gone
        func acquire(hash: String) -> ArchiveLock.AcquireResult {
            if heldByOthers.contains(hash) { return .alreadyHeld }
            acquired.append(hash); return .acquired
        }
        @discardableResult func release(hash: String) -> Bool {
            released.append(hash); return releaseConfirmed
        }
    }

    private enum StoreErr: Error { case begin, stage, commit, missing }

    private final class FakeStore: ArchivePayloadStore {
        private(set) var present: Set<String>
        private(set) var staged: Set<String> = []
        private(set) var committedWholeDir = false
        private(set) var rolledBack = false
        private(set) var manifest: StagingManifest?
        var quarantinePath: String? = "/fake/quarantine"
        var beginFail = false
        var stageFailAt: Int?
        var commitFail = false
        var rollbackThrows = false   // simulate an incomplete restore
        private var nStage = 0
        init(present: Set<String>) { self.present = present }
        func beginStaging(_ m: StagingManifest) throws {
            if beginFail { throw StoreErr.begin }
            manifest = m
        }
        func stage(_ name: String) throws {
            nStage += 1
            if stageFailAt == nStage { throw StoreErr.stage }
            guard present.remove(name) != nil else { throw StoreErr.missing }
            staged.insert(name)
        }
        func rollback() throws {
            rolledBack = true
            if rollbackThrows {
                // Incomplete restore: retain the quarantine (keep staged, keep
                // manifest); do NOT restore to present.
                throw StoreErr.missing
            }
            for n in staged { present.insert(n) }
            staged.removeAll()
            manifest = nil
        }
        private(set) var markedCommitted = false
        func markCommitted() throws { markedCommitted = true }
        func trashQuarantine() throws {
            if commitFail { throw StoreErr.commit }   // retain quarantine; keep staged
            committedWholeDir = true
            staged.removeAll()
            manifest = nil
        }
    }

    private func plan(_ hashes: [String], _ files: [String]) -> ArchiveMutationPlan {
        ArchiveMutationPlan(hashes: hashes, payloadFiles: files)
    }

    private func run(_ plan: ArchiveMutationPlan, idle: Bool = true,
                     revalidate: @escaping (ArchiveMutationPlan) -> Bool = { _ in true },
                     locking: ArchiveLocking, store: ArchivePayloadStore) throws -> ArchiveMutationOutcome {
        // The transaction now derives the payload set UNDER the locks from a
        // `fileExists` probe; feed the fixture plan's payloadFiles as "what
        // exists", so the re-derived plan matches.
        try ArchiveMutation.execute(operation: "test", hashes: plan.hashes,
                                    nowISO8601: "2026-08-23T00:00:00Z",
                                    isEngineIdle: { idle },
                                    fileExists: { plan.payloadFiles.contains($0) },
                                    revalidate: revalidate,
                                    locking: locking, store: store)
    }

    // MARK: happy path

    func test_success_stagesThenWholeDirTrash_releasesOwnedOnly() throws {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h, "fp"+h]
        let store = FakeStore(present: Set(files)); let lock = FakeLocking()
        let out = try run(plan([h], files), locking: lock, store: store)
        XCTAssertNil(out.quarantineRetained)
        XCTAssertTrue(store.committedWholeDir, "whole staging dir committed as one unit")
        XCTAssertTrue(store.present.isEmpty, "original location cleared")
        XCTAssertEqual(lock.acquired, [h]); XCTAssertEqual(lock.released, [h])
    }

    // MARK: guards — nothing staged, no manifest

    func test_notIdle_touchesNothing_noManifest() {
        let h = String(repeating: "a", count: 32)
        let store = FakeStore(present: ["ar"+h]); let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], ["ar"+h]), idle: false, locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .engineNotIdle)
        }
        XCTAssertEqual(lock.acquired, []); XCTAssertNil(store.manifest); XCTAssertEqual(store.present, ["ar"+h])
    }

    func test_lockAcquisitionFailure_releasesEarlier_noManifest_noPayloadTouch() {
        let h1 = String(repeating: "1", count: 32), h2 = String(repeating: "2", count: 32)
        let files = ["ar"+h1, "ar"+h2]
        let store = FakeStore(present: Set(files))
        let lock = FakeLocking(); lock.heldByOthers = [h2]
        XCTAssertThrowsError(try run(plan([h1, h2], files), locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .lockUnavailable(hash: h2, reason: .alreadyHeld))
        }
        XCTAssertEqual(lock.acquired, [h1]); XCTAssertEqual(lock.released, [h1])
        XCTAssertNil(store.manifest, "manifest is written only after locks + revalidate")
        XCTAssertEqual(store.present, Set(files))
    }

    func test_revalidationFailure_releases_noManifest_touchesNothing() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h]
        let store = FakeStore(present: Set(files)); let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), revalidate: { _ in false }, locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .revalidationFailed)
        }
        XCTAssertNil(store.manifest); XCTAssertEqual(store.present, Set(files)); XCTAssertEqual(lock.released, [h])
    }

    func test_beginStagingFailure_releasesLocks_touchesNothing() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h]
        let store = FakeStore(present: Set(files)); store.beginFail = true
        let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .beginStagingFailed)
        }
        XCTAssertEqual(store.present, Set(files)); XCTAssertEqual(lock.released, [h])
    }

    // MARK: staging failure + rollback

    func test_stagingFailure_midway_rollsBackAll_removesManifest() {
        let h = String(repeating: "a", count: 32)
        let files = ["ar"+h, "fp"+h, "sc"+h]
        let store = FakeStore(present: Set(files)); store.stageFailAt = 2
        let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), locking: lock, store: store)) {
            guard case .stagingFailed = ($0 as? ArchiveMutationError) else { return XCTFail("wrong error") }
        }
        XCTAssertTrue(store.rolledBack)
        XCTAssertEqual(store.present, Set(files), "rollback restored every already-staged file")
        XCTAssertTrue(store.staged.isEmpty); XCTAssertNil(store.manifest)
        XCTAssertEqual(lock.released, [h])
    }

    // MARK: staging failure whose rollback ALSO fails — keep locks HELD, retain

    func test_stagingFailure_rollbackAlsoFails_keepsLocksHeld_retainsQuarantine() {
        let h = String(repeating: "a", count: 32)
        let files = ["ar"+h, "fp"+h, "sc"+h]
        let store = FakeStore(present: Set(files))
        store.stageFailAt = 2       // f1 staged, f2 fails → rollback…
        store.rollbackThrows = true // …which cannot fully restore
        let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError,
                           .rollbackIncomplete(quarantine: "/fake/quarantine"))
        }
        XCTAssertEqual(lock.acquired, [h])
        XCTAssertEqual(lock.released, [], "locks stay HELD after an incomplete rollback")
        XCTAssertNotNil(store.manifest, "manifest retained (still pre-commit)")
    }

    // MARK: commit (Trash) failure — no partial family at origin, retained quarantine

    func test_commitCleanupFailure_retainsQuarantine_noPartialFamilyAtOrigin() throws {
        let h = String(repeating: "a", count: 32)
        let files = ["ar"+h, "fp"+h, "sc"+h]
        let store = FakeStore(present: Set(files)); store.commitFail = true
        let lock = FakeLocking()
        let out = try run(plan([h], files), locking: lock, store: store)
        XCTAssertEqual(out.quarantineRetained, "/fake/quarantine", "retained quarantine reported")
        XCTAssertFalse(store.committedWholeDir)
        XCTAssertTrue(store.present.isEmpty, "the ORIGINAL location has no partial family")
        XCTAssertEqual(store.staged, Set(files), "the whole family is safe in the retained quarantine")
        XCTAssertEqual(lock.released, [h], "locks released BEFORE the Trash attempt")
        XCTAssertEqual(out.locksNotReleased, [], "locks were released; leftover is non-blocking")
    }

    // MARK: SF3 — a lock that can't be confirmed released keeps a BLOCKING record

    func test_lockReleaseUnconfirmed_retainsBlockingQuarantine_notTrashed() throws {
        let h = String(repeating: "a", count: 32)
        let files = ["ar"+h, "fp"+h]
        let store = FakeStore(present: Set(files))
        let lock = FakeLocking(); lock.releaseConfirmed = false   // release can't be confirmed
        let out = try run(plan([h], files), locking: lock, store: store)
        XCTAssertEqual(out.locksNotReleased, [h], "unconfirmed release reported as blocking")
        XCTAssertEqual(out.quarantineRetained, "/fake/quarantine", "committed quarantine retained")
        XCTAssertFalse(store.committedWholeDir, "NOT trashed while a lock may survive")
        XCTAssertTrue(store.markedCommitted, "manifest durably marked committed before release")
        XCTAssertTrue(store.present.isEmpty, "family removed from the active dir (committed)")
        XCTAssertEqual(lock.released, [h], "release was attempted")
    }

    // MARK: Blocker 2 — payload set derived UNDER the locks

    func test_payloadSet_derivedUnderLocks_capturesSiblingAddedAtAcquire() throws {
        let h = String(repeating: "a", count: 32)
        // Pre-lock, only ar exists; an external Unison creates fp at the moment
        // we acquire the lock. Deriving the plan AFTER acquisition must see fp.
        final class SideEffectLocking: ArchiveLocking {
            let onAcquire: () -> Void
            init(_ f: @escaping () -> Void) { onAcquire = f }
            func acquire(hash: String) -> ArchiveLock.AcquireResult { onAcquire(); return .acquired }
             func release(hash: String) -> Bool { true }
        }
        var existing: Set<String> = ["ar"+h]
        let store = FakeStore(present: ["ar"+h, "fp"+h])
        var derived: [String] = []
        _ = try ArchiveMutation.execute(
            operation: "test", hashes: [h], nowISO8601: "t",
            isEngineIdle: { true },
            fileExists: { existing.contains($0) },
            revalidate: { derived = $0.payloadFiles; return true },
            locking: SideEffectLocking { existing.insert("fp"+h) },
            store: store)
        XCTAssertEqual(Set(derived), Set(["ar"+h, "fp"+h]),
                       "payload set is frozen only after locks — captures the added sibling")
    }

    // MARK: multi-hash atomicity, foreign-lock, lk-exclusion, ordering

    func test_localToLocal_multiHash_isOnePlan_allOrNothing() {
        let h1 = String(repeating: "1", count: 32), h2 = String(repeating: "2", count: 32)
        let files = ["ar"+h1, "fp"+h1, "ar"+h2, "fp"+h2]
        let store = FakeStore(present: Set(files))
        let lock = FakeLocking(); lock.heldByOthers = [h2]
        XCTAssertThrowsError(try run(plan([h1, h2], files), locking: lock, store: store))
        XCTAssertEqual(store.present, Set(files), "no hash's family removed — atomic plan")
        XCTAssertEqual(lock.released, lock.acquired, "released == acquired (owned only)")
    }

    func test_foreignLock_notInPlan_isNeverReleased() {
        let h = String(repeating: "a", count: 32); let foreign = String(repeating: "f", count: 32)
        let store = FakeStore(present: ["ar"+h])
        let lock = FakeLocking(); lock.heldByOthers = [foreign]
        _ = try? run(plan([h], ["ar"+h]), locking: lock, store: store)
        XCTAssertFalse(lock.released.contains(foreign)); XCTAssertEqual(lock.released, [h])
    }

    func test_planExcludesLk_evenWhenLkExists() {
        let h = String(repeating: "a", count: 32)
        let p = ArchiveMutationPlan(hashes: [h], fileExists: { _ in true })
        XCTAssertFalse(p.payloadFiles.contains("lk"+h))
        XCTAssertEqual(Set(p.payloadFiles), Set(["ar"+h, "fp"+h, "sc"+h, "tm"+h]))
    }

    func test_planDeterministicOrder() {
        let hi = "ffffffffffffffffffffffffffffffff", lo = "00000000000000000000000000000000"
        let p = ArchiveMutationPlan(hashes: [hi, lo], fileExists: { $0.hasPrefix("ar") })
        XCTAssertEqual(p.hashes, [lo, hi]); XCTAssertEqual(p.payloadFiles, ["ar"+lo, "ar"+hi])
    }

    // MARK: real-lock contention — exactly one acquires

    func test_realLock_contention_loserTouchesNoPayload() {
        let h = "c0ffee00c0ffee00c0ffee00c0ffee00"
        let dir = String(cString: unison_bridge_unison_directory())
        let lk = dir + "/lk" + h
        FileManager.default.createFile(atPath: lk, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: lk) }
        let store = FakeStore(present: ["ar"+h])
        XCTAssertThrowsError(try run(plan([h], ["ar"+h]), locking: SystemArchiveLocking(), store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .lockUnavailable(hash: h, reason: .alreadyHeld))
        }
        XCTAssertEqual(store.present, ["ar"+h]); XCTAssertNil(store.manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lk), "foreign lock not removed")
    }

    // SF3: production branches on `disposition`, so lock in the mapping. The two
    // retained states are NOT the same — only the lock-free one may be deleted.
    func test_disposition_distinguishesRetainedStates() {
        XCTAssertEqual(ArchiveMutationOutcome(hashes: ["a"], quarantineRetained: nil).disposition,
                       .clean)
        XCTAssertEqual(ArchiveMutationOutcome(hashes: ["a"], quarantineRetained: "/q").disposition,
                       .lockFreeLeftover(quarantine: "/q"),
                       "retained with every lock released → safe-to-delete leftover")
        XCTAssertEqual(ArchiveMutationOutcome(hashes: ["a"], quarantineRetained: "/q",
                                              locksNotReleased: ["a"]).disposition,
                       .blockedByLock(quarantine: "/q", hashes: ["a"]),
                       "retained with a surviving lock → blocking record, never delete")
    }
}
