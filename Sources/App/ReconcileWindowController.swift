import AppKit

/// Reconcile-window view: an `NSOutlineView` that mirrors Finder's
/// hierarchical view. Files are leaves; intermediate path segments are
/// folders. The tree is rebuilt on every `replaceItems(_:)` from the
/// flat `[StateItem]` we get from OCaml.
///
/// Performance note: rows live entirely in the Swift `items` array; no
/// per-row bridge calls during scrolling. NSOutlineView's view recycling
/// handles the table-of-thousands case naturally — we only build cell
/// views for visible rows, and each cell pulls from a single struct read.
@MainActor
final class ReconcileWindowController: NSWindowController, NSWindowDelegate {

    typealias CloseHandler = @MainActor () -> Void
    typealias RescanRequest = @MainActor () -> Void

    private var items: [StateItem]
    private var tree = ReconcileTree(items: [])
    /// Row indices the user explicitly chose Skip on. We track these
    /// separately because OCaml's `unisonRiToDirection` returns the same
    /// "<-?->" for both auto-detected conflicts (`Conflict "files
    /// differed"`) and user-requested skips (`Conflict "skip requested"`)
    /// — but the user experience is opposite: auto-conflict needs
    /// attention, user-skip is decided. Cleared on every rescan since
    /// OCaml rebuilds reconcile state from scratch.
    private var userSkipped: Set<Int> = []
    private let profile: String
    private let onClose: CloseHandler
    private let onRescanRequested: RescanRequest
    private let outlineView = NSOutlineView()
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

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            onClose()
        }
    }

    /// Replace the displayed items (e.g. after a rescan completes). Must
    /// be called on the main thread. Rebuilds the tree and expands every
    /// folder by default — matches Finder's "outline open" feel.
    func replaceItems(_ newItems: [StateItem]) {
        items = newItems
        tree = ReconcileTree(items: newItems)
        userSkipped.removeAll()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        summaryLabel.stringValue = summaryText(profile: profile)
    }

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

        // The "outline column" hosts the disclosure chevron + indent.
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: Col.path.identifier)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.style = .inset
        outlineView.usesAutomaticRowHeights = false
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 14
        outlineView.indentationMarkerFollowsCell = true
        outlineView.autosaveName = "ReconcileOutline"
        outlineView.autosaveTableColumns = true
        outlineView.autosaveExpandedItems = false  // we re-expand on each populate

        let scroll = NSScrollView()
        scroll.documentView = outlineView
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
        outlineView.addTableColumn(c)
    }

    // MARK: - Toolbar

    private func installToolbar() {
        guard let window else { return }
        toolbarDelegate.controller = self
        // Identifier suffix bump after each schema change forces the
        // autosaved layout to reset — otherwise users keep the old buttons
        // and miss new ones. Bump when item identifiers or grouping change.
        let toolbar = NSToolbar(identifier: "ReconcileToolbar.v3")
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

    /// Toolbar "Profiles" action — return to the picker.
    func returnToPicker() {
        window?.performClose(nil)
    }

    /// Toolbar Stop action — closes the window (returns to picker).
    /// OCaml worker continues until it finishes naturally; real mid-sync
    /// abort would need upstream-registered Abort.all (see TODO).
    func cancelSync() {
        guard isSyncing else { NSSound.beep(); return }
        TraceLog.shared.write("ReconcileWindow: user requested Stop — closing window (OCaml sync continues)")
        window?.performClose(nil)
    }

    // MARK: - Scanning (initial or rescan)

    func rescan() {
        guard !isSyncing else { NSSound.beep(); return }
        onRescanRequested()
    }

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
        guard let node = selectedNodes().first else {
            detailsTextView.string = "Select a row to see details."
            detailsTextView.textColor = .secondaryLabelColor
            return
        }
        if let row = node.row {
            // Leaf — fetch details from OCaml.
            if let cstr = unison_bridge_ri_get_details(Int32(row)) {
                detailsTextView.string = String(cString: cstr)
            } else {
                detailsTextView.string = items[row].path
            }
        } else {
            // Folder — show its path + how many descendants are affected.
            let leafCount = leafRows(under: node).count
            detailsTextView.string = "\(folderFullPath(node))/\n\(leafCount) item\(leafCount == 1 ? "" : "s") in this folder"
        }
        detailsTextView.textColor = .labelColor
    }

    /// Walk a folder node's ancestors to reconstruct the full path. Used
    /// by the details panel — leaves know their `fullPath` already.
    private func folderFullPath(_ node: ReconcileNode) -> String {
        var parts: [String] = []
        var cursor: ReconcileNode? = node
        while let n = cursor, !n.name.isEmpty {
            parts.insert(n.name, at: 0)
            cursor = n.parent
        }
        return parts.joined(separator: "/")
    }

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
        if let node = leafNode(forRow: row) {
            outlineView.reloadItem(node, reloadChildren: false)
        }
        TraceLog.shared.write("reloadRow[\(row)] \(path): progress='\(progress)' bytes=\(bytesTransferred)")
    }

    /// O(items) walk to find the leaf for a row. Fine for the per-row
    /// update path — fires at most ~once per file during sync. If we ever
    /// hit profiles where this is hot, cache row → node in a dictionary.
    private func leafNode(forRow row: Int) -> ReconcileNode? {
        for node in tree.allNodes where node.row == row {
            return node
        }
        return nil
    }

    private func syncDidComplete() {
        isSyncing = false
        progressBar.doubleValue = 100
        progressBar.isHidden = true
        summaryLabel.stringValue = summaryText(profile: profile, syncDone: true)
        TraceLog.shared.write("ReconcileWindow: sync complete")
    }

    // MARK: - Direction overrides

    /// Applied to every leaf row in the current selection — including
    /// leaves *underneath* selected folders. Single click on a folder thus
    /// becomes "apply this action to every file in that folder".
    func applyDirection(_ action: DirectionAction) {
        let rows = leafRowsInSelection()
        guard !rows.isEmpty else { NSSound.beep(); return }
        var changedRows: [Int] = []
        for row in rows {
            guard row < items.count else { continue }
            let raw = action.invoke(row: Int32(row))
            guard let raw, let str = String(validatingUTF8: raw) else {
                TraceLog.shared.write("ri-set failed for row \(row) (\(action))")
                continue
            }
            items[row] = items[row].with(direction: str)
            // Track which rows the user explicitly chose Skip on, so we
            // can visually distinguish them from auto-detected conflicts
            // (both come back as "<-?->" from OCaml).
            if action == .skip {
                userSkipped.insert(row)
            } else {
                userSkipped.remove(row)
            }
            changedRows.append(row)
        }
        for row in changedRows {
            guard let node = leafNode(forRow: row) else { continue }
            // reloadItem refreshes all cell views; makeDirectionCell will
            // re-consult DirectionVisual.{glyph,tint} which read the
            // updated direction string + userSkipped membership.
            outlineView.reloadItem(node, reloadChildren: false)
        }
        if !changedRows.isEmpty {
            summaryLabel.stringValue = summaryText(profile: profile)
        }
    }

    // MARK: - Selection helpers

    /// Currently-selected nodes (folders + leaves), in NSOutlineView's
    /// row order.
    private func selectedNodes() -> [ReconcileNode] {
        outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? ReconcileNode
        }
    }

    /// All leaf rows reachable from the current selection. A selected
    /// folder contributes every leaf underneath it; a selected leaf
    /// contributes itself; duplicates (folder + descendant both selected)
    /// are de-duplicated.
    private func leafRowsInSelection() -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for node in selectedNodes() {
            for row in leafRows(under: node) where !seen.contains(row) {
                seen.insert(row)
                result.append(row)
            }
        }
        return result
    }

    /// All leaf rows in the subtree rooted at `node` (inclusive when node
    /// is itself a leaf).
    private func leafRows(under node: ReconcileNode) -> [Int] {
        var out: [Int] = []
        func walk(_ n: ReconcileNode) {
            if let row = n.row { out.append(row); return }
            for c in n.children { walk(c) }
        }
        walk(node)
        return out
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

// MARK: - Direction-cell view (the only colored cell in the row)

/// Custom cell view used in the Action column. Fills its background with
/// a direction-specific tint and renders the arrow glyph at a larger size
/// + heavier weight so it reads at a glance, especially in dense lists.
final class DirectionCellView: NSTableCellView {
    private let glyphLabel = NSTextField(labelWithString: "")

    var tint: NSColor = .clear {
        didSet {
            guard tint != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        glyphLabel.alignment = .center
        glyphLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        glyphLabel.textColor = .labelColor
        addSubview(glyphLabel)
        textField = glyphLabel
        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            glyphLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if tint != .clear {
            // Inset slightly + round the corners — gives a "badge" feel
            // rather than a column-spanning fill.
            let badge = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3)
            tint.setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

/// Direction-column tints. Two of the values vary by *who* set the
/// direction: OCaml's `<-?->` covers both auto-detected conflicts AND
/// user-requested skips, but we want them to look different — the former
/// demands attention, the latter is settled. Hence the row parameter.
private enum DirectionVisual {
    static func tint(for direction: String, isUserSkipped: Bool) -> NSColor {
        if direction == "<-?->" && isUserSkipped {
            // Settled — neutral gray badge so the user can still see the
            // row was acted on, but it doesn't compete with real conflicts
            // for attention.
            return NSColor.systemGray.withAlphaComponent(0.45)
        }
        switch direction {
        case "---->": return NSColor(red: 0x97/255.0, green: 0xBB/255.0, blue: 0x68/255.0, alpha: 1.0)
        case "<----": return NSColor(red: 0x5A/255.0, green: 0x96/255.0, blue: 0xDE/255.0, alpha: 1.0)
        case "<-?->": return NSColor.systemOrange.withAlphaComponent(0.85)
        case "<-M->": return NSColor.systemPurple.withAlphaComponent(0.75)
        default:      return .clear
        }
    }

    static func glyph(for direction: String, isUserSkipped: Bool) -> String {
        if direction == "<-?->" && isUserSkipped {
            // Circled-minus matches the toolbar Skip button's minus.circle
            // SF Symbol, so the cell glyph and the button that produced
            // it visually agree.
            return "⊖"
        }
        switch direction {
        case "---->": return "→"
        case "<----": return "←"
        case "<-?->": return "⚠︎"   // auto-conflict — needs the user's input
        case "<-M->": return "M"
        default:      return direction
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension ReconcileWindowController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? ReconcileNode { return node.children.count }
        return tree.root.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? ReconcileNode { return node.children[index] }
        return tree.root.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ReconcileNode else { return false }
        return !node.isLeaf
    }
}

// MARK: - NSOutlineViewDelegate

extension ReconcileWindowController: NSOutlineViewDelegate {
    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateDetailsForSelection()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn,
              let col = Col(rawValue: column.identifier.rawValue),
              let node = item as? ReconcileNode else { return nil }

        // The Action column has its own colored cell type — needs the
        // StateItem for tinting, only meaningful for leaves.
        if col == .direction {
            return makeDirectionCell(in: outlineView, node: node)
        }

        // For folder rows, only the path column gets text; the rest are blank.
        let value: String
        if let row = node.row, row < items.count {
            let stateItem = items[row]
            switch col {
            case .path:      value = node.name              // last segment only — indent shows hierarchy
            case .left:      value = stateItem.left
            case .right:     value = stateItem.right
            case .direction: value = ""                     // handled above
            case .size:      value = formatSize(stateItem.sizeBytes, type: stateItem.fileType)
            case .progress:  value = stateItem.progress.trimmingCharacters(in: .whitespaces)
            case .type:      value = stateItem.fileType
            }
        } else {
            // Folder
            switch col {
            case .path: value = node.name
            default:    value = ""
            }
        }
        return makeCell(in: outlineView, identifier: column.identifier, text: value, column: col, isFolder: !node.isLeaf)
    }

    /// Builds (or recycles) the colored Action-column cell. Folders get an
    /// uncolored empty cell; leaves get tinted + bold arrow.
    private func makeDirectionCell(in outlineView: NSOutlineView, node: ReconcileNode) -> NSView {
        let id = NSUserInterfaceItemIdentifier("DirectionCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? DirectionCellView ?? {
            let v = DirectionCellView()
            v.identifier = id
            return v
        }()
        if let row = node.row, row < items.count {
            let item = items[row]
            let skipped = userSkipped.contains(row)
            cell.textField?.stringValue = DirectionVisual.glyph(for: item.direction, isUserSkipped: skipped)
            cell.tint = DirectionVisual.tint(for: item.direction, isUserSkipped: skipped)
        } else {
            cell.textField?.stringValue = ""
            cell.tint = .clear
        }
        return cell
    }

    private func makeCell(in outlineView: NSOutlineView,
                          identifier: NSUserInterfaceItemIdentifier,
                          text: String,
                          column: Col,
                          isFolder: Bool) -> NSView {
        let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
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
        // Folder names get a slight emphasis to read as containers.
        view.textField?.font = isFolder && column == .path
            ? .systemFont(ofSize: NSFont.systemFontSize - 1, weight: .semibold)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        view.textField?.textColor = isFolder ? .secondaryLabelColor : .labelColor
        return view
    }

    private func formatSize(_ bytes: Int64, type: String) -> String {
        if bytes == 0 && type.uppercased() == "DIR" { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
