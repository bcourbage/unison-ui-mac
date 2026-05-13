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
final class ReconcileWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

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

    /// Confirmation when the user tries to close the window mid-sync.
    /// OCaml's sync runs in `doInOtherThread` — we have no way to abort
    /// it (see TODO: real cancel), so "stop and close" really means
    /// "close the window and let the transfer continue in the background
    /// until it finishes". Spelling that out in the alert prevents the
    /// user from thinking they actually stopped the sync.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard isSyncing else { return true }
            let alert = NSAlert()
            alert.messageText = "Synchronization is still running"
            alert.informativeText = "Closing this window won't stop the transfer — OCaml will keep running in the background until the current files finish. Close anyway?"
            alert.addButton(withTitle: "Keep Syncing")
            alert.addButton(withTitle: "Close Window")
            alert.alertStyle = .warning
            return alert.runModal() == .alertSecondButtonReturn
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
        refreshDirectionToolbarEnabled()
    }

    private func configure(profile: String) {
        guard let contentView = window?.contentView else { return }

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.stringValue = summaryText(profile: profile)

        addColumn(.path, title: "Path", width: 380, min: 200, isPrimary: true)
        // Column titles use the upstream manual's terminology: the two
        // endpoints are called the "first" and "second" replica/root,
        // matching the order of the `root = …` lines in the .prf. Either
        // side may be local or remote — there's no client/server
        // distinction in Unison's data model.
        addColumn(.left, title: "First", width: 80, min: 60)
        addColumn(.direction, title: "Action", width: 70, min: 60)
        addColumn(.right, title: "Second", width: 80, min: 60)
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
        outlineView.menu = makeRowContextMenu()
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
        // v4 bump: DirectionAction subitem identifiers changed from
        // dir.toLocal / dir.toRemote → dir.toFirst / dir.toSecond as
        // part of the Local/Remote → First/Second terminology pass.
        // Without the bump, autosaved layouts would keep the old subitem
        // IDs and the segmented control would appear empty for users
        // whose preferences were saved on v3.
        let toolbar = NSToolbar(identifier: "ReconcileToolbar.v4")
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
        // Reload changed leaves AND every ancestor folder up to the root —
        // folder aggregates may have flipped from "mixed" to "uniform" or
        // vice versa. De-dup via identity so shared ancestors only redraw
        // once when several leaves under the same folder all change.
        var nodesToReload: [ObjectIdentifier: ReconcileNode] = [:]
        for row in changedRows {
            guard let leaf = leafNode(forRow: row) else { continue }
            nodesToReload[ObjectIdentifier(leaf)] = leaf
            var ancestor = leaf.parent
            while let n = ancestor, !n.name.isEmpty {
                nodesToReload[ObjectIdentifier(n)] = n
                ancestor = n.parent
            }
        }
        for node in nodesToReload.values {
            outlineView.reloadItem(node, reloadChildren: false)
        }
        if !changedRows.isEmpty {
            summaryLabel.stringValue = summaryText(profile: profile)
        }
    }

    // MARK: - Ignore actions

    /// Right-click context menu for the outline view. The same three Ignore
    /// items also live on the Edit menu — both go through `applyIgnore`.
    private func makeRowContextMenu() -> NSMenu {
        let menu = NSMenu()
        // Validation: NSMenu doesn't auto-revalidate context menus on
        // openPopupContextMenu, but it does call `validateUserInterfaceItem`
        // on each item's target when the menu opens (we set autoenablesItems
        // and rely on the validation method below).
        menu.autoenablesItems = true
        for action in IgnoreAction.all {
            let item = NSMenuItem(title: action.label,
                                  action: #selector(ignoreMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = action.menuTag
            menu.addItem(item)
        }
        return menu
    }

    /// Right-click handler / Edit-menu handler. Both target ignore items
    /// carry an IgnoreAction tag.
    @objc private func ignoreMenuAction(_ sender: NSMenuItem) {
        guard let action = IgnoreAction.from(tag: sender.tag) else { return }
        // Edit-menu invocations operate on the table's selection. Context-menu
        // invocations should operate on the right-clicked row if it isn't
        // part of the current selection — matching Finder's behavior.
        let row = rowForPendingMenuAction()
        applyIgnore(action, row: row)
    }

    /// Resolves which leaf row a menu action targets. Prefers the
    /// outline view's `clickedRow` (set on right-click), falling back to
    /// the first leaf in the current selection. Returns nil when neither
    /// resolves to a leaf — caller should beep.
    private func rowForPendingMenuAction() -> Int? {
        let clicked = outlineView.clickedRow
        if clicked >= 0,
           let node = outlineView.item(atRow: clicked) as? ReconcileNode,
           let row = node.row {
            return row
        }
        return leafRowsInSelection().first
    }

    /// Apply one of the three Ignore actions to a specific leaf row. The
    /// bridge call recomputes OCaml's `theState`; the init2-complete handler
    /// installed on AppDelegate fires re-entrantly and `replaceItems(_:)`
    /// repopulates the table with the post-filter list.
    func applyIgnore(_ action: IgnoreAction, row: Int?) {
        guard !isSyncing else { NSSound.beep(); return }
        guard let row, row >= 0, row < items.count else { NSSound.beep(); return }
        let path = items[row].path
        TraceLog.shared.write("ReconcileWindow: \(action.label) on row \(row) (\(path))")
        if !action.invoke(row: Int32(row)) {
            TraceLog.shared.write("  \(action.label) returned false — no state change")
            NSSound.beep()
        }
        // No explicit reload needed: the bridge invokes the init2-complete
        // handler synchronously, which calls `endRescan` / `replaceItems` and
        // resets userSkipped + redraws the outline.
    }

    /// NSMenuItemValidation entry point. AppKit walks the responder chain
    /// looking for whoever implements the menu item's action; for the
    /// `ignoreMenuAction(_:)` items that's this controller, so we get the
    /// validation call here for both context-menu and Edit-menu items.
    /// Disabled during sync (state mutation while sync is in flight is
    /// unsafe) and when no leaf row is the target.
    ///
    /// AppKit only calls this on the main thread (menu validation runs as
    /// the menu is about to open). The class is `@MainActor` so we let the
    /// Swift-6 isolation match the runtime guarantee.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(ignoreMenuAction(_:)) else { return true }
        guard !isSyncing else { return false }
        return rowForPendingMenuAction() != nil
    }

    // MARK: - Selection helpers

    /// Currently-selected nodes (folders + leaves), in NSOutlineView's
    /// row order.
    private func selectedNodes() -> [ReconcileNode] {
        outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? ReconcileNode
        }
    }

    /// Walks the toolbar's direction group and enables/disables each
    /// subitem based on whether the current selection contains any leaf
    /// rows. Folder-only selections with no descendant leaves (e.g., a
    /// totally empty folder, shouldn't happen but be safe) also disable.
    private func refreshDirectionToolbarEnabled() {
        guard let toolbar = window?.toolbar else { return }
        let hasLeaves = !leafRowsInSelection().isEmpty
        for item in toolbar.items {
            // Direction group: enable/disable each subitem so the
            // segmented control gives per-button feedback.
            if let group = item as? NSToolbarItemGroup,
               group.itemIdentifier == DirectionAction.directionGroupIdentifier {
                for sub in group.subitems {
                    sub.isEnabled = hasLeaves
                }
            }
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
        if toLeft > 0    { parts.append("\(toLeft) ← first") }
        if toRight > 0   { parts.append("\(toRight) → second") }
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
/// Internal (not `private`) so the unit tests can pin the glyph/tint
/// mapping without going through view introspection.
enum DirectionVisual {
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

    /// Aggregate variants for folder rows. Uniform direction → the same
    /// glyph + tint as a leaf with that direction. All-user-skipped → the
    /// settled gray-⊖ pair. Mixed → no badge (empty cell, clear tint).
    static func tint(for aggregate: FolderAggregate) -> NSColor {
        switch aggregate {
        case .uniform(let dir):  return tint(for: dir, isUserSkipped: false)
        case .allUserSkipped:    return NSColor.systemGray.withAlphaComponent(0.45)
        case .mixed:             return .clear
        }
    }

    static func glyph(for aggregate: FolderAggregate) -> String {
        switch aggregate {
        case .uniform(let dir):  return glyph(for: dir, isUserSkipped: false)
        case .allUserSkipped:    return "⊖"
        case .mixed:             return ""
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
        refreshDirectionToolbarEnabled()
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
        // First + Second columns: colored status icon instead of plain text.
        if col == .left || col == .right {
            return makeStatusCell(in: outlineView, node: node, isFirstReplica: col == .left)
        }
        // Path column: Finder-style icon + name. Folders get a tinted
        // folder icon that reflects the aggregate direction of their
        // descendants; files get a neutral doc icon.
        if col == .path {
            return makePathCell(in: outlineView, node: node)
        }

        // Remaining text-only columns: Size, Progress, Type. Folders
        // leave them blank — folder aggregate stats are out of scope
        // for v1 of this column.
        let value: String
        if let row = node.row, row < items.count {
            let stateItem = items[row]
            switch col {
            case .size:      value = formatSize(stateItem.sizeBytes, type: stateItem.fileType)
            case .progress:  value = stateItem.progress.trimmingCharacters(in: .whitespaces)
            case .type:      value = stateItem.fileType
            case .path, .left, .right, .direction: value = ""  // handled above
            }
        } else {
            value = ""
        }
        return makeCell(in: outlineView, identifier: column.identifier, text: value, column: col, isFolder: !node.isLeaf)
    }

    /// Builds (or recycles) the Path-column cell with Finder-style icon
    /// + name. Folder icons are tinted per the folder's aggregate
    /// direction; files get a neutral doc icon.
    private func makePathCell(in outlineView: NSOutlineView, node: ReconcileNode) -> NSView {
        let id = NSUserInterfaceItemIdentifier("PathCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? PathCellView ?? {
            let v = PathCellView()
            v.identifier = id
            return v
        }()
        if node.isLeaf {
            cell.configureAsFile(name: node.name)
        } else {
            cell.configureAsFolder(name: node.name)
        }
        return cell
    }

    /// Builds (or recycles) a status-icon cell for the First or Second
    /// column. Folder rows show no icon (empty cell).
    private func makeStatusCell(in outlineView: NSOutlineView,
                                node: ReconcileNode,
                                isFirstReplica: Bool) -> NSView {
        // Recycle identifier names retained as "StatusLocal" / "StatusRemote"
        // — they're internal NSOutlineView pool keys, not user-visible.
        // Renaming would invalidate cells already in the recycle pool the
        // first time a long-running app sees the rename. Cheap to keep stable.
        let id = NSUserInterfaceItemIdentifier(isFirstReplica ? "StatusLocal" : "StatusRemote")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? StatusIconCellView ?? {
            let v = StatusIconCellView()
            v.identifier = id
            return v
        }()
        if let row = node.row, row < items.count {
            cell.configure(status: isFirstReplica ? items[row].left : items[row].right)
        } else {
            cell.configure(status: "")  // folders have no per-side state
        }
        return cell
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
            // Leaf: direction is the file's own state.
            let item = items[row]
            let skipped = userSkipped.contains(row)
            cell.textField?.stringValue = DirectionVisual.glyph(for: item.direction, isUserSkipped: skipped)
            cell.tint = DirectionVisual.tint(for: item.direction, isUserSkipped: skipped)
        } else {
            // Folder: badge reflects the aggregate of its descendants.
            // Uniform → same glyph/tint as a leaf with that direction.
            // Mixed → empty cell so the user can tell the folder isn't
            //         a one-click target.
            let agg = node.aggregate(items: items, userSkipped: userSkipped)
            cell.textField?.stringValue = DirectionVisual.glyph(for: agg)
            cell.tint = DirectionVisual.tint(for: agg)
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
        view.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        // FAILED in the Progress column is loud red bold — most users
        // notice a sync failure only by scrolling to the row otherwise.
        let isFailure = (column == .progress) && text.uppercased().contains("FAIL")
        if isFailure {
            view.textField?.textColor = .systemRed
            view.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .bold)
        } else {
            view.textField?.textColor = .labelColor
        }
        _ = isFolder  // folder-vs-leaf distinction handled by PathCellView now
        return view
    }

    private func formatSize(_ bytes: Int64, type: String) -> String {
        if bytes == 0 && type.uppercased() == "DIR" { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
