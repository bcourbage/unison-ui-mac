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
    /// Per-row user-pinned decisions that override the rendered badge.
    /// Three cases, all mutually exclusive (the dict can hold at most
    /// one entry per row):
    ///
    ///   - `.skip`        → user chose Skip. Distinguishes from auto-
    ///     detected conflicts: OCaml's `unisonRiToDirection` returns
    ///     `"<-?->"` for BOTH `Conflict "files differed"` and `Conflict
    ///     "skip requested"`, so we need Swift-side state to tell the
    ///     two apart visually.
    ///   - `.forceOlder` / `.forceNewer` → user chose Force Older /
    ///     Force Newer. The resulting OCaml direction is `"---->"` or
    ///     `"<----"` based on mtime; the override flag exists so the
    ///     badge shows the user's *decision* rather than the mtime-
    ///     derived arrow. Without this the user couldn't tell whether
    ///     a row's "→ Second" arrow was a deliberate left/right pick
    ///     or just where the newer mtime happened to land.
    ///
    /// Cleared on every rescan — OCaml rebuilds the row set from
    /// scratch, so any persisted overrides would risk pointing at
    /// rows that no longer exist or have shifted indices.
    private var rowOverrides: [Int: RowOverride] = [:]
    private let profile: String
    private let onClose: CloseHandler
    private let onRescanRequested: RescanRequest
    private let outlineView = NSOutlineView()
    private let summaryLabel = NSTextField(labelWithString: "")
    /// Visible only when the most-recent status message has more than
    /// one line — OCaml's `displayStatus` frequently includes multi-line
    /// SSH error dumps, which we'd otherwise truncate to the first line.
    /// Clicking the button opens an NSAlert with the full text. The
    /// summary label also picks up the full text as a `toolTip` so the
    /// detail is one hover away.
    private let statusDetailsButton = NSButton(title: "Details…", target: nil, action: nil)
    /// Cached full text for the Details button. Reset on every status
    /// update so we never show stale messages.
    private var lastMultiLineStatus: String?
    private let progressBar = NSProgressIndicator()
    private let detailsTextView = NSTextView()
    private let detailsScroll = NSScrollView()
    private let toolbarDelegate = ReconcileToolbarDelegate()
    private(set) var isSyncing = false
    /// One DiffWindowController per reconcile session, reused across
    /// multiple Diff invocations. Created lazily on the first Diff
    /// action — most syncs never need it. Survives the reconcile
    /// window closing: a user might still want to read the diff after
    /// clicking back to the picker, and the window is read-only so a
    /// stale association with the closed reconcile is harmless.
    private var diffWindowController: DiffWindowController?
    /// True when the active profile's `.prf` declares at least one
    /// `merge = …` pattern. Drives the toolbar's Merge-button
    /// visibility AND the Edit-menu Merge item's enablement. Set at
    /// init time by the AppDelegate based on a `ProfileDocument.parse`
    /// of the .prf — we don't query OCaml for this because there's no
    /// upstream-registered callback for it and patching uimacbridge.ml
    /// is off-limits for this app (LLM-built, won't be proposed upstream).
    let mergeConfigured: Bool

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
         mergeConfigured: Bool,
         onClose: @escaping CloseHandler,
         onRescanRequested: @escaping RescanRequest) {
        self.profile = profile
        self.items = []
        self.mergeConfigured = mergeConfigured
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
        rowOverrides.removeAll()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        setSummary(summaryText(profile: profile))
        refreshDirectionToolbarEnabled()
    }

    private func configure(profile: String) {
        guard let contentView = window?.contentView else { return }

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        // Initial config — setSummary keeps the multi-line state in
        // sync even though there's nothing stale at startup. Cheaper to
        // keep one code path than to duplicate the assignment.
        setSummary(summaryText(profile: profile))
        // byTruncatingTail (the default for label-style text fields) is
        // wrong for our case — when long SSH error output lands in the
        // summary slot, byTruncatingMiddle keeps the start AND end
        // visible, which is more useful at a glance.
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.cell?.usesSingleLineMode = true

        // Details button: hidden by default, shown only when the most
        // recent status message has more than one line. SSH connect
        // failures dump multi-line stderr through `displayStatus`, which
        // we'd otherwise truncate to the first line.
        statusDetailsButton.target = self
        statusDetailsButton.action = #selector(showStatusDetails(_:))
        statusDetailsButton.bezelStyle = .inline
        statusDetailsButton.controlSize = .small
        statusDetailsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusDetailsButton.isHidden = true

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

        // Summary row: label takes the available width; button hugs to
        // the trailing edge and only appears when there's multi-line
        // status to disclose.
        let summaryRow = NSStackView(views: [summaryLabel, statusDetailsButton])
        summaryRow.orientation = .horizontal
        summaryRow.spacing = 6
        summaryRow.alignment = .firstBaseline
        summaryRow.distribution = .fill
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusDetailsButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [summaryRow, progressBar, scroll, detailsScroll])
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
            summaryRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
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
        // Diff handlers route Unison's displayDiff / displayDiffErr
        // callbacks into the (lazily-created) DiffWindowController.
        // We install on every reconcile open so the most recent
        // window is the one that receives the result — old diff
        // windows from prior reconciles keep their static content.
        UnisonBridge.installDiffHandler { [weak self] title, text in
            self?.diffWindowController?.showDiff(title: title, text: text)
        }
        UnisonBridge.installDiffErrHandler { [weak self] msg in
            self?.diffWindowController?.showError(msg)
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
        // v5 bump: the direction group's subitem set is now profile-
        // dependent (Merge subitem omitted when the .prf has no `merge`
        // pref). Bumping the identifier resets any autosaved layout so
        // users coming from v4 don't carry a Merge button into profiles
        // that don't support it. v4 was the Local/Remote → First/Second
        // terminology pass.
        let toolbar = NSToolbar(identifier: "ReconcileToolbar.v5")
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
        setSummary("Synchronizing \(profile)…")
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
        setSummary(message)
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
            detailsTextView.string = "\(node.pathFromRoot)/\n\(leafCount) item\(leafCount == 1 ? "" : "s") in this folder"
        }
        detailsTextView.textColor = .labelColor
    }

    func updateScanStatus(_ msg: String) {
        let (firstLine, fullText, hasMore) = Self.splitStatus(msg)
        guard !firstLine.isEmpty else { return }
        summaryLabel.stringValue = firstLine
        if hasMore {
            // Cache the full text and expose it two ways: via tooltip
            // (one-hover access) and via a Details button that opens a
            // larger scrolling sheet (selectable, copyable).
            lastMultiLineStatus = fullText
            summaryLabel.toolTip = fullText
            statusDetailsButton.isHidden = false
        } else {
            lastMultiLineStatus = nil
            summaryLabel.toolTip = nil
            statusDetailsButton.isHidden = true
        }
    }

    /// Split a status message into (firstLine, fullText, hasMore).
    /// `fullText` is the trimmed input; `firstLine` is just the first
    /// trimmed line; `hasMore` is true iff there's at least one
    /// non-empty additional line. Pure function — `nonisolated` so it
    /// can be exercised directly from XCTest (which runs on whatever
    /// thread XCTest picks, not necessarily MainActor).
    nonisolated static func splitStatus(_ msg: String) -> (firstLine: String,
                                                            fullText: String,
                                                            hasMore: Bool) {
        let lines = msg.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmpty = lines.filter { !$0.isEmpty }
        let firstLine = nonEmpty.first ?? ""
        let hasMore = nonEmpty.count > 1
        let fullText = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (firstLine, fullText, hasMore)
    }

    /// Set the summary label to a non-status string (e.g. the post-scan
    /// summary "default · 5 items · 2 conflicts") and clear any stale
    /// multi-line-status disclosure. Use this instead of writing
    /// directly to `summaryLabel.stringValue` so the Details button
    /// doesn't linger past the message that produced it.
    private func setSummary(_ text: String) {
        summaryLabel.stringValue = text
        summaryLabel.toolTip = nil
        lastMultiLineStatus = nil
        statusDetailsButton.isHidden = true
    }

    @objc private func showStatusDetails(_ sender: Any?) {
        guard let text = lastMultiLineStatus, !text.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Status details"
        // NSAlert truncates `informativeText` aggressively for long
        // strings — use an accessoryView with a scrolling text view so
        // multi-screen SSH error dumps stay readable + selectable.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        textView.autoresizingMask = [.width, .height]
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        setSummary(summaryText(profile: profile, syncDone: true))
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
            // Update the row's pinned override based on the action. Skip
            // / Force Older / Force Newer are mutually exclusive — each
            // overwrites whichever flag was there before. Plain direction
            // overrides (toFirst, toSecond) and Merge clear any override
            // since they're auto-direction wins, not user-intent flags.
            switch action {
            case .skip:        rowOverrides[row] = .skip
            case .forceOlder:  rowOverrides[row] = .forceOlder
            case .forceNewer:  rowOverrides[row] = .forceNewer
            case .toFirst, .toSecond, .merge:
                rowOverrides.removeValue(forKey: row)
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
            setSummary(summaryText(profile: profile))
        }
    }

    // MARK: - Ignore actions

    /// Right-click context menu for the outline view. Contents mirror
    /// a subset of the Action + Edit menus, picking the per-row items
    /// that make sense in context: Diff (top — most common right-click
    /// intent), then Ignore Path/Ext/Name. Direction overrides aren't
    /// here because the toolbar already covers them and the user has
    /// the row's row-tinted badge to drive direction decisions.
    private func makeRowContextMenu() -> NSMenu {
        let menu = NSMenu()
        // Validation: NSMenu doesn't auto-revalidate context menus on
        // openPopupContextMenu, but it does call `validateUserInterfaceItem`
        // on each item's target when the menu opens (we set autoenablesItems
        // and rely on the validation method below).
        menu.autoenablesItems = true

        let diff = NSMenuItem(title: "Diff",
                              action: #selector(diffMenuAction(_:)),
                              keyEquivalent: "")
        diff.target = self
        menu.addItem(diff)
        menu.addItem(.separator())

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
    ///
    /// Used by per-row actions that meaningfully apply to multiple leaves
    /// (Ignore Path/Ext/Name — though they only need one path, the
    /// pattern they install affects all matches).
    private func rowForPendingMenuAction() -> Int? {
        let clicked = outlineView.clickedRow
        if clicked >= 0,
           let node = outlineView.item(atRow: clicked) as? ReconcileNode,
           let row = node.row {
            return row
        }
        return leafRowsInSelection().first
    }

    /// Stricter row resolver for Diff (delegates to
    /// `RowSelectionRules.diffTarget` so the rule is unit-tested).
    /// Diff is single-leaf only — folders / multi-row / empty
    /// selections return nil.
    private func rowForDiff() -> Int? {
        let clicked = outlineView.clickedRow
        let rightClickedNode: ReconcileNode? = (clicked >= 0)
            ? (outlineView.item(atRow: clicked) as? ReconcileNode)
            : nil
        return RowSelectionRules.diffTarget(
            rightClickedNode: rightClickedNode,
            selectedNodes: selectedNodes()
        )
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
        // clears rowOverrides + redraws the outline.
    }

    // MARK: - Direction menu actions

    /// Action-menu direction items. Tag carries which DirectionAction;
    /// behavior is identical to clicking the corresponding toolbar
    /// segmented button — applies the direction to every leaf in the
    /// current selection (or the right-clicked row).
    @objc private func directionMenuAction(_ sender: NSMenuItem) {
        guard let action = DirectionAction.from(menuTag: sender.tag) else { return }
        applyDirection(action)
    }

    // MARK: - Diff

    /// Open the diff window for the right-clicked / first-selected
    /// leaf row. The diff itself runs asynchronously on the OCaml
    /// side; the result (or an error) arrives via the diff handlers
    /// installed in `configure`.
    @objc private func diffMenuAction(_ sender: Any?) {
        applyDiff()
    }

    /// Public so the context menu can call this directly. Returns
    /// silently when the action isn't applicable (no selection, sync
    /// in flight, can't-diff row) — `validateMenuItem` should have
    /// already greyed the entry point.
    func applyDiff() {
        guard !isSyncing else { NSSound.beep(); return }
        guard let row = rowForDiff(),
              row >= 0, row < items.count else { NSSound.beep(); return }
        let path = items[row].path
        // Defensive re-check — the menu validation calls canDiff too,
        // but a context-menu click on a row that changed since
        // validation could slip through. Bridge call is cheap.
        guard unison_bridge_can_diff(Int32(row)) else {
            TraceLog.shared.write("ReconcileWindow: canDiff=false for row \(row) (\(path))")
            // Surface a brief alert rather than silently beeping —
            // user clicked Diff, expects feedback.
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Can't diff “\(path)”"
            // canDiff filters: directories, symlinks, problem rows
            // (e.g. access errors), and rows where both sides are
            // PropsChanged-only or one side is Unchanged + the other
            // is PropsChanged-only. Binary files DO pass canDiff;
            // they just produce uninformative output from `diff -u`
            // ("Binary files differ") — so we don't mention binary
            // in the alert text, since user can technically click
            // Diff on a binary file and Unison will return that.
            alert.informativeText =
                "Unison can only diff rows whose content differs on both " +
                "sides and that are actual files (not directories or " +
                "symlinks). This row is either a directory, a symlink, " +
                "had only metadata changes, or hit a problem during " +
                "update detection."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        // Lazily create the diff window — most reconcile sessions
        // never need one.
        if diffWindowController == nil {
            diffWindowController = DiffWindowController()
        }
        diffWindowController?.surfaceForLoading(path: path)
        TraceLog.shared.write("ReconcileWindow: diff requested for row \(row) (\(path))")
        unison_bridge_run_show_diffs(Int32(row))
        // Result arrives via the diff handler → diffWindowController.showDiff,
        // or via the diff-err handler → showError.
    }

    // MARK: - Select Conflicts / Revert to Recommendation

    /// Select every leaf row that's an unresolved conflict — `<-?->`
    /// from OCaml with no user override pinned. Jumps the user to
    /// the rows that still need attention before sync. Pure
    /// classification logic lives in `RowSelectionRules`.
    @objc private func selectConflictsAction(_ sender: Any?) {
        let conflictRows = Set(RowSelectionRules.unresolvedConflictRows(
            items: items, rowOverrides: rowOverrides
        ))
        if conflictRows.isEmpty {
            // Nothing to select — give an audible cue rather than
            // wiping the existing selection.
            NSSound.beep()
            return
        }
        // Map row indices → outline-view row indices via the leaf nodes.
        // Easier than going through the tree: we already have the rows
        // and the outline view lets us select by item.
        var outlineRowsToSelect = IndexSet()
        for node in tree.allNodes where node.isLeaf {
            guard let row = node.row, conflictRows.contains(row) else { continue }
            let outlineRow = outlineView.row(forItem: node)
            if outlineRow >= 0 { outlineRowsToSelect.insert(outlineRow) }
        }
        outlineView.selectRowIndexes(outlineRowsToSelect, byExtendingSelection: false)
        if let first = outlineRowsToSelect.first {
            outlineView.scrollRowToVisible(first)
        }
        TraceLog.shared.write(
            "ReconcileWindow: Select Conflicts → \(conflictRows.count) row(s)"
        )
    }

    /// Clear user overrides on every leaf row in the current
    /// selection, returning them to OCaml's auto-recommended state.
    /// Mirrors the legacy app's "Revert to Unison's Recommendation"
    /// Edit-menu item. Doesn't touch OCaml — only the Swift-side
    /// override dict — since the underlying direction strings are
    /// what OCaml decided in the first place.
    @objc private func revertSelectionAction(_ sender: Any?) {
        guard !isSyncing else { NSSound.beep(); return }
        let rows = Set(leafRowsInSelection())
        guard !rows.isEmpty else { NSSound.beep(); return }
        let before = rowOverrides.count
        rowOverrides = RowSelectionRules.clearOverrides(
            rowOverrides: rowOverrides, forRows: rows
        )
        // Redraw every row that lost an override + every ancestor
        // folder so aggregates re-resolve.
        var nodesToReload: [ObjectIdentifier: ReconcileNode] = [:]
        for row in rows {
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
        TraceLog.shared.write(
            "ReconcileWindow: Revert → cleared overrides on \(before - rowOverrides.count) row(s)"
        )
    }

    /// NSMenuItemValidation entry point. AppKit walks the responder chain
    /// looking for whoever implements the menu item's action; the
    /// reconcile controller claims the ignore and direction selectors,
    /// so AppKit calls us back here for both. We grey items out when
    /// sync is in flight (state mutation is unsafe) or when no leaf row
    /// is selectable. The .merge case is additionally hidden when the
    /// active profile's .prf has no `merge` pref.
    ///
    /// AppKit only calls this on the main thread (menu validation runs
    /// as the menu is about to open). The class is `@MainActor` so we
    /// let the Swift-6 isolation match the runtime guarantee.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(ignoreMenuAction(_:)) {
            guard !isSyncing else { return false }
            return rowForPendingMenuAction() != nil
        }
        if menuItem.action == #selector(diffMenuAction(_:)) {
            guard !isSyncing else { return false }
            // Diff is strictly single-leaf — `rowForDiff` returns nil
            // for folder selections, multi-row selections, and
            // right-clicks on folders. The bridge's canDiff layer
            // then excludes one-sided files (typ=ABSENT on either
            // replica), symlinks, problem rows, and props-only-on-
            // both-sides changes. Both gates must pass.
            guard let row = rowForDiff(),
                  row >= 0, row < items.count else { return false }
            return unison_bridge_can_diff(Int32(row))
        }
        if menuItem.action == #selector(selectConflictsAction(_:)) {
            // Allowed during sync — selection-only, doesn't mutate
            // any row state. Useful for surveying what's left.
            return !RowSelectionRules.unresolvedConflictRows(
                items: items, rowOverrides: rowOverrides
            ).isEmpty
        }
        if menuItem.action == #selector(revertSelectionAction(_:)) {
            guard !isSyncing else { return false }
            // Only useful if at least one selected row carries an
            // override. Otherwise the action is a no-op.
            let rows = leafRowsInSelection()
            return rows.contains { rowOverrides[$0] != nil }
        }
        if menuItem.action == #selector(directionMenuAction(_:)) {
            guard !isSyncing else { return false }
            // Merge item hidden (returning false) when the profile has
            // no `merge` pref. We could also hide it via `isHidden`,
            // but validateMenuItem fires on every menu open and
            // returning false gives consistent disabled-grey styling.
            if let action = DirectionAction.from(menuTag: menuItem.tag),
               action == .merge,
               !mergeConfigured {
                return false
            }
            return !leafRowsInSelection().isEmpty
        }
        return true
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

