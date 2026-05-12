import AppKit

/// One-glyph status icon shown in the Local and Remote columns. Maps
/// Unison's per-side change keyword to a colored SF Symbol so the user
/// can scan a hundred-file changeset and see what's happening on each
/// side at a glance:
///
///     Created       → green   plus.circle.fill
///     Modified      → blue    circle           (hollow)
///     PropsChanged  → blue    circle.dashed    (hollow, partial change)
///     Deleted       → red     minus.circle.fill
///     ""            → gray    circle.fill      (small — "no change")
///
/// PropsChanged shares the modified blue but with a dashed outline,
/// matching the legacy app's distinction between content + metadata.
/// Empty string covers both "Unchanged" and "Problem" — both render as
/// a quiet gray dot so the column isn't blank.
final class StatusIconCellView: NSTableCellView {

    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(status: String) {
        let descriptor = StatusIconDescriptor.forStatus(status)
        let config = NSImage.SymbolConfiguration(pointSize: descriptor.pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [descriptor.color]))
        iconView.image = NSImage(systemSymbolName: descriptor.symbol,
                                 accessibilityDescription: descriptor.tooltip)?
            .withSymbolConfiguration(config)
        toolTip = descriptor.tooltip
    }
}

/// Pure mapping from status string → (symbol, color, tooltip).
/// Pulled out so the unit tests can pin the mapping without instantiating
/// AppKit views.
struct StatusIconDescriptor {
    let symbol: String
    let color: NSColor
    let tooltip: String
    let pointSize: CGFloat

    static func forStatus(_ status: String) -> StatusIconDescriptor {
        switch status {
        case "Created":
            return .init(symbol: "plus.circle.fill",
                         color: .systemGreen,
                         tooltip: "Created",
                         pointSize: 14)
        case "Modified":
            return .init(symbol: "circle",
                         color: .systemBlue,
                         tooltip: "Modified",
                         pointSize: 14)
        case "PropsChanged":
            return .init(symbol: "circle.dashed",
                         color: .systemBlue,
                         tooltip: "Properties changed",
                         pointSize: 14)
        case "Deleted":
            return .init(symbol: "minus.circle.fill",
                         color: .systemRed,
                         tooltip: "Deleted",
                         pointSize: 14)
        case "":
            // Empty covers both "Unchanged" and "Problem" — quiet gray dot
            // so the column isn't blank.
            return .init(symbol: "circle.fill",
                         color: NSColor.tertiaryLabelColor,
                         tooltip: "Unchanged",
                         pointSize: 8)
        default:
            return .init(symbol: "questionmark.circle",
                         color: .secondaryLabelColor,
                         tooltip: status,
                         pointSize: 14)
        }
    }
}
