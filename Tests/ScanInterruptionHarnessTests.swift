#if DEBUG
import XCTest
@testable import unison_ui_mac

/// Deterministic coverage for the Phase 0 scan-interruption harness state
/// machine (§7). Clock-free and effect-free, so every listed scenario is
/// exercised without a live ssh transport or run loop.
final class ScanInterruptionHarnessTests: XCTestCase {

    private typealias SID = EngineSessionCoordinator.SessionID
    private typealias OID = EngineSessionCoordinator.OperationID

    private func binding(session: UInt64 = 1, op: UInt64 = 1, pid: Int32 = 4242,
                         armedAt: UInt64 = 0) -> ScanInterruptionHarness.Binding {
        .init(session: SID(raw: session), op: OID(raw: op),
              pid: pid, startSec: 100, startUsec: 200, armedAt: armedAt)
    }

    // MARK: - Arm

    func test_arm_fromIdle_arms() {
        let h = ScanInterruptionHarness()
        XCTAssertEqual(h.arm(binding()), .armed)
        XCTAssertEqual(h.armedBinding, binding())
    }

    func test_arm_whileInFlight_refusesBusy() {
        let h = ScanInterruptionHarness()
        h.arm(binding())
        XCTAssertEqual(h.arm(binding(session: 2, op: 2)), .refusedBusy)
        // Original binding is untouched.
        XCTAssertEqual(h.armedBinding?.session, SID(raw: 1))
    }

    // MARK: - Matching / mismatched fatal

    func test_fatal_matching_interceptsAndAcknowledges() {
        let h = ScanInterruptionHarness()
        h.arm(binding(session: 7, op: 9))
        XCTAssertEqual(h.observeFatal(session: SID(raw: 7), op: OID(raw: 9), at: 500),
                       .interceptAcknowledge)
    }

    func test_fatal_wrongOp_passesThroughToModal() {
        let h = ScanInterruptionHarness()
        h.arm(binding(session: 7, op: 9))
        XCTAssertEqual(h.observeFatal(session: SID(raw: 7), op: OID(raw: 10)),
                       .passThroughToModal)
        // A mismatched fatal must NOT consume the pending terminal.
        XCTAssertEqual(h.observeFatal(session: SID(raw: 7), op: OID(raw: 9)),
                       .interceptAcknowledge)
    }

