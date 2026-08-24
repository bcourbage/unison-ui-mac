import Foundation

/// The presentation + engine sink a `DiffLifecycle` drives. `owner` / `op` are the
/// raw values of the requesting `SessionID` / `OperationID`, kept opaque so the
/// lifecycle logic is independent of the coordinator and fully unit-testable.
@MainActor
protocol DiffLifecycleSink: AnyObject {
    /// Gate (or un-gate) the owner's reconcile window while its diff owns the
    /// OCaml worker, so no main-thread bridge call can block behind it.
    func diffSetInFlight(_ inFlight: Bool, owner: UInt64)
    /// Show a diff RESULT in the owner's window (a real diff, or the "no output"
    /// notice for a successful command that printed nothing).
    func diffShowResult(title: String, text: String, owner: UInt64)
    /// Show a narrow diff ERROR in the owner's window.
    func diffShowError(_ message: String, owner: UInt64)
    /// Whether the owner's reconcile window still exists (false once the session
    /// was abandoned / returned to Profiles).
    func diffOwnerWindowExists(_ owner: UInt64) -> Bool
    /// Surface a wedged-diff stall at APP level when the owner window is gone.
    func diffPresentAppStall(_ message: String)
    /// Release the diff's engine ownership (drive the coordinator's `diffCompleted`).
    func diffReleaseEngineOwnership(owner: UInt64, op: UInt64)
}

