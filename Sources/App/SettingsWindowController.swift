import AppKit
import UserNotifications

/// The Settings window — opens via `<appname> → Settings… (⌘,)`.
/// Single-tab today, with three sections under it; if/when real
/// configurable preferences appear, the single tab becomes the first
/// of several inside an NSToolbar-on-window layout. For now the
/// content lives directly in the window's content view.
///
/// All wiring goes through `SettingsModel` so the reset semantics
/// are testable without standing up AppKit.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - Section 1: Profile picker layout

    private let pickerLayoutLabel = NSTextField(labelWithString: "")
    private let pickerLayoutResetButton =
        NSButton(title: "Reset", target: nil, action: nil)

    // MARK: - Section 2: SSH version-mismatch suppressions

    private let suppressionsTableView = NSTableView()
    private let suppressionsDeleteButton =
        NSButton(title: "Remove Selected", target: nil, action: nil)
    private let suppressionsClearAllButton =
        NSButton(title: "Clear All", target: nil, action: nil)
    private var suppressions: [SettingsModel.VersionSuppression] = []

    // MARK: - Section 3: Window & toolbar layout

    private let layoutCountsLabel = NSTextField(labelWithString: "")
    private let layoutResetButton =
        NSButton(title: "Reset Window Positions", target: nil, action: nil)

    // MARK: - Section 4: Reconcile display

    private let reconcileLayoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reconcileExpandPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // MARK: - Section 5: Sync completion

    private let notifyCheckbox = NSButton(
        checkboxWithTitle: "Show a notification when a sync finishes",
        target: nil, action: nil)
    private let soundCheckbox = NSButton(
        checkboxWithTitle: "Play a sound when a sync finishes",
        target: nil, action: nil)

    /// Order pinned in code so the popup item indices line up with
    /// these arrays for the selectItem/selectedIndex round-trip.
    private let layoutModes: [ReconcileTree.LayoutMode] =
        [.flat, .nestedCollapsed, .nestedFull]
    private let expandPolicies: [ReconcileTree.ExpandPolicy] =
        [.smart, .all, .rootOnly]

    private static func displayName(for mode: ReconcileTree.LayoutMode) -> String {
        switch mode {
        case .flat:            return "Flat list"
        case .nestedCollapsed: return "Nested (collapsed)"
        case .nestedFull:      return "Nested (full)"
        }
    }

    private static func displayName(for policy: ReconcileTree.ExpandPolicy) -> String {
        switch policy {
        case .smart:    return "Smart (only branches with conflicts)"
        case .all:      return "All branches"
        case .rootOnly: return "Top level only"
        }
    }

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "SettingsWindow"
        window.delegate = self
        configure()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Auto-refresh on becomeKey so counts stay live if the user toggled
    /// something in another window (e.g. hid a profile) while Settings
    /// was open in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    // MARK: - Layout

    private func configure() {
        guard let contentView = window?.contentView else { return }

        // Section 1: Profile picker layout
        let section1Title = sectionHeader("Profile Picker Layout")
        let section1Desc = sectionDescription(
            "Profiles you've hidden from the picker and the custom drag " +
            "order set in the Profile Editor. UI-only — does not affect " +
            "the .prf files on disk or the CLI `unison <profile>` command."
        )
        pickerLayoutLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        pickerLayoutLabel.textColor = .labelColor
        pickerLayoutLabel.lineBreakMode = .byTruncatingTail
        pickerLayoutLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        pickerLayoutResetButton.bezelStyle = .rounded
        pickerLayoutResetButton.target = self
        pickerLayoutResetButton.action = #selector(resetPickerLayoutAction(_:))
        let section1Row = NSStackView(views:
            [pickerLayoutLabel, NSView(), pickerLayoutResetButton])
        section1Row.orientation = .horizontal
        section1Row.spacing = 8

        // Section 2: SSH version-mismatch suppressions
        let section2Title = sectionHeader("SSH Version-Mismatch Suppressions")
        let section2Desc = sectionDescription(
            "Hosts where you checked “Don't remind me again” after the app " +
            "warned about a Unison version difference between this Mac and " +
            "the remote. Removing an entry re-enables the prompt on the next " +
            "profile open."
        )
        configureSuppressionsTable()
        let suppressionsScroll = NSScrollView()
        suppressionsScroll.documentView = suppressionsTableView
        suppressionsScroll.hasVerticalScroller = true
        suppressionsScroll.borderType = .lineBorder
        suppressionsDeleteButton.bezelStyle = .rounded
        suppressionsDeleteButton.target = self
        suppressionsDeleteButton.action = #selector(removeSuppressionAction(_:))
        suppressionsClearAllButton.bezelStyle = .rounded
        suppressionsClearAllButton.target = self
        suppressionsClearAllButton.action = #selector(clearAllSuppressionsAction(_:))
        let section2Row = NSStackView(views:
            [NSView(), suppressionsDeleteButton, suppressionsClearAllButton])
        section2Row.orientation = .horizontal
        section2Row.spacing = 8

        // Section 3: Window & toolbar layout
        let section3Title = sectionHeader("Window & Toolbar Layout")
        let section3Desc = sectionDescription(
            "Stored window positions and reconcile-toolbar layout. Reset " +
            "this if a window has drifted off-screen after a monitor change " +
            "or if you want a clean toolbar arrangement."
        )
        layoutCountsLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        layoutCountsLabel.textColor = .labelColor
        layoutCountsLabel.lineBreakMode = .byTruncatingTail
        layoutCountsLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        layoutResetButton.bezelStyle = .rounded
        layoutResetButton.target = self
        layoutResetButton.action = #selector(resetLayoutAction(_:))
        let section3Row = NSStackView(views:
            [layoutCountsLabel, NSView(), layoutResetButton])
        section3Row.orientation = .horizontal
        section3Row.spacing = 8

        // Section 4: Reconcile display (layout + expand policy)
        let section4Title = sectionHeader("Reconcile Display")
        let section4Desc = sectionDescription(
            "How the reconcile window renders the list of differences. " +
            "Mirrors upstream Unison's \"Switch table nesting\" control " +
            "plus a smart-expand option. Changes take effect on the next " +
            "rescan or profile open."
        )
        for mode in layoutModes {
            reconcileLayoutPopup.addItem(withTitle: Self.displayName(for: mode))
        }
        reconcileLayoutPopup.target = self
        reconcileLayoutPopup.action = #selector(reconcileLayoutChanged(_:))
        for policy in expandPolicies {
            reconcileExpandPopup.addItem(withTitle: Self.displayName(for: policy))
        }
        reconcileExpandPopup.target = self
        reconcileExpandPopup.action = #selector(reconcileExpandChanged(_:))
        let layoutRow = NSStackView(views: [
            NSTextField(labelWithString: "Layout:"),
            reconcileLayoutPopup, NSView(),
        ])
        layoutRow.orientation = .horizontal
        layoutRow.spacing = 8
        let expandRow = NSStackView(views: [
            NSTextField(labelWithString: "Expand on open:"),
            reconcileExpandPopup, NSView(),
        ])
        expandRow.orientation = .horizontal
        expandRow.spacing = 8

        // Section 5: Sync completion cues
        let section5Title = sectionHeader("Sync Completion")
        let section5Desc = sectionDescription(
            "Extra cues when a synchronization finishes. The reconcile " +
            "window always shows an inline result (green ✓ on success, " +
            "red ⚠ on errors); these add a Notification Center banner and " +
            "a sound on top — useful when you've switched away from a long " +
            "sync. Both are on by default."
        )
        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(notifyToggled(_:))
        soundCheckbox.target = self
        soundCheckbox.action = #selector(soundToggled(_:))
        let completionRow = NSStackView(views: [notifyCheckbox, soundCheckbox])
        completionRow.orientation = .vertical
        completionRow.alignment = .leading
        completionRow.spacing = 6

        let stack = NSStackView(views: [
            section1Title, section1Desc, section1Row, divider(),
            section2Title, section2Desc, suppressionsScroll, section2Row, divider(),
            section3Title, section3Desc, section3Row, divider(),
            section4Title, section4Desc, layoutRow, expandRow, divider(),
            section5Title, section5Desc, completionRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            section1Desc.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            section1Row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            section2Desc.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            suppressionsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            suppressionsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            section2Row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            section3Desc.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            section3Row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            section4Desc.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            layoutRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            expandRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            section5Desc.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            completionRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    private func configureSuppressionsTable() {
        let hostCol = NSTableColumn(identifier: .init("host"))
        hostCol.title = "Host"
        hostCol.minWidth = 140
        hostCol.width = 200
        let localCol = NSTableColumn(identifier: .init("local"))
        localCol.title = "This Mac"
        localCol.minWidth = 80
        localCol.width = 100
        let remoteCol = NSTableColumn(identifier: .init("remote"))
        remoteCol.title = "Remote"
        remoteCol.minWidth = 80
        remoteCol.width = 100
        suppressionsTableView.addTableColumn(hostCol)
        suppressionsTableView.addTableColumn(localCol)
        suppressionsTableView.addTableColumn(remoteCol)
        suppressionsTableView.allowsMultipleSelection = true
        suppressionsTableView.dataSource = self
        suppressionsTableView.delegate = self
        suppressionsTableView.usesAlternatingRowBackgroundColors = true
        suppressionsTableView.style = .inset
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        tf.textColor = .labelColor
        return tf
    }

    private func sectionDescription(_ text: String) -> NSTextField {
        let tf = NSTextField(wrappingLabelWithString: text)
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        tf.maximumNumberOfLines = 0
        return tf
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Reload

    private func reload() {
        let (hidden, ordered) = SettingsModel.profilePickerCounts()
        pickerLayoutLabel.stringValue = labelText(hidden: hidden, ordered: ordered)
        pickerLayoutResetButton.isEnabled = (hidden + ordered) > 0

        suppressions = SettingsModel.versionMismatchSuppressions()
        suppressionsTableView.reloadData()
        suppressionsClearAllButton.isEnabled = !suppressions.isEmpty
        refreshSuppressionsDeleteButton()

        let (frames, toolbars) = SettingsModel.windowAndToolbarCounts()
        layoutCountsLabel.stringValue = layoutLabelText(frames: frames, toolbars: toolbars)
        layoutResetButton.isEnabled = (frames + toolbars) > 0

        // Reflect current reconcile-display picks in the popups.
        // `firstIndex` is safe — every enum case is in the arrays.
        if let idx = layoutModes.firstIndex(of: SettingsModel.reconcileLayoutMode()) {
            reconcileLayoutPopup.selectItem(at: idx)
        }
        if let idx = expandPolicies.firstIndex(of: SettingsModel.reconcileExpandPolicy()) {
            reconcileExpandPopup.selectItem(at: idx)
        }

        notifyCheckbox.state = SettingsModel.notifyOnSyncComplete() ? .on : .off
        soundCheckbox.state = SettingsModel.soundOnSyncComplete() ? .on : .off
    }

    private func labelText(hidden: Int, ordered: Int) -> String {
        if hidden == 0 && ordered == 0 {
            return "All profiles visible · default alphabetical order"
        }
        let hiddenPart = hidden == 1 ? "1 hidden profile" : "\(hidden) hidden profiles"
        let orderPart = ordered == 1 ? "1 in custom order" : "\(ordered) in custom order"
        return "\(hiddenPart) · \(orderPart)"
    }

    private func layoutLabelText(frames: Int, toolbars: Int) -> String {
        if frames == 0 && toolbars == 0 {
            return "Default layout — no stored frames or toolbar configurations"
        }
        let framesPart: String = {
            switch frames {
            case 0:  return "no stored frames"
            case 1:  return "1 stored frame"
            default: return "\(frames) stored frames"
            }
        }()
        let toolbarsPart: String = {
            switch toolbars {
            case 0:  return "no stored toolbar configuration"
            case 1:  return "1 stored toolbar configuration"
            default: return "\(toolbars) stored toolbar configurations"
            }
        }()
        return "\(framesPart) · \(toolbarsPart)"
    }

    private func refreshSuppressionsDeleteButton() {
        suppressionsDeleteButton.isEnabled =
            suppressionsTableView.selectedRowIndexes.isEmpty == false
    }

    // MARK: - Actions

    @objc private func resetPickerLayoutAction(_ sender: Any?) {
        SettingsModel.resetProfilePickerLayout()
        reload()
    }

    @objc private func removeSuppressionAction(_ sender: Any?) {
        let selected = suppressionsTableView.selectedRowIndexes
        guard !selected.isEmpty else { NSSound.beep(); return }
        for row in selected {
            guard row < suppressions.count else { continue }
            SettingsModel.removeSuppression(suppressions[row])
        }
        reload()
    }

    @objc private func clearAllSuppressionsAction(_ sender: Any?) {
        guard !suppressions.isEmpty else { return }
        // Single-button confirm because this is a bulk wipe; per-row
        // delete doesn't prompt (a single accidental row removal can
        // be re-suppressed at the next prompt with one click).
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all version-mismatch suppressions?"
        alert.informativeText =
            "All \(suppressions.count) suppressed (host, local-version, " +
            "remote-version) triples will be forgotten. The next sync of " +
            "any affected SSH profile will re-prompt for version mismatch."
        alert.addButton(withTitle: "Cancel")
        let clearBtn = alert.addButton(withTitle: "Clear All")
        clearBtn.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        SettingsModel.clearAllSuppressions()
        reload()
    }

    @objc private func resetLayoutAction(_ sender: Any?) {
        SettingsModel.resetWindowAndToolbarLayout()
        // Note: clearing the autosaved frames doesn't move any
        // currently-open windows — autosaves are written on close and
        // read on open. The next launch of each window picks up the
        // default frame. Surfacing this clearly avoids confusion.
        reload()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Window positions cleared"
        alert.informativeText =
            "Stored window positions and toolbar layout have been removed. " +
            "Open windows keep their current positions until you close them; " +
            "the next time you reopen each window, it uses the default frame."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func reconcileLayoutChanged(_ sender: Any?) {
        let idx = reconcileLayoutPopup.indexOfSelectedItem
        guard idx >= 0, idx < layoutModes.count else { return }
        SettingsModel.setReconcileLayoutMode(layoutModes[idx])
        // No live re-render of an open reconcile window — the change
        // takes effect on the next rescan or profile open, matching
        // the section description in the UI.
    }

    @objc private func reconcileExpandChanged(_ sender: Any?) {
        let idx = reconcileExpandPopup.indexOfSelectedItem
        guard idx >= 0, idx < expandPolicies.count else { return }
        SettingsModel.setReconcileExpandPolicy(expandPolicies[idx])
    }

    @objc private func notifyToggled(_ sender: NSButton) {
        let on = sender.state == .on
        SettingsModel.setNotifyOnSyncComplete(on)
        // Prompt for permission the moment the user opts in, so the first
        // post-enable sync actually surfaces a banner. macOS only shows
        // the system prompt once; later toggles are silent no-ops.
        if on { SyncCompletionAnnouncer.requestAuthorizationIfEnabled() }
    }

    @objc private func soundToggled(_ sender: NSButton) {
        SettingsModel.setSoundOnSyncComplete(sender.state == .on)
    }
}

// MARK: - Suppressions table data source / delegate

extension SettingsWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { suppressions.count }
}

extension SettingsWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < suppressions.count, let columnId = tableColumn?.identifier
        else { return nil }
        let item = suppressions[row]
        let text: String
        switch columnId.rawValue {
        case "host":   text = item.host
        case "local":  text = item.localVersion
        case "remote": text = item.remoteVersion
        default:       text = ""
        }
        let cell = tableView.makeView(withIdentifier: columnId, owner: self)
            as? NSTableCellView ?? {
                let v = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                v.addSubview(tf)
                v.textField = tf
                v.identifier = columnId
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                ])
                return v
            }()
        cell.textField?.stringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshSuppressionsDeleteButton()
    }
}
