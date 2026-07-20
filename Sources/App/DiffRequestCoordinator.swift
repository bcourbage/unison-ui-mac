import Foundation

/// Serializes and identifies asynchronous per-row diff requests so an older,
/// slower result can never overwrite a newer selection, and a result that
/// arrives after the window/session went away is dropped (Lower-severity L1 +
/// the residual Finding #6 test gap).
///
/// Why a coordinator and not a request ID that round-trips: the OCaml diff
/// result (`displayInfoDiff`) carries no request identifier, and it is
/// delivered `DispatchQueue.main.async` from the worker thread — so results can
/// arrive out of order relative to requests and can land on a replacement
/// session's window (the permanent handler routes to `currentSession`). Since a
/// result can't be matched to its request after the fact, correctness comes
/// from **serializing**: at most one diff is outstanding, so the single
/// delivery unambiguously belongs to it. A monotonic token additionally lets
/// `invalidate()` (window close / session teardown / cancellation) drop any
/// result still in flight.
///
/// Pure and synchronous — the controller calls it on the main actor; there is
/// no threading here, which is exactly what makes the policy unit-testable.
struct DiffRequestCoordinator: Equatable {
    /// Token of the outstanding request, or nil when none is in flight.
    private(set) var pendingToken: Int?
    private var nextToken = 1

    /// Whether a diff result/error is currently expected.
    var isAwaitingResult: Bool { pendingToken != nil }

    enum RequestDecision: Equatable {
        /// Proceed: issue `run_show_diffs`. Carries the request's token.
        case issue(token: Int)
        /// A diff is already in flight; refuse so its pending result stays
        /// unambiguous. The UI gives brief feedback and does nothing else.
        case refuseInFlight
    }

    enum Delivery: Equatable {
        /// Deliver to the diff window; the request is now complete.
        case apply
        /// No request is outstanding (already delivered, superseded, or the
        /// window/session went away) — drop it, publish nothing.
        case dropStale
    }

    /// A new diff was requested. Serialize: only issue when nothing is pending.
    mutating func request() -> RequestDecision {
        guard pendingToken == nil else { return .refuseInFlight }
        let token = nextToken
        nextToken += 1
        pendingToken = token
        return .issue(token: token)
    }

    /// `run_show_diffs` returned false (the dispatch raised in OCaml). No async
    /// result will arrive, so clear the pending state; the caller surfaces the
    /// error synchronously. A read-only diff query raising does not corrupt
    /// engine state, so nothing is escalated.
    mutating func requestRaised() {
        pendingToken = nil
    }

    /// A diff result or error arrived. Applied only when a request is
    /// outstanding; otherwise dropped as stale (late/duplicate/superseded, or
    /// routed to a window that never requested it).
    mutating func deliver() -> Delivery {
        guard pendingToken != nil else { return .dropStale }
        pendingToken = nil
        return .apply
    }

    /// The diff window closed, the reconcile session is being torn down, or the
    /// request is otherwise cancelled: forget any in-flight request so a late
    /// result is dropped and a fresh diff can be requested.
    mutating func invalidate() {
        pendingToken = nil
    }
}
