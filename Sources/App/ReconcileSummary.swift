import AppKit

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
/// **Output forms** (one row per `Phase` × interesting items state):
///
/// | Phase | Example |
/// | --- | --- |
/// | `.ready`, items to sync | `121 items · 1.2 GB · 121 First → Second` |
/// | `.ready`, empty | `Everything is up to date` |
/// | `.syncing`, items | `Synchronizing · 121 items · 1.2 GB · 121 First → Second` |
/// | `.done(failures: 0)`, items | `Synchronization complete · 121 items · 1.2 GB · 121 First → Second` |
/// | `.done(failures: 5)`, items | `Synchronization completed with 5 errors · 121 items · 1.2 GB · 121 First → Second` |
/// | `.done(failures: 0)`, empty | `Synchronization complete · nothing to transfer` |
///
/// The `.syncing` line stays visible the whole transfer — keeps the
/// at-a-glance totals in front of the user while the global progress
/// bar + per-row Progress cells carry the dynamic state.
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

    /// Lifecycle phase the reconcile window is in when the summary
    /// is built. Mutually exclusive — three states cover everything.
    enum Phase: Equatable {
        /// Post-init2, pre-Go: rows displayed, ready for user action.
        /// Summary has no status word; the count is the lede.
        case ready
        /// Post-Go, pre-completion: sync in flight.
        /// Summary prefixes "Synchronizing" so the user still sees
        /// the breakdown while the transfer runs.
        case syncing
        /// Post-completion: terminal state for the current sync.
        /// `failures` is the count of rows whose progress ended as
        /// FAILED. Zero → "Synchronization complete"; non-zero →
        /// "Synchronization completed with N error(s)".
        case done(failures: Int)
    }

    /// Build the displayed summary for the given items and phase.
    static func text(items: [StateItem], phase: Phase = .ready) -> String {
        // Build the leading status word (if any). Done-with-errors
        // uses past-tense "completed" because it flows naturally with
        // the "with N errors" clause; the clean-done case uses
        // adjectival "complete" because it reads better as a label.
        // Different forms in different states is deliberate.
        let statusPrefix: String?
        switch phase {
        case .ready:
            statusPrefix = nil
        case .syncing:
            statusPrefix = "Synchronizing"
        case .done(let failures):
            if failures > 0 {
                let noun = failures == 1 ? "error" : "errors"
                statusPrefix = "Synchronization completed with \(failures) \(noun)"
            } else {
                statusPrefix = "Synchronization complete"
            }
        }

        // Empty-items special case: skip the count breakdown entirely
        // and substitute a single explicit phrase. "Everything is up
        // to date" reads as a positive outcome after a clean scan;
        // "nothing to transfer" covers the rare post-sync-with-zero-
        // items case. Mid-sync with zero items is a weird state we
        // shouldn't normally hit (the user wouldn't have clicked Go
        // on an empty list) — fall through to the same nothing-to-
        // transfer phrasing for safety.
        if items.isEmpty {
            switch phase {
            case .ready:
                return "Everything is up to date"
            case .syncing, .done:
                return "\(statusPrefix ?? "")  ·  nothing to transfer"
            }
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

    /// Leading-icon + tint emphasis for a *finished* sync, shown next to
    /// the summary label so "complete" reads at a glance instead of
    /// blending into the same neutral line as every other status. Pure
    /// (returns an `NSColor` like `DirectionVisual.tint`) so the
    /// symbol/tint choice is testable without AppKit UI. Only meaningful
    /// for the `.done` phase — callers apply it in `syncDidComplete`.
    ///
    /// Colors match the app's existing palette: success = systemGreen
    /// (the `→ Second` direction tint), errors = systemRed (the FAILED
    /// row / Stop tint).
    struct CompletionEmphasis: Equatable {
        let symbolName: String
        let tint: NSColor
    }

    static func completionEmphasis(failures: Int) -> CompletionEmphasis {
        if failures > 0 {
            return CompletionEmphasis(symbolName: "exclamationmark.triangle.fill",
                                      tint: .systemRed)
        }
        return CompletionEmphasis(symbolName: "checkmark.circle.fill",
                                  tint: .systemGreen)
    }
}
