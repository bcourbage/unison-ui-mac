import Foundation

/// View-only state about profiles that the user controls via the profile
/// editor: which profiles to hide from the picker, and in what custom
/// order to display the visible ones.
///
/// **None of this touches the `.prf` files.** The CLI `unison <profile>`
/// still sees every profile by basename; only this app's picker filters
/// and reorders. That's a deliberate split — we don't want to introduce
/// a side-channel that the CLI ignores into the .prf format itself.
///
/// Storage lives in `UserDefaults.standard` under
/// `net.courbage.unison-ui-mac` keys:
///   - `profiles.hidden`  : `[String]` of basenames the user has hidden
///   - `profiles.order`   : `[String]` of basenames in user-chosen order
///
/// `apply(to:)` is the single chokepoint that merges disk reality with
/// user preferences:
///   1. Drop any basename in `hidden` (unless `includeHidden = true`).
///   2. Place basenames listed in `order` in that order at the top.
///   3. Append remaining basenames alphabetically.
///
/// A basename present in `order` but absent from the on-disk set is
/// silently ignored — the order list is treated as a soft ranking, not
/// an authoritative roster. (Likewise, a hidden basename that no longer
/// exists on disk just contributes nothing.)
struct ProfilePreferences: Equatable {

    static let hiddenKey = "profiles.hidden"
    static let orderKey = "profiles.order"

    var hidden: Set<String>
    var order: [String]

    init(hidden: Set<String> = [], order: [String] = []) {
        self.hidden = hidden
        self.order = order
    }

    // MARK: - Persistence

    /// Load from UserDefaults. Returns an empty preferences value when no
    /// keys are set (first run, or after a `Reset Defaults`).
    static func load(from defaults: UserDefaults = .standard) -> ProfilePreferences {
        let hiddenList = defaults.stringArray(forKey: hiddenKey) ?? []
        let orderList = defaults.stringArray(forKey: orderKey) ?? []
        return ProfilePreferences(hidden: Set(hiddenList), order: orderList)
    }

    /// Save to UserDefaults. Writes immediately; `UserDefaults` debounces
    /// disk writes itself so we don't need to.
    func save(to defaults: UserDefaults = .standard) {
        // Hidden is stored as a sorted array (not a set) so the on-disk
        // representation is stable + diffable; ordering of the saved
        // hidden list is purely cosmetic for "defaults read" output.
        defaults.set(hidden.sorted(), forKey: Self.hiddenKey)
        defaults.set(order, forKey: Self.orderKey)
    }

    // MARK: - Mutations

    /// Flip a profile's hidden state. Idempotent — calling with the same
    /// profile twice returns to the original state.
    mutating func toggleHidden(_ profile: String) {
        if hidden.contains(profile) {
            hidden.remove(profile)
        } else {
            hidden.insert(profile)
        }
    }

    /// Replace the entire custom order. Pass an empty array to "forget"
    /// the user's ordering and let the picker fall back to alphabetical.
    mutating func setOrder(_ newOrder: [String]) {
        order = newOrder
    }

    /// Drop a profile from both the order list and the hidden set. Use
    /// when a .prf has been deleted from disk to keep the preferences
    /// from accumulating stale entries.
    mutating func forget(_ profile: String) {
        hidden.remove(profile)
        order.removeAll { $0 == profile }
    }

    /// Carry view preferences across a rename — the renamed profile
    /// keeps its position in the custom order and its hidden state. No-op
    /// if `oldName` isn't tracked.
    ///
    /// Used by `ProfileFormWindowController.saveAction` when the user
    /// changes the Profile Name field. Centralized here so the inline-
    /// rename feature (P3) and any future bulk-rename UI use the same
    /// state-migration logic.
    mutating func rename(_ oldName: String, to newName: String) {
        guard oldName != newName else { return }
        if let idx = order.firstIndex(of: oldName) {
            order[idx] = newName
        }
        if hidden.contains(oldName) {
            hidden.remove(oldName)
            hidden.insert(newName)
        }
    }

    // MARK: - Application

    // MARK: - Drag-reorder

    /// Compute a new ordering for `current` after moving `moving` to the
    /// position currently occupied by `dropRow` (an "above" drop in
    /// NSTableView terms — `dropRow == 0` means "before the first row",
    /// `dropRow == current.count` means "after the last row").
    ///
    /// Why this exists: the drop-row index is measured against the
    /// pre-move array, but our move-then-insert algorithm runs against
    /// the array AFTER removals. Without compensation, dragging row 2 to
    /// "position 5" silently lands at position 4. The math is fiddly
    /// enough that it earns a pure-function home + tests.
    ///
    /// Names in `moving` that aren't in `current` are ignored (defensive
    /// — pasteboard payloads can survive across reloads of the source
    /// table). Duplicates in `moving` get de-duplicated.
    static func reorder(_ current: [String],
                        moving: [String],
                        toDropRow dropRow: Int) -> [String] {
        // De-dup while preserving order; keep only names actually in current.
        var seen = Set<String>()
        let dedupMoving = moving.filter { name in
            guard current.contains(name), !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
        if dedupMoving.isEmpty { return current }

        let movedIndices = dedupMoving.compactMap { current.firstIndex(of: $0) }
        // Each moved row whose index sits BEFORE dropRow shifts the
        // effective insertion position down by one when we remove it.
        let removalsBeforeDrop = movedIndices.filter { $0 < dropRow }.count
        var insertionRow = dropRow - removalsBeforeDrop

        var newOrder = current
        let movedSet = Set(dedupMoving)
        newOrder.removeAll { movedSet.contains($0) }
        insertionRow = max(0, min(insertionRow, newOrder.count))
        newOrder.insert(contentsOf: dedupMoving, at: insertionRow)
        return newOrder
    }

    // MARK: - Apply

    /// Filter + sort `available` (raw basenames found on disk) per this
    /// preferences value. With `includeHidden = false` (the picker view)
    /// hidden profiles are dropped; with `includeHidden = true` (the
    /// editor view) they're kept so the user can unhide them.
    ///
    /// Ordering: every basename in `order` that's actually on disk comes
    /// first, in `order`-list sequence. Remaining basenames follow,
    /// alphabetically by Foundation's default Locale-aware comparison.
    func apply(to available: [String], includeHidden: Bool) -> [String] {
        let pool = Set(available)
        let inOrder = order.filter { pool.contains($0) }
        let inOrderSet = Set(inOrder)
        let leftover = available
            .filter { !inOrderSet.contains($0) }
            .sorted()
        let merged = inOrder + leftover
        if includeHidden { return merged }
        return merged.filter { !hidden.contains($0) }
    }
}
