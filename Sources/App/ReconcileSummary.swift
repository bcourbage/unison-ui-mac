import Foundation

/// Builds the one-line summary that appears above the reconcile
/// outline view. Status word (when there is one) always leads; the
/// profile name is intentionally NOT included here — the window
/// title carries it, so repeating it just costs pixels. Direction
/// phrasing reads `<count> <source> → <destination>` so a bare
/// `121 → second` can't be misread as a rate.
///
/// Extracted from `ReconcileWindowController` as a pure function so
/// the breakdown logic — which rows count toward which bucket;
/// whether the bytes total appears; how partial-success summaries
/// are phrased — is testable without standing up AppKit.
///
/// **Output forms**:
///
/// | State | Example |
/// | --- | --- |
/// | Ready, items to sync | `121 items · 1.2 GB · 121 First → Second` |
/// | Ready, empty (nothing to do) | `Everything is up to date` |
/// | Sync done, all clean | `Synchronization complete · 121 items · 1.2 GB · 121 First → Second` |
/// | Sync done, partial failure | `Synchronization completed with 5 errors · 121 items · 1.2 GB · 121 First → Second` |
/// | Sync done, zero items | `Synchronization complete · nothing to transfer` |
///
/// **Override-awareness**: this function intentionally keys off
/// `items[].direction` only, not any user-applied row override. That
/// matches what every other count in the reconcile UI does — once a
/// user overrides a row, the summary still reads from the raw Unison
/// state until the next rescan. Consistency over precision.
enum ReconcileSummary {

    /// Direction strings as Unison emits them via `unisonRiToDirection`.
    /// Mirrors what's already pinned in tests around `DirectionVisual`
    /// and `DirectionAction`. Centralized here so `text(items:...)`
    /// doesn't sprinkle magic literals.
    static let directionToFirst  = "<----"
    static let directionToSecond = "---->"
    static let directionConflict = "<-?->"

    /// Build the displayed summary.
    ///
    /// - Parameters:
    ///   - items: the current row set (after init2 or after sync).
    ///   - syncDone: `true` after `Util.syncComplete` fires; controls
    ///     prefix wording.
    ///   - failedRows: how many rows ended the sync in a FAILED state.
    ///     Only meaningful when `syncDone == true`; ignored otherwise.
    ///     When > 0 the prefix shifts from "Synchronization complete"
    ///     to "Synchronization completed with N error(s)" so the
    ///     partial-success outcome is visible in the summary itself,
    ///     not only in the separate error-banner button.
    static func text(items: [StateItem],
                     syncDone: Bool = false,
                     failedRows: Int = 0) -> String {
        // Build the leading status word (if any). Done-with-errors
        // uses past-tense "completed" because it flows naturally with
        // the "with N errors" clause; the clean-done case uses
        // adjectival "complete" because it reads better as a label.
        // Different forms in different states is deliberate.
        let statusPrefix: String?
        if syncDone {
            if failedRows > 0 {
                let noun = failedRows == 1 ? "error" : "errors"
                statusPrefix = "Synchronization completed with \(failedRows) \(noun)"
            } else {
                statusPrefix = "Synchronization complete"
            }
        } else {
            statusPrefix = nil
        }

        // Empty-items special case: skip the count breakdown entirely
        // and substitute a single explicit phrase. "Everything is up
        // to date" reads as a positive outcome after a clean scan;
        // "nothing to transfer" covers the rare post-sync-with-zero-
        // items case (every row got skipped before Go, etc.).
        if items.isEmpty {
            if syncDone {
                return "\(statusPrefix ?? "")  ·  nothing to transfer"
            }
            return "Everything is up to date"
        }

        let total = items.count
        let conflicts = items.filter { $0.direction == directionConflict }.count
        let toLeft    = items.filter { $0.direction == directionToFirst  }.count
        let toRight   = items.filter { $0.direction == directionToSecond }.count
        let other     = total - conflicts - toLeft - toRight

        // Total bytes that will move in *this* reconcile if the user
        // hits Go right now. Counts only rows with a clear direction
        // arrow (`<----` / `---->`); conflicts and `<-M->` merge rows
        // are excluded — conflicts won't transfer until resolved, and
        // merge runs an external command whose byte output we can't
        // predict ahead of time. Negative `sizeBytes` (shouldn't
        // happen but be defensive) is clamped to 0 so an arithmetic
        // glitch in upstream Unison's size field can't produce a
        // nonsensical negative total.
        let transferBytes = items
            .filter { $0.direction == directionToFirst
                   || $0.direction == directionToSecond }
            .reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }

        var parts: [String] = []
        if let statusPrefix { parts.append(statusPrefix) }
        parts.append("\(total) items")
        if transferBytes > 0 {
            parts.append(ByteCountFormatter.string(
                fromByteCount: transferBytes, countStyle: .file))
        }
        if conflicts > 0 { parts.append("\(conflicts) conflicts") }
        // Direction breakdowns spell source AND destination so the
        // summary reads unambiguously without leaning on the column
        // headers for context. Arrow always points left-to-right in
        // the reading direction (source on the left, destination on
        // the right), regardless of whether the data flow is toward
        // First or toward Second — the source word in front of the
        // arrow tells the user which side started where.
        if toLeft > 0    { parts.append("\(toLeft) Second → First") }
        if toRight > 0   { parts.append("\(toRight) First → Second") }
        if other > 0     { parts.append("\(other) other") }
        return parts.joined(separator: "  ·  ")
    }
}
