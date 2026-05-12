import AppKit

/// Layer 1: read-only listing of reconciliation results.
/// Future layers will add direction overrides + a Go button.
///
/// Performance note: rows live entirely in the Swift array `items`; no
/// per-row bridge calls during scrolling. NSTableView's view recycling
/// handles the table-of-thousands case naturally — we only build cell
/// views for visible rows, and each cell pulls from a single struct read.
@MainActor
final class ReconcileWindowController: NSWindowController, NSWindowDelegate {

    typealias CloseHandler = @MainActor () -> Void
    typealias RescanRequest = @MainActor () -> Void

    private var items: [StateItem]
    private let profile: String
    private let onClose: CloseHandler
    private let onRescanRequested: RescanRequest
    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let detailsTextView = NSTextView()
    private let detailsScroll = NSScrollView()
    private let toolbarDelegate = ReconcileToolbarDelegate()
    private(set) var isSyncing = false

    enum Col: String {
        case path, left, direction, right, size, progress, type
        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(rawValue)
        }
    }

    /// Initialize with no items. The owner (AppDelegate) is expected to
    /// drive init1+init2 against this window, calling `beginInitialScan()`
    /// before invoking the bridge and `replaceItems(_:)` when results
    /// arrive. The empty state is shown until then.
    init(profile: String,
         onClose: @escaping CloseHandler,
         onRescanRequested: @escaping RescanRequest) {
        self.profile = profile
        self.items = []
        self.onClose = onClose
        self.onRescanRequested = onRescanRequested
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Unison — \(profile)"
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "ReconcileWindow"
        window.delegate = self
        configure(profile: profile)
        installToolbar()
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            onClose()
        }
    }

    /// Replace the displayed items (e.g. after a rescan completes). Must
    /// be called on the main thread.
    func replaceItems(_ newItems: [StateItem]) {
        items = newItems
        tableView.reloadData()
        summaryLabel.stringValue = summaryText(profile: profile)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func configure(profile: String) {
        guard let contentView = window?.contentView else { return }

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.stringValue = summaryText(profile: profile)

        addColumn(.path, title: "Path", width: 380, min: 200, isPrimary: true)
        addColumn(.left, title: "Local", width: 80, min: 60)
        addColumn(.direction, title: "Action", width: 70, min: 60)
        addColumn(.right, title: "Remote", width: 80, min: 60)
        addColumn(.size, title: "Size", width: 80, min: 60)
        addColumn(.progress, title: "Progress", width: 80, min: 60)
        addColumn(.type, title: "Type", width: 60, min: 50)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 20
        tableView.autosaveName = "ReconcileTable"
        tableView.autosaveTableColumns = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .lineBorder

        configureDetailsPanel()

        let stack = NSStackView(views: [summaryLabel, progressBar, scroll, detailsScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            detailsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            detailsScroll.heightAnchor.constraint(equalToConstant: 90),
        ])

        UnisonBridge.installReloadRowHandler { [weak self] row, progress, bytes in
            self?.reloadRow(row, progress: progress, bytesTransferred: bytes)
        }
        UnisonBridge.installSyncCompleteHandler { [weak self] in
            self?.syncDidComplete()
        }
        UnisonBridge.installProgressHandler { [weak self] percent in
            self?.updateGlobalProgress(percent)
        }
    }

    private func addColumn(_ col: Col, title: String, width: CGFloat, min: CGFloat, isPrimary: Bool = false) {
        let c = NSTableColumn(identifier: col.identifier)
        c.title = title
        c.width = width
        c.minWidth = min
        c.resizingMask = isPrimary ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        tableView.addTableColumn(c)
    }

    // MARK: - Toolbar

    private func installToolbar() {
        guard let window else { return }
        toolbarDelegate.controller = self
        // Identifier suffix bump after each schema change forces the
        // autosaved layout to reset — otherwise users keep the old buttons
        // and miss new ones. Bump when item identifiers or grouping change.
        let toolbar = NSToolbar(identifier: "ReconcileToolbar.v2")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: - Sync

    func startSync() {
        guard !isSyncing else { return }
        isSyncing = true
        progressBar.doubleValue = 0
        progressBar.isHidden = false
        summaryLabel.stringValue = "Synchronizing \(profile)…"
        TraceLog.shared.write("ReconcileWindow: starting sync")
        unison_bridge_synchronize()
    }

    /// Toolbar "Profiles" action — return to the picker. Just performs
    /// the window close; the windowWillClose -> onClose handler routes
    /// back to AppDelegate.showProfilePicker.
    func returnToPicker() {
        window?.performClose(nil)
    }

    /// Toolbar Stop action — matches the legacy app's "Cancel" semantics:
    /// returns to the profile picker. The OCaml worker continues running
    /// in the background until it finishes naturally. True mid-sync abort
    /// would require exposing OCaml's `Abort.all` via Callback.register,
    /// which the upstream uimacbridge doesn't do (see TODO: real cancel).
    func cancelSync() {
        guard isSyncing else { NSSound.beep(); return }
        TraceLog.shared.write("ReconcileWindow: user requested Stop — closing window (OCaml sync continues)")
        window?.performClose(nil)
    }

    // MARK: - Scanning (initial or rescan)

    /// Triggered by the toolbar's Rescan item. Delegates to AppDelegate
    /// (via `onRescanRequested`) since the init2 handler registration is
    /// process-global — only one owner should manage it at a time.
    func rescan() {
        guard !isSyncing else { NSSound.beep(); return }
        onRescanRequested()
    }

    /// Show the indeterminate progress + status. Used for both the first
    /// scan after opening the window and re-scans triggered from toolbar.
    func beginScanning(_ message: String) {
        progressBar.isHidden = false
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        summaryLabel.stringValue = message
    }

    func beginInitialScan() {
        beginScanning("Opening \(profile)…")
    }

    func beginRescan() {
        beginScanning("Rescanning \(profile)…")
    }

    func endRescan(newItems: [StateItem]) {
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.isHidden = true
        replaceItems(newItems)
    }

    // MARK: - Details panel

    private func configureDetailsPanel() {
        detailsTextView.isEditable = false
        detailsTextView.isSelectable = true
        detailsTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailsTextView.textContainerInset = NSSize(width: 6, height: 6)
        detailsTextView.drawsBackground = true
        detailsTextView.backgroundColor = .textBackgroundColor
        detailsTextView.string = "Select a row to see details."
        detailsTextView.textColor = .secondaryLabelColor

        detailsScroll.documentView = detailsTextView
        detailsScroll.hasVerticalScroller = true
        detailsScroll.borderType = .lineBorder
        detailsScroll.autohidesScrollers = true
    }

    private func updateDetailsForSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else {
            detailsTextView.string = "Select a row to see details."
            detailsTextView.textColor = .secondaryLabelColor
            return
        }
        // Lazy fetch — only when the user actually selects a row.
        if let cstr = unison_bridge_ri_get_details(Int32(row)) {
            detailsTextView.string = String(cString: cstr)
        } else {
            detailsTextView.string = items[row].path  // fallback
        }
        detailsTextView.textColor = .labelColor
    }

    /// Update the status line during a scan (e.g. "Looking for changes…").
    /// First line only — same filter the picker used.
    func updateScanStatus(_ msg: String) {
        let firstLine = msg.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? msg
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            summaryLabel.stringValue = trimmed
        }
    }

    private func updateGlobalProgress(_ percent: Double) {
        guard isSyncing else { return }
        progressBar.doubleValue = max(0, min(100, percent))
    }

    private func reloadRow(_ row: Int, progress: String, bytesTransferred: Int64) {
        guard row >= 0, row < items.count else { return }
        let path = items[row].path
        items[row] = items[row].with(progress: progress, bytesTransferred: bytesTransferred)
        let allCols = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: allCols)
        TraceLog.shared.write("reloadRow[\(row)] \(path): progress='\(progress)' bytes=\(bytesTransferred)")
    }

    private func syncDidComplete() {
        isSyncing = false
        progressBar.doubleValue = 100
        progressBar.isHidden = true
        summaryLabel.stringValue = summaryText(profile: profile, syncDone: true)
        TraceLog.shared.write("ReconcileWindow: sync complete")
    }

    // MARK: - Direction overrides

    /// Applied to all currently-selected rows. The bridge call is synchronous
    /// (round-trip through the OCaml worker), so we update the row's direction
    /// from the value OCaml returns rather than guessing — keeps Swift and
    /// OCaml state in lockstep even if Unison's rules differ from our model.
    func applyDirection(_ action: DirectionAction) {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { NSSound.beep(); return }
        var changedRows = IndexSet()
        for row in rows {
            guard row < items.count else { continue }
            let raw = action.invoke(row: Int32(row))
            guard let raw, let str = String(validatingUTF8: raw) else {
                TraceLog.shared.write("ri-set failed for row \(row) (\(action))")
                continue
            }
            items[row] = items[row].with(direction: str)
            changedRows.insert(row)
        }
        if !changedRows.isEmpty {
            // reloadData only refreshes cell views — the NSTableRowView's
            // background tint must be updated explicitly.
            let allCols = IndexSet(integersIn: 0..<tableView.numberOfColumns)
            tableView.reloadData(forRowIndexes: changedRows, columnIndexes: allCols)
            for row in changedRows {
                guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? TintedRowView else { continue }
                rowView.tint = items[row].rowTint
            }
            summaryLabel.stringValue = summaryText(profile: profile)
        }
    }

    private func summaryText(profile: String, syncDone: Bool = false) -> String {
        let total = items.count
        let conflicts = items.filter { $0.direction == "<-?->" }.count
        let toLeft   = items.filter { $0.direction == "<----" }.count
        let toRight  = items.filter { $0.direction == "---->" }.count
        let other    = total - conflicts - toLeft - toRight
        var parts = ["\(total) items"]
        if conflicts > 0 { parts.append("\(conflicts) conflicts") }
        if toLeft > 0    { parts.append("\(toLeft) ← local") }
        if toRight > 0   { parts.append("\(toRight) → remote") }
        if other > 0     { parts.append("\(other) other") }
        let prefix = syncDone ? "Synchronized" : profile
        return "\(prefix)  ·  " + parts.joined(separator: "  ·  ")
    }
}

