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

    var toolbarIdentifier: NSToolbarItem.Identifier {
        switch self {
        case .toRemote: return .init("dir.toRemote")
        case .toLocal:  return .init("dir.toLocal")
        case .skip:     return .init("dir.skip")
        case .merge:    return .init("dir.merge")
        }
    }

    static let goIdentifier       = NSToolbarItem.Identifier("sync.go")
    static let stopIdentifier     = NSToolbarItem.Identifier("sync.stop")
    static let rescanIdentifier   = NSToolbarItem.Identifier("sync.rescan")
    static let profilesIdentifier = NSToolbarItem.Identifier("nav.profiles")

    func invoke(row: Int32) -> UnsafePointer<CChar>? {
        switch self {
        case .toRemote: return unison_bridge_ri_set_to_remote(row)
        case .toLocal:  return unison_bridge_ri_set_to_local(row)
        case .skip:     return unison_bridge_ri_set_skip(row)
        case .merge:    return unison_bridge_ri_set_merge(row)
        }
    }

    static let all: [DirectionAction] = [.toLocal, .toRemote, .skip, .merge]
}

@MainActor
final class ReconcileToolbarDelegate: NSObject, NSToolbarDelegate {

    weak var controller: ReconcileWindowController?

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        DirectionAction.all.map(\.toolbarIdentifier) + [
            DirectionAction.profilesIdentifier,
            DirectionAction.rescanIdentifier,
            DirectionAction.goIdentifier,
            DirectionAction.stopIdentifier,
            .flexibleSpace, .space,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [DirectionAction.profilesIdentifier,
         .space,
         DirectionAction.toLocal.toolbarIdentifier,
         DirectionAction.toRemote.toolbarIdentifier,
         DirectionAction.skip.toolbarIdentifier,
         DirectionAction.merge.toolbarIdentifier,
         .flexibleSpace,
         DirectionAction.rescanIdentifier,
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
                                    action: #selector(profilesAction(_:)))
        case DirectionAction.goIdentifier:
            return makeWorkflowItem(itemIdentifier,
                                    label: "Go",
                                    paletteLabel: "Synchronize",
                                    toolTip: "Run synchronization",
                                    symbol: "play.fill",
                                    action: #selector(goAction(_:)))
        case DirectionAction.stopIdentifier:
            return makeWorkflowItem(itemIdentifier,
                                    label: "Stop",
                                    paletteLabel: "Cancel sync",
                                    toolTip: "Cancel the running synchronization",
                                    symbol: "stop.fill",
                                    action: #selector(stopAction(_:)))
        case DirectionAction.rescanIdentifier:
            return makeWorkflowItem(itemIdentifier,
                                    label: "Rescan",
                                    paletteLabel: "Rescan",
                                    toolTip: "Re-check both replicas for changes",
                                    symbol: "arrow.clockwise",
                                    action: #selector(rescanAction(_:)))
        default:
            break
        }
        guard let action = DirectionAction.all.first(where: { $0.toolbarIdentifier == itemIdentifier }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = action.label
        item.paletteLabel = action.label
        item.toolTip = action.label
        item.image = NSImage(systemSymbolName: action.systemSymbol, accessibilityDescription: action.label)
        item.target = self
        item.action = #selector(toolbarAction(_:))
        item.tag = directionActionTag(action)
        return item
    }

    private func makeWorkflowItem(_ id: NSToolbarItem.Identifier,
                                  label: String,
                                  paletteLabel: String,
                                  toolTip: String,
                                  symbol: String,
                                  action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = paletteLabel
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }

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
