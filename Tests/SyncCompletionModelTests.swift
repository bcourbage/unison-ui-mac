import XCTest
@testable import unison_ui_mac

/// Finding #10 — the completion path applies ONE bulk post-sync snapshot from
/// cached data with ZERO per-row bridge calls, preserving the exact
/// details-based failure attribution.
final class SyncCompletionModelTests: XCTestCase {

    private func item(_ path: String, progress: String = "", bytes: Int64 = 0) -> StateItem {
        StateItem(path: path, left: "", right: "", direction: "---->",
                  sizeBytes: 0, fileType: "file", progress: progress,
                  bytesTransferred: bytes, changedFromDefault: false)
    }
    private func snap(_ progress: String, _ details: String, _ bytes: Int64 = 0) -> SyncSnapshotRow {
        SyncSnapshotRow(progress: progress, details: details, bytesTransferred: bytes)
    }
    private func applied(_ o: SyncCompletionModel.Outcome) -> SyncCompletionModel.Applied? {
        if case .applied(let a) = o { return a } else { return nil }
    }

    // MARK: - Row kinds: success / failed / partial / already-failed

    func test_allRowKinds_attributedCorrectly() {
        let items = [item("ok"), item("alreadyFailed", progress: "FAILED"),
                     item("detailsFail", progress: "done"), item("partial", progress: "")]
        let snapshot = [
            snap("done", "ok\n  no change here", 10),               // success
            snap("FAILED", "alreadyFailed\nboom"),                  // already failed
            snap("done", "detailsFail\nTransfer aborted: source changed"), // details-only failure
            snap("", "partial\npermission denied"),                 // partial/problematic
        ]
        guard let a = applied(SyncCompletionModel.apply(snapshot: snapshot, to: items)) else {
            return XCTFail("expected applied")
        }
        XCTAssertEqual(a.failedRows, [1, 2, 3])
        XCTAssertEqual(a.items[0].progress, "done")
        XCTAssertTrue(a.items[2].progress.hasPrefix("FAILED:"), "details-only failure synthesized")
        XCTAssertTrue(a.items[3].progress.hasPrefix("FAILED:"))
        XCTAssertEqual(a.items[0].bytesTransferred, 10, "final bytes applied from snapshot")
    }

    func test_skipped_isNotAFailure() {
        // "skipped" is a user-initiated skip, deliberately NOT a failure marker.
        let items = [item("s", progress: "")]
        let a = applied(SyncCompletionModel.apply(snapshot: [snap("", "s\nskipped")], to: items))
        XCTAssertEqual(a?.failedRows, [])
    }

    // MARK: - Count mismatch → no partial apply

    func test_countMismatch_returnsMismatch_noItems() {
        let items = [item("a"), item("b")]
        let o = SyncCompletionModel.apply(snapshot: [snap("done", "a")], to: items)  // 1 vs 2
        guard case .countMismatch(let expected, let got) = o else {
            return XCTFail("expected countMismatch, got \(o)")
        }
        XCTAssertEqual(expected, 2)
        XCTAssertEqual(got, 1)
    }

    func test_emptyRows_ok() {
        let a = applied(SyncCompletionModel.apply(snapshot: [], to: []))
        XCTAssertEqual(a?.items.count, 0)
        XCTAssertEqual(a?.failedRows, [])
    }

    // MARK: - Zero per-row bridge getter calls on the completion application

    func test_apply_makesZeroRiGetDetailsCalls() {
        unison_bridge_test_reset_ri_get_details_count()
        let items = (0..<50).map { item("p\($0)", progress: "done") }
        // Include rows whose failure lives only in details — the synthesis path
        // that USED to call unison_bridge_ri_get_details per row.
        let snapshot = (0..<50).map { i -> SyncSnapshotRow in
            i % 5 == 0 ? snap("done", "p\(i)\nTransfer aborted") : snap("done", "p\(i)\nfine")
        }
        _ = SyncCompletionModel.apply(snapshot: snapshot, to: items)
        XCTAssertEqual(unison_bridge_test_ri_get_details_count(), 0,
                       "completion application must make no per-row getter calls")
    }

    // MARK: - Large synthetic set

    func test_largeSet_appliesAndCountsFailures() {
        let n = 5000
        let items = (0..<n).map { item("f\($0)", progress: "done") }
        let snapshot = (0..<n).map { i -> SyncSnapshotRow in
            i % 100 == 0 ? snap("FAILED", "f\(i)\nboom") : snap("done", "f\(i)\nok")
        }
        guard let a = applied(SyncCompletionModel.apply(snapshot: snapshot, to: items)) else {
            return XCTFail()
        }
        XCTAssertEqual(a.items.count, n)
        XCTAssertEqual(a.failedRows.count, n / 100)
    }

    // MARK: - Row→node index builder (Finding #10 O(1) lookup)

    func test_rowIndex_mapsEveryLeafRow() {
        let items = (0..<20).map { item("dir/sub/leaf\($0)") }
        let tree = ReconcileTree(items: items)
        let index = ReconcileWindowController.buildRowIndex(tree.allNodes)
        for r in 0..<20 {
            XCTAssertEqual(index[r]?.row, r, "row \(r) maps to its own leaf")
        }
    }
}
