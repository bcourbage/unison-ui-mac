import XCTest
@testable import unison_ui_mac

final class ReconcileTreeTests: XCTestCase {

    private func item(_ path: String) -> StateItem {
        StateItem(
            path: path, left: "", right: "", direction: "",
            sizeBytes: 0, fileType: "FILE", progress: "", bytesTransferred: 0
        )
    }

    func test_emptyItems_producesEmptyTree() {
        let tree = ReconcileTree(items: [])
        XCTAssertEqual(tree.leafCount, 0)
        XCTAssertEqual(tree.root.children.count, 0)
        XCTAssertEqual(tree.allNodes.count, 0)
    }

    func test_singleTopLevelFile_isALeafAtRoot() {
        let tree = ReconcileTree(items: [item("README.md")])
        XCTAssertEqual(tree.root.children.count, 1)
        let node = tree.root.children[0]
        XCTAssertEqual(node.name, "README.md")
        XCTAssertEqual(node.row, 0)
        XCTAssertTrue(node.isLeaf)
        XCTAssertEqual(node.fullPath, "README.md")
    }

    func test_nestedPath_buildsIntermediateFolders() {
        let tree = ReconcileTree(items: [item("Documents/Photos/2024/img.jpg")])
        XCTAssertEqual(tree.root.children.count, 1)
        let documents = tree.root.children[0]
        XCTAssertEqual(documents.name, "Documents")
        XCTAssertFalse(documents.isLeaf)
        XCTAssertNil(documents.row)

        let photos = documents.children[0]
        XCTAssertEqual(photos.name, "Photos")
        XCTAssertFalse(photos.isLeaf)

        let year = photos.children[0]
        XCTAssertEqual(year.name, "2024")
        XCTAssertFalse(year.isLeaf)

        let leaf = year.children[0]
        XCTAssertEqual(leaf.name, "img.jpg")
        XCTAssertEqual(leaf.row, 0)
        XCTAssertEqual(leaf.fullPath, "Documents/Photos/2024/img.jpg")
        XCTAssertTrue(leaf.isLeaf)
        // Parent pointers
        XCTAssertTrue(leaf.parent === year)
        XCTAssertTrue(year.parent === photos)
    }

    func test_siblingsShareFolders() {
        let tree = ReconcileTree(items: [
            item("Documents/a.txt"),
            item("Documents/b.txt"),
            item("Pictures/c.jpg"),
        ])
        XCTAssertEqual(tree.leafCount, 3)
        XCTAssertEqual(tree.root.children.count, 2,
                       "Documents + Pictures, not three separate top-levels")

        let documents = tree.root.children.first { $0.name == "Documents" }
        XCTAssertNotNil(documents)
        XCTAssertEqual(documents?.children.count, 2,
                       "a.txt + b.txt share the Documents folder")
        XCTAssertEqual(Set(documents?.children.map(\.name) ?? []), ["a.txt", "b.txt"])

        let pictures = tree.root.children.first { $0.name == "Pictures" }
        XCTAssertEqual(pictures?.children.count, 1)
        XCTAssertEqual(pictures?.children[0].name, "c.jpg")
    }

    func test_rowIndicesArePreserved() {
        // Insert intentionally out-of-order to verify each leaf's `row`
        // tracks the original [StateItem] index.
        let tree = ReconcileTree(items: [
            item("Zeta/file.txt"),       // row 0
            item("Alpha/file.txt"),      // row 1
            item("Mid/sub/file.txt"),    // row 2
        ])
        let zeta = tree.root.children.first { $0.name == "Zeta" }
        XCTAssertEqual(zeta?.children[0].row, 0)

        let alpha = tree.root.children.first { $0.name == "Alpha" }
        XCTAssertEqual(alpha?.children[0].row, 1)

        let mid = tree.root.children.first { $0.name == "Mid" }
        XCTAssertEqual(mid?.children[0].children[0].row, 2)
    }

    func test_allNodes_visitsFoldersAndLeaves() {
        let tree = ReconcileTree(items: [
            item("a/x"),
            item("a/y"),
            item("b/z"),
        ])
        let names = tree.allNodes.map(\.name)
        // Folders + leaves; folders come before their leaves in tree order.
        XCTAssertEqual(Set(names), ["a", "x", "y", "b", "z"])
        XCTAssertEqual(tree.allNodes.filter(\.isLeaf).count, 3)
    }

    // MARK: - pathFromRoot

