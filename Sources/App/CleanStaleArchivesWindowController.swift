import AppKit
import UniformTypeIdentifiers

/// A resizable review window listing the archives no current profile uses
/// (see `ArchiveStaleScanner`). The user can check/uncheck individual
/// rows, see exactly which files and roots each archive covers and which
/// profile (if any) it belongs to, export the list as CSV, and move the
/// checked ones to the Trash. Recoverable (Trash, never delete). Live
/// archives are never listed.
final class CleanStaleArchivesWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    /// One stale archive (an `ar<hash>` plus its `fp/tm/sc` siblings (never the lock lk)).
    struct Row {
        let hash: String
        let reason: ArchiveStaleScanner.Reason
        let profileNames: [String]
        let uncertain: Bool
        /// This Mac's root (the archive's `thisRoot`).
        let root1: String
        /// The paired (other) root.
        let root2: String
        let files: [(url: URL, bytes: Int64)]
        /// Modification time of the `ar` file (informational only).
        let modified: Date?
        /// Whether this row is checked by default. True only when the
        /// archive is provably this machine's own dead state — owned by an
        /// existing local profile (a superseded copy) or a local-only sync
        /// (both roots this Mac). Cross-machine orphans start unchecked
        /// because this Mac could be the *remote* for another machine's
        /// (possibly infrequent) sync.
        let defaultChecked: Bool
        /// Whether this row may be acted on at all. False for anything not
        /// provably safe to remove — uncertain, remote, ambiguous, orphan, or a
        /// "probably old" copy with no live archive to supersede it. A
        /// non-actionable row's checkbox is disabled, Select All skips it, and
        /// the mutation authority rejects it even if stale UI state says checked.
        let actionable: Bool
        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
        var fileNames: String { files.map { $0.url.lastPathComponent }.joined(separator: ", ") }
        var profileText: String {
            profileNames.isEmpty ? "(no profile)" : profileNames.joined(separator: ", ")
        }
    }

    // Preselection is now driven solely by `ArchiveStaleScanner.Finding.actionable`
    // (a provably-superseded, certain, local disposition) folded with global
    // enumeration success — see `scan()`. The former `defaultsToChecked` /
    // `isLocalOnly` heuristics (which preselected local-only orphans) are gone:
    // orphans and "probably old" copies are non-actionable, never preselected.

    /// Called when the window closes so the opener can drop its reference.
    var onClose: (() -> Void)?

    private let unisonDirectory: String
    private var rows: [Row] = []
    /// Parallel to `rows`; whether each row is checked for deletion.
    private var checked: [Bool] = []
    /// Observer for engine activity changes, so the Trash button re-gates
    /// live if a background sync/scan starts or finishes while this window
    /// is open. Removed in `deinit`. `nonisolated(unsafe)`: written once on
    /// the main actor in `init`, read only in the single-threaded `deinit`;
    /// `NotificationCenter.removeObserver` is itself thread-safe.
    private nonisolated(unsafe) var engineActivityObserver: NSObjectProtocol?
    /// Guards against acting on a pre-operation stale classification: any
    /// engine activity since the last scan forces a re-scan before the Trash
    /// button re-enables.
    private var snapshotGuard = StaleSnapshotGuard()

    /// Global attribution state from the last scan: whether the Unison
    /// directory could be enumerated at all, and which profiles resolved with
    /// unreliable includes. Drives the warning banner.
    private struct ProfileScan {
        let profiles: [ArchiveStaleScanner.Profile]
        /// True when the Unison directory itself couldn't be enumerated, so the
        /// full profile set is unknown and every archive must stay uncertain.
        let enumerationFailed: Bool
        /// Profiles whose `include`/`source` graph did not resolve reliably
        /// (missing/unreadable include, cycle, malformed line, bound hit).
        let unresolvedProfiles: [String]
    }
    private var lastProfileScan: ProfileScan?

    private let tableView = NSTableView()
    private let selectAllCheckbox = NSButton(
        checkboxWithTitle: "Select all", target: nil, action: nil)
    /// Orange banner shown only when attribution is globally compromised
    /// (directory unreadable, or profiles with unresolved/unreadable includes).
    /// Collapses to zero height when there is nothing to warn about.
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private var warningZeroHeight: NSLayoutConstraint?
    private let summaryLabel = NSTextField(labelWithString: "")
    private let trashButton = NSButton(title: "", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export CSV…", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let byteFmt = ByteCountFormatter()
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private enum Col {
        static let check = NSUserInterfaceItemIdentifier("check")
        static let files = NSUserInterfaceItemIdentifier("files")
        static let profile = NSUserInterfaceItemIdentifier("profile")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let root1 = NSUserInterfaceItemIdentifier("root1")
        static let root2 = NSUserInterfaceItemIdentifier("root2")
    }

    init(unisonDirectory: String) {
        self.unisonDirectory = unisonDirectory
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Clean Stale Archives"
        window.minSize = NSSize(width: 720, height: 320)
        super.init(window: window)
        window.delegate = self
        window.center()
        configure()
        reload()
        // Deliver on `.main` and enter the main actor SYNCHRONOUSLY: the
        // notification carries no payload, so the handler must read the engine
        // state right now, while it still reflects the transition that fired
        // this callback. An async hop (Task) could run after a later busy→idle
        // transition completes, letting StaleSnapshotGuard miss the busy phase.
        engineActivityObserver = NotificationCenter.default.addObserver(
            forName: .engineActivityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engineActivityChanged()
            }
        }
    }

    /// React to an engine-activity transition. Any activity dirties the stale
    /// classification; once the engine is idle again with a dirty snapshot we
    /// re-scan (so the user can never trash a pre-operation classification),
    /// otherwise we just re-gate the button.
    private func engineActivityChanged() {
        let idle = ArchiveMutationGate.isAllowed(NSApp.delegate as? EngineActivityProviding)
        snapshotGuard.observedActivity(engineIdle: idle)
        if snapshotGuard.shouldReload(engineIdle: idle) {
            reload()   // re-scans; reload() calls didScan() to clear the guard
        } else {
            refreshSelectionUI()
        }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        if let engineActivityObserver {
            NotificationCenter.default.removeObserver(engineActivityObserver)
        }
    }

    /// Whether the most recent scan found anything (lets the opener skip
    /// showing an empty window).
    var hasStaleArchives: Bool { !rows.isEmpty }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [onClose] in onClose?() }
    }

    // MARK: - Layout

    private func configure() {
        guard let content = window?.contentView else { return }

        let header = NSTextField(wrappingLabelWithString:
            "These archives are not used by any current profile. Only rows that " +
            "are provably a superseded copy (replaced by a current profile's live " +
            "archive) can be selected; they move to the Trash (recoverable). " +
            "Everything else — orphans, possible other-machine syncs, remote or " +
            "ambiguous archives — is shown for review only and cannot be selected. " +
            "Live archives (what each profile's next sync uses) are never listed.")
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        warningLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningLabel.textColor = .systemOrange
        warningLabel.isHidden = true
        warningLabel.translatesAutoresizingMaskIntoConstraints = false

        selectAllCheckbox.allowsMixedState = true
        selectAllCheckbox.target = self
        selectAllCheckbox.action = #selector(toggleSelectAll(_:))
        selectAllCheckbox.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addColumn(Col.check, title: "", width: 26, fixed: true)
        addColumn(Col.files, title: "Archive files", width: 220)
        addColumn(Col.profile, title: "Profile", width: 150)
        addColumn(Col.size, title: "Size", width: 80)
        addColumn(Col.modified, title: "Last modified", width: 110)
        addColumn(Col.root1, title: "Root 1 (this Mac)", width: 240)
        addColumn(Col.root2, title: "Root 2", width: 240)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        // The last column (Root 2) absorbs extra width; others stay put.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for button in [exportButton, trashButton, closeButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        exportButton.action = #selector(exportCSVAction(_:))
        trashButton.action = #selector(trashAction(_:))
        trashButton.hasDestructiveAction = true
        closeButton.action = #selector(closeAction(_:))
        closeButton.keyEquivalent = "\u{1b}"

        let footer = NSStackView(views: [NSView(), exportButton, trashButton, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(warningLabel)
        content.addSubview(selectAllCheckbox)
        content.addSubview(summaryLabel)
        content.addSubview(scroll)
        content.addSubview(footer)
        let m: CGFloat = 16
        let warningZero = warningLabel.heightAnchor.constraint(equalToConstant: 0)
        warningZero.isActive = true          // collapsed until a warning appears
        self.warningZeroHeight = warningZero
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            warningLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            warningLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            warningLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            selectAllCheckbox.topAnchor.constraint(equalTo: warningLabel.bottomAnchor, constant: 10),
            selectAllCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            summaryLabel.centerYAnchor.constraint(equalTo: selectAllCheckbox.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            summaryLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: selectAllCheckbox.trailingAnchor, constant: 8),

            scroll.topAnchor.constraint(equalTo: selectAllCheckbox.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
        ])
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier,
                           title: String, width: CGFloat, fixed: Bool = false) {
        let col = NSTableColumn(identifier: id)
        col.title = title
        col.width = width
        col.minWidth = fixed ? width : max(60, width * 0.5)
        if fixed { col.maxWidth = width }
        tableView.addTableColumn(col)
    }

    // MARK: - Data

    private func reload() {
        rows = scan()
        refreshWarning()
        // Record the scan against the staleness guard: a scan taken while the
        // engine is busy is immediately dirty, so the button stays disabled
        // until a clean re-scan happens at idle.
        let idle = ArchiveMutationGate.isAllowed(NSApp.delegate as? EngineActivityProviding)
        snapshotGuard.didScan(engineIdle: idle)
        // Default selection is topology-based, not time-based: only
        // provably-own dead archives start checked (see Row.defaultChecked).
        checked = rows.map { $0.defaultChecked }
        tableView.reloadData()
        let archiveCount = rows.count
        let fileCount = rows.reduce(0) { $0 + $1.files.count }
        let total = byteFmt.string(fromByteCount: rows.reduce(0) { $0 + $1.bytes })
        let reviewCount = rows.filter { !$0.defaultChecked }.count
        let reviewNote = reviewCount > 0
            ? "  ·  \(reviewCount) left unchecked for review" : ""
        summaryLabel.stringValue = rows.isEmpty
            ? "No stale archives. Every archive belongs to a current profile."
            : "\(archiveCount) archive\(archiveCount == 1 ? "" : "s"), " +
              "\(fileCount) file\(fileCount == 1 ? "" : "s"), \(total)\(reviewNote)"
        selectAllCheckbox.isEnabled = !rows.isEmpty
        exportButton.isEnabled = !rows.isEmpty
        refreshSelectionUI()
    }

    /// Update the orange warning banner from the last scan's global attribution
    /// state, collapsing it when there is nothing to warn about.
    private func refreshWarning() {
        let text = Self.attributionWarning(
            enumerationFailed: lastProfileScan?.enumerationFailed ?? false,
            unresolvedProfiles: lastProfileScan?.unresolvedProfiles ?? [])
        if let text {
            warningLabel.stringValue = text
            warningLabel.isHidden = false
            warningZeroHeight?.isActive = false
        } else {
            warningLabel.stringValue = ""
            warningLabel.isHidden = true
            warningZeroHeight?.isActive = true
        }
    }

    /// The banner text for globally-compromised attribution, or nil when
    /// attribution is fully trustworthy. Pure so it can be unit-tested.
    static func attributionWarning(enumerationFailed: Bool,
                                   unresolvedProfiles: [String]) -> String? {
        var parts: [String] = []
        if enumerationFailed {
            parts.append(
                "The Unison directory could not be read, so the full set of " +
                "profiles is unknown. Every archive is shown as uncertain and " +
                "none are preselected. Verify before removing anything.")
        }
        if !unresolvedProfiles.isEmpty {
            let names = unresolvedProfiles.sorted().joined(separator: ", ")
            parts.append(
                "Some profiles have unresolved or unreadable includes (\(names)), " +
                "so their roots can't be fully trusted. Archives that might " +
                "belong to them are shown as uncertain.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// A row is uncertain if its own attribution is uncertain OR attribution is
    /// globally compromised (the directory couldn't be enumerated, so we don't
    /// actually know the profile set). Pure so it can be unit-tested.
    static func rowUncertain(findingUncertain: Bool, globalUncertain: Bool) -> Bool {
        findingUncertain || globalUncertain
    }

    private func scan() -> [Row] {
        let cleanup = ArchiveCleanup(unisonDirectory: unisonDirectory)
        let index = cleanup.indexArchives()
        let ps = profileScan()
        lastProfileScan = ps
        let findings = ArchiveStaleScanner.findings(
            in: index, profiles: ps.profiles, localHostname: ArchiveHash.systemHostname)
        let fm = FileManager.default
        return findings
            .sorted { a, b in
                let aOrphan = a.reason == .orphan, bOrphan = b.reason == .orphan
                if aOrphan != bOrphan { return !aOrphan }   // attributed first
                let ap = a.profileNames.joined(separator: ", ")
                let bp = b.profileNames.joined(separator: ", ")
                if ap != bp { return ap < bp }
                return a.entry.rootsName < b.entry.rootsName
            }
            .map { finding -> Row in
                let comps = finding.entry.rootsName.components(separatedBy: ", ")
                let r1 = finding.entry.thisRoot
                let r2 = comps.first(where: { $0 != r1 }) ?? comps.last ?? ""
                let files = cleanup.findFiles(matching: finding.entry.hash).map { url -> (URL, Int64) in
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    return (url, (attrs?[.size] as? NSNumber)?.int64Value ?? 0)
                }
                let modified = (try? fm.attributesOfItem(atPath: finding.entry.url.path))?[.modificationDate] as? Date
                // Fold in global uncertainty: if the directory couldn't be
                // enumerated we don't know the true profile set, so no archive
                // may be treated as a confident orphan or preselected.
                let uncertain = Self.rowUncertain(
                    findingUncertain: finding.uncertain,
                    globalUncertain: ps.enumerationFailed)
                // Actionable ONLY when the scanner proved it superseded AND the
                // profile set is fully known. Everything else is report-only:
                // non-actionable in the UI and rejected by the mutation authority.
                let actionable = finding.actionable && !ps.enumerationFailed
                return Row(hash: finding.entry.hash,
                           reason: finding.reason,
                           profileNames: finding.profileNames,
                           uncertain: uncertain,
                           root1: r1, root2: r2, files: files,
                           modified: modified, defaultChecked: actionable,
                           actionable: actionable)
            }
    }

    /// Each current profile (name + `root = …` values), with an
    /// `attributionReliable` flag. Attribution is unreliable when path
    /// matching can't be trusted: the profile uses `rootalias` (real roots
    /// differ from the .prf), has a symlinked local root (canonical path
    /// differs), or is a home-dir ssh profile sharing its local root with
    /// another profile (the remote can't disambiguate them offline).
    private func profileScan() -> ProfileScan {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: unisonDirectory) else {
            // The Unison directory can't be enumerated. Returning an empty
            // profile set would make EVERY archive look like a certain orphan
            // and preselect the local-only ones for deletion, from a scan that
            // simply failed to read the profiles. Signal global uncertainty
            // instead: the caller marks every row uncertain and preselects
            // none, and the banner explains why.
            return ProfileScan(profiles: [], enumerationFailed: true, unresolvedProfiles: [])
        }

        struct Raw {
            let name: String
            let roots: [String]
            let usesRootalias: Bool
            /// False when the profile's directives couldn't be resolved cleanly
            /// (missing/unreadable include, cycle, malformed line, bound hit) —
            /// its roots can't be trusted, so attribution must stay uncertain.
            let resolutionReliable: Bool
        }
        let raws: [Raw] = names
            .filter { ($0 as NSString).pathExtension == "prf" }
            .map { name -> Raw in
                let profileName = (name as NSString).deletingPathExtension
                // Resolve `include`/`source`/`include?`/`source?` recursively so
                // a profile whose roots live in an included file is attributed
                // correctly (Finding #9). Conservative: any resolution ambiguity
                // ⇒ `reliable == false` ⇒ the profile's archives stay uncertain.
                let resolution = ProfileRootResolver.resolve(
                    unisonDirectory: unisonDirectory, profile: profileName)
                return Raw(name: profileName,
                           roots: resolution.roots,
                           usesRootalias: !resolution.rootaliases.isEmpty,
                           resolutionReliable: resolution.reliable)
            }

        // Count how many profiles use each local root path (to detect a
        // shared local root).
        var localPathCount: [String: Int] = [:]
        for raw in raws {
            for spec in ArchiveMatcher.rootSpecs(forRoots: raw.roots) where spec.isLocal {
                if let p = spec.path { localPathCount[p, default: 0] += 1 }
            }
        }

        let profiles = raws.map { raw -> ArchiveStaleScanner.Profile in
            let specs = ArchiveMatcher.rootSpecs(forRoots: raw.roots)
            let localPaths = specs.filter { $0.isLocal }.compactMap { $0.path }
            let hasWildcardRemote = specs.contains { $0.path == nil }
            let hasSymlinkRoot = localPaths.contains { Self.isLeafSymlink($0) }
            let sharesLocalRoot = localPaths.contains { (localPathCount[$0] ?? 0) > 1 }
            let reliable = raw.resolutionReliable
                           && !(raw.usesRootalias
                                || hasSymlinkRoot
                                || (hasWildcardRemote && sharesLocalRoot))
            return ArchiveStaleScanner.Profile(
                name: raw.name, roots: raw.roots, attributionReliable: reliable)
        }
        // Surface specifically the profiles whose INCLUDE graph didn't resolve
        // (missing/unreadable include, cycle, malformed line, bound) — the case
        // Finding #9 is about — separate from the broader attribution caveats
        // (rootalias/symlink/shared-root) which the per-row tooltip already
        // explains.
        let unresolved = raws.filter { !$0.resolutionReliable }.map { $0.name }
        return ProfileScan(profiles: profiles,
                           enumerationFailed: false,
                           unresolvedProfiles: unresolved)
    }

    private static func isLeafSymlink(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: expanded)) != nil
    }

    // MARK: - Selection

    @objc private func toggleSelectAll(_ sender: NSButton) {
        // Select All operates ONLY on actionable rows; non-actionable rows can
        // never be selected (report-only). See CleanStalePolicy.
        let actionableIdx = CleanStalePolicy.selectableIndices(actionable: rows.map(\.actionable))
        let target = !actionableIdx.allSatisfy { checked[$0] }   // any actionable unchecked → check all
        for i in actionableIdx { checked[i] = target }
        tableView.reloadData()
        refreshSelectionUI()
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let row = sender.tag
        // Authority: a non-actionable row can never become checked, even via a
        // programmatic/keyboard path.
        guard checked.indices.contains(row), rows[row].actionable else { return }
        checked[row] = (sender.state == .on)
        refreshSelectionUI()
    }

    private func refreshSelectionUI() {
        var checkedFiles = 0
        for i in rows.indices where checked[i] { checkedFiles += rows[i].files.count }
        trashButton.title =
            "Move \(checkedFiles) File\(checkedFiles == 1 ? "" : "s") to Trash"
        // Gate on a non-empty selection, the engine-idle policy, AND a
        // trustworthy (non-dirty) snapshot. The final `trashAction` rechecks,
        // but disabling here gives the user immediate feedback that the action
        // is unavailable while Unison runs or before a stale snapshot re-scans.
        let engineIdle = ArchiveMutationGate.isAllowed(NSApp.delegate as? EngineActivityProviding)
        trashButton.isEnabled = checkedFiles > 0 && snapshotGuard.mayTrash(engineIdle: engineIdle)
        trashButton.toolTip = engineIdle ? nil : ArchiveMutationGate.busyMessage
        // Select-All state reflects only actionable rows (the only selectable set).
        let actionableIdx = CleanStalePolicy.selectableIndices(actionable: rows.map(\.actionable))
        if actionableIdx.isEmpty || actionableIdx.allSatisfy({ !checked[$0] }) {
            selectAllCheckbox.state = .off
        } else if actionableIdx.allSatisfy({ checked[$0] }) {
            selectAllCheckbox.state = .on
        } else {
            selectAllCheckbox.state = .mixed
        }
        selectAllCheckbox.isEnabled = !actionableIdx.isEmpty
    }

    // MARK: - Actions

    @objc private func trashAction(_ sender: Any?) {
        // Only actionable + checked rows are eligible; a non-actionable row is
        // rejected here even if stale UI state marked it checked (authority).
        let hashes = CleanStalePolicy.mutationHashes(
            hashes: rows.map(\.hash), actionable: rows.map(\.actionable), checked: checked)
        guard !hashes.isEmpty else { NSSound.beep(); return }

        // Recheck the engine-idle policy AND the snapshot guard immediately
        // before mutating (UI-level gate; the transaction re-checks under lock).
        let idle = ArchiveMutationGate.isAllowed(NSApp.delegate as? EngineActivityProviding)
        guard snapshotGuard.mayTrash(engineIdle: idle) else {
            if snapshotGuard.shouldReload(engineIdle: idle) { reload() } else { refreshSelectionUI() }
            ArchiveMutationGate.presentBusyRefusal(
                title: "Can’t clean archives right now", on: window)
            return
        }

        // The exact payload family the user reviewed (basenames of the checked,
        // actionable rows). The transaction derives the family again UNDER the
        // locks; if it differs from this — e.g. an external Unison added a
        // sibling in the meantime — we refuse and refresh (Blocker 2).
        let reviewedPayloads = Set(rows.indices
            .filter { checked.indices.contains($0) && checked[$0] && rows[$0].actionable }
            .flatMap { rows[$0].files.map(\.url.lastPathComponent) })

        // Route through the SINGLE mutation authority: acquire each archive's
        // real interprocess lock, derive + stage the family (never lk) via
        // rename(2) UNDER the locks, then Trash the staged set as one unit.
        // `revalidate` confirms every planned hash is still actionable AND the
        // under-lock family matches what was reviewed; otherwise nothing is touched.
        let result = ArchiveMaintenance.mutate(
            operation: "clean-stale", hashes: hashes, unisonDirectory: unisonDirectory,
            isEngineIdle: { ArchiveMutationGate.isAllowed(NSApp.delegate as? EngineActivityProviding) },
            revalidate: { [weak self] plan in
                guard let self else { return false }
                let stillActionable = Set(self.scan().filter { $0.actionable }.map(\.hash))
                return Set(hashes).isSubset(of: stillActionable)
                    && Set(plan.payloadFiles) == reviewedPayloads
            })
        reload()

        switch result {
        case .success(let outcome):
            TraceLog.shared.write("CleanStale: mutated \(outcome.hashes.count) archive(s)"
                + (outcome.quarantineRetained.map { "; quarantine retained at \($0)" } ?? ""))
            let a = NSAlert()
            switch outcome.disposition {
            case .clean:
                return
            case .lockFreeLeftover(let q):
                a.alertStyle = .warning
                a.messageText = "Archives removed, but the quarantine couldn’t be emptied"
                a.informativeText = ArchiveMutationOutcome.lockFreeLeftoverBody(q)
            case .blockedByLock(let q, _):
                (NSApp.delegate as? ArchiveBlockCoordinating)?.refreshBlockedArchiveState()
                a.alertStyle = .critical
                a.messageText = "Archives removed, but a lock is still held"
                a.informativeText = ArchiveMutationOutcome.blockedByLockBody(q)
            }
            a.addButton(withTitle: "OK")
            if let window { a.beginSheetModal(for: window) { _ in } } else { a.runModal() }
        case .failure(let error):
            TraceLog.shared.write("CleanStale: mutation refused — \(error)")
            let a = NSAlert()
            a.alertStyle = .informational
            a.messageText = "Nothing was moved"
            a.informativeText = Self.mutationRefusalText(error)
            a.addButton(withTitle: "OK")
            if let window { a.beginSheetModal(for: window) { _ in } } else { a.runModal() }
        }
    }

    /// Human-readable reason a mutation refused. Every case is fail-closed —
    /// nothing was removed and the originals are intact.
    static func mutationRefusalText(_ error: Error) -> String {
        guard let e = error as? ArchiveMutationError else {
            return "The archives were left untouched; the originals are intact."
        }
        switch e {
        case .engineNotIdle:
            return "Unison became busy, so the archives were left untouched. Try again when it’s idle."
        case .lockUnavailable:
            return "Another Unison process holds a lock on one of these archives, so nothing was removed. Close other Unison instances and try again."
        case .revalidationFailed:
            return "The set of stale archives changed since you reviewed it, so nothing was moved. The list has been refreshed; review and try again."
        case .beginStagingFailed, .stagingFailed:
            return "Preparing to move the archives failed, so nothing was removed. The originals are intact."
        case .rollbackIncomplete(let quarantine):
            return "An archive move was interrupted and could not be fully undone. "
                + "Nothing was deleted and the archives' locks are still held (so "
                + "Unison stays blocked). Quit any other Unison, then recover the "
                + "files here without deleting the locks:\n\n\(quarantine)"
        }
    }

    @objc private func exportCSVAction(_ sender: Any?) {
        guard !rows.isEmpty, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.title = "Export Stale Archive List"
        panel.nameFieldStringValue = "stale-archives.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.csv().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let fail = NSAlert()
                fail.alertStyle = .warning
                fail.messageText = "Couldn't save the CSV"
                fail.informativeText = error.localizedDescription
                fail.addButton(withTitle: "OK")
                fail.beginSheetModal(for: window) { _ in }
            }
        }
    }

    /// One row per file, so the CSV records exactly what would be trashed.
    /// Each replica root is its own column.
    private func csv() -> String {
        var lines = ["File,Profile,Reason,Size (bytes),Root 1,Root 2"]
        for row in rows {
            let reason = (row.reason == .orphan ? "orphan" : "superseded")
                + (row.uncertain ? " (uncertain)" : "")
            let profile = row.profileNames.joined(separator: "; ")
            for file in row.files {
                lines.append([
                    Self.csvField(file.url.lastPathComponent),
                    Self.csvField(profile),
                    Self.csvField(reason),
                    Self.csvField(String(file.bytes)),
                    Self.csvField(row.root1),
                    Self.csvField(row.root2),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC-4180 field quoting: wrap in quotes (doubling embedded quotes)
    /// when the value contains a comma, quote, or newline.
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    @objc private func closeAction(_ sender: Any?) {
        window?.close()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let item = rows[row]
        switch tableColumn?.identifier {
        case Col.check:
            return checkboxCell(row: row)
        case Col.files:
            return labelCell(item.fileNames, monospaced: true, tooltip: item.fileNames)
        case Col.profile:
            let text = item.profileText + (item.uncertain ? " ?" : "")
            let tip = item.uncertain
                ? "Attribution uncertain: a profile has unresolved or unreadable " +
                  "includes, uses rootalias, has a symlinked root, shares a local " +
                  "root, or the Unison directory couldn't be read, so this may be " +
                  "wrong. Verify before relying on it."
                : (item.profileNames.isEmpty ? item.reason.label : item.profileText)
            let cell = labelCell(text, tooltip: tip)
            cell.textField?.textColor =
                (item.profileNames.isEmpty || item.uncertain) ? .systemOrange : .labelColor
            return cell
        case Col.size:
            let cell = labelCell(byteFmt.string(fromByteCount: item.bytes), tooltip: nil)
            cell.textField?.alignment = .right
            return cell
        case Col.modified:
            let text = item.modified.map { dateFmt.string(from: $0) } ?? "unknown"
            return labelCell(text, tooltip: "Informational only; not used to decide what is safe to remove.")
        case Col.root1:
            return labelCell(item.root1, tooltip: item.root1, truncateMiddle: true)
        case Col.root2:
            return labelCell(item.root2, tooltip: item.root2, truncateMiddle: true)
        default:
            return nil
        }
    }

    private func checkboxCell(row: Int) -> NSView {
        let cell = NSTableCellView()
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
        box.tag = row
        // Non-actionable (report-only) rows are visibly disabled — they can't be
        // checked at all — and carry a tooltip explaining why.
        box.isEnabled = rows.indices.contains(row) && rows[row].actionable
        if rows.indices.contains(row) {
            box.toolTip = CleanStalePolicy.refusalReason(
                actionable: rows[row].actionable, uncertain: rows[row].uncertain,
                reason: rows[row].reason)
        }
        box.state = (checked.indices.contains(row) && checked[row]) ? .on : .off
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func labelCell(_ text: String,
                           monospaced: Bool = false,
                           tooltip: String?,
                           truncateMiddle: Bool = false) -> NSTableCellView {
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = truncateMiddle ? .byTruncatingMiddle : .byTruncatingTail
        field.toolTip = tooltip
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
