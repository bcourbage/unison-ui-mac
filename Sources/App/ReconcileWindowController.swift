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
    /// Invoked when the user presses "Return to Profiles" while a connect/scan
    /// (not a sync) is in flight. The owner (AppDelegate) abandons the
    /// presentation and returns to the picker; it does NOT cancel the scan,
    /// which continues in the background until its own terminal (the coordinator
    /// retains the engine lease and closes on that terminal).
    typealias CancelScanRequest = @MainActor () -> Void
    /// Owner veto for a window-close: returns true to ALLOW the close, false to
    /// intercept it. In-place scan interruption was withdrawn (issue #53 / #94),
    /// so the owner allows the close during a connect/scan and handles it via the
    /// leave path (abandon presentation, retain the scan lease).
    typealias WindowShouldCloseRequest = @MainActor () -> Bool
    /// The Profiles toolbar action, routed to the owner. Returns true if the
    /// owner HANDLED it, false → the controller falls back to `performClose` so a
    /// running sync still gets its three-way confirmation via `windowShouldClose`.
    /// Post-#94 the owner never "handles" it, so this always returns false.
    typealias ProfilesRequest = @MainActor () -> Bool
    /// Invoked when the user presses Go. The window never calls the sync
    /// bridge itself — it asks the engine coordinator (via AppDelegate) to
    /// authorize the sync. The coordinator answers with a `.beginSync`
    /// effect, whose driver calls `enterSyncingUI()` + the bridge. This
    /// keeps the coordinator the single authority over engine actions.
    typealias SyncStartRequest = @MainActor () -> Void
    /// Invoked when the user chooses how to leave a running sync (Stop /
    /// Abort & Close / Close & let it run). The window routes the choice
    /// through the coordinator, which owns the abort + connection-close
    /// decision — the window never calls `unison_bridge_abort_sync()`.
    typealias SyncExitRequest = @MainActor (EngineSessionCoordinator.SyncExitIntent) -> Void
    /// Invoked when a per-row mutation (direction / Ignore) fails AFTER OCaml
    /// state began changing (Blocker 4). The engine is no longer provably
    /// consistent with the displayed rows, so the window asks the coordinator to
    /// enter restart-required rather than leave the ready UI actionable.
    typealias EngineUncertainRequest = @MainActor (_ reason: String) -> Void
    /// Perform an Ignore for THIS session through the driver, which binds the
    /// dedicated ignore completion to the session before invoking the bridge and
    /// (on success) delivers the fresh rows back via `applyIgnoreResult`. Returns
    /// the bridge's structured result so the window can classify DIRTY failures.
    typealias IgnoreRequest = @MainActor (_ action: IgnoreAction, _ row: Int) -> unison_op_result_t
    /// Ask the app-global broker (via AppDelegate) to issue a diff for `row`,
    /// owned by this window's session. Returns whether it was issued, refused
    /// (one already outstanding / draining), or raised synchronously.
    typealias DiffRequest = @MainActor (_ row: Int) -> DiffRequestResult
    /// The diff window closed (or the session is leaving): drain this session's
    /// outstanding diff so a late result is discarded.
    typealias DiffAbandon = @MainActor () -> Void

    private var items: [StateItem]
    private var tree = ReconcileTree(items: [])
    /// O(1) row-index → leaf-node lookup (Finding #10), rebuilt atomically with
    /// `items`/`tree` in `replaceItems` and `beginScanning` so a stale mapping
    /// can never survive a scan/rescan/Ignore. Replaces the old O(n) walk over
    /// `tree.allNodes` on every per-row progress update (which was ~quadratic
    /// across a large sync).
    private var rowToNode: [Int: ReconcileNode] = [:]
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
    private let onCancelScan: CancelScanRequest
    private let onWindowShouldClose: WindowShouldCloseRequest
    private let onProfilesRequested: ProfilesRequest

    /// User pressed Go; see `SyncStartRequest`.
    private let onSyncStart: SyncStartRequest
    /// User chose how to leave a running sync; see `SyncExitRequest`.
    private let onSyncExit: SyncExitRequest
    /// A row mutation left the engine uncertain; see `EngineUncertainRequest`.
    private let onEngineUncertain: EngineUncertainRequest
    /// Perform an Ignore through the driver; see `IgnoreRequest`.
    private let onIgnore: IgnoreRequest
    /// Issue a diff through the app-global broker; see `DiffRequest`.
    private let onDiffRequest: DiffRequest
    /// Drain this session's outstanding diff; see `DiffAbandon`.
    private let onDiffAbandon: DiffAbandon
    /// True between a successful Ignore invocation and its dedicated completion
    /// landing (`applyIgnoreResult`). During this gap the published OCaml roots
    /// are the post-Ignore set but the displayed rows are still the pre-Ignore
    /// set, so row actions MUST be disabled — otherwise a click would address the
    /// wrong OCaml item. Gates row/sync/rescan actions like `isScanning`.
    private var mutationInFlight = false
    /// PR-4: set by the driver (`AppDelegate.driveBeginDiff` / diff completion)
    /// while THIS session's diff occupies the OCaml worker. Folds into `actionGate`
    /// so every engine-reaching action is refused at its method boundary — a
    /// bridge call on the main thread would block behind the wedged diff.
    private(set) var diffInFlight = false
    /// Terminal restart-required latch. Set by `showRestartRequired`; once
    /// set, all row/sync/rescan actions are disabled (the coordinator has
    /// declared the engine unsafe for reuse — the user must quit + reopen).
    private var restartRequired = false
    /// Finding #10: sync completed but its per-file results couldn't be shown
    /// (snapshot marshalling failure / count mismatch). Unlike `restartRequired`
    /// the engine is fine — so Rescan stays available — but the displayed rows
    /// are not trustworthy, so Sync and per-row actions are disabled until a
    /// Rescan refreshes state. Cleared when a rescan begins.
    private var syncResultsUnavailable = false
    /// True between `beginScanning` and `endRescan` — i.e. while the
    /// initial connect/scan (or a rescan) is in flight. Gates the Stop
    /// button, which during a connect/scan is "Return to Profiles": it
    /// abandons the presentation and returns to the picker (the scan winds
    /// down in the background; it is not cancelled). Distinct from `isSyncing`
    /// (a running file transfer).
    private(set) var isScanning = false
    private let outlineView = NSOutlineView()
    private let summaryLabel = NSTextField(labelWithString: "")
    /// Leading status glyph for the summary row. Hidden except after a
    /// sync completes, when `applyCompletionEmphasis` shows a green ✓
    /// (clean) or red ⚠ (errors) so the finish reads at a glance.
    private let statusIcon = NSImageView()
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

    /// Sync-phase no-progress detector (issues #6 / #34). Progress-callback
    /// silence is NOT proof of a wedged transport — a healthy transfer of many
    /// small files can be callback-sparse — so this detector is ADVISORY and
    /// NON-fatal (issue #34): on expiry it shows an informational notice
    /// (`SyncStallNotice`) and does NOT mutate coordinator/engine state or tell
    /// the user to abort. It clears on the next progress event and on any sync
    /// terminal. A real operation-bound liveness signal would need an engine
    /// heartbeat (vendored-blob change) and is tracked as a post-release
    /// follow-up. Reset on every progress event.
    private let syncStallTimeout: TimeInterval = 45
    private lazy var syncStall = SyncStallDetector(
        timeout: syncStallTimeout,
        onStall: { [weak self] in self?.showSyncStallNotice() },
        onResume: { [weak self] in self?.clearSyncStallNotice() })
    private let toolbarDelegate = ReconcileToolbarDelegate()
    private(set) var isSyncing = false
    /// True when the user pressed Stop during the current sync. Read at
    /// `finalizeSyncUI` so the terminal summary reads "Synchronization
    /// stopped" (orange) instead of "complete"/"completed with N errors".
    /// Reset at each `startSync`.
    private var userRequestedStop = false

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
         onRescanRequested: @escaping RescanRequest,
         onCancelScan: @escaping CancelScanRequest,
         onWindowShouldClose: @escaping WindowShouldCloseRequest = { true },
         onProfilesRequested: @escaping ProfilesRequest = { false },
         onSyncStart: @escaping SyncStartRequest,
         onSyncExit: @escaping SyncExitRequest,
         onEngineUncertain: @escaping EngineUncertainRequest,
         onIgnore: @escaping IgnoreRequest,
         onDiffRequest: @escaping DiffRequest,
         onDiffAbandon: @escaping DiffAbandon) {
        self.profile = profile
        self.items = []
        self.mergeConfigured = mergeConfigured
        self.onClose = onClose
        self.onRescanRequested = onRescanRequested
        self.onCancelScan = onCancelScan
        self.onWindowShouldClose = onWindowShouldClose
        self.onProfilesRequested = onProfilesRequested
        self.onSyncStart = onSyncStart
        self.onSyncExit = onSyncExit
        self.onEngineUncertain = onEngineUncertain
        self.onIgnore = onIgnore
        self.onDiffRequest = onDiffRequest
        self.onDiffAbandon = onDiffAbandon
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
            // The owner's veto hook. In-place scan interruption was withdrawn
            // (issue #53 / #94), so this always allows the close during a
            // connect/scan; the close then routes through the owner's leave path
            // (abandon presentation, retain the scan lease). false here → do not
            // close.
            if !onWindowShouldClose() { return false }
            guard isSyncing else { return true }
            let alert = NSAlert()
            alert.messageText = "Synchronization is still running"
            alert.informativeText =
                "Choose how to close this window:\n\n" +
                "• Abort & Close: stop the sync and close. Already-in-progress " +
                "transfers may complete before the abort takes effect; queued " +
                "rows will fail.\n" +
                "• Close (let it run): close the window but let the sync " +
                "continue in the background until it finishes naturally.\n" +
                "• Keep Syncing: don't close. You can hit Stop in the toolbar " +
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
                // Abort & Close — the coordinator aborts the transport and
                // closes the connection once the sync unwinds. We never call
                // unison_bridge_abort_sync() directly.
                Log.reconcile.notice("user closed mid-sync with Abort & Close")
                userRequestedStop = true
                onSyncExit(.abortAndClose)
                return true
            case .alertThirdButtonReturn:
                // Close (let it run) — no abort; the coordinator closes the
                // connection after the sync finishes naturally.
                Log.reconcile.notice("user closed mid-sync without aborting")
                onSyncExit(.closeAndLetRun)
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
        // Any fresh publication (scan or ignore) means rows now match roots, so
        // the mutation gate no longer applies.
        mutationInFlight = false
        outlineView.isEnabled = true
        items = newItems
        let layout = SettingsModel.reconcileLayoutMode()
        let policy = SettingsModel.reconcileExpandPolicy()
        tree = ReconcileTree(items: newItems, layout: layout)
        rebuildRowIndex()
        // Fresh, valid row set ⇒ any prior "results unavailable" state is cleared.
        syncResultsUnavailable = false
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
        statusIcon.isHidden = true
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let summaryRow = NSStackView(views: [statusIcon, summaryLabel, statusDetailsButton])
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

        // Bridge callbacks are NOT installed here anymore. AppDelegate owns
        // the single set of permanent, token-bound handlers (installed once
        // at launch) and forwards presentation into the live session's
        // window via `reloadRow` / `updateGlobalProgress` / `finalizeSyncUI`
        // / `showDiff` / `showDiffError`. Per-window installation was the old
        // dual-authority pattern: the most-recently-opened window silently
        // stole the callbacks from any still-live session.
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
        // v6 bump: added the Quit toolbar item. Bumping resets the
        // autosaved layout so existing users actually get the new button.
        let toolbar = NSToolbar(identifier: "ReconcileToolbar.v6")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: - Sync

    /// Go button / Action-menu Go. Does NOT touch the sync bridge — asks the
    /// engine coordinator (via AppDelegate) to authorize the sync. The
    /// coordinator answers with a `.beginSync` effect, whose driver calls
    /// `enterSyncingUI()` and `unison_bridge_synchronize()`. Keeping the
    /// bridge call out of the window is what makes the coordinator the sole
    /// authority over engine actions.
    func startSync() {
        // Method-boundary gate (not just toolbar/menu validation): never start a
        // sync during an Ignore publication gap or a restart.
        guard actionGate.allows(.sync) else { NSSound.beep(); return }
        onSyncStart()
    }

    /// Enter the syncing UI. Called by the coordinator's `.beginSync` driver
    /// (AppDelegate) once the sync is authorized — never directly by the Go
    /// button. Sets up the progress bar + summary and arms the stall
    /// detector; the driver issues the bridge call alongside this.
    func enterSyncingUI() {
        guard !isSyncing else { return }
        isSyncing = true
        userRequestedStop = false   // fresh run
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
        TraceLog.shared.write("ReconcileWindow: entering syncing UI")
        syncStall.start()   // arm the advisory no-progress detector for the transfer
    }

    /// Toolbar "Profiles" action — return to the picker. Routed to the owner,
    /// which does not "handle" it (in-place scan interruption was withdrawn,
    /// issue #53 / #94), so we fall back to `performClose(nil)`, which routes
    /// through `windowShouldClose` — this is what preserves the three-way
    /// confirmation when a sync is running (round 3 correction 1). During a
    /// connect/scan the close then abandons the presentation (the scan winds
    /// down in the background).
    func returnToPicker() {
        if !onProfilesRequested() {
            window?.performClose(nil)
        }
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
    /// unwinds. `finalizeSyncUI` fires once OCaml has fully wound
    /// down and resets the UI to "done" state.
    func cancelSync() {
        // Stop during the connect/scan phase (pre-sync): hand off to the owner,
        // which abandons the presentation and returns to the picker. It does NOT
        // cancel the scan (that continues in the background until its own
        // terminal); it lets the user leave a slow/wedged connect without
        // waiting for the watchdog timeout.
        if isScanning && !isSyncing {
            // The connect/scan-phase Stop item is the honest "Return to
            // Profiles": it abandons the connect/scan and returns to the picker
            // (no sync to abort; the scan winds down in the background). In-place
            // scan interruption was withdrawn (issue #53 / #94). See
            // StopItemAppearance.
            Log.reconcile.notice("user requested Return to Profiles during connect/scan")
            TraceLog.shared.write("ReconcileWindow: Return to Profiles during connect/scan")
            setSummary(StopItemAppearance.returnToProfiles.progressSummary)
            onCancelScan()
            return
        }
        guard isSyncing else { NSSound.beep(); return }
        userRequestedStop = true   // finalizeSyncUI reads this for the "stopped" summary
        Log.reconcile.notice("user requested Stop — routing abort through the coordinator")
        TraceLog.shared.write("ReconcileWindow: user requested Stop — coordinator abort (keep window)")
        setSummary("Aborting sync… in-progress transfers may finish before the abort takes effect")
        // The coordinator owns the abort. It emits `.abortSync`, whose
        // driver calls the bridge. We never call unison_bridge_abort_sync().
        onSyncExit(.stopAndKeepWindow)
        // Don't close the window. finalizeSyncUI will fire once the
        // OCaml side has fully unwound, at which point the user can
        // close manually OR rescan.
    }

    // MARK: - Scanning (initial or rescan)

    func rescan() {
        // Method-boundary gate: reject during an Ignore publication gap (as well
        // as during a sync or a restart).
        guard actionGate.allows(.rescan) else { NSSound.beep(); return }
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
        rebuildRowIndex()
        syncResultsUnavailable = false
        rowOverrides.removeAll()
        outlineView.reloadData()
        detailsTextView.string = "Select a row to see details."

        isScanning = true
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
        isScanning = false
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.isHidden = true
        replaceItems(newItems)
        refreshToolbarEnabled()
    }

    // MARK: - Details panel

    private func configureDetailsPanel() {
        // Canonical NSTextView-in-NSScrollView geometry (see
        // ScrollableTextView). Without it this footer rendered BLANK in
        // the CI-built release (SDK 15.5) — the string was in the model
        // but never drawn. Wrap mode: details scroll vertically.
        ScrollableTextView.configure(text: detailsTextView, scroll: detailsScroll,
                                     mode: .wrap,
                                     initialSize: NSSize(width: 400, height: 80))

        detailsTextView.isEditable = false
        detailsTextView.isSelectable = true
        detailsTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailsTextView.textContainerInset = NSSize(width: 6, height: 6)
        detailsTextView.drawsBackground = true
        detailsTextView.backgroundColor = .textBackgroundColor
        detailsTextView.string = "Select a row to see details."
        detailsTextView.textColor = .secondaryLabelColor

        detailsScroll.borderType = .lineBorder
        detailsScroll.autohidesScrollers = true
    }

    private func updateDetailsForSelection() {
        // During an Ignore publication gap the displayed row indices are stale
        // against the newly-published OCaml roots, so ri_get_details(row) would
        // read the wrong item. Show a placeholder and DO NOT touch the bridge;
        // the details refresh again when the fresh rows land.
        guard actionGate.allows(.details) else {
            detailsTextView.string = "Applying ignore…"
            detailsTextView.textColor = .secondaryLabelColor
            return
        }
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
        clearCompletionEmphasis()
    }

    /// Reset the summary line to its neutral styling — hides the status
    /// glyph and drops the bold/colored completion treatment. Called from
    /// `setSummary` so any non-completion write (rescan, start-sync,
    /// abort, status line) automatically sheds a prior sync's green/red
    /// emphasis. Mirrors the initial styling set in `configure`.
    private func clearCompletionEmphasis() {
        statusIcon.isHidden = true
        statusIcon.image = nil
        summaryLabel.textColor = .labelColor
        summaryLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .medium)
    }

    /// Apply the green-✓ / red-⚠ completion treatment: leading glyph,
    /// tinted bold summary text. Called from `finalizeSyncUI` after the
    /// summary text is set. The next `setSummary` (e.g. a rescan) clears
    /// it via `clearCompletionEmphasis`.
    private func applyCompletionEmphasis(failures: Int, stopped: Bool = false,
                                         resultsUnavailable: Bool = false) {
        let emphasis = ReconcileSummary.completionEmphasis(
            failures: failures, stopped: stopped, resultsUnavailable: resultsUnavailable)
        let config = NSImage.SymbolConfiguration(
            pointSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
            .applying(.init(paletteColors: [emphasis.tint]))
        statusIcon.image = NSImage(systemSymbolName: emphasis.symbolName,
                                   accessibilityDescription: emphasis.accessibilityLabel)?
            .withSymbolConfiguration(config)
        statusIcon.isHidden = false
        summaryLabel.textColor = emphasis.tint
        summaryLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .bold)
    }

    @objc private func showStatusDetails(_ sender: Any?) {
        guard let text = lastMultiLineStatus, !text.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Status details"
        // NSAlert truncates `informativeText` aggressively for long
        // strings — use an accessoryView with a scrolling text view so
        // multi-screen SSH error dumps stay readable + selectable. Wrap
        // mode (vertical scroll) via the canonical geometry — without it
        // a long dump clips with a dead scroller. See ScrollableTextView.
        let (scroll, textView) = ScrollableTextView.make(
            mode: .wrap, initialSize: NSSize(width: 520, height: 240))
        scroll.borderType = .lineBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Forwarded by AppDelegate's permanent progress handler for the live
    /// session. Non-private: the window no longer installs its own handler.
    func updateGlobalProgress(_ percent: Double) {
        guard isSyncing else { return }
        progressBar.doubleValue = max(0, min(100, percent))
        noteSyncProgress()
    }

    /// Forward a progress event to the advisory detector. Called at sync start
    /// and on every progress event; the detector clears a shown notice on resume
    /// and re-arms.
    private func noteSyncProgress() {
        guard isSyncing else { return }
        syncStall.noteProgress()
    }

    private func cancelSyncStallDetector() {
        syncStall.stop()
    }

    /// No sync progress observed for `syncStallTimeout` (issue #34). This is
    /// ADVISORY and NON-fatal: callback silence is not evidence the transport is
    /// wedged (a healthy many-small-file transfer can be callback-sparse). We do
    /// NOT mutate coordinator/engine state and do NOT tell the user to abort —
    /// just surface an informational notice that progress hasn't been observed
    /// and the transfer may still be running. It clears on the next progress
    /// event (`clearSyncStallNotice`) and on completion (`cancelSyncStallDetector`).
    private func showSyncStallNotice() {
        guard isSyncing else { return }
        Log.reconcile.notice("sync: no progress observed for \(Int(self.syncStallTimeout))s — advisory notice (nonfatal; transfer may still be running)")
        // setSummary() clears completion emphasis (hides + nils statusIcon), so
        // it MUST run before we install the attention icon — otherwise the icon
        // is set and then immediately cleared.
        setSummary(SyncStallNotice.message(seconds: Int(syncStallTimeout)))
        let config = NSImage.SymbolConfiguration(
            pointSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
            .applying(.init(paletteColors: [.systemOrange]))
        statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "no progress observed")?
            .withSymbolConfiguration(config)
        statusIcon.isHidden = false
    }

    /// Progress resumed after an advisory notice — clear it.
    private func clearSyncStallNotice() {
        statusIcon.isHidden = true
        setSummary(summaryText())
    }

    /// Forwarded by AppDelegate's permanent reload-row handler for the live
    /// session. Non-private: the window no longer installs its own handler.
    func reloadRow(_ row: Int, progress: String, bytesTransferred: Int64) {
        guard row >= 0, row < items.count else { return }
        let old = items[row]
        let new = old.with(progress: progress, bytesTransferred: bytesTransferred)
        items[row] = new
        // Advance the folder aggregate caches incrementally: apply just this
        // row's delta up its ancestor chain (O(depth)) instead of re-walking
        // every ancestor's subtree on every progress tick (which was O(N²) for a
        // folder of N transferring files). Only the dynamic parts change — a
        // row's size is fixed, so `aggTotalSize` (the Size column) is untouched.
        if let node = leafNode(forRow: row) {
            let a = ReconcileTree.contribution(of: old)
            let b = ReconcileTree.contribution(of: new)
            node.applyProgressDelta(doneSize: b.doneSize - a.doneSize,
                                    terminal: b.terminal - a.terminal,
                                    started: b.started - a.started)
            // Reload ONLY the Progress column for the leaf + every ancestor —
            // the only thing that changed. This avoids re-rendering their
            // (unchanged, O(subtree)) direction/size cells on every progress
            // tick, and with the O(1) cached fraction keeps a tick O(depth).
            var chain: [ReconcileNode] = [node]
            var ancestor = node.parent
            while let n = ancestor, !n.name.isEmpty { chain.append(n); ancestor = n.parent }
            reloadProgressColumn(for: chain)
        }
        TraceLog.shared.write("reloadRow[\(row)] \(new.path): progress='\(progress)' bytes=\(bytesTransferred)")
        noteSyncProgress()
    }

    /// Reload only the Progress column for the given nodes' currently-visible
    /// rows. Used during sync so a folder's aggregate bar advances without
    /// re-rendering its unchanged (and O(subtree)) direction/size cells.
    private func reloadProgressColumn(for nodes: [ReconcileNode]) {
        let progressCol = outlineView.column(withIdentifier: Col.progress.identifier)
        guard progressCol >= 0 else { return }
        var rows = IndexSet()
        for n in nodes {
            let r = outlineView.row(forItem: n)   // -1 when hidden (collapsed)
            if r >= 0 { rows.insert(r) }
        }
        guard !rows.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rows,
                               columnIndexes: IndexSet(integer: progressCol))
    }

    /// O(1) lookup of the leaf for a row via the `rowToNode` index, which is
    /// rebuilt synchronously alongside `items`/`tree` (see `buildRowIndex`), so
    /// it can never lag the current row set. Replaces the former O(items) walk
    /// over the tree (Finding #10).
    private func leafNode(forRow row: Int) -> ReconcileNode? {
        rowToNode[row]
    }

    /// Rebuild the O(1) row→leaf-node index from the current `tree`. MUST be
    /// called in the same synchronous block that assigns `items`/`tree` (see
    /// `replaceItems`, `beginScanning`) so the index is always consistent with
    /// the published rows — a stale mapping could reload the wrong row.
    private func rebuildRowIndex() {
        rowToNode = Self.buildRowIndex(tree.allNodes)
    }

    /// Pure row→leaf-node index builder (testable). First occurrence of a given
    /// row wins, matching the old `allNodes` walk order.
    nonisolated static func buildRowIndex(_ nodes: [ReconcileNode]) -> [Int: ReconcileNode] {
        var index: [Int: ReconcileNode] = [:]
        for node in nodes {
            guard let r = node.row else { continue }
            if index[r] == nil { index[r] = node }
        }
        return index
    }

    /// Terminal sync-UI presentation. Called by the coordinator's
    /// `.presentSyncResults` effect (via AppDelegate), never by a bridge
    /// handler the window installed. The connection-close policy is the
    /// coordinator's now, so this method no longer signals an owner: it
    /// only paints the completed/failed/stopped state.
    func finalizeSyncUI(snapshot: [SyncSnapshotRow]) {
        isSyncing = false
        cancelSyncStallDetector()
        progressBar.doubleValue = 100
        progressBar.isHidden = true

        // Finding #10: apply the ONE bulk post-sync snapshot to the cached row
        // model — the completion path makes ZERO per-row bridge calls. The
        // snapshot carries each row's final progress + details; the SAME
        // details-based failure synthesis (a row whose progress isn't FAILED but
        // whose details carry a failure marker → "FAILED: <reason>") runs on
        // that cached data, so transfer failures and partial/problematic rows
        // are attributed identically to before. A row-count mismatch cannot be
        // applied partially, so it routes to the unavailable-results path (the
        // engine is quiescent + archive committed — NOT restartRequired).
        let applied: SyncCompletionModel.Applied
        switch SyncCompletionModel.apply(snapshot: snapshot, to: items) {
        case .countMismatch(let expected, let got):
            TraceLog.shared.write(
                "ReconcileWindow: sync snapshot count mismatch "
                + "(expected \(expected), got \(got)) — results unavailable")
            finalizeSyncUnavailable(reason: "per-file results didn't match the file list")
            return
        case .applied(let a):
            applied = a
        }
        items = applied.items
        outlineView.reloadData()
        let failedRowSet = applied.failedRows
        let failures = failedRowSet.count
        phase = .done(failures: failures)
        // If the user pressed Stop, the run ended on an abort — report it as
        // "stopped" (orange), not "complete"/"errors", so the Stop is
        // acknowledged even when in-flight transfers happened to finish first.
        let summary = ReconcileSummary.text(items: items, phase: phase,
                                            stopped: userRequestedStop)
        setSummary(summary)
        applyCompletionEmphasis(failures: failures, stopped: userRequestedStop)
        refreshToolbarEnabled()

        // Opt-out audible + Notification Center cues (Settings-gated;
        // both default ON). The inline green ✓ / red ⚠ above is always
        // on. Surfaced here, once, at the single sync-complete chokepoint.
        SyncCompletionAnnouncer.announce(summary: summary, failures: failures)

        // If anything failed, force-expand the ancestor chain of every
        // FAILED row — even when the user's configured ExpandPolicy is
        // `.smart` or `.rootOnly` and those rows would otherwise be
        // buried under collapsed folders. The user picked their policy
        // to focus pre-sync triage; post-sync triage is a different
        // task with different visibility needs. This is additive on
        // top of whatever the policy already expanded — the user's
        // setting isn't mutated, and the next rescan rebuilds the
        // tree (so the widening doesn't persist beyond this
        // sync-complete view).
        if !failedRowSet.isEmpty {
            let toReveal = tree.nodesToRevealRows(failedRowSet)
            for node in toReveal {
                outlineView.expandItem(node, expandChildren: false)
            }
            if !toReveal.isEmpty {
                TraceLog.shared.write(
                    "ReconcileWindow: revealed \(toReveal.count) folder(s) " +
                    "containing FAILED row(s)")
            }
        }

        TraceLog.shared.write("ReconcileWindow: sync complete (failures: \(failures))")
        // No owner callback here: the connection-close policy (close now for
        // non-interactive profiles, hold for interactive) lives in the
        // coordinator's `syncCompleted` reducer, which already emitted the
        // matching `.closeConnection` effect (if any) before this present.
    }

    /// Finding #10: sync finished and the archive was committed, but the engine
    /// could not produce the per-file results (a snapshot marshalling failure)
    /// or they didn't match the row set. The engine is QUIESCENT — this is a
    /// read-only-results failure, NOT engine contamination, so it does NOT go
    /// through `restartRequired`. Show a clear terminal message, never present
    /// ordinary success, never apply a partial snapshot, and leave only safe
    /// recovery/navigation actions live (Rescan, Profiles, Quit).
    func finalizeSyncUnavailable(reason: String) {
        isSyncing = false
        cancelSyncStallDetector()
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.isHidden = true
        syncResultsUnavailable = true
        phase = .done(failures: 0)
        setSummary("Synchronization finished, but its per-file results could not "
                   + "be displayed. Rescan before synchronizing again.")
        applyCompletionEmphasis(failures: 0, stopped: false, resultsUnavailable: true)
        refreshToolbarEnabled()
        TraceLog.shared.write("ReconcileWindow: sync results unavailable — \(reason)")
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

    /// Terminal restart-required presentation. Called by the coordinator's
    /// `.restartRequired` effect (via AppDelegate) when the engine can't be
    /// proven safe for reuse (a wedged connect, an uncertain timeout, or a
    /// display-only fatal). Freezes the window: the sync/scan spinners stop,
    /// row/sync/rescan actions are disabled (`restartRequired` latch), and
    /// the summary tells the user the one recovery — quit and reopen. Only
    /// navigation (Profiles / Quit) stays live.
    func showRestartRequired(reason: String) {
        restartRequired = true
        isSyncing = false
        isScanning = false
        cancelSyncStallDetector()
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.isHidden = true
        setSummary("Unison must be restarted to continue. Quit Unison and "
                   + "reopen the profile. (\(reason))")
        let config = NSImage.SymbolConfiguration(
            pointSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
            .applying(.init(paletteColors: [.systemOrange]))
        statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "restart required")?
            .withSymbolConfiguration(config)
        statusIcon.isHidden = false
        refreshToolbarEnabled()
        TraceLog.shared.write("ReconcileWindow: restart required (\(reason))")
    }

    /// Diff-result presentation. AppDelegate calls this ONLY after the
    /// app-global `DiffRequestBroker` has confirmed the result belongs to this
    /// session (the owner of the single outstanding request); a stale/late
    /// result from an abandoned or replaced session is dropped by the broker
    /// before it ever reaches here, so this method just displays.
    func showDiff(title: String, text: String) {
        diffWindowController?.showDiff(title: title, text: text)
    }

    /// Diff-error presentation. Same broker-gated contract as `showDiff`.
    func showDiffError(_ message: String) {
        diffWindowController?.showError(message)
    }

    // MARK: - Direction overrides

    /// Applied to every leaf row in the current selection — including
    /// leaves *underneath* selected folders. Single click on a folder thus
    /// becomes "apply this action to every file in that folder".
    func applyDirection(_ action: DirectionAction) {
        guard actionGate.allows(.direction) else { NSSound.beep(); return }
        let rows = leafRowsInSelection()
        guard !rows.isEmpty else { NSSound.beep(); return }
        var changedRows: [Int] = []
        for row in rows {
            guard row < items.count else { continue }
            let (result, dir, changed) = action.invoke(row: Int32(row))
            if result == UNISON_OP_FAILED_DIRTY {
                // Blocker 4: the setter mutated (or may have mutated) this row's
                // OCaml state before failing. The engine no longer provably
                // matches the displayed rows, so stop the batch and hand the
                // engine to the coordinator for restart-required rather than
                // leave a stale-but-actionable table. Any rows already changed
                // this batch are moot — the window is about to freeze.
                TraceLog.shared.write("ri-set DIRTY on row \(row) (\(action)) — engine uncertain")
                onEngineUncertain("direction override failed after mutating a row")
                return
            }
            guard result == UNISON_OP_OK else {
                // INVALID (bad row / missing callback) or FAILED_CLEAN (raised
                // before any mutation) — nothing changed; skip this row.
                TraceLog.shared.write("ri-set skipped row \(row) (\(action), result \(result.rawValue))")
                continue
            }
            items[row] = items[row].with(direction: dir, changedFromDefault: changed)
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
        // A CONTEXT-menu invocation operates on the freshly right-clicked row; an
        // Edit-menu (menu-bar) invocation operates on the current selection and must
        // ignore the now-stale `clickedRow` (SF2).
        let row = rowForPendingMenuAction(preferClicked: isContextMenuItem(sender))
        applyIgnore(action, row: row)
    }

    /// True iff `item` belongs to the outline view's RIGHT-CLICK context menu
    /// (whose items were captured against a fresh `clickedRow`) rather than a
    /// menu-bar menu. `outlineView.clickedRow` persists after a context menu
    /// dismisses, so a later menu-bar Ignore/Diff must NOT honor it — it would
    /// target a stale (or, after a rescan, a different) row (SF2).
    private func isContextMenuItem(_ item: NSMenuItem?) -> Bool {
        item?.menu === outlineView.menu
    }

    /// Resolves which leaf row a menu action targets. Only a CONTEXT-menu
    /// invocation (`preferClicked`) honors the right-clicked row; every other
    /// entry point (Edit menu, menu bar) uses the current selection, so a stale
    /// `clickedRow` can't be targeted. Returns nil when neither resolves to a leaf.
    private func rowForPendingMenuAction(preferClicked: Bool) -> Int? {
        if preferClicked, let node = clickedNode(), let row = node.row {
            return row
        }
        return leafRowsInSelection().first
    }

    /// Stricter row resolver for Diff (delegates to `RowSelectionRules.diffTarget`
    /// so the rule is unit-tested). Diff is single-leaf only. Only a CONTEXT-menu
    /// invocation honors the right-clicked row (SF2); otherwise the target is the
    /// selection alone — matching the toolbar Diff, which already ignores `clickedRow`.
    private func rowForDiff(preferClicked: Bool) -> Int? {
        RowSelectionRules.diffTarget(
            rightClickedNode: preferClicked ? clickedNode() : nil,
            selectedNodes: selectedNodes()
        )
    }

    /// Apply one of the three Ignore actions to a specific leaf row. The bridge
    /// call recomputes OCaml's `theState` and installs the new per-row roots,
    /// then delivers the post-filter rows through the DEDICATED asynchronous
    /// Ignore completion (bound by the driver to this session) — NOT the
    /// init2/scan handler. `applyIgnoreResult(_:)` repopulates the table when
    /// that completion lands.
    func applyIgnore(_ action: IgnoreAction, row: Int?) {
        guard actionGate.allows(.ignore) else { NSSound.beep(); return }
        guard let row, row >= 0, row < items.count else { NSSound.beep(); return }
        let path = items[row].path
        TraceLog.shared.write("ReconcileWindow: \(action.label) on row \(row) (\(path))")
        // Route through the driver: it binds the dedicated ignore completion to
        // THIS session before invoking the bridge, so the fresh rows come back to
        // this exact window via `applyIgnoreResult`.
        let result = onIgnore(action, row)
        if result == UNISON_OP_OK {
            // The Ignore mutated theState and installed new OCaml roots, but the
            // fresh rows arrive on the (async) dedicated completion. Until they
            // land, the displayed rows are stale against the new roots — set the
            // mutation gate (blocks every engine-reaching action via
            // `actionGate`) and disable the outline view for presentation
            // clarity. `applyIgnoreResult` lifts both.
            mutationInFlight = true
            outlineView.isEnabled = false
            setSummary("Applying ignore…")
            updateDetailsForSelection()   // show the placeholder immediately
            refreshToolbarEnabled()
        } else if result == UNISON_OP_FAILED_DIRTY {
            // Blocker 4: the ignore pattern was persisted / theState rewritten,
            // but the post-filter rows couldn't be published — the table now
            // lies about the engine. Route to restart-required.
            TraceLog.shared.write("  \(action.label) DIRTY — engine uncertain")
            onEngineUncertain("ignore failed after mutating engine state")
        } else {
            // INVALID / FAILED_CLEAN — nothing changed; narrow no-op.
            TraceLog.shared.write("  \(action.label) no-op (result \(result.rawValue))")
            NSSound.beep()
        }
    }

    /// Deliver a successful Ignore's fresh rows to THIS session (called by the
    /// driver's dedicated ignore completion, bound to this window's session).
    /// Replaces the displayed rows to match the already-installed OCaml roots and
    /// lifts the mutation gate — the atomic "rows now match roots" point.
    func applyIgnoreResult(_ newItems: [StateItem]) {
        mutationInFlight = false
        outlineView.isEnabled = true
        replaceItems(newItems)
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

    /// Open the diff window for the right-clicked / first-selected leaf row. The
    /// diff runs SYNCHRONOUSLY inside the single OCaml worker, but the driver runs
    /// that bridge call OFF the main thread on the serial engine lane (PR-4), so it
    /// doesn't block the UI; the result (or an error) arrives via the diff handlers
    /// installed in `configure`.
    @objc private func diffMenuAction(_ sender: Any?) {
        applyDiff(preferClicked: isContextMenuItem(sender as? NSMenuItem))
    }

    /// Diff entry point for the toolbar button. Resolves the target
    /// strictly from the *selection* (passing `rightClickedNode: nil`)
    /// rather than through `rowForDiff()`, whose `outlineView.clickedRow`
    /// lookup can return a stale row left over from an earlier
    /// context-menu invocation — a toolbar click doesn't update
    /// clickedRow. This matches `canDiffCurrentSelection()`, the same
    /// predicate that enables/disables the toolbar item.
    func diffSelectedRow() {
        guard let row = RowSelectionRules.diffTarget(
            rightClickedNode: nil, selectedNodes: selectedNodes()),
              row >= 0, row < items.count else { NSSound.beep(); return }
        performDiff(row: row)
    }

    /// Menu-driven Diff. `preferClicked` is true only for the right-click context
    /// menu; menu-bar/Edit invocations use the selection alone (SF2). Returns
    /// silently when the action isn't applicable (`validateMenuItem` greys it).
    func applyDiff(preferClicked: Bool) {
        guard let row = rowForDiff(preferClicked: preferClicked),
              row >= 0, row < items.count else { NSSound.beep(); return }
        performDiff(row: row)
    }

    /// Shared Diff core for both entry points (menu/context via
    /// `applyDiff(preferClicked:)`, toolbar button via `diffSelectedRow()`). Runs the
    /// sync-in-flight + defensive `canDiff` re-checks, surfaces the
    /// loading window, and kicks off the async OCaml diff. `row` is
    /// assumed in-bounds.
    private func performDiff(row: Int) {
        // Method-boundary gate: reject BEFORE any canDiff / run_show_diffs bridge
        // call while an Ignore publication is pending (the row index would
        // address the wrong OCaml root) or a restart is required.
        guard actionGate.allows(.diff) else { NSSound.beep(); return }
        let path = items[row].path
        // Issue through the coordinator (engine ownership) + app-global broker
        // (result routing) via AppDelegate. Both the `canDiff` precondition and the
        // diff itself now run OFF the main thread (PR-4), so a slow/wedged remote
        // transfer can't beachball the app. A refusal means the engine is busy with
        // another operation, or an abandoned diff is still draining.
        let outcome = onDiffRequest(row)
        switch outcome {
        case .refused:
            NSSound.beep()
            TraceLog.shared.write("ReconcileWindow: diff refused (engine busy/draining) for row \(row)")
            return
        case .issued:
            break
        }

        // Lazily create the diff window — most reconcile sessions never need
        // one. Closing it drains this session's outstanding diff so a late
        // result is dropped and can't be misattributed to a later request.
        if diffWindowController == nil {
            diffWindowController = DiffWindowController()
            diffWindowController?.onClose = { [weak self] in
                self?.onDiffAbandon()
            }
        }
        diffWindowController?.surfaceForLoading(path: path)
        TraceLog.shared.write("ReconcileWindow: diff requested for row \(row) (\(path))")
        // The result arrives via AppDelegate's diff handler (routed to this window
        // by the broker) → showDiff; or the async completion → showDiffError
        // (raised, not diffable, or wedged).
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
        // The outline operations are injectable so this whole path is testable
        // without a real (headless-unreliable) outline view.
        let ops = outlineOps
        // SF14: reveal any conflict rows buried under COLLAPSED folders BEFORE
        // mapping. Without this, `row(forItem:)` returns -1 for a hidden node and
        // the conflict is silently dropped — and if EVERY conflict is hidden, the
        // selection below would clear the user's existing selection for nothing.
        for node in tree.nodesToRevealRows(conflictRows) {
            ops.expand(node)
        }
        // Map row indices → outline-view row indices via the leaf nodes.
        var outlineRowsToSelect = IndexSet()
        for node in tree.allNodes where node.row != nil {
            guard let row = node.row, conflictRows.contains(row) else { continue }
            let outlineRow = ops.outlineRow(node)
            if outlineRow >= 0 { outlineRowsToSelect.insert(outlineRow) }
        }
        // Belt-and-suspenders: after revealing, every conflict maps to a real row.
        // If (defensively) none did, don't wipe the existing selection.
        guard !outlineRowsToSelect.isEmpty else { NSSound.beep(); return }
        ops.select(outlineRowsToSelect)
        if let first = outlineRowsToSelect.first {
            ops.scrollToVisible(first)
        }
        TraceLog.shared.write(
            "ReconcileWindow: Select Conflicts → \(conflictRows.count) row(s)"
        )
    }

    /// Clear user overrides on every leaf row in the current
    /// selection, returning them to OCaml's auto-recommended state.
    /// "Revert to Unison's Recommendation" (Finding #2). This performs a REAL
    /// engine revert: each direction action already mutated OCaml via
    /// `unisonRiSet*`, so clearing the Swift override alone would leave sync
    /// using the forced direction/skip. For each selected modified leaf we call
    /// `unison_bridge_ri_revert`, which resets the row to
    /// `diff.default_direction` in the engine (the exact inverse of all six
    /// actions), then we resync the Swift row (direction + changedFromDefault)
    /// and clear its visual override so badge, rows, and engine agree.
    ///
    /// A row whose revert reports FAILED_DIRTY stops the batch and enters
    /// restart-required; rows already reverted this batch stay synced first.
    @objc private func revertSelectionAction(_ sender: Any?) {
        // Same mutation gate as the direction actions (blocks during sync,
        // restart, and the Ignore publication gap).
        guard actionGate.allows(.direction) else { NSSound.beep(); return }
        let rows = leafRowsInSelection().filter { isRevertible($0) }
        guard !rows.isEmpty else { NSSound.beep(); return }
        var changedRows: [Int] = []
        for row in rows {
            guard row < items.count else { continue }
            var buf = [CChar](repeating: 0, count: 16)
            var changed = false
            let result = unison_bridge_ri_revert(Int32(row), &buf, buf.count, &changed)
            if result == UNISON_OP_FAILED_DIRTY {
                // The revert began mutating the row but a readback failed — the
                // engine no longer provably matches the displayed rows. Keep the
                // rows already reverted this batch synced (done in prior
                // iterations), then hand the engine to restart-required.
                TraceLog.shared.write("revert DIRTY on row \(row) — engine uncertain")
                redrawRowsAndAncestors(changedRows)
                onEngineUncertain("revert failed after mutating a row")
                return
            }
            guard result == UNISON_OP_OK else {
                // INVALID (bad row / missing callback) — nothing changed; skip.
                TraceLog.shared.write("revert skipped row \(row) (result \(result.rawValue))")
                continue
            }
            // Engine reset succeeded: resync the Swift row to the restored
            // recommendation (changed is false by definition) and drop the
            // visual override so the badge clears.
            items[row] = items[row].with(direction: String(cString: buf),
                                         changedFromDefault: changed)
            rowOverrides.removeValue(forKey: row)
            changedRows.append(row)
        }
        redrawRowsAndAncestors(changedRows)
        if !changedRows.isEmpty { setSummary(summaryText()) }
        TraceLog.shared.write("ReconcileWindow: Revert → engine-reverted \(changedRows.count) row(s)")
    }

    /// Redraw the given leaf rows plus every ancestor folder so aggregates
    /// re-resolve. Shared by direction/revert batch handlers.
    private func redrawRowsAndAncestors(_ rows: [Int]) {
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
    }

    /// A row is revertible if it diverges from the engine's recommendation
    /// (`changedFromDefault`) OR carries a visual-intent override (Skip / Force),
    /// so a Force whose result equals the default direction is still revertible
    /// to clear its badge. Covers plain First/Second/Merge too, which leave no
    /// `rowOverrides` entry but do set `changedFromDefault`.
    private func isRevertible(_ row: Int) -> Bool {
        guard row >= 0, row < items.count else { return false }
        return RowSelectionRules.isRevertible(
            changedFromDefault: items[row].changedFromDefault,
            hasOverride: rowOverrides[row] != nil)
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
            return rowForPendingMenuAction(preferClicked: isContextMenuItem(menuItem)) != nil
        }
        if menuItem.action == #selector(diffMenuAction(_:)) {
            guard isActionable else { return false }
            // Diff is strictly single-leaf — `rowForDiff` returns nil
            // for folder selections, multi-row selections, and
            // right-clicks on folders. The bridge's canDiff layer
            // then excludes one-sided files (typ=ABSENT on either
            // replica), symlinks, problem rows, and props-only-on-
            // both-sides changes. Both gates must pass. Validation honors the
            // clicked row only for the context menu (SF2).
            guard let row = rowForDiff(preferClicked: isContextMenuItem(menuItem)),
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
            // Enabled when at least one selected leaf is revertible — it
            // diverges from the engine recommendation (changedFromDefault, which
            // covers plain First/Second/Merge that leave no override) OR carries
            // a visual Force/Skip override (so a Force whose result equals the
            // default is still revertible to clear its badge).
            return leafRowsInSelection().contains { isRevertible($0) }
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
            // Stop is meaningful mid-sync (abort the sync) OR mid connect/scan
            // (Return to Profiles: abandon presentation and go back to the
            // picker; the scan winds down in the background). Disabled once the
            // engine needs a restart.
            if restartRequired { return false }
            if case .syncing = phase { return true }
            return isScanning
        }
        if menuItem.action == #selector(rescanMenuAction(_:)) {
            // Rescan is the way out of .done back to .ready — enabled post-sync.
            // Blocked during an active sync, once a restart is required, and
            // during an Ignore publication gap (same gate the method enforces).
            return actionGate.allows(.rescan)
        }
        // Action ▸ Show Profile Picker is NOT validated here anymore (issue #38):
        // it is an app-global navigation command owned by AppDelegate with an
        // explicit target + the shared `ShowProfilePickerMenuPolicy` routing
        // decision, so a single authority decides it and an intermittent
        // responder-chain/validation failure can't grey it.
        return true
    }

    // MARK: - Workflow menu dispatch (Go / Stop / Rescan)
    //
    // These are the responder-chain targets for the Action menu's
    // top-of-menu workflow items. They forward to the existing
    // toolbar-action methods so the menu and toolbar paths share
    // behavior. The toolbar items (in ReconcileToolbarDelegate) call
    // the same `startSync` / `cancelSync` / `rescan` methods directly.
    // (Show Profile Picker is app-global navigation, owned by AppDelegate
    // with an explicit target — see `showProfilePickerAppAction` / issue #38.)

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
        if let p = selectedNodesProviderForTesting { return p() }
        return outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? ReconcileNode
        }
    }

    /// The node under the outline view's right-click (`clickedRow`), or nil. A test
    /// seam replaces the source so the production menu handlers can be exercised
    /// without a real click (headless `clickedRow` can't be set).
    private func clickedNode() -> ReconcileNode? {
        if let p = clickedNodeProviderForTesting { return p() }
        let clicked = outlineView.clickedRow
        return clicked >= 0 ? (outlineView.item(atRow: clicked) as? ReconcileNode) : nil
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

    /// Phase-appropriate copy for the Stop toolbar item. Read by the toolbar
    /// delegate during validation so the item is relabelled "Return to
    /// Profiles" during the connect/scan phase (where it does not abort a
    /// sync) and "Stop" during an actual sync. Pure decision in
    /// `StopItemAppearance`.
    var stopItemAppearance: StopItemAppearance {
        StopItemAppearance.forPhase(isScanning: isScanning, isSyncing: isSyncing)
    }

    /// True when the current *selection* (ignoring any clicked row) is
    /// exactly one diff-able leaf — the Diff toolbar item's enablement
    /// predicate. Mirrors the `validateMenuItem` gate for
    /// `diffMenuAction` but driven off selection, since the toolbar
    /// button isn't a context-menu entry: requires `.ready` with items
    /// (`isActionable`), a single selected leaf (`diffTarget`), and the
    /// bridge's `canDiff` to pass. The bridge call is cheap and only
    /// reached once both cheaper gates clear.
    private func canDiffCurrentSelection() -> Bool {
        guard isActionable else { return false }
        guard let row = RowSelectionRules.diffTarget(
            rightClickedNode: nil, selectedNodes: selectedNodes()),
              row >= 0, row < items.count else { return false }
        return unison_bridge_can_diff(Int32(row))
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
            // Go: same gate as direction overrides. Disabled during sync, after
            // sync completes, when items is empty, and when results are
            // unavailable (`isActionable` now folds in `resultsUnavailable`).
            return isActionable
        case DirectionAction.stopIdentifier:
            // Stop is meaningful while a sync is in flight OR while the
            // connect/scan is running — during a sync it aborts; during a
            // connect/scan it is "Return to Profiles" (abandon the presentation
            // and go back to the picker; the scan winds down in the background).
            // Disabled once the engine needs a restart (nothing to act on).
            return !restartRequired && (syncing || isScanning)
        case DirectionAction.rescanIdentifier:
            // Rescan is the way out of `.done` back to `.ready` — explicitly
            // available after completion. Blocked while OCaml is running a sync,
            // once a restart is required, and during an Ignore publication gap
            // (same gate the method enforces).
            return actionGate.allows(.rescan)
        case DirectionAction.profilesIdentifier:
            // Always navigable back to the picker.
            return true
        case DirectionAction.quitIdentifier:
            // Quit is always available — same as ⌘Q.
            return true
        case DirectionAction.diffIdentifier:
            // Diff: enabled only when the selection is exactly one
            // diff-able leaf. Same predicate that gates the Action-menu
            // / context-menu Diff entry, driven off selection.
            return canDiffCurrentSelection()
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
    /// Rows targeted by the current selection: each selected node's own row +
    /// descendants, deduplicated so a hybrid directory selected alongside one of
    /// its children still yields each row exactly once. Pure logic in
    /// `ReconcileTree.rows(inSelection:)` (tested).
    private func leafRowsInSelection() -> [Int] {
        ReconcileTree.rows(inSelection: selectedNodes())
    }

    /// Every reconcile row in the subtree rooted at `node`: the node's own row
    /// (a file, or a directory that is itself a reconcile item) AND every
    /// descendant row. Used for the details footer's item count.
    private func leafRows(under node: ReconcileNode) -> [Int] {
        node.subtreeRows()
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
    /// Snapshot of the current gating state, used by BOTH the action methods and
    /// menu/toolbar validation so they can't drift. The pure predicate lives in
    /// `ReconcileActionGate` (unit-tested).
    private var actionGate: ReconcileActionGate {
        let gatePhase: ReconcileActionGate.Phase
        switch phase {
        case .ready:   gatePhase = .ready
        case .syncing: gatePhase = .syncing
        case .done:    gatePhase = .done
        }
        return ReconcileActionGate(
            restartRequired: restartRequired,
            mutationInFlight: mutationInFlight,
            isSyncing: isSyncing,
            isScanning: isScanning,
            phase: gatePhase,
            hasItems: !items.isEmpty,
            diffInFlight: diffInFlight,
            resultsUnavailable: syncResultsUnavailable)
    }

    /// Driver hook: mark this session's diff as in flight (or done). While set,
    /// `actionGate` refuses every engine-reaching action, the details panel shows a
    /// placeholder instead of calling `ri_get_details`, and toolbar/menu items
    /// disable — so no bridge call runs on the main thread behind the wedged diff.
    func setDiffInFlight(_ value: Bool) {
        guard diffInFlight != value else { return }
        diffInFlight = value
        refreshToolbarEnabled()
        updateDetailsForSelection()   // show placeholder while diffing; refresh after
    }

    private var isActionable: Bool { actionGate.isActionable }

    /// Test seam: the gate the action methods and menu/toolbar validation consult.
    var actionGateForTesting: ReconcileActionGate { actionGate }

    // MARK: - PR-5 injection seams (production reads the outline view; tests inject)

    /// Outline operations used by Select Conflicts, injectable so the
    /// reveal→map→select path runs without a real outline view (headless collapse
    /// is unreliable).
    struct OutlineOps {
        var expand: (ReconcileNode) -> Void
        var outlineRow: (ReconcileNode) -> Int
        var select: (IndexSet) -> Void
        var scrollToVisible: (Int) -> Void
    }
    var outlineOpsForTesting: OutlineOps?
    private var outlineOps: OutlineOps {
        outlineOpsForTesting ?? OutlineOps(
            expand: { [outlineView] in outlineView.expandItem($0, expandChildren: false) },
            outlineRow: { [outlineView] in outlineView.row(forItem: $0) },
            select: { [outlineView] in outlineView.selectRowIndexes($0, byExtendingSelection: false) },
            scrollToVisible: { [outlineView] in outlineView.scrollRowToVisible($0) })
    }
    /// Override the right-click source and the selection source, so the production
    /// menu handlers can be driven without a real click/selection.
    var clickedNodeProviderForTesting: (() -> ReconcileNode?)?
    var selectedNodesProviderForTesting: (() -> [ReconcileNode])?

    var outlineViewForTesting: NSOutlineView { outlineView }
    var treeForTesting: ReconcileTree { tree }
    var contextMenuForTesting: NSMenu? { outlineView.menu }
    func isContextMenuItemForTesting(_ item: NSMenuItem?) -> Bool { isContextMenuItem(item) }
    func selectConflictsForTesting() { selectConflictsAction(nil) }
    /// Invoke the real menu handlers with a context-menu vs a menu-bar sender.
    func ignoreMenuActionForTesting(_ sender: NSMenuItem) { ignoreMenuAction(sender) }
    func diffMenuActionForTesting(_ sender: NSMenuItem) { diffMenuAction(sender) }
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
        return node.isContainer
    }
}

// MARK: - NSOutlineViewDelegate

extension ReconcileWindowController: NSOutlineViewDelegate {
    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateDetailsForSelection()
        refreshToolbarEnabled()
    }

    // Toggling a folder mid-sync flips its Progress cell between the
    // aggregate summary bar (collapsed) and blank (expanded, children own
    // their bars). Repaint it immediately rather than waiting for the next
    // progress tick. The toggled item arrives under the "NSObject" key.
    //
    // CRITICAL: repaint by RELOADING THE ROW'S CELLS (by index), never via
    // `reloadItem(_:reloadChildren:)`. `reloadItem` synchronously re-posts
    // the ItemDidExpand/DidCollapse notification, which re-enters this very
    // handler and recurses until the stack overflows (observed as a crash
    // in 0.1.5/0.1.6 when collapsing a folder mid-sync). Reloading a row's
    // cells changes no expansion state, so it can't re-enter.
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ReconcileNode else { return }
        repaintProgressCell(for: node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ReconcileNode else { return }
        repaintProgressCell(for: node)
    }

    /// Repaint just the toggled folder's own row (so its collapsed-folder
    /// aggregate bar appears/clears). Only meaningful during sync; reloads
    /// the row's cells by index, which posts no expand/collapse notification.
    private func repaintProgressCell(for node: ReconcileNode) {
        guard isSyncing else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.numberOfColumns > 0 else { return }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
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
        // ProgressCellView. Folders show an aggregate bar over their subtree
        // while syncing, collapsed or expanded (see makeProgressCell).
        if col == .progress {
            return makeProgressCell(in: outlineView, node: node)
        }

        // Size column (0.4.2): a file leaf shows its own size; a folder — an
        // intermediate grouping node OR a directory that is itself one reconcile
        // item — shows the aggregate size of the changed items beneath it (sum of
        // descendant leaf sizes), blank when that sum is zero (e.g. pure
        // deletions / prop-only changes).
        if col == .size {
            let text: String
            if let row = node.row, row < items.count,
               items[row].fileType.uppercased() != "DIR" {
                text = formatSize(items[row].sizeBytes)          // file leaf
            } else {
                let total = node.aggTotalSize   // folder / dir row: cached, O(1)
                text = total > 0 ? formatSize(total) : ""
            }
            return makeCell(in: outlineView, identifier: column.identifier,
                            text: text, column: col, isFolder: node.isContainer)
        }

        // Remaining text-only column: Type. Folders leave it blank.
        let value: String
        if let row = node.row, row < items.count {
            let stateItem = items[row]
            switch col {
            case .type:      value = stateItem.fileType
            case .size:      value = ""  // handled above
            case .progress:  value = ""  // handled above
            case .path, .left, .right, .direction: value = ""  // handled above
            }
        } else {
            value = ""
        }
        return makeCell(in: outlineView, identifier: column.identifier, text: value, column: col, isFolder: node.isContainer)
    }

    /// Builds (or recycles) the Progress-column cell. Leaf rows get a
    /// ProgressCellView reflecting that file's transfer. A folder, while
    /// syncing, shows an aggregate bar over its subtree (see
    /// `ReconcileNode.progressFraction`) whether collapsed or expanded (0.4.2) —
    /// so a parent always reflects its descendants' overall progress.
    private func makeProgressCell(in outlineView: NSOutlineView,
                                   node: ReconcileNode) -> NSView {
        let id = NSUserInterfaceItemIdentifier("ProgressCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ProgressCellView ?? {
            let v = ProgressCellView()
            v.identifier = id
            return v
        }()
        if node.isTerminalLeaf, let row = node.row, row < items.count {
            // A pure leaf (no children) shows its own file's transfer.
            cell.configure(progress: items[row].progress)
        } else if isSyncing, let fraction = node.cachedProgressFraction() {
            // A folder — including a directory that is itself a reconcile item —
            // shows an aggregate bar over its subtree while syncing, collapsed or
            // expanded (0.4.2). Read from the incrementally-maintained cache
            // (O(1)); a collapsed folder is the only visible sign of its hidden
            // children's progress, and an expanded folder shows overall progress
            // alongside each child's own bar.
            cell.configure(fraction: fraction)
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
        if node.isTerminalLeaf {
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

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
