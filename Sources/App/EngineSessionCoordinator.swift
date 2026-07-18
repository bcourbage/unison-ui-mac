import Foundation

/// Single authority for the Unison engine's per-profile lifecycle
/// (issue #6). Replaces the ad-hoc booleans (`engineBusy`,
/// `remoteConnectionOpen`, generation counters, deferred-close handlers)
/// with one explicit state machine.
///
/// The invariant the ad-hoc version violated:
///
///     UI abandoned  ≠  operation stopped  ≠  engine idle
///
/// Only a *genuine terminal event* (`scanCompleted` / `syncCompleted` /
/// `closeCompleted`) releases the engine lease. `abandon(...)` — the user
/// left the window, pressed Stop during a scan, or a watchdog fired —
/// merely marks the in-flight op abandoned and defers the connection close
/// until that op actually terminates. If it never terminates the
/// coordinator stays busy (a queued open keeps waiting) rather than
/// pretending the engine went idle.
///
/// **Pure reducer.** Every event method fully mutates state and then
/// returns a list of `Effect`s for the caller (AppDelegate) to perform.
/// The coordinator never calls out mid-transition, so a reentrant driver
/// callback can never observe a half-transitioned state. This makes the
/// machine trivially unit-testable: assert `(phase, connection, effects)`.
@MainActor
final class EngineSessionCoordinator {

    /// Opaque per-operation token. The driver records the token when it
    /// *starts* a bridge operation and passes that same token back on the
    /// operation's completion — never "whatever token is active now", which
    /// would misattribute a stale event to a newer session.
    struct Token: Hashable, CustomStringConvertible {
        let raw: UInt64
        var description: String { "op#\(raw)" }
    }

    /// Established-connection state. A close is asynchronous, so this
    /// distinguishes "we asked to close" from "it's actually closed", and
    /// records a failure instead of silently assuming success.
    enum ConnectionState: Equatable {
        case none
        case open(interactive: Bool)
        case closing
        case closeFailed(String)
    }

    /// Engine phase. Exactly one engine operation is ever in flight (the
    /// OCaml runtime is single-session), so the active op's token lives in
    /// the phase.
    enum Phase: Equatable {
        case idle
        case opening(Token)   // init1 + credential prompt (connect phase)
        case scanning(Token)  // init2 (update detection)
        case ready(Token)     // scan done; awaiting the user
        case syncing(Token)   // transport in flight
        case closing(Token)   // connection teardown in flight
        case restartRequired(String)  // unrecoverable; needs quit/reopen
    }

    /// A side effect for the caller to perform *after* the coordinator has
    /// finished mutating its state. Returned from event methods; never
    /// executed by the coordinator itself.
    enum Effect: Equatable {
        case beginOpen(token: Token, profile: String)     // create window + init1→scan
        case beginRescanReuse(token: Token)               // init2 only, live connection
        case closeConnection(token: Token)                // off-main close; report closeCompleted
        case showWaiting(profile: String)                 // queued: window waits
        case presentScanResults(token: Token)             // populate the window's items
        case presentSyncResults(token: Token)             // finalize the sync UI
        case restartRequired(reason: String)              // tell the user to quit/reopen
    }

    private(set) var phase: Phase = .idle
    private(set) var connection: ConnectionState = .none

    /// The active op's window was abandoned by the user; close the
    /// connection and go idle once the op terminates, don't surface UI.
    private var abandoned = false
    /// Profile to open once the engine returns to idle (last pick wins).
    private var queuedOpen: String?
    private var nextRaw: UInt64 = 0

    // MARK: - Queries

    /// True when `token` is the live op AND its window hasn't been
    /// abandoned — i.e. status/progress for it should still be shown.
    /// Terminal events use their returned effects instead of this.
    func isCurrent(_ token: Token) -> Bool {
        activeToken == token && !abandoned
    }

    var isIdle: Bool { phase == .idle }

    private var activeToken: Token? {
        switch phase {
        case .opening(let t), .scanning(let t), .ready(let t),
             .syncing(let t), .closing(let t):
            return t
        case .idle, .restartRequired:
            return nil
        }
    }

    private func mintToken() -> Token {
        nextRaw += 1
        return Token(raw: nextRaw)
    }

    // MARK: - User intents

    /// User picked a profile. Starts immediately if idle, else queues
    /// behind the in-flight (possibly abandoned) op.
    func requestOpen(profile: String) -> [Effect] {
        switch phase {
        case .idle:
            let token = mintToken()
            phase = .opening(token)
            abandoned = false
            connection = .none
            return [.beginOpen(token: token, profile: profile)]
        case .restartRequired(let reason):
            return [.restartRequired(reason: reason)]
        default:
            queuedOpen = profile          // last pick wins
            return [.showWaiting(profile: profile)]
        }
    }

