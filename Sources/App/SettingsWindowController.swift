import AppKit
import UserNotifications

/// The Settings window, opened via `<appname> → Settings… (⌘,)`.
/// Toolbar-tab layout (`SettingsTabViewController`, `.toolbar` style):
/// Saved State, Reconcile, and Sync, each a pane built in `makePane`.
/// The window resizes to the selected tab's height.
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

    // MARK: - Section 6: Logging

    /// Unison directory, so shared-mode changes can rewrite the .prf files.
    private let unisonDirectory: String

    private let logModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let logPathLabel = NSTextField(labelWithString: "Default folder:")
    private let logPathField = NSTextField(string: "")
    private let logPathBrowse =
        NSButton(title: "Choose…", target: nil, action: nil)
    /// Prevents the propagation prompt from showing twice when one user
    /// action triggers both the mode popup and the path field's end-editing.
    private var propagationPromptActive = false

    /// Pinned order so popup indices line up with the enum.
    private let loggingModes: [SettingsModel.LoggingMode] =
        [.sameFile, .sameDirectory, .perProfile]

    private static func displayName(for mode: SettingsModel.LoggingMode) -> String {
        switch mode {
        case .sameFile:      return "All profiles share one log file"
        case .sameDirectory: return "All profiles share one folder (one file each)"
        case .perProfile:    return "Each profile has its own location"
        }
    }


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

    // MARK: - Section 7: Archive maintenance

    private let cleanStaleButton =
        NSButton(title: "Clean Stale Archives…", target: nil, action: nil)
    /// Retains the review window while it's open.
    private var staleWindowController: CleanStaleArchivesWindowController?

    // MARK: - Section 8: Software updates

    /// Sparkle update preferences. Nil when there is no live updater (the
    /// XCTest host), in which case the Updates tab is omitted entirely.
    private let updatePreferences: (any UpdatePreferences)?
    private let autoUpdateCheckbox = NSButton(
        checkboxWithTitle: "Automatically check for updates",
        target: nil, action: nil)
    private let systemProfileCheckbox = NSButton(
        checkboxWithTitle: "Include an anonymous system profile with update checks",
        target: nil, action: nil)

    // MARK: - Section 9: Command line tool

    /// What `unison` resolves to in two PATH contexts, recomputed from the
    /// filesystem on every reload (see CommandLineToolStatus). The login shell
    /// is spawned off the main thread; the labels show "Checking…" meanwhile.
    private let cliTerminalLabel = NSTextField(wrappingLabelWithString: "Checking…")
    private let cliRemoteLabel = NSTextField(wrappingLabelWithString: "Checking…")
    private let cliActionButton = NSButton(title: "Install", target: nil, action: nil)
    private let cliRefreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private var cliContexts: [CommandLineToolContextStatus] = []
    private var cliAction: CommandLineToolAction?
    private var cliRefreshGeneration = 0

    // MARK: - Init

    init(unisonDirectory: String,
         updatePreferences: (any UpdatePreferences)? = nil) {
        self.unisonDirectory = unisonDirectory
        self.updatePreferences = updatePreferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        // No frame autosave: it restores a fixed frame that fights
        // NSTabViewController's per-tab height sizing. The window sizes
        // itself to the selected tab on open.
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
        // Section 1: Profile picker layout
        let section1Title = sectionHeader("Profile Picker Layout")
        let section1Desc = sectionDescription(
            "Profiles you've hidden from the picker and the custom drag " +
            "order set in the Profile Editor. This is display-only. It does " +
            "not affect the .prf files on disk or the CLI `unison <profile>` " +
            "command."
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
            "red ⚠ on errors). These add a Notification Center banner and a " +
            "sound, useful when you've switched away from a long sync. Both " +
            "are on by default."
        )
        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(notifyToggled(_:))
        soundCheckbox.target = self
        soundCheckbox.action = #selector(soundToggled(_:))
        let completionRow = NSStackView(views: [notifyCheckbox, soundCheckbox])
        completionRow.orientation = .vertical
        completionRow.alignment = .leading
        completionRow.spacing = 6

        // Section 6: Logging
        let section6Title = sectionHeader("Logging")
        let section6Desc = sectionDescription(
            "How log file locations are chosen for your profiles. Shared " +
            "modes apply one file or folder to every profile that has " +
            "logging on. Per-profile mode lets each profile set its own " +
            "location, using the folder below only as a starting suggestion."
        )
        for mode in loggingModes {
            logModePopup.addItem(withTitle: Self.displayName(for: mode))
        }
        logModePopup.target = self
        logModePopup.action = #selector(logModeChanged(_:))
        let modeRow = NSStackView(views: [
            NSTextField(labelWithString: "Mode:"), logModePopup, NSView(),
        ])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        logPathField.delegate = self
        logPathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logPathBrowse.bezelStyle = .rounded
        logPathBrowse.target = self
        logPathBrowse.action = #selector(chooseLogPathAction(_:))
        let section6Row = NSStackView(views: [
            logPathLabel, logPathField, logPathBrowse,
        ])
        section6Row.orientation = .horizontal
        section6Row.spacing = 8

        let section7Title = sectionHeader("Archive Maintenance")
        let section7Desc = sectionDescription(
            "Unison keeps a reconciliation archive for each profile. Old " +
            "copies accumulate after a profile is deleted or this Mac is " +
            "renamed. Scan for archives that no current profile uses and " +
            "move them to the Trash (recoverable). Live archives are left " +
            "untouched.")
        cleanStaleButton.bezelStyle = .rounded
        cleanStaleButton.target = self
        cleanStaleButton.action = #selector(cleanStaleArchivesAction(_:))
        let section7Row = NSStackView(views: [cleanStaleButton, NSView()])
        section7Row.orientation = .horizontal
        section7Row.spacing = 8

        // Section 8: Software updates. Built and shown only when an updater
        // exists; the XCTest host has none, so the tab is absent there.
        let section8Title = sectionHeader("Software Updates")
        let section8Desc = sectionDescription(
            "Choose whether the app checks for updates on its own and what it " +
            "includes when it does. You can change these at any time, including " +
            "after the first-launch prompt.")
        autoUpdateCheckbox.target = self
        autoUpdateCheckbox.action = #selector(autoUpdateToggled(_:))
        systemProfileCheckbox.target = self
        systemProfileCheckbox.action = #selector(systemProfileToggled(_:))
        let updatesCheckboxRow = NSStackView(
            views: [autoUpdateCheckbox, systemProfileCheckbox])
        updatesCheckboxRow.orientation = .vertical
        updatesCheckboxRow.alignment = .leading
        updatesCheckboxRow.spacing = 6
        let section8ProfileDesc = sectionDescription(
            "The profile is anonymous: macOS version, Mac model, CPU, memory, " +
            "app version, and preferred language. It is sent only when the app " +
            "checks for updates.")

        // Section 9: Command line tool. Status is read from the filesystem on
        // every reload; nothing here is a stored preference.
        let section9Title = sectionHeader("The unison Command")
        let section9Desc = sectionDescription(
            "The app bundle carries a command-line launcher. Linked onto PATH as " +
            "`unison`, it makes `unison -ui graphic` open this app and lets " +
            "`unison -server`, run by a remote machine over ssh, use this app's " +
            "Unison. Below is what `unison` resolves to right now, for two PATHs.")
        for label in [cliTerminalLabel, cliRemoteLabel] {
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.textColor = .labelColor
            label.isSelectable = true
        }
        let terminalHeading = sectionDescription("Terminal (as a login shell builds its PATH):")
        let remoteHeading = sectionDescription("Remote command (the PATH sshd gives a command arriving over ssh):")
        cliActionButton.bezelStyle = .rounded
        cliActionButton.target = self
        cliActionButton.action = #selector(commandLineToolAction(_:))
        cliActionButton.isEnabled = false
        cliRefreshButton.bezelStyle = .rounded
        cliRefreshButton.target = self
        cliRefreshButton.action = #selector(refreshCommandLineToolAction(_:))
        let section9Row = NSStackView(views: [cliActionButton, NSView(), cliRefreshButton])
        section9Row.orientation = .horizontal
        section9Row.spacing = 8
        let section9Note = sectionDescription(
            "Install creates /usr/local/bin/unison, which is on the PATH of login " +
            "shells, and asks for an administrator password. Commands arriving over " +
            "ssh get sshd's default PATH, which has neither /usr/local/bin nor the " +
            "Homebrew prefix, so machines that sync to this Mac set servercmd in " +
            "their profile. Both PATHs above are reconstructions: a PATH change " +
            "made only in .zshrc, or one made in .zshenv, can select a different " +
            "unison than shown here.")

        // ----- Group sections into Safari-style toolbar tabs -----
        // NSTabViewController(.toolbar) builds the toolbar, swaps the pane
        // views, and animates the window to each pane's preferredContentSize
        // (set in makePane) with content kept top-anchored.
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar
        // No crossfade on tab switch; just the native height animation.
        tabVC.transitionOptions = []
        tabVC.addTabViewItem(makePane(
            symbol: "arrow.counterclockwise.circle", label: "Saved State",
            views: [section1Title, section1Desc, section1Row, divider(),
                    section2Title, section2Desc, suppressionsScroll, section2Row, divider(),
                    section3Title, section3Desc, section3Row],
            tallViews: [(suppressionsScroll, 140)]))
        tabVC.addTabViewItem(makePane(
            symbol: "arrow.left.arrow.right.square", label: "Reconcile",
            views: [section4Title, section4Desc, layoutRow, expandRow]))
        tabVC.addTabViewItem(makePane(
            symbol: "bell.badge", label: "Sync",
            views: [section5Title, section5Desc, completionRow]))
        tabVC.addTabViewItem(makePane(
            symbol: "doc.text", label: "Logging",
            views: [section6Title, section6Desc, modeRow, section6Row]))
        tabVC.addTabViewItem(makePane(
            symbol: "archivebox", label: "Maintenance",
            views: [section7Title, section7Desc, section7Row]))
        if updatePreferences != nil {
            tabVC.addTabViewItem(makePane(
                symbol: "arrow.triangle.2.circlepath", label: "Updates",
                views: [section8Title, section8Desc,
                        updatesCheckboxRow, section8ProfileDesc]))
        }

        tabVC.addTabViewItem(makePane(
            symbol: "terminal", label: "Command Line",
            views: [section9Title, section9Desc,
                    terminalHeading, cliTerminalLabel,
                    remoteHeading, cliRemoteLabel,
                    section9Row, section9Note]))

        window?.contentViewController = tabVC
        window?.toolbarStyle = .preference
        window?.title = "Settings"
    }

    /// Build one toolbar-tab pane: a vertical stack of `views` in a
    /// fixed-width container, each subview pinned to the content width so
    /// wrapping descriptions wrap and trailing buttons right-align.
    /// `tallViews` get a minimum height (the suppressions table). Returns
    /// an `NSTabViewItem` ready to add to the `NSTabViewController`.
    private func makePane(symbol: String, label: String,
                          views: [NSView],
                          tallViews: [(NSView, CGFloat)] = []) -> NSTabViewItem {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // Extra bottom inset so the last control isn't crammed against the
        // window edge after the height-fit.
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 540),
        ]
        for v in views {
            constraints.append(
                v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32))
        }
        for (v, h) in tallViews {
            constraints.append(v.heightAnchor.constraint(greaterThanOrEqualToConstant: h))
        }
        NSLayoutConstraint.activate(constraints)

        let vc = NSViewController()
        vc.view = pane
        // Drive the per-tab window height. Reliable now that the wrapping
        // descriptions set preferredMaxLayoutWidth, so fittingSize is the
        // true content height. NSTabViewController animates the window to
        // this on switch, keeping content top-anchored (no "fly-in").
        pane.layoutSubtreeIfNeeded()
        vc.preferredContentSize = pane.fittingSize
        let item = NSTabViewItem(viewController: vc)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
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
        // Pane is 540 wide with 16pt side insets → 508pt content. Pinning
        // the wrap width here (not just via a width constraint) lets
        // `fittingSize` compute the real multi-line height, which the
        // tab-resize logic depends on. Matches the width constraint in
        // `makePane` (stack.width − 32).
        tf.preferredMaxLayoutWidth = 540 - 32
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

        // Logging: reflect the current mode and its path. Don't clobber the
        // path field while it's being edited (it's the first responder).
        if let idx = loggingModes.firstIndex(of: SettingsModel.loggingMode()) {
            logModePopup.selectItem(at: idx)
        }
        if window?.firstResponder !== logPathField.currentEditor() {
            syncLogPathRowToMode()
        }

        // Software updates: reflect Sparkle's current preferences. No-op when
        // there is no updater (the Updates tab is absent).
        if let prefs = updatePreferences {
            autoUpdateCheckbox.state = prefs.automaticallyChecksForUpdates ? .on : .off
            systemProfileCheckbox.state = prefs.sendsSystemProfile ? .on : .off
        }

        refreshCommandLineToolStatus()
    }

    // MARK: - Command line tool

    /// Recompute both PATH contexts off the main thread (the login shell is
    /// spawned) and show the result. A stale answer from an earlier refresh is
    /// discarded by generation.
    private func refreshCommandLineToolStatus() {
        cliRefreshGeneration += 1
        let generation = cliRefreshGeneration
        cliTerminalLabel.stringValue = "Checking…"
        cliRemoteLabel.stringValue = "Checking…"
        cliActionButton.isEnabled = false
        cliRefreshButton.isEnabled = false
        Task { [weak self] in
            // Blocking work runs on GCD inside currentStatusAsync, never on the
            // cooperative pool (see CommandLineToolStatus.currentStatusAsync).
            let contexts = await CommandLineToolStatus.currentStatusAsync()
            guard let self, self.cliRefreshGeneration == generation else { return }
            self.showCommandLineToolStatus(contexts)
        }
    }

    private func showCommandLineToolStatus(_ contexts: [CommandLineToolContextStatus]) {
        cliContexts = contexts
        let terminal = contexts.first
        let remote = contexts.dropFirst().first
        cliTerminalLabel.stringValue = CommandLineToolWording.describe(terminal)
        cliRemoteLabel.stringValue = CommandLineToolWording.describe(remote)
        cliAction = CommandLineToolActionPolicy.availableAction(contexts: contexts)
        switch cliAction {
        case .install:
            cliActionButton.title = "Install…"
            cliActionButton.isEnabled = true
        case .repair:
            cliActionButton.title = "Repair…"
            cliActionButton.isEnabled = true
        case .remove:
            cliActionButton.title = "Remove…"
            cliActionButton.isEnabled = true
        case nil:
            cliActionButton.title = "Install…"
            cliActionButton.isEnabled = false
        }
        cliRefreshButton.isEnabled = true
    }

    @objc private func refreshCommandLineToolAction(_ sender: Any?) {
        refreshCommandLineToolStatus()
    }

    @objc private func commandLineToolAction(_ sender: Any?) {
        guard let action = cliAction, let window else { return }
        let launcher = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS/cltool")
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch action {
        case .install:
            alert.messageText = "Install the unison command?"
            alert.informativeText =
                "Creates \(CommandLineToolStatus.installLinkPath) as a link to this app's " +
                "command-line launcher. Requires an administrator password."
            alert.addButton(withTitle: "Install")
        case .repair(let linkPath, let oldTarget, let displacing):
            alert.messageText = "Repair the unison command?"
            alert.informativeText = CommandLineToolWording.repairDetails(
                linkPath: linkPath, oldTarget: oldTarget, displacing: displacing)
                + " Requires an administrator password."
            alert.addButton(withTitle: "Repair")
        case .remove(let linkPath, _):
            alert.messageText = "Remove the unison command?"
            alert.informativeText =
                "Deletes the link at \(linkPath). The app keeps working from the profile " +
                "picker. Requires an administrator password."
            alert.addButton(withTitle: "Remove")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Self.performAdmin(action: action, launcherPath: launcher) { [weak self] error in
                if let error {
                    TraceLog.shared.write("command-line tool action failed: \(error)")
                    let failure = NSAlert()
                    failure.alertStyle = .warning
                    failure.messageText = "The unison command was not changed"
                    failure.informativeText = error
                    failure.addButton(withTitle: "OK")
                    if let window = self?.window { failure.beginSheetModal(for: window) } else { failure.runModal() }
                }
                self?.refreshCommandLineToolStatus()
            }
        }
    }

    /// Run the action's shell command with administrator privileges through
    /// AppleScript's `do shell script … with administrator privileges`, which
    /// shows the system authentication dialog. NSAppleScript is main-thread
    /// only, and the authentication dialog is modal anyway, so this runs
    /// synchronously on the main thread and calls `completion` with nil on
    /// success or a message on failure (a cancelled dialog included).
    @MainActor
    static func performAdmin(action: CommandLineToolAction, launcherPath: String,
                             completion: (String?) -> Void) {
        let command = CommandLineToolActionPolicy.adminShellCommand(for: action, launcherPath: launcherPath)
        let source = CommandLineToolActionPolicy.appleScript(runningAsAdmin: command)
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&errorInfo)
        let message: String? = errorInfo.map { info in
            (info[NSAppleScript.errorMessage] as? String) ?? "The command could not be run."
        }
        completion(message)
    }

    /// Update the path label, value, and placeholder to match the selected
    /// logging mode.
    private func syncLogPathRowToMode() {
        switch SettingsModel.loggingMode() {
        case .sameFile:
            logPathLabel.stringValue = "Log file:"
            logPathField.placeholderString =
                (SettingsModel.defaultUnisonDirectory as NSString).appendingPathComponent("Unison.log")
            logPathField.stringValue =
                UserDefaults.standard.string(forKey: SettingsModel.sharedLogFileKey) ?? ""
        case .sameDirectory:
            logPathLabel.stringValue = "Folder:"
            logPathField.placeholderString = SettingsModel.defaultUnisonDirectory
            logPathField.stringValue =
                UserDefaults.standard.string(forKey: SettingsModel.sharedLogDirectoryKey) ?? ""
        case .perProfile:
            logPathLabel.stringValue = "Default folder:"
            logPathField.placeholderString = SettingsModel.defaultUnisonDirectory
            logPathField.stringValue =
                UserDefaults.standard.string(forKey: SettingsModel.defaultLogDirectoryKey) ?? ""
        }
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
            return "Default layout. No stored frames or toolbar configurations."
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

    // MARK: - Archive maintenance

    /// Scan for archives no current profile uses (superseded older
    /// generations + orphans from deleted profiles / former hostnames)
    /// and offer to move them to the Trash. Reviewable + recoverable.
    @objc private func cleanStaleArchivesAction(_ sender: Any?) {
        if let existing = staleWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        // The controller scans on init; skip showing an empty window.
        let wc = CleanStaleArchivesWindowController(unisonDirectory: unisonDirectory)
        guard wc.hasStaleArchives else {
            let done = NSAlert()
            done.messageText = "No stale archives found"
            done.informativeText =
                "Every archive belongs to a current profile. Nothing to " +
                "clean up."
            done.addButton(withTitle: "OK")
            done.runModal()
            return
        }
        wc.onClose = { [weak self] in self?.staleWindowController = nil }
        staleWindowController = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
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
            "Open windows keep their current positions until you close them. " +
            "The next time you reopen each window, it uses the default frame."
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

    @objc private func autoUpdateToggled(_ sender: NSButton) {
        updatePreferences?.automaticallyChecksForUpdates = (sender.state == .on)
    }

    @objc private func systemProfileToggled(_ sender: NSButton) {
        updatePreferences?.sendsSystemProfile = (sender.state == .on)
    }

    @objc private func logModeChanged(_ sender: Any?) {
        let idx = logModePopup.indexOfSelectedItem
        guard idx >= 0, idx < loggingModes.count else { return }
        SettingsModel.setLoggingMode(loggingModes[idx])
        syncLogPathRowToMode()
        // Switching into a shared mode is a deliberate "everyone shares"
        // action — offer to apply it to existing profiles.
        offerPropagationIfShared()
    }

    @objc private func chooseLogPathAction(_ sender: Any?) {
        let mode = SettingsModel.loggingMode()
        let pickFile = (mode == .sameFile)
        let onPick: (String) -> Void = { [weak self] path in
            guard let self else { return }
            self.logPathField.stringValue = path
            self.persistLogPath(path, for: mode)
            self.offerPropagationIfShared()
        }
        if pickFile {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue =
                (SettingsModel.sharedLogFile() as NSString).lastPathComponent
            panel.directoryURL = URL(fileURLWithPath:
                (SettingsModel.sharedLogFile() as NSString).deletingLastPathComponent)
            let run: (NSApplication.ModalResponse) -> Void = { resp in
                guard resp == .OK, let url = panel.url else { return }
                onPick(url.path)
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: run) }
            else { run(panel.runModal()) }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            let run: (NSApplication.ModalResponse) -> Void = { resp in
                guard resp == .OK, let url = panel.url else { return }
                onPick(url.path)
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: run) }
            else { run(panel.runModal()) }
        }
    }

    private func persistLogPath(_ path: String, for mode: SettingsModel.LoggingMode) {
        switch mode {
        case .sameFile:      SettingsModel.setSharedLogFile(path)
        case .sameDirectory: SettingsModel.setSharedLogDirectory(path)
        case .perProfile:    SettingsModel.setDefaultLogDirectory(path)
        }
    }

    /// In a shared mode, ask whether to apply the shared file/folder to every
    /// profile that already has logging on (all-or-nothing). Per-profile mode
    /// never touches existing profiles.
    private func offerPropagationIfShared() {
        let mode = SettingsModel.loggingMode()
        guard mode == .sameFile || mode == .sameDirectory else { return }
        // One user action (picking the mode) can fire both the popup action
        // and the path field's end-editing, each calling this. Guard so the
        // prompt shows only once.
        guard !propagationPromptActive else { return }
        propagationPromptActive = true
        let target = (mode == .sameFile)
            ? SettingsModel.sharedLogFile()
            : SettingsModel.sharedLogDirectory()
        let alert = NSAlert()
        alert.messageText = "Apply to all profiles?"
        alert.informativeText = "Update every profile that has logging turned on to use \(target)? This rewrites the log file setting in those .prf files. Choose Don't Update to leave existing profiles unchanged."
        let updateButton = alert.addButton(withTitle: "Update All")
        let dontButton = alert.addButton(withTitle: "Don't Update")
        updateButton.keyEquivalent = "\r"        // Enter → Update All
        dontButton.keyEquivalent = "\u{1b}"      // Esc → Don't Update
        let act: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self else { return }
            self.propagationPromptActive = false
            guard resp == .alertFirstButtonReturn else { return }
            let result = self.propagateLoggingToAllProfiles(mode: mode)
            self.reportPropagation(result: result)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: act) }
        else { act(alert.runModal()) }
    }

    /// Rewrite the `logfile` of every profile with logging on to match the
    /// shared mode, with honest structured accounting. Reads and writes go
    /// through real filesystem seams; writes use the established transactional
    /// writer (`ProfileSaveTransaction`) so a partial failure never silently
    /// looks like success. Profile directives/raw content round-trip through
    /// `ProfileDocument`.
    private func propagateLoggingToAllProfiles(mode: SettingsModel.LoggingMode)
        -> BulkLogPropagation.Result {
        let dir = unisonDirectory
        let tx = ProfileSaveTransaction(ops: SystemFileOps(), unisonDirectory: dir)
        return BulkLogPropagation.run(
            mode: mode,
            sharedFile: SettingsModel.sharedLogFile(),
            sharedDirectory: SettingsModel.sharedLogDirectory(),
            defaultLogName: { SettingsModel.defaultLogName(forProfile: $0) },
            listProfileFileNames: { try? FileManager.default.contentsOfDirectory(atPath: dir) },
            read: {
                try? String(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent($0),
                            encoding: .utf8)
            },
            write: { file, content in
                let base = (file as NSString).deletingPathExtension
                do {
                    // In-place overwrite (oldName == newName): backup + atomic
                    // install + rollback via the shared transaction.
                    try tx.commit(oldName: base, newName: base, content: content)
                    return nil
                } catch {
                    return error
                }
            })
    }

    /// Present the five-way outcome (nothing-needed / complete-success /
    /// partial-success / complete-failure / cannot-enumerate) from the
    /// structured result — never "nothing needed updating" for a failure.
    private func reportPropagation(result: BulkLogPropagation.Result) {
        let outcome = BulkLogPropagation.classify(result)
        let (title, body) = BulkLogPropagation.present(outcome)
        let alert = NSAlert()
        alert.alertStyle = {
            switch outcome {
            case .cannotEnumerate, .completeFailure: return .critical
            case .partialSuccess: return .warning
            case .nothingNeeded, .completeSuccess: return .informational
            }
        }()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) { _ in } }
        else { alert.runModal() }
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    // Persist the path when the user finishes editing, then offer to apply
    // it in shared modes. Editing the field per keystroke would prompt too
    // eagerly, so we act on commit only.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as AnyObject === logPathField else { return }
        persistLogPath(logPathField.stringValue, for: SettingsModel.loggingMode())
        offerPropagationIfShared()
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
