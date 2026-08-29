import XCTest
@testable import unison_ui_mac

/// PR-5 UI-targeting fixes, driven through the PRODUCTION menu handlers and the
/// Select-Conflicts path via injected seams (headless clickedRow / collapse can't
/// be driven directly):
///   SF2  — menu-bar Ignore/Diff act on the SELECTION; context-menu on the CLICKED row.
///   SF14 — Select Conflicts expands a buried conflict's folder and selects it.
@MainActor
final class ReconcileUITargetingTests: XCTestCase {

    private final class Box<T> { var value: T? }

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
            onClose: {}, onRescanRequested: {},
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

    // Round 3: a context-menu Ignore on a FOLDER or BLANK space must NOT fall
    // through to the selection — it has no leaf target (beep), never the selected file.

    /// Load a folder-nested tree and return the controller with the folder node
    /// clicked and leaf B selected.
    private func setupContextClickOnFolder(_ clickIsNil: Bool) -> (ReconcileWindowController, Box<Int?>) {
        let savedLayout = SettingsModel.reconcileLayoutMode()
        SettingsModel.setReconcileLayoutMode(.nestedFull)
        addTeardownBlock { SettingsModel.setReconcileLayoutMode(savedLayout) }

        let box = Box<Int?>()
        let c = makeRecordingController(onIgnoreRow: { box.value = $0 }, onDiffRow: { box.value = $0 })
        c.replaceItems([item("folder/leaf.txt", "<-?->"), item("b.txt", "<-?->")])
        let folder = c.treeForTesting.allNodes.first { $0.name == "folder" && $0.row == nil }!
        let b = c.treeForTesting.allNodes.first { $0.row == 1 }!
        c.clickedNodeProviderForTesting = clickIsNil ? { nil } : { folder }
        c.selectedNodesProviderForTesting = { [b] }
        return (c, box)
    }

    func test_sf2_contextIgnore_onFolder_targetsNothing_notSelection() {
        let (c, box) = setupContextClickOnFolder(false)   // clicked a synthetic folder
        let item = contextIgnoreItem(c)
        XCTAssertFalse(c.validateMenuItem(item), "context Ignore on a folder is disabled")
        c.ignoreMenuActionForTesting(item)
        XCTAssertNil(box.value, "no Ignore is applied to the selected leaf")
    }

    func test_sf2_contextIgnore_onBlankSpace_targetsNothing_notSelection() {
        let (c, box) = setupContextClickOnFolder(true)    // right-clicked blank space
        let item = contextIgnoreItem(c)
        XCTAssertFalse(c.validateMenuItem(item), "context Ignore on blank space is disabled")
        c.ignoreMenuActionForTesting(item)
        XCTAssertNil(box.value, "no Ignore is applied to the selection")
    }

    func test_sf2_contextDiff_onFolderOrBlank_targetsNothing_notSelection() {
        for clickIsNil in [false, true] {
            let (c, box) = setupContextClickOnFolder(clickIsNil)
            let ctxDiff = c.contextMenuForTesting!.items.first!   // the "Diff" item
            XCTAssertFalse(c.validateMenuItem(ctxDiff),
                           "context Diff on \(clickIsNil ? "blank" : "a folder") is disabled")
            c.diffMenuActionForTesting(ctxDiff)
            XCTAssertNil(box.value, "no Diff targets the selected leaf")
        }
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
