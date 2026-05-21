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
    /// Displayed name in the Path column. Effectively immutable except
    /// during build-time tree transformations — specifically
    /// `ReconcileTree.collapseSingleChildChains(in:)`, which mutates
    /// folder names to be a `/`-joined path of the absorbed chain
    /// (`a/b/c` instead of three separate folder rows). No other code
    /// path writes `name` after construction.
    var name: String
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

    /// Reconstruct the full path of this node. Leaves return the stored
    /// `fullPath` set at construction time (the original Unison path).
    /// Folders walk up the ancestor chain, joining names with `/`. The
    /// synthetic root (empty name) contributes nothing. Used for
    /// truncation tooltips and the details footer.
    ///
    /// Side note: this is O(depth) per call, which is fine — folders
    /// are at most a few dozen deep in any realistic profile.
    var pathFromRoot: String {
        if let stored = fullPath { return stored }
        var parts: [String] = []
        var cursor: ReconcileNode? = self
        while let n = cursor, !n.name.isEmpty {
            parts.insert(n.name, at: 0)
            cursor = n.parent
        }
        return parts.joined(separator: "/")
    }
}

/// A user-pinned decision on a reconcile row that overrides how the
/// row's direction is *rendered*. OCaml still resolves the actual
/// direction (e.g. `unisonRiForceNewer` produces `"---->"` or `"<----"`
/// based on mtime), but the GUI wants to show the user's intent —
/// "I picked Force Newer" — rather than the resulting arrow.
///
/// Tracked Swift-side on `ReconcileWindowController.rowOverrides`,
/// cleared on every rescan (OCaml rebuilds the row set from scratch,
/// so persisting overrides across rescans would risk stale entries).
enum RowOverride: Equatable {
    /// User clicked Skip. Overlays OCaml's `"<-?->"` (which the OCaml
    /// side uses for both auto-detected conflicts and explicit skips).
    case skip
    /// User clicked Force Older. The resulting direction depends on
    /// mtime; the badge instead shows the "older wins" decision.
    case forceOlder
    /// User clicked Force Newer. Same idea, opposite direction.
    case forceNewer
}

/// Folder-level summary of every leaf reachable from a `ReconcileNode`.
/// Computed by walking the subtree; used to tint folder icons in the
/// outline view so a uniform folder reads at a glance.
///
/// Override states (skip / forceOlder / forceNewer) participate in the
/// aggregate too: a folder whose leaves are ALL the same override
/// renders that override's badge, hiding the underlying direction —
/// same intent-over-result rule that applies to individual rows.
enum FolderAggregate: Equatable {
    /// Every leaf has the same direction string (e.g. "---->") AND no
    /// leaf carries a user override.
    case uniform(String)
    /// Every leaf was explicitly skipped by the user. Distinct from
    /// uniform("<-?->") because the user-decided state should look
    /// "settled" rather than "needs attention".
    case allUserSkipped
    /// Every leaf was set to Force Older.
    case allForcedOlder
    /// Every leaf was set to Force Newer.
    case allForcedNewer
    /// Anything else — descendants disagree, OR a mix of override
    /// states + plain directions, OR there are no leaves (e.g. a
    /// folder that has lost all its children due to filtering).
    case mixed
}

extension ReconcileNode {
    /// Walk the subtree and classify it. O(leaves under this node).
    /// Folders call this lazily on each render; the controller caches
    /// the result when convenient.
    ///
    /// Override rules:
    ///   - All leaves carry the same override          → that override's aggregate
    ///     (e.g. all .forceNewer ⇒ .allForcedNewer).
    ///   - No leaf carries any override AND all leaves share one
    ///     OCaml direction string                       → .uniform(direction).
    ///   - Mix of overrides, or mix of directions       → .mixed.
    ///
    /// The "all same override" rule deliberately *overrides* a uniform
    /// underlying direction so a folder whose every leaf is "Force
    /// Newer" reads as forced rather than as the resulting arrow —
    /// matching the per-row decision-over-result semantics.
    func aggregate(items: [StateItem],
                   rowOverrides: [Int: RowOverride]) -> FolderAggregate {
        var directions = Set<String>()
        var overrides: [RowOverride?] = []
        var leafCount = 0

        func walk(_ node: ReconcileNode) {
            if let row = node.row, row < items.count {
                directions.insert(items[row].direction)
                overrides.append(rowOverrides[row])
                leafCount += 1
            } else {
                for c in node.children { walk(c) }
            }
        }
        walk(self)

        if leafCount == 0 { return .mixed }

        // All leaves share one override? Folder picks up that override's
        // aggregate, hiding the underlying direction.
        if let first = overrides.first, let firstOverride = first,
           overrides.allSatisfy({ $0 == firstOverride }) {
            switch firstOverride {
            case .skip:        return .allUserSkipped
            case .forceOlder:  return .allForcedOlder
            case .forceNewer:  return .allForcedNewer
            }
        }

        // No leaf has an override AND all directions agree?
        // (Plain auto-resolution case — fallthrough from the override
        // checks above.)
        if overrides.allSatisfy({ $0 == nil }),
           directions.count == 1, let only = directions.first {
            return .uniform(only)
        }

        // Mixed-skipped-with-conflict special case: every leaf is
        // "<-?->" but only some are skipped — the unskipped ones still
        // need attention, so render the folder as conflict-orange rather
        // than mixed. Preserved from the pre-override design.
        if directions == ["<-?->"],
           overrides.allSatisfy({ $0 == nil || $0 == .skip }) {
            return .uniform("<-?->")
        }

        return .mixed
    }
}

