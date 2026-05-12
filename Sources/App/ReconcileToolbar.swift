import AppKit

/// One of the four direction-override operations the user can apply to
/// selected reconcile rows. Each binds to the matching ri-set bridge call.
enum DirectionAction {
    case toRemote   // local wins  -> data flows ➡
    case toLocal    // remote wins -> data flows ⬅
    case skip       // mark conflict (don't sync)
    case merge      // run merge — only useful with `merge` pref configured

    var label: String {
        switch self {
        case .toRemote: return "→ Remote"
        case .toLocal:  return "← Local"
        case .skip:     return "Skip"
        case .merge:    return "Merge"
        }
    }

    var systemSymbol: String {
        switch self {
        case .toRemote: return "arrow.right"
        case .toLocal:  return "arrow.left"
        case .skip:     return "minus.circle"
        case .merge:    return "arrow.triangle.merge"
        }
    }

    /// Per-action accent for the toolbar icon. Same palette as the row tints
    /// (see StateItem.rowTint) so the visual language is consistent.
    var accentColor: NSColor {
        switch self {
        case .toRemote: return .systemGreen
        case .toLocal:  return .systemBlue
        case .skip:     return .systemOrange
        case .merge:    return .systemPurple
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        switch self {
        case .toRemote: return .init("dir.toRemote")
        case .toLocal:  return .init("dir.toLocal")
        case .skip:     return .init("dir.skip")
        case .merge:    return .init("dir.merge")
        }
    }

    static let goIdentifier         = NSToolbarItem.Identifier("sync.go")
    static let stopIdentifier       = NSToolbarItem.Identifier("sync.stop")
    static let rescanIdentifier     = NSToolbarItem.Identifier("sync.rescan")
    static let profilesIdentifier   = NSToolbarItem.Identifier("nav.profiles")
    /// Segmented-control group hosting all four direction items.
    static let directionGroupIdentifier = NSToolbarItem.Identifier("dir.group")

    func invoke(row: Int32) -> UnsafePointer<CChar>? {
        switch self {
        case .toRemote: return unison_bridge_ri_set_to_remote(row)
        case .toLocal:  return unison_bridge_ri_set_to_local(row)
        case .skip:     return unison_bridge_ri_set_skip(row)
        case .merge:    return unison_bridge_ri_set_merge(row)
        }
    }

    /// Display order in the toolbar group, left → right.
    /// Local first (matches direction column reading "Local → Remote"), then
    /// Remote, then non-direction outcomes (Skip, Merge).
    static let all: [DirectionAction] = [.toLocal, .toRemote, .skip, .merge]
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
        [DirectionAction.profilesIdentifier,
         DirectionAction.rescanIdentifier,
         .space,
         DirectionAction.directionGroupIdentifier,
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

    /// Build a single segmented group containing all four direction overrides.
    /// `selectionMode = .momentary` because each click is an action (not a
    /// toggle) — clicking "← Local" applies that direction to the selection,
    /// it isn't a sticky state on the toolbar.
    private func makeDirectionGroup(_ id: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.label = "Direction"
        group.paletteLabel = "Set Direction"
        group.controlRepresentation = .expanded
        group.selectionMode = .momentary

        let subitems: [NSToolbarItem] = DirectionAction.all.map { action in
            let sub = NSToolbarItem(itemIdentifier: action.toolbarIdentifier)
            sub.label = action.label
            sub.paletteLabel = action.label
            sub.toolTip = action.label
            sub.image = symbolImage(action.systemSymbol,
                                    accessibility: action.label,
                                    tint: action.accentColor)
            sub.target = self
            sub.action = #selector(toolbarAction(_:))
            sub.tag = directionActionTag(action)
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
        guard let action = directionActionFromTag(sender.tag) else { return }
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

private func directionActionTag(_ action: DirectionAction) -> Int {
    switch action {
    case .toRemote: return 1
    case .toLocal:  return 2
    case .skip:     return 3
    case .merge:    return 4
    }
}

private func directionActionFromTag(_ tag: Int) -> DirectionAction? {
    switch tag {
    case 1: return .toRemote
    case 2: return .toLocal
    case 3: return .skip
    case 4: return .merge
    default: return nil
    }
}
