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

    func configureAsFile(name: String) {
        nameField.stringValue = name
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
        iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        toolTip = nil
    }

    /// Folder icon is always the native Finder blue, regardless of any
    /// aggregate state. The aggregate is conveyed by the Action column,
    /// not by recoloring the folder itself — folders read as folders.
    func configureAsFolder(name: String) {
        nameField.stringValue = name
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")?
            .withSymbolConfiguration(config)
        toolTip = nil
    }
}
