import Sparkle

/// The two user-facing update preferences the Settings window exposes, behind a
/// protocol so `SettingsWindowController` does not depend on Sparkle directly
/// and can be driven by a fake. Both properties are Sparkle-owned and persist to
/// `UserDefaults`; setting them takes effect immediately (the updater reschedules
/// its automatic check when `automaticallyChecksForUpdates` changes).
@MainActor
protocol UpdatePreferences: AnyObject {
    /// Whether the app checks for updates on its own schedule.
    var automaticallyChecksForUpdates: Bool { get set }
    /// Whether an anonymous system profile is included when the app checks.
    var sendsSystemProfile: Bool { get set }
}

extension SPUUpdater: UpdatePreferences {}
