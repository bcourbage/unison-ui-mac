import XCTest
@testable import unison_ui_mac

/// Transaction integrity for the single archive-mutation authority (phase model:
/// durable intent BEFORE locks → acquire → record plan under locks → stage via
/// rename → rollback-then-release-then-discard on failure → whole-dir Trash,
/// retain on cleanup failure; the record is removed only after confirmed release).
/// Logic is tested with fakes; one case uses the REAL lock bridge for genuine
/// on-disk contention. Crash-safe production behavior (real rename, whole-dir
/// Trash, restart detection) is in ArchiveStagingStoreTests.
final class ArchiveMutationTransactionTests: XCTestCase {

    private final class FakeLocking: ArchiveLocking {
        var heldByOthers: Set<String> = []
        /// Force a specific non-acquired result for a hash (exception/invalidHash/…).
        var failWith: [String: ArchiveLock.AcquireResult] = [:]
        private(set) var acquired: [String] = []
        private(set) var released: [String] = []
        var releaseConfirmed = true   // whether release() reports the lock gone
        func acquire(hash: String) -> ArchiveLock.AcquireResult {
            if let forced = failWith[hash] { return forced }
            if heldByOthers.contains(hash) { return .alreadyHeld }
            acquired.append(hash); return .acquired
        }
        @discardableResult func release(hash: String) -> Bool {
            released.append(hash); return releaseConfirmed
        }
    }

    private enum StoreErr: Error { case begin, plan, stage, commit, missing, discard }

    private final class FakeStore: ArchivePayloadStore {
        private(set) var present: Set<String>
        private(set) var staged: Set<String> = []
        private(set) var committedWholeDir = false
        private(set) var rolledBack = false
        private(set) var discarded = false
        private(set) var manifest: StagingManifest?
        var quarantinePath: String? = "/fake/quarantine"
        var beginFail = false        // beginIntent fails (BEFORE any lock)
        var recordPlanFail = false   // recordPlan fails (after locks, before staging)
        var stageFailAt: Int?
        var commitFail = false
        var rollbackThrows = false   // simulate an incomplete restore
        var discardThrows = false    // simulate the quarantine removal failing
        private var nStage = 0
        init(present: Set<String>) { self.present = present }
        func beginIntent(_ m: StagingManifest) throws {
            if beginFail { throw StoreErr.begin }
            manifest = m   // durable intent record, phase acquiring
        }
        func recordPlan(_ m: StagingManifest) throws {
            if recordPlanFail { throw StoreErr.plan }
            manifest = m   // acquiring → staging, with the payload plan
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
            // NOTE: the record is NOT removed here — that is `discardRecord`, gated
            // on confirmed lock release (SF1).
        }
        func discardRecord() throws {
            if discardThrows {
                // Propagate + RETAIN state (never lie about success). A real store
                // also flips the on-disk record to a non-blocking phase first.
                throw StoreErr.discard
            }
            discarded = true
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
        XCTAssertNil(store.manifest, "intent record discarded once the acquired lock is released")
        XCTAssertTrue(store.discarded, "record removed only after confirmed release")
        XCTAssertEqual(store.present, Set(files))
    }

