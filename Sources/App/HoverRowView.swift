import AppKit

/// Sidebar row that draws its own rounded selection and hover highlights so
/// the two share identical geometry (Claude-style). Selection is "blue"
/// while the window is active (like a standard macOS sidebar) and falls back
/// to the unemphasized gray when it isn't.
final class HoverRowView: NSTableRowView {
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    /// Sidebars stay highlighted while the window is active, regardless of
    /// which control holds focus.
    private var active: Bool { window?.isKeyWindow ?? false }

    // Selection drives the cell's text/glyph color ourselves. With
    // selectionHighlightStyle == .none, AppKit never propagates an
    // emphasized background style to the cell, so we set it directly —
    // and crucially we do it in the draw cycle and on every isSelected
    // change, so the label turns white the instant the row is selected
    // (e.g. on mouse-down), not only after the selection notification.
    override var isSelected: Bool { didSet { needsDisplay = true; applyCellStyle() } }

    private func applyCellStyle() {
        let emphasized = isSelected && active
        let bg: NSView.BackgroundStyle = emphasized ? .emphasized : .normal
        let tint: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        for case let cell as NSTableCellView in subviews {
            if cell.backgroundStyle != bg { cell.backgroundStyle = bg }
            if cell.imageView?.contentTintColor != tint { cell.imageView?.contentTintColor = tint }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyCellStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        applyCellStyle()
        let r = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        if isSelected {
            (active ? NSColor.selectedContentBackgroundColor
                    : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            path.fill()
        } else if hovered {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            path.fill()
        }
    }
}
