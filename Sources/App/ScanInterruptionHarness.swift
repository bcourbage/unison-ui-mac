#if DEBUG
import Foundation

/// Phase 0 scan-interruption spike (issue #24 follow-up), §7 of
/// docs/scan-interruption-design.md.
///
/// Pure state machine for the Debug-only "expected scan interruption" harness.
/// It encodes every decision the design requires; the AppDelegate glue is thin
/// and just performs the effects (SIGKILL via the C primitive, ack the worker,
/// poll reap, drive close/drain/reopen). Keeping the decisions here — clock-free
/// and effect-free — makes them deterministically testable without a live ssh
/// transport or an AppKit run loop (same posture as `EngineSessionCoordinator`
/// and `DiffRequestBroker`).
///
/// The whole type is `#if DEBUG`, so it and its hooks are absent from Release.
///
/// Invariants enforced here:
/// - A terminal is recorded **exactly once** per armed cycle; later matching
///   fatals/terminals are swallowed as duplicates (never a second record, never
///   a modal).
/// - Close/drain is only *reachable* after a matching worker terminal
///   (`awaitingReap` → `closingReopen`); it is never authorized from
///   `awaitingTerminal`.
/// - Deadline, ambiguous reap, duplicate/mismatched terminal at the wrong time,
///   and cleanup failure all funnel to `quarantined`, which is one-way: reopen
///   is refused and the picker is never presented as if quiescence were proven.
/// - Timestamps are injected by the caller (monotonic on the real path) so
///   latency is recorded without the state machine reading a clock.
final class ScanInterruptionHarness {

    typealias SessionID = EngineSessionCoordinator.SessionID
    typealias OperationID = EngineSessionCoordinator.OperationID

    /// Exact identity the interruption is bound to. PID + start identity are the
    /// reap-classification key; session + op match the worker terminal.
    struct Binding: Equatable {
        let session: SessionID
        let op: OperationID
        let pid: Int32
        let startSec: Int64
        let startUsec: Int32
        /// Injected monotonic timestamp at arm time (for latency accounting).
        let armedAt: UInt64
    }

    enum State: Equatable {
        case idle
        /// Child signalled; waiting for the matching worker terminal, bounded by
        /// the caller's deadline.
        case awaitingTerminal(Binding)
        /// Terminal recorded; caller is polling reap classification.
        case awaitingReap(Binding, terminalAt: UInt64)
        /// Reap confirmed; caller is verifying + close/drain + reopen.
        case closingReopen(Binding)
        /// One-way failure: reopen refused, quiescence never claimed.
        case quarantined(reason: String)
        /// A cycle completed cleanly; ready to arm the next one.
        case done
    }

    private(set) var state: State = .idle

    // MARK: - Arm

    enum ArmResult: Equatable {
        case armed
        /// Not idle/done — a cycle is already in flight or quarantined.
        case refusedBusy
    }

    /// Arm for a freshly-signalled child. Only valid from `idle`/`done`; a
    /// quarantined or in-flight harness refuses (the caller must `reset()` a
    /// quarantine explicitly for the next cycle).
    @discardableResult
    func arm(_ binding: Binding) -> ArmResult {
        switch state {
        case .idle, .done:
            state = .awaitingTerminal(binding)
            return .armed
        default:
            return .refusedBusy
        }
    }

    // MARK: - Terminal observation

    /// Decision for a fatal delivered through the bridge trampoline.
    enum FatalDecision: Equatable {
        /// Matching expected fatal, first one: caller acks the worker WITHOUT a
        /// modal and the terminal is now recorded.
        case interceptAcknowledge
        /// Matching, but a terminal was already recorded: swallow it (still no
        /// modal) without double-recording.
        case duplicateIgnore
        /// Not armed, or session/op does not match: normal production modal.
        case passThroughToModal
    }

    /// Observe a fatal for `(session, op)`. Only the exact armed identity is
    /// intercepted; everything else passes through to the production modal.
    func observeFatal(session: SessionID, op: OperationID,
                      at now: UInt64 = 0) -> FatalDecision {
        switch state {
        case .awaitingTerminal(let b) where b.session == session && b.op == op:
            state = .awaitingReap(b, terminalAt: now)
            return .interceptAcknowledge
        case .awaitingReap(let b, _) where b.session == session && b.op == op,
             .closingReopen(let b) where b.session == session && b.op == op:
            // Terminal already recorded for this binding — a late/duplicate
            // fatal for the same op. Swallow (no modal, no re-record).
            return .duplicateIgnore
        default:
            return .passThroughToModal
        }
    }

