import AppKit

/// Structured editor for `include` directives. One row per included file: an
/// editable combo box (the existing .prf files, or a typed name) plus a
/// Top/Bottom position. There are only ever a few, so it's a plain row list
/// with an Add button rather than a text box.
@MainActor
final class IncludeListView: NSView {

    private let rowsStack = NSStackView()
    private let addButton = KeyNavButton(title: "Add Include", target: nil, action: nil)
    private let existingNames: [String]
    var onChange: (() -> Void)?

    /// Each include as (file name, isTop, comment). Blank-name rows are
    /// dropped; comment is the optional line shown above the include.
    var entries: [(name: String, top: Bool, comment: String)] {
        get {
            rowsStack.arrangedSubviews.compactMap { row in
                guard let combo = row.viewWithTag(1) as? NSComboBox,
                      let popup = row.viewWithTag(2) as? NSPopUpButton else { return nil }
                let name = combo.stringValue.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                let comment = (row.viewWithTag(3) as? NSTextField)?
                    .stringValue.trimmingCharacters(in: .whitespaces) ?? ""
                return (name, popup.indexOfSelectedItem == 0, comment)
            }
        }
        set {
            rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for e in newValue { appendRow(makeRow(name: e.name, top: e.top, comment: e.comment)) }
        }
    }

    init(label: String, help: String, existingNames: [String]) {
        self.existingNames = existingNames
        super.init(frame: .zero)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let helpField = NSTextField(wrappingLabelWithString: help)
        helpField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpField.textColor = .secondaryLabelColor
        helpField.attributedStringValue = HelpText.attributed(
            help, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        helpField.maximumNumberOfLines = 0
        helpField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        let addRow = NSStackView(views: [addButton, NSView()])
        addRow.orientation = .horizontal

        let outer = NSStackView(views: [labelField, helpField, rowsStack, addRow])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in [helpField, rowsStack, addRow] as [NSView] {
            v.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func appendRow(_ row: NSView) {
        rowsStack.addArrangedSubview(row)
        // Safe to pin width now: the row shares rowsStack as ancestor.
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func makeRow(name: String, top: Bool, comment: String) -> NSView {
        let commentField = NSTextField(string: comment)
        commentField.tag = 3
        commentField.placeholderString = "Comment (optional)"
        commentField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        commentField.delegate = self
        commentField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let combo = NSComboBox()
        combo.tag = 1
        combo.isEditable = true
        combo.completes = true
        combo.addItems(withObjectValues: existingNames)
        combo.stringValue = name
        combo.target = self
        combo.action = #selector(rowChanged)
        combo.delegate = self
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        combo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let popup = KeyNavPopUpButton()
        popup.tag = 2
        popup.addItems(withTitles: ["Top", "Bottom"])
        popup.selectItem(at: top ? 0 : 1)
        popup.target = self
        popup.action = #selector(rowChanged)
        popup.setContentHuggingPriority(.required, for: .horizontal)

        let removeCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let remove = KeyNavButton(
            image: NSImage(systemSymbolName: "minus.circle",
                           accessibilityDescription: "Remove")?
                .withSymbolConfiguration(removeCfg) ?? NSImage(),
            target: self, action: #selector(removeTapped(_:)))
        remove.isBordered = false
        remove.bezelStyle = .regularSquare
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove this include"
        remove.setContentHuggingPriority(.required, for: .horizontal)
        remove.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let controls = NSStackView(views: [combo, popup, remove])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.distribution = .fill
        combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        // The comment sits on its own line above the file + position row,
        // prefixed with a "#" so it reads as a comment even when filled in.
        let hash = NSTextField(labelWithString: "#")
        hash.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        hash.textColor = .secondaryLabelColor
        hash.setContentHuggingPriority(.required, for: .horizontal)
        let commentRow = NSStackView(views: [hash, commentField])
        commentRow.orientation = .horizontal
        commentRow.spacing = 4
        commentRow.distribution = .fill

        let row = NSStackView(views: [commentRow, controls])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        commentRow.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    @objc private func addTapped() {
        appendRow(makeRow(name: "", top: true, comment: ""))
        onChange?()
    }

    @objc private func removeTapped(_ sender: NSButton) {
        // Walk up to the row that's a direct arranged subview of rowsStack.
        var v: NSView? = sender
        while let cur = v, cur.superview !== rowsStack { v = cur.superview }
        v?.removeFromSuperview()
        onChange?()
    }

    @objc private func rowChanged(_ sender: Any?) { onChange?() }
}

extension IncludeListView: NSComboBoxDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Spaces in include names are fine now — they're backslash-escaped on
        // write (see ProfileDocument.escapeWord), so no inline validation.
        onChange?()
    }
}
