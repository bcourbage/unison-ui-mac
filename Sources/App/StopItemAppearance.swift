import Foundation

/// Pure decision for the Stop toolbar item's user-facing copy.
///
/// The single "Stop" item does double duty across two phases, and the honest
/// label differs:
///
/// - **During an actual sync** it aborts the running synchronization (sets
///   OCaml's `Abort` flag; transfers unwind at the next checkpoint). Label
///   "Stop".
/// - **During the connect/scan phase (pre-sync)** there is no sync to abort.
///   The action abandons the in-flight connect and returns to the profile
///   picker (the scan itself is not interrupted in-process today — it winds
///   down in the background). Labelling that "Stop" / "Cancel the running
///   synchronization" overstates what happens, so the item is relabelled
///   "Return to Profiles" with a matching summary ("Returning to profiles…").
///
/// Extracted as a pure type so the copy decision is unit-testable without an
/// AppKit UI harness (same posture as `RowSelectionRules`). If a future Phase
/// 1a genuinely interrupts the scan in-process, the pre-sync case can become a
/// real "Stop Scan" rather than a return-to-profiles.
enum StopItemAppearance: Equatable {
    /// A sync is in flight: the item aborts it.
    case stopSync
    /// Connect/scan phase, nothing to abort: the item returns to the picker.
    case returnToProfiles

    var label: String {
        switch self {
        case .stopSync:         return "Stop"
        case .returnToProfiles: return "Return to Profiles"
        }
    }

    var toolTip: String {
        switch self {
        case .stopSync:         return "Cancel the running synchronization"
        case .returnToProfiles: return "Return to the profile list"
        }
    }

    /// The in-progress summary shown when the item is invoked.
    var progressSummary: String {
        switch self {
        case .stopSync:         return "Aborting sync… in-progress transfers may finish before the abort takes effect"
        case .returnToProfiles: return "Returning to profiles…"
        }
    }

    /// Decide from the controller's phase flags. Sync takes precedence: once a
    /// sync is running the item is a sync-abort even though `isScanning` may
    /// still read true during the transition.
    static func forPhase(isScanning: Bool, isSyncing: Bool) -> StopItemAppearance {
        (isScanning && !isSyncing) ? .returnToProfiles : .stopSync
    }
}
