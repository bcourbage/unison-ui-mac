import Foundation

/// A node in the reconcile-tree. Two kinds:
///   - **Leaf**: maps to a single `StateItem` (a file or symlink in the
///     reconcile result). `row` is the index into the controller's `items`
///     array; `fullPath` is the original Unison path.
///   - **Folder**: an intermediate path component. `row` is nil. Children
///     are the contents (other folders or leaves). The synthetic root
///     itself is a folder with no name.
///
/// Equality is reference identity. The outline view holds nodes as `Any`
/// items and compares them with `===`; the tree is rebuilt on each
/// `replaceItems(_:)` so cached references don't outlive a reconcile.
final class ReconcileNode {
    let name: String
    let row: Int?
    let fullPath: String?
    fileprivate(set) var children: [ReconcileNode] = []
    weak var parent: ReconcileNode?

    init(name: String, row: Int? = nil, fullPath: String? = nil) {
        self.name = name
        self.row = row
        self.fullPath = fullPath
    }

    var isLeaf: Bool { row != nil }
}

/// Builds a path-segment tree from a flat `[StateItem]` so an NSOutlineView
/// can render the reconcile as Finder-style indented folders.
///
/// Path semantics follow Unison's convention: forward-slash separated,
/// no leading slash (the path is relative to each replica's root).
struct ReconcileTree {

    /// Synthetic root. Its `children` are the top-level entries.
    let root: ReconcileNode

    /// Total leaves in the tree. Equals the input `items.count`.
    let leafCount: Int

    /// Flatten visit (folders + leaves in tree order). Useful for tests.
    var allNodes: [ReconcileNode] {
        var out: [ReconcileNode] = []
        func walk(_ node: ReconcileNode) {
            for child in node.children {
                out.append(child)
                walk(child)
            }
        }
        walk(root)
        return out
    }

    init(items: [StateItem]) {
        let root = ReconcileNode(name: "")
        for (index, item) in items.enumerated() {
            ReconcileTree.insert(path: item.path, row: index, into: root)
        }
        self.root = root
        self.leafCount = items.count
    }

    private static func insert(path: String, row: Int, into root: ReconcileNode) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        var cursor = root
        for (i, part) in parts.enumerated() {
            let isLast = (i == parts.count - 1)
            if let existing = cursor.children.first(where: { $0.name == part }) {
                // An intermediate node already exists at this path. If the
                // current insertion is for a leaf at exactly this segment,
                // treat it as a sibling rather than collapsing — that case
                // only arises with duplicate paths, which Unison shouldn't
                // produce, but defend anyway.
                cursor = existing
                continue
            }
            let node: ReconcileNode
            if isLast {
                node = ReconcileNode(name: part, row: row, fullPath: path)
            } else {
                node = ReconcileNode(name: part)
            }
            node.parent = cursor
            cursor.children.append(node)
            cursor = node
        }
    }
}
