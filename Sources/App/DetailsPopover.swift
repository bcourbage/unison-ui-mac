import AppKit

/// A readable place for text that does not fit a status line: a fixed-width
/// popover holding wrapping, selectable text that scrolls once it outgrows a
/// height cap, with optional buttons beneath. Used by the Profile Editor's
/// check report and the reconcile window's status details.
@MainActor
enum DetailsPopover {

    /// A report as attributed text: the first line in bold, each further line
    /// on its own, the closing line muted when there is more than one.
    static func attributed(_ lines: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 6
        for (i, line) in lines.enumerated() {
            let isFirst = i == 0, isLast = i == lines.count - 1 && lines.count > 1
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isFirst ? bold : body,
                .foregroundColor: isLast ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: para,
            ]
            out.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: attrs))
        }
        return out
    }

    static func make(text: NSAttributedString, width: CGFloat = 480, maxHeight: CGFloat = 360,
                     buttons: [NSButton] = []) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        let needed = text.boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 16
        let height = min(max(needed, 40), maxHeight)
        let (scroll, textView) = ScrollableTextView.make(mode: .wrap, initialSize: NSSize(width: width, height: height))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.textStorage?.setAttributedString(text)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        var views: [NSView] = [scroll]
        if !buttons.isEmpty {
            for b in buttons { b.bezelStyle = .rounded }
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal; row.spacing = 8
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let vc = NSViewController(); vc.view = stack
        popover.contentViewController = vc
        return popover
    }
}
