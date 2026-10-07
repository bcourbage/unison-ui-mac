import AppKit

/// Help strings in the profile editor mark code-like examples with
/// backticks, as in `Name *.tmp`. Rendered as plain text the backticks show;
/// this turns each backticked span into monospaced text and drops the
/// markers, so examples read as code without stray characters.
enum HelpText {

    enum Segment: Equatable {
        case text(String)
        case code(String)
    }

    /// Split `help` at backticks. An unmatched trailing backtick is kept as
    /// text so nothing is lost.
    nonisolated static func segments(_ help: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(help)
        while let open = rest.firstIndex(of: "`") {
            let before = rest[..<open]
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: "`") else {
                // No closing marker: everything from here is text.
                break
            }
            if !before.isEmpty { out.append(.text(String(before))) }
            out.append(.code(String(afterOpen[..<close])))
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    /// `help` with its backticked spans in a monospaced font of the same
    /// size, the rest in `font` and `color`.
    @MainActor
    static func attributed(_ help: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        let out = NSMutableAttributedString()
        for segment in segments(help) {
            switch segment {
            case .text(let s):
                out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
            case .code(let s):
                out.append(NSAttributedString(string: s, attributes: [.font: mono, .foregroundColor: color]))
            }
        }
        return out
    }
}
