import AppKit

/// Editor for a Unison `.prf` profile. Two modes:
///
/// - **Edit existing** — opens with a profile name (e.g. "Sync-Home") and
///   loads `<unisonDirectory>/<name>.prf` into the form. Name is locked.
/// - **New** — name is editable; on save we write to a fresh file (with
///   collision check) and the picker reloads.
///
/// What it surfaces beyond the legacy app's text-only "raw .prf" view:
/// - Roots and paths as separate top-level fields with folder pickers.
/// - **Ignore + Ignorenot (include-exception)** patterns as their own
///   multi-line fields, since these are the most-edited keys in practice.
/// - All other keys are preserved verbatim in an "Advanced" raw-text
///   field. The user can still hand-edit anything we don't expose.
///
/// Terminology: the two endpoints of a sync are both called "roots" of
/// "replicas" in the upstream manual; either can be local or remote. We
/// label them **First** and **Second**, matching how the manual refers
/// to them ("the first replica", "the second replica") and how the .prf
/// stores them — two `root = …` lines in order.
///
/// Storage: writes the .prf via `ProfileDocument.serialized` to
/// `<unisonDirectory>/<name>.prf` atomically (.writeAtomic). A backup
/// copy `<name>.prf.bak` is written first, replaced on each save —
/// cheap insurance against the editor corrupting a profile.
@MainActor
final class ProfileFormWindowController: NSWindowController, NSWindowDelegate {

    typealias SaveCompletion = @MainActor (_ profileName: String) -> Void

    private let unisonDirectory: String
    private let initialProfileName: String?   // nil = new profile
    private let onSaved: SaveCompletion
    private var prfDocument: ProfileDocument

    // Top-level fields. firstRootField / secondRootField map to the
    // first and second `root = …` lines in the .prf, in document order.
    // Either may be a local path or an ssh://… / socket://… URL.
    private let nameField = NSTextField(string: "")
    private let firstRootField = NSTextField(string: "")
    private let secondRootField = NSTextField(string: "")

    // List fields (multi-line, one value per line)
    private let pathsView = ListFieldView(
        label: "Paths to sync",
        help: "Top-level paths to include in the sync. Blank means \"sync everything under the root\"."
    )
    private let ignoreView = ListFieldView(
        label: "Ignore patterns",
        help: "Each line is a raw Unison ignore pattern: `Path foo/bar`, `Name *.tmp`, `Regex \\..*`."
    )
    private let ignorenotView = ListFieldView(
        label: "Include (override ignore)",
        help: "Exceptions to the ignore patterns. A match here keeps the path even if `ignore` would drop it."
    )

    // Catch-all for unknown keys / advanced prefs
    private let advancedView = ListFieldView(
        label: "Advanced (other prefs)",
        help: "Each line is a raw `key = value` pref. Edit with care — typos here propagate to the .prf file as-is."
    )

    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // (Historical note: there used to be a `renameWarningAcceptedFor`
    // flag here that gated an "archive orphan" warning on rename. The
    // warning was based on a misunderstanding of upstream — archive
    // files are keyed off `(thisRoot, rootsName, archiveFormat)`,
    // none of which include the profile filename. Renaming a .prf
    // does NOT orphan archives. The warning was removed; see the
    // ArchiveHash.swift comment + the May-2026 commit that landed
    // the proactive Reset Archives feature.)

