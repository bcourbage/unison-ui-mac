import AppKit

/// Single source of truth for the "NSTextView inside an NSScrollView"
/// geometry. A programmatically created `NSTextView` set as a scroll
/// view's `documentView` renders correctly under newer SDKs but
/// misbehaves under older-SDK / Release builds unless an explicit frame
/// + resizing + text-container setup is applied — it either paints
/// BLANK (string is in the model, never drawn) or refuses to scroll
/// long content. That trap bit four separate views here before this
/// helper existed (the reconcile details footer, the Diff window, the
/// Profile Editor list fields, and the status-details alert). Routing
/// every scrollable text view through this one place makes the bug
/// class impossible to reintroduce by copy-paste drift. See Apple's
/// "Putting an NSTextView in an NSScrollView".
///
/// Tested in `ScrollableTextViewTests`. Note the *symptom* is
/// Release-only, but the *cause* — the properties set here — is
/// identical in Debug and Release, so a Debug config-assertion test is
/// a faithful regression guard for a defect that never reproduces in
/// the test environment.
@MainActor
enum ScrollableTextView {

    /// Line-wrapping behaviour of the hosted text view.
    enum Mode {
        /// Wrap to the (fixed) width; scroll vertically only. For prose,
        /// status dumps, path lists.
        case wrap
        /// Don't wrap — long lines scroll horizontally. For code / diff
        /// output where wrapping would mangle column alignment.
        case noWrap
    }

    /// Apply the canonical geometry to an existing text view + scroll
    /// view pair and wire the text view in as the document view.
    ///
    /// Sets ONLY the bug-prone geometry and scroller flags. Callers keep
    /// ownership of behaviour/appearance — font, `isEditable`,
    /// `textContainerInset`, `borderType`, background, `autohidesScrollers`,
    /// the find bar, and Auto Layout flags — none of which were ever the
    /// cause of the blank/clip bug.
    static func configure(text: NSTextView,
                          scroll: NSScrollView,
                          mode: Mode,
                          initialSize: NSSize) {
        text.frame = NSRect(origin: .zero, size: initialSize)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        // Required for the view to grow with content and thus for the
        // scroll view to scroll. Its absence is what clipped long status
        // dumps with a dead scroller.
        text.isVerticallyResizable = true

        switch mode {
        case .wrap:
            text.isHorizontallyResizable = false
            // `.width` only — pairing `.height` with vertical resizing
            // fights the content-driven height.
            text.autoresizingMask = [.width]
            text.textContainer?.containerSize =
                NSSize(width: initialSize.width, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
        case .noWrap:
            text.isHorizontallyResizable = true
            text.autoresizingMask = [.width, .height]
            text.textContainer?.containerSize =
                NSSize(width: CGFloat.greatestFiniteMagnitude,
                       height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = false
        }

        scroll.documentView = text
        scroll.hasVerticalScroller = true
        // A horizontal scroller only makes sense when lines don't wrap.
        scroll.hasHorizontalScroller = (mode == .noWrap)
    }

    /// Convenience for call sites that don't already hold the instances
    /// (e.g. a text view built locally inside a method). Creates a fresh
    /// pair, applies `configure`, and returns both. Callers still set
    /// font / border / content afterwards.
    static func make(mode: Mode, initialSize: NSSize)
        -> (scroll: NSScrollView, text: NSTextView)
    {
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: initialSize))
        let text = NSTextView(frame: NSRect(origin: .zero, size: initialSize))
        configure(text: text, scroll: scroll, mode: mode, initialSize: initialSize)
        return (scroll, text)
    }
}
