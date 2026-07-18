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
/// Only a *genuine terminal callback* (`scanCompleted` / `syncCompleted`
/// / `closeCompleted`) releases the engine lease. `abandon(...)` — the
/// user left the window, pressed Stop during a scan, or a watchdog fired
/// — merely marks the in-flight op abandoned and defers the connection
/// close until that op actually terminates. If it never terminates, the
/// coordinator stays busy (a queued open keeps waiting) rather than
/// pretending the engine went idle.
///
/// Pure logic: all side effects go through `Driver`, so the machine is
/// unit-testable with a fake driver (see EngineSessionCoordinatorTests).
@MainActor
final class EngineSessionCoordinator {

    /// Opaque per-operation token. Carried through every bridge callback
    /// so a stale/superseded completion is recognized and can still
    /// release its own lease without corrupting a newer op.
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

    /// Side effects the coordinator asks its owner (AppDelegate) to
    /// perform. The coordinator never calls the bridge or AppKit directly.
    @MainActor
    protocol Driver: AnyObject {
        /// Create/show the reconcile window in scanning state and run the
        /// full connect+scan (init1 → prompts → init2) for `token`.
        func engineBeginOpen(token: Token, profile: String)
        /// Re-run init2 only, reusing the live connection, for `token`.
        func engineBeginRescanReuse(token: Token)
        /// Close the established connection off-main; report the result
        /// back via `closeCompleted(token:status:)`.
        func engineCloseConnection(token: Token)
        /// A profile was picked while busy: show its window waiting for the
        /// previous operation to finish.
        func engineShowWaiting(profile: String)
        /// The engine can't continue (close failed, or an abandoned op is
        /// wedged) — tell the user to quit and reopen.
        func engineRestartRequired(reason: String)
    }

    weak var driver: Driver?

    private(set) var phase: Phase = .idle
    private(set) var connection: ConnectionState = .none

    /// The active op's window was abandoned by the user; close the
    /// connection and go idle once the op terminates, don't surface UI.
    private var abandoned = false
    /// Profile to open once the engine returns to idle (last pick wins).
    private var queuedOpen: String?
    private var nextRaw: UInt64 = 0

    init(driver: Driver? = nil) { self.driver = driver }

    // MARK: - Queries (used by the driver to gate UI-result processing)

    /// True when `token` is the live op AND its window hasn't been
    /// abandoned — i.e. UI results for it should still be shown. A stale
    /// or abandoned token returns false: its terminal callback still
    /// releases the lease, but its UI work is suppressed.
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

    /// User picked a profile in the picker. Starts immediately if idle,
    /// else queues behind the in-flight (possibly abandoned) op. Returns
    /// the token if it started now, nil if queued/refused.
    @discardableResult
    func requestOpen(profile: String) -> Token? {
        switch phase {
        case .idle:
            let token = mintToken()
            phase = .opening(token)
            abandoned = false
            connection = .none
            driver?.engineBeginOpen(token: token, profile: profile)
            return token
        case .restartRequired(let reason):
            // Don't start new work against a contaminated runtime.
            driver?.engineRestartRequired(reason: reason)
            return nil
        default:
            // Busy: an earlier op (typically abandoned) is still running.
            queuedOpen = profile          // last pick wins
            driver?.engineShowWaiting(profile: profile)
            return nil
        }
    }

    /// User asked to rescan the open profile. Reuses the live connection
    /// if one is open, else re-establishes it (full open+scan).
    func requestRescan(profile: String) {
        guard case .ready(let prev) = phase else { return }  // only from ready
        let token = mintToken()
        switch connection {
        case .open:
            phase = .scanning(token)
            driver?.engineBeginRescanReuse(token: token)
        case .none:
            // Connection was closed on sync-end (non-interactive): reopen.
            phase = .opening(token)
            driver?.engineBeginOpen(token: token, profile: profile)
        case .closing, .closeFailed:
            // A close is in flight or failed — don't scan over it.
            phase = .ready(prev)  // stay put
            if case .closeFailed(let r) = connection {
                enterRestartRequired("previous close failed: \(r)")
            }
        }
    }