    func test_fatal_whenIdle_passesThroughToModal() {
        let h = ScanInterruptionHarness()
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)),
                       .passThroughToModal)
    }

    // MARK: - Duplicate terminal delivery

    func test_duplicateFatal_afterTerminal_isSwallowed() {
        let h = ScanInterruptionHarness()
        h.arm(binding())
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)),
                       .interceptAcknowledge)
        // Second matching fatal: swallowed, no modal, no re-record.
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)),
                       .duplicateIgnore)
    }

    func test_duplicateScanTerminal_afterTerminal_isDuplicate() {
        let h = ScanInterruptionHarness()
        h.arm(binding())
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)),
                       .accepted)
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)),
                       .duplicate)
    }

    func test_mixedTerminals_secondKindIsDuplicate() {
        // scan-terminal first, then a late fatal for the same op → duplicate.
        let h = ScanInterruptionHarness()
        h.arm(binding())
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)),
                       .accepted)
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)),
                       .duplicateIgnore)
    }

    // MARK: - Scan-completes-before-signal race

    func test_scanTerminal_whenIdle_isUnrelated() {
        // The scan completed before we armed — nothing to intercept.
        let h = ScanInterruptionHarness()
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)),
                       .unrelated)
        XCTAssertEqual(h.state, .idle)
    }

    // MARK: - Timer precedence (disarm only the matching timer)

    func test_stallTimerDefers_onlyForArmedOp() {
        let h = ScanInterruptionHarness()
        h.arm(binding(session: 3, op: 4))
        XCTAssertTrue(h.stallTimerShouldDefer(session: SID(raw: 3), op: OID(raw: 4)))
        XCTAssertFalse(h.stallTimerShouldDefer(session: SID(raw: 3), op: OID(raw: 5)))
        XCTAssertFalse(h.stallTimerShouldDefer(session: SID(raw: 9), op: OID(raw: 4)))
    }

    func test_stallTimerDoesNotDefer_whenIdle() {
        let h = ScanInterruptionHarness()
        XCTAssertFalse(h.stallTimerShouldDefer(session: SID(raw: 1), op: OID(raw: 1)))
    }

    // MARK: - Deadline / quarantine

    func test_deadline_whileAwaitingTerminal_quarantines() {
        let h = ScanInterruptionHarness()
        h.arm(binding())
        XCTAssertTrue(h.deadlineElapsed())
        XCTAssertTrue(h.isQuarantined)
        XCTAssertFalse(h.reopenAllowed)
    }

    func test_deadline_afterTerminal_isNoOp() {
        let h = ScanInterruptionHarness()
        h.arm(binding())
        _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1))
        XCTAssertFalse(h.deadlineElapsed())          // terminal already arrived
        XCTAssertFalse(h.isQuarantined)
    }

    // MARK: - Reap polling outcomes

    func test_reap_absent_proceeds() {
        let h = armedThenTerminal()
        XCTAssertEqual(h.resolveReap(UNISON_REAP_ABSENT), .proceed)
        XCTAssertEqual(h.state, .closingReopen(binding()))
    }

    func test_reap_reused_proceeds() {
        let h = armedThenTerminal()
        XCTAssertEqual(h.resolveReap(UNISON_REAP_REUSED), .proceed)
    }

    func test_reap_zombie_quarantines() {
        let h = armedThenTerminal()
        XCTAssertEqual(h.resolveReap(UNISON_REAP_ZOMBIE), .quarantine)
        XCTAssertFalse(h.reopenAllowed)
    }

    func test_reap_live_quarantines() {
        let h = armedThenTerminal()
        XCTAssertEqual(h.resolveReap(UNISON_REAP_LIVE), .quarantine)
    }

    func test_reap_unknown_quarantines() {
        let h = armedThenTerminal()
        XCTAssertEqual(h.resolveReap(UNISON_REAP_UNKNOWN), .quarantine)
    }

    func test_reap_resolvedOutsideAwaitingReap_quarantinesDefensively() {
        let h = ScanInterruptionHarness()   // idle
        XCTAssertEqual(h.resolveReap(UNISON_REAP_ABSENT), .quarantine)
    }

    // MARK: - Cleanup failure

    func test_cleanupFailure_duringCloseReopen_quarantines() {
        let h = armedThenTerminal()
        _ = h.resolveReap(UNISON_REAP_ABSENT)        // → closingReopen
        h.noteCleanupFailure(reason: "drain threw")
        XCTAssertTrue(h.isQuarantined)
        XCTAssertFalse(h.reopenAllowed)
    }

    // MARK: - Happy path + reopen refusal + next cycle

    func test_happyPath_reopenComplete_reachesDone() {
        let h = armedThenTerminal()
        _ = h.resolveReap(UNISON_REAP_ABSENT)
        h.noteReopenComplete()
        XCTAssertEqual(h.state, .done)
        XCTAssertTrue(h.reopenAllowed)
        // done allows arming the next cycle.
        XCTAssertEqual(h.arm(binding(session: 2, op: 2)), .armed)
    }

    func test_quarantine_refusesReopenAndArm_untilReset() {
        let h = ScanInterruptionHarness()
        h.arm(binding())
        h.deadlineElapsed()                          // → quarantined
        XCTAssertFalse(h.reopenAllowed)
        XCTAssertEqual(h.arm(binding(session: 2, op: 2)), .refusedBusy)
        h.reset()
        XCTAssertEqual(h.state, .idle)
        XCTAssertEqual(h.arm(binding(session: 2, op: 2)), .armed)
    }

    // MARK: - helper

    private func armedThenTerminal() -> ScanInterruptionHarness {
        let h = ScanInterruptionHarness()
        h.arm(binding())
        _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1), at: 42)
        return h
    }
}
#endif
