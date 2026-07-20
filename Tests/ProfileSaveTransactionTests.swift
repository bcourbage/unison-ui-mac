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
        var faultOn: (op: String, suffix: String)?

        private func maybeFail(_ op: String, _ path: String) throws {
            if let f = faultOn, f.op == op, path.hasSuffix(f.suffix) {
                faultOn = nil            // one-shot, so a retry can succeed
                throw InjectedFault()
            }
        }
        func exists(_ path: String) -> Bool { files[path] != nil }
        func writeAtomic(_ content: String, to path: String) throws {
            try maybeFail("write", path); files[path] = content; log.append("write \(path)")
        }
        func copy(from: String, to: String) throws {
            try maybeFail("copy", to)
            files[to] = files[from]; log.append("copy \(from)->\(to)")
        }
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

    func test_rename_writesNewRemovesOldCarriesBackup() throws {
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        ops.files["/u/a.prf.bak"] = "Abak"
        try tx(ops).commit(oldName: "a", newName: "b", content: "B")
        XCTAssertEqual(ops.files["/u/b.prf"], "B")
        XCTAssertNil(ops.files["/u/a.prf"], "old profile removed")
        XCTAssertEqual(ops.files["/u/b.prf.bak"], "Abak", "sidecar carried to new name")
        XCTAssertNil(ops.files["/u/a.prf.bak"])
    }

    func test_rename_writeBeforeRemove_originalRecoverableUntilDurable() throws {
        // Log order proves the new file is written BEFORE the old is removed.
        let ops = FakeFileOps()
        ops.files["/u/a.prf"] = "A"
        try tx(ops).commit(oldName: "a", newName: "b", content: "B")
        let writeIdx = ops.log.firstIndex { $0 == "write /u/b.prf" }!
        let removeIdx = ops.log.firstIndex { $0 == "remove /u/a.prf" }!
        XCTAssertLessThan(writeIdx, removeIdx)
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
        ops.faultOn = ("write", "b.prf")
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

        // Rename → new present, old gone, sidecar carried
        try t.commit(oldName: "p", newName: "q", content: "root = /c\n")
        XCTAssertEqual(read("q.prf"), "root = /c\n")
        XCTAssertNil(read("p.prf"))
        XCTAssertEqual(read("q.prf.bak"), "root = /a\n")

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