    /// Decision for a non-fatal async terminal (e.g. the scan-failed / init2
    /// completion callback) matching the binding.
    enum TerminalDecision: Equatable {
        case accepted        // first matching terminal → recorded
        case duplicate       // terminal already recorded for this binding
        case unrelated       // not armed / mismatched op → ignore
    }

    /// Observe an async worker terminal for `(session, op)`.
    func observeScanTerminal(session: SessionID, op: OperationID,
                             at now: UInt64 = 0) -> TerminalDecision {
        switch state {
        case .awaitingTerminal(let b) where b.session == session && b.op == op:
            state = .awaitingReap(b, terminalAt: now)
            return .accepted
        case .awaitingReap(let b, _) where b.session == session && b.op == op,
             .closingReopen(let b) where b.session == session && b.op == op:
            return .duplicate
        default:
            return .unrelated
        }
    }

    // MARK: - Deadline

    /// The caller's terminal-wait deadline elapsed. Only meaningful while still
    /// `awaitingTerminal`: tips into quarantine. A no-op (returns false) once a
    /// terminal has arrived or the harness is otherwise not waiting.
    @discardableResult
    func deadlineElapsed() -> Bool {
        if case .awaitingTerminal = state {
            state = .quarantined(reason: "no worker terminal within the deadline")
            return true
        }
        return false
    }

    // MARK: - Reap resolution

    enum ReapDecision: Equatable {
        case proceed       // reaped (or pid reused) → safe to verify + close/reopen
        case quarantine    // zombie / live / unknown → ambiguous, refuse reopen
    }

    /// Resolve the (already-polled) final reap classification. Only valid while
    /// `awaitingReap`; any other state is a programming error and quarantines
    /// defensively.
    @discardableResult
    func resolveReap(_ reap: unison_reap_state_t) -> ReapDecision {
        guard case .awaitingReap(let b, _) = state else {
            state = .quarantined(reason: "reap resolved outside awaitingReap")
            return .quarantine
        }
        switch reap {
        case UNISON_REAP_ABSENT, UNISON_REAP_REUSED:
            state = .closingReopen(b)
            return .proceed
        default: // ZOMBIE / LIVE / UNKNOWN
            state = .quarantined(reason: "ambiguous reap state (\(reap.rawValue))")
            return .quarantine
        }
    }

    // MARK: - Cleanup / completion

    /// Verification or close/drain failed during `closingReopen`.
    func noteCleanupFailure(reason: String) {
        if case .closingReopen = state {
            state = .quarantined(reason: "cleanup failed: \(reason)")
        }
    }

    /// The verified close/drain + reopen completed successfully.
    func noteReopenComplete() {
        if case .closingReopen = state { state = .done }
    }

    // MARK: - Queries

    /// The binding currently armed/in-flight, if any. The caller uses `.op` to
    /// disarm ONLY the matching scan-stall timer (never a different op's).
    var armedBinding: Binding? {
        switch state {
        case .awaitingTerminal(let b), .awaitingReap(let b, _), .closingReopen(let b):
            return b
        default:
            return nil
        }
    }

    /// True when a racing scan-stall timer for `(session, op)` must defer to the
    /// harness (the harness owns the terminal decision for the armed op, so the
    /// stall timer must not also fire one — "exactly one terminal authority").
    func stallTimerShouldDefer(session: SessionID, op: OperationID) -> Bool {
        guard let b = armedBinding else { return false }
        return b.session == session && b.op == op
    }

    /// Reopen is allowed unless we are quarantined. (In `closingReopen` the
    /// caller is *performing* the reopen; a fresh open is only gated by the
    /// coordinator, which already refuses in `.restartRequired`.)
    var reopenAllowed: Bool {
        if case .quarantined = state { return false }
        return true
    }

    var isQuarantined: Bool {
        if case .quarantined = state { return true }
        return false
    }

    /// Clear the harness for the next spike cycle. The only exit from
    /// `quarantined` (a deliberate, explicit reset — quarantine is one-way for
    /// the cycle it ends).
    func reset() { state = .idle }
}
#endif
