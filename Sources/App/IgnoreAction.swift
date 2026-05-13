import AppKit

/// One of the three ignore-pattern operations a user can apply to a single
/// reconcile row. Mirrors the legacy UI's Edit-menu items "Ignore Path",
/// "Ignore Extension", "Ignore Name" and binds to the matching bridge call.
///
/// Each invocation:
/// 1. Registers a permanent ignore pattern via `Uicommon.addIgnorePattern`
///    (so it persists into the profile's ignore list on the next save).
/// 2. Re-runs OCaml's `unisonUpdateForIgnore`, which filters the global
///    reconcile state in place.
/// 3. Re-fires the init2-complete handler with the new state-item array.
///    The reconcile window replaces its rows in place — same code path as
///    a rescan.
///
/// The row index passed to `invoke(row:)` becomes meaningless after the
/// call returns: post-filter row numbering doesn't match pre-filter, so
/// callers must treat each ignore action as a one-shot per row.
enum IgnoreAction {
    /// Ignore exactly this path (e.g. `foo/bar/baz.txt`).
    case path
    /// Ignore anything with the same extension (e.g. `*.tmp`).
    case ext
    /// Ignore anything with the same basename, anywhere in the tree
    /// (e.g. `.DS_Store`).
    case name

    /// Label shown in menu items and context menus.
    var label: String {
        switch self {
        case .path: return "Ignore Path"
        case .ext:  return "Ignore Extension"
        case .name: return "Ignore Name"
        }
    }

    /// Stable identifier used for menu-item validation and tagging. Bumping
    /// requires updating the Edit menu wiring in MainMenu.swift.
    var menuTag: Int {
        switch self {
        case .path: return 101
        case .ext:  return 102
        case .name: return 103
        }
    }

    /// Returns true on success. Swallows the bool the bridge returns; the
    /// caller already knows it acted on the only selected row, and a false
    /// here means a build mismatch (the OCaml symbol wasn't registered) or
    /// an out-of-range row — both should already have been guarded.
    func invoke(row: Int32) -> Bool {
        switch self {
        case .path: return unison_bridge_ignore_path(row)
        case .ext:  return unison_bridge_ignore_ext(row)
        case .name: return unison_bridge_ignore_name(row)
        }
    }

    static let all: [IgnoreAction] = [.path, .ext, .name]

    static func from(tag: Int) -> IgnoreAction? {
        IgnoreAction.all.first { $0.menuTag == tag }
    }
}
