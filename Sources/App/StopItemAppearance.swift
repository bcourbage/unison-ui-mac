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
    /// Scan phase over a QUALIFIED direct-ssh transport (Phase 1a, issue #24):
    /// the item genuinely interrupts the running scan in-process (SIGKILL the
    /// transport child → unwind → stop in place). Only offered when the
    /// session's `ssh -G` qualification proved a direct single-child transport;
    /// otherwise the honest `.returnToProfiles` is shown.
    case stopScan

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
        case .stopScan:         return "Stop Scan"
        }
    }

    var toolTip: String {
        switch self {
        case .stopSync:         return "Cancel the running synchronization"
        case .returnToProfiles: return "Return to the profile list"
        case .stopScan:         return "Interrupt the running scan and stop"
        }
    }

    /// SF Symbol for the item. The connect/scan affordance uses a neutral
    /// back-navigation glyph, NOT the red stop sign, because it does not
    /// interrupt the scan — it returns to the picker. `.stopScan` genuinely
    /// interrupts, so it takes the stop glyph.
    var systemSymbol: String {
        switch self {
        case .stopSync:         return "stop.fill"
        case .returnToProfiles: return "chevron.backward"
        case .stopScan:         return "stop.fill"
        }
    }

    /// Only a real sync-abort is destructive-tinted (red). Return-to-profiles
    /// is ordinary navigation and takes the normal tint. A genuine scan
    /// interruption stops in-flight engine work, so it is destructive-tinted
    /// like a sync-abort.
    var tint: Tint {
        switch self {
        case .stopSync:         return .destructive
        case .returnToProfiles: return .normal
        case .stopScan:         return .destructive
        }
    }

    /// The in-progress summary shown when the item is invoked.
    var progressSummary: String {
        switch self {
        case .stopSync:         return "Aborting sync… in-progress transfers may finish before the abort takes effect"
        case .returnToProfiles: return "Returning to profiles…"
        case .stopScan:         return "Stopping scan…"
        }
    }

    /// Decide from the controller's phase flags. Sync takes precedence: once a
    /// sync is running the item is a sync-abort even though `isScanning` may
    /// still read true during the transition. In the scan phase, the item
    /// becomes a genuine `.stopScan` only when the session's transport qualified
    /// for in-process interruption; otherwise it stays the honest
    /// `.returnToProfiles`.
    static func forPhase(isScanning: Bool, isSyncing: Bool,
                         scanInterruptAvailable: Bool = false) -> StopItemAppearance {
        guard isScanning && !isSyncing else { return .stopSync }
        return scanInterruptAvailable ? .stopScan : .returnToProfiles
    }
}
