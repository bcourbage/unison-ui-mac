import Foundation

/// Advisory no-progress detector for the sync/transfer phase (issue #34).
///
/// Deliberately NON-fatal: on expiry it invokes `onStall` (the caller shows an
/// advisory notice) and does NOT touch coordinator/engine state. It cannot, and
/// must not, claim the transport is wedged — progress-callback silence is not
/// liveness (see `SyncStallNotice`). It resets on every progress event and
/// clears (via `onResume`) when progress returns; the caller `stop()`s it on any
/// sync terminal so a completed sync clears the notice cleanly.
///
/// Extracted from `ReconcileWindowController` so the arm/reset/fire/clear state
/// machine is unit-testable with an injected scheduler (no real 45s waits).
@MainActor
final class SyncStallDetector {

    struct Handle { let cancel: () -> Void }
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Handle

    private let timeout: TimeInterval
    private let scheduler: Scheduler
    private let onStall: () -> Void
    private let onResume: () -> Void

    private var handle: Handle?
    private var running = false
    /// True while the advisory notice is showing (fired and not yet resumed).
    private(set) var isStalled = false

    init(timeout: TimeInterval,
         scheduler: @escaping Scheduler = SyncStallDetector.mainQueueScheduler,
         onStall: @escaping () -> Void,
         onResume: @escaping () -> Void) {
        self.timeout = timeout
        self.scheduler = scheduler
        self.onStall = onStall
        self.onResume = onResume
    }

    var isArmed: Bool { handle != nil }

    /// Sync started — begin watching.
    func start() {
        running = true
        isStalled = false
        rearm()
    }

    /// A progress event (global fraction or per-row bytes). Clears a shown
    /// notice and re-arms. No-op when not running.
    func noteProgress() {
        guard running else { return }
        if isStalled { isStalled = false; onResume() }
        rearm()
    }

    /// Sync terminal (completion / stop / teardown): stop watching and clear.
    func stop() {
        running = false
        handle?.cancel()
        handle = nil
        isStalled = false
    }

    private func rearm() {
        handle?.cancel()
        handle = scheduler(timeout) { [weak self] in self?.fire() }
    }

    private func fire() {
        handle = nil
        guard running else { return }
        isStalled = true
        onStall()   // advisory notice only — never a coordinator/engine mutation
    }

    static let mainQueueScheduler: Scheduler = { timeout, body in
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        return Handle { item.cancel() }
    }
}
