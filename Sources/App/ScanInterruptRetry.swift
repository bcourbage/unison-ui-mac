import Foundation

/// Identity-bound authority for retrying a post-interruption reconnect that hit
/// a transient "archives are locked" (issue #24 live-matrix finding). A Stop
/// Scan SIGKILLs the transport; the orphaned remote `unison -server` releases
/// its (empty, owner-less) archive lock only when it asynchronously notices the
/// dropped socket, so a reconnect that beats that release hits the lock. The
/// driver retries the reconnect, bounded.
///
/// The lease binds that authority to the EXACT reconnect it was issued for —
/// `(profile, session, reconnect op)` — so a leaked/stale lease can NEVER
/// authorize a retry for a different profile, a replacement session, or a
/// superseded operation (the round-4 stale-state defect: `.returnToPicker`
/// closing through `driveCloseInterruptWindow` used to leave loose retry flags
/// that the next selected profile inherited). Pure value type; the driver holds
/// exactly one and clears it at every teardown/terminal path.
struct ScanInterruptRetryLease: Equatable {
    let profile: String
    let session: EngineSessionCoordinator.SessionID
    /// The reconnect's SCAN operation this authority is bound to.
    let op: EngineSessionCoordinator.OperationID
    let retriesLeft: Int

    /// A lock fatal is retryable ONLY when it belongs to this lease's exact
    /// reconnect and budget remains. Rejects wrong-profile, wrong-session,
    /// wrong-operation, and exhausted cases.
    func accepts(profile p: String,
                 session s: EngineSessionCoordinator.SessionID,
                 op o: EngineSessionCoordinator.OperationID) -> Bool {
        retriesLeft > 0 && profile == p && session == s && op == o
    }

    /// The lease to carry into the next retry (one fewer attempt).
    func decremented() -> ScanInterruptRetryLease {
        ScanInterruptRetryLease(profile: profile, session: session, op: op,
                                retriesLeft: retriesLeft - 1)
    }
}

enum ScanInterruptRetryPolicy {
    /// What to do with a Unison "archives are locked" fatal, given the current
    /// lease and whether a retry reopen is already in flight.
    enum Decision: Equatable {
        /// A valid, in-identity, non-exhausted lock fatal → retry with this
        /// (decremented) lease.
        case retry(ScanInterruptRetryLease)
        /// A duplicate / late / superseded fatal arriving while a retry reopen
        /// is already pending → acknowledge silently (no modal, no new retry).
        case suppress
        /// Not ours (an unrelated / legit lock, or the budget is exhausted with
        /// no reopen pending) → let the normal fatal modal handle it.
        case passThrough
    }

    /// Decide a lock fatal. `session`/`op` are the reconnect operation currently
    /// in flight at fatal time (the driver's pending scan), or `nil` in the brief
    /// gap between an accepted retry and the reopened scan (pendingScan already
    /// consumed). Pure + total.
    static func decideLockFatal(lease: ScanInterruptRetryLease?,
                                retryInFlight: Bool,
                                profile: String?,
                                session: EngineSessionCoordinator.SessionID?,
                                op: EngineSessionCoordinator.OperationID?) -> Decision {
        if let lease, let profile, let session, let op,
           lease.accepts(profile: profile, session: session, op: op) {
            return .retry(lease.decremented())
        }
        // No matching authority. A retry reopen is in flight but the new scan
        // hasn't re-established its identity yet (no pending op) → this is a
        // duplicate/late straggler for the just-consumed transport → ack it
        // silently. Every other no-authority case — a real pending scan with an
        // exhausted budget, a wrong-profile/wrong-op fatal, or an unrelated legit
        // lock — surfaces the honest modal.
        if retryInFlight, session == nil || op == nil {
            return .suppress
        }
        return .passThrough
    }
}