    func test_pathFromRoot_forLeaf_returnsStoredFullPath() {
        let tree = ReconcileTree(items: [item("Documents/Photos/img.jpg")])
        let leaf = tree.allNodes.first(where: { $0.isLeaf })!
        XCTAssertEqual(leaf.pathFromRoot, "Documents/Photos/img.jpg")
    }

    func test_pathFromRoot_forFolder_walksAncestors() {
        let tree = ReconcileTree(items: [item("Documents/Photos/2024/img.jpg")])
        // Drill down to the Photos folder.
        let documents = tree.root.children[0]
        let photos = documents.children[0]
        let year = photos.children[0]
        XCTAssertEqual(documents.pathFromRoot, "Documents")
        XCTAssertEqual(photos.pathFromRoot, "Documents/Photos")
        XCTAssertEqual(year.pathFromRoot, "Documents/Photos/2024")
    }

    func test_pathFromRoot_forSyntheticRoot_isEmpty() {
        // The synthetic root has an empty name; its path is "".
        let tree = ReconcileTree(items: [item("a")])
        XCTAssertEqual(tree.root.pathFromRoot, "")
    }

    func test_pathFromRoot_forTopLevelFolder_isJustItsName() {
        let tree = ReconcileTree(items: [item("Documents/a.txt")])
        let documents = tree.root.children[0]
        XCTAssertEqual(documents.pathFromRoot, "Documents")
    }

    // MARK: - FolderAggregate

    private func item(_ path: String, direction: String) -> StateItem {
        StateItem(
            path: path, left: "", right: "", direction: direction,
            sizeBytes: 0, fileType: "FILE", progress: "", bytesTransferred: 0
        )
    }