    /// User asked to rescan. Reuses the live connection if open, else
    /// re-establishes it (full open+scan).
    func requestRescan(profile: String) -> [Effect] {
        guard case .ready(let prev) = phase else { return [] }
        switch connection {
        case .open:
            let token = mintToken()
            phase = .scanning(token)
            return [.beginRescanReuse(token: token)]
        case .none:
            let token = mintToken()
            phase = .opening(token)
            return [.beginOpen(token: token, profile: profile)]
        case .closeFailed(let r):
            return enterRestartRequired("previous close failed: \(r)")
        case .closing:
            phase = .ready(prev)          // a close is mid-flight; stay put
            return []
        }
    }

    /// User started a sync (Go).
    func syncStarted(_ token: Token) -> [Effect] {
        guard case .ready(let t) = phase, t == token else { return [] }
        phase = .syncing(token)
        return []
    }

    /// User left the profile / pressed Stop / a watchdog fired. Never idles
    /// the engine: an in-flight op keeps its lease and its connection close
    /// is deferred to its terminal event.
    func abandon(reason: String) -> [Effect] {
        switch phase {
        case .ready:
            return beginCloseThenIdle()   // engine idle → safe to close now
        case .opening, .scanning, .syncing:
            abandoned = true              // close + idle on the terminal event
            return []
        case .closing, .idle, .restartRequired:
            return []
        }
    }

    // MARK: - Engine terminal events (from bridge callbacks, token-bound)

    /// Remote connection established. `interactive` = a password sheet was
    /// shown this connect.
    func connectionOpened(_ token: Token, interactive: Bool) -> [Effect] {
        guard activeToken == token else { return [] }
        connection = .open(interactive: interactive)
        if case .opening = phase { phase = .scanning(token) }
        return []
    }

    /// Scan (init2) finished — ALWAYS releases the scan lease, even for an
    /// abandoned op (the whole point).
    func scanCompleted(_ token: Token) -> [Effect] {
        guard activeToken == token else { return [] }
        if abandoned {
            return beginCloseThenIdle()
        }
        phase = .ready(token)
        return [.presentScanResults(token: token)]
    }

    /// Sync finished (after commitUpdates) — ALWAYS releases the lease.
    func syncCompleted(_ token: Token) -> [Effect] {
        guard activeToken == token else { return [] }
        if abandoned {
            return beginCloseThenIdle()   // let-it-run / abort&close → close after done
        }
        phase = .ready(token)
        // Auth-cost close policy (2b): non-interactive closes now, window
        // stays; interactive holds until leave.
        if case .open(interactive: false) = connection {
            connection = .closing
            return [.presentSyncResults(token: token), .closeConnection(token: token)]
        }
        return [.presentSyncResults(token: token)]
    }

    /// Result of a `closeConnection` effect.
    func closeCompleted(_ token: Token, status: Int32) -> [Effect] {
        if status == 0 {
            connection = .none
            if case .closing = phase { return finishToIdle() }
            return []                     // sync-end close while .ready — cleared, window stays
        }
        let msg = "close returned status \(status)"
        connection = .closeFailed(msg)
        if case .closing = phase {
            return enterRestartRequired(msg)   // can't safely idle over residual state
        }
        return []                          // .ready with a failed connection; leave/rescan handles it
    }

    // MARK: - Internal transitions (mutate, then return effects)

    private func beginCloseThenIdle() -> [Effect] {
        guard let token = activeToken else { return finishToIdle() }
        switch connection {
        case .open:
            connection = .closing
            phase = .closing(token)
            return [.closeConnection(token: token)]
        case .none:
            return finishToIdle()
        case .closing:
            phase = .closing(token)       // already closing; wait for closeCompleted
            return []
        case .closeFailed(let r):
            return enterRestartRequired("close failed: \(r)")
        }
    }

    private func finishToIdle() -> [Effect] {
        phase = .idle
        abandoned = false
        connection = .none
        if let profile = queuedOpen {
            queuedOpen = nil
            return requestOpen(profile: profile)   // mutates to opening, returns .beginOpen
        }
        return []
    }

    private func enterRestartRequired(_ reason: String) -> [Effect] {
        phase = .restartRequired(reason)
        abandoned = false
        queuedOpen = nil
        return [.restartRequired(reason: reason)]
    }
}