/// Direction-column tints + glyphs. A row's badge is the function of
/// two inputs: the OCaml-resolved `direction` string (`"---->"`,
/// `"<----"`, `"<-?->"`, `"<-M->"`), and an optional `RowOverride`
/// recording what the user pinned for that row. The override wins —
/// the whole point is to make "I chose this" legible at a glance
/// rather than conflating it with the auto-resolved arrow.
///
/// Override mapping:
///   - `.skip`       → gray ⊖ (settled — "I told it not to sync")
///   - `.forceOlder` → brown ↺ (mtime decision: older wins)
///   - `.forceNewer` → teal  ↻ (mtime decision: newer wins)
///
/// Internal (not `private`) so the unit tests can pin the glyph/tint
/// mapping without going through view introspection.
enum DirectionVisual {

    /// Older-wins force badge: brown (matches DirectionAction.forceOlder
    /// accent on the toolbar SF Symbol) with reduced alpha to read as
    /// a "decided" state rather than competing with conflict-orange.
    private static let forcedOlderTint = NSColor.systemBrown.withAlphaComponent(0.65)
    /// Newer-wins force badge: teal (matches DirectionAction.forceNewer).
    private static let forcedNewerTint = NSColor.systemTeal.withAlphaComponent(0.55)
    /// Skip badge: neutral gray.
    private static let skipTint = NSColor.systemGray.withAlphaComponent(0.45)

