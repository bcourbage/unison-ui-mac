import XCTest
@testable import unison_ui_mac

/// Pure-logic coverage for the Select Conflicts and Revert to
/// Recommendation action items. The rules live in
/// `RowSelectionRules` so they're testable without an NSOutlineView
/// harness — the controller wraps the results in selection + reload.
final class RowSelectionRulesTests: XCTestCase {

    private func item(_ path: String, _ dir: String) -> StateItem {
        StateItem(path: path, left: "", right: "", direction: dir,
                  sizeBytes: 0, fileType: "FILE", progress: "", bytesTransferred: 0,
                  changedFromDefault: false)
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

    // MARK: - diffTarget

    /// Helpers for building ReconcileNode fixtures with the right
    /// shape for diffTarget tests. The function only inspects `.row`
    /// — we don't need the full tree, just a node with the right
    /// leaf/folder property.
    private func leaf(_ row: Int) -> ReconcileNode {
        ReconcileNode(name: "leaf-\(row)", row: row, fullPath: "/leaf-\(row)")
    }
    private func folder(_ name: String = "folder") -> ReconcileNode {
        ReconcileNode(name: name)  // no row → folder
    }

    func test_diffTarget_rightClickedLeaf_returnsThatLeaf() {
        // Right-clicked a leaf, with the same leaf in selection. Easy case.
        let target = leaf(7)
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: target, selectedNodes: [target]
        )
        XCTAssertEqual(result, 7)
    }

    func test_diffTarget_rightClickedLeaf_overridesSelection() {
        // Right-clicked leaf 9, but selection is leaf 3 (e.g. user
        // right-clicked a row that wasn't part of their existing
        // selection). The right-clicked row wins — matches Finder's
        // behavior.
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: leaf(9), selectedNodes: [leaf(3)]
        )
        XCTAssertEqual(result, 9)
    }

    func test_diffTarget_rightClickedFolder_returnsNil() {
        // Folders have no row — Diff is meaningless for them.
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: folder(), selectedNodes: [leaf(3)]
        )
        XCTAssertNil(result,
                     "right-clicked folder must NOT fall back to selection")
    }

    func test_diffTarget_noRightClick_singleLeafSelected_returnsThatLeaf() {
        // Action-menu invocation (no right-click context). With exactly
        // one leaf in the selection, that's our target.
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: nil, selectedNodes: [leaf(5)]
        )
        XCTAssertEqual(result, 5)
    }

    func test_diffTarget_noRightClick_folderSelected_returnsNil() {
        // The bug the user reported: a selected folder used to slip
        // through (controller fell back to "first leaf in selection").
        // Now: a folder in the selection means Diff is greyed.
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: nil, selectedNodes: [folder()]
        )
        XCTAssertNil(result)
    }

    func test_diffTarget_noRightClick_multipleLeavesSelected_returnsNil() {
        // Diff is single-row by nature — multi-select greys it out
        // rather than picking an arbitrary row.
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: nil, selectedNodes: [leaf(1), leaf(2)]
        )
        XCTAssertNil(result)
    }

    func test_diffTarget_noRightClick_mixedSelection_returnsNil() {
        // A folder plus a leaf in the selection (count != 1) → nil
        // regardless of order.
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: nil, selectedNodes: [folder(), leaf(5)]
        )
        XCTAssertNil(result)
    }

    func test_diffTarget_noRightClick_emptySelection_returnsNil() {
        let result = RowSelectionRules.diffTarget(
            rightClickedNode: nil, selectedNodes: []
        )
        XCTAssertNil(result)
    }

    // MARK: - isRevertible (Finding #2 — Revert menu eligibility)

    func test_isRevertible_plainDirectionChange_viaChangedFromDefault() {
        // First/Second/Merge leave no override but DO diverge from the default →
        // must still be revertible (the pre-fix gap: rowOverrides-only checks
        // missed these entirely).
        XCTAssertTrue(RowSelectionRules.isRevertible(changedFromDefault: true, hasOverride: false))
    }

    func test_isRevertible_skipOrForce_viaOverride() {
        // Skip / Force carry a visual override.
        XCTAssertTrue(RowSelectionRules.isRevertible(changedFromDefault: true, hasOverride: true))
    }

    func test_isRevertible_forceEqualsDefault_stillRevertibleToClearBadge() {
        // A Force whose result happens to equal the default direction reports
        // changedFromDefault=false, but the badge (override) must still be
        // clearable via Revert.
        XCTAssertTrue(RowSelectionRules.isRevertible(changedFromDefault: false, hasOverride: true))
    }

    func test_isRevertible_unchangedNoOverride_notRevertible() {
        XCTAssertFalse(RowSelectionRules.isRevertible(changedFromDefault: false, hasOverride: false))
    }
}