    /// Designated initializer.
    ///
    /// - profileName: pass nil to create a new profile, or the basename
    ///   (no `.prf` suffix) to edit an existing one.
    /// - onSaved: called after a successful save with the resulting
    ///   profile basename. Use it to refresh the picker.
    init(unisonDirectory: String,
         profileName: String?,
         onSaved: @escaping SaveCompletion) {
        self.unisonDirectory = unisonDirectory
        self.initialProfileName = profileName
        self.onSaved = onSaved
        self.prfDocument = ProfileDocument()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = profileName.map { "Edit Profile — \($0)" } ?? "New Profile"
        window.center()
        super.init(window: window)
        // Form (single-profile content editor) has its own autosave key
        // distinct from the multi-profile manager so they don't fight
        // over the same saved frame in NSUserDefaults.
        windowFrameAutosaveName = "ProfileFormWindow"
        window.delegate = self

        configure()
        loadDocumentIntoForm()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Layout

    private func configure() {
        guard let contentView = window?.contentView else { return }

        nameField.placeholderString = "profile-name (filename without .prf)"
        // Always editable: changing the name on an existing profile
        // performs a rename at save time (move the .prf on disk, carry
        // the .bak along, update prefs.order/hidden so the user's view
        // settings follow the renamed profile). Renaming is genuinely
        // benign for Unison's archive state — archive files are keyed
        // off the roots, not the profile filename — so we don't need
        // a confirmation sheet for it. The Profile Editor's "Reset
        // Archives" button is the way to wipe archives if the user
        // wants to.
        nameField.isEditable = true
        if let initial = initialProfileName {
            nameField.stringValue = initial
        }

        // Either root can be local or remote — placeholder shows both
        // common forms. The Browse button on each lets the user pick a
        // local directory; remote roots are typed in by hand.
        firstRootField.placeholderString =
            "/Users/you/Documents   or   ssh://user@host//path"
        secondRootField.placeholderString =
            "/Volumes/backup/sync   or   ssh://user@host//path"

        // Lower horizontal compression resistance on the editable
        // single-line fields. Defaults are .defaultHigh (750), which —
        // with a long path like
        // "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents/"
        // — caused AutoLayout to grow the *window* (the only thing in the
        // constraint chain without a hard width pin) rather than truncate
        // the field, pushing the Browse buttons and Save/Cancel offscreen.
        // .defaultLow (250) tells AutoLayout: "feel free to compress this
        // field; the user can scroll within it horizontally." Same fix
        // for nameField so a long temporary name during rename doesn't
        // do the same.
        for field in [nameField, firstRootField, secondRootField] {
            field.setContentCompressionResistancePriority(
                .defaultLow, for: .horizontal)
        }

        let browseFirst = makeBrowseButton(target: self,
                                           action: #selector(browseFirstRoot(_:)))
        let browseSecond = makeBrowseButton(target: self,
                                            action: #selector(browseSecondRoot(_:)))

        // `wrappingLabelWithString:` (vs. `labelWithString:`) sets the
        // text field up to wrap automatically based on available width —
        // no need for a `preferredMaxLayoutWidth` dance. The earlier
        // `labelWithString:` version with `maximumNumberOfLines = 3`
        // rendered as a single super-wide line and was a co-contributor
        // to the window-growth issue described above.
        let rootsHelp = NSTextField(wrappingLabelWithString:
            "Each root is one endpoint of the sync. A root can be a local " +
            "directory (e.g. /Users/you/Documents) or a remote URL " +
            "(ssh://user@host//path). Both can be local — there is no " +
            "client/server distinction in the .prf file."
        )
        rootsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rootsHelp.textColor = .secondaryLabelColor
        rootsHelp.maximumNumberOfLines = 0

        let nameRow = labeledRow(label: "Profile name", control: nameField)
        let firstRow = labeledRow(label: "First root",
                                  control: hstack([firstRootField, browseFirst]))
        let secondRow = labeledRow(label: "Second root",
                                   control: hstack([secondRootField, browseSecond]))

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveAction(_:))
        saveButton.keyEquivalent = "\r"

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        cancelButton.keyEquivalent = "\u{1b}"  // Escape

        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fill

        let stack = NSStackView(views: [
            nameRow, firstRow, secondRow, rootsHelp,
            sectionDivider(),
            pathsView,
            ignoreView,
            ignorenotView,
            sectionDivider(),
            advancedView,
            buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // Stretch every form row to the stack's full width.
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            firstRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            secondRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            rootsHelp.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            pathsView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            ignoreView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            ignorenotView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            advancedView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    private func labeledRow(label: String, control: NSView) -> NSStackView {
        let lbl = NSTextField(labelWithString: label + ":")
        lbl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lbl.textColor = .secondaryLabelColor
        lbl.alignment = .left
        let row = NSStackView(views: [lbl, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill
        lbl.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return row
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 6
        s.distribution = .fill
        return s
    }

    private func sectionDivider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func makeBrowseButton(target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: "Browse…", target: target, action: action)
        b.bezelStyle = .rounded
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return b
    }

    // MARK: - Document <-> form

    /// Reads the .prf from disk (when editing existing) and populates the
    /// form fields. Unknown keys land in the Advanced field as raw lines.
    private func loadDocumentIntoForm() {
        if let name = initialProfileName {
            let url = profileURL(forName: name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                prfDocument = ProfileDocument.parse(text)
            } else {
                TraceLog.shared.write("ProfileForm: failed to read \(url.path)")
            }
        }
        // Top-level fields: the two `root = …` lines in document order.
        // Either can be a local path or an ssh://… / socket://… URL.
        let roots = prfDocument.values(forKey: "root")
        firstRootField.stringValue = roots.first ?? ""
        secondRootField.stringValue = roots.count >= 2 ? roots[1] : ""

        // List fields
        pathsView.values = prfDocument.values(forKey: "path")
        ignoreView.values = prfDocument.values(forKey: "ignore")
        ignorenotView.values = prfDocument.values(forKey: "ignorenot")

        // Advanced: every key we don't surface above, rendered as
        // `key = value` lines in original order.
        advancedView.values = advancedLines(from: prfDocument)
    }

    /// Compute the "advanced" view content: every key=value entry whose
    /// key isn't already exposed by a dedicated field, plus comments
    /// summarized via a single header. Blank lines and comments aren't
    /// shown here — they live on the document only and are merged back at
    /// save time.
    private func advancedLines(from doc: ProfileDocument) -> [String] {
        let handled: Set<String> = ["root", "path", "ignore", "ignorenot"]
        return doc.entries.compactMap { entry in
            if case let .keyValue(k, v) = entry, !handled.contains(k) {
                return "\(k) = \(v)"
            }
            return nil
        }
    }

    /// Push the form fields back into `document` and serialize. We do this
    /// in a deterministic order so the editor's output is stable: known
    /// fields first (in display order), then the advanced raw lines.
    private func formIntoDocument() -> ProfileDocument {
        var doc = prfDocument  // start from the loaded doc so comments/order survive

        // Roots: rewrite the entire `root` list from the two fields,
        // dropping blanks. If both are blank we still want at least one
        // entry so the save round-trips, but for simplicity we just
        // remove the key entirely — the user will see the failure on next
        // load (Unison itself will refuse to open a rootless profile).
        var roots: [String] = []
        let first  = firstRootField.stringValue.trimmingCharacters(in: .whitespaces)
        let second = secondRootField.stringValue.trimmingCharacters(in: .whitespaces)
        if !first.isEmpty  { roots.append(first) }
        if !second.isEmpty { roots.append(second) }
        doc.setValues(roots, forKey: "root")

        doc.setValues(pathsView.values, forKey: "path")
        doc.setValues(ignoreView.values, forKey: "ignore")
        doc.setValues(ignorenotView.values, forKey: "ignorenot")

        // Reconcile the advanced field with the existing document. Each
        // line should be `key = value`; we drop any line that doesn't
        // parse. Then for each key, replace any existing entries — but
        // only for keys NOT in our known set (those are already handled).
        let handled: Set<String> = ["root", "path", "ignore", "ignorenot"]
        var seenAdvancedKeys: [String: [String]] = [:]
        var orderedAdvancedKeys: [String] = []
        for line in advancedView.values {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty || handled.contains(key) { continue }
            if seenAdvancedKeys[key] == nil { orderedAdvancedKeys.append(key) }
            seenAdvancedKeys[key, default: []].append(value)
        }
        // Remove every advanced key from the document first (in case the
        // user deleted a line), then re-apply.
        let priorAdvancedKeys: Set<String> = Set(doc.entries.compactMap {
            if case let .keyValue(k, _) = $0, !handled.contains(k) { return k }
            return nil
        })
        for k in priorAdvancedKeys where seenAdvancedKeys[k] == nil {
            doc.setValues([], forKey: k)
        }
        for k in orderedAdvancedKeys {
            doc.setValues(seenAdvancedKeys[k] ?? [], forKey: k)
        }

        return doc
    }

    // MARK: - Actions

    @objc private func browseFirstRoot(_ sender: NSButton) {
        browseRoot(into: firstRootField)
    }

    @objc private func browseSecondRoot(_ sender: NSButton) {
        browseRoot(into: secondRootField)
    }

    /// Open an NSOpenPanel for choosing a local directory and stash the
    /// chosen path into the given field. Browse only handles local roots —
    /// remote URLs (ssh://, socket://) must be typed in directly.
    private func browseRoot(into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }

    @objc private func cancelAction(_ sender: NSButton) {
        window?.performClose(nil)
    }

    @objc private func saveAction(_ sender: NSButton) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showAlert(text: "Profile name required",
                      info: "Pick a filename for the profile (without the .prf extension).",
                      style: .warning)
            return
        }
        // Block characters that would break the filename → CLI invocation
        // path. Unison accepts pretty much anything in the prf basename
        // but slashes and colons would confuse the user later.
        let forbidden = CharacterSet(charactersIn: "/\\:")
        if name.rangeOfCharacter(from: forbidden) != nil {
            showAlert(text: "Invalid profile name",
                      info: "Profile names can't contain slashes or colons.",
                      style: .warning)
            return
        }

        let url = profileURL(forName: name)
        let isNew = (initialProfileName == nil)
        // True when an existing profile is being saved under a different
        // name — i.e. the user renamed it via the Profile Name field.
        // We treat this as a rename + write in one atomic-ish step.
        let isRename = !isNew && name != initialProfileName

        // Collision detection: refuse to overwrite an unrelated existing
        // file. For New: any existing .prf with that name is a conflict.
        // For Rename: same rule (the source's old name is fine — we're
        // about to move it away).
        let collisionTarget = isNew || isRename
        if collisionTarget, FileManager.default.fileExists(atPath: url.path) {
            showAlert(text: "Profile already exists",
                      info: "\(name).prf is already in the Unison directory. Pick a different name.",
                      style: .warning)
            return
        }

        let doc = formIntoDocument()
        let text = doc.serialized

        // For Rename: move the source .prf (and its .bak sidecar) out of
        // the way first, so the destination write below is clean. We
        // do the rename BEFORE the write so a write failure leaves the
        // user with the renamed-but-stale file — still consistent —
        // rather than two files (old + new) on a partial write.
        if isRename, let oldName = initialProfileName {
            // No confirm sheet: see comment in `configure(profile:)`.
            // Renaming a .prf is benign for archive state because
            // Unison's archive hash depends on roots, not the .prf
            // filename.
            let oldURL = profileURL(forName: oldName)
            let oldBak = oldURL.appendingPathExtension("bak")
            let newBak = url.appendingPathExtension("bak")
            do {
                if FileManager.default.fileExists(atPath: oldURL.path) {
                    try FileManager.default.moveItem(at: oldURL, to: url)
                }
                if FileManager.default.fileExists(atPath: oldBak.path) {
                    try? FileManager.default.moveItem(at: oldBak, to: newBak)
                }
                // Carry view preferences (hide / order) across the rename
                // so the renamed profile stays in the same slot in the
                // manager / picker. See ProfilePreferencesTests.test_rename_*.
                var prefs = ProfilePreferences.load()
                prefs.rename(oldName, to: name)
                prefs.save()
                TraceLog.shared.write("ProfileForm: renamed \(oldName) -> \(name)")
            } catch {
                showAlert(text: "Couldn't rename profile",
                          info: "Renaming \(oldName).prf → \(name).prf:\n\(error.localizedDescription)",
                          style: .critical)
                return
            }
        }

        // Backup before overwrite. Skipping on a first write (file doesn't
        // exist yet) is fine — there's nothing to back up.
        if FileManager.default.fileExists(atPath: url.path) {
            let backupURL = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            TraceLog.shared.write("ProfileForm: wrote \(url.path) (\(text.count) bytes)")
            onSaved(name)
            window?.performClose(nil)
        } catch {
            showAlert(text: "Failed to save profile",
                      info: "\(url.path):\n\(error.localizedDescription)",
                      style: .critical)
        }
    }

    private func profileURL(forName name: String) -> URL {
        URL(fileURLWithPath: unisonDirectory).appendingPathComponent("\(name).prf")
    }

    private func showAlert(text: String, info: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = info
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // (The rename-warning alert + NSTextFieldDelegate that gated it
    // were removed in May 2026 — they were based on a misunderstanding
    // of upstream's archive-hash algorithm. The hash is computed from
    // `(thisRoot, rootsName, archiveFormat)`, all of which come from
    // the .prf's `root = …` lines, not the filename. Renaming the
    // .prf doesn't change the roots, so the archive hash is stable
    // and no orphans occur.)
}

/// Re-usable multi-line list field. One entry per line; blank lines
/// dropped on the way out. Exposed to the editor as a `values: [String]`
/// property the editor reads/writes directly.
@MainActor
final class ListFieldView: NSView {

    private let labelField: NSTextField
    private let helpField: NSTextField
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    var values: [String] {
        get {
            textView.string
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            textView.string = newValue.joined(separator: "\n")
        }
    }

    init(label: String, help: String) {
        labelField = NSTextField(labelWithString: label)
        helpField = NSTextField(labelWithString: help)
        super.init(frame: .zero)

        labelField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        helpField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpField.textColor = .secondaryLabelColor
        helpField.lineBreakMode = .byWordWrapping
        helpField.maximumNumberOfLines = 2

        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Disable smart-paste shenanigans on path content.
        textView.isAutomaticLinkDetectionEnabled = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.autohidesScrollers = true

        labelField.translatesAutoresizingMaskIntoConstraints = false
        helpField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)
        addSubview(helpField)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            labelField.topAnchor.constraint(equalTo: topAnchor),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor),
            helpField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 2),
            helpField.leadingAnchor.constraint(equalTo: leadingAnchor),
            helpField.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: helpField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }
}