/// Owns the asynchronous per-diff lifecycle: the app-global `DiffRequestBroker`
/// (result routing / draining), the OFF-MAIN bridge dispatch, the wedged-diff
/// watchdog, and the completion handshake that resolves a no-output success. The
/// scheduler, bridge, and sink are all injected so the exact production sequence
/// is locked by tests without a real queue, bridge, or 45-second wait.
///
/// Engine OWNERSHIP (`.diffing`) is taken/released by the coordinator via the
/// caller; this type never touches it except to ask the sink to release it when a
/// diff terminates.
@MainActor
final class DiffLifecycle {
    typealias Cancel = () -> Void
    /// Run the diff bridge OFF the main thread, then deliver `(canDiff, ok)` back
    /// on the main actor. `ok` is whether the OCaml call completed without raising.
    typealias BridgeRunner =
        @Sendable (_ row: Int, _ completion: @escaping @MainActor @Sendable (Bool, Bool) -> Void) -> Void
    /// Schedule `fire` after `delay`; return a cancel closure.
    typealias WatchdogScheduler =
        (_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> Cancel

    private unowned let sink: DiffLifecycleSink
    private let runBridge: BridgeRunner
    private let scheduleWatchdog: WatchdogScheduler
    private let stallTimeout: TimeInterval

    private var broker = DiffRequestBroker()
    private var owner: UInt64?                    // the outstanding request's owner
    private var current: (owner: UInt64, op: UInt64)?
    private var cancelWatchdog: Cancel?
    private var appAlertShown = false

    init(sink: DiffLifecycleSink,
         runBridge: @escaping BridgeRunner,
         scheduleWatchdog: @escaping WatchdogScheduler,
         stallTimeout: TimeInterval) {
        self.sink = sink
        self.runBridge = runBridge
        self.scheduleWatchdog = scheduleWatchdog
        self.stallTimeout = stallTimeout
    }

    // MARK: - Request gating (broker)

    /// Ask the broker to start a diff owned by `owner`. Returns true if issued (the
    /// broker was idle). The CALLER then takes engine ownership via the coordinator.
    func request(owner: UInt64) -> Bool {
        switch broker.request(owner: owner) {
        case .issue:
            self.owner = owner
            return true
        case .refuseInFlight, .refuseDraining:
            return false
        }
    }

    /// Undo a broker request when the coordinator refused engine ownership after it.
    /// The request was never dispatched, so it must go straight back to idle — NOT
    /// draining (which would wait forever for a callback that can't arrive, SF2).
    func undoRequest(owner: UInt64) {
        broker.cancelUnissued(owner: owner)
        if self.owner == owner { self.owner = nil }
    }

    // MARK: - Execution

    /// Begin the OFF-MAIN diff for a coordinator-authorized `(owner, op, row)`.
    func begin(owner: UInt64, op: UInt64, row: Int) {
        current = (owner, op)
        sink.diffSetInFlight(true, owner: owner)
        armWatchdog(owner: owner, op: op)
        runBridge(row) { [weak self] canDiff, ok in
            self?.complete(owner: owner, op: op, canDiff: canDiff, ok: ok)
        }
    }

    /// The bridge call returned. Resolve the request (error / real result already
    /// delivered / no-output), release engine ownership, and clear the gate.
    private func complete(owner: UInt64, op: UInt64, canDiff: Bool, ok: Bool) {
        guard current.map({ $0 == (owner, op) }) ?? false else { return }
        current = nil
        cancelWatchdog?(); cancelWatchdog = nil; appAlertShown = false
        sink.diffSetInFlight(false, owner: owner)
        // The synchronous return is the terminal handshake. Resolve it through the
        // broker's `deliver()` disposition — the SAME state machine as a callback —
        // so it correctly returns to idle from EITHER `.outstanding` (present the
        // outcome) OR `.draining` (an abandoned/timed-out diff — drop presentation,
        // don't reopen the window the user dismissed). A no-op if a real callback
        // already resolved it (broker idle → `.dropStale`).
        switch broker.deliver() {
        case .apply(let o):
            if self.owner == o { self.owner = nil }
            if ok {
                // Success but NO callback fired → the diff produced no output.
                sink.diffShowResult(title: "Diff",
                                    text: "The diff command produced no output.", owner: o)
            } else {
                sink.diffShowError(canDiff
                    ? "Unison could not produce a diff for this item."
                    : "This item can’t be diffed — it’s a directory, a symlink, had only metadata "
                      + "changes, or hit a problem during update detection.", owner: o)
            }
        case .dropStale:
            // A real result already delivered, or an abandoned request just drained
            // (broker back to idle — unstuck either way; present nothing).
            if self.owner == owner { self.owner = nil }
        }
        sink.diffReleaseEngineOwnership(owner: owner, op: op)
    }

    // MARK: - Callback delivery (from the bridge diff/diff-err handlers)

    func deliverResult(title: String, text: String) {
        if case .apply(let o) = broker.deliver() {
            if self.owner == o { self.owner = nil }
            sink.diffShowResult(title: title, text: text, owner: o)
        }
    }

    func deliverError(_ message: String) {
        if case .apply(let o) = broker.deliver() {
            if self.owner == o { self.owner = nil }
            sink.diffShowError(message, owner: o)
        }
    }

    /// The owner's window/session is going away while its diff is still in flight.
    /// Enter draining so a late result is discarded; engine ownership is released
    /// only when the bridge call actually returns (`complete`).
    func abandon(owner: UInt64) {
        broker.abandon(owner: owner)
        if self.owner == owner { self.owner = nil }
    }

    // MARK: - Wedged-diff watchdog

    private func armWatchdog(owner: UInt64, op: UInt64) {
        cancelWatchdog?()
        appAlertShown = false
        cancelWatchdog = scheduleWatchdog(stallTimeout) { [weak self] in
            self?.watchdogFired(owner: owner, op: op)
        }
    }

    /// The diff ran past the stall timeout. Drop a very-late result and surface the
    /// stall in the owner window, or — if it was abandoned — at app level (once).
    private func watchdogFired(owner: UInt64, op: UInt64) {
        guard current.map({ $0 == (owner, op) }) ?? false else { return }
        broker.abandon(owner: owner)
        let message =
            "A file comparison is taking unusually long — the remote connection may be stalled. "
            + "The app is waiting for it and other engine actions stay disabled until it finishes. "
            + "If it never does, quit and reopen the app."
        if sink.diffOwnerWindowExists(owner) {
            sink.diffShowError(message, owner: owner)
        } else if !appAlertShown {
            appAlertShown = true
            sink.diffPresentAppStall(message)
        }
    }

    // MARK: - Test-visible state
    var isAwaitingResult: Bool { broker.isAwaitingResult }
    var isDraining: Bool { broker.isDraining }
    var outstandingOwner: UInt64? { owner }
}
