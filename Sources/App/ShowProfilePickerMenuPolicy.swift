import Foundation

/// Enablement policy for the **Action ▸ Show Profile Picker** menu command
/// (issue #38). This command is an app-global navigation action; it is owned by
/// `AppDelegate` with an EXPLICIT target so its validation never depends on
/// transient responder-chain resolution (the intermittent first-menu-open race
/// that greyed the whole Action menu during `.opening`). Pure so the rule is
/// unit-testable without an AppKit/menu harness.
///
/// Authoritative inputs: whether a reconcile session currently exists (the
/// command navigates that session back to the picker) and the coordinator's
/// phase. Navigation is available in every phase EXCEPT `.syncing` — closing
/// mid-sync must go through the window's three-way sync-confirmation prompt, so
/// the menu shortcut is greyed to avoid bypassing it. With no reconcile session
/// (already at the picker) there is nothing to navigate, so it is disabled.
enum ShowProfilePickerMenuPolicy {
    static func enabled(hasReconcileSession: Bool,
                        phase: EngineSessionCoordinator.Phase) -> Bool {
        guard hasReconcileSession else { return false }
        if case .syncing = phase { return false }
        return true
    }
}
