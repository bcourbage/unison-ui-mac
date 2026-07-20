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
    // `var` (not `let`): updated to the new name only AFTER a rename commits
    // successfully, so a failed save leaves the controller's identity matching
    // the (unchanged) on-disk state and a retry behaves correctly (Finding #11).
    private var initialProfileName: String?   // nil = new profile
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
        help: "Top-level paths to include in the sync. Blank means \"sync everything under the root\". Lines beginning with # are comments."
    )
    private let ignoreView = ListFieldView(
        label: "Ignore patterns",
        help: "One Unison ignore pattern per line. Examples: `Name *.tmp`, `Path build`, `Regex \\..*`, `BelowPath foo`. Use Add Common… for typical sets. Lines beginning with # are comments."
    )
    private let ignorenotView = ListFieldView(
        label: "Exceptions (override ignore)",
        help: "Patterns kept even when an ignore rule would drop them (`ignorenot`). One per line. Lines beginning with # are comments."
    )

    // Built in configure() (needs the list of existing profiles).
    private var includesView: IncludeListView!
    /// Finding #7: set by every genuine Includes-editor change (add/remove/name/
    /// Top-Bottom/comment), reset after form population. Drives the no-op include
    /// decision explicitly, so an untouched Includes section is always treated as
    /// unchanged even when its displayed form is lossy.
    private var includesDirty = false

    // Catch-all for unknown keys / advanced prefs
    private let advancedView = ListFieldView(
        label: "Advanced (other prefs)",
        help: "Each line is a raw `key = value` pref. Edit with care. Typos here propagate to the .prf file as is."
    )

    // Logging (Options section)
    private let logCheckbox = NSButton(
        checkboxWithTitle: "Write a log file", target: nil, action: nil)
    private let logFolderField = NSTextField(string: "")
    private let logFolderBrowse = NSButton(title: "Choose…", target: nil, action: nil)
    private let logNameField = NSTextField(string: "")
    private var logFolderRow: NSView!
    private var logNameRow: NSView!
    /// `log` value as loaded, so turning the checkbox off can preserve an
    /// explicit `false`/absent rather than silently flipping the meaning.
    private var originalLog: String?

    /// Tier-1 inheritance banner: shown when the profile `include`s others.
    private let includesBanner = NSTextField(labelWithString: "")

    // Remote connection (SSH / servercmd). Surfaced inside Roots when a
    // root is remote; previously these lived in the Advanced catch-all.
    private let servercmdField = NSTextField(string: "")
    private let sshcmdField = NSTextField(string: "")
    private let sshargsField = NSTextField(string: "")
    private let clientHostNameField = NSTextField(string: "")
    private let remoteGroup = NSStackView()
    /// Keys owned by the SSH subsection — excluded from the Advanced
    /// catch-all so they aren't edited in two places.
    private static let remoteKeys = ["servercmd", "sshcmd", "sshargs", "clientHostName"]

    /// Templates for the Ignore section's "Add Common…" menu. Values are
    /// raw `ignore` strings, appended to the freeform editor.
    private static let commonIgnores: [(label: String, patterns: [String])] = [
        ("macOS metadata", ["Name .DS_Store", "Name ._*", "Name .Spotlight-V100",
                            "Name .Trashes", "Name .fseventsd"]),
        ("iCloud placeholders", ["Name *.icloud", "Name .*.icloud"]),
        ("Version control", ["Name .git", "Name .svn", "Name .hg"]),
        ("Build artifacts", ["Name node_modules", "Name .build", "Name DerivedData",
                            "Name __pycache__"]),
        ("Temp / editor files", ["Name *.tmp", "Name *.swp", "Name *~"]),
    ]

    // General: mirrors the Profile Editor list's hide/show toggle
    // (UserDefaults `profiles.hidden`). "Show" checked == not hidden.
    private let visibilityCheckbox = NSButton(
        checkboxWithTitle: "Show in the profile picker", target: nil, action: nil)

    // File Attributes — which metadata Unison preserves. Tri-state popups
    // (Default / On / Off); Default writes no line.
    private let timesPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rsrcPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ownerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let groupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dontchmodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    // perms is a bitmask, not a bool: Default / Ignore differences (= 0) /
    // Custom mask. The mask field sits inline after the popup and is shown
    // only for "Custom mask…" (collapsed otherwise) — so the rows below it
    // never shift.
    private let permsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let permsMaskField = NSTextField(string: "")

    // Options — sync *behavior* prefs (how a sync runs), distinct from what
    // is synced. Same tri-state popups (Default / On / Off).
    private let confirmbigdelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fastcheckPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // Conflict handling — `prefer`/`force` collapsed into one popup. `force`
    // makes a replica authoritative (overwrites the other); `prefer` only
    // resolves conflicts. Both take a root value or `newer`/`older`.
    private let conflictPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// (title, key, target). target ∈ first|second|newer|older; Default = nils.
    private static let conflictChoices: [(title: String, key: String?, target: String?)] = [
        ("Default (ask on conflict)", nil, nil),
        ("Prefer first root",  "prefer", "first"),
        ("Prefer second root", "prefer", "second"),
        ("Prefer newer",       "prefer", "newer"),
        ("Prefer older",       "prefer", "older"),
        ("Force first root",   "force",  "first"),
        ("Force second root",  "force",  "second"),
        ("Force newer",        "force",  "newer"),
        ("Force older",        "force",  "older"),
    ]
    /// Holds a `prefer`/`force` value the popup can't represent (e.g. a root
    /// that matches neither field) so it still round-trips on save.
    private var rawConflict: (key: String, value: String)?

    private static let attrKeys = ["times", "perms", "rsrc", "owner", "group", "dontchmod"]
    private static let optionKeys = ["confirmbigdel", "auto", "fastcheck", "prefer", "force", "log", "logfile"]
    /// All keys with dedicated UI — excluded from the Advanced catch-all.
    private static var handledKeys: Set<String> {
        Set(["root", "path", "ignore", "ignorenot"] + remoteKeys + attrKeys + optionKeys)
    }

    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let openPrfButton = NSButton(title: "Open .prf File…", target: nil, action: nil)

    // Sidebar navigator (left) + swappable section container (right).
    // Each entry pairs a sidebar title with the section's content view;
    // the controls inside are the same instances the load/save logic
    // reads, just rehoused — so `loadDocumentIntoForm`/`formIntoDocument`
    // are unchanged.
    private let sidebarTable = NSTableView()
    private let sidebarSearch = NSSearchField()
    /// Row → index into sectionViews, honoring the current search filter.
    private var visibleSectionIndices: [Int] = []
    private let sectionContainer = NSView()
    private var sectionViews: [(title: String, icon: String, view: NSView)] = []

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
        // `.v2` abandons any frame saved before the help-label width fix —
        // those got polluted to an over-wide value. New name → reopens at
        // the default size once, then autosaves normally.
        windowFrameAutosaveName = "ProfileFormWindow.v2"
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
            "(ssh://user@host//path). Both can be local. There is no " +
            "client/server distinction in the .prf file."
        )
        rootsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rootsHelp.textColor = .secondaryLabelColor
        rootsHelp.maximumNumberOfLines = 0
        rootsHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        // Escape hatch: hand the raw .prf to the user's default editor.
        // Lives as a "pop-out" affordance in the content's upper-right
        // corner (à la Outlook's reading-pane pop-out), built into the
        // right pane below. Only meaningful once the file exists, so it's
        // disabled for a brand-new (unsaved) profile. See makePopOutBar().
        configurePopOutButton()

        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fill

        // Remote Connection subsection (inside Roots), shown only when a
        // root is remote. Re-evaluated live as the root fields change.
        servercmdField.placeholderString = "remote unison path (servercmd)"
        sshcmdField.placeholderString = "ssh"
        sshargsField.placeholderString = "extra ssh args, e.g. -p 2222"
        clientHostNameField.placeholderString = "this Mac's hostname (rarely needed)"
        for f in [servercmdField, sshcmdField, sshargsField, clientHostNameField] {
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let remoteHeader = NSTextField(labelWithString: "Remote Connection")
        remoteHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let remoteHelp = NSTextField(wrappingLabelWithString:
            "How to reach a remote (ssh://) root. Leave blank to use Unison's defaults.")
        remoteHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        remoteHelp.textColor = .secondaryLabelColor
        remoteHelp.maximumNumberOfLines = 0
        remoteHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteGroup.orientation = .vertical
        remoteGroup.alignment = .leading
        remoteGroup.spacing = 8
        let remoteRows: [NSView] = [
            remoteHeader, remoteHelp,
            labeledRow(label: "Remote unison", control: servercmdField),
            labeledRow(label: "SSH command", control: sshcmdField),
            labeledRow(label: "SSH args", control: sshargsField),
            labeledRow(label: "Client host", control: clientHostNameField),
        ]
        for v in remoteRows {
            remoteGroup.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: remoteGroup.widthAnchor).isActive = true
        }
        // Live remote detection: show/hide the subsection as roots change.
        firstRootField.delegate = self
        secondRootField.delegate = self

        // Let the editable list views absorb a section's spare vertical
        // space instead of leaving it empty at the bottom.
        for v in [pathsView, ignoreView, ignorenotView, advancedView] as [NSView] {
            v.setContentHuggingPriority(.defaultLow, for: .vertical)
        }

        // "Add Common…" appends typical ignore sets to the freeform editor.
        let addCommonPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        addCommonPopup.bezelStyle = .rounded
        addCommonPopup.addItem(withTitle: "Add Common…")
        for t in Self.commonIgnores { addCommonPopup.addItem(withTitle: t.label) }
        addCommonPopup.target = self
        addCommonPopup.action = #selector(addCommonIgnore(_:))
        addCommonPopup.setContentHuggingPriority(.required, for: .horizontal)
        let addCommonRow = NSStackView(views: [addCommonPopup, NSView()])
        addCommonRow.orientation = .horizontal
        addCommonRow.spacing = 8

        // ----- File Attributes section -----
        for p in [timesPopup, rsrcPopup, ownerPopup, groupPopup, dontchmodPopup] {
            p.addItems(withTitles: ["Default", "On", "Off"])
        }
        permsPopup.addItems(withTitles:
            ["Default", "Ignore permission differences", "Custom mask…"])
        permsPopup.target = self
        permsPopup.action = #selector(permsModeChanged)
        permsPopup.setContentHuggingPriority(.required, for: .horizontal)
        permsMaskField.placeholderString = "e.g. 0o1777"
        permsMaskField.toolTip = "Octal (0o755), hex (0x1FF), or decimal"
        permsMaskField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        // Mask field lives inline after the popup; a trailing spacer keeps
        // it from stretching across the row.
        let permsSpacer = NSView()
        permsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let permsRow = labeledRow(label: "Permissions",
            control: hstack([permsPopup, permsMaskField, permsSpacer]))

        let attrHelp = NSTextField(wrappingLabelWithString:
            "Which file metadata Unison keeps in sync. \"Default\" leaves the setting out of the profile entirely (Unison's standard behavior).")
        attrHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        attrHelp.textColor = .secondaryLabelColor
        attrHelp.maximumNumberOfLines = 0
        attrHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fileAttrs = sectionStack([
            attrHelp,
            attrRow("Modification times", timesPopup),
            permsRow,
            attrRow("Resource forks", rsrcPopup),
            attrRow("Owner", ownerPopup),
            attrRow("Group", groupPopup),
            attrRow("Suppress chmod", dontchmodPopup),
        ])

        // ----- Options section -----
        for p in [confirmbigdelPopup, autoPopup, fastcheckPopup] {
            p.addItems(withTitles: ["Default", "On", "Off"])
        }
        conflictPopup.addItems(withTitles: Self.conflictChoices.map { $0.title })
        let optionsHelp = NSTextField(wrappingLabelWithString:
            "How a sync runs (not what is synced). \"Default\" leaves the setting out of the profile entirely (Unison's standard behavior).")
        optionsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        optionsHelp.textColor = .secondaryLabelColor
        optionsHelp.maximumNumberOfLines = 0
        optionsHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let conflictHelp = NSTextField(wrappingLabelWithString:
            "\"Force\" makes one root authoritative and overwrites the other. \"Prefer\" only breaks ties on conflicting changes.")
        conflictHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        conflictHelp.textColor = .secondaryLabelColor
        conflictHelp.maximumNumberOfLines = 0
        conflictHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Logging controls (in Options). The checkbox toggles logging. The
        // folder defaults to the app's log directory (shown as the
        // placeholder) unless you choose a different one. The file name
        // defaults to Unison-<profile>.log. Both rows hide when logging off.
        logCheckbox.target = self
        logCheckbox.action = #selector(logToggled(_:))
        logFolderField.placeholderString = SettingsModel.defaultLogDirectory()
        logFolderField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logFolderBrowse.bezelStyle = .rounded
        logFolderBrowse.target = self
        logFolderBrowse.action = #selector(browseLogFolder(_:))
        logFolderBrowse.setContentHuggingPriority(.required, for: .horizontal)
        logNameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logFolderRow = labeledRow(label: "Folder",
            control: hstack([logFolderField, logFolderBrowse]))
        logNameRow = labeledRow(label: "File name", control: logNameField)

        let options = sectionStack([
            optionsHelp,
            attrRow("Conflict handling", conflictPopup),
            conflictHelp,
            attrRow("Confirm big deletions", confirmbigdelPopup),
            attrRow("Auto-accept changes", autoPopup),
            attrRow("Fast update check", fastcheckPopup),
            sectionDivider(),
            logCheckbox,
            logFolderRow,
            logNameRow,
        ])

        // Includes section: a small rule-based editor (one row per included
        // file, each with a Top/Bottom position).
        includesView = IncludeListView(
            label: "Included profiles",
            help: "Pull in another prefs file's settings. \"Top\" applies before this profile, so this profile wins single-value conflicts. \"Bottom\" applies after, so the included file wins.",
            existingNames: existingProfileNames())
        includesView.onChange = { [weak self] in
            self?.includesDirty = true       // a genuine user edit (add/remove/name/pos/comment)
            self?.refreshIncludesBanner()
        }

        // ----- Sidebar sections (controls rehoused) -----
        sectionViews = [
            ("General",  "gearshape", sectionStack([nameRow, visibilityCheckbox])),
            ("Roots",    "arrow.left.arrow.right", sectionStack([firstRow, secondRow, rootsHelp, remoteGroup])),
            ("Paths",    "folder", sectionStack([pathsView], fill: true)),
            ("Ignore",   "eye.slash", sectionStack([ignoreView, addCommonRow, ignorenotView], fill: true)),
            ("File Attributes", "tag", fileAttrs),
            ("Options",  "slider.horizontal.3", options),
            ("Includes", "doc.on.doc", sectionStack([includesView])),
            ("Advanced", "curlybraces", sectionStack([advancedView], fill: true)),
        ]
        visibleSectionIndices = Array(sectionViews.indices)

        // The Ignore section stacks two list views; with equal hugging the
        // stack would hand all the slack to one. Pin them equal so each
        // gets ~half the height. Activated here — after both are arranged
        // subviews of the Ignore stack — so they share a common ancestor.
        ignorenotView.heightAnchor.constraint(equalTo: ignoreView.heightAnchor).isActive = true

        let col = NSTableColumn(identifier: .init("section"))
        col.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(col)
        sidebarTable.headerView = nil
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.style = .sourceList
        sidebarTable.rowSizeStyle = .default
        sidebarTable.selectionHighlightStyle = .none  // HoverRowView draws selection + hover with matching geometry
        sidebarTable.backgroundColor = .clear
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        // Search box atop the sidebar (Claude-style), filtering sections.
        sidebarSearch.placeholderString = "Search"
        sidebarSearch.delegate = self
        sidebarSearch.sendsWholeSearchString = false
        sidebarSearch.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSStackView(views: [sidebarSearch, sidebarScroll])
        sidebar.orientation = .vertical
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 8, right: 8)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarSearch.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true
        sidebarScroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true

        sectionContainer.translatesAutoresizingMaskIntoConstraints = false

        // Pop-out button sits right-aligned in a slim top bar above the
        // section content — the window's upper-right corner.
        let popOutBar = NSStackView(views: [NSView(), openPrfButton])
        popOutBar.orientation = .horizontal
        popOutBar.translatesAutoresizingMaskIntoConstraints = false

        // Tier-1 inheritance banner — hidden unless the profile includes
        // others. Spans the content width above the section.
        includesBanner.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        includesBanner.textColor = .secondaryLabelColor
        includesBanner.lineBreakMode = .byTruncatingTail
        includesBanner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        includesBanner.isHidden = true

        let rightSide = NSStackView(views: [popOutBar, includesBanner, sectionContainer, buttonRow])
        rightSide.orientation = .vertical
        rightSide.spacing = 10
        rightSide.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        rightSide.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(sidebar)
        contentView.addSubview(rightSide)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 176),

            rightSide.topAnchor.constraint(equalTo: contentView.topAnchor),
            rightSide.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rightSide.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            rightSide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            sectionContainer.widthAnchor.constraint(equalTo: rightSide.widthAnchor, constant: -28),
            buttonRow.widthAnchor.constraint(equalTo: rightSide.widthAnchor, constant: -28),
            popOutBar.widthAnchor.constraint(equalTo: rightSide.widthAnchor, constant: -28),
            includesBanner.widthAnchor.constraint(equalTo: rightSide.widthAnchor, constant: -28),
        ])

        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showSection(0)
    }

    /// Vertical stack of a section's controls, each stretched to width.
    private func sectionStack(_ views: [NSView], fill: Bool = false) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        }
        // Field sections top-pack: a flexible spacer soaks up the extra
        // height so rows aren't spread apart. Editor sections (fill: true)
        // let their text view absorb the space instead.
        if !fill {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            s.addArrangedSubview(spacer)
            spacer.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        }
        return s
    }

    /// Swap the right-side container to show the selected section. Views
    /// are reused (the array retains them), so control state persists.
    private func showSection(_ index: Int) {
        guard sectionViews.indices.contains(index) else { return }
        refreshIncludesBanner()
        sectionContainer.subviews.forEach { $0.removeFromSuperview() }
        let v = sectionViews[index].view
        sectionContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: sectionContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: sectionContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: sectionContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: sectionContainer.bottomAnchor),
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
        lbl.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return row
    }

    /// Show/hide the Tier-1 inheritance banner from the current includes.
    private func refreshIncludesBanner() {
        let names = includesView.entries.map { $0.name }
        includesBanner.isHidden = names.isEmpty
        if !names.isEmpty {
            includesBanner.stringValue = "Includes " + names.joined(separator: ", ")
                + ". Settings from those files also apply at sync time."
        }
    }

    /// Other `.prf` basenames in the Unison directory (excluding this one),
    /// offered in the "Add Existing…" include picker.
    private func existingProfileNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: unisonDirectory)) ?? []
        return names
            .filter { ($0 as NSString).pathExtension == "prf" }
            .map { ($0 as NSString).deletingPathExtension }
            .filter { $0 != initialProfileName }
            .sorted()
    }

    /// Show the log path controls per the global logging mode:
    /// shared-file → checkbox only; shared-folder → file name only;
    /// per-profile → folder + file name. All hidden when logging is off.
    private func updateLogfileVisibility() {
        let on = (logCheckbox.state == .on)
        let mode = SettingsModel.loggingMode()
        logFolderRow?.isHidden = !on || mode != .perProfile
        logNameRow?.isHidden   = !on || mode == .sameFile
    }

    /// Default log file name for the current profile.
    private func defaultLogName() -> String {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? (initialProfileName ?? "sync") : typed
        return "Unison-\(name).log"
    }

    // Redraw the sidebar rows so the selection (and each cell's text/glyph
    // color, applied in HoverRowView.drawBackground) refreshes when the
    // window gains or loses key.
    private func redrawSidebarSelection() {
        sidebarTable.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }
    func windowDidBecomeKey(_ notification: Notification) { redrawSidebarSelection() }
    func windowDidResignKey(_ notification: Notification) { redrawSidebarSelection() }

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

        // List fields (with interleaved # comments preserved)
        pathsView.values = prfDocument.valuesWithComments(forKey: "path")
        ignoreView.values = prfDocument.valuesWithComments(forKey: "ignore")
        ignorenotView.values = prfDocument.valuesWithComments(forKey: "ignorenot")

        // Advanced: every key we don't surface above, rendered as
        // `key = value` lines in original order.
        advancedView.values = advancedLines(from: prfDocument)

        // Remote connection fields (owned by Roots → Remote Connection).
        servercmdField.stringValue = prfDocument.firstValue(forKey: "servercmd") ?? ""
        sshcmdField.stringValue = prfDocument.firstValue(forKey: "sshcmd") ?? ""
        sshargsField.stringValue = prfDocument.firstValue(forKey: "sshargs") ?? ""
        clientHostNameField.stringValue = prfDocument.firstValue(forKey: "clientHostName") ?? ""
        updateRemoteVisibility()

        // Picker visibility (mirrors the Profile Editor's eye toggle).
        let isHidden = initialProfileName.map {
            ProfilePreferences.load().hidden.contains($0)
        } ?? false
        visibilityCheckbox.state = isHidden ? .off : .on

        // File attributes
        setTriState(timesPopup, from: prfDocument.firstValue(forKey: "times"))
        setTriState(rsrcPopup, from: prfDocument.firstValue(forKey: "rsrc"))
        setTriState(ownerPopup, from: prfDocument.firstValue(forKey: "owner"))
        setTriState(groupPopup, from: prfDocument.firstValue(forKey: "group"))
        setTriState(dontchmodPopup, from: prfDocument.firstValue(forKey: "dontchmod"))
        switch prfDocument.firstValue(forKey: "perms") {
        case nil:        permsPopup.selectItem(at: 0)
        case "0"?:       permsPopup.selectItem(at: 1)
        case let mask?:  permsPopup.selectItem(at: 2); permsMaskField.stringValue = mask
        }
        updatePermsMaskVisibility()

        // Options
        setTriState(confirmbigdelPopup, from: prfDocument.firstValue(forKey: "confirmbigdel"))
        setTriState(autoPopup, from: prfDocument.firstValue(forKey: "auto"))
        setTriState(fastcheckPopup, from: prfDocument.firstValue(forKey: "fastcheck"))
        loadConflict()

        // Logging. Split an existing logfile into folder + name. Leave the
        // folder blank when it matches the default so the placeholder shows
        // through (blank means "use the default").
        originalLog = prfDocument.firstValue(forKey: "log")
        logCheckbox.state = (originalLog == "true") ? .on : .off
        logNameField.placeholderString = defaultLogName()
        if let lf = prfDocument.firstValue(forKey: "logfile"), !lf.isEmpty {
            let dir = (lf as NSString).deletingLastPathComponent
            logFolderField.stringValue = (dir == SettingsModel.defaultLogDirectory()) ? "" : dir
            logNameField.stringValue = (lf as NSString).lastPathComponent
        } else {
            logFolderField.stringValue = ""
            logNameField.stringValue = ""
        }
        updateLogfileVisibility()

        // Includes (Top/Bottom position + optional comment). The combo shows
        // the profile name without the `.prf` suffix — we add it back on save.
        includesView.entries =
            prfDocument.topIncludes.map { (name: Self.displayIncludeName($0.name), top: true, comment: $0.comment) }
            + prfDocument.bottomIncludes.map { (name: Self.displayIncludeName($0.name), top: false, comment: $0.comment) }
        // Populating the combo programmatically doesn't fire `onChange`, but
        // reset the dirty flag explicitly so a fresh form is never seen as edited.
        includesDirty = false
        refreshIncludesBanner()
    }

    /// Strip a trailing `.prf` for display in the Includes combo — the user
    /// picks profiles by name, not filename.
    private static func displayIncludeName(_ name: String) -> String {
        name.hasSuffix(".prf") ? String(name.dropLast(4)) : name
    }

    /// Append `.prf` for the on-disk `include` line so it's explicit that the
    /// target is a profile file. Unison loads `include Foo.prf` and the bare
    /// `include Foo` to the same file (prefs.ml profilePathname), so this is
    /// safe; we just make it clearer.
    private static func includeNameForDisk(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasSuffix(".prf") { return t }
        return t + ".prf"
    }

    /// Map the profile's `prefer`/`force` onto the conflict popup. An
    /// unrepresentable value (root matching neither field) gets a dynamic
    /// item appended so it stays visible and round-trips on save.
    private func loadConflict() {
        rawConflict = nil
        while conflictPopup.numberOfItems > Self.conflictChoices.count {
            conflictPopup.removeItem(at: conflictPopup.numberOfItems - 1)
        }
        // `force` wins over `prefer` if a profile somehow sets both.
        let pair: (String, String)?
        if let f = prfDocument.firstValue(forKey: "force") { pair = ("force", f) }
        else if let p = prfDocument.firstValue(forKey: "prefer") { pair = ("prefer", p) }
        else { pair = nil }

        guard let (key, value) = pair else { conflictPopup.selectItem(at: 0); return }
        if let idx = conflictIndex(key: key, value: value) {
            conflictPopup.selectItem(at: idx)
        } else {
            rawConflict = (key, value)
            conflictPopup.addItem(withTitle: "\(key) = \(value)")
            conflictPopup.selectItem(at: conflictPopup.numberOfItems - 1)
        }
    }

    /// Index of the standard popup choice matching (key, value), or nil if
    /// the value doesn't map to first/second root or newer/older.
    private func conflictIndex(key: String, value: String) -> Int? {
        let first = firstRootField.stringValue.trimmingCharacters(in: .whitespaces)
        let second = secondRootField.stringValue.trimmingCharacters(in: .whitespaces)
        let target: String?
        if value == "newer" { target = "newer" }
        else if value == "older" { target = "older" }
        else if !first.isEmpty, value == first { target = "first" }
        else if !second.isEmpty, value == second { target = "second" }
        else { target = nil }
        guard let target else { return nil }
        return Self.conflictChoices.firstIndex { $0.key == key && $0.target == target }
    }

    /// The literal `prefer`/`force` value for a popup target.
    private func conflictValue(forTarget target: String) -> String {
        switch target {
        case "first":  return firstRootField.stringValue.trimmingCharacters(in: .whitespaces)
        case "second": return secondRootField.stringValue.trimmingCharacters(in: .whitespaces)
        default:       return target   // "newer" / "older"
        }
    }

    private func isRemoteRoot(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("ssh://") || t.hasPrefix("socket://")
    }

    /// Show the Remote Connection subsection only when a root is remote.
    private func updateRemoteVisibility() {
        remoteGroup.isHidden = !(isRemoteRoot(firstRootField.stringValue)
                                 || isRemoteRoot(secondRootField.stringValue))
    }

    // MARK: - File attributes helpers

    /// A label + left-aligned control row for the File Attributes section.
    private func attrRow(_ label: String, _ control: NSView) -> NSView {
        labeledRow(label: label, control: hstack([control, NSView()]))
    }

    /// Popup positions for the Default/On/Off tri-state options. Raw
    /// values match the `addItems(withTitles: ["Default","On","Off"])`
    /// order so they double as `selectItem(at:)` indices.
    enum TriState: Int { case `default` = 0, on = 1, off = 2 }

    /// Map a pref's raw string value to a tri-state position. Pure +
    /// `nonisolated` so it's unit-testable without the popup. Unison
    /// accepts several boolean spellings — true/false, yes/no, and a bare
    /// key (no `= value`) meaning true — so all must map to On/Off.
    /// Anything else (incl. the literal "default", or an absent key)
    /// is Default. The old true/false-only mapping silently turned
    /// `fastcheck = no` into "Default" and then DROPPED it on save.
    nonisolated static func triState(forPrefValue value: String?) -> TriState {
        switch value?.lowercased() {
        case "true", "yes", "":  return .on   // incl. bare key (= true)
        case "false", "no":      return .off
        default:                 return .default
        }
    }

    /// Inverse: the value to persist for a tri-state position — `true`/
    /// `false` for On/Off, or nil for Default (so the key is omitted).
    /// Note this normalizes yes/no → true/false on save (behaviourally
    /// identical to Unison; a cosmetic rewrite of the user's spelling).
    nonisolated static func prefValue(forTriState t: TriState) -> String? {
        switch t {
        case .on:      return "true"
        case .off:     return "false"
        case .default: return nil
        }
    }

    private func setTriState(_ p: NSPopUpButton, from value: String?) {
        p.selectItem(at: Self.triState(forPrefValue: value).rawValue)
    }

    private func triStateValue(_ p: NSPopUpButton) -> String? {
        Self.prefValue(forTriState: TriState(rawValue: p.indexOfSelectedItem) ?? .default)
    }

    @objc private func permsModeChanged() { updatePermsMaskVisibility() }

    /// The inline mask field is shown only for "Custom mask…". It's an
    /// arranged subview of the row's stack, so hiding it collapses it and
    /// the popup keeps its place — mirrors the Remote Connection group's
    /// show/hide. The rows below never shift.
    private func updatePermsMaskVisibility() {
        permsMaskField.isHidden = (permsPopup.indexOfSelectedItem != 2)
    }

    /// Accept an octal (`0o755`), hex (`0x1FF`), or decimal integer.
    private func isValidPermsMask(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t.hasPrefix("0o") || t.hasPrefix("0O") { return Int(t.dropFirst(2), radix: 8) != nil }
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16) != nil }
        return Int(t) != nil
    }

    /// Compute the "advanced" view content: every key=value entry whose
    /// key isn't already exposed by a dedicated field, plus comments
    /// summarized via a single header. Blank lines and comments aren't
    /// shown here — they live on the document only and are merged back at
    /// save time.
    private func advancedLines(from doc: ProfileDocument) -> [String] {
        let handled: Set<String> = Self.handledKeys
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

        doc.setValuesWithComments(pathsView.values, forKey: "path")
        doc.setValuesWithComments(ignoreView.values, forKey: "ignore")
        doc.setValuesWithComments(ignorenotView.values, forKey: "ignorenot")

        // Remote connection keys, owned by Roots → Remote Connection. Set
        // the value or remove the key when the field is blank.
        for (field, key) in [(servercmdField, "servercmd"),
                             (sshcmdField, "sshcmd"),
                             (sshargsField, "sshargs"),
                             (clientHostNameField, "clientHostName")] {
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            doc.setValue(v.isEmpty ? nil : v, forKey: key)
        }

        // File attributes (tri-state booleans + perms). Default → no line.
        doc.setValue(triStateValue(timesPopup), forKey: "times")
        doc.setValue(triStateValue(rsrcPopup), forKey: "rsrc")
        doc.setValue(triStateValue(ownerPopup), forKey: "owner")
        doc.setValue(triStateValue(groupPopup), forKey: "group")
        doc.setValue(triStateValue(dontchmodPopup), forKey: "dontchmod")
        switch permsPopup.indexOfSelectedItem {
        case 1: doc.setValue("0", forKey: "perms")
        case 2:
            let m = permsMaskField.stringValue.trimmingCharacters(in: .whitespaces)
            doc.setValue(m.isEmpty ? nil : m, forKey: "perms")
        default: doc.setValue(nil, forKey: "perms")
        }

        // Options (tri-state behavior prefs). Default → no line.
        doc.setValue(triStateValue(confirmbigdelPopup), forKey: "confirmbigdel")
        doc.setValue(triStateValue(autoPopup), forKey: "auto")
        doc.setValue(triStateValue(fastcheckPopup), forKey: "fastcheck")

        // Conflict handling: resolve the popup (or a raw value it can't
        // represent) into a single (key, value) and apply it via
        // ProfileDocument.setConflict, which sets in place and clears the
        // other key. See that method for why position matters here.
        let sel = conflictPopup.indexOfSelectedItem
        if sel < Self.conflictChoices.count {
            let c = Self.conflictChoices[sel]
            if let key = c.key, let target = c.target {
                doc.setConflict(key: key, value: conflictValue(forTarget: target))
            } else {
                doc.setConflict(key: nil, value: nil)   // Default (ask on conflict)
            }
        } else if let raw = rawConflict {
            doc.setConflict(key: raw.key, value: raw.value)
        }

        // Logging. The global mode decides how logfile is composed.
        if logCheckbox.state == .on {
            doc.setValue("true", forKey: "log")
            let nameRaw = logNameField.stringValue.trimmingCharacters(in: .whitespaces)
            let name = nameRaw.isEmpty ? defaultLogName() : nameRaw
            let folderRaw = logFolderField.stringValue.trimmingCharacters(in: .whitespaces)
            let perProfileFolder = folderRaw.isEmpty
                ? SettingsModel.defaultLogDirectory()
                : (folderRaw as NSString).expandingTildeInPath
            doc.setValue(SettingsModel.composeLogfile(
                mode: SettingsModel.loggingMode(),
                name: name,
                sharedFile: SettingsModel.sharedLogFile(),
                sharedDirectory: SettingsModel.sharedLogDirectory(),
                perProfileFolder: perProfileFolder), forKey: "logfile")
        } else {
            // Off: write `false` only if it was previously on; otherwise
            // preserve the original (absent stays absent, false stays false).
            doc.setValue(originalLog == "true" ? "false" : originalLog, forKey: "log")
            doc.setValue(nil, forKey: "logfile")
        }

        // Reconcile the advanced field with the existing document. Each
        // line should be `key = value`; we drop any line that doesn't
        // parse. Then for each key, replace any existing entries — but
        // only for keys NOT in our known set (those are already handled).
        let handled: Set<String> = Self.handledKeys
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

        // Includes LAST — after every key-value write above. `setIncludes`
        // positions bottom includes right after the last key-value entry,
        // so writing them last guarantees they sit below newly-added
        // Advanced (and conflict/log) keys. Done earlier, a key appended at
        // end-of-document would land *below* a just-placed bottom include,
        // flipping their order (the reported "include jumps above my
        // Advanced item" bug). Top includes still land before the first pref.
        //
        // Finding #7: only rebuild the includes when the user actually changed
        // them. If unchanged, leave every include lexeme, pass-through directive,
        // raw line, comment, and position exactly as loaded. `.refuseUnmanaged`
        // is handled (and refused) in `saveAction` before any mutation; treat it
        // as a no-op here defensively (and `setIncludes` itself refuses too).
        switch includeSaveDecision() {
        case .unchanged, .refuseUnmanaged:
            break
        case .applyTopBottom:
            let edited = includesView.entries
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            doc.setIncludes(
                top: edited.filter { $0.top }
                    .map { ProfileDocument.IncludeEntry(name: Self.includeNameForDisk($0.name), comment: $0.comment) },
                bottom: edited.filter { !$0.top }
                    .map { ProfileDocument.IncludeEntry(name: Self.includeNameForDisk($0.name), comment: $0.comment) })
        }

        return doc
    }

    /// The Finding #7 include-save decision. No-op detection uses the explicit
    /// editor dirty flag (`includesDirty`), NOT a lossy display-projection
    /// comparison — an untouched Includes section is always `.unchanged`. Used by
    /// `saveAction` (to refuse before any filesystem work) and by
    /// `formIntoDocument` (to skip or apply the rebuild).
    private func includeSaveDecision() -> ProfileDocument.IncludeSaveDecision {
        ProfileDocument.includeSaveDecision(
            includesEdited: includesDirty,
            hasUnmanagedOrderedEntries: prfDocument.hasUnmanagedOrderedEntries)
    }

    /// Add the "pop-out" button to the title bar's upper-right corner as a
    /// borderless symbol button (Outlook-style). It hands the raw .prf to
    /// the user's default editor via openPrfFile(_:).
    /// Hand-drawn "open in external editor" glyph: a rounded box with an
    /// open top-right corner and an arrow shooting out through it. SF
    /// Symbols only offers an arrow *inside* a closed square, which doesn't
    /// read as "pop out", so we draw our own template image.
    private static func popOutGlyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            // Box, open at the top-right corner.
            let box = NSBezierPath()
            box.lineWidth = 1.6
            box.lineCapStyle = .round
            box.lineJoinStyle = .round
            box.move(to: NSPoint(x: 8.5, y: 13.5))   // top edge, left of opening
            box.line(to: NSPoint(x: 4, y: 13.5))     // top-left
            box.line(to: NSPoint(x: 4, y: 4))        // left → bottom-left
            box.line(to: NSPoint(x: 13.5, y: 4))     // bottom → bottom-right
            box.line(to: NSPoint(x: 13.5, y: 8.5))   // right edge, below opening
            box.stroke()
            // Arrow shooting out through the open corner.
            let arrow = NSBezierPath()
            arrow.lineWidth = 1.6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 8, y: 8))
            arrow.line(to: NSPoint(x: 15, y: 15))    // shaft to upper-right
            arrow.move(to: NSPoint(x: 10.5, y: 15))  // arrowhead barbs
            arrow.line(to: NSPoint(x: 15, y: 15))
            arrow.line(to: NSPoint(x: 15, y: 10.5))
            arrow.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    private func configurePopOutButton() {
        openPrfButton.image = Self.popOutGlyph()
        openPrfButton.imagePosition = .imageOnly
        openPrfButton.imageScaling = .scaleProportionallyDown
        openPrfButton.isBordered = false
        openPrfButton.bezelStyle = .regularSquare
        openPrfButton.contentTintColor = .controlAccentColor
        openPrfButton.target = self
        openPrfButton.action = #selector(openPrfFile(_:))
        openPrfButton.isEnabled = (initialProfileName != nil)
        openPrfButton.toolTip = initialProfileName != nil
            ? "Open this profile's .prf file in your default editor"
            : "Save the profile first to edit its .prf file directly."
        openPrfButton.setContentHuggingPriority(.required, for: .horizontal)
        openPrfButton.translatesAutoresizingMaskIntoConstraints = false
        openPrfButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        openPrfButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    // MARK: - Actions

    @objc private func addCommonIgnore(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem - 1   // item 0 is the "Add Common…" title
        guard idx >= 0, idx < Self.commonIgnores.count else { return }
        var lines = ignoreView.values
        for p in Self.commonIgnores[idx].patterns where !lines.contains(p) {
            lines.append(p)
        }
        ignoreView.values = lines
        sender.selectItem(at: 0)
    }

    @objc private func logToggled(_ sender: NSButton) {
        // Default folder + name show through as placeholders, so nothing to
        // pre-fill: blank fields mean "use the default".
        logNameField.placeholderString = defaultLogName()
        updateLogfileVisibility()
    }

    @objc private func browseLogFolder(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        let start = logFolderField.stringValue.trimmingCharacters(in: .whitespaces)
        panel.directoryURL = URL(fileURLWithPath:
            start.isEmpty ? SettingsModel.defaultLogDirectory()
                          : (start as NSString).expandingTildeInPath)
        let runIt: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.logFolderField.stringValue = url.path
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: runIt) }
        else { runIt(panel.runModal()) }
    }

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

    /// Open the profile's .prf in the user's default editor for that file
    /// type. Disabled for unsaved profiles. Warns first, since editing the
    /// file externally while this form is open means whichever is saved
    /// last wins.
    @objc private func openPrfFile(_ sender: NSButton) {
        guard let name = initialProfileName else { return }
        let url = profileURL(forName: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(text: "File not found",
                      info: "\(url.lastPathComponent) no longer exists on disk.",
                      style: .warning)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open \(url.lastPathComponent) in an external editor?"
        alert.informativeText = "Changes you make there and changes you make here both write the same file. Whichever is saved last wins. Close this editor with Cancel before saving externally to avoid overwriting your edits."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        let openIfConfirmed: (NSApplication.ModalResponse) -> Void = { resp in
            if resp == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: openIfConfirmed)
        } else {
            openIfConfirmed(alert.runModal())
        }
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

        // Validate a custom permission mask before writing anything.
        if permsPopup.indexOfSelectedItem == 2,
           !isValidPermsMask(permsMaskField.stringValue) {
            showAlert(text: "Invalid permission mask",
                      info: "Enter an octal (e.g. 0o755), hex (0x1FF), or decimal number, or choose a different Permissions option.",
                      style: .warning)
            return
        }

        // A key that has a dedicated section won't be saved from the
        // Advanced box (the section is authoritative). Rather than silently
        // drop it, stop and point the user to the right place.
        let strandedKeys = advancedView.values.compactMap { line -> String? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            return Self.handledKeys.contains(k) ? k : nil
        }
        if !strandedKeys.isEmpty {
            let list = Array(Set(strandedKeys)).sorted().joined(separator: ", ")
            showAlert(text: "Set these in their own section",
                      info: "These settings have a dedicated section and won't be saved from Advanced: \(list). Set them in the matching section (Roots, Ignore, File Attributes, or Options), then remove them from Advanced.",
                      style: .warning)
            return
        }

        // `include` directives have no `=`, so the Advanced reconciler would
        // silently drop them. Point the user to the Includes section instead.
        if advancedView.values.contains(where: {
            $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first == "include"
        }) {
            showAlert(text: "Manage includes in the Includes section",
                      info: "Move any include lines to the Includes section, where you can set each one's Top or Bottom position, then remove them from Advanced.",
                      style: .warning)
            return
        }

        // Names with spaces are fine: ProfileDocument escapes them on write
        // (`include File\ System\ Ignores`), which Unison reads back as one
        // word. No validation needed here.

        // Finding #7: if the user changed the includes AND this profile contains
        // unmanaged ordered content — pass-through directives (`source`/
        // `include?`/`source?`) OR any line the editor doesn't recognize — refuse
        // the save BEFORE touching the filesystem. Rebuilding includes could
        // reorder that content and silently change how preferences override each
        // other.
        if includeSaveDecision() == .refuseUnmanaged {
            showAlert(text: "Includes can't be edited here",
                      info: "This profile contains ordered lines the Includes section doesn't manage — for example source, include?, or source? directives, or other custom lines. Changing includes here could reorder them and alter how settings override each other. Use “Open .prf” to edit this profile in your text editor, then reload.",
                      style: .warning)
            return
        }

        let doc = formIntoDocument()
        let text = doc.serialized

        // Failure-safe, retry-consistent commit (Finding #11): backs up before
        // overwriting, writes the new file BEFORE removing the old on a rename
        // (original recoverable until the replacement is durable), and rolls a
        // failed rename back to the pre-save state. All filesystem side effects
        // happen here; controller identity + prefs are updated ONLY after this
        // succeeds, so a failure leaves a coherent state the user can retry.
        let tx = ProfileSaveTransaction(ops: SystemFileOps(), unisonDirectory: unisonDirectory)
        do {
            try tx.commit(oldName: isNew ? nil : initialProfileName, newName: name, content: text)
        } catch let error as ProfileSaveError {
            presentSaveError(error, name: name)
            return
        } catch {
            showAlert(text: "Failed to save profile",
                      info: "\(url.path):\n\(error.localizedDescription)", style: .critical)
            return
        }

        // --- Commit succeeded: update identity + preferences, then close. ---
        TraceLog.shared.write("ProfileForm: saved \(url.path) (\(text.count) bytes)")
        var prefs = ProfilePreferences.load()
        if isRename, let oldName = initialProfileName {
            // Carry view preferences (hide / order) across the rename so the
            // renamed profile stays in the same slot. See
            // ProfilePreferencesTests.test_rename_*.
            prefs.rename(oldName, to: name)
            TraceLog.shared.write("ProfileForm: renamed \(oldName) -> \(name)")
        }
        // Identity now reflects the committed name — a subsequent save in this
        // (still-open) window would target the right file.
        initialProfileName = name
        // Apply picker visibility for the final name (mirrors the Profile
        // Editor's eye toggle).
        if visibilityCheckbox.state == .on { prefs.hidden.remove(name) }
        else { prefs.hidden.insert(name) }
        prefs.save()
        onSaved(name)
        window?.performClose(nil)
    }

    /// Map a transactional save failure to a precise alert. In every case the
    /// on-disk state is coherent and the operation can be retried.
    private func presentSaveError(_ error: ProfileSaveError, name: String) {
        switch error {
        case .destinationExists:
            showAlert(text: "Profile already exists",
                      info: "\(name).prf is already in the Unison directory. Pick a different name.",
                      style: .warning)
        case .destinationBackupExists:
            showAlert(text: "A backup already exists at that name",
                      info: "\(name).prf.bak is already in the Unison directory. Renaming to “\(name)” would overwrite it, so nothing was changed. Remove or rename that backup, or pick a different name.",
                      style: .warning)
        case .backupFailed(let detail):
            showAlert(text: "Couldn't back up the existing profile",
                      info: "Nothing was changed. \(detail)", style: .critical)
        case .writeFailed(let detail):
            showAlert(text: "Failed to save profile",
                      info: "The existing profile is unchanged. \(detail)", style: .critical)
        case .renameCleanupFailed(let detail):
            showAlert(text: "Couldn't complete the rename",
                      info: "The profile was left under its original name. \(detail)",
                      style: .critical)
        case .rollbackFailed(let detail):
            showAlert(text: "The rename failed and could not be fully undone",
                      info: "The Unison directory may now contain both the old and the new profile. Check it before retrying. \(detail)",
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

// MARK: - Sidebar navigator

extension ProfileFormWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleSectionIndices.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let v = NSTableCellView()
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            iv.contentTintColor = .secondaryLabelColor
            v.addSubview(iv)
            v.imageView = iv
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: NSFont.systemFontSize)
            v.addSubview(tf)
            v.textField = tf
            v.identifier = id
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18),
                iv.heightAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            ])
            return v
        }()
        guard visibleSectionIndices.indices.contains(row) else { return cell }
        let s = sectionViews[visibleSectionIndices[row]]
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        cell.imageView?.image = NSImage(systemSymbolName: s.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        cell.textField?.stringValue = s.title
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SidebarRow")
        return tableView.makeView(withIdentifier: id, owner: self) as? HoverRowView
            ?? { let r = HoverRowView(); r.identifier = id; return r }()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // selectionHighlightStyle == .none means AppKit won't repaint the
        // old/new rows on its own; force it so our custom selection moves.
        redrawSidebarSelection()
        let r = sidebarTable.selectedRow
        guard visibleSectionIndices.indices.contains(r) else { return }
        showSection(visibleSectionIndices[r])
    }

    /// Recompute the visible rows from the search text, preserving the
    /// current selection when it survives the filter.
    private func filterSidebar() {
        let q = sidebarSearch.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let selectedIdx = sidebarTable.selectedRow >= 0
            && visibleSectionIndices.indices.contains(sidebarTable.selectedRow)
            ? visibleSectionIndices[sidebarTable.selectedRow] : nil
        // Match the section TITLE *and* the labels of the controls inside it,
        // so e.g. "fast" surfaces the Options section via its "Fast update
        // check" field. Title-only matching hid every field whose section
        // title didn't happen to contain the query.
        visibleSectionIndices = sectionViews.indices.filter {
            q.isEmpty
                || sectionViews[$0].title.lowercased().contains(q)
                || Self.sectionKeys(forTitle: sectionViews[$0].title).contains { $0.contains(q) }
                || Self.sectionContainsLabel(sectionViews[$0].view, query: q)
        }
        sidebarTable.reloadData()
        // Resolve which section to display: keep the current one if it still
        // matches, otherwise jump to the first match. Crucially, call
        // showSection — programmatic selectRowIndexes does NOT fire
        // tableViewSelectionDidChange, so without this the detail pane would
        // stay stuck on the pre-search section (the reported symptom: search
        // "fast", sidebar empties, but File Attributes stays on screen).
        let target = (selectedIdx.map(visibleSectionIndices.contains) == true)
            ? selectedIdx
            : visibleSectionIndices.first
        if let target, let row = visibleSectionIndices.firstIndex(of: target) {
            sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            showSection(target)
        } else {
            // No matches — clear the detail so it's unambiguously "no results"
            // rather than a stale section.
            sectionContainer.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    /// The technical Unison pref keys a section owns, so search matches
    /// e.g. "fastcheck" (the .prf key) as well as "Fast update check" (the
    /// visible label). Reuses the same key lists the load/save logic uses,
    /// so it can't drift from what each section actually edits. Lowercased
    /// for case-insensitive `contains` against the query.
    static func sectionKeys(forTitle title: String) -> [String] {
        let keys: [String]
        switch title {
        case "Roots":           keys = ["root"] + remoteKeys
        case "Paths":           keys = ["path"]
        case "Ignore":          keys = ["ignore", "ignorenot"]
        case "File Attributes": keys = attrKeys
        case "Options":         keys = optionKeys
        case "Includes":        keys = ["include"]
        default:                keys = []
        }
        return keys.map { $0.lowercased() }
    }

    /// True if any label-bearing control in `view`'s subtree contains
    /// `query` (already lowercased). Walks NSTextField labels (skipping
    /// editable fields so user-typed values like roots/paths don't match),
    /// NSButton titles (checkboxes), and NSPopUpButton item titles. Done
    /// on demand rather than precomputed so it's robust to controls whose
    /// titles are populated after section assembly.
    private static func sectionContainsLabel(_ view: NSView, query: String) -> Bool {
        if let pop = view as? NSPopUpButton {
            if pop.itemTitles.contains(where: { $0.lowercased().contains(query) }) { return true }
        } else if let field = view as? NSTextField, !field.isEditable {
            if field.stringValue.lowercased().contains(query) { return true }
        } else if let button = view as? NSButton {
            if button.title.lowercased().contains(query) { return true }
        }
        for sub in view.subviews where sectionContainsLabel(sub, query: query) { return true }
        return false
    }
}

extension ProfileFormWindowController: NSSearchFieldDelegate {
    // The search field and the two root fields all route here. Dispatch
    // on the sender: search filters the sidebar; a root change re-evaluates
    // the Remote Connection subsection's visibility.
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject === sidebarSearch {
            filterSidebar()
        } else {
            updateRemoteVisibility()
        }
    }
}

