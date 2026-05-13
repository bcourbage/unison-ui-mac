import XCTest
@testable import unison_ui_mac

/// Pure-logic coverage for the Select Conflicts and Revert to
/// Recommendation action items. The rules live in
/// `RowSelectionRules` so they're testable without an NSOutlineView
/// harness — the controller wraps the results in selection + reload.
final class RowSelectionRulesTests: XCTestCase {

    private func item(_ path: String, _ dir: String) -> StateItem {
        StateItem(path: path, left: "", right: "", direction: dir,
                  sizeBytes: 0, fileType: "FILE", progress: "", bytesTransferred: 0)
    }

    // MARK: - unresolvedConflictRows

    func test_unresolved_conflictWithNoOverride_isCounted() {
        let items = [
            item("a", "<-?->"),
            item("b", "---->"),
            item("c", "<-?->"),
        ]
        let rows = RowSelectionRules.unresolvedConflictRows(
            items: items, rowOverrides: [:]
        )
        XCTAssertEqual(rows, [0, 2])
    }

    func test_unresolved_userSkippedConflict_isExcluded() {
        // The user already addressed this row via Skip — it shouldn't
        // appear in "needs attention" again.
        let items = [item("a", "<-?->"), item("b", "<-?->")]
        let rows = RowSelectionRules.unresolvedConflictRows(
            items: items, rowOverrides: [0: .skip]
        )
        XCTAssertEqual(rows, [1])
    }

    func test_unresolved_forceOlderOrNewer_excludesRow() {
        // Force Older / Newer overrides resolve a conflict — even
        // though the row's underlying direction may have been
        // "<-?->" at some point, after the force it's "---->" or
        // "<----". But our list-of-items would in practice have the
        // forced direction string. Defensive: even if the items
        // still report "<-?->", an override of any kind clears
        // "unresolved" status.
        let items = [
            item("a", "<-?->"),  // override = forceOlder
            item("b", "<-?->"),  // override = forceNewer
            item("c", "<-?->"),  // no override → unresolved
        ]
        let overrides: [Int: RowOverride] = [
            0: .forceOlder, 1: .forceNewer,
        ]
        XCTAssertEqual(
            RowSelectionRules.unresolvedConflictRows(items: items, rowOverrides: overrides),
            [2]
        )
    }

    func test_unresolved_nonConflictDirections_areNotIncluded() {
        // "---->", "<----", "<-M->" — none of these are conflicts.
        // They shouldn't be selected by "Select Conflicts" even if
        // they have no override.
        let items = [
            item("a", "---->"),
            item("b", "<----"),
            item("c", "<-M->"),
            item("d", "<-?->"),
        ]
        let rows = RowSelectionRules.unresolvedConflictRows(
            items: items, rowOverrides: [:]
        )
        XCTAssertEqual(rows, [3])
    }

    func test_unresolved_empty_returnsEmpty() {
        XCTAssertEqual(
            RowSelectionRules.unresolvedConflictRows(items: [], rowOverrides: [:]),
            []
        )
    }

    // MARK: - clearOverrides

    func test_clearOverrides_removesOnlyRequestedRows() {
        let before: [Int: RowOverride] = [
            0: .skip, 1: .forceOlder, 2: .forceNewer, 3: .skip
        ]
        let after = RowSelectionRules.clearOverrides(
            rowOverrides: before, forRows: [1, 3]
        )
        XCTAssertEqual(after[0], .skip)
        XCTAssertNil(after[1])
        XCTAssertEqual(after[2], .forceNewer)
        XCTAssertNil(after[3])
    }

    func test_clearOverrides_noTargetRows_isNoOp() {
        let before: [Int: RowOverride] = [0: .skip, 1: .forceOlder]
        let after = RowSelectionRules.clearOverrides(
            rowOverrides: before, forRows: []
        )
        XCTAssertEqual(after, before)
    }

    func test_clearOverrides_rowWithNoOverride_isNoOp() {
        let before: [Int: RowOverride] = [0: .skip]
        let after = RowSelectionRules.clearOverrides(
            rowOverrides: before, forRows: [5, 99]
        )
        XCTAssertEqual(after, before)
    }
}
