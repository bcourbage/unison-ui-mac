import Foundation

/// Single authority for the Unison engine's per-profile lifecycle
/// (issue #6). Replaces the ad-hoc booleans with one explicit state
/// machine whose contract is designed to *reject* incorrect wiring, not
/// merely centralize it.
///
/// Invariant the ad-hoc version violated:
///
///     UI abandoned  ≠  operation stopped  ≠  engine idle
///
/// Only a genuine terminal event (`scanCompleted` / `syncCompleted` /
/// `closeCompleted` / `operationFailed`) releases the engine lease.
/// `abandon(...)` merely marks the in-flight op abandoned and defers the
/// connection close until that op actually terminates.
///
/// Identity model (two distinct IDs — do not conflate):
///  - `SessionID`   — one visible profile/work unit; stable across
///                    connect → scan → ready → sync → rescan → close.
///                    Keys the reconcile window.
///  - `OperationID` — one asynchronous bridge op (connect, scan, sync,
///                    close). Minted fresh for each. Identifies which
///                    callback is completing. The driver records the op
///                    id when it *starts* a bridge call and passes that
///                    same id back on completion — never "the active id at
///                    delivery time".
///
/// Every terminal event is guarded on *exact phase + session + op*, so a
/// stale or duplicate callback is a no-op instead of a corrupting
/// transition.
///
/// Pure reducer: each event fully mutates state, then returns `[Effect]`
/// for the caller (AppDelegate) to perform. Nothing is executed
/// mid-transition, so a reentrant callback can't observe an intermediate
/// state.
@MainActor
final class EngineSessionCoordinator {

    struct SessionID: Hashable, CustomStringConvertible {
        let raw: UInt64
        var description: String { "session#\(raw)" }
    }
    struct OperationID: Hashable, CustomStringConvertible {
        let raw: UInt64
        var description: String { "op#\(raw)" }
    }
    struct OpenRequestID: Hashable, CustomStringConvertible {
        let raw: UInt64
        var description: String { "openReq#\(raw)" }
    }

    /// Established-connection state. A close is asynchronous and can fail;
    /// `.failed` is terminal-unsafe (the engine must be restarted).
    enum ConnectionState: Equatable {
        case none
        case open(interactive: Bool)
        case failed(String)
    }

    /// Where a close should leave us: fully idle (leave / abandon), or back
    /// to the visible results window (non-interactive sync-end close).
    enum CloseOutcome: Equatable { case toIdle, backToReady }

    enum Phase: Equatable {
        case idle
        case opening(SessionID, OperationID)   // init1 + credential prompt
        case scanning(SessionID, OperationID)  // init2
        case ready(SessionID)                  // no op in flight; awaiting user
        case syncing(SessionID, OperationID)   // transport
        case closing(SessionID, OperationID, CloseOutcome)
        case restartRequired(String)
    }

