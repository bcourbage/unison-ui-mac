import AppKit

/// Displays the result of `runShowDiffs` for one reconcile row. One
/// instance per reconcile session — the same window is reused across
/// multiple Diff invocations, with the title and content updated in
/// place. The window stays open after the reconcile window closes so
/// the user can keep referencing the diff (it's read-only, so the
/// stale association with a now-closed reconcile is harmless).
///
/// **Diff content**: comes straight from Unison's configured `diff`
/// pref command on the OCaml side. With the default value
/// (`diff -u CURRENT1 CURRENT2`) the text is unified-diff format,
/// which we render in a monospaced view with light per-line
/// colorization (`+` = green, `-` = red, `@@` = blue header).
///
/// **Errors**: `displayDiffErr` fires when Unison can't produce a
/// diff (e.g. one side is binary, the row isn't a file). The window
/// switches to an error state — same window, red-tinted message
/// area, no diff text. The user can then dismiss or hit Diff on a
/// different row.
@MainActor
final class DiffWindowController: NSWindowController, NSWindowDelegate {

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "")

    /// Called when the diff window closes, so the owner can cancel any diff
    /// request still in flight (drop its late result; unblock the next diff).
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Diff"
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "DiffWindow"
        window.delegate = self
        configure()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Layout

    private func configure() {
        guard let contentView = window?.contentView else { return }

        headerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.cell?.usesSingleLineMode = true
        // Low horizontal compression resistance. The header changes
        // text dynamically ("Generating diff for <long path>…",
        // titles from displayDiff, error messages) — without this,
        // a long file path could push the diff window wider on each
        // re-binding. Same pathology as the reconcile summary label.
        headerLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // Don't auto-substitute quotes/dashes — diff output uses bare
        // ASCII and we want it to stay byte-faithful.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Canonical NSTextView-in-NSScrollView geometry (see
        // ScrollableTextView). No-wrap so long unified-diff lines scroll
        // horizontally rather than wrap and mangle column alignment.
        ScrollableTextView.configure(text: textView, scroll: scrollView,
                                     mode: .noWrap,
                                     initialSize: NSSize(width: 700, height: 500))
        scrollView.borderType = .lineBorder
        scrollView.autohidesScrollers = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headerLabel, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
    }

    // MARK: - Public API

    /// Bring the window forward; if no diff content is loaded yet,
    /// show a placeholder. Used when the user invokes Diff and the
    /// window needs to surface immediately (the diff itself comes
    /// later via `showDiff`).
    func surfaceForLoading(path: String) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.title = "Diff — \(path)"
        headerLabel.stringValue = "Generating diff for \(path)…"
        headerLabel.textColor = .secondaryLabelColor
        textView.string = ""
        clearTextStyling()
    }

    /// Display a completed diff. `title` is typically the file's
    /// relative path; `text` is the raw output from Unison's
    /// configured `diff` command (default `diff -u`).
    func showDiff(title: String, text: String) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.title = "Diff — \(title)"
        headerLabel.stringValue = title
        headerLabel.textColor = .secondaryLabelColor
        textView.string = text
        applyUnifiedDiffColoring()
    }

    /// Display an error in the diff window — replaces any prior diff
    /// content with the error message in red. Used when
    /// `displayDiffErr` fires (e.g. "Can't diff: path doesn't refer
    /// to a file in both replicas").
    func showError(_ message: String) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.title = "Diff — error"
        headerLabel.stringValue = "Diff failed"
        headerLabel.textColor = .systemRed
        textView.string = message
        clearTextStyling()
    }

    // MARK: - Coloring

    /// Light syntax coloring for unified-diff output:
    ///   - lines starting with `+` (not `+++`) → green (added)
    ///   - lines starting with `-` (not `---`) → red (removed)
    ///   - `@@ ... @@` hunk headers           → blue
    ///   - `+++ filename` / `--- filename`    → bold (file headers)
    /// Everything else stays labelColor. Computed in O(text length)
    /// once per diff load; not incremental — fine because diff
    /// outputs are typically a few hundred lines at most.
    private func applyUnifiedDiffColoring() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        // Reset all attributes first — recycled cells / re-renders
        // would otherwise inherit attributes from the previous diff.
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ], range: full)

        let text = textView.string as NSString
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = text.substring(with: lineRange)
            let (color, isBold) = Self.unifiedDiffLineStyle(line)
            if let color {
                storage.addAttribute(.foregroundColor, value: color, range: lineRange)
            }
            if isBold {
                let bold = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .bold)
                storage.addAttribute(.font, value: bold, range: lineRange)
            }
            lineStart = NSMaxRange(lineRange)
        }
    }

    /// Internal — exposed for tests via `@testable`. Maps one diff
    /// line to (foreground color, isBold). Returns (nil, false) for
    /// lines that should render in the default labelColor.
    /// `nonisolated` so XCTest can call without main-actor hop.
    nonisolated static func unifiedDiffLineStyle(_ line: String)
        -> (color: NSColor?, isBold: Bool)
    {
        // Order matters: check the 3-char prefixes BEFORE the 1-char
        // ones (otherwise `+++` would match the `+` rule).
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return (nil, true)  // file header — bold, no tint
        }
        if line.hasPrefix("@@") {
            return (.systemBlue, false)  // hunk header
        }
        if line.hasPrefix("+") {
            return (.systemGreen, false)  // added line
        }
        if line.hasPrefix("-") {
            return (.systemRed, false)    // removed line
        }
        return (nil, false)
    }

    /// Reset any per-line coloring from a previous diff so error /
    /// loading text renders in plain labelColor.
    private func clearTextStyling() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ], range: full)
    }
}
