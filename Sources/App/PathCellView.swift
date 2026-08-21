import AppKit

/// Path-column cell that mirrors Finder's list view: a small icon
/// (folder for folders, generic doc for files) followed by the name in
/// system body font + labelColor. Folder icons are tinted by the folder's
/// aggregate state — uniform direction → that direction's color, mixed
/// or default → neutral folder-blue.
final class PathCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.cell?.usesSingleLineMode = true

        addSubview(iconView)
        addSubview(nameField)
        imageView = iconView
        textField = nameField

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configureAsFile(name: String, fullPath: String? = nil) {
        nameField.stringValue = name
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
        iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        applyTooltip(fullPath: fullPath, displayedName: name)
    }

    /// Folder icon is always the native Finder blue, regardless of any
    /// aggregate state. The aggregate is conveyed by the Action column,
    /// not by recoloring the folder itself — folders read as folders.
    func configureAsFolder(name: String, fullPath: String? = nil) {
        nameField.stringValue = name
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")?
            .withSymbolConfiguration(config)
        applyTooltip(fullPath: fullPath, displayedName: name)
    }

    /// Set a hover tooltip showing the full path when:
    ///  - the full path is provided AND
    ///  - it differs from the displayed name (otherwise the tooltip would
    ///    duplicate what the user is already looking at).
    /// The Path column truncates with `byTruncatingMiddle`, so the most
    /// common reason to want a tooltip is "the column is narrower than
    /// the name". A nil tooltip is cleared so a recycled cell doesn't
    /// retain a stale value from its previous binding.
    private func applyTooltip(fullPath: String?, displayedName: String) {
        if let fullPath, fullPath != displayedName {
            toolTip = fullPath
        } else {
            toolTip = nil
        }
    }
}
