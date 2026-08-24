import Foundation

/// The pure selection/mutation guards for the Clean Stale window, extracted so
/// each can be unit-verified (removing one now fails a test). The window
/// delegates its three guards to these: which rows may be selected (Select-All
/// and the checkbox-enabled state), which hashes the mutation authority may act
/// on (checked AND actionable), and the per-row reason a report-only row is
/// disabled.
enum CleanStalePolicy {

    /// Row indices that may be selected — actionable rows only. Non-actionable
    /// (report-only) rows are never selectable.
    static func selectableIndices(actionable: [Bool]) -> [Int] {
        actionable.indices.filter { actionable[$0] }
    }

    /// The hashes the mutation authority may act on: checked AND actionable. A
    /// non-actionable row is excluded even if some stale UI state marked it
    /// checked. (`actionable`, `checked`, and `hashes` are parallel arrays.)
    static func mutationHashes(hashes: [String], actionable: [Bool], checked: [Bool]) -> [String] {
        hashes.indices
            .filter { $0 < actionable.count && $0 < checked.count && actionable[$0] && checked[$0] }
            .map { hashes[$0] }
    }

    /// A concrete explanation for a non-actionable (report-only) row, shown so
    /// the user understands why its checkbox is disabled. Nil when actionable.
    static func refusalReason(actionable: Bool,
                              uncertain: Bool,
                              reason: ArchiveStaleScanner.Reason) -> String? {
        if actionable { return nil }
        if uncertain {
            return "Report-only: this archive can't be attributed with certainty "
                + "(it may involve a remote replica, contain ambiguous roots, or "
                + "belong to a profile with unresolved includes)."
        }
        switch reason {
        case .orphan:
            return "Report-only: no current profile uses this archive (orphan)."
        case .superseded:
            return "Report-only: this looks like an old copy, but no current live "
                + "archive was found to supersede it."
        }
    }
}