/// Builds a tree from a flat `[StateItem]` for the reconcile outline
/// view. Three layout modes, mirroring upstream Unison's "Switch table
/// nesting" segmented control:
///
/// - **`.flat`** — every leaf is a direct child of the synthetic root;
///   no intermediate folder nodes. The Path column shows the full
///   path per row. Useful when the user wants a flat alphabetical
///   list of every affected file regardless of where it sits in the
///   directory tree.
/// - **`.nestedCollapsed`** — full path-segment tree, then any folder
///   with exactly one child is merged with that child by concatenating
///   names (`a/b/c/leaf.txt` instead of four separate rows). Compact
///   for deep paths through otherwise-uninteresting directories.
///   Mirrors upstream's `collapseParentsWithSingleChildren`.
/// - **`.nestedFull`** — full path-segment tree, no collapsing. Every
///   directory level is its own row. Most hierarchical, busiest
///   visually.
///
/// Path semantics follow Unison's convention: forward-slash separated,
/// no leading slash (the path is relative to each replica's root).
struct ReconcileTree {

    /// Which structural mode the tree was built with. Three modes that
    /// match the user-facing "Layout" setting one-to-one. Stored on the
    /// tree so consumers (e.g. expand-policy logic, the outline view
    /// data source) can adapt without re-reading user defaults.
    enum LayoutMode: String, CaseIterable {
        /// Every leaf is a top-level row; no folder nodes.
        case flat
        /// Path-segment tree with single-child chains merged. Default.
        case nestedCollapsed
        /// Path-segment tree with every folder level as its own row.
        case nestedFull
    }

    /// How aggressively folders are pre-expanded on first populate.
    /// Independent of `LayoutMode` — applies to both nested layouts;
    /// flat layout has no folders so the policy is irrelevant there
    /// (`nodesToExpand` returns an empty set).
    enum ExpandPolicy: String, CaseIterable {
        /// Expand only folders whose subtree contains a row that
        /// needs the user's attention (conflict without an override).
        /// Default. Matches upstream Unison's `expandConflictedParent`.
        case smart
        /// Expand every folder. Fully revealed Finder-style outline.
        /// Today's behavior before this setting existed.
        case all
        /// Expand nothing — show only top-level entries; user drills
        /// in by clicking. Useful for very large diffs.
        case rootOnly
    }

    /// Synthetic root. Its `children` are the top-level entries.
    let root: ReconcileNode

    /// Total leaves in the tree. Equals the input `items.count`.
    let leafCount: Int

    /// Mode used to construct this tree.
    let layoutMode: LayoutMode

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

