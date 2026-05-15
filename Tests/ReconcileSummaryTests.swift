import XCTest
@testable import unison_ui_mac

/// Tests for the reconcile-window's one-line summary. Pure logic
/// extracted from `ReconcileWindowController` so the count breakdown,
/// bytes total, status-leads ordering, and partial-success phrasing
/// can all be pinned without standing up AppKit.
final class ReconcileSummaryTests: XCTestCase {

    // MARK: - Builders

    private func item(direction: String,
                      size: Int64 = 0,
                      type: String = "FILE") -> StateItem {
        StateItem(path: "p", left: "Modified", right: "",
                  direction: direction, sizeBytes: size, fileType: type,
                  progress: "", bytesTransferred: 0)
    }

    private let toFirst  = ReconcileSummary.directionToFirst   // "<----"
    private let toSecond = ReconcileSummary.directionToSecond  // "---->"
    private let conflict = ReconcileSummary.directionConflict  // "<-?->"

    // MARK: - Empty cases

    func test_empty_preSync_showsUpToDateMessage() {
        // No items → explicit positive phrasing. No status prefix
        // appears separately; the trailing phrase IS the message.
        let out = ReconcileSummary.text(items: [])
        XCTAssertEqual(out, "Everything is up to date")
    }

    func test_empty_postSync_showsNothingToTransfer() {
        // Edge case: sync somehow finished with 0 items.
        let out = ReconcileSummary.text(items: [], syncDone: true)
        XCTAssertTrue(out.hasPrefix("Synchronization complete"), out)
        XCTAssertTrue(out.contains("nothing to transfer"), out)
    }

    // MARK: - Profile is NOT included in the summary

    func test_summary_doesNotIncludeProfileName() {
        // Profile lives in the window title. The summary line is
        // pure state + counts; no redundant profile prefix.
        let items = [item(direction: toSecond, size: 1)]
        let outPre  = ReconcileSummary.text(items: items)
        let outPost = ReconcileSummary.text(items: items, syncDone: true)
        // (Construction proves the function takes no `profile` arg.)
        XCTAssertFalse(outPre.contains("profile"),
                       "summary must not echo a profile name in pre-sync")
        XCTAssertFalse(outPost.contains("profile"),
                       "summary must not echo a profile name in post-sync")
    }

    // MARK: - Status-first ordering

    func test_preSync_withItems_leadsWithCounts_noStatusPrefix() {
        // Ready state has no status word — count is the lede.
        let items = [item(direction: toSecond, size: 1_000_000)]
        let out = ReconcileSummary.text(items: items)
        XCTAssertTrue(out.hasPrefix("1 items"), out)
    }

    func test_postSync_clean_leadsWithStatusPrefix() {
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(items: items, syncDone: true)
        XCTAssertTrue(out.hasPrefix("Synchronization complete  ·  "), out)
    }

    func test_postSync_withFailures_leadsWithErrorCountPhrase() {
        // The partial-success path needs to read as such in the
        // summary itself, not only via the side error banner.
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(
            items: items, syncDone: true, failedRows: 5)
        XCTAssertTrue(out.hasPrefix("Synchronization completed with 5 errors"), out)
    }

    func test_postSync_singleFailure_usesSingularNoun() {
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(
            items: items, syncDone: true, failedRows: 1)
        XCTAssertTrue(out.contains("1 error"), out)
        XCTAssertFalse(out.contains("1 errors"), "must use singular")
    }

    func test_failedRows_ignoredWhenSyncIsNotDone() {
        // Pre-sync `failedRows` is meaningless (nothing has run yet);
        // builder ignores it. The summary still reads as a fresh
        // ready-state line.
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(
            items: items, syncDone: false, failedRows: 99)
        XCTAssertFalse(out.contains("error"))
        XCTAssertFalse(out.contains("Synchroniz"))
    }

    // MARK: - Existing breakdown + bytes behavior preserved

