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

    /// Reconcile-window lifecycle phase. Single source of truth for
    /// what stage the window is in:
    ///   - `.ready`   — post-init2 (or freshly opened), pre-Go;
    ///                  items may be empty (up-to-date) or populated
    ///   - `.syncing` — post-Go, pre-completion
    ///   - `.done`    — sync finished (cleanly or with failures); the
    ///                  user must rescan to start a new cycle
    ///
    /// Drives both the summary text (via `summaryText()`) AND the
    /// gating of action buttons + menu items (via `isActionable`).
    /// Keeping these in lockstep means "what the user reads in the
    /// summary" and "what the user can click" can't get out of sync.
    private var phase: ReconcileSummary.Phase = .ready
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
        // Default 1100×580. Width chosen to fit every toolbar item at
        // `.iconAndLabel` mode (Profiles, Rescan, direction group's 4
        // expanded subitems, Go, Stop) plus the unified-toolbar title
        // area without spilling into the overflow chevron. The clamp
        // below shrinks the initial frame on screens that can't host
        // 1100×580 (Larger Text mode on a 13" MacBook, etc.) so the
        // window never opens with its right edge offscreen.
        let initialSize = NSSize(width: 1100, height: 580)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedSize = NSSize(
            width:  min(initialSize.width,  screen.width  - 40),
            height: min(initialSize.height, screen.height - 40)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: clampedSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        // Hard minimum content size. AppKit refuses to restore an
        // autosaved frame narrower than this — so a window resized
        // narrow under one profile won't permanently squish all future
        // reconcile windows. 960 fits the unified toolbar comfortably;
        // 400 keeps the outline view from collapsing past usefulness.
        window.contentMinSize = NSSize(width: 960, height: 400)
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
    /// Three choices:
    ///   - **Keep Syncing**: don't close; sync continues; user can
    ///     hit Stop or wait for completion.
    ///   - **Abort & Close**: invoke the real abort (Abort.all in
    ///     OCaml), then close the window. In-flight transfers may
    ///     complete naturally before the abort propagates; subsequent
    ///     rows fail. User loses visibility into FAILED rows.
    ///   - **Close (let it run)**: close the window without aborting.
    ///     OCaml worker keeps syncing in the background until natural
    ///     completion. Useful when the user wants to keep the transfer
    ///     going but reclaim screen space.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard isSyncing else { return true }
            let alert = NSAlert()
            alert.messageText = "Synchronization is still running"
            alert.informativeText =
                "Choose how to close this window:\n\n" +
                "• Abort & Close — stop the sync and close. Already-in-progress " +
                "transfers may complete before the abort takes effect; queued " +
                "rows will fail.\n" +
                "• Close (let it run) — close the window but let the sync " +
                "continue in the background until it finishes naturally.\n" +
                "• Keep Syncing — don't close. You can hit Stop in the toolbar " +
                "to abort with the window staying open."
            alert.addButton(withTitle: "Keep Syncing")
            let abortClose = alert.addButton(withTitle: "Abort & Close")
            abortClose.hasDestructiveAction = true
            alert.addButton(withTitle: "Close (let it run)")
            alert.alertStyle = .warning
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Keep Syncing
                return false
            case .alertSecondButtonReturn:
                // Abort & Close
                Log.reconcile.notice("user closed mid-sync with Abort & Close")
                unison_bridge_abort_sync()
                return true
            case .alertThirdButtonReturn:
                // Close (let it run)
                Log.reconcile.notice("user closed mid-sync without aborting")
                return true
            default:
                return false
            }
        }
    }

    /// Replace the displayed items (e.g. after a rescan completes). Must
    /// be called on the main thread. Rebuilds the tree per the user's
    /// `SettingsModel.reconcileLayoutMode` (default `.nestedCollapsed`,
    /// mirroring upstream Unison's "Layout" segmented control) and
    /// expands folders per `SettingsModel.reconcileExpandPolicy`
    /// (default `.smart` — only branches with unresolved conflicts).
    /// Both settings are re-read on every populate, so a change in
    /// the Settings window takes effect on the next rescan.
    func replaceItems(_ newItems: [StateItem]) {
        items = newItems
        let layout = SettingsModel.reconcileLayoutMode()
        let policy = SettingsModel.reconcileExpandPolicy()
        tree = ReconcileTree(items: newItems, layout: layout)
        rowOverrides.removeAll()
        outlineView.reloadData()
        applyExpandPolicy(policy)
        // Fresh row set ⇒ back to the ready phase; the previous
        // sync (if any) is no longer in scope.
        phase = .ready
        setSummary(summaryText())
        refreshToolbarEnabled()
    }

    /// Walk the new tree and ask the outline view to expand the nodes
    /// the policy selects. `rowOverrides` is empty at this point
    /// (cleared in replaceItems) — the policy still consults it so
    /// the same helper is reusable from any future "re-apply policy
    /// without rebuilding the tree" path.
    private func applyExpandPolicy(_ policy: ReconcileTree.ExpandPolicy) {
        let toExpand = tree.nodesToExpand(
            policy: policy, items: items, rowOverrides: rowOverrides)
        for node in toExpand {
            outlineView.expandItem(node, expandChildren: false)
        }
    }

    private func configure(profile: String) {
        guard let contentView = window?.contentView else { return }

        // Primary status line — uses the system's primary label
        // color (near-black in light mode, near-white in dark mode)
        // rather than `.secondaryLabelColor`. The summary carries
        // load-bearing information (current phase, item count, total
        // bytes, direction breakdown, error count) and deserves the
        // primary text-color hierarchy slot, not the secondary one.
        // Bumped to `.medium` weight for a touch more presence
        // without going to bold.
        summaryLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .medium)
        summaryLabel.textColor = .labelColor
        // Initial config — setSummary keeps the multi-line state in
        // sync even though there's nothing stale at startup. Cheaper to
        // keep one code path than to duplicate the assignment.
        setSummary(summaryText())
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
        // 24pt rows (was 20) — gives the Progress column's
        // NSProgressIndicator at `.regular` controlSize enough vertical
        // room to render its bar without clipping, and keeps the rest
        // of the row contents (Finder-style icon + name, status icons)
        // comfortable rather than cramped. Comparable to Finder's
        // list-view default row height.
        outlineView.rowHeight = 24
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
        // status to disclose. Error banner sits next to it, also
        // hugging trailing edge, also only visible when relevant.
        let summaryRow = NSStackView(views: [summaryLabel, statusDetailsButton])
        summaryRow.orientation = .horizontal
        summaryRow.spacing = 6
        summaryRow.alignment = .firstBaseline
        summaryRow.distribution = .fill
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Compression resistance LOW so the label truncates (its
        // lineBreakMode is .byTruncatingMiddle) when the summary text
        // grows. Defaults to .defaultHigh (750), which combined with
        // `usesSingleLineMode = true` told AutoLayout "if my text
        // doesn't fit, grow the parent instead of compressing me" —
        // causing the reconcile window to widen on its own at init2
        // completion when the summary went from "Looking for
        // changes..." to "<profile> · 121 items · 121 → second".
        // AppKit then walked the constraint chain up to the window
        // itself (the only thing with no required width pin under a
        // .resizable styleMask) and silently widened it.
        summaryLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
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
        // Compose the breakdown into the summary so the user keeps
        // the at-a-glance totals (item count + bytes + direction)
        // visible throughout the transfer. updateScanStatus(_:)
        // suppresses its own writes while isSyncing is true so
        // OCaml's rotating per-file status doesn't overwrite this.
        phase = .syncing
        setSummary(summaryText())
        refreshToolbarEnabled()
        TraceLog.shared.write("ReconcileWindow: starting sync")
        unison_bridge_synchronize()
    }

    /// Toolbar "Profiles" action — return to the picker.
    func returnToPicker() {
        window?.performClose(nil)
    }

    /// Toolbar Stop action — abort the running sync. Calls
    /// `unison_bridge_abort_sync()`, which sets OCaml's `Abort.abortAll`
    /// flag; the sync worker observes it at the next
    /// `Abort.check` checkpoint (typically between files) and unwinds
    /// by raising `Util.Transient "Aborted by user request"`. Already-
    /// in-progress operations may complete naturally before the abort
    /// propagates, so the user may see one or two more rows complete
    /// before the rest fail.
    ///
    /// Doesn't close the window — keeping it open lets the user
    /// inspect FAILED rows in the Progress column after the abort
    /// unwinds. `syncDidComplete` fires once OCaml has fully wound
    /// down and resets the UI to "done" state.
    func cancelSync() {
        guard isSyncing else { NSSound.beep(); return }
        Log.reconcile.notice("user requested Stop — sending abort signal to OCaml")
        TraceLog.shared.write("ReconcileWindow: user requested Stop — aborting in-flight sync")
        setSummary("Aborting sync… in-progress transfers may finish before the abort takes effect")
        unison_bridge_abort_sync()
        // Don't close the window. syncDidComplete will fire once the
        // OCaml side has fully unwound, at which point the user can
        // close manually OR rescan.
    }

    // MARK: - Scanning (initial or rescan)

    func rescan() {
        guard !isSyncing else { NSSound.beep(); return }
        onRescanRequested()
    }

    func beginScanning(_ message: String) {
        // Clear the displayed state of the previous scan up front so
        // the user can't mistake stale results for in-progress ones.
        // Without this, a rescan visually left the prior reconcile's
        // rows in place with just a "Rescanning…" summary line on
        // top — which read as "scan complete, here are the results"
        // until init2 actually returned. Clearing items, the tree,
        // and rowOverrides drops the outline view to empty for the
        // duration of the scan; `replaceItems(_:)` repopulates it
        // when init2 completes. For the initial-scan path
        // (`beginInitialScan`) this is a no-op visually — the window
        // was just opened and the row set was already empty.
        items = []
        tree = ReconcileTree(items: [])
        rowOverrides.removeAll()
        outlineView.reloadData()
        detailsTextView.string = "Select a row to see details."

        progressBar.isHidden = false
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        setSummary(message)
        refreshToolbarEnabled()
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

        // During an active sync, the summary line holds the static
        // breakdown ("Synchronizing · 121 items · 1.2 GB · …") set
        // by startSync(). OCaml's rotating per-file status narration
        // would otherwise overwrite that line by line, losing the
        // user's at-a-glance totals during a long transfer. The
        // global progress bar + per-row Progress cells carry the
        // dynamic state.
        //
        // For diagnostics, every status message — including ones
        // that look like errors — is logged to TraceLog (via the
        // AppDelegate-side handler that calls into this method).
        // Per-row failures get attributed at sync-complete via
        // `attributeRowFailuresFromDetails`, which scans each row's
        // OCaml-side details string for failure markers. The
        // combination of those two paths (TraceLog for the
        // diagnostic stream, per-row ⚠ + tooltip for user-visible
        // outcomes) replaced an earlier red banner pill that
        // accumulated keyword-matched status lines — that surface
        // proved redundant once per-row attribution landed, and was
        // prone to false positives on path-containing keywords.
        if !isSyncing {
            summaryLabel.stringValue = firstLine
            if hasMore {
                // Cache the full text and expose it two ways: via
                // tooltip (one-hover access) and via a Details button
                // that opens a larger scrolling sheet (selectable,
                // copyable).
                lastMultiLineStatus = fullText
                summaryLabel.toolTip = fullText
                statusDetailsButton.isHidden = false
            } else {
                lastMultiLineStatus = nil
                summaryLabel.toolTip = nil
                statusDetailsButton.isHidden = true
            }
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

        // Some Unison failure paths only update the row's
        // *details* field (`unison_bridge_ri_get_details`), not its
        // *progress* field. The screenshot example: a transfer
        // aborted because the source file changed mid-sync — Unison
        // stores "Transfer aborted" in the row's details but leaves
        // progress stuck at whatever percent it reached before the
        // abort. The Progress column would draw a partial blue bar
        // (looks successful-ish), the row wouldn't carry the ⚠ FAILED
        // marker, and the summary's failure count would miss it.
        //
        // Walk every row at sync-complete: for any row whose progress
        // isn't already FAILED, check its details string for a
        // failure marker and synthesize "FAILED: <reason>" into the
        // progress field if found. ProgressDescriptor.parse + the
        // ProgressCellView then take over as if Unison had emitted
        // FAILED itself.
        attributeRowFailuresFromDetails()

        // Count rows whose progress ended FAILED (now including the
        // synthesized ones from the pass above). Latches into the
        // phase so both the summary ("Synchronization completed with
        // N error(s)") AND the action-gating logic see the same
        // terminal state.
        let failures = items
            .filter { ProgressDescriptor.parse($0.progress).isFailure }
            .count
        phase = .done(failures: failures)
        setSummary(summaryText())
        refreshToolbarEnabled()
        TraceLog.shared.write("ReconcileWindow: sync complete (failures: \(failures))")
    }

    /// Walk every row whose progress field doesn't already indicate
    /// failure. Query its per-row details from OCaml; if the details
    /// contain a failure marker (Transfer aborted / Failed: /
    /// permission denied / …), synthesize a FAILED progress string
    /// for that row and reload it in the outline view. Catches the
    /// failure modes Unison signals via per-row details without
    /// touching the per-row progress field.
    ///
    /// Cost: ~one bridge round-trip per non-failed row, only at
    /// sync-complete time. For typical sync sizes that's tens or
    /// hundreds of round-trips synchronously on main — fast enough
    /// (each call is a single mutex-handoff to the OCaml worker that
    /// reads a stored string).
    private func attributeRowFailuresFromDetails() {
        for row in items.indices {
            if ProgressDescriptor.parse(items[row].progress).isFailure {
                continue
            }
            guard let cstr = unison_bridge_ri_get_details(Int32(row)) else {
                continue
            }
            let details = String(cString: cstr)
            guard Self.detailsIndicateFailure(details) else { continue }
            let reason = Self.failureReason(from: details)
            items[row] = items[row].with(
                progress: "FAILED: \(reason)",
                bytesTransferred: items[row].bytesTransferred)
            if let node = leafNode(forRow: row) {
                outlineView.reloadItem(node, reloadChildren: false)
            }
            TraceLog.shared.write(
                "ReconcileWindow: synthesized FAILED for row[\(row)] " +
                "(\(items[row].path)) — reason: \(reason)")
        }
    }

    /// Pure classification: does a per-row details string indicate a
    /// transfer failure that the row's progress field missed?
    /// Conservative — only triggers on markers unlikely to appear in
    /// success messages. "skipped" is deliberately NOT a marker
    /// because Unison uses it for user-initiated skips.
    nonisolated static func detailsIndicateFailure(_ details: String) -> Bool {
        let lowered = details.lowercased()
        let markers = [
            "transfer aborted",
            "transfer failed",
            "failed:",
            "permission denied",
            "could not open",
            "couldn't open",
            "no such file",
        ]
        return markers.contains(where: { lowered.contains($0) })
    }

    /// Extract a short user-facing reason from a per-row details
    /// string. Used to populate the synthesized FAILED progress
    /// message; gets truncated by the Progress column's lineBreakMode
    /// when displayed but is fully available in the details panel.
    nonisolated static func failureReason(from details: String) -> String {
        let markers = [
            "transfer aborted", "transfer failed", "failed:",
            "permission denied", "could not open", "couldn't open",
            "no such file",
        ]
        let lines = details.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // First line that contains a marker wins — that's the line
        // most directly describing the failure.
        for line in lines {
            let lower = line.lowercased()
            if markers.contains(where: { lower.contains($0) }) {
                return line
            }
        }
        // Fallback: last non-empty line.
        return lines.last ?? "transfer error"
    }

    /// Reset transient sync-UI state without closing the window. Called
    /// from the AppDelegate's fatal/warn-cancel handlers when sync was
    /// in flight (`isSyncing == true` at the time the alert fired).
    ///
    /// Keeping the window open after a sync fatal lets the user inspect
    /// which rows succeeded (Progress = "done") vs which failed
    /// (Progress = bold red "⚠ FAILED") before deciding to rescan or
    /// return to the picker.
    ///
    /// We transition `phase` to `.done(failures: ...)` here so the
    /// post-abort UI behaves the same as any other completed sync:
    /// Go is disabled (running it again on a half-aborted state is
    /// dicey — the user should rescan first), Stop is disabled
    /// (nothing to abort), Rescan is enabled (the obvious next
    /// step). The summary message is overridden with the explicit
    /// "Sync interrupted — <reason>" string, since that's more
    /// informative than a generic "Synchronization completed".
    func resetSyncUIAfterAbort(reason: String) {
        isSyncing = false
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        let failures = items
            .filter { ProgressDescriptor.parse($0.progress).isFailure }
            .count
        phase = .done(failures: failures)
        setSummary("Sync interrupted — \(reason)")
        refreshToolbarEnabled()
        TraceLog.shared.write("ReconcileWindow: resetSyncUIAfterAbort (\(reason))")
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
            setSummary(summaryText())
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
    /// reconcile controller claims those selectors, so AppKit calls
    /// us back here for each.
    ///
    /// State-changing actions (direction overrides, Go, Diff, Revert,
    /// Ignore) gate on `isActionable` — true only in the `.ready`
    /// phase with at least one item. That disables them after sync
    /// completes (you must rescan to act again), during sync (the
    /// OCaml worker is busy), and when there's nothing to act on
    /// (empty / up-to-date). Read-only actions (Select Conflicts)
    /// bypass the gate and validate on their own data.
    ///
    /// AppKit only calls this on the main thread (menu validation runs
    /// as the menu is about to open). The class is `@MainActor` so we
    /// let the Swift-6 isolation match the runtime guarantee.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(ignoreMenuAction(_:)) {
            guard isActionable else { return false }
            return rowForPendingMenuAction() != nil
        }
        if menuItem.action == #selector(diffMenuAction(_:)) {
            guard isActionable else { return false }
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
            // Read-only selection helper — allowed in any phase
            // (including .syncing and .done) as long as there are
            // unresolved conflicts present. Useful for surveying
            // remaining conflicts after a partial sync.
            return !RowSelectionRules.unresolvedConflictRows(
                items: items, rowOverrides: rowOverrides
            ).isEmpty
        }
        if menuItem.action == #selector(revertSelectionAction(_:)) {
            guard isActionable else { return false }
            // Only useful if at least one selected row carries an
            // override. Otherwise the action is a no-op.
            let rows = leafRowsInSelection()
            return rows.contains { rowOverrides[$0] != nil }
        }
        if menuItem.action == #selector(directionMenuAction(_:)) {
            guard isActionable else { return false }
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
        if menuItem.action == #selector(goMenuAction(_:)) {
            // Go is the "run sync" primary — same gate as
            // direction-change actions: must be in .ready with items.
            return isActionable
        }
        if menuItem.action == #selector(stopMenuAction(_:)) {
            // Stop only meaningful mid-sync.
            if case .syncing = phase { return true }
            return false
        }
        if menuItem.action == #selector(rescanMenuAction(_:)) {
            // Rescan is the way out of .done back to .ready — we
            // explicitly want it enabled post-sync. Only blocked
            // during an active sync (OCaml runtime is occupied).
            if case .syncing = phase { return false }
            return true
        }
        return true
    }

    // MARK: - Workflow menu dispatch (Go / Stop / Rescan)
    //
    // These are the responder-chain targets for the Action menu's
    // top-of-menu workflow items. They just forward to the existing
    // toolbar-action methods so the menu and toolbar paths share
    // behavior. The toolbar items (in ReconcileToolbarDelegate) call
    // the same `startSync` / `cancelSync` / `rescan` methods directly.

    @objc func goMenuAction(_ sender: Any?) {
        startSync()
    }

    @objc func stopMenuAction(_ sender: Any?) {
        cancelSync()
    }

    @objc func rescanMenuAction(_ sender: Any?) {
        rescan()
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
    /// Trigger an immediate revalidation of every visible toolbar
    /// item. The actual gating logic lives in
    /// `canPerformToolbarAction(_:)` and is invoked via the toolbar's
    /// `NSToolbarItemValidation` path
    /// (`ReconcileToolbarDelegate.validateToolbarItem`).
    ///
    /// Why this exists: NSToolbar's auto-validation loop only fires
    /// periodically (and on window-key changes). On a phase
    /// transition we want the visual state to update *now*, not on
    /// the next tick — so we explicitly ask the toolbar to
    /// revalidate. The validation call ends up at
    /// `canPerformToolbarAction` for each item, which reads `phase`
    /// + selection state and returns the correct `isEnabled` value.
    private func refreshToolbarEnabled() {
        window?.toolbar?.validateVisibleItems()
    }

    /// Single source of truth for whether a given toolbar item should
    /// be enabled. Called by `ReconcileToolbarDelegate.validateToolbarItem`
    /// during AppKit's auto-validation cycle. The same lifecycle
    /// gates as `validateMenuItem(_:)`; both paths share the
    /// `isActionable` helper so they can't drift.
    func canPerformToolbarAction(_ identifier: NSToolbarItem.Identifier) -> Bool {
        let syncing: Bool = {
            if case .syncing = phase { return true }
            return false
        }()
        switch identifier {
        case DirectionAction.goIdentifier:
            // Go: same gate as direction overrides. Disabled during
            // sync, after sync completes, and when items is empty.
            return isActionable
        case DirectionAction.stopIdentifier:
            // Stop only meaningful while a sync is in flight.
            return syncing
        case DirectionAction.rescanIdentifier:
            // Rescan is the way out of `.done` back to `.ready` —
            // explicitly available after completion. Only blocked
            // while OCaml is actively running a sync.
            return !syncing
        case DirectionAction.profilesIdentifier:
            // Always navigable back to the picker.
            return true
        case DirectionAction.directionGroupIdentifier:
            // The group container is enabled if any subitem would be
            // enabled — but AppKit also validates each subitem
            // individually, so this is mostly cosmetic. Match the
            // subitem rule for consistency.
            return isActionable && !leafRowsInSelection().isEmpty
        default:
            // Direction subitems (← First, → Second, Skip, Merge)
            // all use identifiers from DirectionAction.toolbarActions.
            // Gated like the group container: must be actionable AND
            // have leaf rows in the selection.
            if DirectionAction.toolbarActions
                .contains(where: { $0.toolbarIdentifier == identifier })
            {
                return isActionable && !leafRowsInSelection().isEmpty
            }
            // Unknown identifier (e.g. .flexibleSpace, .space) —
            // default to enabled; AppKit handles non-actionable
            // items naturally.
            return true
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

    private func summaryText() -> String {
        ReconcileSummary.text(items: items, phase: phase)
    }

    /// Computed gate for "state-changing actions" — the controller's
    /// answer to "is there anything the user can usefully do to the
    /// rows right now?"
    ///
    /// Returns `true` only when:
    ///  - we have rows to act on (items isn't empty), AND
    ///  - the phase is `.ready` (post-init2, pre-Go, fresh state).
    ///
    /// Specifically `false` when:
    ///  - phase is `.syncing` (mutations would race the OCaml worker),
    ///  - phase is `.done(…)` (the row set is post-sync — fixed state;
    ///    direction overrides, Go, Diff, Revert all need a rescan to
    ///    be useful again),
    ///  - items is empty ("Everything is up to date" — nothing to act on).
    ///
    /// Read-only actions (Select Conflicts, navigation) bypass this
    /// gate and validate on their own data.
    private var isActionable: Bool {
        guard !items.isEmpty else { return false }
        switch phase {
        case .ready:           return true
        case .syncing, .done:  return false
        }
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
        refreshToolbarEnabled()
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