    init(items: [StateItem], layout: LayoutMode = .nestedFull) {
        let root = ReconcileNode(name: "")
        self.layoutMode = layout
        switch layout {
        case .flat:
            // Every leaf becomes a direct child of root. Name = full
            // path (so the Path column shows it verbatim). No
            // intermediate folder nodes are created.
            for (index, item) in items.enumerated() {
                let node = ReconcileNode(
                    name: item.path, row: index, fullPath: item.path)
                node.parent = root
                root.children.append(node)
            }
        case .nestedFull, .nestedCollapsed:
            for (index, item) in items.enumerated() {
                ReconcileTree.insert(path: item.path, row: index, into: root)
            }
            if layout == .nestedCollapsed {
                ReconcileTree.collapseSingleChildChains(in: root)
            }
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

    /// Compute which folder nodes should be expanded on first
    /// populate, given a policy + the underlying items. Pure: returns
    /// a set the caller (`ReconcileWindowController.replaceItems`)
    /// then iterates to call `outlineView.expandItem(_:)`.
    ///
    /// - `.all` — every folder node in the tree (today's default
    ///   behavior — fully revealed Finder-style outline).
    /// - `.smart` — only folders whose subtree contains a row that
    ///   needs the user's attention (conflict `<-?->` without an
    ///   override). Other folders stay collapsed; the user drills in
    ///   manually. Mirrors upstream Unison's `expandConflictedParent`
    ///   pass. Default — usually fewer rows are visible, which makes
    ///   the rows that matter easier to spot.
    /// - `.rootOnly` — none of the folders are expanded; the outline
    ///   shows only top-level entries. Useful for very large diffs
    ///   where the user wants to navigate by clicking in.
    ///
    /// `rowOverrides` is consulted so a conflict that's already
    /// overridden (Skip / Force Older / Force Newer) no longer counts
    /// as "needs attention" under `.smart` — the user has already
    /// decided on that row.
    func nodesToExpand(
        policy: ExpandPolicy,
        items: [StateItem],
        rowOverrides: [Int: RowOverride]
    ) -> [ReconcileNode] {
        switch policy {
        case .rootOnly:
            return []
        case .all:
            // Every folder (non-leaf), excluding the synthetic root
            // itself (the outline view's caller will handle showing
            // top-level items unconditionally).
            return allNodes.filter { !$0.isLeaf }
        case .smart:
            return smartNodesToExpand(items: items, rowOverrides: rowOverrides)
        }
    }

    /// "Expand only what needs attention" — return every folder node
    /// whose subtree contains at least one unresolved conflict row.
    /// Walked recursively, so a single deeply-buried conflict expands
    /// the whole ancestor chain.
    private func smartNodesToExpand(
        items: [StateItem],
        rowOverrides: [Int: RowOverride]
    ) -> [ReconcileNode] {
        var result: [ReconcileNode] = []
        // Returns true if THIS subtree contains an unresolved conflict.
        @discardableResult
        func walk(_ node: ReconcileNode) -> Bool {
            if let row = node.row {
                // Leaf — does this row need attention? Conflict
                // direction AND no user override.
                guard row < items.count else { return false }
                let isConflict = items[row].direction
                    == ReconcileSummary.directionConflict
                let hasOverride = rowOverrides[row] != nil
                return isConflict && !hasOverride
            }
            var subtreeHasConflict = false
            for child in node.children {
                if walk(child) { subtreeHasConflict = true }
            }
            // Don't add the synthetic root to the expand list — the
            // outline view always shows top-level items.
            if subtreeHasConflict, !node.name.isEmpty {
                result.append(node)
            }
            return subtreeHasConflict
        }
        walk(root)
        return result
    }

    /// Walk the tree bottom-up and merge any non-root node that has
    /// exactly one child into that child. The child's `name` becomes
    /// the joined path of the absorbed chain (`a/b/c/file.txt` instead
    /// of four separate rows). Mirrors upstream Unison's
    /// `ReconItem.collapseParentsWithSingleChildren:` in
    /// `src/uimac/ReconItem.m`.
    ///
    /// Leaves stay leaves (row + fullPath survive); folders that
    /// absorb a single-folder child become combined-name folders that
    /// still hold the child's grandchildren.
    static func collapseSingleChildChains(in root: ReconcileNode) {
        // Internal recursive collapse — returns the node that should
        // appear at the caller's position. May be `node` itself
        // (collapse didn't apply or this is root) or the absorbed
        // child (collapse happened — caller should substitute).
        func collapse(_ node: ReconcileNode, isRoot: Bool) -> ReconcileNode {
            // Collapse children first (bottom-up).
            for i in 0..<node.children.count {
                let collapsed = collapse(node.children[i], isRoot: false)
                if collapsed !== node.children[i] {
                    collapsed.parent = node
                    node.children[i] = collapsed
                }
            }
            // Now decide if THIS node collapses into its single child.
            // Root is never collapsed (would lose the synthetic anchor).
            // A node with multiple children stays put. A leaf has no
            // children to absorb into; the `children.count == 1` gate
            // already excludes it.
            if !isRoot, node.children.count == 1 {
                let child = node.children[0]
                child.name = "\(node.name)/\(child.name)"
                // child.parent will be re-pointed to node.parent by the
                // caller's substitution.
                return child
            }
            return node
        }
        _ = collapse(root, isRoot: true)
    }
}
