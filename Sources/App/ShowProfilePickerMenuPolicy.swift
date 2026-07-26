import Foundation

/// Routing decision for the **Action ▸ Show Profile Picker** menu command
/// (issue #38). This command is app-global navigation owned by `AppDelegate`
/// with an EXPLICIT target, so its validation/dispatch no longer depends on
/// transient responder-chain resolution — an intermittent responder-chain /
/// menu-validation failure that occasionally greyed the item at first menu-open
/// during `.opening`, eliminated by the explicit target.
///
/// A SINGLE decision drives both `validateMenuItem` (enabled iff not
/// `.unavailable`) and the action (which re-evaluates it at its own boundary so
/// menu validation is not the only authority). Three navigable states:
///
/// - `.currentSession` — a live reconcile session exists and the coordinator is
///   not `.syncing` (closing mid-sync must go through the window's three-way
///   sync-confirmation prompt, so the menu shortcut is disabled then).
/// - `.waitingRequest` — a queued-open **waiting window** exists (a replacement
///   the user queued behind an abandoned operation). Navigating cancels that
///   exact queued request. Enabled even if the ABANDONED engine op is syncing —
///   it is the old op that may be syncing, not this waiting request. Takes
///   precedence: a waiting window is the front, actionable target.
/// - `.unavailable` — picker-only / nothing to navigate.
enum ShowProfilePickerMenuTarget: Equatable {
    case currentSession
    case waitingRequest
    case unavailable
}

enum ShowProfilePickerMenuPolicy {
    static func route(hasCurrentSession: Bool,
                      phase: EngineSessionCoordinator.Phase,
                      hasWaitingWindow: Bool) -> ShowProfilePickerMenuTarget {
        if hasWaitingWindow { return .waitingRequest }
        if hasCurrentSession {
            if case .syncing = phase { return .unavailable }
            return .currentSession
        }
        return .unavailable
    }
}
