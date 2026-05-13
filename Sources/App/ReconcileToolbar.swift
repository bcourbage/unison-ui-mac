import AppKit

/// A per-row direction-override the user can apply to selected reconcile
/// rows. Each binds to the matching ri-set bridge call. Naming follows
/// the upstream manual's terminology: the two endpoints are the "first"
/// and "second" replicas, in .prf-line order. `toSecond` = propagate
/// first → second (right arrow); `toFirst` = propagate second → first
/// (left arrow).
///
/// **Toolbar vs menu**: `.toFirst / .toSecond / .skip / .merge` live in
/// the toolbar's segmented group (`Self.toolbarActions`) AND on the
/// Edit menu. `.forceOlder / .forceNewer` are menu-only — they pick a
/// direction based on mtime and are needed often enough to expose but
/// rarely enough that they don't earn toolbar real estate. Matches the
/// legacy app's menu structure.
enum DirectionAction: CaseIterable {
    case toSecond    // first wins  -> data flows first → second  ➡
    case toFirst     // second wins -> data flows second → first  ⬅
    case skip        // mark conflict (don't sync)
    case merge       // run merge — only useful with `merge` pref configured
    case forceOlder  // propagate the older mtime side over the newer
    case forceNewer  // propagate the newer mtime side over the older

    var label: String {
        switch self {
        case .toSecond:   return "→ Second"
        case .toFirst:    return "← First"
        case .skip:       return "Skip"
        case .merge:      return "Merge"
        case .forceOlder: return "Force Older"
        case .forceNewer: return "Force Newer"
        }
    }

    var systemSymbol: String {
        switch self {
        case .toSecond:   return "arrow.right"
        case .toFirst:    return "arrow.left"
        case .skip:       return "minus.circle"
        case .merge:      return "arrow.triangle.merge"
        case .forceOlder: return "clock.arrow.circlepath"
        case .forceNewer: return "clock.badge"
        }
    }

    /// Per-action accent for the toolbar icon. Same palette as the row tints
    /// (see StateItem.rowTint) so the visual language is consistent.
    var accentColor: NSColor {
        switch self {
        case .toSecond:   return .systemGreen
        case .toFirst:    return .systemBlue
        case .skip:       return .systemOrange
        case .merge:      return .systemPurple
        case .forceOlder: return .systemBrown
        case .forceNewer: return .systemTeal
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        switch self {
        case .toSecond:   return .init("dir.toSecond")
        case .toFirst:    return .init("dir.toFirst")
        case .skip:       return .init("dir.skip")
        case .merge:      return .init("dir.merge")
        case .forceOlder: return .init("dir.forceOlder")
        case .forceNewer: return .init("dir.forceNewer")
        }
    }

    static let goIdentifier         = NSToolbarItem.Identifier("sync.go")
    static let stopIdentifier       = NSToolbarItem.Identifier("sync.stop")
    static let rescanIdentifier     = NSToolbarItem.Identifier("sync.rescan")
    static let profilesIdentifier   = NSToolbarItem.Identifier("nav.profiles")
    /// Segmented-control group hosting the toolbar direction items.
    static let directionGroupIdentifier = NSToolbarItem.Identifier("dir.group")

    func invoke(row: Int32) -> UnsafePointer<CChar>? {
        switch self {
        // Bridge function names retain "to_remote / to_local" because they
        // mirror the OCaml `unisonRiSetRight / unisonRiSetLeft` callback
        // names — that's the layer where direction is unambiguous (right
        // = second column, left = first column). Renaming the bridge would
        // mean either patching upstream or adding a translation layer.
        case .toSecond:   return unison_bridge_ri_set_to_remote(row)
        case .toFirst:    return unison_bridge_ri_set_to_local(row)
        case .skip:       return unison_bridge_ri_set_skip(row)
        case .merge:      return unison_bridge_ri_set_merge(row)
        case .forceOlder: return unison_bridge_ri_force_older(row)
        case .forceNewer: return unison_bridge_ri_force_newer(row)
        }
    }

    /// Stable per-action tag for menu items. Reserved range 1–9 (1–4
    /// are also the toolbar group's segmented-control tags; menu items
    /// use the same numbers since they share `applyDirection`). Distinct
    /// from IgnoreAction's 101+ range.
    var menuTag: Int {
        switch self {
        case .toSecond:   return 1
        case .toFirst:    return 2
        case .skip:       return 3
        case .merge:      return 4
        case .forceOlder: return 5
        case .forceNewer: return 6
        }
    }

    static func from(menuTag tag: Int) -> DirectionAction? {
        DirectionAction.allCases.first { $0.menuTag == tag }
    }

    /// Display order in the toolbar group, left → right.
    /// First first (matches the column reading "First → Second"), then
    /// Second, then non-direction outcomes (Skip, Merge). Force older/
    /// newer are menu-only and omitted here.
    static let toolbarActions: [DirectionAction] = [.toFirst, .toSecond, .skip, .merge]

    /// Action menu order — direction first, then alternatives, then
    /// the mtime-based force variants. Matches the legacy app's Action
    /// menu layout. Used by `MainMenu` to populate the menu items.
    static let menuActions: [DirectionAction] = [
        .toFirst, .toSecond, .skip, .merge, .forceOlder, .forceNewer,
    ]
}

@MainActor
final class ReconcileToolbarDelegate: NSObject, NSToolbarDelegate {

