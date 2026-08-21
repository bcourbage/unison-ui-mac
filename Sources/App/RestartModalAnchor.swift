import Foundation

/// Pure anchor-selection for the restart-required / fatal modal notice
/// (issue #35 correction 1). Kept separate from AppKit so it is deterministically
/// testable.
///
/// `AppDelegate.profileWindowController` may still OWN a closed, invisible picker
/// window while a reconcile or waiting window is on screen — anchoring a sheet to
/// that invisible picker would attach the modal to a window the user cannot see.
/// So the choice is made on VISIBILITY, in priority order:
///   1. the first visible reconcile/waiting (session) window — the modal appears
///      on the window the failure relates to;
///   2. otherwise the picker, only if it is actually visible;
///   3. otherwise app-modal (no anchor).
enum RestartModalAnchor {

    enum Choice: Equatable {
        case window(Int)   // index into the ordered candidate (session-window) list
        case picker
        case appModal
    }

    /// - Parameters:
    ///   - candidatesVisible: visibility of the ordered reconcile/waiting windows.
    ///   - pickerVisible: whether the picker window is currently visible.
    static func choose(candidatesVisible: [Bool], pickerVisible: Bool) -> Choice {
        if let i = candidatesVisible.firstIndex(where: { $0 }) { return .window(i) }
        return pickerVisible ? .picker : .appModal
    }
}
