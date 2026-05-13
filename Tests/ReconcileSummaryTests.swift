import XCTest
@testable import unison_ui_mac

/// Tests for the reconcile-window's one-line summary. Pure logic
/// extracted from `ReconcileWindowController` so the count breakdown
/// + bytes total can be pinned without standing up AppKit.
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

    // MARK: - Basic counts

    func test_empty_showsZeroItemsAndNoTransferBytes() {
        let out = ReconcileSummary.text(items: [], profile: "Sync")
        XCTAssertTrue(out.hasPrefix("Sync  ·  0 items"), out)
        XCTAssertFalse(out.contains("KB"), "no bytes line for empty")
        XCTAssertFalse(out.contains("MB"), "no bytes line for empty")
    }

    func test_onlyConflicts_noTransferBytesShown() {
        // Conflicts don't transfer until resolved. Even with non-zero
        // sizeBytes on the conflict rows, the bytes total stays out.
        let items = [
            item(direction: conflict, size: 5_000_000),
            item(direction: conflict, size: 1_000_000),
        ]
        let out = ReconcileSummary.text(items: items, profile: "Sync")
        XCTAssertTrue(out.contains("2 items"))
        XCTAssertTrue(out.contains("2 conflicts"))
        XCTAssertFalse(out.contains("MB"), "conflicts must not contribute bytes")
    }

    func test_directionalRows_contributeBytesToTotal() {
        let items = [
            item(direction: toSecond, size: 1_000_000),  // 1 MB
            item(direction: toSecond, size: 2_000_000),  // 2 MB
            item(direction: toFirst,  size: 3_000_000),  // 3 MB
        ]
        let out = ReconcileSummary.text(items: items, profile: "Sync")
        // ByteCountFormatter with .file style gives MB, but exact
        // string varies by locale ("6 MB" vs "6,0 MB"). Substring
        // check on the numeric prefix only.
        XCTAssertTrue(out.contains("3 items"))
        XCTAssertTrue(out.contains("MB"), "bytes column must appear for directional rows")
        XCTAssertTrue(out.contains("1 ← first") || out.contains("1  ← first"))
        XCTAssertTrue(out.contains("2 → second") || out.contains("2  → second"))
    }

    func test_mixedRows_bytesIncludeOnlyDirectional() {
        // Two rows transfer (1 MB + 2 MB = 3 MB), one conflict
        // ignored, one unknown direction also ignored.
        let items = [
            item(direction: toSecond, size: 1_000_000),
            item(direction: toFirst,  size: 2_000_000),
            item(direction: conflict, size: 9_999_999),
            item(direction: "XXXXX",  size: 9_999_999),
        ]
        let out = ReconcileSummary.text(items: items, profile: "Sync")
        XCTAssertTrue(out.contains("4 items"))
        XCTAssertTrue(out.contains("1 conflicts"))
        XCTAssertTrue(out.contains("1 other"))
        // The 3 MB total must show, but the conflict's 10 MB must
        // NOT inflate the total. The ByteCountFormatter for 3 MB
        // produces "3 MB" exactly (or "3,0 MB" in some locales) —
        // not 12.99 MB.
        XCTAssertTrue(out.contains("3 MB") || out.contains("3,0 MB"))
        XCTAssertFalse(out.contains("13 MB"))
        XCTAssertFalse(out.contains("12 MB"))
    }

    func test_zeroByteRows_areCountedButTotalStaysHidden() {
        // Directory rows (sizeBytes = 0) still get counted in items
        // and direction bucket, but contribute nothing to the bytes
        // total. If every directional row has size 0, the bytes part
        // is suppressed entirely (transferBytes > 0 gate).
        let items = [
            item(direction: toSecond, size: 0, type: "DIR"),
            item(direction: toSecond, size: 0, type: "DIR"),
        ]
        let out = ReconcileSummary.text(items: items, profile: "Sync")
        XCTAssertTrue(out.contains("2 items"))
        XCTAssertTrue(out.contains("2 → second"))
        XCTAssertFalse(out.contains("byte") || out.contains("KB") || out.contains("MB"),
                       "no bytes when total is 0")
    }

    func test_negativeBytes_areClampedToZero() {
        // Defensive: if upstream Unison ever reports a negative size
        // (shouldn't happen but let's not crash or produce a nonsense
        // negative total), it doesn't subtract from the running total.
        let items = [
            item(direction: toSecond, size: -1_000_000),
            item(direction: toSecond, size:  2_000_000),
        ]
        let out = ReconcileSummary.text(items: items, profile: "Sync")
        // The 2 MB row contributes; the negative row contributes 0.
        XCTAssertTrue(out.contains("2 MB") || out.contains("2,0 MB"))
        XCTAssertFalse(out.contains("-"))
        XCTAssertFalse(out.contains("1 MB"))
    }

    // MARK: - Prefix

    func test_prefixUsesProfileNameByDefault() {
        let out = ReconcileSummary.text(
            items: [item(direction: toSecond, size: 1)],
            profile: "My-Profile")
        XCTAssertTrue(out.hasPrefix("My-Profile"))
    }

    func test_prefixUsesSynchronizedAfterSyncCompletes() {
        let out = ReconcileSummary.text(
            items: [item(direction: toSecond, size: 1)],
            profile: "My-Profile",
            syncDone: true)
        XCTAssertTrue(out.hasPrefix("Synchronized"))
        XCTAssertFalse(out.contains("My-Profile"),
                       "post-sync summary doesn't repeat the profile name")
    }

    // MARK: - Field ordering

    func test_bytesAppearAfterItemsAndBeforeDirectionBreakdown() {
        let items = [item(direction: toSecond, size: 1_500_000)]
        let out = ReconcileSummary.text(items: items, profile: "Sync")
        // Order matters for the at-a-glance read: count → size →
        // breakdown. Verify item-count appears before "MB" appears
        // before the direction breakdown.
        guard let itemsPos = out.range(of: "1 items")?.lowerBound,
              let mbPos    = out.range(of: "MB")?.lowerBound,
              let dirPos   = out.range(of: "→ second")?.lowerBound
        else { XCTFail("expected substrings missing: \(out)"); return }
        XCTAssertLessThan(itemsPos, mbPos)
        XCTAssertLessThan(mbPos, dirPos)
    }
}
