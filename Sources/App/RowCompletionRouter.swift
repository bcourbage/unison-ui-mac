import Foundation

/// Extracted, unit-testable routing for the two asynchronous bridge completions
/// that deliver a fresh `[StateItem]` set: a **scan** completion (`init2`) and a
/// successful **Ignore** completion. They ride SEPARATE identity tokens, which is
/// the whole point of the extraction — the invariants fall out of keeping them
/// apart:
///
///   - An Ignore completion can never satisfy or clear a pending scan (or a
///     later rescan): `routeIgnore` reads only `pendingIgnore`, `routeScan` reads
///     only `pendingScan`. Neither can return the other's route.
///   - A stale/duplicate completion is dropped: the driver clears the token when
///     it consumes a route, so a second completion finds `nil` → `.drop`.
///   - A completion for a session that is no longer live (closed or replaced by
///     a new session with a distinct id) is dropped rather than updating the
///     replacement: `routeIgnore` requires the pending session to be in
///     `liveSessions`.
///
/// These are pure functions; the driver (AppDelegate) owns the token storage and
/// the live-session set (its `windowBySession` keys) and clears the consumed
/// token. Tests drive these directly — the real routing logic, not a bridge test
/// handler installed in place of it.
enum RowCompletionRoute: Equatable {
    case scan(session: EngineSessionCoordinator.SessionID,
              op: EngineSessionCoordinator.OperationID)
    case ignore(session: EngineSessionCoordinator.SessionID)
    case drop
}

enum RowCompletionRouter {
    /// A scan (`init2`) completion routes solely on `pendingScan`. Session
    /// liveness for the scan path is enforced downstream by the coordinator
    /// (`scanCompleted` no-ops on a stale/abandoned op).
    static func routeScan(
        pendingScan: (EngineSessionCoordinator.SessionID,
                      EngineSessionCoordinator.OperationID)?
    ) -> RowCompletionRoute {
        guard let (s, op) = pendingScan else { return .drop }
        return .scan(session: s, op: op)
    }

    /// A successful Ignore completion routes solely on `pendingIgnore`, and only
    /// if that session is still live — so a completion arriving after the
    /// session was closed or replaced updates nothing.
    static func routeIgnore(
        pendingIgnore: EngineSessionCoordinator.SessionID?,
        liveSessions: Set<EngineSessionCoordinator.SessionID>
    ) -> RowCompletionRoute {
        guard let s = pendingIgnore, liveSessions.contains(s) else { return .drop }
        return .ignore(session: s)
    }
}
