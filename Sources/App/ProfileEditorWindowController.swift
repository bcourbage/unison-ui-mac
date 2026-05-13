import AppKit

/// "Profile Editor" — a multi-profile manager window.
///
/// Lists every `.prf` in the Unison directory and lets the user:
///   - **Create** new profiles (opens the form editor in "new" mode)
///   - **Edit** existing profiles (opens the form editor for the row)
///   - **Delete** (move-to-Trash) .prf files, with confirmation
///   - **Reorder** rows via drag handle ("hamburger" `line.3.horizontal`)
///   - **Hide / Unhide** profiles from the picker via eye icon
///
/// **Hide and reorder are UI-only.** They're persisted in
/// `UserDefaults` via `ProfilePreferences` — the .prf files themselves
/// are untouched. The CLI `unison <profile>` still sees every profile
/// and in whatever order Unison's loader scans for them.
///
/// The form editor (`ProfileFormWindowController`) is owned by this
/// controller — open one at a time, replacing on demand.
@MainActor
final class ProfileEditorWindowController: NSWindowController, NSWindowDelegate {

    typealias ChangedHandler = @MainActor () -> Void

    private let unisonDirectory: String
    /// Fired after any change that the picker should reflect (rename,
    /// delete, hide-toggle, reorder, save-from-form). AppDelegate uses
    /// this to refresh `ProfileWindowController.reloadProfiles()`.
    private let onProfilesChanged: ChangedHandler

    /// All profiles found on disk, after applying the user's custom
    /// order. Hidden profiles are still shown here (dimmed) so the user
    /// can unhide them — that's the editor's whole job.
    private var profiles: [String] = []
    private var prefs = ProfilePreferences()

    private let tableView = NSTableView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let newButton = NSButton(title: "New…", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate…", target: nil, action: nil)
    // Rename has no dedicated button — the Profile Name field in the
    // form is editable, so renaming is just "Edit → change name → Save".
    // Avoids two ways to do the same thing.
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    /// "Reset Archives" trashes the Unison archive files (ar*/fp*/lk*/
    /// tm*/sc*) for the selected profile, forcing the next sync to
    /// rebuild reconciliation state from scratch. Useful when archives
    /// get corrupted (rare but possible — crash mid-write, etc.).
    /// See `ArchiveHash` for how we identify which files belong to the
    /// profile without going through OCaml.
    private let resetArchivesButton = NSButton(title: "Reset Archives…", target: nil, action: nil)
    /// Re-reads the `.prf` list from disk. Auto-fires on `windowDidBecomeKey`
    /// already; this button is for the rare case where the user is staring
    /// at the manager and modifies a file in another tool without losing
    /// focus.
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private var formController: ProfileFormWindowController?

    private static let rowPasteboardType =
        NSPasteboard.PasteboardType("net.courbage.unison-ui-mac.profile-row")

    enum Col: String {
        case drag, visibility, name
        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(rawValue)
        }
    }

    init(unisonDirectory: String, onProfilesChanged: @escaping ChangedHandler) {
        self.unisonDirectory = unisonDirectory
        self.onProfilesChanged = onProfilesChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Profile Editor"
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "ProfileEditorWindow"
        window.delegate = self

        configure()
        reload()
    }

    // MARK: - NSWindowDelegate

    /// Refresh the profile list whenever the editor becomes key. Picks up
    /// external changes (CLI-created .prf, manual rename in Finder, etc.)
    /// without requiring the user to close + reopen the window. Reload is
    /// a `contentsOfDirectory` + `reloadData` — cheap.
    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Layout

    private func configure() {
        guard let contentView = window?.contentView else { return }

        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.stringValue = unisonDirectory

        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.maximumNumberOfLines = 2
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.stringValue =
            "Hide and reorder only affect this app's picker. " +
            "The CLI `unison <profile>` still sees every .prf in the directory."

        configureTableView()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder

        for button in [newButton, duplicateButton, editButton,
                       deleteButton, resetArchivesButton, refreshButton,
                       doneButton] {
            button.bezelStyle = .rounded
        }
        newButton.target = self
        newButton.action = #selector(newAction(_:))
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicateAction(_:))
        editButton.target = self
        editButton.action = #selector(editAction(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteAction(_:))
        resetArchivesButton.target = self
        resetArchivesButton.action = #selector(resetArchivesAction(_:))
        refreshButton.target = self
        refreshButton.action = #selector(refreshAction(_:))
        // ⌘R as the conventional macOS "refresh" shortcut. AppKit dispatches
        // through the button's target since the window will be key whenever
        // the editor is visible.
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = [.command]
        doneButton.target = self
        doneButton.action = #selector(doneAction(_:))
        doneButton.keyEquivalent = "\r"

