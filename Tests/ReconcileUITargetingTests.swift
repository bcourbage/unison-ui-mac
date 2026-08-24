import XCTest
@testable import unison_ui_mac

/// PR-5 UI-targeting fixes, driven through the PRODUCTION menu handlers and the
/// Select-Conflicts path via injected seams (headless clickedRow / collapse can't
/// be driven directly):
///   SF2  — menu-bar Ignore/Diff act on the SELECTION; context-menu on the CLICKED row.
///   SF14 — Select Conflicts expands a buried conflict's folder and selects it.
@MainActor
final class ReconcileUITargetingTests: XCTestCase {

    private func item(_ path: String, _ direction: String) -> StateItem {
        StateItem(path: path, left: "f", right: "f", direction: direction,
                  sizeBytes: 1, fileType: "file", progress: "", bytesTransferred: 0,
                  changedFromDefault: false)
    }

    /// A controller wired so the target row of an Ignore / Diff is recorded.
    private func makeRecordingController(
        onIgnoreRow: @escaping (Int) -> Void,
        onDiffRow: @escaping (Int) -> Void
    ) -> ReconcileWindowController {
        ReconcileWindowController(
            profile: "T", mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onCancelScan: {},
            onSyncStart: {}, onSyncExit: { _ in }, onEngineUncertain: { _ in },
            onIgnore: { _, row in onIgnoreRow(row); return UNISON_OP_INVALID },
            onDiffRequest: { row in onDiffRow(row); return .refused },
            onDiffAbandon: {})
    }

    private func node(_ c: ReconcileWindowController, row: Int) -> ReconcileNode {
        c.treeForTesting.allNodes.first { $0.row == row }!
    }

    /// Stale clicked row = A(0); selection = B(1). Assert the resolved target.
    private func setupStaleClick(_ c: ReconcileWindowController) {
        c.replaceItems([item("a.txt", "<-?->"), item("b.txt", "<-?->")])
        let a = node(c, row: 0), b = node(c, row: 1)
        c.clickedNodeProviderForTesting = { a }        // a stale right-click on A
        c.selectedNodesProviderForTesting = { [b] }    // the user selected B
    }

    private func contextIgnoreItem(_ c: ReconcileWindowController) -> NSMenuItem {
        c.contextMenuForTesting!.items.first { IgnoreAction.from(tag: $0.tag) != nil }!
    }
    private func menuBarItem(tag: Int) -> NSMenuItem {
        let m = NSMenu()
        let it = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        it.tag = tag
        m.addItem(it)
        return it
    }

    // MARK: - SF2: Ignore

    func test_sf2_menuBarIgnore_usesSelection_notStaleClickedRow() {
        var recorded: Int?
        let c = makeRecordingController(onIgnoreRow: { recorded = $0 }, onDiffRow: { _ in })
        setupStaleClick(c)
        c.ignoreMenuActionForTesting(menuBarItem(tag: contextIgnoreItem(c).tag))
        XCTAssertEqual(recorded, 1, "menu-bar Ignore targets the SELECTION (B), not the stale clicked A")
    }

    func test_sf2_contextIgnore_usesClickedRow() {
        var recorded: Int?
        let c = makeRecordingController(onIgnoreRow: { recorded = $0 }, onDiffRow: { _ in })
        setupStaleClick(c)
        c.ignoreMenuActionForTesting(contextIgnoreItem(c))
        XCTAssertEqual(recorded, 0, "context-menu Ignore targets the CLICKED row (A)")
    }

    // MARK: - SF2: Diff

    func test_sf2_menuBarDiff_usesSelection_notStaleClickedRow() {
        var recorded: Int?
        let c = makeRecordingController(onIgnoreRow: { _ in }, onDiffRow: { recorded = $0 })
        setupStaleClick(c)
        let barDiff = menuBarItem(tag: 0)              // not in the context menu
        c.diffMenuActionForTesting(barDiff)
        XCTAssertEqual(recorded, 1, "menu-bar Diff targets the SELECTION (B)")
    }

    func test_sf2_contextDiff_usesClickedRow() {
        var recorded: Int?
        let c = makeRecordingController(onIgnoreRow: { _ in }, onDiffRow: { recorded = $0 })
        setupStaleClick(c)
        let ctxDiff = c.contextMenuForTesting!.items.first!   // the context "Diff" item
        c.diffMenuActionForTesting(ctxDiff)
        XCTAssertEqual(recorded, 0, "context-menu Diff targets the CLICKED row (A)")
    }

    // MARK: - SF14: Select Conflicts reveals + selects a buried conflict

    func test_sf14_selectConflicts_expandsBuriedConflictFolder_andSelectsIt() {
        // Nested layout so the tree has a real "folder" node to reveal.
        let savedLayout = SettingsModel.reconcileLayoutMode()
        SettingsModel.setReconcileLayoutMode(.nestedFull)
        defer { SettingsModel.setReconcileLayoutMode(savedLayout) }

        let c = makeRecordingController(onIgnoreRow: { _ in }, onDiffRow: { _ in })
        // a.txt (row 0, not a conflict), folder/conflict.txt (row 1, conflict).
        c.replaceItems([item("a.txt", "="), item("folder/conflict.txt", "<-?->")])

        // Simulate a COLLAPSED folder deterministically: the conflict node maps to
        // -1 until its folder is expanded; then it maps to a real row.
        var expanded = Set<ObjectIdentifier>()
        var selected = IndexSet()
        c.outlineOpsForTesting = ReconcileWindowController.OutlineOps(
            expand: { expanded.insert(ObjectIdentifier($0)) },
            outlineRow: { node in
                guard node.row == 1 else { return 0 }         // the conflict leaf
                // Visible only once ANY of its ancestor folders was expanded.
                return expanded.isEmpty ? -1 : 5
            },
            select: { selected = $0 },
            scrollToVisible: { _ in })

        c.selectConflictsForTesting()

        XCTAssertFalse(expanded.isEmpty, "the buried conflict's folder was expanded")
        XCTAssertEqual(selected, IndexSet(integer: 5),
                       "the (now-revealed) conflict row is selected — not silently dropped")
    }

    func test_sf14_selectConflicts_noConflicts_keepsExistingSelection() {
        let c = makeRecordingController(onIgnoreRow: { _ in }, onDiffRow: { _ in })
        c.replaceItems([item("a.txt", "="), item("b.txt", "=")])
        var selectCalled = false
        c.outlineOpsForTesting = ReconcileWindowController.OutlineOps(
            expand: { _ in }, outlineRow: { _ in 0 },
            select: { _ in selectCalled = true }, scrollToVisible: { _ in })
        c.selectConflictsForTesting()
        XCTAssertFalse(selectCalled, "no conflicts → selection is not touched (not wiped)")
    }

    // MARK: - SF2 distinguisher

    func test_sf2_isContextMenuItem_distinguishesContextFromMenuBar() {
        let c = makeRecordingController(onIgnoreRow: { _ in }, onDiffRow: { _ in })
        XCTAssertTrue(c.isContextMenuItemForTesting(c.contextMenuForTesting?.items.first))
        XCTAssertFalse(c.isContextMenuItemForTesting(menuBarItem(tag: 0)))
        XCTAssertFalse(c.isContextMenuItemForTesting(nil))
    }
}