    static func tint(for direction: String, override: RowOverride?) -> NSColor {
        // Override wins over the underlying direction — the visual
        // signals user intent, not the resolved arrow.
        if let override {
            switch override {
            case .skip:        return skipTint
            case .forceOlder:  return forcedOlderTint
            case .forceNewer:  return forcedNewerTint
            }
        }
        switch direction {
        case "---->": return NSColor(red: 0x97/255.0, green: 0xBB/255.0, blue: 0x68/255.0, alpha: 1.0)
        case "<----": return NSColor(red: 0x5A/255.0, green: 0x96/255.0, blue: 0xDE/255.0, alpha: 1.0)
        case "<-?->": return NSColor.systemOrange.withAlphaComponent(0.85)
        case "<-M->": return NSColor.systemPurple.withAlphaComponent(0.75)
        default:      return .clear
        }
    }

    static func glyph(for direction: String, override: RowOverride?) -> String {
        // Override-driven glyphs hide the directional arrow on purpose:
        // for force older/newer the resulting arrow is just an mtime
        // artifact, not the user's decision. Showing the arrow would
        // make it ambiguous whether the user clicked → Second or Force
        // Newer (where mtime happened to be on First's side).
        if let override {
            switch override {
            // ⊖ matches the toolbar Skip button's minus.circle SF Symbol.
            case .skip:        return "⊖"
            // ↺ (counterclockwise) reads as "turn back time" — older.
            case .forceOlder:  return "↺"
            // ↻ (clockwise) reads as "advance time" — newer.
            case .forceNewer:  return "↻"
            }
        }
        switch direction {
        case "---->": return "→"
        case "<----": return "←"
        case "<-?->": return "⚠︎"   // auto-conflict — needs the user's input
        case "<-M->": return "M"
        default:      return direction
        }
    }

