#if DEBUG
import Foundation

/// Phase 0 scan-interruption spike (issue #24 follow-up), §7 of
/// docs/scan-interruption-design.md.
///
/// Pure state machine for the Debug-only "expected scan interruption" harness.
/// It models the WHOLE cycle — original-scan terminal → reap → coordinator
/// close (status 0) → replacement open → replacement scan completion — and only
/// then reaches `.done`. Every failure (deadline, ambiguous reap, non-zero
/// close, replacement failure, cleanup failure) funnels to a one-way
/// `quarantined` state. Clock-free and effect-free, so all decisions are
/// deterministically testable; the AppDelegate glue performs the effects and
/// feeds lifecycle events back in.
///
/// The whole type is `#if DEBUG`, so it and its hooks are absent from Release.
///
/// Key invariants (verified by tests):
/// - Exactly one terminal is recorded per cycle; later matching terminals are
///   duplicates (no modal, no re-record, no second drive).
/// - The coordinator close is only *requested* after a matching terminal AND a
///   confirmed reap (`awaitingReap` → `closing`); close/drain never precedes the
///   terminal.
/// - `.done` is reached ONLY after a status-0 close AND a completed replacement
///   scan (`reopening` → `done`) — never at reopen-request time.
/// - Once close/reopen begins (`closing`/`reopening`), a fatal is NOT swallowed
///   as a duplicate: it follows normal production routing (it may belong to the
///   replacement op).
/// - `arm` is refused unless idle/done, so a busy harness never signals a child.
final class ScanInterruptionHarness {

    typealias SessionID = EngineSessionCoordinator.SessionID
    typealias OperationID = EngineSessionCoordinator.OperationID

    struct Binding: Equatable {
        let session: SessionID
        let op: OperationID
        let pid: Int32
        let startSec: Int64
        let startUsec: Int32
        let armedAt: UInt64          // injected monotonic timestamp (latency)
    }

    struct ReplacementID: Equatable {
        let session: SessionID
        let op: OperationID
    }

    enum State: Equatable {
        case idle
        case awaitingTerminal(Binding)
        case awaitingReap(Binding, terminalAt: UInt64)
        /// Reap confirmed; the exact op was reported `operationFailed(quiescent:
        /// true)` and a reopen requested. Awaiting the close's status.
        case closing(Binding)
        /// Close returned status 0; awaiting the replacement scan to complete.
        case reopening(Binding, replacement: ReplacementID?)
        case quarantined(reason: String)
        case done
    }

    private(set) var state: State = .idle

    // MARK: - Arm

    enum ArmResult: Equatable { case armed, refusedBusy }

    /// True only when a new cycle may start. The driver MUST check this before
    /// invoking the C signal primitive so a busy harness never signals a child.
    var canArm: Bool {
        switch state {
        case .idle, .done: return true
        default:           return false
        }
    }

    @discardableResult
    func arm(_ binding: Binding) -> ArmResult {
        guard canArm else { return .refusedBusy }
        state = .awaitingTerminal(binding)
        return .armed
    }

    // MARK: - Original-scan terminal

    enum FatalDecision: Equatable {
        case interceptAcknowledge   // first matching fatal → ack worker, no modal
        case duplicateIgnore        // matching, terminal already recorded, pre-reopen → swallow
        case passThroughToModal     // unrelated / not armed / reopen underway → normal modal
    }

    func observeFatal(session: SessionID, op: OperationID,
                      at now: UInt64 = 0) -> FatalDecision {
        switch state {
        case .awaitingTerminal(let b) where b.session == session && b.op == op:
            state = .awaitingReap(b, terminalAt: now)
            return .interceptAcknowledge
        case .awaitingReap(let b, _) where b.session == session && b.op == op:
            // Terminal recorded, but the replacement op has NOT begun yet — a
            // late duplicate of the original fatal. Swallow (no modal).
            return .duplicateIgnore
        default:
            // Includes closing/reopening: once close/reopen is underway an
            // unattributed fatal may belong to the replacement op, so it must
            // get normal routing (never swallowed).
            return .passThroughToModal
        }
    }

    enum TerminalDecision: Equatable { case accepted, duplicate, unrelated }

    /// Async worker terminal for the ORIGINAL op (init2-complete / scan-failed).
    func observeScanTerminal(session: SessionID, op: OperationID,
                             at now: UInt64 = 0) -> TerminalDecision {
        switch state {
        case .awaitingTerminal(let b) where b.session == session && b.op == op:
            state = .awaitingReap(b, terminalAt: now)
            return .accepted
        case .awaitingReap(let b, _) where b.session == session && b.op == op:
            return .duplicate
        default:
            return .unrelated
        }
    }

    // MARK: - Deadline (covers every non-terminal in-flight phase)

    @discardableResult
    func deadlineElapsed() -> Bool {
        switch state {
        case .awaitingTerminal, .awaitingReap, .closing, .reopening:
            state = .quarantined(reason: "scan-interrupt phase exceeded its deadline")
            return true
        default:
            return false
        }
    }

    // MARK: - Reap resolution

