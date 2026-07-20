import Foundation

/// Pure logic for the "Select Conflicts" and "Revert to Recommendation"
/// menu items. Broken out from the controller so the rules are
/// testable without an NSOutlineView harness — the controller wraps
/// each function in a thin selection-update + reload pass.
///
/// Both functions take the post-init2 `[StateItem]` array and the
/// controller's `[Int: RowOverride]` so they can reason about the
/// underlying OCaml direction AND the user's pinned decisions.
enum RowSelectionRules {

    /// Return the row indices that count as "unresolved conflict":
    /// auto-detected `<-?->` from OCaml AND no user override pinned.
    /// User-skipped, user-merged, or user-forced rows are excluded —
    /// the user has already decided what to do with them.
    ///
    /// Use case: `Action → Select Conflicts` jumps the user to the
    /// rows that still need attention before a sync can proceed
    /// without ambiguity.
    static func unresolvedConflictRows(
        items: [StateItem],
        rowOverrides: [Int: RowOverride]
    ) -> [Int] {
        var out: [Int] = []
        for (row, item) in items.enumerated() {
            guard item.direction == "<-?->" else { continue }
            // Skip rows the user has already addressed via Skip,
            // Force Older, or Force Newer (those overrides override
            // both the direction string AND the "needs attention"
            // status of the row).
            if rowOverrides[row] != nil { continue }
            out.append(row)
        }
        return out
    }

    /// Resolve the target row for a single-leaf action (currently Diff).
    /// Diff fundamentally operates on one file — folders, multi-row
    /// selections, and clicks outside any row produce nil.
    ///
    /// Inputs are the same data the controller has, factored out so
    /// the logic is testable without an outline-view harness:
    ///   - `rightClickedNode`: the node under the right-click target,
    ///     or nil if the menu invocation isn't from a right-click
    ///     (e.g. it came from the Action menu).
    ///   - `selectedNodes`: the controller's `selectedNodes()` snapshot.
    ///
    /// Rule:
    ///   1. If `rightClickedNode` is non-nil, that's the target —
    ///      regardless of selection. Returns its `.row` (nil for
    ///      folders).
    ///   2. Otherwise, require exactly one node in the selection AND
    ///      that node to be a leaf. Multi-row / folder-selection /
    ///      empty-selection all return nil.
    ///
    /// The caller still runs `canDiff` on the returned row to gate on
    /// upstream's "files-different-on-both-sides" predicate.
    static func diffTarget(
        rightClickedNode: ReconcileNode?,
        selectedNodes: [ReconcileNode]
    ) -> Int? {
        if let rc = rightClickedNode {
            return rc.row  // nil when the right-clicked node is a folder
        }
        guard selectedNodes.count == 1 else { return nil }
        return selectedNodes[0].row  // nil for folders
    }

    // NOTE: the former `clearOverrides` helper (a pure "drop the Swift override"
    // dict op) was removed with Finding #2 — it encoded the original defect
    // (clearing the visual override without reverting the OCaml direction). Revert
    // now goes through `revertSelectionAction` → `unison_bridge_ri_revert`, which
    // resets the engine and clears the override together.

    /// Whether a row can be reverted to Unison's recommendation. True when the
    /// row diverges from the engine default (`changedFromDefault` — covers plain
    /// First/Second/Merge, which leave no visual override) OR carries a
    /// visual-intent override such as Skip/Force (so a Force whose result equals
    /// the default direction is still revertible, to clear its badge).
    static func isRevertible(changedFromDefault: Bool, hasOverride: Bool) -> Bool {
        changedFromDefault || hasOverride
    }
}
