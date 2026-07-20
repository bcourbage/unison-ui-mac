import XCTest
import AppKit
@testable import unison_ui_mac

/// Tests for the reconcile-window's one-line summary. Pure logic
/// extracted from `ReconcileWindowController` so the count breakdown,
/// bytes total, status-leads ordering, phase-driven prefix, and
/// partial-success phrasing can all be pinned without standing up
/// AppKit.
final class ReconcileSummaryTests: XCTestCase {

    // MARK: - Builders

    private func item(direction: String,
                      size: Int64 = 0,
                      type: String = "FILE") -> StateItem {
        StateItem(path: "p", left: "Modified", right: "",
                  direction: direction, sizeBytes: size, fileType: type,
                  progress: "", bytesTransferred: 0, changedFromDefault: false)
    }

    private let toFirst  = ReconcileSummary.directionToFirst   // "<----"
    private let toSecond = ReconcileSummary.directionToSecond  // "---->"
    private let conflict = ReconcileSummary.directionConflict  // "<-?->"

    // MARK: - Empty cases per phase

    func test_empty_ready_showsUpToDateMessage() {
        let out = ReconcileSummary.text(items: [], phase: .ready)
        XCTAssertEqual(out, "Everything is up to date")
    }

    func test_empty_doneClean_showsNothingToTransfer() {
        let out = ReconcileSummary.text(items: [], phase: .done(failures: 0))
        XCTAssertTrue(out.hasPrefix("Synchronization complete"), out)
        XCTAssertTrue(out.contains("nothing to transfer"), out)
    }

    func test_empty_syncing_showsNothingToTransfer() {
        // Pathological state (sync running with no items) — should
        // still render cleanly rather than crashing or showing "0
        // items". The "nothing to transfer" tail covers it.
        let out = ReconcileSummary.text(items: [], phase: .syncing)
        XCTAssertTrue(out.hasPrefix("Synchronizing"), out)
        XCTAssertTrue(out.contains("nothing to transfer"), out)
    }

    // MARK: - Phase-driven status prefixes

    func test_ready_withItems_hasNoStatusPrefix() {
        // Ready state has no status word — count is the lede.
        let items = [item(direction: toSecond, size: 1_000_000)]
        let out = ReconcileSummary.text(items: items, phase: .ready)
        XCTAssertTrue(out.hasPrefix("1 items"), out)
        XCTAssertFalse(out.contains("Synchroniz"),
                       "ready state must not show any sync status word")
    }

    func test_syncing_withItems_leadsWithSynchronizingPrefix() {
        // The whole point of this phase: keep the breakdown visible
        // during the transfer with a leading "Synchronizing".
        let items = [item(direction: toSecond, size: 1_000_000)]
        let out = ReconcileSummary.text(items: items, phase: .syncing)
        XCTAssertTrue(out.hasPrefix("Synchronizing  ·  "), out)
        XCTAssertTrue(out.contains("1 items"),
                      "breakdown must be preserved during sync: \(out)")
        XCTAssertTrue(out.contains("MB"),
                      "bytes must be preserved during sync: \(out)")
    }

    func test_doneClean_leadsWithSynchronizationComplete() {
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(items: items, phase: .done(failures: 0))
        XCTAssertTrue(out.hasPrefix("Synchronization complete  ·  "), out)
    }

    func test_doneWithFailures_leadsWithErrorCountPhrase() {
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(items: items, phase: .done(failures: 5))
        XCTAssertTrue(out.hasPrefix("Synchronization completed with 5 errors"), out)
    }

    func test_doneWithSingleFailure_usesSingularNoun() {
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(items: items, phase: .done(failures: 1))
        XCTAssertTrue(out.contains("1 error"), out)
        XCTAssertFalse(out.contains("1 errors"), "must use singular")
    }

    func test_doneStopped_leadsWithSynchronizationStopped() {
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(items: items, phase: .done(failures: 0),
                                        stopped: true)
        XCTAssertTrue(out.hasPrefix("Synchronization stopped  ·  "), out)
    }

    func test_doneStopped_takesPrecedenceOverErrorCount() {
        // Aborted items often register as failures; a user-stopped run must
        // still read "stopped", not "completed with N errors".
        let items = [item(direction: toSecond, size: 1)]
        let out = ReconcileSummary.text(items: items, phase: .done(failures: 5),
                                        stopped: true)
        XCTAssertTrue(out.hasPrefix("Synchronization stopped"), out)
        XCTAssertFalse(out.contains("errors"), out)
    }

    func test_doneStopped_emptyItems() {
        let out = ReconcileSummary.text(items: [], phase: .done(failures: 0),
                                        stopped: true)
        XCTAssertTrue(out.hasPrefix("Synchronization stopped"), out)
    }

