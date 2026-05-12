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
}
