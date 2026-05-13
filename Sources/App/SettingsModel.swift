import Foundation

/// Pure-logic backing for the Settings window. Knows the catalog of
/// UserDefaults keys this app writes, can describe their current state
/// in user-readable form, and can clear them on demand. Lives separately
/// from `SettingsWindowController` so the reset behavior is testable
/// without standing up AppKit.
///
/// **Scope.** Only the keys *this app* writes are listed here. We don't
/// try to reset system-level AppKit defaults (locale, LSQuarantine
/// metadata, NSApplicationCrashOnExceptions, etc.) — those aren't ours
/// to manage.
enum SettingsModel {

    // MARK: - Key catalog

    /// Keys for AppKit's automatic window-frame autosaves. Every
    /// `windowFrameAutosaveName` set on a controller in this project
    /// must be listed here so the "reset window & toolbar layout"
    /// button actually clears its frame. If you add a new window
    /// controller, extend this list.
    static let windowFrameAutosaveNames: [String] = [
        "ProfileWindow",
        "ProfileEditorWindow",
        "ProfileFormWindow",
        "ReconcileWindow",
        "DiffWindow",
        "SettingsWindow",
    ]

    /// AppKit stores autosaved window frames under `"NSWindow Frame <name>"`.
    static func windowFrameKey(_ autosaveName: String) -> String {
        "NSWindow Frame \(autosaveName)"
    }

    /// NSToolbar autosave keys we use. When `ReconcileToolbar` bumps
    /// its identifier suffix (currently `.v4`), the old key is
    /// orphaned; include retired versions so a reset cleans up the
    /// trail too.
    static let toolbarConfigurationKeys: [String] = [
        "NSToolbar Configuration ReconcileToolbar.v4",
        "NSToolbar Configuration ReconcileToolbar.v3",
    ]

    // MARK: - Profile picker layout

    /// `(hiddenCount, customOrderCount)` for the picker-layout section's
    /// descriptive label. Useful for "5 hidden, 12 in custom order" UI.
    static func profilePickerCounts(in defaults: UserDefaults = .standard)
        -> (hidden: Int, ordered: Int)
    {
        let hidden = (defaults.stringArray(forKey: ProfilePreferences.hiddenKey) ?? []).count
        let ordered = (defaults.stringArray(forKey: ProfilePreferences.orderKey) ?? []).count
        return (hidden, ordered)
    }

    /// Reset profile-picker layout: clear `profiles.hidden` and
    /// `profiles.order`. After this, every profile becomes visible
    /// and sorts alphabetically.
    static func resetProfilePickerLayout(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ProfilePreferences.hiddenKey)
        defaults.removeObject(forKey: ProfilePreferences.orderKey)
    }

    // MARK: - SSH version-mismatch suppressions

    /// One row in the suppressions list. The triple is parsed back from
    /// the `"host|local|remote"` token shape that VersionCheck writes.
    struct VersionSuppression: Equatable, Hashable {
        let host: String
        let localVersion: String
        let remoteVersion: String
        /// Round-trips through `VersionCheck.Suppression.token(...)` so
        /// the value we hand to `defaults.set([...])` is byte-identical
        /// to what VersionCheck would have written.
        var token: String {
            "\(host)|\(localVersion)|\(remoteVersion)"
        }
        /// Parse the inverse of `token`. `nil` if the field count is
        /// wrong (stray data from a hand-edited plist).
        static func parse(_ token: String) -> VersionSuppression? {
            let parts = token.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return VersionSuppression(host: String(parts[0]),
                                      localVersion: String(parts[1]),
                                      remoteVersion: String(parts[2]))
        }
    }

    /// Snapshot the suppressions currently in defaults, in stored order.
    /// Malformed tokens are silently dropped.
    static func versionMismatchSuppressions(in defaults: UserDefaults = .standard)
        -> [VersionSuppression]
    {
        let list = defaults.stringArray(forKey: VersionCheck.Suppression.key) ?? []
        return list.compactMap { VersionSuppression.parse($0) }
    }

    /// Remove one suppression — useful for "delete this row" in the UI.
    /// Idempotent: removing a triple that isn't present is a no-op.
    static func removeSuppression(_ target: VersionSuppression,
                                  in defaults: UserDefaults = .standard) {
        var list = defaults.stringArray(forKey: VersionCheck.Suppression.key) ?? []
        list.removeAll { $0 == target.token }
        if list.isEmpty {
            defaults.removeObject(forKey: VersionCheck.Suppression.key)
        } else {
            defaults.set(list, forKey: VersionCheck.Suppression.key)
        }
    }

    /// Wipe every SSH version-mismatch suppression. After this, the
    /// next profile-open on any ssh:// root re-prompts.
    static func clearAllSuppressions(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: VersionCheck.Suppression.key)
    }

    // MARK: - Window & toolbar layout

    /// `(framesSet, toolbarsSet)` — counts of how many of our
    /// known keys are currently populated. Drives the section
    /// label ("3 window frames stored").
    static func windowAndToolbarCounts(in defaults: UserDefaults = .standard)
        -> (frames: Int, toolbars: Int)
    {
        let frames = windowFrameAutosaveNames
            .filter { defaults.object(forKey: windowFrameKey($0)) != nil }
            .count
        let toolbars = toolbarConfigurationKeys
            .filter { defaults.object(forKey: $0) != nil }
            .count
        return (frames, toolbars)
    }

    /// Clear every window-frame and toolbar-configuration key this
    /// app knows about. The next launch reopens with default sizes
    /// and toolbar layout — useful when a window has drifted
    /// off-screen after a monitor change.
    static func resetWindowAndToolbarLayout(in defaults: UserDefaults = .standard) {
        for name in windowFrameAutosaveNames {
            defaults.removeObject(forKey: windowFrameKey(name))
        }
        for key in toolbarConfigurationKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
