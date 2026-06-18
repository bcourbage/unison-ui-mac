import AppKit

/// Lists `.prf` profiles in the Unison preferences directory and lets the
/// user pick one. Pure picker — no init/scan logic. Once the user picks
/// a profile, `onComplete(profile)` fires and the AppDelegate is
/// responsible for closing the picker, opening the reconcile window, and
/// driving init1/init2.
@MainActor
final class ProfileWindowController: NSWindowController, NSWindowDelegate {

    typealias Completion = @MainActor (_ profile: String) -> Void

    private let unisonDirectory: String
    private let onComplete: Completion
    private var profiles: [String] = []

    private let tableView = NSTableView()
    // "Run" matches the CLI verb (`unison <profile>`) and the workflow —
    // picking a profile here kicks off the init1+init2 scan that leads
    // into reconcile + sync. "Open" was misleading: it sounded like
    // opening a document for editing.
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
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
        window.delegate = self
        configure()
        reload()
    }

    // MARK: - NSWindowDelegate

    /// Refresh the profile list whenever the picker becomes key. Catches
    /// the "user created/edited a profile in Finder or via the CLI" case
    /// where we'd otherwise show a stale view until app restart. Reload
    /// is just a `contentsOfDirectory` + `reloadData` — cheap enough to
    /// run on every focus change.
    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func configure() {
        guard let contentView = window?.contentView else { return }

        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        // Low horizontal compression resistance so a long Unison
        // directory path truncates within the label rather than
        // pushing the window wider. See the same fix on
        // ReconcileWindowController.summaryLabel for the pathology
        // (single-line NSTextField + .resizable window → AppKit
        // walks the constraint chain up and grows the window).
        pathLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
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
        tableView.doubleAction = #selector(runSelected)
        tableView.style = .inset
        tableView.rowSizeStyle = .default

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder

        runButton.bezelStyle = .rounded
        runButton.target = self
        runButton.action = #selector(runSelected)
        runButton.keyEquivalent = "\r"

        // Quit lives at the far left of the bottom bar — separated from
        // the primary Run action on the right so it can't be hit by
        // reflex. Same affordance as ⌘Q / the reconcile-window toolbar.
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitApp)

        // Picker is now pure: list + Run (+ Quit). Create / Duplicate /
        // Rename / Edit / Delete / Hide / Reorder all live in the Profile
        // Editor manager window (Edit → Profile Editor…). Keeps the main
        // view uncluttered — one canonical place for "manage my profiles".
        let bottomRow = NSStackView(views: [quitButton, NSView(), runButton])
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

    /// Reload the profile list from disk and re-apply the selection.
    ///
    /// Selection priority:
    ///   1. Explicit `preferredSelection` if provided AND present in
    ///      the resulting list (used by AppDelegate when returning
    ///      from the reconcile window — the just-run profile gets
    ///      pre-selected so the user can re-run it with one click).
    ///   2. Whatever was previously selected if it's still present
    ///      (so a `windowDidBecomeKey`-triggered reload doesn't
    ///      wipe the user's manual click).
    ///   3. The "default" profile by name if it exists.
    ///   4. Row 0 as the final fallback.
    private func reload(preferredSelection: String? = nil) {
        let priorSelection = currentlySelectedProfile()
        let url = URL(fileURLWithPath: unisonDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let available = contents
            .filter { ($0 as NSString).pathExtension == "prf" }
            .map { ($0 as NSString).deletingPathExtension }
        // Apply the user's view preferences (hide + custom order) — the
        // picker shows the filtered + reordered list. Hidden profiles
        // are deliberately excluded so they don't clutter the launch view;
        // the user can still unhide them from the Profile Editor.
        let prefs = ProfilePreferences.load()
        profiles = prefs.apply(to: available, includeHidden: false)
        tableView.reloadData()

        let targetIdx: Int? = {
            if let preferred = preferredSelection,
               let idx = profiles.firstIndex(of: preferred) {
                return idx
            }
            if let prior = priorSelection,
               let idx = profiles.firstIndex(of: prior) {
                return idx
            }
            if let idx = profiles.firstIndex(of: "default") {
                return idx
            }
            return profiles.isEmpty ? nil : 0
        }()
        if let idx = targetIdx {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        TraceLog.shared.write("ProfileWindow: \(profiles.count) profiles (of \(available.count) on disk) in \(unisonDirectory)")
    }

    /// Reload the profile list (e.g. after the editor saved a new file,
    /// or after returning from the reconcile window). If `select` is
    /// non-nil and matches an entry, that entry takes priority over
    /// the prior-selection / default-name fallbacks in `reload`.
    func reloadProfiles(select: String? = nil) {
        reload(preferredSelection: select)
        // Scroll the explicit selection into view if it's far down a
        // long list. The reload itself sets the selection; this is
        // purely about visibility.
        if let target = select, let idx = profiles.firstIndex(of: target) {
            tableView.scrollRowToVisible(idx)
        }
    }

    /// The currently-selected profile name, or nil if no row is selected.
    /// Used by autotest entry points and any future menu actions that
    /// want to act on "the profile the user is looking at".
    func currentlySelectedProfile() -> String? {
        let row = tableView.selectedRow
        guard row >= 0, row < profiles.count else { return nil }
        return profiles[row]
    }

    /// Programmatic entry — selects the named profile in the table and
    /// triggers Run as if the user had double-clicked. Used by the
    /// env-var autotest hook in AppDelegate.
    func autoSelectAndOpen(profile: String) {
        guard let idx = profiles.firstIndex(of: profile) else {
            TraceLog.shared.write("AUTOTEST: profile '\(profile)' not found")
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        runSelected()
    }

    @objc private func quitApp() {
        // NSApp.terminate runs applicationWillTerminate → clean OCaml
        // bridge shutdown, identical to ⌘Q.
        NSApp.terminate(nil)
    }

    @objc private func runSelected() {
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