    func test_onlyConflicts_noTransferBytesShown() {
        let items = [
            item(direction: conflict, size: 5_000_000),
            item(direction: conflict, size: 1_000_000),
        ]
        let out = ReconcileSummary.text(items: items)
        XCTAssertTrue(out.contains("2 items"))
        XCTAssertTrue(out.contains("2 conflicts"))
        XCTAssertFalse(out.contains("MB"), "conflicts must not contribute bytes")
    }

    func test_directionalRows_contributeBytesToTotal() {
        let items = [
            item(direction: toSecond, size: 1_000_000),
            item(direction: toSecond, size: 2_000_000),
            item(direction: toFirst,  size: 3_000_000),
        ]
        let out = ReconcileSummary.text(items: items)
        XCTAssertTrue(out.contains("3 items"))
        XCTAssertTrue(out.contains("MB"))
        XCTAssertTrue(out.contains("1 Second → First"), out)
        XCTAssertTrue(out.contains("2 First → Second"), out)
    }

    func test_mixedRows_bytesIncludeOnlyDirectional() {
        let items = [
            item(direction: toSecond, size: 1_000_000),
            item(direction: toFirst,  size: 2_000_000),
            item(direction: conflict, size: 9_999_999),
            item(direction: "XXXXX",  size: 9_999_999),
        ]
        let out = ReconcileSummary.text(items: items)
        XCTAssertTrue(out.contains("4 items"))
        XCTAssertTrue(out.contains("1 conflicts"))
        XCTAssertTrue(out.contains("1 other"))
        XCTAssertTrue(out.contains("3 MB") || out.contains("3,0 MB"))
        XCTAssertFalse(out.contains("13 MB"))
        XCTAssertFalse(out.contains("12 MB"))
    }

    func test_zeroByteRows_areCountedButTotalStaysHidden() {
        let items = [
            item(direction: toSecond, size: 0, type: "DIR"),
            item(direction: toSecond, size: 0, type: "DIR"),
        ]
        let out = ReconcileSummary.text(items: items)
        XCTAssertTrue(out.contains("2 items"))
        XCTAssertTrue(out.contains("2 First → Second"))
        XCTAssertFalse(out.contains("byte") || out.contains("KB") || out.contains("MB"),
                       "no bytes when total is 0")
    }

    func test_negativeBytes_areClampedToZero() {
        let items = [
            item(direction: toSecond, size: -1_000_000),
            item(direction: toSecond, size:  2_000_000),
        ]
        let out = ReconcileSummary.text(items: items)
        XCTAssertTrue(out.contains("2 MB") || out.contains("2,0 MB"))
        XCTAssertFalse(out.contains("-"))
    }

    // MARK: - Field ordering

    func test_postSync_clean_statusComesBeforeCountsBeforeDirection() {
        let items = [item(direction: toSecond, size: 1_500_000)]
        let out = ReconcileSummary.text(items: items, syncDone: true)
        guard let statusPos = out.range(of: "Synchronization complete")?.lowerBound,
              let itemsPos  = out.range(of: "1 items")?.lowerBound,
              let mbPos     = out.range(of: "MB")?.lowerBound,
              let dirPos    = out.range(of: "First → Second")?.lowerBound
        else { XCTFail("expected substrings missing: \(out)"); return }
        XCTAssertLessThan(statusPos, itemsPos)
        XCTAssertLessThan(itemsPos, mbPos)
        XCTAssertLessThan(mbPos, dirPos)
    }

    func test_postSync_errors_errorPhraseComesBeforeCounts() {
        let items = [item(direction: toSecond, size: 1_500_000)]
        let out = ReconcileSummary.text(
            items: items, syncDone: true, failedRows: 3)
        guard let errPos   = out.range(of: "3 errors")?.lowerBound,
              let itemsPos = out.range(of: "1 items")?.lowerBound
        else { XCTFail("expected substrings missing: \(out)"); return }
        XCTAssertLessThan(errPos, itemsPos,
                          "the error count belongs in the lede, not buried")
    }
}
