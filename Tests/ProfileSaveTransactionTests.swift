import XCTest
@testable import unison_ui_mac

/// Finding #11 — failure-safe, retry-consistent profile save/rename.
/// Every stage's failure is injected deterministically with an in-memory
/// `FakeFileOps` (no real files touched), and the resulting state is asserted
/// coherent + retryable. Happy paths are also exercised against the real
/// `SystemFileOps` in a temporary directory.
final class ProfileSaveTransactionTests: XCTestCase {

    private struct InjectedFault: Error {}

    /// In-memory filesystem. `files[path] = contents`; a fault can be injected
    /// on the first matching (op, path-suffix).
    private final class FakeFileOps: ProfileFileOps {
        var files: [String: String] = [:]
        private(set) var log: [String] = []
        /// One-shot faults; each matching (op, path-suffix) throws once and is
        /// consumed, so a retry can succeed. A list (not a single slot) lets a
        /// test inject a failure AND a subsequent rollback failure.
        var faults: [(op: String, suffix: String)] = []
        /// Convenience for the common single-fault case.
        var faultOn: (op: String, suffix: String)? {
            get { faults.first }
            set { faults = newValue.map { [$0] } ?? [] }
        }

        private func maybeFail(_ op: String, _ path: String) throws {
            if let i = faults.firstIndex(where: { $0.op == op && path.hasSuffix($0.suffix) }) {
                faults.remove(at: i)     // one-shot
                throw InjectedFault()
            }
        }
        /// Fires after each exists() result is computed. A test uses it to
        /// create the destination between the transaction's preliminary
        /// `exists` pre-check and the later exclusive install (the TOCTOU race).
        var afterExists: ((String) -> Void)?

        func exists(_ path: String) -> Bool {
            let r = files[path] != nil
            afterExists?(path)
            return r
        }
        func writeAtomic(_ content: String, to path: String) throws {
            try maybeFail("write", path); files[path] = content; log.append("write \(path)")
        }
        /// When true, a collision (destination exists) ALSO fails to clean up
        /// the private staging file, so installExclusive surfaces the honest
        /// `.cleanupFailed` residue error instead of a plain EEXIST.
        var installCleanupFailsOnCollision = false

        // Models an atomic no-replace install: fails with EEXIST if the
        // destination already exists (matching renamex_np RENAME_EXCL), so a
        // file that appeared mid-flight is never overwritten.
        func installExclusive(_ content: String, to path: String) throws {
            try maybeFail("install", path)
            if files[path] != nil {
                if installCleanupFailsOnCollision {
                    throw ProfileSaveError.cleanupFailed(
                        "exclusive install of \(path) failed: File exists; AND its private " +
                        "staging file \(path).stagingXYZ could not be removed; the staging " +
                        "file remains and \(path) is unchanged")
                }
                throw ProfileFileOpsError(operation: "installExclusive",
                                          from: path + ".stagingXYZ", to: path, code: EEXIST)
            }
            files[path] = content; log.append("install \(path)")
        }
        func copy(from: String, to: String) throws {
            try maybeFail("copy", to)
            files[to] = files[from]; log.append("copy \(from)->\(to)")
        }
        // Models POSIX rename: an ATOMIC replace. The fault (if any) throws
        // BEFORE any mutation, so a failed move never leaves a partial state —
        // matching the real SystemFileOps.move (rename(2)).
        func move(from: String, to: String) throws {
            try maybeFail("move", to)
            files[to] = files[from]; files[from] = nil; log.append("move \(from)->\(to)")
        }
        func remove(_ path: String) throws {
            try maybeFail("remove", path); files[path] = nil; log.append("remove \(path)")
        }
    }

    private let dir = "/u"
    private func tx(_ ops: ProfileFileOps) -> ProfileSaveTransaction {
        ProfileSaveTransaction(ops: ops, unisonDirectory: dir)
    }

    // MARK: - Happy paths (fake)

    func test_new_writesFileNoBackup() throws {
        let ops = FakeFileOps()
        try tx(ops).commit(oldName: nil, newName: "p", content: "root = /a\n")
        XCTAssertEqual(ops.files["/u/p.prf"], "root = /a\n")
        XCTAssertNil(ops.files["/u/p.prf.bak"])
    }

