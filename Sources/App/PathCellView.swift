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

    func configureAsFolder(name: String, aggregate: FolderAggregate) {
        nameField.stringValue = name
        let (tint, tooltip) = Self.folderAppearance(for: aggregate)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        toolTip = tooltip
    }

    /// Folder-tint palette. Direction-based tints use the same hexes as
    /// the Action-column badges so the visual language is consistent
    /// across the row.
    private static func folderAppearance(for aggregate: FolderAggregate) -> (NSColor, String) {
        switch aggregate {
        case .uniform("---->"):
            return (NSColor(red: 0x97/255.0, green: 0xBB/255.0, blue: 0x68/255.0, alpha: 1.0),
                    "All items → Remote")
        case .uniform("<----"):
            return (NSColor(red: 0x5A/255.0, green: 0x96/255.0, blue: 0xDE/255.0, alpha: 1.0),
                    "All items ← Local")
        case .uniform("<-?->"):
            return (NSColor.systemOrange.withAlphaComponent(0.85),
                    "All items in conflict")
        case .uniform("<-M->"):
            return (NSColor.systemPurple.withAlphaComponent(0.75),
                    "All items will be merged")
        case .uniform(let other):
            return (.secondaryLabelColor, "Uniform: \(other)")
        case .allUserSkipped:
            return (NSColor.systemGray.withAlphaComponent(0.7),
                    "All items skipped")
        case .mixed:
            // Default Finder-folder feel — system blue but a touch muted.
            return (NSColor.systemBlue.withAlphaComponent(0.85),
                    "Mixed actions in this folder")
        }
    }
}