extension ReconcileWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

/// Tinted row view that draws a translucent background color based on the
/// reconcile direction (green for "to remote", blue for "to local",
/// orange for conflict, purple for merge, clear otherwise). The system
/// alternating-row + selection highlight still apply on top.
final class TintedRowView: NSTableRowView {
    var tint: NSColor = .clear {
        didSet {
            guard tint != oldValue else { return }
            needsDisplay = true
        }
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if tint != .clear {
            tint.setFill()
            dirtyRect.fill(using: .sourceOver)
        }
    }
}

private extension StateItem {
    /// Soft, system-color-derived tint per OCaml direction string. Uses
    /// low alpha so the path text + selection highlight stay readable in
    /// both light and dark mode.
    var rowTint: NSColor {
        switch direction {
        case "---->": return NSColor.systemGreen.withAlphaComponent(0.10)  // local → remote
        case "<----": return NSColor.systemBlue.withAlphaComponent(0.10)   // remote → local
        case "<-?->": return NSColor.systemOrange.withAlphaComponent(0.15) // conflict
        case "<-M->": return NSColor.systemPurple.withAlphaComponent(0.12) // merge
        default:      return .clear
        }
    }
}

extension ReconcileWindowController: NSTableViewDelegate {
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetailsForSelection()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard row < items.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("TintedRow")
        let view = tableView.makeView(withIdentifier: id, owner: self) as? TintedRowView ?? {
            let v = TintedRowView()
            v.identifier = id
            return v
        }()
        view.tint = items[row].rowTint
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn,
              let col = Col(rawValue: column.identifier.rawValue),
              row < items.count else { return nil }
        let item = items[row]
        let value: String
        switch col {
        case .path:      value = item.path
        case .left:      value = item.left
        case .right:     value = item.right
        case .direction: value = directionGlyph(item.direction)
        case .size:      value = formatSize(item.sizeBytes, type: item.fileType)
        case .progress:  value = item.progress.trimmingCharacters(in: .whitespaces)
        case .type:      value = item.fileType
        }
        return makeCell(in: tableView, identifier: column.identifier, text: value, column: col)
    }

    private func makeCell(in tableView: NSTableView,
                          identifier: NSUserInterfaceItemIdentifier,
                          text: String,
                          column: Col) -> NSView {
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            v.addSubview(tf)
            v.textField = tf
            v.identifier = identifier
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()
        view.textField?.stringValue = text
        view.textField?.alignment = (column == .size) ? .right :
                                    (column == .progress) ? .right :
                                    (column == .direction) ? .center : .left
        return view
    }

    private func directionGlyph(_ raw: String) -> String {
        switch raw {
        case "---->": return "→"
        case "<----": return "←"
        case "<-?->": return "⚠︎"
        case "<-M->": return "M"
        default:      return raw
        }
    }

    private func formatSize(_ bytes: Int64, type: String) -> String {
        // Directories carry 0 in OCaml's reporting; skip showing 0 B for them.
        if bytes == 0 && type.uppercased() == "DIR" { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