    /// Side effects for the caller to perform after state is fully mutated.
    /// Presentation (`showSession`) is separate from engine work
    /// (`beginConnect`/`beginScan`/...) so the driver retains one window
    /// per session and never has to guess whether to create or reuse it.
    enum Effect: Equatable {
        case showSession(SessionID, profile: String)         // create/retain the window
        case beginConnect(SessionID, OperationID, profile: String)  // init1
        case beginScan(SessionID, OperationID)               // init2 over live connection
        case beginSync(SessionID, OperationID)               // synchronize
        case closeConnection(SessionID, OperationID)         // off-main close → closeCompleted
        case showWaiting(OpenRequestID, profile: String)     // queued behind a busy op
        case presentScanResults(SessionID)
        case presentSyncResults(SessionID)
        case restartRequired(reason: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var connection: ConnectionState = .none

    private var abandoned = false
    private var currentProfile: String?
    private var queued: (id: OpenRequestID, profile: String)?

    private var nextSession: UInt64 = 0
    private var nextOp: UInt64 = 0
    private var nextRequest: UInt64 = 0

    // MARK: - Queries

    /// The session whose window is on screen (nil when idle/restart).
    var currentSession: SessionID? {
        switch phase {
        case .opening(let s, _), .scanning(let s, _), .ready(let s),
             .syncing(let s, _), .closing(let s, _, _):
            return s
        case .idle, .restartRequired:
            return nil
        }
    }

    /// Whether status/progress for `session` should still be shown.
    func isVisible(_ session: SessionID) -> Bool {
        currentSession == session && !abandoned
    }

    var isIdle: Bool { phase == .idle }

    private func mintSession() -> SessionID { nextSession += 1; return SessionID(raw: nextSession) }
    private func mintOp() -> OperationID { nextOp += 1; return OperationID(raw: nextOp) }
    private func mintRequest() -> OpenRequestID { nextRequest += 1; return OpenRequestID(raw: nextRequest) }

    // MARK: - User intents

    /// User picked a profile. Starts immediately if idle, else queues
    /// behind the in-flight (possibly abandoned) op.
    func requestOpen(profile: String) -> [Effect] {
        switch phase {
        case .idle:
            return startFreshOpen(profile: profile)
        case .restartRequired(let reason):
            return [.restartRequired(reason: reason)]
        default:
            let id = mintRequest()
            queued = (id, profile)          // last pick wins
            return [.showWaiting(id, profile: profile)]
        }
    }

    /// The user closed a queued waiting window before it started.
    func cancelQueuedOpen(_ id: OpenRequestID) -> [Effect] {
        if queued?.id == id { queued = nil }
        return []
    }

    /// User asked to rescan the visible profile.
    func requestRescan() -> [Effect] {
        guard case .ready(let s) = phase else { return [] }
        switch connection {
        case .open:
            let op = mintOp()
            phase = .scanning(s, op)
            return [.beginScan(s, op)]
        case .none:
            let op = mintOp()
            phase = .opening(s, op)
            return [.beginConnect(s, op, profile: currentProfile ?? "")]
        case .failed(let r):
            return enterRestartRequired("previous close failed: \(r)")
        }
    }

    /// User pressed Go. Authorizes the sync via `.beginSync`; the driver
    /// must call the bridge only in response to that effect.
    func requestSync() -> [Effect] {
        guard case .ready(let s) = phase else { return [] }
        let op = mintOp()
        phase = .syncing(s, op)
        return [.beginSync(s, op)]
    }

    /// User left / pressed Stop / a watchdog fired. Never idles the engine
    /// while an op is in flight — defers close to the terminal event.
    func abandon(reason: String) -> [Effect] {
        switch phase {
        case .ready(let s):
            return beginClose(s, outcome: .toIdle)
        case .opening, .scanning, .syncing:
            abandoned = true
            return []
        case .closing, .idle, .restartRequired:
            return []
        }
    }

    // MARK: - Engine terminal events (token-bound, phase-exact)

    /// Connect phase finished; `connection` is `.open(interactive:)` for a
    /// remote root or `.none` for a local one. Authorizes the scan.
    func connectFinished(_ session: SessionID, _ op: OperationID,
                         connection: ConnectionState) -> [Effect] {
        guard case .opening(session, op) = phase else { return [] }
        self.connection = connection
        if abandoned { return beginClose(session, outcome: .toIdle) }
        let scanOp = mintOp()
        phase = .scanning(session, scanOp)
        return [.beginScan(session, scanOp)]
    }

    func scanCompleted(_ session: SessionID, _ op: OperationID) -> [Effect] {
        guard case .scanning(session, op) = phase else { return [] }
        if abandoned { return beginClose(session, outcome: .toIdle) }
        phase = .ready(session)
        return [.presentScanResults(session)]
    }

    func syncCompleted(_ session: SessionID, _ op: OperationID) -> [Effect] {
        guard case .syncing(session, op) = phase else { return [] }
        if abandoned { return beginClose(session, outcome: .toIdle) }
        phase = .ready(session)
        // Auth-cost policy (2b): non-interactive closes now (window stays);
        // interactive holds until leave.
        if case .open(interactive: false) = connection {
            return [.presentSyncResults(session)] + beginClose(session, outcome: .backToReady)
        }
        return [.presentSyncResults(session)]
    }

    /// Result of a `closeConnection` effect. Guarded on the exact close op
    /// so a delayed close from an older operation can't touch the current
    /// connection.
    func closeCompleted(_ session: SessionID, _ op: OperationID, status: Int32) -> [Effect] {
        guard case .closing(session, op, let outcome) = phase else { return [] }
        if status == 0 {
            connection = .none
            switch outcome {
            case .toIdle:      return finishToIdle()
            case .backToReady: phase = .ready(session); return []
            }
        }
        // Any close failure leaves the engine unsafe for reuse — surface it
        // immediately regardless of why the close was started.
        connection = .failed("status \(status)")
        return enterRestartRequired("connection close failed (status \(status))")
    }

    /// A terminal FAILURE of an in-flight op (fatal, warning-cancel,
    /// connection failure, prompt cancel, OCaml exception). Releases the
    /// lease that a normal completion never will. Never released merely
    /// because a fatal UI callback was shown.
    ///
    /// `engineIsQuiescent`: the caller confirms the OCaml worker has
    /// actually unwound (not just that the UI displayed an error). If it
    /// can't be proven, we require restart rather than reuse a possibly
    /// contaminated runtime.
    func operationFailed(_ session: SessionID, _ op: OperationID,
                         reason: String, engineIsQuiescent: Bool) -> [Effect] {
        let active: Bool
        switch phase {
        case .opening(session, op), .scanning(session, op), .syncing(session, op):
            active = true
        default:
            active = false
        }
        guard active else { return [] }
        if engineIsQuiescent {
            return beginClose(session, outcome: .toIdle)
        }
        return enterRestartRequired(reason)
    }

    // MARK: - Internal transitions (mutate, then return effects)

    private func startFreshOpen(profile: String) -> [Effect] {
        let s = mintSession()
        let op = mintOp()
        phase = .opening(s, op)
        abandoned = false
        connection = .none
        currentProfile = profile
        return [.showSession(s, profile: profile), .beginConnect(s, op, profile: profile)]
    }

    private func beginClose(_ session: SessionID, outcome: CloseOutcome) -> [Effect] {
        switch connection {
        case .open:
            let op = mintOp()
            phase = .closing(session, op, outcome)
            return [.closeConnection(session, op)]
        case .none:
            switch outcome {
            case .toIdle:      return finishToIdle()
            case .backToReady: phase = .ready(session); return []
            }
        case .failed(let r):
            return enterRestartRequired("close failed: \(r)")
        }
    }

    private func finishToIdle() -> [Effect] {
        phase = .idle
        abandoned = false
        connection = .none
        currentProfile = nil
        if let q = queued {
            queued = nil
            return startFreshOpen(profile: q.profile)
        }
        return []
    }

    private func enterRestartRequired(_ reason: String) -> [Effect] {
        phase = .restartRequired(reason)
        abandoned = false
        queued = nil
        return [.restartRequired(reason: reason)]
    }
}
