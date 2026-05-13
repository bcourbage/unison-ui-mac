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

    /// Apply "Revert to Recommendation" to a set of rows. Returns the
    /// new override dict — the controller installs it after calling
    /// the bridge to reset each row's direction on the OCaml side.
    ///
    /// Semantics: for each requested row, drop any user override so
    /// the row falls back to OCaml's auto-detected direction. Rows
    /// NOT in `revertRows` are left untouched.
    ///
    /// Pure dict operation — doesn't touch OCaml. The caller is
    /// responsible for re-resolving the OCaml side (typically by
    /// calling `unisonRiToDirection` on each row, since we want to
    /// see what OCaml would have chosen now that our override is
    /// gone). For rows that were `.skip` (which sets OCaml to
    /// `Conflict "skip requested"`), the caller may want to call
    /// `unisonRiResetConflict` — currently unimplemented (no upstream
    /// callback for "clear the conflict"); for v1 we just clear the
    /// Swift-side override and let the row continue to show as a
    /// conflict, which is what OCaml's reconciler thinks anyway.
    static func clearOverrides(
        rowOverrides: [Int: RowOverride],
        forRows revertRows: Set<Int>
    ) -> [Int: RowOverride] {
        var next = rowOverrides
        for row in revertRows { next.removeValue(forKey: row) }
        return next
    }
}
