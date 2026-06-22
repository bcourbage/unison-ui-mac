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

/// Progress-column cell. Renders Unison's `progress` field as a
/// standard macOS `NSProgressIndicator` (bar style, small control
/// size) with an overlaid percent label.
///
/// Earlier implementation drew the bar directly via `draw(_:)` on a
/// layer-backed `NSTableCellView`. That had two problems user-visible:
/// (1) the bar didn't advance during a sync — only the % text updated
/// — because AppKit's layer-cache for `draw(_:)` overrides on a
/// recycled table cell wasn't reliably invalidated by `needsDisplay`;
/// (2) the muted `systemBlue @ 0.35 alpha` fill looked off-brand vs.
/// the user's actual accent color. `NSProgressIndicator` solves both:
/// it follows `NSColor.controlAccentColor` (so it picks up the
/// user's System Settings → Appearance accent), and it redraws
/// correctly under every Auto Layout / cell-reuse path because its
/// own internals manage invalidation.
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
    private let bar = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // .regular size (vs. .small earlier) gives a meaningfully
        // visible bar at the slightly larger row height set in
        // ReconcileWindowController (24pt). At .small the bar was
        // only a few pixels tall — easy to misread, and any text
        // sitting on top of it was unavoidably overlapping the
        // accent-colored fill.
        bar.style = .bar
        bar.controlSize = .regular
        bar.isIndeterminate = false
        bar.usesThreadedAnimation = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        addSubview(bar)

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

        // Bar fills the row almost edge-to-edge; the text label
        // occupies the same rect but only one of them is visible at
        // a time (see `configure(progress:)`). Stacking via
        // centerYAnchor keeps both centered vertically.
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            textOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Show an aggregate fraction (a collapsed-folder summary) as a
    /// bar-only cell — no text overlay, like a numeric leaf row. Used for
    /// folder rows during sync; leaves go through `configure(progress:)`.
    func configure(fraction: Double) {
        let clamped = max(0, min(1, fraction))
        descriptor = ProgressDescriptor(fraction: clamped, text: "", isFailure: false)
        bar.isHidden = false
        bar.doubleValue = clamped
        textOverlay.stringValue = ""
        toolTip = nil
    }

    func configure(progress: String) {
        descriptor = ProgressDescriptor.parse(progress)
        if let f = descriptor.fraction, !descriptor.isFailure {
            // Numeric percent rows AND "done": bar only, no text overlay,
            // no tooltip. The bar's fill fraction is the indicator —
            // matches Finder / App Store / macOS installer idiom for
            // in-flight file transfers.
            bar.isHidden = false
            bar.doubleValue = f
            textOverlay.stringValue = ""
            toolTip = nil
        } else if descriptor.isFailure {
            // Failure rows: just the ⚠ glyph, full failure message on
            // hover. The Progress column is typically narrow, so the
            // previous "⚠ FAILED: Transfer aborted…" almost always
            // got truncated mid-reason and was uselessly cropped.
            // Icon-plus-tooltip is the macOS-standard "more info on
            // hover" idiom (Finder uses it for truncated filenames).
            // The full text is also available in the details panel
            // below when the row is selected.
            bar.isHidden = true
            bar.doubleValue = 0
            textOverlay.stringValue = "⚠"
            textOverlay.textColor = .systemRed
            textOverlay.font = .systemFont(
                ofSize: NSFont.systemFontSize, weight: .bold)
            toolTip = descriptor.text
        } else {
            // Other textual states ("start", any non-numeric label):
            // show the text. These are short ("start") and rarely
            // exceed the column width, so no tooltip needed.
            bar.isHidden = true
            bar.doubleValue = 0
            textOverlay.stringValue = descriptor.text
            textOverlay.textColor = .labelColor
            textOverlay.font = .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize - 1, weight: .regular)
            toolTip = nil
        }
    }
}
