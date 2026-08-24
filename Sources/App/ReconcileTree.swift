import Foundation

/// A node in the reconcile-tree. Two traits combine freely (see the accessors
/// below): a node MAY carry its own reconcile row (`row != nil`,
/// `hasReconcileRow`) and/or have children (`isContainer`).
///   - **Terminal leaf**: a row, no children — a file/symlink reconcile item.
///     `row` indexes the controller's `items`; `fullPath` is the Unison path.
///   - **Grouping folder**: no row, has children — an intermediate path
///     component. The synthetic root is a nameless grouping folder.
///   - **Hybrid directory**: BOTH a row AND children — a directory that is
///     itself a reconcile item (e.g. a dir-property change) *and* has changed
///     descendants. It renders as an expandable folder while still carrying its
///     own row. So `row != nil` does NOT imply "leaf", and a folder does NOT
///     always have `row == nil`.
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
    /// The reconcile-result index this node carries, or nil for a pure grouping
    /// folder. A node can have BOTH a `row` and `children`: a directory that is
    /// itself one reconcile item (e.g. a dir-property change) *and* has changed
    /// descendants. Settable during tree build (`ReconcileTree.insert` may set
    /// the row on a folder node whose children were inserted first).
    fileprivate(set) var row: Int?
    fileprivate(set) var fullPath: String?
    fileprivate(set) var children: [ReconcileNode] = []
    weak var parent: ReconcileNode?

    // MARK: aggregate caches (0.4.2). Static ones (`aggTotalSize`,
    // `aggLeafCount`) are computed once by `ReconcileTree.computeAggregates`
    // after the tree is built and never change (a row's `sizeBytes` is fixed at
    // scan time). Dynamic ones advance incrementally as transfer progress
    // arrives (`ReconcileWindowController.reloadRow` walks the ancestor chain
    // applying per-row deltas), so folder cells render O(1) instead of
    // re-walking their subtree on every progress repaint.
    /// Σ `sizeBytes` (>0) over this node's own row and every descendant row.
    fileprivate(set) var aggTotalSize: Int64 = 0
    /// Number of rows in this subtree (own row + descendants).
    fileprivate(set) var aggLeafCount: Int = 0
    fileprivate(set) var aggDoneSize: Double = 0
    fileprivate(set) var aggTerminalCount: Int = 0
    fileprivate(set) var aggStartedCount: Int = 0

    init(name: String, row: Int? = nil, fullPath: String? = nil) {
        self.name = name
        self.row = row
        self.fullPath = fullPath
    }

    // A node has three orthogonal traits — a directory that is itself a
    // reconcile item AND has changed descendants is a *hybrid* that is both a
    // container and carries a row. Name the concepts explicitly rather than
    // overloading "leaf":
    /// Carries its own reconcile-result row (a file, or a directory that is
    /// itself a reconcile item).
    var hasReconcileRow: Bool { row != nil }
    /// Has children → expandable in the outline (folder icon, disclosure
    /// triangle). True for a hybrid directory even though it also has a row.
    var isContainer: Bool { !children.isEmpty }
    /// Renders as a single non-expandable line (no children).
    var isTerminalLeaf: Bool { children.isEmpty }

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

        // Count this node's OWN row (a directory that is itself a reconcile
        // item) and ALWAYS recurse into children — a node may carry both.
        func walk(_ node: ReconcileNode) {
            if let row = node.row, row < items.count {
                directions.insert(items[row].direction)
                overrides.append(rowOverrides[row])
                leafCount += 1
            }
            for c in node.children { walk(c) }
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

    /// Sum of `sizeBytes` (>0) over this node's own row and every descendant row
    /// — a folder's aggregate size (total of the *changed* items shown beneath
    /// it, plus its own if it is a directory reconcile item). O(subtree).
    /// The runtime path uses the cached `aggTotalSize`; this pure walk is the
    /// spec the cache is tested against (0.4.2).
    func aggregateSizeBytes(items: [StateItem]) -> Int64 {
        var total: Int64 = 0
        func walk(_ node: ReconcileNode) {
            if let row = node.row, row < items.count {
                total += ReconcileTree.contribution(of: items[row]).totalSize
            }
            for c in node.children { walk(c) }
        }
        walk(self)
        return total
    }

    /// Aggregate transfer progress over this node's own row + every descendant,
    /// as a fraction 0…1, for a folder's bar during sync. nil when the subtree
    /// has no rows or nothing has started yet. Byte-weighted when Σ size > 0;
    /// falls back to terminal-count / row-count for all-zero-size subtrees. The
    /// runtime path uses the cached `cachedProgressFraction()`; this pure walk is
    /// the spec the cache is tested against.
    func progressFraction(items: [StateItem]) -> Double? {
        var totalSize: Int64 = 0, doneSize = 0.0
        var leafCount = 0, terminalCount = 0, startedCount = 0
        func walk(_ node: ReconcileNode) {
            if let row = node.row, row < items.count {
                let c = ReconcileTree.contribution(of: items[row])
                totalSize += c.totalSize; doneSize += c.doneSize
                leafCount += c.leafCount; terminalCount += c.terminal
                startedCount += c.started
            }
            for c in node.children { walk(c) }
        }
        walk(self)
        return ReconcileTree.fraction(totalSize: totalSize, doneSize: doneSize,
                                      leafCount: leafCount, terminalCount: terminalCount,
                                      startedCount: startedCount)
    }

    /// O(1) folder progress from the cached accumulators (kept current
    /// incrementally). Equivalent to `progressFraction(items:)`.
    func cachedProgressFraction() -> Double? {
        ReconcileTree.fraction(totalSize: aggTotalSize, doneSize: aggDoneSize,
                               leafCount: aggLeafCount, terminalCount: aggTerminalCount,
                               startedCount: aggStartedCount)
    }

    /// Every reconcile row in this subtree — the node's OWN row (if any) plus
    /// every descendant row, each once (a path is unique in the tree). For a
    /// hybrid directory this yields its own directory row *and* its descendants.
    func subtreeRows() -> [Int] {
        var out: [Int] = []
        func walk(_ n: ReconcileNode) {
            if let row = n.row { out.append(row) }
            for c in n.children { walk(c) }
        }
        walk(self)
        return out
    }

    /// Apply a per-row progress delta to this node and every ancestor (walk to
    /// root), keeping the cached accumulators current in O(depth). Called by
    /// `ReconcileWindowController.reloadRow` after a leaf's progress changes.
    func applyProgressDelta(doneSize: Double, terminal: Int, started: Int) {
        var cursor: ReconcileNode? = self
        while let n = cursor {
            n.aggDoneSize += doneSize
            n.aggTerminalCount += terminal
            n.aggStartedCount += started
            cursor = n.parent
        }
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
        ReconcileTree.computeAggregates(root, items: items)
        self.root = root
        self.leafCount = items.count
    }

    private static func insert(path: String, row: Int, into root: ReconcileNode) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        var cursor = root
        for (i, part) in parts.enumerated() {
            let isLast = (i == parts.count - 1)
            // Descend into (or create) the node for this segment.
            if let existing = cursor.children.first(where: { $0.name == part }) {
                cursor = existing
            } else {
                let node = ReconcileNode(name: part)
                node.parent = cursor
                cursor.children.append(node)
                cursor = node
            }
            // The last segment is where this reconcile row lives. The node may
            // already exist as a grouping folder (its children were inserted
            // first) — a directory that is itself a reconcile item AND has
            // changed descendants. Attach the row here; a node can hold both a
            // row and children. Keep the first row on an exact-duplicate path
            // (Unison shouldn't emit duplicates).
            if isLast, cursor.row == nil {
                cursor.row = row
                cursor.fullPath = path
            }
        }
    }

    /// One row's contribution to a folder aggregate — the single source of truth
    /// for the from-scratch `ReconcileNode` walks AND the incremental cache
    /// (`computeAggregates` / `ReconcileWindowController.reloadRow`). `totalSize`
    /// is static (fixed at scan); the rest advance as transfer progress arrives.
    struct RowContribution {
        var totalSize: Int64   // sizeBytes if > 0, else 0
        var leafCount: Int     // always 1 (one row)
        var doneSize: Double   // size-weighted bytes considered transferred
        var terminal: Int      // 1 when done / FAILED
        var started: Int       // 1 when progress is non-empty
    }

    /// The reconcile rows targeted by a selection of nodes: each selected
    /// subtree's rows (own + descendants), deduplicated so a row is returned
    /// exactly once even when a node and one of its descendants are both
    /// selected. Preserves first-seen order. Pure — testable independently of
    /// the outline view.
    static func rows(inSelection nodes: [ReconcileNode]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for node in nodes {
            for row in node.subtreeRows() where seen.insert(row).inserted {
                out.append(row)
            }
        }
        return out
    }

    static func contribution(of it: StateItem) -> RowContribution {
        let p = it.progress.trimmingCharacters(in: .whitespaces)
        let isTerminal = p.caseInsensitiveCompare("done") == .orderedSame
            || p.uppercased().contains("FAIL")
        let size = it.sizeBytes > 0 ? it.sizeBytes : 0
        let done = size > 0
            ? (isTerminal ? Double(size) : Double(min(max(0, it.bytesTransferred), size)))
            : 0
        return RowContribution(totalSize: size, leafCount: 1, doneSize: done,
                               terminal: isTerminal ? 1 : 0, started: p.isEmpty ? 0 : 1)
    }

    /// Byte-weighted progress fraction (0…1) from accumulated sums; nil when the
    /// subtree has no rows or nothing has started. Shared by the pure walk and
    /// the cached reader so both agree.
    fileprivate static func fraction(totalSize: Int64, doneSize: Double, leafCount: Int,
                                     terminalCount: Int, startedCount: Int) -> Double? {
        guard leafCount > 0, startedCount > 0 else { return nil }
        if totalSize > 0 { return max(0, min(1, doneSize / Double(totalSize))) }
        return Double(terminalCount) / Double(leafCount)
    }

    /// Bottom-up pass filling every node's aggregate caches: static
    /// `aggTotalSize` / `aggLeafCount` (fixed at scan time) and the initial
    /// dynamic accumulators from each row's current progress (idle right after a
    /// scan). `ReconcileWindowController.reloadRow` then advances the dynamic
    /// ones incrementally. A node's aggregate is its OWN row plus its children's.
    static func computeAggregates(_ root: ReconcileNode, items: [StateItem]) {
        func walk(_ node: ReconcileNode) {
            var total: Int64 = 0, leaves = 0
            var done = 0.0, terminal = 0, started = 0
            if let row = node.row, row < items.count {
                let c = contribution(of: items[row])
                total += c.totalSize; leaves += c.leafCount
                done += c.doneSize; terminal += c.terminal; started += c.started
            }
            for child in node.children {
                walk(child)
                total += child.aggTotalSize; leaves += child.aggLeafCount
                done += child.aggDoneSize; terminal += child.aggTerminalCount
                started += child.aggStartedCount
            }
            node.aggTotalSize = total; node.aggLeafCount = leaves
            node.aggDoneSize = done; node.aggTerminalCount = terminal
            node.aggStartedCount = started
        }
        walk(root)
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
            return allNodes.filter { $0.isContainer }
        case .smart:
            return smartNodesToExpand(items: items, rowOverrides: rowOverrides)
        }
    }

    /// "Reveal failed rows" — return every folder node whose subtree
    /// contains at least one row in `failedRows`. Used by
    /// `ReconcileWindowController` after a sync completes with
    /// failures, to ensure ⚠ FAILED rows are visible regardless of
    /// the user's configured `ExpandPolicy` (which was chosen for
    /// the pre-sync diff, not for post-sync triage). Additive — the
    /// caller invokes this on top of the existing expand state, and
    /// the next rescan rebuilds the tree, so this widening is
    /// effectively one-shot.
    ///
    /// Pure: returns a set the caller iterates to call
    /// `outlineView.expandItem(_:)`. The configured policy is not
    /// mutated.
    ///
    /// The container nodes to `expandItem` so every row in `rows` becomes visible
    /// (its collapsed ancestor chain is revealed). Generic over an arbitrary row
    /// set — used post-sync to reveal FAILED rows and by Select Conflicts to reveal
    /// unresolved-conflict rows buried under collapsed folders (SF14). The
    /// configured expand policy is not mutated.
    func nodesToRevealRows(_ rows: Set<Int>) -> [ReconcileNode] {
        var result: [ReconcileNode] = []
        // Returns whether this node's OWN row or any descendant is in `rows`.
        // A hybrid directory node evaluates its own row AND recurses.
        @discardableResult
        func walk(_ node: ReconcileNode) -> Bool {
            let ownHit = node.row.map { rows.contains($0) } ?? false
            var childHit = false
            for child in node.children {
                if walk(child) { childHit = true }
            }
            // Expand a container when a DESCENDANT is a target, to reveal it. A node
            // whose own row is a target doesn't need expanding (it's a visible line);
            // its ancestors expand via the propagated return. Skip the synthetic
            // root (never an outline item).
            if childHit, !node.name.isEmpty {
                result.append(node)
            }
            return ownHit || childHit
        }
        walk(root)
        return result
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
        // Returns whether this node's OWN row or any descendant is an unresolved
        // conflict. A hybrid directory node evaluates its own row AND recurses.
        func needsAttention(_ row: Int) -> Bool {
            guard row < items.count else { return false }
            return items[row].direction == ReconcileSummary.directionConflict
                && rowOverrides[row] == nil
        }
        @discardableResult
        func walk(_ node: ReconcileNode) -> Bool {
            let ownConflict = node.row.map(needsAttention) ?? false
            var childConflict = false
            for child in node.children {
                if walk(child) { childConflict = true }
            }
            // Expand a container when a DESCENDANT needs attention, to reveal it.
            // A node whose own row conflicts doesn't need expanding (it's a
            // visible line); ancestors expand via the propagated return. Skip
            // the synthetic root.
            if childConflict, !node.name.isEmpty {
                result.append(node)
            }
            return ownConflict || childConflict
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
            // already excludes it. A node that carries its OWN row (a
            // directory reconcile item) must NOT collapse into its child —
            // that would discard the directory's own row.
            if !isRoot, node.children.count == 1, node.row == nil {
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
