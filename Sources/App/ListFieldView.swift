import AppKit

/// Re-usable multi-line list field. One entry per line; blank lines
/// dropped on the way out. Exposed to the editor as a `values: [String]`
/// property the editor reads/writes directly.
@MainActor
final class ListFieldView: NSView {

    private let labelField: NSTextField
    private let helpField: NSTextField
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    /// Wrapped continuation lines indent under their entry's first line, so a
    /// long entry that wraps is visually distinct from separate entries.
    private let hangingStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 0
        p.headIndent = 18
        return p
    }()

    // Test seams for the help-label layout regression (round 4).
    var helpTextForTesting: String { helpField.stringValue }
    var helpMaxLinesForTesting: Int { helpField.maximumNumberOfLines }
    var helpFontForTesting: NSFont { helpField.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize) }

    var values: [String] {
        get {
            textView.string
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            textView.string = newValue.joined(separator: "\n")
            if let ts = textView.textStorage {
                ts.addAttribute(.paragraphStyle, value: hangingStyle,
                                range: NSRange(location: 0, length: ts.length))
            }
        }
    }

    init(label: String, help: String) {
        labelField = NSTextField(labelWithString: label)
        helpField = NSTextField(labelWithString: help)
        super.init(frame: .zero)

        labelField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        helpField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpField.textColor = .secondaryLabelColor
        // Backticked examples in the help render as code, not as backticks.
        helpField.attributedStringValue = HelpText.attributed(
            help, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        helpField.lineBreakMode = .byWordWrapping
        // Unrestricted: the escape-grammar help needs 3–4 wrapped lines at the
        // default window width, and a 2-line cap hid the examples (round 4). The
        // label wraps and grows to show the whole string.
        helpField.maximumNumberOfLines = 0
        // Don't let the (required) width chain up to the window honor this
        // label's single-line intrinsic width — that grows the resizable
        // window. Low resistance → it wraps to the available width instead.
        helpField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        textView.defaultParagraphStyle = hangingStyle
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
            .paragraphStyle: hangingStyle,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Disable smart-paste shenanigans on path content.
        textView.isAutomaticLinkDetectionEnabled = false

        // Canonical NSTextView-in-NSScrollView geometry (see
        // ScrollableTextView). Without it these path fields drew but
        // never became first responder on click — effectively
        // non-editable — in the shipped (CI, SDK 15.5) build while fine
        // in local Debug. Wrap mode: path content scrolls vertically.
        ScrollableTextView.configure(text: textView, scroll: scrollView,
                                     mode: .wrap,
                                     initialSize: NSSize(width: 400, height: 80))
        scrollView.borderType = .lineBorder
        scrollView.autohidesScrollers = true

        labelField.translatesAutoresizingMaskIntoConstraints = false
        helpField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)
        addSubview(helpField)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            labelField.topAnchor.constraint(equalTo: topAnchor),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor),
            helpField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 2),
            helpField.leadingAnchor.constraint(equalTo: leadingAnchor),
            helpField.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: helpField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }
}
