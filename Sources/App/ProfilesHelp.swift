import Foundation

/// Pure decision for the Profiles toolbar item's help text (tooltip and
/// accessibility help), which is phase-dependent.
///
/// Profiles is the single navigation-back-to-the-picker control. Its position
/// and label never change; only the help text varies, to state the actual
/// consequence of leaving in each phase (issue #117):
///
/// - **Idle** (results shown, or a completed run): it simply returns to the
///   picker.
/// - **Connecting/scanning**: `isScanning` covers both connection setup and the
///   change scan. Leaving abandons the presentation; the connection or scan
///   winds down in the background (in-place scan interruption was withdrawn,
///   issue #53 / #94).
/// - **Synchronizing**: leaving routes through the window-close path, which
///   raises the three-way "still running" confirmation.
///
/// Varying help text is spatially inert (no label/width change), so it does not
/// reintroduce the reflow that motivated #117. Extracted as a pure type so the
/// copy decision is unit-testable without an AppKit UI harness.
enum ProfilesHelp: Equatable {
    case idle
    case connectingOrScanning
    case synchronizing

    /// Tooltip text for the current phase.
    var toolTip: String {
        switch self {
        case .idle:
            return "Return to Profiles."
        case .connectingOrScanning:
            return "Return to Profiles. The current connection or scan continues in the background."
        case .synchronizing:
            return "Return to Profiles. A confirmation appears while synchronization is running."
        }
    }

    /// Accessibility help. Same wording as the tooltip; kept as its own accessor
    /// so a future divergence has a single place to live.
    var accessibilityHelp: String { toolTip }

    /// Sync takes precedence over scan, matching `StopItemAppearance`/gate
    /// ordering: once a sync is running the leave semantics are the sync
    /// confirmation even if a scan flag is still settling.
    static func forPhase(isScanning: Bool, isSyncing: Bool) -> ProfilesHelp {
        if isSyncing { return .synchronizing }
        if isScanning { return .connectingOrScanning }
        return .idle
    }
}