        // Bottom row reads left-to-right by lifecycle of a profile:
        // create (New, Duplicate), modify (Edit — also handles rename
        // via the name field), destroy (Delete), recover (Reset
        // Archives, Refresh), then dismiss (Done) on the far right.
        let bottomRow = NSStackView(views: [
            newButton, duplicateButton,
            editButton, deleteButton,
            resetArchivesButton, refreshButton,
            NSView(), doneButton,
        ])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.distribution = .fill

        let stack = NSStackView(views: [pathLabel, scroll, bottomRow, footerLabel])
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
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])

        refreshButtonEnabled()
    }

    private func configureTableView() {
        // Three columns: drag handle, visibility toggle, profile name.
        // Headers hidden — the rows are self-explanatory and the manager
        // is narrow enough that headers would just take vertical space.
        let dragCol = NSTableColumn(identifier: Col.drag.identifier)
        dragCol.title = ""
        dragCol.width = 26
        dragCol.minWidth = 26
        dragCol.maxWidth = 26
        dragCol.resizingMask = []

        let visCol = NSTableColumn(identifier: Col.visibility.identifier)
        visCol.title = ""
        visCol.width = 28
        visCol.minWidth = 28
        visCol.maxWidth = 28
        visCol.resizingMask = []

        let nameCol = NSTableColumn(identifier: Col.name.identifier)
        nameCol.title = "Profile"
        nameCol.resizingMask = .autoresizingMask

        tableView.addTableColumn(dragCol)
        tableView.addTableColumn(visCol)
        tableView.addTableColumn(nameCol)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.rowSizeStyle = .default
        tableView.target = self
        tableView.doubleAction = #selector(editAction(_:))
        tableView.allowsMultipleSelection = false

        // Drag-reorder. Custom pasteboard type encodes the source row's
        // profile name — we resolve back to its current index at drop
        // time (in case the data has shifted, though we don't allow
        // external drops).
        tableView.registerForDraggedTypes([Self.rowPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
    }

    // MARK: - Data

    /// Re-read profile list from disk + reapply preferences. Called on
    /// init, after any mutation, and any time the .prf directory might
    /// have changed externally.
    private func reload() {
        let url = URL(fileURLWithPath: unisonDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let available = contents
            .filter { ($0 as NSString).pathExtension == "prf" }
            .map { ($0 as NSString).deletingPathExtension }

        prefs = ProfilePreferences.load()
        // includeHidden: true — the editor's whole point is to manage
        // hidden state, so hidden rows are listed (dimmed).
        profiles = prefs.apply(to: available, includeHidden: true)
        tableView.reloadData()
        refreshButtonEnabled()
    }

    /// Persist the user's preferences AND notify the picker so it
    /// re-applies the new state. Call after any prefs mutation.
    private func savePrefsAndNotify() {
        prefs.save()
        onProfilesChanged()
    }

    private func selectedProfile() -> String? {
        let row = tableView.selectedRow
        guard row >= 0, row < profiles.count else { return nil }
        return profiles[row]
    }

    private func refreshButtonEnabled() {
        let hasSelection = (tableView.selectedRow >= 0)
        editButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        duplicateButton.isEnabled = hasSelection
        resetArchivesButton.isEnabled = hasSelection
    }

    // MARK: - Actions

    @objc private func newAction(_ sender: Any?) {
        openForm(for: nil)
    }

    @objc private func editAction(_ sender: Any?) {
        guard let profile = selectedProfile() else { NSSound.beep(); return }
        openForm(for: profile)
    }

    @objc private func doneAction(_ sender: Any?) {
        window?.performClose(nil)
    }

    /// Manual refresh — re-reads the `.prf` list from disk. Mainly there
    /// for the ⌘R shortcut + edge cases where `windowDidBecomeKey` isn't
    /// enough (e.g. another app modified the directory while the manager
    /// stayed key). Cheap; just hits the filesystem and reloads the table.
    @objc private func refreshAction(_ sender: Any?) {
        reload()
    }

    /// Open the single-profile form for create-or-edit. The form's
    /// onSaved callback feeds back to us so we can refresh the list
    /// (and propagate to the picker via savePrefsAndNotify).
    private func openForm(for profileName: String?) {
        formController?.close()
        let form = ProfileFormWindowController(
            unisonDirectory: unisonDirectory,
            profileName: profileName
        ) { [weak self] savedName in
            self?.handleFormSaved(savedName: savedName, wasNew: profileName == nil)
        }
        form.showWindow(nil)
        form.window?.makeKeyAndOrderFront(nil)
        formController = form
    }

    private func handleFormSaved(savedName: String, wasNew: Bool) {
        TraceLog.shared.write("ProfileEditor: form saved '\(savedName)' (new=\(wasNew))")
        // Re-read prefs from disk first — the form may have mutated
        // `prefs.order` / `prefs.hidden` itself (rename path) and our
        // in-memory copy is stale at this point.
        prefs = ProfilePreferences.load()
        // New profiles go to the end of the user's custom order so a
        // freshly created profile lands somewhere predictable instead of
        // popping into the middle via the alphabetical fallback. Only
        // meaningful if the user already has a custom order; otherwise
        // leaving order empty keeps the picker alphabetical.
        if wasNew, !prefs.order.contains(savedName), !prefs.order.isEmpty {
            prefs.order.append(savedName)
            prefs.save()
        }
        reload()
        // Select the saved profile so the user can immediately edit again
        // or hide it without re-navigating.
        if let idx = profiles.firstIndex(of: savedName) {
            tableView.selectRowIndexes(IndexSet(integer: idx),
                                       byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
        onProfilesChanged()
    }

    @objc private func duplicateAction(_ sender: Any?) {
        guard let source = selectedProfile() else { NSSound.beep(); return }
        let suggestion = uniqueDuplicateName(basedOn: source)
        guard let newName = promptForName(
            messageText: "Duplicate profile “\(source)”",
            informativeText: "Enter a name for the new profile. The .prf " +
                "contents will be copied verbatim — roots, ignore patterns, " +
                "all preferences.",
            initialValue: suggestion,
            confirmTitle: "Duplicate"
        ) else { return }

        let srcURL = profileURL(source)
        let dstURL = profileURL(newName)
        let fm = FileManager.default
        do {
            try fm.copyItem(at: srcURL, to: dstURL)
            TraceLog.shared.write("ProfileEditor: duplicated \(source) -> \(newName)")
            // New name goes onto the user's custom order right after the
            // source — so duplicate lands next to its origin in the list.
            if let srcIdx = prefs.order.firstIndex(of: source) {
                prefs.order.insert(newName, at: srcIdx + 1)
                prefs.save()
            }
            reload()
            if let idx = profiles.firstIndex(of: newName) {
                tableView.selectRowIndexes(IndexSet(integer: idx),
                                           byExtendingSelection: false)
                tableView.scrollRowToVisible(idx)
            }
            onProfilesChanged()
        } catch {
            showFailureAlert(text: "Couldn't duplicate profile",
                             info: "\(dstURL.path):\n\(error.localizedDescription)")
        }
    }

    /// Proactive Reset Archives — wipes the local archive files
    /// (ar*/fp*/lk*/tm*/sc*) for the selected profile's roots, so the
    /// next sync rebuilds reconciliation state from scratch. Useful
    /// when the archive is corrupted (rare but possible — typically
    /// from a sync crash mid-write) without having to wait for the
    /// reactive recovery to surface the "inconsistent state" fatal.
    ///
    /// The hash that identifies which files belong to the profile is
    /// computed in Swift (`ArchiveHash`) by replicating upstream's
    /// MD5 logic. The user can verify against
    /// `unison -showArchiveName <profile>` if they want belt-and-
    /// suspenders confirmation that we'd touch the right files.
    @objc private func resetArchivesAction(_ sender: Any?) {
        guard let profile = selectedProfile() else { NSSound.beep(); return }

        // Compute the hash. Surface failures verbatim — these are the
        // user-actionable cases (profile file missing, no roots, no
        // local root) where we should NOT silently delete anything.
        let result = ArchiveHash.compute(unisonDirectory: unisonDirectory,
                                          profile: profile)
        switch result {
        case .failure(let why):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Can't reset archives for “\(profile)”"
            switch why {
            case .profileFileMissing:
                alert.informativeText =
                    "Couldn't read \(unisonDirectory)/\(profile).prf. " +
                    "If you deleted the .prf manually, you can still " +
                    "clean up its archives by looking up the hash with " +
                    "`unison -showArchiveName` and removing the matching " +
                    "ar*/fp*/lk* files from the Unison directory."
            case .noRoots:
                alert.informativeText =
                    "The profile has no `root = …` lines, so we can't " +
                    "compute its archive hash. Edit the profile to add " +
                    "the two replica roots first."
            case .noLocalRoot:
                alert.informativeText =
                    "Both of this profile's roots are remote (ssh:// or " +
                    "socket://). Archive files live on the local machine " +
                    "that runs Unison — since this profile has no local " +
                    "root, there's nothing to reset from here. Run reset " +
                    "from a machine that hosts one of the replicas."
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        case .success(let computed):
            confirmAndResetArchives(profile: profile, computed: computed)
        }
    }

    /// Second-stage prompt: show the user the files we're about to
    /// trash, with the archive hash + canonical roots for verification,
    /// then perform the deletion via `NSFileManager.trashItem(at:)`.
    private func confirmAndResetArchives(profile: String,
                                         computed: ArchiveHash.Result) {
        let cleanup = ArchiveCleanup(unisonDirectory: unisonDirectory)
        let files = cleanup.findFiles(matching: computed.hash)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset archives for “\(profile)”?"
        if files.isEmpty {
            alert.informativeText =
                "No archive files matching this profile's hash were " +
                "found in \(unisonDirectory). The profile's archive " +
                "either lives on the remote side, or has already been " +
                "cleaned up.\n\nArchive hash: \(computed.hash)\n" +
                "Canonical roots: \(computed.rootsName)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        // Order matters: Cancel first → Return defaults to safe.
        let fileList = files.map { "  • \($0.lastPathComponent)" }
            .joined(separator: "\n")
        alert.informativeText =
            "The following archive files will be moved to the Trash:\n\n" +
            "\(fileList)\n\n" +
            "The next sync of this profile will rebuild reconciliation " +
            "state from scratch (full re-scan of both replicas). For " +
            "large replicas this can take a long time.\n\n" +
            "Archive hash: \(computed.hash)\n" +
            "(Verify with `unison -showArchiveName \(profile)` if you " +
            "want to double-check.)"
        alert.addButton(withTitle: "Cancel")
        let trashBtn = alert.addButton(withTitle: "Move \(files.count) File\(files.count == 1 ? "" : "s") to Trash")
        trashBtn.hasDestructiveAction = true

        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let outcome = cleanup.trash(files)
        TraceLog.shared.write(
            "ProfileEditor: reset archives for '\(profile)' hash=\(computed.hash) " +
            "trashed=\(outcome.trashed.count) failed=\(outcome.failed.count)"
        )
        for (url, err) in outcome.failed {
            TraceLog.shared.write("  failed: \(url.lastPathComponent) — \(err)")
        }

        if !outcome.failed.isEmpty {
            // Partial failure — surface so the user knows manual
            // cleanup is needed for the rest.
            let failedList = outcome.failed
                .map { "  • \($0.0.lastPathComponent): \($0.1.localizedDescription)" }
                .joined(separator: "\n")
            let fail = NSAlert()
            fail.alertStyle = .critical
            fail.messageText = "Some archive files couldn't be moved to Trash"
            fail.informativeText =
                "\(outcome.trashed.count) of \(files.count) succeeded.\n" +
                "Failures:\n\(failedList)"
            fail.addButton(withTitle: "OK")
            fail.runModal()
        }
    }

    @objc private func deleteAction(_ sender: Any?) {
        guard let profile = selectedProfile() else { NSSound.beep(); return }
        let url = profileURL(profile)

        // Pre-compute the profile's archive files BEFORE asking. The .prf
        // gets trashed during this flow, so we need to know what archives
        // it claims while the file is still around to parse. If hash
        // compute fails (no roots, no local root, .prf already gone),
        // archive cleanup just isn't offered — the user can still hit
        // Reset Archives separately if needed.
        var archiveFiles: [URL] = []
        if case .success(let computed) = ArchiveHash.compute(
            unisonDirectory: unisonDirectory, profile: profile) {
            archiveFiles = ArchiveCleanup(unisonDirectory: unisonDirectory)
                .findFiles(matching: computed.hash)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete profile “\(profile)”?"
        if archiveFiles.isEmpty {
            alert.informativeText =
                "The .prf file at \(url.path) will be moved to the Trash. " +
                "If you'd rather keep the file but hide it from the picker, " +
                "use the eye icon next to the name instead."
        } else {
            let plural = archiveFiles.count == 1 ? "" : "s"
            alert.informativeText =
                "The .prf file at \(url.path) will be moved to the Trash. " +
                "\(archiveFiles.count) archive file\(plural) for this profile " +
                "(ar*, fp*, etc.) will also be moved if the box below is " +
                "checked — they're useless without the profile that owns " +
                "them. Uncheck if you plan to restore the .prf from Trash " +
                "and resume syncing where you left off."
        }

        // Order matters here. NSAlert assigns the Return key to the FIRST
        // added button — we want Cancel to be the default for safety
        // (Return = "don't delete"). The "Cancel"-titled button also
        // automatically gets the Escape key equivalent. We previously
        // tried to override the default-button title after the fact, which
        // gave us two buttons both labeled "Cancel"; that's the bug fix.
        alert.addButton(withTitle: "Cancel")
        let trashBtn = alert.addButton(withTitle: "Move to Trash")
        trashBtn.hasDestructiveAction = true

        // Accessory checkbox: "Also delete N archive file(s)". Default-on
        // because orphan archives serve no purpose, but easy to uncheck.
        // Suppressed entirely when there are no archives to clean up.
        var archiveCheckbox: NSButton? = nil
        if !archiveFiles.isEmpty {
            let plural = archiveFiles.count == 1 ? "" : "s"
            let cb = NSButton(checkboxWithTitle:
                "Also move \(archiveFiles.count) archive file\(plural) to Trash",
                target: nil, action: nil)
            cb.state = .on
            alert.accessoryView = cb
            archiveCheckbox = cb
        }

        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let shouldCleanArchives = archiveCheckbox?.state == .on
        let fm = FileManager.default
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            // Best-effort cleanup of the editor's backup sidecar.
            let bak = url.appendingPathExtension("bak")
            if fm.fileExists(atPath: bak.path) {
                try? fm.trashItem(at: bak, resultingItemURL: nil)
            }
            TraceLog.shared.write("ProfileEditor: trashed \(url.path)")

            // Archive cleanup if requested. Partial failures get surfaced
            // after the .prf delete succeeds so the user knows manual
            // cleanup is needed for the remainder — we never let an
            // archive-cleanup failure undo a successful profile delete.
            if shouldCleanArchives && !archiveFiles.isEmpty {
                let outcome = ArchiveCleanup(unisonDirectory: unisonDirectory)
                    .trash(archiveFiles)
                TraceLog.shared.write(
                    "ProfileEditor: archive cleanup on delete '\(profile)' " +
                    "trashed=\(outcome.trashed.count) failed=\(outcome.failed.count)"
                )
                for (failedURL, err) in outcome.failed {
                    TraceLog.shared.write("  failed: \(failedURL.lastPathComponent) — \(err)")
                }
                if !outcome.failed.isEmpty {
                    let failedList = outcome.failed
                        .map { "  • \($0.0.lastPathComponent): \($0.1.localizedDescription)" }
                        .joined(separator: "\n")
                    let fail = NSAlert()
                    fail.alertStyle = .warning
                    fail.messageText = "Some archive files couldn't be moved to Trash"
                    fail.informativeText =
                        "The profile was deleted, but \(outcome.failed.count) of " +
                        "\(archiveFiles.count) archive file\(archiveFiles.count == 1 ? " was" : "s were") " +
                        "left in place.\nFailures:\n\(failedList)"
                    fail.addButton(withTitle: "OK")
                    fail.runModal()
                }
            }

            // Remove the now-deleted profile from prefs so we don't
            // accumulate stale order/hidden entries.
            prefs.forget(profile)
            prefs.save()
            reload()
            onProfilesChanged()
        } catch {
            let fail = NSAlert()
            fail.alertStyle = .critical
            fail.messageText = "Couldn't delete profile"
            fail.informativeText = "\(url.path):\n\(error.localizedDescription)"
            fail.addButton(withTitle: "OK")
            fail.runModal()
        }
    }

    @objc private func toggleVisibility(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < profiles.count else { return }
        let profile = profiles[row]
        prefs.toggleHidden(profile)
        savePrefsAndNotify()
        // Row-only reload — visibility column + name styling change.
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    private func profileURL(_ name: String) -> URL {
        URL(fileURLWithPath: unisonDirectory).appendingPathComponent("\(name).prf")
    }

    /// Pick a unique name "<base> copy", "<base> copy 2", … that doesn't
    /// collide with an existing .prf on disk. Used as the default value
    /// in the Duplicate prompt so the user can hit Enter and get a
    /// reasonable name.
    private func uniqueDuplicateName(basedOn base: String) -> String {
        let fm = FileManager.default
        var candidate = "\(base) copy"
        var n = 2
        while fm.fileExists(atPath: profileURL(candidate).path) {
            candidate = "\(base) copy \(n)"
            n += 1
        }
        return candidate
    }

    /// Show a modal sheet asking for a profile name. Returns the trimmed
    /// non-empty name if the user clicks the confirm button AND the name
    /// passes validation (no slashes/colons, doesn't collide with an
    /// existing .prf). Returns nil on Cancel or repeated validation
    /// failure (the user sees an inline alert for each failure).
    ///
    /// We intentionally don't reuse `ProfileFormWindowController.saveAction`'s
    /// validation here — duplicate/rename are file-level operations and
    /// shouldn't go through the form-editor's parser. Same rules,
    /// different code path.
    private func promptForName(messageText: String,
                               informativeText: String,
                               initialValue: String,
                               confirmTitle: String) -> String? {
        // Loop so we can re-prompt after a validation failure rather
        // than dropping the user back to the manager window.
        var prefilled = initialValue
        while true {
            let alert = NSAlert()
            alert.messageText = messageText
            alert.informativeText = informativeText
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: "Cancel")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            input.stringValue = prefilled
            input.placeholderString = "profile-name (without .prf)"
            alert.accessoryView = input
            // Make the text field the first responder so the user can
            // type immediately. NSAlert won't focus the accessoryView
            // automatically.
            alert.window.initialFirstResponder = input

            let response = alert.runModal()
            if response != .alertFirstButtonReturn { return nil }

            let trimmed = input.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                showFailureAlert(text: "Profile name required",
                                 info: "Pick a non-empty name for the profile.")
                prefilled = ""
                continue
            }
            let forbidden = CharacterSet(charactersIn: "/\\:")
            if trimmed.rangeOfCharacter(from: forbidden) != nil {
                showFailureAlert(text: "Invalid profile name",
                                 info: "Profile names can't contain slashes or colons.")
                prefilled = trimmed
                continue
            }
            // Collision check. For Rename, the "old name == new name"
            // case is a no-op handled by the caller — but a different
            // existing file is a conflict.
            if FileManager.default.fileExists(atPath: profileURL(trimmed).path) {
                // Allow returning the same name as a no-op for Rename.
                // The caller checks for new == old and short-circuits.
                if trimmed != initialValue {
                    showFailureAlert(text: "Profile already exists",
                                     info: "“\(trimmed).prf” already exists in the Unison directory.")
                    prefilled = trimmed
                    continue
                }
            }
            return trimmed
        }
    }

    private func showFailureAlert(text: String, info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Data source

extension ProfileEditorWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    // MARK: Drag-reorder

    /// Encode the profile name onto the pasteboard so the drop side can
    /// identify which row is being moved. We use the basename (not the
    /// row index) because if the source-row index ever drifts during the
    /// drag we still resolve the right profile.
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < profiles.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(profiles[row], forType: Self.rowPasteboardType)
        return item
    }

    /// Only allow drops between rows (insert), not on rows (replace).
    /// Forces the drop UI to show the standard horizontal indicator line.
    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        // Drag must originate from this same table.
        guard let source = info.draggingSource as? NSTableView, source === tableView else {
            return []
        }
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let pbItems = info.draggingPasteboard.pasteboardItems else { return false }
        // We only ever drag a single row (allowsMultipleSelection=false),
        // but loop for safety.
        let droppedNames: [String] = pbItems.compactMap {
            $0.string(forType: Self.rowPasteboardType)
        }
        guard !droppedNames.isEmpty else { return false }

        // Drop-row index math lives in ProfilePreferences.reorder so it
        // can be unit-tested without an AppKit harness — see
        // ProfilePreferencesTests.test_reorder_*.
        let newOrder = ProfilePreferences.reorder(profiles,
                                                  moving: droppedNames,
                                                  toDropRow: row)
        profiles = newOrder
        // Persist the new order. We store every visible profile (even
        // hidden ones) so toggling hide later doesn't reset the order.
        prefs.order = newOrder
        savePrefsAndNotify()
        tableView.reloadData()
        // Keep the dragged profile selected for follow-up actions.
        if let first = droppedNames.first,
           let idx = profiles.firstIndex(of: first) {
            tableView.selectRowIndexes(IndexSet(integer: idx),
                                       byExtendingSelection: false)
        }
        return true
    }
}

// MARK: - Delegate

extension ProfileEditorWindowController: NSTableViewDelegate {
    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshButtonEnabled()
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = tableColumn,
              let col = Col(rawValue: column.identifier.rawValue),
              row >= 0, row < profiles.count else { return nil }
        let name = profiles[row]
        let isHidden = prefs.hidden.contains(name)
        switch col {
        case .drag:
            return dragHandleCell(in: tableView)
        case .visibility:
            return visibilityCell(in: tableView, row: row, isHidden: isHidden)
        case .name:
            return nameCell(in: tableView, name: name, isHidden: isHidden)
        }
    }

    /// Static hamburger icon. The whole row is draggable; this is just
    /// the visual affordance ("☰" via SF Symbol `line.3.horizontal`).
    private func dragHandleCell(in tableView: NSTableView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("DragHandleCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let v = NSTableCellView()
            v.identifier = id
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            iv.image = NSImage(systemSymbolName: "line.3.horizontal",
                               accessibilityDescription: "Drag to reorder")
            iv.contentTintColor = .tertiaryLabelColor
            v.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
            ])
            return v
        }()
        return cell
    }

    /// Toggle button. Eye = visible in picker; eye.slash = hidden.
    /// Tag carries the row index so the action knows which profile to
    /// toggle without needing the controller to track it externally.
    private func visibilityCell(in tableView: NSTableView,
                                row: Int,
                                isHidden: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier("VisibilityCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let v = NSTableCellView()
            v.identifier = id
            let btn = NSButton()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.isBordered = false
            btn.bezelStyle = .smallSquare
            btn.imagePosition = .imageOnly
            btn.target = self
            btn.action = #selector(toggleVisibility(_:))
            v.addSubview(btn)
            v.identifier = id
            // We stash the button on the cell so the row-recycler can
            // re-bind tag + image without re-creating subviews.
            v.subviews.first?.identifier = NSUserInterfaceItemIdentifier("VisibilityButton")
            NSLayoutConstraint.activate([
                btn.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                btn.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                btn.widthAnchor.constraint(equalToConstant: 22),
                btn.heightAnchor.constraint(equalToConstant: 22),
            ])
            return v
        }()
        if let btn = cell.subviews.compactMap({ $0 as? NSButton }).first {
            btn.tag = row
            let symbol = isHidden ? "eye.slash" : "eye"
            let desc = isHidden ? "Hidden — click to show in picker"
                                : "Visible — click to hide from picker"
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
            btn.toolTip = desc
            btn.contentTintColor = isHidden ? .tertiaryLabelColor : .secondaryLabelColor
        }
        return cell
    }

    /// Profile name. Dimmed when the profile is hidden so the visibility
    /// state is legible at a glance, even before the user mouses over
    /// the eye icon.
    private func nameCell(in tableView: NSTableView,
                          name: String,
                          isHidden: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier("NameCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf)
            v.textField = tf
            v.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()
        cell.textField?.stringValue = name
        cell.textField?.textColor = isHidden ? .tertiaryLabelColor : .labelColor
        return cell
    }
}
