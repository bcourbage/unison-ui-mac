import Foundation

/// Outcome of asking the broker to start a diff.
enum DiffRequestResult: Equatable {
    /// The diff was issued to the engine; its result will arrive asynchronously.
    case issued
    /// Refused: a diff is already outstanding, or an abandoned one is still
    /// draining. The UI gives brief feedback and does nothing else.
    case refused
    /// `run_show_diffs` returned false (the dispatch raised in OCaml). No async
    /// result will arrive; the caller surfaces a narrow diff error.
    case raised
}

/// APP-GLOBAL serializer/owner for asynchronous per-row diff requests.
///
/// Why global (not per-window): the OCaml diff result carries **no request
/// identifier** and is delivered through a single permanent C handler that, in
/// the app, is routed to the *current* session's window. A per-window
/// coordinator therefore cannot protect a replacement session — a late result
/// from an abandoned session is routed to whatever window is now current and,
/// if that window has its own pending request, accepted as *its* result. The
/// only way to make the "a late result of an abandoned/replaced session can
/// never be accepted as a new session's result" invariant REAL (not
/// timing-dependent) without round-tripping an id through OCaml is to serialize
/// globally and gate on draining:
///
/// - At most ONE diff is outstanding across the whole app, tagged with its
///   owning session.
/// - When the owning session is abandoned/replaced while its request is still
///   outstanding, the broker enters `draining` and REFUSES new requests until
///   the now-unwanted result arrives and is discarded. So a replacement
///   session's request is never issued while an older result is in flight, and
///   an abandoned result can never be delivered as a newer session's result.
///
/// Pure and synchronous — mutated on the main actor; no threading here, which
/// is what makes the invariant unit-testable against the exact dangerous
/// ordering rather than a race.
struct DiffRequestBroker: Equatable {
    /// Opaque owner identity — the raw value of the requesting `SessionID`.
    typealias Owner = UInt64

    private enum State: Equatable {
        /// Nothing outstanding; a request may be issued.
        case idle
        /// A request is outstanding, owned by `owner`, awaiting its result.
        case outstanding(Owner)
        /// The owner of the outstanding request went away; its result is still
        /// in flight and must be discarded before any new request is allowed.
        case draining
    }
    private var state: State = .idle

    enum RequestDecision: Equatable {
        case issue
        /// A diff owned by some session is already outstanding.
        case refuseInFlight
        /// An abandoned request's result has not yet drained.
        case refuseDraining
    }

    enum Delivery: Equatable {
        /// Publish to `owner`'s window; the request is complete.
        case apply(owner: Owner)
        /// Drop it — no wanted request is outstanding (drained an abandoned
        /// result, or a spurious/duplicate delivery). Publish nothing.
        case dropStale
    }

    /// True iff a wanted request is outstanding (awaiting its result).
    var isAwaitingResult: Bool {
        if case .outstanding = state { return true } else { return false }
    }
    /// True while an abandoned result is still being drained.
    var isDraining: Bool { state == .draining }

    /// Ask to start a diff owned by `owner`. Issues only from idle; a request
    /// already outstanding (any owner) is refused, and a draining abandoned
    /// request refuses new work until it drains.
    mutating func request(owner: Owner) -> RequestDecision {
        switch state {
        case .idle:
            state = .outstanding(owner)
            return .issue
        case .outstanding:
            return .refuseInFlight
        case .draining:
            return .refuseDraining
        }
    }

    /// `run_show_diffs` returned false for `owner`'s just-issued request: the
    /// OCaml dispatch raised, so NO async result will arrive. Clear to idle
    /// (only if this owner still holds the outstanding request). A read-only
    /// diff query raising does not corrupt engine state, so nothing escalates.
    mutating func requestRaised(owner: Owner) {
        if case .outstanding(let o) = state, o == owner { state = .idle }
    }

    /// A diff result/error arrived. Because at most one request is ever
    /// outstanding and a replacement is refused until an abandoned result
    /// drains, a delivery is unambiguous:
    /// - outstanding → apply to its owner (the wanted session);
    /// - draining → this IS the abandoned result: discard it and return to idle;
    /// - idle → nothing wanted it: drop.
    mutating func deliver() -> Delivery {
        switch state {
        case .outstanding(let o):
            state = .idle
            return .apply(owner: o)
        case .draining:
            state = .idle
            return .dropStale
        case .idle:
            return .dropStale
        }
    }

    /// `owner`'s session/diff-window is going away. If it owns the outstanding
    /// request, enter draining so its still-in-flight result is discarded and
    /// no new request is issued until then. If it doesn't own the outstanding
    /// request (nothing outstanding, or a different owner — which cannot happen
    /// while serialized, but is handled defensively), this is a no-op.
    mutating func abandon(owner: Owner) {
        if case .outstanding(let o) = state, o == owner { state = .draining }
    }
}
