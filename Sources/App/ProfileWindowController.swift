import AppKit

/// Lists `.prf` profiles in the Unison preferences directory and lets the
/// user pick one. Mirrors the legacy `ProfileController.m` — same data
/// (directory listing of *.prf), simpler implementation (no nib, modern
/// view-based NSTableView, programmatic Auto Layout).
@MainActor
final class ProfileWindowController: NSWindowController {

    typealias Completion = @MainActor (_ profile: String, _ items: [StateItem]) -> Void

    private let unisonDirectory: String
    private let onComplete: Completion
    private var profiles: [String] = []

    private let tableView = NSTableView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")
    private let progressSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

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

        progressSpinner.style = .spinning
        progressSpinner.controlSize = .small
        progressSpinner.isDisplayedWhenStopped = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        statusLabel.usesSingleLineMode = true
        statusLabel.cell?.wraps = false
        statusLabel.cell?.isScrollable = false
        // Cap width so a long file path can't push other UI off-screen.
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottomRow = NSStackView(views: [progressSpinner, statusLabel, NSView(), openButton])
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

    private var passwordSheet: PasswordSheet?

    private func beginBusy(_ status: String) {
        statusLabel.stringValue = status
        progressSpinner.startAnimation(nil)
    }

    private func endBusy() {
        progressSpinner.stopAnimation(nil)
        statusLabel.stringValue = ""
    }

    /// Called after a fatal-error sheet (or a warning where the user chose
    /// "Cancel sync") — the in-flight init1/init2 will not fire its
    /// completion callback, so we reset the picker UI ourselves.
    func abortInFlight() {
        endBusy()
        openButton.isEnabled = true
        tableView.isEnabled = true
        if let sheet = passwordSheet?.window, let parent = window {
            parent.endSheet(sheet)
        }
        passwordSheet = nil
    }

    /// Drives Remote.openConnection's state machine. Calls connectionPrompt,
    /// shows a sheet for each non-nil prompt, sends the user's response, and
    /// either loops (further prompt) or calls connectionEnd then init2.
    private func drivePromptLoop() {
        guard let cstr = unison_bridge_connection_prompt() else {
            // No more prompts — finalize and proceed.
            TraceLog.shared.write("connection: no more prompts — calling connection_end + init2")
            unison_bridge_connection_end()
            unison_bridge_init2()
            return
        }
        let prompt = String(cString: cstr)
        TraceLog.shared.write("connection prompt: \(prompt)")
        let sheet = PasswordSheet(prompt: prompt) { [weak self] response in
            guard let self else { return }
            self.passwordSheet = nil
            guard let response else {
                TraceLog.shared.write("connection: user cancelled")
                unison_bridge_connection_cancel()
                self.endBusy()
                self.openButton.isEnabled = true
                self.tableView.isEnabled = true
                return
            }
            unison_bridge_connection_reply(response)
            // Loop — the next prompt may be another field, or nil for done.
            self.drivePromptLoop()
        }
        passwordSheet = sheet
        if let parent = self.window {
            sheet.runAsSheet(over: parent)
        }
    }

    /// Programmatic entry — selects the named profile in the table and
    /// triggers the init flow as if the user had double-clicked. Used by
    /// the env-var autotest hook in AppDelegate.
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
        TraceLog.shared.write("ProfileWindow: selected '\(profile)' — calling init1")

        openButton.isEnabled = false
        tableView.isEnabled = false
        beginBusy("Opening \(profile)…")

        // Mirror OCaml status messages into our status label so the user sees
        // "Looking for changes ..." style updates. Take only the first line —
        // Unison sometimes sends multi-line warning blocks that would push
        // the status bar to multi-line height and clobber the layout. Real
        // warning/error UI is on the TODO list.
        UnisonBridge.installStatusHandler { [weak self] msg in
            let firstLine = msg.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? msg
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                self?.statusLabel.stringValue = trimmed
            }
        }

        UnisonBridge.installInit1CompleteHandler { [weak self] needsPrompt in
            TraceLog.shared.write("init1 complete (needs_prompt=\(needsPrompt))")
            guard let self else { return }
            if needsPrompt {
                self.drivePromptLoop()
            } else {
                TraceLog.shared.write("init1 ok — calling init2")
                unison_bridge_init2()
            }
        }

        UnisonBridge.installInit2CompleteHandler { [weak self] items in
            TraceLog.shared.write("init2 complete — \(items.count) reconcile items")
            guard let self else { return }
            self.endBusy()
            self.openButton.isEnabled = true
            self.tableView.isEnabled = true
            self.onComplete(profile, items)
        }

        profile.withCString { unison_bridge_init1($0) }
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