    func test_revalidationFailure_releases_discardsRecord_touchesNothing() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h]
        let store = FakeStore(present: Set(files)); let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), revalidate: { _ in false }, locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .revalidationFailed)
        }
        XCTAssertNil(store.manifest); XCTAssertTrue(store.discarded)
        XCTAssertEqual(store.present, Set(files)); XCTAssertEqual(lock.released, [h])
    }

    // SF1: the intent record is written BEFORE any lock, so a failure to write it
    // means no lock was ever acquired — nothing to release, nothing to detect.
    func test_beginIntentFailure_beforeAnyLock_touchesNothing() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h]
        let store = FakeStore(present: Set(files)); store.beginFail = true
        let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .beginStagingFailed)
        }
        XCTAssertEqual(store.present, Set(files))
        XCTAssertEqual(lock.acquired, [], "no lock acquired before the intent record exists")
        XCTAssertEqual(lock.released, [])
    }

    // SF1: recordPlan runs AFTER locks are held; a failure there releases the
    // held locks and discards the intent record (no orphaned lock).
    func test_recordPlanFailure_afterLocks_releasesAndDiscards() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h]
        let store = FakeStore(present: Set(files)); store.recordPlanFail = true
        let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError, .beginStagingFailed)
        }
        XCTAssertEqual(lock.acquired, [h]); XCTAssertEqual(lock.released, [h])
        XCTAssertTrue(store.discarded); XCTAssertNil(store.manifest)
        XCTAssertEqual(store.present, Set(files))
    }

    // SF2: if a held lock cannot be confirmed released on an early-exit path, the
    // intent record is RETAINED and the transaction PROPAGATES a retained-lock
    // outcome (not the bare revalidation error) so the app refreshes the block.
    func test_revalidationFailure_unconfirmedRelease_propagatesRetainedLock() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h]
        let store = FakeStore(present: Set(files))
        let lock = FakeLocking(); lock.releaseConfirmed = false
        XCTAssertThrowsError(try run(plan([h], files), revalidate: { _ in false }, locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError,
                           .lockRetainedAfterAbort(hashes: [h], quarantine: "/fake/quarantine"))
        }
        XCTAssertFalse(store.discarded, "record retained because release was not confirmed")
        XCTAssertNotNil(store.manifest, "leftover lock stays detectable on restart")
    }

    // SF1: record deletion fails AFTER a successful rollback and release. The
    // transaction must surface a lock-free cleanup condition (not lie about a
    // clean discard), and the store must retain its in-memory state.
    func test_stagingFailure_discardFailsAfterRelease_surfacesLockFreeLeftover() {
        let h = String(repeating: "a", count: 32); let files = ["ar"+h, "fp"+h]
        let store = FakeStore(present: Set(files))
        store.stageFailAt = 2       // f1 staged, f2 fails → rollback restores all
        store.discardThrows = true  // …but the quarantine record can't be removed
        let lock = FakeLocking()
        XCTAssertThrowsError(try run(plan([h], files), locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError,
                           .abortedCleanupIncomplete(quarantine: "/fake/quarantine"))
        }
        XCTAssertTrue(store.rolledBack); XCTAssertEqual(lock.released, [h], "locks released")
        XCTAssertFalse(store.discarded, "discard did not succeed")
        XCTAssertNotNil(store.manifest, "store retained its in-memory record (no false success)")
    }

    // SF2: a FOREIGN lock caused acquisition to fail AND the intent folder can't be
    // removed. The transaction must NOT claim the archive is unlocked — it keeps the
    // `lockUnavailable` primary (a foreign lock still exists, and the acquiring
    // record blocks on restart), and that error requires a block refresh.
    func test_lockUnavailable_discardFailsAfterRelease_keepsLockUnavailablePrimary() {
        let h1 = String(repeating: "1", count: 32), h2 = String(repeating: "2", count: 32)
        let files = ["ar"+h1, "ar"+h2]
        let store = FakeStore(present: Set(files)); store.discardThrows = true
        let lock = FakeLocking(); lock.heldByOthers = [h2]   // foreign lock on h2
        XCTAssertThrowsError(try run(plan([h1, h2], files), locking: lock, store: store)) {
            XCTAssertEqual($0 as? ArchiveMutationError,
                           .lockUnavailable(hash: h2, reason: .alreadyHeld),
                           "foreign-lock primary preserved, not masked as 'unlocked'")
        }
        XCTAssertEqual(lock.released, [h1], "the app-owned lock was released")
        XCTAssertNotNil(store.manifest, "the intent record is retained (blocks on restart)")
    }

    // SF1/SF2: the block-refresh classifier — the lock-leaving failures require an
    // in-session refresh; the clean-abort failures do not. Only `.alreadyHeld`
    // among the lockUnavailable reasons proves a lock exists.
    func test_requiresArchiveBlockRefresh_classifier() {
        XCTAssertTrue(ArchiveMutationError.rollbackIncomplete(quarantine: "/q").requiresArchiveBlockRefresh)
        XCTAssertTrue(ArchiveMutationError.lockRetainedAfterAbort(hashes: ["a"], quarantine: "/q").requiresArchiveBlockRefresh)
        XCTAssertTrue(ArchiveMutationError.lockUnavailable(hash: "a", reason: .alreadyHeld).requiresArchiveBlockRefresh)
        // The non-alreadyHeld reasons leave the lock state UNKNOWN (not proven
        // absent), so they refresh conservatively too.
        XCTAssertTrue(ArchiveMutationError.lockUnavailable(hash: "a", reason: .exception).requiresArchiveBlockRefresh)
        XCTAssertTrue(ArchiveMutationError.lockUnavailable(hash: "a", reason: .invalidHash).requiresArchiveBlockRefresh)
        XCTAssertTrue(ArchiveMutationError.lockUnavailable(hash: "a", reason: .bridgeMissing).requiresArchiveBlockRefresh)
        XCTAssertFalse(ArchiveMutationError.revalidationFailed.requiresArchiveBlockRefresh)
        XCTAssertFalse(ArchiveMutationError.stagingFailed(file: "x").requiresArchiveBlockRefresh)
        XCTAssertFalse(ArchiveMutationError.beginStagingFailed.requiresArchiveBlockRefresh)
        XCTAssertFalse(ArchiveMutationError.engineNotIdle.requiresArchiveBlockRefresh)
        XCTAssertFalse(ArchiveMutationError.abortedCleanupIncomplete(quarantine: "/q").requiresArchiveBlockRefresh)
        // And the Error-typed classifier the callers actually use:
        XCTAssertTrue(CleanStaleArchivesWindowController.mutationRequiresBlockRefresh(
            ArchiveMutationError.rollbackIncomplete(quarantine: "/q")))
        XCTAssertFalse(CleanStaleArchivesWindowController.mutationRequiresBlockRefresh(
            ArchiveMutationError.revalidationFailed))
    }

    // SF2: a matrix over all four lock-acquisition failure reasons, each combined
    // with a discard failure. A failed acquisition never proves the lock ABSENT, so
    // EVERY reason preserves the lockUnavailable primary and requires a block
    // refresh — none is downgraded to a "lock-free leftover" that would falsely
    // claim the archive is unlocked.
    func test_lockFailureMatrix_everyReasonPreservesPrimary_neverClaimsUnlocked() {
        let reasons: [ArchiveLock.AcquireResult] = [.alreadyHeld, .exception, .invalidHash, .bridgeMissing]
        for reason in reasons {
            let h = String(repeating: "a", count: 32); let files = ["ar"+h]
            let store = FakeStore(present: Set(files)); store.discardThrows = true
            let lock = FakeLocking(); lock.failWith = [h: reason]
            XCTAssertThrowsError(try run(plan([h], files), locking: lock, store: store)) { err in
                XCTAssertEqual(err as? ArchiveMutationError,
                               .lockUnavailable(hash: h, reason: reason),
                               "\(reason): acquisition failure preserved, not masked as unlocked")
                XCTAssertTrue((err as? ArchiveMutationError)?.requiresArchiveBlockRefresh ?? false,
                              "\(reason): held or unknown → refresh the block")
            }
            XCTAssertNotNil(store.manifest, "record retained on every discard failure")
        }
    }

    // SF1: each lock-failure reason gets its own accurate diagnostic — only
    // `.alreadyHeld` mentions another Unison holding the archive.
    func test_mutationRefusalText_perLockReason() {
        func text(_ r: ArchiveLock.AcquireResult) -> String {
            CleanStaleArchivesWindowController.mutationRefusalText(
                ArchiveMutationError.lockUnavailable(hash: "a", reason: r))
        }
        XCTAssertTrue(text(.alreadyHeld).contains("Another Unison"))
        XCTAssertFalse(text(.exception).contains("Another Unison"))
        XCTAssertFalse(text(.invalidHash).contains("Another Unison"))
        XCTAssertFalse(text(.bridgeMissing).contains("Another Unison"))
        // Distinct, non-empty guidance for each.
        XCTAssertNotEqual(text(.exception), text(.bridgeMissing))
        XCTAssertFalse(text(.bridgeMissing).isEmpty)
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