    func test_aggregate_uniformDirection_whenAllChildrenAgree() {
        let items = [
            item("a/x", direction: "---->"),
            item("a/y", direction: "---->"),
            item("a/z", direction: "---->"),
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: [:]),
                       .uniform("---->"))
    }

    func test_aggregate_mixed_whenChildrenDisagree() {
        let items = [
            item("a/x", direction: "---->"),
            item("a/y", direction: "<----"),
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: [:]),
                       .mixed)
    }

    func test_aggregate_allUserSkipped_overridesUniformDirection() {
        // Every child shares direction "<-?->", but every child is also
        // user-skipped → folder should report .allUserSkipped, not
        // .uniform("<-?->"), so it reads as "settled" rather than
        // "needs attention".
        let items = [
            item("a/x", direction: "<-?->"),
            item("a/y", direction: "<-?->"),
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        let overrides: [Int: RowOverride] = [0: .skip, 1: .skip]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: overrides),
                       .allUserSkipped)
    }

    func test_aggregate_partialUserSkipped_keepsUniformConflict() {
        // Half the children are user-skipped, half aren't. The unskipped
        // ones still need attention so the folder stays "needs attention".
        let items = [
            item("a/x", direction: "<-?->"),
            item("a/y", direction: "<-?->"),
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: [0: .skip]),
                       .uniform("<-?->"))
    }

    func test_aggregate_nestedFolders_recurseThroughChildren() {
        // a/sub/x → ---->
        // a/sub/y → ---->
        // The top-level "a" should also see uniform("---->") because
        // every leaf under it agrees.
        let items = [
            item("a/sub/x", direction: "---->"),
            item("a/sub/y", direction: "---->"),
        ]
        let tree = ReconcileTree(items: items)
        let topA = tree.root.children[0]
        XCTAssertEqual(topA.name, "a")
        XCTAssertEqual(topA.aggregate(items: items, rowOverrides: [:]),
                       .uniform("---->"))
    }

    // MARK: - Force-older / force-newer aggregates

    func test_aggregate_allForcedOlder_overridesUnderlyingDirections() {
        // Every leaf is set to Force Older. The OCaml directions may
        // differ leaf-to-leaf (mtime resolution lands on either side),
        // but the folder should still report .allForcedOlder so the
        // user sees the *decision* uniformity, not the mtime artifact.
        let items = [
            item("a/x", direction: "---->"),
            item("a/y", direction: "<----"),  // different direction, same decision
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        let overrides: [Int: RowOverride] = [0: .forceOlder, 1: .forceOlder]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: overrides),
                       .allForcedOlder)
    }

    func test_aggregate_allForcedNewer_overridesUnderlyingDirections() {
        let items = [
            item("a/x", direction: "---->"),
            item("a/y", direction: "<----"),
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        let overrides: [Int: RowOverride] = [0: .forceNewer, 1: .forceNewer]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: overrides),
                       .allForcedNewer)
    }

    func test_aggregate_mixedOverrides_yieldsMixed() {
        // Different decisions across leaves → no single badge can
        // represent the folder's state. Mixed sends the user to drill in.
        let items = [
            item("a/x", direction: "---->"),
            item("a/y", direction: "---->"),
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        let overrides: [Int: RowOverride] = [0: .forceOlder, 1: .forceNewer]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: overrides),
                       .mixed)
    }

    func test_aggregate_someForcedSomeAuto_yieldsMixed() {
        // A leaf with no override and a leaf with .forceNewer disagree
        // about "what's the user's stance" → mixed, even if their
        // underlying OCaml directions happen to agree.
        let items = [
            item("a/x", direction: "---->"),
            item("a/y", direction: "---->"),
        ]
        let tree = ReconcileTree(items: items)
        let folder = tree.root.children[0]
        XCTAssertEqual(folder.aggregate(items: items, rowOverrides: [1: .forceNewer]),
                       .mixed)
    }

    // MARK: - LayoutMode

    private func itemWithDirection(_ path: String, _ direction: String) -> StateItem {
        StateItem(
            path: path, left: "", right: "", direction: direction,
            sizeBytes: 0, fileType: "FILE", progress: "", bytesTransferred: 0
        )
    }

    func test_flatLayout_everyLeafIsTopLevel() {
        // Flat mode: every leaf goes directly under root, named with
        // the full path. No intermediate folder nodes are created
        // even when paths share prefixes.
        let tree = ReconcileTree(
            items: [
                item("Documents/Photos/img.jpg"),
                item("Documents/Photos/img2.jpg"),
                item("Documents/notes.txt"),
            ],
            layout: .flat
        )
        XCTAssertEqual(tree.layoutMode, .flat)
        XCTAssertEqual(tree.root.children.count, 3,
                       "flat: every leaf is a direct child of root")
        for child in tree.root.children {
            XCTAssertTrue(child.isLeaf,
                          "flat: no intermediate folder nodes")
        }
        // Names are the full paths, in original order.
        XCTAssertEqual(tree.root.children.map { $0.name }, [
            "Documents/Photos/img.jpg",
            "Documents/Photos/img2.jpg",
            "Documents/notes.txt",
        ])
        // fullPath survives so pathFromRoot still returns the original
        // path (used for tooltips + details lookups).
        XCTAssertEqual(tree.root.children[0].fullPath,
                       "Documents/Photos/img.jpg")
    }

    func test_nestedFullLayout_isTheOldFinderStyleBehavior() {
        let tree = ReconcileTree(
            items: [item("Documents/Photos/img.jpg")],
            layout: .nestedFull
        )
        XCTAssertEqual(tree.layoutMode, .nestedFull)
        // Documents / Photos / img.jpg — three nested nodes.
        XCTAssertEqual(tree.root.children.count, 1)
        let docs = tree.root.children[0]
        XCTAssertEqual(docs.name, "Documents")
        XCTAssertFalse(docs.isLeaf)
        let photos = docs.children[0]
        XCTAssertEqual(photos.name, "Photos")
        XCTAssertFalse(photos.isLeaf)
        XCTAssertEqual(photos.children[0].name, "img.jpg")
        XCTAssertTrue(photos.children[0].isLeaf)
    }

    func test_nestedCollapsed_singleChildChainBecomesOneNode() {
        // Deep chain where every level has exactly one child should
        // collapse to a single combined-name leaf at root.
        let tree = ReconcileTree(
            items: [item("a/b/c/d/file.txt")],
            layout: .nestedCollapsed
        )
        XCTAssertEqual(tree.layoutMode, .nestedCollapsed)
        XCTAssertEqual(tree.root.children.count, 1)
        let node = tree.root.children[0]
        XCTAssertEqual(node.name, "a/b/c/d/file.txt")
        XCTAssertTrue(node.isLeaf, "leaf at the end of the collapsed chain")
        XCTAssertEqual(node.fullPath, "a/b/c/d/file.txt",
                       "fullPath preserved through collapse")
    }

    func test_nestedCollapsed_branchingFolderStaysExpanded() {
        // a/b has two children (file1.txt and file2.txt) → can't
        // collapse. But the chain `top/a/b` collapses to "top/a/b"
        // because top→a→b each have only one child.
        let tree = ReconcileTree(
            items: [
                item("top/a/b/file1.txt"),
                item("top/a/b/file2.txt"),
            ],
            layout: .nestedCollapsed
        )
        // Root has one child: the collapsed folder "top/a/b".
        XCTAssertEqual(tree.root.children.count, 1)
        let collapsed = tree.root.children[0]
        XCTAssertEqual(collapsed.name, "top/a/b")
        XCTAssertFalse(collapsed.isLeaf,
                       "folder with multiple leaf children stays a folder")
        XCTAssertEqual(collapsed.children.count, 2)
        XCTAssertEqual(collapsed.children.map { $0.name },
                       ["file1.txt", "file2.txt"])
    }

    func test_nestedCollapsed_mixedDepthsPreserveFolderBoundaries() {
        // Mix of paths where SOME levels collapse and others don't.
        // a/b has two paths: a/b/c/leaf1 and a/b/leaf2. The "c"
        // chain in a/b/c/leaf1 collapses (c has one child). The
        // a/b folder doesn't collapse (two children).
        let tree = ReconcileTree(
            items: [
                item("a/b/c/leaf1.txt"),
                item("a/b/leaf2.txt"),
            ],
            layout: .nestedCollapsed
        )
        // Root → one node: "a/b" (top-down collapse: a has 1 child,
        // collapses with b; b has 2 children so the chain stops).
        XCTAssertEqual(tree.root.children.count, 1)
        let ab = tree.root.children[0]
        XCTAssertEqual(ab.name, "a/b")
        XCTAssertEqual(ab.children.count, 2)
        // The "c/leaf1.txt" chain inside a/b is a single collapsed leaf;
        // "leaf2.txt" is a normal leaf.
        let names = Set(ab.children.map { $0.name })
        XCTAssertTrue(names.contains("c/leaf1.txt"),
                      "c/leaf chain collapsed into one node: \(names)")
        XCTAssertTrue(names.contains("leaf2.txt"))
    }

    func test_nestedFull_defaultLayout_isUnchanged() {
        // The default initializer (no `layout:`) should still build
        // a full nested tree — preserves existing test expectations
        // around the original API.
        let tree = ReconcileTree(items: [item("a/b/c.txt")])
        XCTAssertEqual(tree.layoutMode, .nestedFull)
        XCTAssertEqual(tree.root.children[0].name, "a")
    }

    // MARK: - ExpandPolicy

    func test_expandPolicy_rootOnly_returnsEmpty() {
        let items = [
            itemWithDirection("a/b/conflict.txt", "<-?->"),
            itemWithDirection("a/b/ok.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        let nodes = tree.nodesToExpand(
            policy: .rootOnly, items: items, rowOverrides: [:])
        XCTAssertEqual(nodes.count, 0,
                       "rootOnly: no folders pre-expanded regardless of content")
    }

    func test_expandPolicy_all_expandsEveryFolder() {
        let items = [
            itemWithDirection("a/b/conflict.txt", "<-?->"),
            itemWithDirection("c/d/ok.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        let nodes = tree.nodesToExpand(
            policy: .all, items: items, rowOverrides: [:])
        // Expect every folder node: a, a/b, c, c/d → 4 folders.
        // (Leaves are excluded; only folders are returned.)
        XCTAssertEqual(nodes.count, 4)
        XCTAssertTrue(nodes.allSatisfy { !$0.isLeaf })
    }

    func test_expandPolicy_smart_expandsOnlyConflictBranches() {
        // a/b/conflict.txt is a conflict; c/d/ok.txt isn't.
        // Smart should expand a and a/b but NOT c or c/d.
        let items = [
            itemWithDirection("a/b/conflict.txt", "<-?->"),
            itemWithDirection("c/d/ok.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        let nodes = tree.nodesToExpand(
            policy: .smart, items: items, rowOverrides: [:])
        let names = Set(nodes.map { $0.name })
        XCTAssertEqual(names, ["a", "b"],
                       "smart expand: a + a/b (conflict branch); c/d stays collapsed. Got \(names)")
    }

    func test_expandPolicy_smart_ignoresOverriddenConflicts() {
        // A conflict that's already been overridden (Skip / Force…)
        // no longer needs the user's attention — smart shouldn't
        // expand its ancestor chain on its account.
        let items = [
            itemWithDirection("a/b/conflict.txt", "<-?->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        let resolved: [Int: RowOverride] = [0: .skip]
        let nodes = tree.nodesToExpand(
            policy: .smart, items: items, rowOverrides: resolved)
        XCTAssertTrue(nodes.isEmpty,
                      "smart: overridden conflict doesn't trigger expansion")
    }

    func test_expandPolicy_smart_flatLayoutHasNoFoldersToExpand() {
        // Flat layout has no folder nodes at all → smart returns []
        // regardless of conflict presence.
        let items = [
            itemWithDirection("a/b/conflict.txt", "<-?->"),
        ]
        let tree = ReconcileTree(items: items, layout: .flat)
        let nodes = tree.nodesToExpand(
            policy: .smart, items: items, rowOverrides: [:])
        XCTAssertEqual(nodes.count, 0)
    }

    // MARK: - nodesToRevealFailedRows (post-sync failure expansion)

    func test_revealFailedRows_empty_setReturnsEmpty() {
        // No failures → nothing to reveal. Mirrors the "successful
        // sync" path where the policy-driven expansion stays unchanged.
        let items = [
            itemWithDirection("a/b/file.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        XCTAssertTrue(tree.nodesToRevealFailedRows([]).isEmpty)
    }

    func test_revealFailedRows_expandsAncestorChainOfFailedLeaf() {
        // Row 0 (a/b/c/fail.txt) is the only failure. Reveal should
        // return every folder on the path: a, a/b, a/b/c.
        let items = [
            itemWithDirection("a/b/c/fail.txt", "---->"),
            itemWithDirection("a/b/c/ok.txt", "---->"),
            itemWithDirection("x/y/elsewhere.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        let nodes = tree.nodesToRevealFailedRows([0])
        let names = Set(nodes.map { $0.name })
        XCTAssertEqual(names, ["a", "b", "c"],
                       "should expand the full ancestor chain. Got \(names)")
    }

    func test_revealFailedRows_doesNotExpandSiblingBranches() {
        // Failure in a/ should not pull c/ into the expand set.
        let items = [
            itemWithDirection("a/fail.txt", "---->"),
            itemWithDirection("c/d/ok.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        let nodes = tree.nodesToRevealFailedRows([0])
        let names = Set(nodes.map { $0.name })
        XCTAssertEqual(names, ["a"], "only the failed row's branch. Got \(names)")
    }

    func test_revealFailedRows_multipleFailuresUnionTheirAncestors() {
        // Two unrelated failures (a/fail.txt + c/d/fail.txt) — reveal
        // should union both ancestor chains: a, c, c/d.
        let items = [
            itemWithDirection("a/fail.txt", "---->"),
            itemWithDirection("c/d/fail.txt", "---->"),
            itemWithDirection("x/ok.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        let nodes = tree.nodesToRevealFailedRows([0, 1])
        let names = Set(nodes.map { $0.name })
        XCTAssertEqual(names, ["a", "c", "d"],
                       "union of both ancestor chains. Got \(names)")
    }

    func test_revealFailedRows_flatLayoutHasNoFoldersToReveal() {
        // Flat layout has no folder nodes — the FAILED leaves are
        // already top-level and always visible. Reveal returns [].
        let items = [
            itemWithDirection("a/b/fail.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .flat)
        XCTAssertTrue(tree.nodesToRevealFailedRows([0]).isEmpty)
    }

    func test_revealFailedRows_pureSingleChildChainHasNoFoldersToReveal() {
        // nestedCollapsed merges a single-child chain "a/b/c/fail.txt"
        // into a single leaf node at the top level (name becomes the
        // joined path). No folder ancestors survive the collapse —
        // there's nothing to expand, just like the flat layout.
        let items = [
            itemWithDirection("a/b/c/fail.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedCollapsed)
        XCTAssertTrue(tree.nodesToRevealFailedRows([0]).isEmpty,
                      "single-child chain collapses away; no folders remain")
    }

    func test_revealFailedRows_collapsedBranchingFolderStillReveals() {
        // Branching folder doesn't collapse away — it has two
        // children, so it survives as a folder node. A failure under
        // one branch should reveal that folder. Tree shape:
        //   a/
        //     fail.txt   ← row 0 (the failure)
        //     ok.txt
        let items = [
            itemWithDirection("a/fail.txt", "---->"),
            itemWithDirection("a/ok.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedCollapsed)
        let nodes = tree.nodesToRevealFailedRows([0])
        XCTAssertEqual(nodes.count, 1,
                       "branching folder survives collapse → one ancestor")
        XCTAssertEqual(nodes[0].name, "a",
                       "ancestor is the un-collapsed folder")
    }

    func test_revealFailedRows_unknownRowIndexIsIgnored() {
        // Defensive: caller passes a row index that doesn't exist in
        // the tree. Should not crash, should not return phantom nodes.
        let items = [
            itemWithDirection("a/file.txt", "---->"),
        ]
        let tree = ReconcileTree(items: items, layout: .nestedFull)
        XCTAssertTrue(tree.nodesToRevealFailedRows([999]).isEmpty)
    }
}