    // MARK: - Profile name is NOT included

    func test_summary_doesNotIncludeProfileName() {
        // Profile lives in the window title. The summary is pure
        // state + counts; no redundant profile echo.
        let items = [item(direction: toSecond, size: 1)]
        for phase in [ReconcileSummary.Phase.ready,
                      .syncing,
                      .done(failures: 0),
                      .done(failures: 3)] {
            let out = ReconcileSummary.text(items: items, phase: phase)
            XCTAssertFalse(out.lowercased().contains("profile"),
                           "phase \(phase) must not echo 'profile': \(out)")
        }
    }

    // MARK: - Breakdown behavior preserved

    func test_onlyConflicts_noTransferBytesShown() {
        let items = [
            item(direction: conflict, size: 5_000_000),
            item(direction: conflict, size: 1_000_000),
        ]
        let out = ReconcileSummary.text(items: items, phase: .ready)
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
        let out = ReconcileSummary.text(items: items, phase: .ready)
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
        let out = ReconcileSummary.text(items: items, phase: .ready)
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
        let out = ReconcileSummary.text(items: items, phase: .ready)
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
        let out = ReconcileSummary.text(items: items, phase: .ready)
        XCTAssertTrue(out.contains("2 MB") || out.contains("2,0 MB"))
        XCTAssertFalse(out.contains("-"))
    }

    // MARK: - Field ordering

    func test_done_statusBeforeCountsBeforeDirection() {
        let items = [item(direction: toSecond, size: 1_500_000)]
        let out = ReconcileSummary.text(items: items, phase: .done(failures: 0))
        guard let statusPos = out.range(of: "Synchronization complete")?.lowerBound,
              let itemsPos  = out.range(of: "1 items")?.lowerBound,
              let mbPos     = out.range(of: "MB")?.lowerBound,
              let dirPos    = out.range(of: "First → Second")?.lowerBound
        else { XCTFail("expected substrings missing: \(out)"); return }
        XCTAssertLessThan(statusPos, itemsPos)
        XCTAssertLessThan(itemsPos, mbPos)
        XCTAssertLessThan(mbPos, dirPos)
    }

    func test_done_errorPhraseComesBeforeCounts() {
        let items = [item(direction: toSecond, size: 1_500_000)]
        let out = ReconcileSummary.text(items: items, phase: .done(failures: 3))
        guard let errPos   = out.range(of: "3 errors")?.lowerBound,
              let itemsPos = out.range(of: "1 items")?.lowerBound
        else { XCTFail("expected substrings missing: \(out)"); return }
        XCTAssertLessThan(errPos, itemsPos,
                          "the error count belongs in the lede, not buried")
    }

    func test_syncing_synchronizingComesBeforeCounts() {
        // Belt-and-suspenders for the new syncing phase: the
        // breakdown follows the status word, never precedes it.
        let items = [item(direction: toSecond, size: 1_500_000)]
        let out = ReconcileSummary.text(items: items, phase: .syncing)
        guard let statusPos = out.range(of: "Synchronizing")?.lowerBound,
              let itemsPos  = out.range(of: "1 items")?.lowerBound
        else { XCTFail("expected substrings missing: \(out)"); return }
        XCTAssertLessThan(statusPos, itemsPos)
    }

    // MARK: - Completion emphasis

    func test_completionEmphasis_zeroFailures_isGreenCheck() {
        let e = ReconcileSummary.completionEmphasis(failures: 0)
        XCTAssertEqual(e.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(e.tint, .systemGreen)
    }

    func test_completionEmphasis_withFailures_isRedWarning() {
        let e = ReconcileSummary.completionEmphasis(failures: 3)
        XCTAssertEqual(e.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(e.tint, .systemRed)
    }

    func test_completionEmphasis_oneFailure_stillRedWarning() {
        // Boundary: a single failure is still the error treatment.
        let e = ReconcileSummary.completionEmphasis(failures: 1)
        XCTAssertEqual(e.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(e.tint, .systemRed)
    }

    func test_completionEmphasis_stopped_isOrangeStop() {
        let e = ReconcileSummary.completionEmphasis(failures: 0, stopped: true)
        XCTAssertEqual(e.symbolName, "stop.circle.fill")
        XCTAssertEqual(e.tint, .systemOrange)
    }

    func test_completionEmphasis_stopped_winsOverFailures() {
        // A user-stopped run reads as "stopped" (orange), not error (red),
        // even when aborted items registered as failures.
        let e = ReconcileSummary.completionEmphasis(failures: 4, stopped: true)
        XCTAssertEqual(e.symbolName, "stop.circle.fill")
        XCTAssertEqual(e.tint, .systemOrange)
    }
}