    /// The user started a sync (Go).
    func syncStarted(_ token: Token) {
        guard case .ready(let t) = phase, t == token else { return }
        phase = .syncing(token)
    }

    /// User left the profile / pressed Stop / a watchdog fired. Never
    /// idles the engine: if an op is in flight it keeps its lease and the
    /// connection close is deferred to that op's terminal callback.
    func abandon(reason: String) {
        switch phase {
        case .ready:
            // Engine already idle (awaiting user) — safe to close now.
            beginCloseThenIdle()
        case .opening, .scanning, .syncing:
            abandoned = true   // close + idle happen on the terminal callback
        case .closing, .idle, .restartRequired:
            break              // nothing to abandon
        }
    }

    // MARK: - Engine terminal events (from bridge callbacks)

    /// Remote connection established (drivePromptLoop reached "no more
    /// prompts"). `interactive` = a password sheet was shown this connect.
    func connectionOpened(_ token: Token, interactive: Bool) {
        guard activeToken == token else { return }
        connection = .open(interactive: interactive)
        if case .opening = phase { phase = .scanning(token) }
    }

    /// Scan (init2) finished — ALWAYS releases the scan lease, even for a
    /// superseded/abandoned op (that's the whole point).
    func scanCompleted(_ token: Token) {
        guard activeToken == token else { return }
        if abandoned {
            beginCloseThenIdle()
        } else {
            phase = .ready(token)
        }
    }

    /// Sync finished (after commitUpdates) — ALWAYS releases the lease.
    func syncCompleted(_ token: Token) {
        guard activeToken == token else { return }
        if abandoned {
            beginCloseThenIdle()      // let-it-run / abort&close → close after done
            return
        }
        // Stay-open completion: apply the auth-cost close policy.
        phase = .ready(token)
        switch connection {
        case .open(interactive: false):
            // Non-interactive: close now; a later Rescan reopens silently.
            connection = .closing
            driver?.engineCloseConnection(token: token)
        case .open(interactive: true), .none, .closing, .closeFailed:
            break  // interactive → hold until leave; local → nothing
        }
    }

    /// Result of an `engineCloseConnection` request.
    func closeCompleted(_ token: Token, status: Int32) {
        // A close belongs to whatever op requested it; tolerate a token
        // that's no longer active (op already advanced) but only act on
        // the current one.
        if status == 0 {
            connection = .none
            if case .closing = phase { finishToIdle() }
            // else: sync-end close while .ready — connection cleared, window stays.
        } else {
            let msg = "close returned status \(status)"
            connection = .closeFailed(msg)
            if case .closing = phase {
                // Can't safely reach idle; a fresh init1 would race residual
                // engine state. Require restart.
                enterRestartRequired(msg)
            }
            // else: stay .ready with a failed connection; leave/rescan handles it.
        }
    }

    // MARK: - Internal transitions

    private func beginCloseThenIdle() {
        guard let token = activeToken else { finishToIdle(); return }
        switch connection {
        case .open:
            connection = .closing
            phase = .closing(token)
            driver?.engineCloseConnection(token: token)
        case .none:
            finishToIdle()
        case .closing:
            phase = .closing(token)   // already closing; wait for closeCompleted
        case .closeFailed(let r):
            enterRestartRequired("close failed: \(r)")
        }
    }

    private func finishToIdle() {
        phase = .idle
        abandoned = false
        connection = .none
        if let profile = queuedOpen {
            queuedOpen = nil
            _ = requestOpen(profile: profile)
        }
    }

    private func enterRestartRequired(_ reason: String) {
        phase = .restartRequired(reason)
        abandoned = false
        queuedOpen = nil
        driver?.engineRestartRequired(reason: reason)
    }
}
