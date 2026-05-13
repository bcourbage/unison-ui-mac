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
}
