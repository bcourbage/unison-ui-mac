import AppKit

/// Lists `.prf` profiles in the Unison preferences directory and lets the
/// user pick one. Pure picker — no init/scan logic. Once the user picks
/// a profile, `onComplete(profile)` fires and the AppDelegate is
/// responsible for closing the picker, opening the reconcile window, and
/// driving init1/init2.
@MainActor
final class ProfileWindowController: NSWindowController {

    typealias Completion = @MainActor (_ profile: String) -> Void

    private let unisonDirectory: String
    private let onComplete: Completion
    private var profiles: [String] = []

    private let tableView = NSTableView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")

    init(unisonDirectory: String, onComplete: @escaping Completion) {
        self.unisonDirectory = unisonDirectory
        self.onComplete = onComplete
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Profiles"
        window.center()
        super.init(window: window)
        // setFrameAutosaveName must be set after the window is owned by a
        // controller; NSWindowController will then persist+restore frame
        // under this key in NSUserDefaults.
        windowFrameAutosaveName = "ProfileWindow"
        configure()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func configure() {
        guard let contentView = window?.contentView else { return }

        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.stringValue = unisonDirectory

        let column = NSTableColumn(identifier: .init("profile"))
        column.title = "Profile"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.style = .inset
        tableView.rowSizeStyle = .default

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openSelected)
        openButton.keyEquivalent = "\r"

        let bottomRow = NSStackView(views: [NSView(), openButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill
        bottomRow.spacing = 8

        let stack = NSStackView(views: [pathLabel, scroll, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    private func reload() {
        let url = URL(fileURLWithPath: unisonDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        profiles = contents
            .filter { ($0 as NSString).pathExtension == "prf" }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
        tableView.reloadData()
        if let defaultIdx = profiles.firstIndex(of: "default") ?? (profiles.isEmpty ? nil : 0) {
            tableView.selectRowIndexes(IndexSet(integer: defaultIdx), byExtendingSelection: false)
        }
        TraceLog.shared.write("ProfileWindow: \(profiles.count) profiles in \(unisonDirectory)")
    }

    /// Programmatic entry — selects the named profile in the table and
    /// triggers Open as if the user had double-clicked. Used by the
    /// env-var autotest hook in AppDelegate.
    func autoSelectAndOpen(profile: String) {
        guard let idx = profiles.firstIndex(of: profile) else {
            TraceLog.shared.write("AUTOTEST: profile '\(profile)' not found")
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        openSelected()
    }

    @objc private func openSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < profiles.count else { NSSound.beep(); return }
        let profile = profiles[row]
        TraceLog.shared.write("ProfileWindow: selected '\(profile)' — handing off to AppDelegate")
        onComplete(profile)
    }
}

extension ProfileWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
}

extension ProfileWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ProfileCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf)
            v.textField = tf
            v.identifier = identifier
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()
        cell.textField?.stringValue = profiles[row]
        return cell
    }
}
