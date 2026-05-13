import Foundation

/// Builds the one-line summary that appears above the reconcile
/// outline view ("Sync-Home · 121 items · 450 MB · 121 → second" etc.).
///
/// Extracted from `ReconcileWindowController` as a pure function so
/// the breakdown logic (which rows count toward which bucket; whether
/// the bytes total appears; the post-sync "Synchronized" prefix) is
/// testable without standing up AppKit.
///
/// **Override-awareness**: this function intentionally keys off
/// `items[].direction` only, not any user-applied row override. That
/// matches what every other count in the reconcile UI does — once a
/// user overrides a row, the summary still reads from the raw Unison
/// state until the next rescan. Consistency over precision; an
/// override-aware summary would need to share `rowOverrides` and
/// re-derive the effective direction, and the bookkeeping isn't
/// worth the marginal accuracy gain.
enum ReconcileSummary {

    /// Direction strings as Unison emits them via `unisonRiToDirection`.
    /// Mirrors what's already pinned in tests around `DirectionVisual`
    /// and `DirectionAction`. Centralized here so `text(items:...)`
    /// doesn't sprinkle magic literals.
    static let directionToFirst  = "<----"
    static let directionToSecond = "---->"
    static let directionConflict = "<-?->"

    /// Build the displayed summary. `syncDone == true` swaps the
    /// leading "<profile>" for "Synchronized" — same single source
    /// of truth used both during reconcile and after sync completion.
    static func text(items: [StateItem],
                     profile: String,
                     syncDone: Bool = false) -> String {
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

        var parts = ["\(total) items"]
        if transferBytes > 0 {
            parts.append(ByteCountFormatter.string(
                fromByteCount: transferBytes, countStyle: .file))
        }
        if conflicts > 0 { parts.append("\(conflicts) conflicts") }
        if toLeft > 0    { parts.append("\(toLeft) ← first") }
        if toRight > 0   { parts.append("\(toRight) → second") }
        if other > 0     { parts.append("\(other) other") }
        let prefix = syncDone ? "Synchronized" : profile
        return "\(prefix)  ·  " + parts.joined(separator: "  ·  ")
    }
}
