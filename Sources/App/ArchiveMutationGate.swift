import AppKit

extension Notification.Name {
    /// Posted on the main thread by `AppDelegate` after every batch of
    /// coordinator effects runs, i.e. whenever the engine's activity state
    /// may have changed. Windows that gate destructive archive maintenance
    /// (Settings → Clean Stale Archives, the Profile Editor's Reset Archives
    /// and delete-with-archives) observe this to refresh their controls'
    /// enabled state while they're already open, so a background sync/scan
    /// starting or finishing is reflected without the user reopening them.
    static let engineActivityDidChange =
        Notification.Name("net.courbage.unison-ui-mac.engineActivityDidChange")
}

/// The app-side view of the coordinator's single destructive-mutation
/// policy (`EngineSessionCoordinator.allowsDestructiveArchiveMutation`).
/// `AppDelegate` is the concrete provider — it owns the coordinator — and
/// windows consult it through `NSApp.delegate as? EngineActivityProviding`
/// so they never hold their own copy of engine state.
@MainActor
protocol EngineActivityProviding: AnyObject {
    /// True only when the engine is exactly idle. Mirrors the coordinator.
    var allowsDestructiveArchiveMutation: Bool { get }
}

/// After a destructive mutation RETAINS a committed record because a lock could
/// not be confirmed released (`ArchiveMutationOutcome.Disposition.blockedByLock`),
/// the affected profiles must stay blocked IMMEDIATELY — within the same session,
/// not only after the next launch. Callers report it to the coordinator (the
/// `AppDelegate`), which re-scans so the profile-open gate is live at once.
@MainActor
protocol ArchiveBlockCoordinating: AnyObject {
    @discardableResult
    func refreshBlockedArchiveState() -> Bool
}

/// Tracks whether a stale-archive row snapshot is still trustworthy across
/// engine-activity transitions. The Clean Stale window classifies archives as
/// stale by reading the Unison directory; a sync/scan that runs afterward can
/// change that classification (delete, rewrite, or re-attribute archives), so a
/// snapshot taken before an operation must NOT be acted on after it. The
/// snapshot is trustworthy only when it was scanned while idle AND no engine
/// activity has happened since — otherwise it must be re-scanned first.
///
/// Pure value type so the busy→idle invalidation logic is unit-testable
/// without any AppKit or engine.
struct StaleSnapshotGuard {
    /// True when the current snapshot can no longer be trusted (scanned during
    /// activity, or activity occurred since the scan).
    private(set) var dirty = false

    /// Record that a fresh scan just happened. A scan taken while the engine
    /// is busy is immediately dirty (the directory is being mutated under it).
    mutating func didScan(engineIdle: Bool) { dirty = !engineIdle }

    /// Observe an engine-activity transition. Any non-idle observation dirties
    /// the snapshot; an idle observation alone never clears it (only a re-scan
    /// via `didScan` does).
    mutating func observedActivity(engineIdle: Bool) { if !engineIdle { dirty = true } }

    /// May the current snapshot be trashed? Only when idle and clean.
    func mayTrash(engineIdle: Bool) -> Bool { engineIdle && !dirty }

    /// Should the rows be re-scanned now? True once the engine is idle again
    /// but the snapshot is dirty from intervening activity.
    func shouldReload(engineIdle: Bool) -> Bool { engineIdle && dirty }
}

/// The recheck every final destructive archive handler performs immediately
/// before it moves/deletes/rewrites archive files. Disabled buttons and menu
/// items are a courtesy, not a guarantee: a confirmation sheet can be opened
/// while idle and confirmed after a background operation has started (a
/// TOCTOU window), so the mutation site itself must re-ask the policy.
///
/// `provider` is normally the `AppDelegate`. When it is nil we fail SAFE and
/// refuse — there is no authority to confirm the engine is idle. Pure and
/// synchronous so the policy is unit-testable without any UI.
@MainActor
enum ArchiveMutationGate {
    static func isAllowed(_ provider: EngineActivityProviding?) -> Bool {
        provider?.allowsDestructiveArchiveMutation ?? false
    }

    /// The single non-alarming explanation shown when a destructive archive
    /// action is refused because the engine is busy. Kept here so every
    /// call site reads identically.
    static let busyMessage = "Wait for the current Unison operation to finish."

    /// Present the standard "engine busy" refusal as a sheet on `window`
    /// (or app-modal if there is none). Returns after the sheet is set up;
    /// the alert is non-critical (informational), matching the fact that
    /// nothing went wrong — the user simply needs to wait.
    @MainActor
    static func presentBusyRefusal(title: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = busyMessage
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
