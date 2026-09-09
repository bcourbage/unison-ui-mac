import AppKit

/// A popup that takes keyboard focus even when the system's Full Keyboard
/// Access is off. `NSPopUpButton`/`NSButton` normally gate
/// `acceptsFirstResponder` on that system setting, so the Profile Editor's
/// control sections could not be navigated by keyboard without it; these
/// override it to depend only on being enabled and visible.
final class KeyNavPopUpButton: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}

/// A button (checkbox, push, or image) that takes keyboard focus even when Full
/// Keyboard Access is off. See `KeyNavPopUpButton`.
final class KeyNavButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}

/// Collecting the keyboard-focusable controls of a section and locating the one
/// that currently holds focus. Pure and testable.
enum KeyboardFocus {

    /// The focusable controls under `root`, depth-first in subview order (which,
    /// for the stack-view layout, is top-to-bottom then left-to-right): the
    /// enabled, visible `NSControl`s that accept first responder. A label is a
    /// non-editable text field and does not accept it, so labels are excluded.
    @MainActor
    static func focusables(in root: NSView) -> [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) {
            if v.isHidden { return }
            if let c = v as? NSControl, c.isEnabled, c.acceptsFirstResponder {
                out.append(c)
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    /// The index in `controls` of the one holding `responder`. A text field or
    /// combo box is edited through the window's field editor, whose delegate is
    /// the control, so map that back.
    @MainActor
    static func indexOfResponder(_ responder: NSResponder?, in controls: [NSView]) -> Int? {
        guard let responder else { return nil }
        var view = responder as? NSView
        if let text = responder as? NSText, let owner = text.delegate as? NSView { view = owner }
        guard let v = view else { return nil }
        return controls.firstIndex { $0 === v || v.isDescendant(of: $0) }
    }

    /// The next control to focus from `current` (nil = focus is outside the
    /// section). Forward enters at the first control and wraps; backward enters
    /// at the last and wraps.
    static func nextIndex(from current: Int?, count: Int, backward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return backward ? count - 1 : 0 }
        return backward ? (current - 1 + count) % count : (current + 1) % count
    }
}
