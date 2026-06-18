import AppKit
import UserNotifications

/// Fires the optional, user-configurable cues when a sync finishes: a
/// Notification Center banner and/or a system sound. Both are gated by
/// `SettingsModel` toggles (default ON). The always-on inline emphasis
/// (green ✓ / red ⚠ next to the summary) lives in the reconcile window;
/// this type only owns the opt-out audible + notification cues so the
/// "should I announce, and how" decision reads from one place.
///
/// Notification authorization is requested elsewhere (at launch, and
/// when the user re-enables the toggle in Settings) rather than here —
/// posting when unauthorized is a silent no-op, so `announce` stays free
/// of permission-prompt side effects and can be called on every sync.
@MainActor
enum SyncCompletionAnnouncer {

    /// Announce a completed sync. `summary` is the one-line reconcile
    /// summary (reused verbatim as the notification body); `failures`
    /// picks the success vs. error variant of both cues.
    static func announce(summary: String, failures: Int,
                         defaults: UserDefaults = .standard) {
        if SettingsModel.soundOnSyncComplete(in: defaults) {
            playSound(failures: failures)
        }
        if SettingsModel.notifyOnSyncComplete(in: defaults) {
            postNotification(summary: summary, failures: failures)
        }
    }

    private static func playSound(failures: Int) {
        // "Glass" is the conventional positive completion chime; "Basso"
        // is the system error tone. Fall back to a plain beep if a future
        // macOS ever drops the named sounds.
        let name: NSSound.Name = failures > 0 ? "Basso" : "Glass"
        if let sound = NSSound(named: name) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private static func postNotification(summary: String, failures: Int) {
        let content = UNMutableNotificationContent()
        content.title = failures > 0
            ? "Sync finished with \(failures) error\(failures == 1 ? "" : "s")"
            : "Sync complete"
        content.body = summary
        // nil trigger → deliver immediately. A fresh UUID identifier per
        // call so successive syncs stack rather than coalescing.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Ask for notification permission if the toggle is on. Called at
    /// launch and when the user flips the Settings checkbox to ON, so the
    /// first post after enabling actually displays. Empty completion —
    /// the result surfaces naturally the next time a sync finishes.
    static func requestAuthorizationIfEnabled(defaults: UserDefaults = .standard) {
        guard SettingsModel.notifyOnSyncComplete(in: defaults) else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Retained delegate so completion banners appear even while we're the
    /// frontmost app. Without a `willPresent` opt-in, macOS suppresses
    /// banners for the active application and silently routes them to
    /// Notification Center only — which is exactly when a user is most
    /// likely watching the sync. Installed once at launch.
    private static let presenter = SyncCompletionPresenter()

    static func installPresenter() {
        UNUserNotificationCenter.current().delegate = presenter
    }
}

/// `UNUserNotificationCenterDelegate` whose sole job is to force
/// foreground presentation of completion banners. Plain `NSObject` (not
/// `@MainActor`) because the system invokes the delegate on its own
/// queue; the body touches no main-actor state. `.sound` is intentionally
/// omitted — the audible cue is handled separately by `playSound`, so the
/// notification stays silent to avoid a double chime.
final class SyncCompletionPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