    weak var controller: ReconcileWindowController?

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [DirectionAction.profilesIdentifier,
         DirectionAction.rescanIdentifier,
         DirectionAction.directionGroupIdentifier,
         DirectionAction.goIdentifier,
         DirectionAction.stopIdentifier,
         .flexibleSpace, .space]
    }

    /// Reading order: navigation (Profiles) → context refresh (Rescan) →
    /// per-row direction overrides (segmented group) → flexible space →
    /// primary action (Go) → escape hatch (Stop). Placing Stop on the far
    /// right separates "destructive" from "primary" visually.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Two .space items between clusters give a clearer visual break than
        // one — Profiles/Rescan are navigation+context, the direction group
        // is per-row action, Go/Stop are workflow primary/escape.
        [DirectionAction.profilesIdentifier,
         DirectionAction.rescanIdentifier,
         .space, .space,
         DirectionAction.directionGroupIdentifier,
         .space, .space,
         .flexibleSpace,
         DirectionAction.goIdentifier,
         DirectionAction.stopIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case DirectionAction.profilesIdentifier:
            return makeWorkflowItem(itemIdentifier,
                                    label: "Profiles",
                                    paletteLabel: "Choose Profile",
                                    toolTip: "Return to the profile picker",
                                    symbol: "list.bullet",
                                    tint: nil,
                                    action: #selector(profilesAction(_:)))
        case DirectionAction.goIdentifier:
            return makeWorkflowItem(itemIdentifier,
                                    label: "Go",
                                    paletteLabel: "Synchronize",
                                    toolTip: "Run synchronization",
                                    symbol: "play.fill",
                                    tint: .systemGreen,
                                    action: #selector(goAction(_:)))
        case DirectionAction.stopIdentifier:
            return makeWorkflowItem(itemIdentifier,
                                    label: "Stop",
                                    paletteLabel: "Cancel sync",
                                    toolTip: "Cancel the running synchronization",
                                    symbol: "stop.fill",
                                    tint: .systemRed,
                                    action: #selector(stopAction(_:)))
        case DirectionAction.rescanIdentifier:
            return makeWorkflowItem(itemIdentifier,
                                    label: "Rescan",
                                    paletteLabel: "Rescan",
                                    toolTip: "Re-check both replicas for changes",
                                    symbol: "arrow.clockwise",
                                    tint: nil,
                                    action: #selector(rescanAction(_:)))
        case DirectionAction.directionGroupIdentifier:
            return makeDirectionGroup(itemIdentifier)
        default:
            return nil
        }
    }

    // MARK: - Item factories

    private func makeWorkflowItem(_ id: NSToolbarItem.Identifier,
                                  label: String,
                                  paletteLabel: String,
                                  toolTip: String,
                                  symbol: String,
                                  tint: NSColor?,
                                  action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = paletteLabel
        item.toolTip = toolTip
        item.image = symbolImage(symbol, accessibility: label, tint: tint)
        item.target = self
        item.action = action
        return item
    }

    /// Build the segmented group of direction overrides. `selectionMode
    /// = .momentary` because each click is an action (not a toggle) —
    /// clicking "← First" applies that direction to the selection, it
    /// isn't a sticky state on the toolbar.
    ///
    /// **Merge filtering**: when the active profile has no `merge` pref
    /// configured, the .merge subitem is omitted entirely. The action
    /// would silently fail at sync time otherwise — better to hide a
    /// useless button than to gray it out with no explanation, since
    /// "configure merge in your .prf" isn't something the user can do
    /// from the reconcile window. Set via `controller.mergeConfigured`
    /// at init time (one .prf parse per reconcile-window open).
    private func makeDirectionGroup(_ id: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.label = "Direction"
        group.paletteLabel = "Set Direction"
        group.controlRepresentation = .expanded
        group.selectionMode = .momentary

        let mergeConfigured = controller?.mergeConfigured ?? true
        let actions = DirectionAction.toolbarActions.filter { action in
            action != .merge || mergeConfigured
        }
        let subitems: [NSToolbarItem] = actions.map { action in
            let sub = NSToolbarItem(itemIdentifier: action.toolbarIdentifier)
            sub.label = action.label
            sub.paletteLabel = action.label
            sub.toolTip = action.label
            sub.image = symbolImage(action.systemSymbol,
                                    accessibility: action.label,
                                    tint: action.accentColor)
            sub.target = self
            sub.action = #selector(toolbarAction(_:))
            sub.tag = action.menuTag
            return sub
        }
        group.subitems = subitems
        return group
    }

    /// SF Symbol with optional palette tint. nil tint = system monochrome.
    private func symbolImage(_ name: String, accessibility: String, tint: NSColor?) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility)
        guard let tint else { return image }
        let config = NSImage.SymbolConfiguration(paletteColors: [tint])
        return image?.withSymbolConfiguration(config)
    }

    // MARK: - Actions

    @objc private func toolbarAction(_ sender: NSToolbarItem) {
        guard let action = DirectionAction.from(menuTag: sender.tag) else { return }
        controller?.applyDirection(action)
    }

    @objc private func goAction(_ sender: NSToolbarItem) {
        controller?.startSync()
    }

    @objc private func stopAction(_ sender: NSToolbarItem) {
        controller?.cancelSync()
    }

    @objc private func rescanAction(_ sender: NSToolbarItem) {
        controller?.rescan()
    }

    @objc private func profilesAction(_ sender: NSToolbarItem) {
        controller?.returnToPicker()
    }
}

// (Previously: directionActionTag / directionActionFromTag — both
// folded into DirectionAction.menuTag / DirectionAction.from(menuTag:)
// so the toolbar AND the menu use the same tag scheme.)
