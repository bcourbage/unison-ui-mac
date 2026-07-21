import Foundation

/// Operation-bound no-progress timer for the init2/scan phase (issue #24).
///
/// The connect watchdog is disarmed once `connection_end` returns; the scan
/// (`init2`, update detection) that follows is otherwise un-timed, so a
/// connection whose transport dies or freezes *after* authentication hangs the
/// `.scanning` phase. This timer bounds it: `arm`ed when a remote scan starts,
/// `reset` on each scan-status delivery, `disarm`ed on any scan terminal, and on
/// expiry it invokes `onFire` with the exact `(SessionID, OperationID)` — which
/// the caller routes to `operationFailed(..., engineIsQuiescent: false)` →
/// coordinator restart-required.
///
/// Extracted from `AppDelegate` so the arm/reset/disarm/fire behavior is
/// unit-testable with an injected scheduler (no real 120s waits). The default
/// scheduler is `DispatchQueue.main.asyncAfter`, i.e. the monotonic wall-clock
/// dispatch timer.
@MainActor
final class ScanStallTimer {

    /// A scheduled, cancellable fire. Injected so tests can capture and trigger
    /// it deterministically instead of waiting on a real timer.
    struct Handle { let cancel: () -> Void }
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Handle

    typealias Op = (EngineSessionCoordinator.SessionID, EngineSessionCoordinator.OperationID)

    private let timeout: TimeInterval
    private let scheduler: Scheduler
    private let onFire: (EngineSessionCoordinator.SessionID, EngineSessionCoordinator.OperationID) -> Void

    private var handle: Handle?
    private var armedOp: Op?

    init(timeout: TimeInterval,
         scheduler: @escaping Scheduler = ScanStallTimer.mainQueueScheduler,
         onFire: @escaping (EngineSessionCoordinator.SessionID, EngineSessionCoordinator.OperationID) -> Void) {
        self.timeout = timeout
        self.scheduler = scheduler
        self.onFire = onFire
    }

    var isArmed: Bool { handle != nil }

    /// Arm (or re-arm) for the exact scan op, replacing any pending fire.
    func arm(_ s: EngineSessionCoordinator.SessionID, _ op: EngineSessionCoordinator.OperationID) {
        handle?.cancel()
        armedOp = (s, op)
        handle = scheduler(timeout) { [weak self] in self?.fire(s, op) }
    }

    /// Reset the timer on scan progress. No-op if not armed.
    func reset() {
        guard let (s, op) = armedOp else { return }
        arm(s, op)
    }

    /// Cancel any pending fire (scan terminal / abandonment-to-terminal path).
    func disarm() {
        handle?.cancel()
        handle = nil
        armedOp = nil
    }

    private func fire(_ s: EngineSessionCoordinator.SessionID, _ op: EngineSessionCoordinator.OperationID) {
        handle = nil
        armedOp = nil
        onFire(s, op)
    }

    static let mainQueueScheduler: Scheduler = { timeout, body in
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        return Handle { item.cancel() }
    }
}