    /// Aggregate variants for folder rows. Uniform direction (no
    /// overrides) → the same glyph + tint as a leaf with that direction.
    /// All-same-override → that override's badge (the underlying
    /// direction is hidden, same as the per-row rule). Mixed → no
    /// badge (empty cell, clear tint).
    static func tint(for aggregate: FolderAggregate) -> NSColor {
        switch aggregate {
        case .uniform(let dir):  return tint(for: dir, override: nil)
        case .allUserSkipped:    return skipTint
        case .allForcedOlder:    return forcedOlderTint
        case .allForcedNewer:    return forcedNewerTint
        case .mixed:             return .clear
        }
    }

    static func glyph(for aggregate: FolderAggregate) -> String {
        switch aggregate {
        case .uniform(let dir):  return glyph(for: dir, override: nil)
        case .allUserSkipped:    return "⊖"
        case .allForcedOlder:    return "↺"
        case .allForcedNewer:    return "↻"
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
        // Progress column: custom-drawn bar + percent text via
        // ProgressCellView. Folder rows show nothing (no per-row
        // progress for folder summaries — covered by the global bar).
        if col == .progress {
            return makeProgressCell(in: outlineView, node: node)
        }

        // Remaining text-only columns: Size, Type. Folders leave them
        // blank — folder aggregate stats are out of scope for v1.
        let value: String
        if let row = node.row, row < items.count {
            let stateItem = items[row]
            switch col {
            case .size:      value = formatSize(stateItem.sizeBytes, type: stateItem.fileType)
            case .type:      value = stateItem.fileType
            case .progress:  value = ""  // handled above
            case .path, .left, .right, .direction: value = ""  // handled above
            }
        } else {
            value = ""
        }
        return makeCell(in: outlineView, identifier: column.identifier, text: value, column: col, isFolder: !node.isLeaf)
    }

    /// Builds (or recycles) the Progress-column cell. Leaf rows get a
    /// ProgressCellView (bar + text); folder rows get an empty
    /// `NSTableCellView` (folders don't accumulate per-row progress —
    /// the global bar at the top of the window covers that case).
    private func makeProgressCell(in outlineView: NSOutlineView,
                                   node: ReconcileNode) -> NSView {
        let id = NSUserInterfaceItemIdentifier("ProgressCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ProgressCellView ?? {
            let v = ProgressCellView()
            v.identifier = id
            return v
        }()
        if let row = node.row, row < items.count {
            cell.configure(progress: items[row].progress)
        } else {
            cell.configure(progress: "")
        }
        return cell
    }

    /// Builds (or recycles) the Path-column cell with Finder-style icon
    /// + name. Folder icons are tinted per the folder's aggregate
    /// direction; files get a neutral doc icon. The full reconstructed
    /// path goes into the cell as a hover tooltip so users can still
    /// read the whole path even when the column is too narrow to show
    /// it (column truncates with `byTruncatingMiddle`).
    private func makePathCell(in outlineView: NSOutlineView, node: ReconcileNode) -> NSView {
        let id = NSUserInterfaceItemIdentifier("PathCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? PathCellView ?? {
            let v = PathCellView()
            v.identifier = id
            return v
        }()
        let fullPath = node.pathFromRoot
        if node.isLeaf {
            cell.configureAsFile(name: node.name, fullPath: fullPath)
        } else {
            cell.configureAsFolder(name: node.name, fullPath: fullPath)
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
            // Leaf: direction is the file's own state, possibly tweaked
            // by a user-pinned override (skip / forceOlder / forceNewer).
            let item = items[row]
            let override = rowOverrides[row]
            cell.textField?.stringValue = DirectionVisual.glyph(for: item.direction, override: override)
            cell.tint = DirectionVisual.tint(for: item.direction, override: override)
        } else {
            // Folder: badge reflects the aggregate of its descendants.
            // Uniform direction → same glyph/tint as a leaf. All-same-
            // override → that override's badge (hides the underlying
            // direction, matching per-row semantics). Mixed → empty.
            let agg = node.aggregate(items: items, rowOverrides: rowOverrides)
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
                                    (column == .direction) ? .center : .left
        view.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        view.textField?.textColor = .labelColor
        // The Progress column used to land here with a FAIL-red branch;
        // both progress text and the FAIL state now live in
        // ProgressCellView (`isFailure` switches the overlay to bold red).
        _ = isFolder  // folder-vs-leaf distinction handled by PathCellView now
        return view
    }

    private func formatSize(_ bytes: Int64, type: String) -> String {
        if bytes == 0 && type.uppercased() == "DIR" { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
