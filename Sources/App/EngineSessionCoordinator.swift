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

    /// Connection state of the current session. The old `.none` conflated two
    /// very different situations — a local↔local session (no remote connection
    /// ever) and a remote session whose connection has been closed — which let
    /// `requestSync()` authorize a sync over a dead remote connection. They are
    /// now distinct (finding 5):
    ///  - `.localOnly`    — local↔local profile; scan/sync need no connection.
    ///  - `.disconnected` — remote session with no live connection: either not
    ///                      yet connected, or closed after a sync-end/leave. A
    ///                      remote sync must NOT be authorized here; a rescan
    ///                      reconnects first.
    ///  - `.open`         — remote connection established.
    ///  - `.failed`       — a close failed; terminal-unsafe, engine must restart.
    enum ConnectionState: Equatable {
        case localOnly
        case disconnected
        case open(interactive: Bool)
        case failed(String)
    }

    /// Where a close should leave us: fully idle (leave / abandon), or back
    /// to the visible results window (non-interactive sync-end close).
    enum CloseOutcome: Equatable { case toIdle, backToReady }

    /// Result of the connect phase. Deliberately NOT `ConnectionState`: a
    /// connect that *failed* must go through `operationFailed`, so the
    /// driver can't authorize a scan over a `.failed` connection.
    enum ConnectResult: Equatable { case local, remote(interactive: Bool) }

    /// How the user chose to leave a running sync.
    enum SyncExitIntent: Equatable {
        case stopAndKeepWindow   // abort, keep window, present terminal results
        case abortAndClose       // abort, suppress results, close after unwind
        case closeAndLetRun      // no abort, suppress results, close after completion
    }

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
        case abortSync(SessionID, OperationID)               // cooperative Abort.all on the running sync
        case showWaiting(OpenRequestID, profile: String)     // queued behind a busy op
        case presentScanResults(SessionID)
        /// Sync completed and its per-row snapshot marshalled — present results.
        case presentSyncResults(SessionID, [SyncSnapshotRow])
        /// Sync completed but its per-row results could not be produced. The
        /// engine is quiescent (sync + archive commit finished); this is a
        /// read-only-results failure, NOT engine contamination — so it does NOT
        /// go through `restartRequired`.
        case presentSyncUnavailable(SessionID, reason: String)
        case restartRequired(reason: String)
    }

    /// Outcome of the post-sync completion snapshot, delivered to
    /// `syncCompleted`. Both cases consume the same pending `(session, op)` and
    /// release the sync lease exactly once; they differ only in which present
    /// effect fires.
    enum SyncResults: Equatable {
        case available([SyncSnapshotRow])
        case unavailable(reason: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var connection: ConnectionState = .disconnected

    private var abandoned = false
    private var currentProfile: String?
    private var queued: (id: OpenRequestID, profile: String)?

    /// A rescan requested while a non-interactive sync-end close is still in
    /// flight (`.closing(..., .backToReady)`). It cannot start until the close
    /// returns (the connection is being torn down); recorded here and consumed
    /// by `closeCompleted` so the reconnect/scan starts immediately after a
    /// successful close (finding 4). Not a parallel lifecycle state in the
    /// window controller — one flag, owned solely by the coordinator.
    private var rescanAfterClose: SessionID?

    // Callback-identity invariant (finding 5). The bridge callbacks do NOT
    // carry op tokens. Correct attribution therefore rests on a strict
    // NON-OVERLAP invariant the driver enforces: at most one connect / scan /
    // sync bridge op is ever in flight at a time (the driver's mutually
    // exclusive pendingConnect/pendingScan/pendingSync slots), and a new op of
    // a kind is only started after the previous terminal event. The driver
    // records the `(SessionID, OperationID)` it started an op with and passes
    // that same token back on completion; every terminal event here is guarded
    // on *exact phase + session + op*, so a stale or duplicate delivery is a
    // no-op. The reducer's token rejection (stale/duplicate terminal events) is
    // unit-tested. The driver-side non-overlap itself is NOT covered by a
    // permanent driver test harness — it rests on the driver's mutually
    // exclusive pending slots (code structure) and is exercised by live
    // testing. If overlap were ever introduced, tokens would have to be threaded
    // through the bridge instead.

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

    /// The single coordinator-owned policy for destructive engine/archive
    /// maintenance (Clean Stale Archives, Reset Archives, deleting a
    /// profile's archives, or anything else that moves/deletes/rewrites
    /// Unison archive files). Such mutation touches the very `ar*`/`fp*`/`lk*`
    /// files a live operation reads or writes, so it is allowed ONLY when the
    /// engine owns no session at all — exactly `.idle`. Every other phase
    /// (`.opening`/`.scanning`/`.ready`/`.syncing`/`.closing`/`.restartRequired`)
    /// forbids it: a background sync/scan can still be reading archives, a
    /// close is still tearing the connection down, and `.restartRequired`
    /// means the runtime is in an uncertain state that a restart must clear
    /// first. Drivers gate UI on this AND recheck it immediately before the
    /// mutation (disabled controls alone can't close the confirm-sheet TOCTOU
    /// window — the engine can become busy while a sheet is up).
    var allowsDestructiveArchiveMutation: Bool { phase == .idle }

    /// True only in the terminal `restartRequired` phase. Used by the driver
    /// to authorize orphan-connection cleanup after a watchdog-invalidated
    /// connect: `currentSession == nil` alone would also be true in ordinary
    /// `.idle`, which is NOT an orphan-cleanup state.
    var isRestartRequired: Bool {
        if case .restartRequired = phase { return true }
        return false
    }

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
        case .closing(let s, let op, .backToReady):
            // A non-interactive sync-end close is in flight but the user is
            // moving on. Picking another profile means this session should
            // end, not return to its results window — upgrade the outcome so
            // the close idles and the queued open then starts.
            let id = mintRequest()
            queued = (id, profile)
            phase = .closing(s, op, .toIdle)
            return [.showWaiting(id, profile: profile)]
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
        // Finding 4: a rescan requested while a non-interactive sync-end close
        // is still in flight must not be silently discarded. Record the intent;
        // `closeCompleted` starts the reconnect/scan once the close returns.
        if case .closing(let s, _, .backToReady) = phase {
            rescanAfterClose = s
            return []
        }
        guard case .ready(let s) = phase else { return [] }
        switch connection {
        case .open, .localOnly:
            // A live remote connection or a local session can be rescanned
            // directly (init2) — no reconnect, no init1 rerun. A local
            // session has no connection to re-establish.
            let op = mintOp()
            phase = .scanning(s, op)
            return [.beginScan(s, op)]
        case .disconnected:
            // Remote connection is closed — reconnect (init1) before scanning.
            guard let profile = currentProfile else {
                return enterRestartRequired("ready session has no profile")
            }
            let op = mintOp()
            phase = .opening(s, op)
            return [.beginConnect(s, op, profile: profile)]
        case .failed(let r):
            return enterRestartRequired("previous close failed: \(r)")
        }
    }

    /// User pressed Go. Authorizes the sync via `.beginSync`; the driver
    /// must call the bridge only in response to that effect.
    func requestSync() -> [Effect] {
        guard case .ready(let s) = phase else { return [] }
        // Finding 5: never authorize a remote sync over a closed connection.
        switch connection {
        case .open, .localOnly:
            let op = mintOp()
            phase = .syncing(s, op)
            return [.beginSync(s, op)]
        case .disconnected:
            // Remote connection was closed (e.g. after a non-interactive
            // sync-end close). Refuse — the user must Rescan (reconnect) first.
            return []
        case .failed(let r):
            return enterRestartRequired("cannot sync: previous close failed: \(r)")
        }
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
        case .closing(let s, let op, .backToReady):
            // The sync-end close is still running; the window is going away.
            // Upgrade it to end at idle instead of returning to a now-gone
            // results window (which would strand an ownerless .ready).
            phase = .closing(s, op, .toIdle)
            abandoned = true
            return []
        case .closing(_, _, .toIdle), .idle, .restartRequired:
            return []
        }
    }

    /// The user chose how to leave a running sync (Stop / Abort & Close /
    /// Close-and-let-run). Routes the abort through the coordinator so it,
    /// not the window, is the single authority over engine actions.
    func requestSyncExit(_ intent: SyncExitIntent) -> [Effect] {
        guard case .syncing(let session, let op) = phase else { return [] }
        switch intent {
        case .stopAndKeepWindow:
            return [.abortSync(session, op)]
        case .abortAndClose:
            abandoned = true
            return [.abortSync(session, op)]
        case .closeAndLetRun:
            abandoned = true
            return []
        }
    }

    // MARK: - Engine terminal events (token-bound, phase-exact)

    /// Connect phase finished; `connection` is `.open(interactive:)` for a
    /// remote root or `.localOnly` for a local one. Authorizes the scan.
    func connectFinished(_ session: SessionID, _ op: OperationID,
                         result: ConnectResult) -> [Effect] {
        guard case .opening(session, op) = phase else { return [] }
        switch result {
        case .local:                  connection = .localOnly
        case .remote(let interactive): connection = .open(interactive: interactive)
        }
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

    func syncCompleted(_ session: SessionID, _ op: OperationID,
                       results: SyncResults) -> [Effect] {
        // Bind to the EXACT pending sync; stale / duplicate / wrong-operation
        // completions match no phase and are dropped (lease released once).
        guard case .syncing(session, op) = phase else { return [] }
        if abandoned { return beginClose(session, outcome: .toIdle) }
        phase = .ready(session)
        // `.available` and `.unavailable` follow the IDENTICAL lifecycle: the
        // engine is quiescent and the archive is committed either way, so an
        // unavailable snapshot must NOT enter restartRequired. Only the present
        // effect differs.
        let present: Effect
        switch results {
        case .available(let snapshot):     present = .presentSyncResults(session, snapshot)
        case .unavailable(let reason):     present = .presentSyncUnavailable(session, reason: reason)
        }
        // Auth-cost policy (2b): non-interactive closes now (window stays);
        // interactive holds until leave.
        if case .open(interactive: false) = connection {
            return [present] + beginClose(session, outcome: .backToReady)
        }
        return [present]
    }

    /// Result of a `closeConnection` effect. Guarded on the exact close op
    /// so a delayed close from an older operation can't touch the current
    /// connection.
    func closeCompleted(_ session: SessionID, _ op: OperationID, status: Int32) -> [Effect] {
        guard case .closing(session, op, let outcome) = phase else { return [] }
        if status == 0 {
            connection = .disconnected
            switch outcome {
            case .toIdle:
                rescanAfterClose = nil
                return finishToIdle()
            case .backToReady:
                // Finding 4: a rescan requested during this close (recorded in
                // `rescanAfterClose`) starts now — reconnect over the
                // just-closed connection, then scan.
                if rescanAfterClose == session {
                    rescanAfterClose = nil
                    guard let profile = currentProfile else {
                        return enterRestartRequired("close-then-rescan: session has no profile")
                    }
                    let op2 = mintOp()
                    phase = .opening(session, op2)
                    return [.beginConnect(session, op2, profile: profile)]
                }
                phase = .ready(session)
                return []
            }
        }
        // Any close failure leaves the engine unsafe for reuse — surface it
        // immediately regardless of why the close was started (finding 4: a
        // close failure still transitions to restartRequired even with a
        // rescan queued).
        connection = .failed("status \(status)")
        rescanAfterClose = nil
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
    /// A per-row mutation (direction override / Ignore) failed AFTER OCaml
    /// state began changing while the session sat in `.ready` (Blocker 4). The
    /// engine is no longer provably consistent with the displayed rows, so we
    /// cannot leave the ready UI live/actionable — transition to
    /// restart-required. A no-op unless we are actually `.ready` (a stale action
    /// arriving in another phase is ignored).
    func engineBecameUncertain(reason: String) -> [Effect] {
        guard case .ready = phase else { return [] }
        return enterRestartRequired(reason)
    }

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
        connection = .disconnected
        currentProfile = profile
        return [.showSession(s, profile: profile), .beginConnect(s, op, profile: profile)]
    }

    private func beginClose(_ session: SessionID, outcome: CloseOutcome) -> [Effect] {
        switch connection {
        case .open:
            let op = mintOp()
            phase = .closing(session, op, outcome)
            return [.closeConnection(session, op)]
        case .localOnly, .disconnected:
            // No live connection to close — go straight to the outcome.
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
        connection = .disconnected
        currentProfile = nil
        rescanAfterClose = nil
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
        rescanAfterClose = nil
        return [.restartRequired(reason: reason)]
    }
}
