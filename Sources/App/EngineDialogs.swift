import AppKit

/// The alerts that carry engine text to the user: a warning the engine asks
/// about before continuing, a fatal error, and the restart-required notice
/// that follows a fatal. Engine text can run to many lines (the first-sync
/// warning explains canonical paths, archive formats and propagation rules),
/// and a fatal often ends in a long path, so the alerts keep their own text
/// short and carry the complete diagnostic in a scrolling, selectable
/// details area with a Copy Details button. Nothing is truncated.
@MainActor
enum EngineDialogs {

    static let warningTitle = "Unison warning"
    static let fatalTitle = "Unison error"
    static let restartTitle = "Unison needs to be restarted"
    static let restartInstruction = "Quit Unison and open it again to continue."
    static let restartRemoteCheckOffer = "You can check the remote command for this profile first."
    static let continueButton = "Continue"
    static let cancelButton = "Cancel"
    static let copyDetailsButton = "Copy Details"

    /// The engine asked whether to continue (Unison's `warn`). The first line
    /// of its message is the summary; the whole message is in Details. The
    /// caller adds the buttons, Continue first and Cancel second.
    static func warningAlert(text: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warningTitle
        attachSummaryAndDetails(alert, text: text)
        return alert
    }

    /// A fatal engine error. The caller adds the recovery buttons.
    static func fatalAlert(text: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = fatalTitle
        attachSummaryAndDetails(alert, text: text)
        return alert
    }

    /// The app-level restart notice. Its own text is the recovery action; the
    /// error that caused it, already shown once by the fatal alert, is in
    /// Details so it is not repeated in the body and never cut short. The
    /// caller adds the buttons.
    static func restartAlert(reason: String, remoteCheckOffered: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = restartTitle
        alert.informativeText = remoteCheckOffered
            ? restartInstruction + " " + restartRemoteCheckOffer
            : restartInstruction
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            alert.accessoryView = detailsAccessory(text: trimmed)
        }
        return alert
    }

    /// First non-empty line of `text`, for an alert's summary line.
    nonisolated static func summaryLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text
    }

    /// Summary in the alert body; the complete text in Details when there is
    /// more than the summary.
    private static func attachSummaryAndDetails(_ alert: NSAlert, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summaryLine(of: trimmed)
        alert.informativeText = summary
        if trimmed != summary {
            alert.accessoryView = detailsAccessory(text: trimmed)
        }
    }

    /// A scrolling, selectable, read-only text area holding `text` in full,
    /// with a Copy Details button beneath. Sized for an alert accessory.
    ///
    /// NSAlert lays its accessory out from the view's FRAME and widens the
    /// alert to fit it; an Auto Layout view with no frame is placed at its
    /// zero size and overflows the alert. So this view is frame-based.
    static func detailsAccessory(text: String,
                                 width: CGFloat = 400,
                                 maxHeight: CGFloat = 200,
                                 pasteboard: NSPasteboard = .general) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        let needed = attributed.boundingRect(
            with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 16
        let height = min(max(needed, 44), maxHeight)

        let copy = CopyTextButton(title: copyDetailsButton, text: text, pasteboard: pasteboard)
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copy.sizeToFit()
        let gap: CGFloat = 6
        let buttonHeight = copy.frame.height

        let (scroll, textView) = ScrollableTextView.make(mode: .wrap, initialSize: NSSize(width: width, height: height))
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.textStorage?.setAttributedString(attributed)
        textView.setAccessibilityLabel("Details")

        // AppKit's origin is bottom-left, so the button sits at y = 0 and the
        // scroll view above it.
        let container = DetailsAccessoryView(
            frame: NSRect(x: 0, y: 0, width: width, height: height + gap + buttonHeight),
            scroll: scroll)
        copy.frame = NSRect(x: 0, y: 0, width: copy.frame.width, height: buttonHeight)
        scroll.frame = NSRect(x: 0, y: buttonHeight + gap, width: width, height: height)
        scroll.autoresizingMask = [.width]
        container.addSubview(scroll)
        container.addSubview(copy)
        return container
    }
}

/// The frame-based accessory container. Once the alert puts it on screen,
/// the text is scrolled to its beginning: a text view laid out before its
/// window exists can otherwise come up showing its last lines.
@MainActor
final class DetailsAccessoryView: NSView {
    let scroll: NSScrollView

    init(frame: NSRect, scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollToTop()
    }

    func scrollToTop() {
        // NSTextView is flipped, so its origin is the top of the text.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// A button that copies a fixed text to a pasteboard when pressed.
@MainActor
final class CopyTextButton: NSButton {
    let text: String
    let pasteboard: NSPasteboard

    init(title: String, text: String, pasteboard: NSPasteboard) {
        self.text = text
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(copyText(_:))
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    @objc func copyText(_ sender: Any?) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
