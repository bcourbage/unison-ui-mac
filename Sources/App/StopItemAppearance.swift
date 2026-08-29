import Foundation

/// Pure decision for the Stop toolbar/menu item's presentation.
///
/// The item means exactly one thing: abort a running synchronization. It is
/// enabled and destructive-tinted only while a sync is in flight; in every
/// other phase it is a disabled, neutral "Stop". Returning to the profile list
/// during a connect/scan is the Profiles control's job, not this item's
/// (issue #117), so this type no longer relabels to "Return to Profiles".
///
/// Presentation is derived from a single `canStop` verdict, which the caller
/// takes from the shared `ReconcileActionGate` (`allows(.stop)`). Enablement and
/// tint therefore cannot disagree: if the gate disables the item (for example a
/// restart became required while a sync flag was still set), it is also painted
/// neutral, never a disabled-but-red control.
///
/// The title is constant, which is also what keeps the toolbar item a constant
/// width so neighbouring items (Go) do not reflow between phases — the spatial
/// half of issue #117.
///
/// Extracted as a pure type so the copy/tint decision is unit-testable without
/// an AppKit UI harness (same posture as `RowSelectionRules`).
struct StopItemAppearance: Equatable {
    /// The shared gate's verdict for `.stop`: a sync is in flight and no restart
    /// is required. Drives enablement at the call site and the tint here, from
    /// one source, so the two can never disagree.
    let canStop: Bool

    /// Semantic tint, mapped to a concrete `NSColor` by the toolbar. Kept as a
    /// value (not `NSColor`) so this type stays AppKit-free and the tint is
    /// exactly assertable in tests. `.destructive` → red; `.normal` → the
    /// default toolbar tint (no accent).
    enum Tint: Equatable {
        case normal
        case destructive
    }

    /// The title never changes — the item is always "Stop".
    var title: String { "Stop" }

    /// Always the stop glyph; there is no phase-dependent icon swap.
    var systemSymbol: String { "stop.fill" }

    /// Destructive (red) only when the sync-abort is actually available;
    /// neutral when the item is disabled.
    var tint: Tint { canStop ? .destructive : .normal }

    /// Describes the single action. Present in both states so the disabled item
    /// still explains itself.
    var toolTip: String { "Cancel the running synchronization" }
}
