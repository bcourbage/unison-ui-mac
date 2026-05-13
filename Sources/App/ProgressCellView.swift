import AppKit

/// Pure-data description of one row's transfer progress, parsed from
/// Unison's `progress` string. Broken out from the cell view so the
/// "what counts as a percentage / failure / idle" rule is unit-testable.
///
/// Unison emits progress text in one of these shapes (see
/// `unison_state_item_t.progress` in UnisonBridgeC.h):
///   - `""` — idle (no sync running, or done with no terminal label)
///   - `"start "` — kicking off; no measurable percent yet
///   - `" 35%"` / `"35%"` / `"100%"` — running
///   - `"done"` — terminal success
///   - `"FAILED"` (or any string containing `FAIL`) — terminal failure
///
/// The throttling in OCaml only emits intermediate ticks when the
/// percent changes by >1%, so small files collapse to one event at
/// 100%. Large files (or slow network links) produce a stream of
/// ticks that the cell can animate.
struct ProgressDescriptor: Equatable {
    /// Bar fill fraction in 0…1, or nil when no bar should be drawn
    /// (idle, "start" with no number, failure).
    let fraction: Double?
    /// Text to overlay on the cell. Empty for idle cells.
    let text: String
    /// True when the row failed — switches the text to bold red, no bar.
    let isFailure: Bool

    static let empty = ProgressDescriptor(fraction: nil, text: "", isFailure: false)

    static func parse(_ raw: String) -> ProgressDescriptor {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        // Failures land in the Progress column too (Unison concatenates
        // "FAILED: <message>"); match by substring so we catch them all.
        if trimmed.uppercased().contains("FAIL") {
            return ProgressDescriptor(fraction: nil, text: trimmed, isFailure: true)
        }
        if trimmed == "done" {
            return ProgressDescriptor(fraction: 1.0, text: "done", isFailure: false)
        }
        // Percent: "<num>%" with optional leading/trailing whitespace.
        if trimmed.hasSuffix("%") {
            let numText = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            if let pct = Double(numText) {
                let clamped = max(0, min(1, pct / 100))
                return ProgressDescriptor(fraction: clamped, text: trimmed, isFailure: false)
            }
        }
        // "start " or anything else — show the text label, no bar.
        return ProgressDescriptor(fraction: nil, text: trimmed, isFailure: false)
    }
}

/// Progress-column cell. Renders Unison's `progress` field as a small
/// bar with overlaid percent text. The bar is drawn directly into the
/// cell (rather than via NSProgressIndicator) so it fits cleanly in
/// the 20pt row height — NSProgressIndicator's smallest standard
/// preset is taller than that, and we don't need its animation hooks.
///
/// State table:
///   - idle ("")              → empty cell (no bar, no text)
///   - "start"                → text "start", no bar
///   - "35%"                  → bar fill 0.35, text "35%"
///   - "done"                 → bar fill 1.0, text "done"
///   - "FAILED" / "FAIL: …"   → bold red text, no bar
final class ProgressCellView: NSTableCellView {

    private var descriptor: ProgressDescriptor = .empty
    private let textOverlay = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        textOverlay.translatesAutoresizingMaskIntoConstraints = false
        textOverlay.alignment = .center
        textOverlay.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize - 1, weight: .regular)
        textOverlay.textColor = .labelColor
        textOverlay.drawsBackground = false
        textOverlay.lineBreakMode = .byTruncatingTail
        textOverlay.cell?.usesSingleLineMode = true
        addSubview(textOverlay)
        textField = textOverlay
        NSLayoutConstraint.activate([
            textOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(progress: String) {
        descriptor = ProgressDescriptor.parse(progress)
        textOverlay.stringValue = descriptor.text
        textOverlay.textColor = descriptor.isFailure ? .systemRed : .labelColor
        textOverlay.font = descriptor.isFailure
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .bold)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw the bar (if any) FIRST so the overlaid text sits on top.
        // We rely on the text-field's labelColor giving enough contrast
        // against the 0.35-alpha blue fill; tweak the fill alpha if
        // the text ever looks washed out.
        if let f = descriptor.fraction, !descriptor.isFailure {
            let track = bounds.insetBy(dx: 4, dy: 5)
            let radius: CGFloat = 3
            // Background track — neutral, so the bar reads as
            // "progress against a known total" rather than "color blob".
            NSColor.separatorColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            // Fill segment, sized to the fraction.
            var fillRect = track
            fillRect.size.width = max(0, fillRect.width * CGFloat(f))
            if fillRect.width > 0 {
                NSColor.systemBlue.withAlphaComponent(0.35).setFill()
                // Clip the fill into the rounded track so the leading
                // edge of the fill doesn't poke past the radius corners.
                let clipPath = NSBezierPath(roundedRect: track,
                                            xRadius: radius, yRadius: radius)
                NSGraphicsContext.current?.saveGraphicsState()
                clipPath.addClip()
                NSBezierPath(rect: fillRect).fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        }
        super.draw(dirtyRect)
    }
}