    func test_overwrite_backsUpThenWrites() throws {
        let ops = FakeFileOps()
        ops.files["/u/p.prf"] = "OLD"
        try tx(ops).commit(oldName: "p", newName: "p", content: "NEW")
        XCTAssertEqual(ops.files["/u/p.prf"], "NEW")
        XCTAssertEqual(ops.files["/u/p.prf.bak"], "OLD", "prior content is backed up")
        XCTAssertNil(ops.files["/u/p.prf.bak.tmp"], "temp backup is cleaned up")
    }

    func test_rename_backsUpImmediatelyPreSaveSource_notPriorBak() throws {
        // CORRECTED (Finding #11 review): the renamed profile's backup must be
        // the IMMEDIATELY-PRE-SAVE source content ("A"), matching in-place
        // overwrite semantics — NOT the source's stale prior `.bak` ("Abak").
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.files["/u/a.prf.bak"] = "Abak"
        try tx(ops).commit(oldName: "a", newName: "b", content: "B")
        XCTAssertEqual(ops.files["/u/b.prf"], "B")
        XCTAssertNil(ops.files["/u/a.prf"], "old profile removed")
        XCTAssertEqual(ops.files["/u/b.prf.bak"], "A",
                       "backup holds the pre-save source content, not the stale prior .bak")
        XCTAssertNil(ops.files["/u/a.prf.bak"], "orphaned old backup cleaned up")
        XCTAssertNil(ops.files["/u/b.prf.bak.tmp"], "temp backup cleaned up")
    }

    func test_rename_writeBeforeRemove_originalRecoverableUntilDurable() throws {
        // Log order proves the new file is written BEFORE the old is removed.
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        try tx(ops).commit(oldName: "a", newName: "b", content: "B")
        let installIdx = ops.log.firstIndex { $0 == "install /u/b.prf" }!
        let removeIdx = ops.log.firstIndex { $0 == "remove /u/a.prf" }!
        XCTAssertLessThan(installIdx, removeIdx)
    }

