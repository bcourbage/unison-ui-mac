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
        "ProfileFormWindow",     // orphaned after the .v2 rename; kept so reset cleans it
        "ProfileFormWindow.v2",
        "ReconcileWindow",
        "DiffWindow",
        "SettingsWindow",
    ]

    /// AppKit stores autosaved window frames under `"NSWindow Frame <name>"`.
    static func windowFrameKey(_ autosaveName: String) -> String {
        "NSWindow Frame \(autosaveName)"
    }

    /// NSToolbar autosave keys we use. When `ReconcileToolbar` bumps
    /// its identifier suffix (currently `.v5`), the old key is
    /// orphaned; include retired versions so a reset cleans up the
    /// trail too. **Add a new entry here whenever the toolbar
    /// identifier bumps**, otherwise the orphan stays in defaults
    /// and "Reset Window & Toolbar Layout" doesn't actually clean it.
    static let toolbarConfigurationKeys: [String] = [
        "NSToolbar Configuration ReconcileToolbar.v6",
        "NSToolbar Configuration ReconcileToolbar.v5",
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

    // MARK: - Reconcile display (layout mode + expand policy)

    /// UserDefaults key for the reconcile-window layout mode (Flat /
    /// Nested collapsed / Nested full). String-valued: stores the
    /// `ReconcileTree.LayoutMode.rawValue` (`"flat"`, `"nestedCollapsed"`,
    /// `"nestedFull"`).
    static let reconcileLayoutModeKey = "reconcile.layoutMode"

    /// UserDefaults key for the reconcile-window expand policy (Smart
    /// / All / Root only). String-valued, stores
    /// `ReconcileTree.ExpandPolicy.rawValue`.
    static let reconcileExpandPolicyKey = "reconcile.expandPolicy"

    /// Read the configured reconcile layout mode. Defaults to
    /// `.nestedCollapsed` when the key is absent or holds a value
    /// no longer in the enum (e.g. someone hand-edited the plist to
    /// a stale string after a code change).
    static func reconcileLayoutMode(
        in defaults: UserDefaults = .standard
    ) -> ReconcileTree.LayoutMode {
        guard let raw = defaults.string(forKey: reconcileLayoutModeKey),
              let mode = ReconcileTree.LayoutMode(rawValue: raw)
        else { return .nestedCollapsed }
        return mode
    }

    /// Persist the user's layout-mode pick. Used by SettingsWindowController.
    static func setReconcileLayoutMode(
        _ mode: ReconcileTree.LayoutMode,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: reconcileLayoutModeKey)
    }

    /// Read the configured expand policy. Defaults to `.smart`.
    static func reconcileExpandPolicy(
        in defaults: UserDefaults = .standard
    ) -> ReconcileTree.ExpandPolicy {
        guard let raw = defaults.string(forKey: reconcileExpandPolicyKey),
              let policy = ReconcileTree.ExpandPolicy(rawValue: raw)
        else { return .smart }
        return policy
    }

    /// Persist the user's expand-policy pick.
    static func setReconcileExpandPolicy(
        _ policy: ReconcileTree.ExpandPolicy,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(policy.rawValue, forKey: reconcileExpandPolicyKey)
    }

    /// Drop both reconcile-display keys back to defaults. Used by the
    /// Settings window's "Reset profile picker layout" cousin if/when
    /// we extend the reset surface; for now it's exposed as the
    /// counterpart to the picker-layout reset for symmetry.
    static func resetReconcileDisplay(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: reconcileLayoutModeKey)
        defaults.removeObject(forKey: reconcileExpandPolicyKey)
    }

    // MARK: - Sync-completion cues

    /// UserDefaults key for "post a Notification Center banner when a
    /// sync finishes". Bool-valued; **absent → ON**. The inline summary
    /// emphasis (green ✓ / red ⚠) is always on and not gated here — only
    /// the notification and sound cues are user-toggleable.
    static let syncCompleteNotifyKey = "sync.complete.notify"

    /// UserDefaults key for "play a sound when a sync finishes".
    /// Bool-valued; **absent → ON**.
    static let syncCompleteSoundKey = "sync.complete.sound"

    /// Whether to post a completion notification. Opt-out (defaults to
    /// `true`): the user asked for the finish to be conspicuous, so the
    /// cue is on until explicitly disabled. `object(forKey:) as? Bool`
    /// distinguishes "absent" (→ default true) from an explicit stored
    /// `false`, which `bool(forKey:)` could not.
    static func notifyOnSyncComplete(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: syncCompleteNotifyKey) as? Bool ?? true
    }

    static func setNotifyOnSyncComplete(_ on: Bool,
                                        in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: syncCompleteNotifyKey)
    }

    /// Whether to play a sound on completion. Opt-out (defaults to `true`).
    static func soundOnSyncComplete(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: syncCompleteSoundKey) as? Bool ?? true
    }

    static func setSoundOnSyncComplete(_ on: Bool,
                                       in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: syncCompleteSoundKey)
    }

    // MARK: - Default log directory

    /// UserDefaults key for the directory the profile editor uses when it
    /// suggests a `logfile` path. String-valued; absent → `~/Library/Logs`.
    static let defaultLogDirectoryKey = "logging.defaultDirectory"

    /// Unison's directory on macOS — where profiles and archives live, and
    /// the natural home for log files (co-located, as Unison itself
    /// defaults). Used as the fallback default log directory.
    static let defaultUnisonDirectory = "~/Library/Application Support/Unison"

    /// The configured default log directory, expanded to an absolute path.
    /// Falls back to Unison's directory when unset.
    static func defaultLogDirectory(in defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: defaultLogDirectoryKey)?
            .trimmingCharacters(in: .whitespaces)
        let path = (raw?.isEmpty == false) ? raw! : defaultUnisonDirectory
        return (path as NSString).expandingTildeInPath
    }

    static func setDefaultLogDirectory(_ path: String,
                                       in defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultLogDirectoryKey)
        } else {
            defaults.set(trimmed, forKey: defaultLogDirectoryKey)
        }
    }

    /// Suggested absolute `logfile` path for a profile: the default log
    /// directory + `Unison-<profile>.log`.
    static func suggestedLogfile(forProfile name: String,
                                 in defaults: UserDefaults = .standard) -> String {
        let safe = name.isEmpty ? "sync" : name
        return (defaultLogDirectory(in: defaults) as NSString)
            .appendingPathComponent("Unison-\(safe).log")
    }

    /// Default per-profile log file name.
    static func defaultLogName(forProfile name: String) -> String {
        "Unison-\(name.isEmpty ? "sync" : name).log"
    }

    // MARK: - Logging mode

    /// How log file paths are chosen across profiles. Drives what the
    /// profile editor's logging controls show and how `logfile` is written.
    enum LoggingMode: String {
        case sameFile        // all profiles log to one shared file
        case sameDirectory   // all profiles log into one shared folder, one file each
        case perProfile      // each profile sets its own path (default is a pre-fill only)
    }

    static let loggingModeKey = "logging.mode"

    static func loggingMode(in defaults: UserDefaults = .standard) -> LoggingMode {
        guard let raw = defaults.string(forKey: loggingModeKey),
              let mode = LoggingMode(rawValue: raw) else { return .perProfile }
        return mode
    }

    static func setLoggingMode(_ mode: LoggingMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: loggingModeKey)
    }

    /// Compose a profile's `logfile` path from the logging mode and the
    /// already-resolved inputs. Pure (the caller does the UserDefaults reads
    /// and tilde expansion) so the per-mode rule is unit-testable:
    ///   - `.sameFile`      → the one shared file (`name` ignored)
    ///   - `.sameDirectory` → shared folder + per-profile file `name`
    ///   - `.perProfile`    → this profile's folder + file `name`
    static func composeLogfile(mode: LoggingMode,
                               name: String,
                               sharedFile: String,
                               sharedDirectory: String,
                               perProfileFolder: String) -> String {
        switch mode {
        case .sameFile:      return sharedFile
        case .sameDirectory: return (sharedDirectory as NSString).appendingPathComponent(name)
        case .perProfile:    return (perProfileFolder as NSString).appendingPathComponent(name)
        }
    }

    // Mode 1: the single shared log file (absolute path).
    static let sharedLogFileKey = "logging.sharedFile"

    static func sharedLogFile(in defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: sharedLogFileKey)?.trimmingCharacters(in: .whitespaces)
        let path = (raw?.isEmpty == false) ? raw!
            : (defaultUnisonDirectory as NSString).appendingPathComponent("Unison.log")
        return (path as NSString).expandingTildeInPath
    }

    static func setSharedLogFile(_ path: String, in defaults: UserDefaults = .standard) {
        let t = path.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { defaults.removeObject(forKey: sharedLogFileKey) }
        else { defaults.set(t, forKey: sharedLogFileKey) }
    }

    // Mode 2: the shared folder (absolute path); file name stays per-profile.
    static let sharedLogDirectoryKey = "logging.sharedDirectory"

    static func sharedLogDirectory(in defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: sharedLogDirectoryKey)?.trimmingCharacters(in: .whitespaces)
        let path = (raw?.isEmpty == false) ? raw! : defaultUnisonDirectory
        return (path as NSString).expandingTildeInPath
    }

    static func setSharedLogDirectory(_ path: String, in defaults: UserDefaults = .standard) {
        let t = path.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { defaults.removeObject(forKey: sharedLogDirectoryKey) }
        else { defaults.set(t, forKey: sharedLogDirectoryKey) }
    }
}
