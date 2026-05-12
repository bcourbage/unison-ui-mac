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

    static let goIdentifier = NSToolbarItem.Identifier("sync.go")

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
        DirectionAction.all.map(\.toolbarIdentifier) + [DirectionAction.goIdentifier, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [DirectionAction.toLocal.toolbarIdentifier,
         DirectionAction.toRemote.toolbarIdentifier,
         DirectionAction.skip.toolbarIdentifier,
         DirectionAction.merge.toolbarIdentifier,
         .flexibleSpace,
         DirectionAction.goIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == DirectionAction.goIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Go"
            item.paletteLabel = "Synchronize"
            item.toolTip = "Run synchronization"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Go")
            item.target = self
            item.action = #selector(goAction(_:))
            return item
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

    @objc private func toolbarAction(_ sender: NSToolbarItem) {
        guard let action = directionActionFromTag(sender.tag) else { return }
        controller?.applyDirection(action)
    }

    @objc private func goAction(_ sender: NSToolbarItem) {
        controller?.startSync()
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