/// Sidebar row that draws its own rounded selection and hover highlights so
/// the two share identical geometry (Claude-style). Selection is "blue"
/// while the window is active (like a standard macOS sidebar) and falls back
/// to the unemphasized gray when it isn't.
final class HoverRowView: NSTableRowView {
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    /// Sidebars stay highlighted while the window is active, regardless of
    /// which control holds focus.
    private var active: Bool { window?.isKeyWindow ?? false }

    // Selection drives the cell's text/glyph color ourselves. With
    // selectionHighlightStyle == .none, AppKit never propagates an
    // emphasized background style to the cell, so we set it directly —
    // and crucially we do it in the draw cycle and on every isSelected
    // change, so the label turns white the instant the row is selected
    // (e.g. on mouse-down), not only after the selection notification.
    override var isSelected: Bool { didSet { needsDisplay = true; applyCellStyle() } }

    private func applyCellStyle() {
        let emphasized = isSelected && active
        let bg: NSView.BackgroundStyle = emphasized ? .emphasized : .normal
        let tint: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        for case let cell as NSTableCellView in subviews {
            if cell.backgroundStyle != bg { cell.backgroundStyle = bg }
            if cell.imageView?.contentTintColor != tint { cell.imageView?.contentTintColor = tint }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyCellStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        applyCellStyle()
        let r = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        if isSelected {
            (active ? NSColor.selectedContentBackgroundColor
                    : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            path.fill()
        } else if hovered {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            path.fill()
        }
    }
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

    /// Wrapped continuation lines indent under their entry's first line, so a
    /// long entry that wraps is visually distinct from separate entries.
    private let hangingStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 0
        p.headIndent = 18
        return p
    }()

    var values: [String] {
        get {
            textView.string
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            textView.string = newValue.joined(separator: "\n")
            if let ts = textView.textStorage {
                ts.addAttribute(.paragraphStyle, value: hangingStyle,
                                range: NSRange(location: 0, length: ts.length))
            }
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
        // Don't let the (required) width chain up to the window honor this
        // label's single-line intrinsic width — that grows the resizable
        // window. Low resistance → it wraps to the available width instead.
        helpField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        textView.defaultParagraphStyle = hangingStyle
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
            .paragraphStyle: hangingStyle,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Disable smart-paste shenanigans on path content.
        textView.isAutomaticLinkDetectionEnabled = false

        // Canonical NSTextView-in-NSScrollView geometry (see
        // ScrollableTextView). Without it these path fields drew but
        // never became first responder on click — effectively
        // non-editable — in the shipped (CI, SDK 15.5) build while fine
        // in local Debug. Wrap mode: path content scrolls vertically.
        ScrollableTextView.configure(text: textView, scroll: scrollView,
                                     mode: .wrap,
                                     initialSize: NSSize(width: 400, height: 80))
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

/// Structured editor for `include` directives. One row per included file: an
/// editable combo box (the existing .prf files, or a typed name) plus a
/// Top/Bottom position. There are only ever a few, so it's a plain row list
/// with an Add button rather than a text box.
@MainActor
final class IncludeListView: NSView {

    private let rowsStack = NSStackView()
    private let addButton = NSButton(title: "Add Include", target: nil, action: nil)
    private let existingNames: [String]
    var onChange: (() -> Void)?

    /// Each include as (file name, isTop, comment). Blank-name rows are
    /// dropped; comment is the optional line shown above the include.
    var entries: [(name: String, top: Bool, comment: String)] {
        get {
            rowsStack.arrangedSubviews.compactMap { row in
                guard let combo = row.viewWithTag(1) as? NSComboBox,
                      let popup = row.viewWithTag(2) as? NSPopUpButton else { return nil }
                let name = combo.stringValue.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                let comment = (row.viewWithTag(3) as? NSTextField)?
                    .stringValue.trimmingCharacters(in: .whitespaces) ?? ""
                return (name, popup.indexOfSelectedItem == 0, comment)
            }
        }
        set {
            rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for e in newValue { appendRow(makeRow(name: e.name, top: e.top, comment: e.comment)) }
        }
    }

    init(label: String, help: String, existingNames: [String]) {
        self.existingNames = existingNames
        super.init(frame: .zero)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let helpField = NSTextField(wrappingLabelWithString: help)
        helpField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpField.textColor = .secondaryLabelColor
        helpField.maximumNumberOfLines = 0
        helpField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        let addRow = NSStackView(views: [addButton, NSView()])
        addRow.orientation = .horizontal

        let outer = NSStackView(views: [labelField, helpField, rowsStack, addRow])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in [helpField, rowsStack, addRow] as [NSView] {
            v.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func appendRow(_ row: NSView) {
        rowsStack.addArrangedSubview(row)
        // Safe to pin width now: the row shares rowsStack as ancestor.
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func makeRow(name: String, top: Bool, comment: String) -> NSView {
        let commentField = NSTextField(string: comment)
        commentField.tag = 3
        commentField.placeholderString = "Comment (optional)"
        commentField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        commentField.delegate = self
        commentField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let combo = NSComboBox()
        combo.tag = 1
        combo.isEditable = true
        combo.completes = true
        combo.addItems(withObjectValues: existingNames)
        combo.stringValue = name
        combo.target = self
        combo.action = #selector(rowChanged)
        combo.delegate = self
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        combo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let popup = NSPopUpButton()
        popup.tag = 2
        popup.addItems(withTitles: ["Top", "Bottom"])
        popup.selectItem(at: top ? 0 : 1)
        popup.target = self
        popup.action = #selector(rowChanged)
        popup.setContentHuggingPriority(.required, for: .horizontal)

        let removeCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let remove = NSButton(
            image: NSImage(systemSymbolName: "minus.circle",
                           accessibilityDescription: "Remove")?
                .withSymbolConfiguration(removeCfg) ?? NSImage(),
            target: self, action: #selector(removeTapped(_:)))
        remove.isBordered = false
        remove.bezelStyle = .regularSquare
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove this include"
        remove.setContentHuggingPriority(.required, for: .horizontal)
        remove.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let controls = NSStackView(views: [combo, popup, remove])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.distribution = .fill
        combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        // The comment sits on its own line above the file + position row,
        // prefixed with a "#" so it reads as a comment even when filled in.
        let hash = NSTextField(labelWithString: "#")
        hash.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        hash.textColor = .secondaryLabelColor
        hash.setContentHuggingPriority(.required, for: .horizontal)
        let commentRow = NSStackView(views: [hash, commentField])
        commentRow.orientation = .horizontal
        commentRow.spacing = 4
        commentRow.distribution = .fill

        let row = NSStackView(views: [commentRow, controls])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        commentRow.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    @objc private func addTapped() {
        appendRow(makeRow(name: "", top: true, comment: ""))
        onChange?()
    }

    @objc private func removeTapped(_ sender: NSButton) {
        // Walk up to the row that's a direct arranged subview of rowsStack.
        var v: NSView? = sender
        while let cur = v, cur.superview !== rowsStack { v = cur.superview }
        v?.removeFromSuperview()
        onChange?()
    }

    @objc private func rowChanged(_ sender: Any?) { onChange?() }
}

extension IncludeListView: NSComboBoxDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Spaces in include names are fine now — they're backslash-escaped on
        // write (see ProfileDocument.escapeWord), so no inline validation.
        onChange?()
    }
}
