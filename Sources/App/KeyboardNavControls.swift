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
            if let c = v as? NSControl, c.isEnabled, isNavigable(c) {
                out.append(c)
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    /// Whether a control participates in keyboard navigation, by type rather
    /// than by `acceptsFirstResponder`: a combo box reports the latter false
    /// while it is being edited (its field editor is the responder), which
    /// would drop it from the list mid-edit and strand Tab on the first row.
    /// Labels are non-editable text fields and are excluded.
    @MainActor
    private static func isNavigable(_ c: NSControl) -> Bool {
        if c is NSComboBox || c is NSPopUpButton || c is NSButton { return true }
        if let field = c as? NSTextField { return field.isEditable }
        return false
    }

    /// The index in `controls` of the one holding `responder`. A text field is
    /// edited through the window's field editor, whose delegate is the field; a
    /// combo box's field editor delegate is not the combo, so walk the responder
    /// chain up to the owning control instead of relying on the delegate alone.
    @MainActor
    static func indexOfResponder(_ responder: NSResponder?, in controls: [NSView]) -> Int? {
        // A non-text control is first responder itself.
        if let v = responder as? NSView, let i = controls.firstIndex(where: { $0 === v }) { return i }
        // A text field or combo box being edited holds the window's field editor;
        // currentEditor() names the control whose editor it is (the combo's
        // field-editor delegate is not the combo, so this is the reliable map).
        if let text = responder as? NSText {
            for (i, c) in controls.enumerated() where (c as? NSControl)?.currentEditor() === text { return i }
        }
        // Fallback: walk the responder/view ancestry.
        var r = responder
        while let cur = r {
            if let v = cur as? NSView,
               let i = controls.firstIndex(where: { $0 === v || v.isDescendant(of: $0) }) {
                return i
            }
            r = cur.nextResponder
        }
        return nil
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