    /// Poll decision (§8, correction #3): ABSENT/REUSED resolve immediately as
    /// success; LIVE/ZOMBIE/UNKNOWN keep polling until the grace deadline, then
    /// resolve (→ quarantine). Pure so the polling contract is testable without
    /// the driver's async loop.
    static func shouldKeepPolling(_ reap: unison_reap_state_t,
                                  elapsed: TimeInterval, grace: TimeInterval) -> Bool {
        if reap == UNISON_REAP_ABSENT || reap == UNISON_REAP_REUSED { return false }
        return elapsed < grace
    }

    enum ReapDecision: Equatable { case proceed, quarantine }

    /// Resolve the (polled) reap classification. Only valid in `awaitingReap`.
    @discardableResult
    func resolveReap(_ reap: unison_reap_state_t) -> ReapDecision {
        guard case .awaitingReap(let b, _) = state else {
            state = .quarantined(reason: "reap resolved outside awaitingReap")
            return .quarantine
        }
        switch reap {
        case UNISON_REAP_ABSENT, UNISON_REAP_REUSED:
            state = .closing(b)
            return .proceed
        default: // ZOMBIE / LIVE / UNKNOWN
            state = .quarantined(reason: "ambiguous reap state (\(reap.rawValue))")
            return .quarantine
        }
    }

    // MARK: - Close / reopen lifecycle

    enum CloseDecision: Equatable { case proceedReopen, quarantine }

    /// The coordinator close completed. Only valid in `closing`. Status 0 →
    /// `reopening`; any non-zero close is unsafe → quarantine.
    @discardableResult
    func noteCloseCompleted(status: Int32) -> CloseDecision {
        guard case .closing(let b) = state else { return .quarantine }
        if status == 0 {
            state = .reopening(b, replacement: nil)
            return .proceedReopen
        }
        state = .quarantined(reason: "connection close failed (status \(status))")
        return .quarantine
    }

    /// Record the replacement session/op once it opens. Only valid in
    /// `reopening` before a replacement is recorded.
    func noteReplacementOpen(session: SessionID, op: OperationID) {
        if case .reopening(let b, nil) = state {
            state = .reopening(b, replacement: ReplacementID(session: session, op: op))
        }
    }

    enum ReplacementDecision: Equatable { case completed, ignore }

    /// The replacement scan completed SUCCESSFULLY. Only reaches `.done` when it
    /// matches the recorded replacement identity (completion + verification).
    /// Anything else is ignored (stale / not-yet-recorded).
    @discardableResult
    func noteReplacementScanComplete(session: SessionID, op: OperationID) -> ReplacementDecision {
        if case .reopening(_, let r?) = state, r.session == session, r.op == op {
            state = .done
            return .completed
        }
        return .ignore
    }

    enum ReplacementFailureDecision: Equatable { case quarantined, ignore }

    /// The replacement scan FAILED (scan-failed callback / fatal). A matching
    /// replacement failure is NOT success — it quarantines so the cycle never
    /// falsely reports `.done`. (Blocker 3.)
    @discardableResult
    func noteReplacementScanFailed(session: SessionID, op: OperationID) -> ReplacementFailureDecision {
        if case .reopening(_, let r?) = state, r.session == session, r.op == op {
            state = .quarantined(reason: "replacement scan failed")
            return .quarantined
        }
        return .ignore
    }

    /// The coordinator entered `.restartRequired` during the cycle (a non-zero
    /// close, a replacement init1/connect/scan failure, or a replacement fatal
    /// routed through normal handling). Quarantine so the outcome is never
    /// mistaken for success. No-op once idle/done/quarantined.
    func noteCoordinatorRestart() {
        switch state {
        case .awaitingTerminal, .awaitingReap, .closing, .reopening:
            state = .quarantined(reason: "coordinator entered restart-required during the cycle")
        default:
            break
        }
    }

    /// Verification or an effect failed during close/reopen.
    func noteCleanupFailure(reason: String) {
        switch state {
        case .closing, .reopening, .awaitingReap:
            state = .quarantined(reason: "cleanup failed: \(reason)")
        default:
            break
        }
    }

    // MARK: - Queries

    var armedBinding: Binding? {
        switch state {
        case .awaitingTerminal(let b), .awaitingReap(let b, _),
             .closing(let b), .reopening(let b, _):
            return b
        default:
            return nil
        }
    }

    /// True while a racing scan-stall timer for `(session, op)` must defer to
    /// the harness (exactly one terminal authority for the armed op).
    func stallTimerShouldDefer(session: SessionID, op: OperationID) -> Bool {
        guard let b = armedBinding else { return false }
        return b.session == session && b.op == op
    }

    /// True once the close/reopen phase has begun — the interceptor uses this to
    /// stop swallowing fatals as duplicates.
    var replacementUnderway: Bool {
        switch state {
        case .closing, .reopening: return true
        default:                   return false
        }
    }

    var isReopening: Bool {
        if case .reopening = state { return true }
        return false
    }

    var reopenAllowed: Bool {
        if case .quarantined = state { return false }
        return true
    }

    var isQuarantined: Bool {
        if case .quarantined = state { return true }
        return false
    }

    /// Clear for the next cycle. The only exit from `quarantined`.
    func reset() { state = .idle }
}
#endif
