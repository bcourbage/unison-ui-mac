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
///   picker (the scan itself is not interrupted in-process — it winds down in
///   the background). Labelling that "Stop" / "Cancel the running
///   synchronization" overstates what happens, so the item is relabelled
///   "Return to Profiles" with a matching summary ("Returning to profiles…").
///
/// In-place scan interruption was withdrawn (issue #53, declined; the dormant
/// machinery removed in #94), so the scan phase always shows the honest
/// `.returnToProfiles`.
///
/// Extracted as a pure type so the copy decision is unit-testable without an
/// AppKit UI harness (same posture as `RowSelectionRules`).
enum StopItemAppearance: Equatable {
    /// A sync is in flight: the item aborts it.
    case stopSync
    /// Connect/scan phase, nothing to abort: the item returns to the picker.
    case returnToProfiles

    /// Semantic tint, mapped to a concrete `NSColor` by the toolbar. Kept as a
    /// value (not `NSColor`) so this type stays AppKit-free and the tint is
    /// exactly assertable in tests. `.destructive` → red; `.normal` → the
    /// default toolbar tint (no accent).
    enum Tint: Equatable {
        case normal
        case destructive
    }

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

    /// SF Symbol for the item. The connect/scan affordance uses a neutral
    /// back-navigation glyph, NOT the red stop sign, because it does not
    /// interrupt the scan — it returns to the picker.
    var systemSymbol: String {
        switch self {
        case .stopSync:         return "stop.fill"
        case .returnToProfiles: return "chevron.backward"
        }
    }

    /// Only a real sync-abort is destructive-tinted (red). Return-to-profiles
    /// is ordinary navigation and takes the normal tint.
    var tint: Tint {
        switch self {
        case .stopSync:         return .destructive
        case .returnToProfiles: return .normal
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
    /// still read true during the transition. In the scan phase the item is the
    /// honest `.returnToProfiles` (in-place scan interruption is not offered).
    static func forPhase(isScanning: Bool, isSyncing: Bool) -> StopItemAppearance {
        guard isScanning && !isSyncing else { return .stopSync }
        return .returnToProfiles
    }
}