    func test_renameOntoExistingUnrelatedFile_refused_noChange() {
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.files["/u/b.prf"] = "EXISTING-B"
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B")) {
            XCTAssertEqual($0 as? ProfileSaveError, .destinationExists(name: "b"))
        }
        XCTAssertEqual(ops.files["/u/a.prf"], "A", "source untouched")
        XCTAssertEqual(ops.files["/u/b.prf"], "EXISTING-B", "unrelated destination untouched")
    }

    // MARK: - Fault injection: overwrite

    func test_overwrite_backupCopyFails_originalIntact_notOverwritten() {
        let ops = FakeFileOps()
        ops.files["/u/p.prf"] = "OLD"
        ops.files["/u/p.prf.bak"] = "PRIORBAK"
        ops.faultOn = ("copy", "p.prf.bak.tmp")
        XCTAssertThrowsError(try tx(ops).commit(oldName: "p", newName: "p", content: "NEW")) {
            guard case .backupFailed = ($0 as? ProfileSaveError) else { return XCTFail() }
        }
        XCTAssertEqual(ops.files["/u/p.prf"], "OLD", "not overwritten when backup fails")
        XCTAssertEqual(ops.files["/u/p.prf.bak"], "PRIORBAK", "prior backup preserved")
        XCTAssertNil(ops.files["/u/p.prf.bak.tmp"], "temp cleaned up")
    }

    func test_overwrite_backupMoveFails_priorBackupPreserved() {
        let ops = FakeFileOps()
        ops.files["/u/p.prf"] = "OLD"
        ops.files["/u/p.prf.bak"] = "PRIORBAK"
        ops.faultOn = ("move", "p.prf.bak")   // the atomic replace step
        XCTAssertThrowsError(try tx(ops).commit(oldName: "p", newName: "p", content: "NEW")) {
            guard case .backupFailed = ($0 as? ProfileSaveError) else { return XCTFail() }
        }
        XCTAssertEqual(ops.files["/u/p.prf"], "OLD")
        XCTAssertEqual(ops.files["/u/p.prf.bak"], "PRIORBAK", "atomic move never destroys prior .bak")
        XCTAssertNil(ops.files["/u/p.prf.bak.tmp"])
    }

    func test_overwrite_writeFails_originalIntact_retrySucceeds() throws {
        let ops = FakeFileOps()
        ops.files["/u/p.prf"] = "OLD"
        ops.faultOn = ("write", "p.prf")
        XCTAssertThrowsError(try tx(ops).commit(oldName: "p", newName: "p", content: "NEW")) {
            guard case .writeFailed = ($0 as? ProfileSaveError) else { return XCTFail() }
        }
        XCTAssertEqual(ops.files["/u/p.prf"], "OLD", "atomic write leaves the original on failure")
        XCTAssertEqual(ops.files["/u/p.prf.bak"], "OLD", "backup already captured the original")
        // Retry (fault is one-shot) now succeeds.
        try tx(ops).commit(oldName: "p", newName: "p", content: "NEW")
        XCTAssertEqual(ops.files["/u/p.prf"], "NEW")
    }

    // MARK: - Fault injection: rename

    func test_rename_writeFails_originalIntact_retrySucceeds() throws {
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.faultOn = ("install", "b.prf")   // rename installs the new file exclusively
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B")) {
            guard case .writeFailed = ($0 as? ProfileSaveError) else { return XCTFail() }
        }
        XCTAssertEqual(ops.files["/u/a.prf"], "A", "original still present")
        XCTAssertNil(ops.files["/u/b.prf"], "no half-written destination")
        // Retry succeeds and completes the rename.
        try tx(ops).commit(oldName: "a", newName: "b", content: "B")
        XCTAssertEqual(ops.files["/u/b.prf"], "B")
        XCTAssertNil(ops.files["/u/a.prf"])
    }

    func test_rename_removeOldFails_rollsBackToPreSaveState() {
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.faultOn = ("remove", "a.prf")
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B")) {
            guard case .renameCleanupFailed = ($0 as? ProfileSaveError) else { return XCTFail() }
        }
        // Rolled back: new file removed, old left exactly as before.
        XCTAssertEqual(ops.files["/u/a.prf"], "A")
        XCTAssertNil(ops.files["/u/b.prf"], "new file rolled back so state is coherent (old-only)")
    }

    func test_rename_removeOldFails_thenRetrySucceeds() throws {
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.faultOn = ("remove", "a.prf")   // one-shot
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B"))
        // Because the failure rolled back cleanly, the identity ("a") still
        // matches disk and the destination is free — a retry works.
        try tx(ops).commit(oldName: "a", newName: "b", content: "B")
        XCTAssertEqual(ops.files["/u/b.prf"], "B")
        XCTAssertNil(ops.files["/u/a.prf"])
    }

    func test_rename_refusedWhenDestinationBackupExists_noChange() {
        // A stray <newName>.prf.bak must not be silently clobbered by the
        // rename's own backup step.
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.files["/u/b.prf.bak"] = "UNRELATED-BAK"
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B")) {
            XCTAssertEqual($0 as? ProfileSaveError, .destinationBackupExists(name: "b"))
        }
        XCTAssertEqual(ops.files["/u/a.prf"], "A", "source untouched")
        XCTAssertEqual(ops.files["/u/b.prf.bak"], "UNRELATED-BAK", "existing backup untouched")
        XCTAssertNil(ops.files["/u/b.prf"], "no new file written")
    }

    func test_rename_backupFails_rollsBackNewFile_thenRetrySucceeds() throws {
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.faultOn = ("copy", "b.prf.bak.tmp")   // backup copy fails
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B")) {
            guard case .backupFailed = ($0 as? ProfileSaveError) else { return XCTFail() }
        }
        // New file rolled back → exact pre-save state (old-only).
        XCTAssertEqual(ops.files["/u/a.prf"], "A")
        XCTAssertNil(ops.files["/u/b.prf"], "new file rolled back after backup failure")
        XCTAssertNil(ops.files["/u/b.prf.bak"])
        // Retry (fault one-shot) completes the rename.
        try tx(ops).commit(oldName: "a", newName: "b", content: "B")
        XCTAssertEqual(ops.files["/u/b.prf"], "B")
        XCTAssertEqual(ops.files["/u/b.prf.bak"], "A")
        XCTAssertNil(ops.files["/u/a.prf"])
    }

    func test_rename_removeOldFails_andRollbackAlsoFails_reportsResidueHonestly() {
        // remove(old) fails AND the rollback removal of the new file also fails.
        // The transaction must NOT claim a clean pre-save state; it reports
        // .rollbackFailed and the disk genuinely holds BOTH files.
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.faults = [("remove", "a.prf"),      // step 3 remove-old fails
                      ("remove", "b.prf")]        // rollback of new file also fails
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B")) {
            guard case .rollbackFailed(let detail) = ($0 as? ProfileSaveError) else {
                return XCTFail("expected rollbackFailed, got \($0)")
            }
            XCTAssertTrue(detail.contains("b.prf"), "message names the residual new file")
        }
        // Honest residue: both files present (the backup rollback succeeded).
        XCTAssertEqual(ops.files["/u/a.prf"], "A")
        XCTAssertEqual(ops.files["/u/b.prf"], "B")
        XCTAssertNil(ops.files["/u/b.prf.bak"], "the new backup was rolled back")
    }

    // MARK: - No-clobber race (destination appears after the pre-check)

    func test_rename_destinationRace_afterPrecheck_refused_sourceAndIntruderUntouched() {
        // The destination does not exist at the preliminary `exists` pre-check,
        // but another actor creates it before the exclusive install. The
        // install must refuse (destinationExists), leaving BOTH the original
        // source and the unrelated intruder file untouched.
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.afterExists = { path in
            if path == "/u/b.prf" {
                ops.files["/u/b.prf"] = "INTRUDER"   // appears mid-flight
                ops.afterExists = nil                // one-shot
            }
        }
        XCTAssertThrowsError(try tx(ops).commit(oldName: "a", newName: "b", content: "B")) {
            XCTAssertEqual($0 as? ProfileSaveError, .destinationExists(name: "b"))
        }
        XCTAssertEqual(ops.files["/u/a.prf"], "A", "original source untouched")
        XCTAssertEqual(ops.files["/u/b.prf"], "INTRUDER",
                       "unrelated destination that appeared mid-flight is NOT overwritten")
    }

    func test_new_destinationRace_afterPrecheck_refused_intruderUntouched() {
        let ops = FakeFileOps()
        ops.afterExists = { path in
            if path == "/u/p.prf" { ops.files["/u/p.prf"] = "INTRUDER"; ops.afterExists = nil }
        }
        XCTAssertThrowsError(try tx(ops).commit(oldName: nil, newName: "p", content: "NEW")) {
            XCTAssertEqual($0 as? ProfileSaveError, .destinationExists(name: "p"))
        }
        XCTAssertEqual(ops.files["/u/p.prf"], "INTRUDER", "not overwritten by the exclusive install")
    }

    // MARK: - Stale-temp cleanup failure is reported, not swallowed

    func test_overwrite_staleTempCleanupFails_reportsResidue_originalUnchanged() {
        let ops = FakeFileOps()
        ops.files["/u/p.prf"] = "OLD"
        ops.files["/u/p.prf.bak.tmp"] = "STALE"       // leftover from a prior crash
        ops.faultOn = ("remove", "p.prf.bak.tmp")     // cleanup of it fails
        XCTAssertThrowsError(try tx(ops).commit(oldName: "p", newName: "p", content: "NEW")) {
            guard case .cleanupFailed(let detail) = ($0 as? ProfileSaveError) else {
                return XCTFail("expected cleanupFailed, got \($0)")
            }
            XCTAssertTrue(detail.contains("p.prf.bak.tmp"), "names the stray temp")
            XCTAssertTrue(detail.contains("unchanged"), "states the original is unchanged")
        }
        XCTAssertEqual(ops.files["/u/p.prf"], "OLD", "original untouched")
        XCTAssertEqual(ops.files["/u/p.prf.bak.tmp"], "STALE", "residue honestly left in place")
    }

    // MARK: - Real filesystem: exclusive install (no-replace, private staging)

    /// Names of any leftover staging files in a directory (the old fixed
    /// `*.new.tmp` OR the private `.unison-ui-save.*` scheme).
    private func stagingResidue(in base: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { $0.hasSuffix(".new.tmp") || $0.hasPrefix(".unison-ui-save") }
    }

    private func makeTempDir(_ tag: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileSaveTx\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func test_real_installExclusive_refusesExistingDestination() throws {
        let base = try makeTempDir("Excl")
        defer { try? FileManager.default.removeItem(at: base) }
        let ops = SystemFileOps()
        let dest = base.appendingPathComponent("p.prf").path
        try "EXISTING".write(toFile: dest, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ops.installExclusive("NEW", to: dest)) {
            XCTAssertEqual(($0 as? ProfileFileOpsError)?.code, EEXIST,
                           "exclusive install must fail with EEXIST on an existing destination")
        }
        XCTAssertEqual(try String(contentsOfFile: dest, encoding: .utf8), "EXISTING",
                       "existing destination is not overwritten")

        // A fresh path installs cleanly.
        let fresh = base.appendingPathComponent("q.prf").path
        try ops.installExclusive("FRESH", to: fresh)
        XCTAssertEqual(try String(contentsOfFile: fresh, encoding: .utf8), "FRESH")
    }

    /// (1) Separate exclusive-install attempts use INDEPENDENT staging files —
    /// no shared fixed staging path — so they cannot cross-write.
    func test_real_installExclusive_usesIndependentPrivateStaging() throws {
        let base = try makeTempDir("Indep")
        defer { try? FileManager.default.removeItem(at: base) }
        let ops = SystemFileOps()
        let a = base.appendingPathComponent("a.prf").path
        let b = base.appendingPathComponent("b.prf").path
        try ops.installExclusive("AAA", to: a)
        try ops.installExclusive("BBB", to: b)
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "AAA")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "BBB")
        // The old shared fixed staging names must never exist, and nothing
        // staging-like may linger.
        XCTAssertFalse(FileManager.default.fileExists(atPath: a + ".new.tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b + ".new.tmp"))
        XCTAssertTrue(stagingResidue(in: base).isEmpty,
                      "no staging residue: \(stagingResidue(in: base))")
    }

    /// (2) Concurrent contenders installing the SAME destination: exactly one
    /// succeeds, and the destination holds that contender's COMPLETE bytes (no
    /// truncation or cross-written mix).
    func test_real_installExclusive_concurrentContenders_oneWinnerCompleteBytes() throws {
        let base = try makeTempDir("Race")
        defer { try? FileManager.default.removeItem(at: base) }
        let ops = SystemFileOps()
        let dest = base.appendingPathComponent("p.prf").path
        let n = 8
        // Distinct, large per-contender content so a partial/mixed write is
        // detectable (each is ~40 KB with a unique marker and a distinct END).
        let contents = (0..<n).map { i in String(repeating: "C\(i)-", count: 10_000) + "END\(i)" }

        let lock = NSLock(); var successes = 0
        let group = DispatchGroup()
        for i in 0..<n {
            group.enter()
            DispatchQueue.global().async {
                do {
                    try ops.installExclusive(contents[i], to: dest)
                    lock.lock(); successes += 1; lock.unlock()
                } catch { /* EEXIST expected for the losers */ }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(successes, 1, "exactly one contender installs the destination")
        let final = try String(contentsOfFile: dest, encoding: .utf8)
        XCTAssertTrue(contents.contains(final),
                      "destination holds exactly one contender's COMPLETE bytes (no mix/truncation)")
        XCTAssertTrue(stagingResidue(in: base).isEmpty,
                      "losers cleaned up their private staging files: \(stagingResidue(in: base))")
    }

    /// (3) Destination-exists PLUS a temp-cleanup failure is reported honestly
    /// (as `.cleanupFailed` naming the residue), NOT reduced to
    /// `.destinationExists`. Exercised through the transaction with a fake that
    /// simulates the collision-then-cleanup-failure at install time; the
    /// destination is one that appeared AFTER the pre-check (the race).
    func test_installExclusive_destExistsPlusCleanupFailure_reportsResidue() {
        let ops = FakeFileOps()
        ops.installCleanupFailsOnCollision = true
        ops.afterExists = { path in
            if path == "/u/p.prf" { ops.files["/u/p.prf"] = "INTRUDER"; ops.afterExists = nil }
        }
        XCTAssertThrowsError(try tx(ops).commit(oldName: nil, newName: "p", content: "NEW")) {
            guard case .cleanupFailed(let detail) = ($0 as? ProfileSaveError) else {
                return XCTFail("expected cleanupFailed (not destinationExists), got \($0)")
            }
            XCTAssertTrue(detail.contains("p.prf"), "names the residual staging / destination")
            XCTAssertTrue(detail.lowercased().contains("staging"), "names the residual temp")
        }
        XCTAssertEqual(ops.files["/u/p.prf"], "INTRUDER", "unrelated destination untouched")
    }

    /// (4) No staging file remains after an ordinary SUCCESS or an ordinary
    /// destination COLLISION.
    func test_real_installExclusive_noStagingResidue_afterSuccessOrCollision() throws {
        let base = try makeTempDir("Residue")
        defer { try? FileManager.default.removeItem(at: base) }
        let ops = SystemFileOps()
        let dest = base.appendingPathComponent("p.prf").path

        try ops.installExclusive("ONE", to: dest)                 // ordinary success
        XCTAssertTrue(stagingResidue(in: base).isEmpty, "no residue after success")

        XCTAssertThrowsError(try ops.installExclusive("TWO", to: dest)) {  // ordinary collision
            XCTAssertEqual(($0 as? ProfileFileOpsError)?.code, EEXIST)
        }
        XCTAssertEqual(try String(contentsOfFile: dest, encoding: .utf8), "ONE", "unchanged")
        XCTAssertTrue(stagingResidue(in: base).isEmpty, "no residue after collision")
    }

    // MARK: - Real filesystem: move is an atomic replace

    func test_real_moveReplacesExistingDestinationAtomically() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileSaveTxMove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let from = base.appendingPathComponent("from").path
        let to = base.appendingPathComponent("to").path
        try "NEW".write(toFile: from, atomically: true, encoding: .utf8)
        try "OLD".write(toFile: to, atomically: true, encoding: .utf8)
        try SystemFileOps().move(from: from, to: to)
        XCTAssertEqual(try String(contentsOfFile: to, encoding: .utf8), "NEW",
                       "rename replaced the existing destination")
        XCTAssertFalse(FileManager.default.fileExists(atPath: from), "source gone after move")
    }

    // MARK: - Real filesystem (SystemFileOps) happy paths, temp dir only

    func test_real_newOverwriteRename() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileSaveTx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let t = ProfileSaveTransaction(ops: SystemFileOps(), unisonDirectory: base.path)
        func read(_ n: String) -> String? {
            try? String(contentsOfFile: base.appendingPathComponent(n).path, encoding: .utf8)
        }

        // New
        try t.commit(oldName: nil, newName: "p", content: "root = /a\n")
        XCTAssertEqual(read("p.prf"), "root = /a\n")

        // Overwrite → backup holds prior content
        try t.commit(oldName: "p", newName: "p", content: "root = /b\n")
        XCTAssertEqual(read("p.prf"), "root = /b\n")
        XCTAssertEqual(read("p.prf.bak"), "root = /a\n")

        // Rename → new present, old gone, backup holds the IMMEDIATELY-PRE-SAVE
        // source content ("root = /b\n" — p's content just before this rename),
        // NOT p's stale prior .bak ("root = /a\n"). The orphaned p.prf.bak is
        // cleaned up.
        try t.commit(oldName: "p", newName: "q", content: "root = /c\n")
        XCTAssertEqual(read("q.prf"), "root = /c\n")
        XCTAssertNil(read("p.prf"))
        XCTAssertEqual(read("q.prf.bak"), "root = /b\n")
        XCTAssertNil(read("p.prf.bak"), "orphaned old backup cleaned up")

        // Rename onto an existing unrelated file is refused
        try "OTHER".write(toFile: base.appendingPathComponent("r.prf").path,
                          atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try t.commit(oldName: "q", newName: "r", content: "X")) {
            XCTAssertEqual($0 as? ProfileSaveError, .destinationExists(name: "r"))
        }
        XCTAssertEqual(read("q.prf"), "root = /c\n", "source intact after refused rename")
        XCTAssertEqual(read("r.prf"), "OTHER", "unrelated file intact")
    }
}
