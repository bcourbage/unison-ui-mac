import XCTest
@testable import unison_ui_mac

/// Transaction integrity for the single archive-mutation authority. Covers the
/// review's required invariants: exactly-one-acquirer contention, lock-failure
/// and revalidation-failure release-and-touch-nothing, failure before/during/
/// after staging, rollback restores every staged file, multi-hash atomicity,
/// pre-existing locks untouched, `lk` never in payloads, and only-owned-locks
/// released. Logic is tested with fakes; one case uses the REAL lock bridge for
/// genuine on-disk contention.
final class ArchiveMutationTransactionTests: XCTestCase {

    // MARK: fakes

    private final class FakeLocking: ArchiveLocking {
        var heldByOthers: Set<String> = []   // simulate foreign/contended locks
        private(set) var acquired: [String] = []
        private(set) var released: [String] = []
        func acquire(hash: String) -> ArchiveLock.AcquireResult {
            if heldByOthers.contains(hash) { return .alreadyHeld }
            acquired.append(hash); return .acquired
        }
        func release(hash: String) { released.append(hash) }
    }

    private enum StoreErr: Error { case stage, commit, missing }

    /// Models the on-disk state: `present` = at original location, `staged` =
    /// renamed into staging, `trashed` = committed to Trash.
    private final class FakeStore: ArchivePayloadStore {
        private(set) var present: Set<String>
        private(set) var staged: Set<String> = []
        private(set) var trashed: [String] = []
        var stageFailAt: Int?    // fail the Nth stage() call (1-based)
        var commitFailAt: Int?   // fail the Nth commit() call (1-based)
        private var nStage = 0
        private var nCommit = 0
        init(present: Set<String>) { self.present = present }
        func stage(_ name: String) throws {
            nStage += 1
            if stageFailAt == nStage { throw StoreErr.stage }
            guard present.remove(name) != nil else { throw StoreErr.missing }
            staged.insert(name)
        }
        func unstage(_ name: String) throws {
            guard staged.remove(name) != nil else { throw StoreErr.missing }
            present.insert(name)
        }
        func commit(_ name: String) throws {
            nCommit += 1
            if commitFailAt == nCommit { throw StoreErr.commit }
            guard staged.remove(name) != nil else { throw StoreErr.missing }
            trashed.append(name)
        }
    }

    private func plan(_ hashes: [String], _ files: [String]) -> ArchiveMutationPlan {
        ArchiveMutationPlan(hashes: hashes, payloadFiles: files)
    }

    // MARK: happy path

    func test_success_stagesThenTrashesAll_releasesOwnedOnly() throws {
        let h = String(repeating: "a", count: 32)
        let files = ["ar"+h, "fp"+h]
        let store = FakeStore(present: Set(files))
        let lock = FakeLocking()
        let out = try ArchiveMutation.execute(
            plan: plan([h], files), isEngineIdle: { true }, revalidate: { true },
            locking: lock, store: store)
        XCTAssertEqual(Set(out.trashed), Set(files))
        XCTAssertEqual(out.commitFailures, [])
        XCTAssertTrue(store.present.isEmpty, "original location cleared")
        XCTAssertEqual(Set(store.trashed), Set(files))
        XCTAssertEqual(lock.acquired, [h])
        XCTAssertEqual(lock.released, [h], "released exactly the owned lock")
    }

    // MARK: guards touch nothing

    func test_notIdle_throws_touchesNothing() {
        let h = String(repeating: "a", count: 32)
        let store = FakeStore(present: ["ar"+h]); let lock = FakeLocking()
        XCTAssertThrowsError(try ArchiveMutation.execute(
            plan: plan([h], ["ar"+h]), isEngineIdle: { false }, revalidate: { true },
            locking: lock, store: store)) { XCTAssertEqual($0 as? ArchiveMutationError, .engineNotIdle) }
        XCTAssertEqual(lock.acquired, []); XCTAssertEqual(store.present, ["ar"+h]); XCTAssertEqual(store.trashed, [])
    }

