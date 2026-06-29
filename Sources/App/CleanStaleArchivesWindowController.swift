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

    /// One stale archive (an `ar<hash>` plus its `fp/lk/tm/sc` siblings).
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
        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
        var fileNames: String { files.map { $0.url.lastPathComponent }.joined(separator: ", ") }
        var profileText: String {
            profileNames.isEmpty ? "(no profile)" : profileNames.joined(separator: ", ")
        }
    }

    /// Called when the window closes so the opener can drop its reference.
    var onClose: (() -> Void)?

    private let unisonDirectory: String
    private var rows: [Row] = []
    /// Parallel to `rows`; whether each row is checked for deletion.
    private var checked: [Bool] = []

    private let tableView = NSTableView()
    private let selectAllCheckbox = NSButton(
        checkboxWithTitle: "Select all", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let trashButton = NSButton(title: "", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export CSV…", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let byteFmt = ByteCountFormatter()

    private enum Col {
        static let check = NSUserInterfaceItemIdentifier("check")
        static let files = NSUserInterfaceItemIdentifier("files")
        static let profile = NSUserInterfaceItemIdentifier("profile")
        static let size = NSUserInterfaceItemIdentifier("size")
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
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

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
            "These archives are not used by any current profile. Checked " +
            "rows move to the Trash (recoverable). Live archives — what " +
            "each profile's next sync uses — are never listed here.")
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

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
        content.addSubview(selectAllCheckbox)
        content.addSubview(summaryLabel)
        content.addSubview(scroll)
        content.addSubview(footer)
        let m: CGFloat = 16
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            selectAllCheckbox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
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
        checked = Array(repeating: true, count: rows.count)
        tableView.reloadData()
        let archiveCount = rows.count
        let fileCount = rows.reduce(0) { $0 + $1.files.count }
        let total = byteFmt.string(fromByteCount: rows.reduce(0) { $0 + $1.bytes })
        let uncertainCount = rows.filter { $0.uncertain }.count
        let uncertainNote = uncertainCount > 0
            ? "  ·  \(uncertainCount) uncertain (marked ?)" : ""
        summaryLabel.stringValue = rows.isEmpty
            ? "No stale archives. Every archive belongs to a current profile."
            : "\(archiveCount) archive\(archiveCount == 1 ? "" : "s"), " +
              "\(fileCount) file\(fileCount == 1 ? "" : "s"), \(total)\(uncertainNote)"
        selectAllCheckbox.isEnabled = !rows.isEmpty
        exportButton.isEnabled = !rows.isEmpty
        refreshSelectionUI()
    }

    private func scan() -> [Row] {
        let cleanup = ArchiveCleanup(unisonDirectory: unisonDirectory)
        let index = cleanup.indexArchives()
        let findings = ArchiveStaleScanner.findings(
            in: index, profiles: profiles(), localHostname: ArchiveHash.systemHostname)
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
                return Row(hash: finding.entry.hash,
                           reason: finding.reason,
                           profileNames: finding.profileNames,
                           uncertain: finding.uncertain,
                           root1: r1, root2: r2, files: files)
            }
    }

    /// Each current profile (name + `root = …` values), with an
    /// `attributionReliable` flag. Attribution is unreliable when path
    /// matching can't be trusted: the profile uses `rootalias` (real roots
    /// differ from the .prf), has a symlinked local root (canonical path
    /// differs), or is a home-dir ssh profile sharing its local root with
    /// another profile (the remote can't disambiguate them offline).
    private func profiles() -> [ArchiveStaleScanner.Profile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: unisonDirectory) else { return [] }

        struct Raw { let name: String; let roots: [String]; let usesRootalias: Bool }
        let raws: [Raw] = names
            .filter { ($0 as NSString).pathExtension == "prf" }
            .compactMap { name in
                let url = URL(fileURLWithPath: unisonDirectory).appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let doc = ProfileDocument.parse(text)
                return Raw(name: (name as NSString).deletingPathExtension,
                           roots: doc.values(forKey: "root"),
                           usesRootalias: !doc.values(forKey: "rootalias").isEmpty)
            }

        // Count how many profiles use each local root path (to detect a
        // shared local root).
        var localPathCount: [String: Int] = [:]
        for raw in raws {
            for spec in ArchiveMatcher.rootSpecs(forRoots: raw.roots) where spec.isLocal {
                if let p = spec.path { localPathCount[p, default: 0] += 1 }
            }
        }

        return raws.map { raw in
            let specs = ArchiveMatcher.rootSpecs(forRoots: raw.roots)
            let localPaths = specs.filter { $0.isLocal }.compactMap { $0.path }
            let hasWildcardRemote = specs.contains { $0.path == nil }
            let hasSymlinkRoot = localPaths.contains { Self.isLeafSymlink($0) }
            let sharesLocalRoot = localPaths.contains { (localPathCount[$0] ?? 0) > 1 }
            let reliable = !(raw.usesRootalias
                             || hasSymlinkRoot
                             || (hasWildcardRemote && sharesLocalRoot))
            return ArchiveStaleScanner.Profile(
                name: raw.name, roots: raw.roots, attributionReliable: reliable)
        }
    }

    private static func isLeafSymlink(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: expanded)) != nil
    }

    // MARK: - Selection

    @objc private func toggleSelectAll(_ sender: NSButton) {
        let target = !checked.allSatisfy { $0 }   // any unchecked → check all
        for i in checked.indices { checked[i] = target }
        tableView.reloadData()
        refreshSelectionUI()
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let row = sender.tag
        guard checked.indices.contains(row) else { return }
        checked[row] = (sender.state == .on)
        refreshSelectionUI()
    }

    private func refreshSelectionUI() {
        var checkedFiles = 0
        for i in rows.indices where checked[i] { checkedFiles += rows[i].files.count }
        trashButton.title =
            "Move \(checkedFiles) File\(checkedFiles == 1 ? "" : "s") to Trash"
        trashButton.isEnabled = checkedFiles > 0
        if rows.isEmpty || checked.allSatisfy({ !$0 }) {
            selectAllCheckbox.state = .off
        } else if checked.allSatisfy({ $0 }) {
            selectAllCheckbox.state = .on
        } else {
            selectAllCheckbox.state = .mixed
        }
    }

    // MARK: - Actions

    @objc private func trashAction(_ sender: Any?) {
        var files: [URL] = []
        for i in rows.indices where checked[i] { files.append(contentsOf: rows[i].files.map(\.url)) }
        guard !files.isEmpty else { NSSound.beep(); return }
        let outcome = ArchiveCleanup(unisonDirectory: unisonDirectory).trash(files)
        TraceLog.shared.write(
            "CleanStale: trashed=\(outcome.trashed.count) failed=\(outcome.failed.count)")
        reload()
        guard !outcome.failed.isEmpty else { return }
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
        if let window { fail.beginSheetModal(for: window) { _ in } } else { fail.runModal() }
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
                ? "Attribution uncertain: a profile uses rootalias, a symlinked root, " +
                  "or shares a local root, so this may be wrong. Verify before relying on it."
                : (item.profileNames.isEmpty ? item.reason.label : item.profileText)
            let cell = labelCell(text, tooltip: tip)
            cell.textField?.textColor =
                (item.profileNames.isEmpty || item.uncertain) ? .systemOrange : .labelColor
            return cell
        case Col.size:
            let cell = labelCell(byteFmt.string(fromByteCount: item.bytes), tooltip: nil)
            cell.textField?.alignment = .right
            return cell
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
