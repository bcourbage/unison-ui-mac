import XCTest
@testable import unison_ui_mac

/// PR-5 UI-targeting fixes:
///   SF2  — menu-bar Ignore/Diff must NOT honor a stale `clickedRow`; only a
///          context-menu invocation does.
///   SF14 — Select Conflicts must reveal conflicts buried under collapsed folders
///          before mapping, and never wipe the selection to nothing.
@MainActor
final class ReconcileUITargetingTests: XCTestCase {

    private func makeController() -> ReconcileWindowController {
        ReconcileWindowController(
            profile: "T", mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onCancelScan: {},
            onSyncStart: {}, onSyncExit: { _ in }, onEngineUncertain: { _ in },
            onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
    }

    private func item(_ path: String, _ direction: String) -> StateItem {
        StateItem(path: path, left: "f", right: "f", direction: direction,
                  sizeBytes: 1, fileType: "file", progress: "", bytesTransferred: 0,
                  changedFromDefault: false)
    }

    // MARK: - SF2

    func test_sf2_isContextMenuItem_distinguishesContextFromMenuBar() {
        let c = makeController()
        let ctx = try? XCTUnwrap(c.contextMenuForTesting)
        let ctxItem = ctx?.items.first          // the context menu's "Diff" item
        XCTAssertNotNil(ctxItem)
        XCTAssertTrue(c.isContextMenuItemForTesting(ctxItem),
                      "an item in the outline's context menu is a context invocation")

        // A menu-bar / Edit-menu item lives in a different NSMenu.
        let barMenu = NSMenu()
        let barItem = NSMenuItem(title: "Diff", action: nil, keyEquivalent: "")
        barMenu.addItem(barItem)
        XCTAssertFalse(c.isContextMenuItemForTesting(barItem),
                       "a menu-bar item must NOT be treated as a context invocation (stale clickedRow)")
        XCTAssertFalse(c.isContextMenuItemForTesting(nil))
    }

    // MARK: - SF14

    /// The reveal logic (deterministic, no outline-view layout): a conflict buried
    /// under a folder is (a) found by `unresolvedConflictRows` and (b) its collapsed
    /// folder is returned by `nodesToRevealRows` — which `selectConflictsAction`
    /// expands before mapping, so the conflict is never silently dropped (SF14).
    /// (The final outline selection can't be asserted headlessly — NSOutlineView
    /// doesn't honor collapse state without a display pass.)
    func test_sf14_revealTargeting_identifiesCollapsedConflictFolder() {
        let items = [item("a.txt", "="), item("folder/conflict.txt", "<-?->")]
        let tree = ReconcileTree(items: items, layout: .nestedFull)   // real folder nodes
        let conflictRows = Set(RowSelectionRules.unresolvedConflictRows(items: items, rowOverrides: [:]))
        XCTAssertEqual(conflictRows, [1], "the buried conflict is found")
        let reveal = tree.nodesToRevealRows(conflictRows)
        XCTAssertTrue(reveal.contains { $0.name == "folder" },
                      "the collapsed folder containing the conflict is targeted for reveal")
    }

    /// With NO conflicts, Select Conflicts must beep and NOT clear an existing
    /// selection (the original bug wiped it when the mapped set came out empty).
    func test_sf14_selectConflicts_noConflicts_keepsExistingSelection() {
        let c = makeController()
        c.replaceItems([item("a.txt", "="), item("b.txt", "=")])
        let ov = c.outlineViewForTesting
        ov.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        c.selectConflictsForTesting()
        XCTAssertEqual(ov.selectedRowIndexes, IndexSet(integer: 0),
                       "no conflicts → existing selection is preserved, not wiped")
    }
}