    func test_lockAcquisitionFailure_releasesEarlier_touchesNoPayload() {
        let h1 = String(repeating: "1", count: 32), h2 = String(repeating: "2", count: 32)
        let files = ["ar"+h1, "ar"+h2]
        let store = FakeStore(present: Set(files))
        let lock = FakeLocking(); lock.heldByOthers = [h2]     // second lock contended
        XCTAssertThrowsError(try ArchiveMutation.execute(
            plan: plan([h1, h2], files), isEngineIdle: { true }, revalidate: { true },
            locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .lockUnavailable(hash: h2, reason: .alreadyHeld))
        }
        XCTAssertEqual(lock.acquired, [h1])
        XCTAssertEqual(lock.released, [h1], "the earlier lock is released")
        XCTAssertEqual(store.present, Set(files), "no payload touched")
        XCTAssertEqual(store.trashed, [])
    }

    func test_revalidationFailure_releasesLocks_touchesNothing() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h, "fp"+h]
        let store = FakeStore(present: Set(files)); let lock = FakeLocking()
        XCTAssertThrowsError(try ArchiveMutation.execute(
            plan: plan([h], files), isEngineIdle: { true }, revalidate: { false },
            locking: lock, store: store)) { XCTAssertEqual($0 as? ArchiveMutationError, .revalidationFailed) }
        XCTAssertEqual(lock.acquired, [h]); XCTAssertEqual(lock.released, [h])
        XCTAssertEqual(store.present, Set(files)); XCTAssertEqual(store.trashed, [])
    }

    // MARK: staging failure + rollback

    func test_stagingFailure_beforeAnyStage_touchesNothing() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h, "fp"+h]
        let store = FakeStore(present: Set(files)); store.stageFailAt = 1
        let lock = FakeLocking()
        XCTAssertThrowsError(try ArchiveMutation.execute(
            plan: plan([h], files), isEngineIdle: { true }, revalidate: { true },
            locking: lock, store: store)) {
            guard case .stagingFailed = ($0 as? ArchiveMutationError) else { return XCTFail("wrong error") }
        }
        XCTAssertEqual(store.present, Set(files), "nothing staged remains removed")
        XCTAssertEqual(store.trashed, []); XCTAssertEqual(lock.released, [h])
    }

    func test_stagingFailure_midway_rollsBackEveryStagedFile() {
        let h = String(repeating: "a", count: 32)
        let files = ["ar"+h, "fp"+h, "sc"+h]           // 3 files
        let store = FakeStore(present: Set(files)); store.stageFailAt = 2   // file 1 staged, file 2 fails
        let lock = FakeLocking()
        XCTAssertThrowsError(try ArchiveMutation.execute(
            plan: plan([h], files), isEngineIdle: { true }, revalidate: { true },
            locking: lock, store: store))
        XCTAssertEqual(store.present, Set(files), "rollback restored EVERY already-staged file")
        XCTAssertTrue(store.staged.isEmpty, "nothing left in staging after rollback")
        XCTAssertEqual(store.trashed, [])
        XCTAssertEqual(lock.released, [h])
    }

    // MARK: commit failure — no partial family at the ORIGINAL location

    func test_commitFailure_leavesFileInStaging_notAtOriginal_noPartialFamily() throws {
        let h = String(repeating: "a", count: 32)
        let files = ["ar"+h, "fp"+h, "sc"+h]
        let store = FakeStore(present: Set(files)); store.commitFailAt = 2   // 2nd commit fails
        let lock = FakeLocking()
        let out = try ArchiveMutation.execute(
            plan: plan([h], files), isEngineIdle: { true }, revalidate: { true },
            locking: lock, store: store)
        XCTAssertEqual(out.commitFailures.count, 1, "one file failed to reach Trash")
        XCTAssertTrue(store.present.isEmpty, "the ORIGINAL location has no partial family")
        XCTAssertEqual(store.staged.count, 1, "the un-trashed file is recoverable in staging")
        XCTAssertEqual(store.trashed.count, 2)
        XCTAssertEqual(lock.released, [h])
    }

    // MARK: multi-hash atomicity + only-owned + lk-exclusion

    func test_localToLocal_multiHashReset_isOnePlan_allOrNothing() {
        // Two hashes (as a local↔local reset produces); the 2nd lock contended.
        let h1 = String(repeating: "1", count: 32), h2 = String(repeating: "2", count: 32)
        let files = ["ar"+h1, "fp"+h1, "ar"+h2, "fp"+h2]
        let store = FakeStore(present: Set(files))
        let lock = FakeLocking(); lock.heldByOthers = [h2]
        XCTAssertThrowsError(try ArchiveMutation.execute(
            plan: plan([h1, h2], files), isEngineIdle: { true }, revalidate: { true },
            locking: lock, store: store))
        XCTAssertEqual(store.present, Set(files), "no hash's family removed — the plan is atomic")
        XCTAssertEqual(store.trashed, [])
        XCTAssertEqual(lock.released, lock.acquired, "released == acquired (owned only)")
    }

    func test_preExistingForeignLock_notInPlan_isNeverReleased() {
        let h = String(repeating: "a", count: 32)
        let foreign = String(repeating: "f", count: 32)
        let store = FakeStore(present: ["ar"+h])
        let lock = FakeLocking(); lock.heldByOthers = [foreign]   // foreign lock, not in plan
        _ = try? ArchiveMutation.execute(
            plan: plan([h], ["ar"+h]), isEngineIdle: { true }, revalidate: { true },
            locking: lock, store: store)
        XCTAssertFalse(lock.released.contains(foreign), "a foreign lock is never released")
        XCTAssertEqual(lock.released, [h])
    }

    func test_planExcludesLk_evenWhenLkFileExists() {
        let h = String(repeating: "a", count: 32)
        // fileExists says every prefix (including lk) is present.
        let p = ArchiveMutationPlan(hashes: [h], fileExists: { _ in true })
        XCTAssertFalse(p.payloadFiles.contains("lk"+h), "lk is never a payload")
        XCTAssertEqual(Set(p.payloadFiles), Set(["ar"+h, "fp"+h, "sc"+h, "tm"+h]))
    }

    func test_planIsDeterministicallyOrdered() {
        let hi = "ffffffffffffffffffffffffffffffff", lo = "00000000000000000000000000000000"
        let p = ArchiveMutationPlan(hashes: [hi, lo], fileExists: { $0.hasPrefix("ar") })
        XCTAssertEqual(p.hashes, [lo, hi])
        XCTAssertEqual(p.payloadFiles, ["ar"+lo, "ar"+hi])
    }

    // MARK: real-lock contention (two holders, exactly one acquires)

    func test_realLock_contention_exactlyOneAcquires_andTouchesNoPayload() {
        // Seed a foreign lock on disk (as another process's acquire would).
        let h = "c0ffee00c0ffee00c0ffee00c0ffee00"
        let dir = String(cString: unison_bridge_unison_directory())
        let lk = dir + "/lk" + h
        FileManager.default.createFile(atPath: lk, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: lk) }

        let store = FakeStore(present: ["ar"+h])   // if touched, the assert below fails
        XCTAssertThrowsError(try ArchiveMutation.execute(
            plan: plan([h], ["ar"+h]), isEngineIdle: { true }, revalidate: { true },
            locking: SystemArchiveLocking(), store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .lockUnavailable(hash: h, reason: .alreadyHeld))
        }
        XCTAssertEqual(store.present, ["ar"+h], "the transaction that lost the race touched no payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lk), "the foreign lock was not removed")
    }
}
