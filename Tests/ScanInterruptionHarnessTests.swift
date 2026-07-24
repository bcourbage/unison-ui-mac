#if DEBUG
import XCTest
@testable import unison_ui_mac

/// Deterministic coverage for the Phase 0 scan-interruption harness state
/// machine (§7) INCLUDING the full close→reopen lifecycle. Clock-free and
/// effect-free, so every scenario — including the driver-wiring contracts the
/// reviewer asked to prove — is exercised without a live transport or run loop.
final class ScanInterruptionHarnessTests: XCTestCase {

    private typealias SID = EngineSessionCoordinator.SessionID
    private typealias OID = EngineSessionCoordinator.OperationID
    private typealias H = ScanInterruptionHarness

    private func binding(session: UInt64 = 1, op: UInt64 = 1, pid: Int32 = 4242,
                         armedAt: UInt64 = 0) -> H.Binding {
        .init(session: SID(raw: session), op: OID(raw: op),
              pid: pid, startSec: 100, startUsec: 200, armedAt: armedAt)
    }

    /// Drive to `.closing` (armed → fatal terminal → reap proceed).
    private func closing() -> H {
        let h = H()
        h.arm(binding())
        _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1), at: 10)
        XCTAssertEqual(h.resolveReap(UNISON_REAP_ABSENT), .proceed)
        return h
    }

    // MARK: - Arm / busy guard (correction #5)

    func test_arm_fromIdle_arms_andCanArm() {
        let h = H()
        XCTAssertTrue(h.canArm)
        XCTAssertEqual(h.arm(binding()), .armed)
        XCTAssertFalse(h.canArm)                 // busy after arm
    }

    func test_busyHarness_refusesArm_andReportsNotArmable() {
        let h = H()
        h.arm(binding())
        // Every in-flight state reports canArm == false → driver issues NO signal.
        XCTAssertFalse(h.canArm)
        XCTAssertEqual(h.arm(binding(session: 2, op: 2)), .refusedBusy)
        _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1))
        XCTAssertFalse(h.canArm)                 // awaitingReap
        _ = h.resolveReap(UNISON_REAP_ABSENT)
        XCTAssertFalse(h.canArm)                 // closing
    }

    // MARK: - Matching / mismatched fatal

    func test_fatal_matching_interceptsOnce_thenDuplicate() {
        let h = H()
        h.arm(binding())
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)), .interceptAcknowledge)
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)), .duplicateIgnore)
    }

    func test_fatal_wrongOp_passesThrough_andDoesNotConsumeTerminal() {
        let h = H()
        h.arm(binding(session: 7, op: 9))
        XCTAssertEqual(h.observeFatal(session: SID(raw: 7), op: OID(raw: 10)), .passThroughToModal)
        XCTAssertEqual(h.observeFatal(session: SID(raw: 7), op: OID(raw: 9)), .interceptAcknowledge)
    }

    func test_fatal_whenIdle_passesThrough() {
        XCTAssertEqual(H().observeFatal(session: SID(raw: 1), op: OID(raw: 1)), .passThroughToModal)
    }

    // MARK: - init2-complete / scan-failed races terminate exactly once

    func test_scanTerminal_acceptedOnce_thenDuplicate() {
        let h = H()
        h.arm(binding())
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)), .accepted)
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)), .duplicate)
    }

    func test_mixedTerminals_fatalThenScan_secondIsDuplicate() {
        let h = H()
        h.arm(binding())
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)), .interceptAcknowledge)
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)), .duplicate)
    }

    func test_mixedTerminals_scanThenFatal_secondIsDuplicate() {
        let h = H()
        h.arm(binding())
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)), .accepted)
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)), .duplicateIgnore)
    }

    // MARK: - scan-completes-before-arm race

    func test_scanTerminal_whenIdle_isUnrelated() {
        let h = H()
        XCTAssertEqual(h.observeScanTerminal(session: SID(raw: 1), op: OID(raw: 1)), .unrelated)
        XCTAssertEqual(h.state, .idle)
    }

    // MARK: - Timer precedence

    func test_stallTimerDefers_onlyForArmedOp() {
        let h = H()
        h.arm(binding(session: 3, op: 4))
        XCTAssertTrue(h.stallTimerShouldDefer(session: SID(raw: 3), op: OID(raw: 4)))
        XCTAssertFalse(h.stallTimerShouldDefer(session: SID(raw: 3), op: OID(raw: 5)))
        XCTAssertFalse(h.stallTimerShouldDefer(session: SID(raw: 9), op: OID(raw: 4)))
        XCTAssertFalse(H().stallTimerShouldDefer(session: SID(raw: 3), op: OID(raw: 4)))
    }

    // MARK: - Reap polling contract (correction #3)

    func test_pollContract_absentAndReused_resolveImmediately() {
        XCTAssertFalse(H.shouldKeepPolling(UNISON_REAP_ABSENT, elapsed: 0, grace: 2))
        XCTAssertFalse(H.shouldKeepPolling(UNISON_REAP_REUSED, elapsed: 0, grace: 2))
    }

    func test_pollContract_liveZombieUnknown_keepPollingUntilGrace() {
        for st in [UNISON_REAP_LIVE, UNISON_REAP_ZOMBIE, UNISON_REAP_UNKNOWN] {
            XCTAssertTrue(H.shouldKeepPolling(st, elapsed: 0.5, grace: 2),
                          "\(st.rawValue) must keep polling before grace")
            XCTAssertFalse(H.shouldKeepPolling(st, elapsed: 2.0, grace: 2),
                           "\(st.rawValue) must resolve at/after grace")
        }
    }

    // MARK: - Reap resolution

    func test_reap_absentOrReused_proceedToClosing() {
        for st in [UNISON_REAP_ABSENT, UNISON_REAP_REUSED] {
            let h = H(); h.arm(binding())
            _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1))
            XCTAssertEqual(h.resolveReap(st), .proceed)
            XCTAssertEqual(h.state, .closing(binding()))
        }
    }

    func test_reap_zombieLiveUnknown_quarantine() {
        for st in [UNISON_REAP_ZOMBIE, UNISON_REAP_LIVE, UNISON_REAP_UNKNOWN] {
            let h = H(); h.arm(binding())
            _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1))
            XCTAssertEqual(h.resolveReap(st), .quarantine)
            XCTAssertTrue(h.isQuarantined)
            XCTAssertFalse(h.reopenAllowed)
        }
    }

    // MARK: - Close → reopen lifecycle (corrections #1, #4)

    func test_closeStatusNonZero_neverReachesDone_quarantines() {
        let h = closing()
        XCTAssertEqual(h.noteCloseCompleted(status: 2), .quarantine)
        XCTAssertNotEqual(h.state, .done)
        XCTAssertTrue(h.isQuarantined)
        // A later replacement completion cannot revive it.
        XCTAssertEqual(h.noteReplacementScanComplete(session: SID(raw: 5), op: OID(raw: 5)), .ignore)
        XCTAssertTrue(h.isQuarantined)
    }

    func test_done_onlyAfterReplacementScanComplete() {
        let h = closing()
        XCTAssertEqual(h.noteCloseCompleted(status: 0), .proceedReopen)
        XCTAssertNotEqual(h.state, .done)              // reopening, NOT done yet
        h.noteReplacementOpen(session: SID(raw: 2), op: OID(raw: 2))
        XCTAssertNotEqual(h.state, .done)              // replacement not yet complete
        XCTAssertEqual(
            h.noteReplacementScanComplete(session: SID(raw: 2), op: OID(raw: 2)), .completed)
        XCTAssertEqual(h.state, .done)
        XCTAssertTrue(h.canArm)                        // ready for the next cycle
    }

    func test_replacementCompletion_wrongIdentity_isIgnored() {
        let h = closing()
        _ = h.noteCloseCompleted(status: 0)
        h.noteReplacementOpen(session: SID(raw: 2), op: OID(raw: 2))
        XCTAssertEqual(
            h.noteReplacementScanComplete(session: SID(raw: 9), op: OID(raw: 9)), .ignore)
        XCTAssertNotEqual(h.state, .done)              // still reopening
    }

    func test_replacementConnectTimeout_quarantines() {
        let h = closing()
        _ = h.noteCloseCompleted(status: 0)            // reopening
        XCTAssertTrue(h.deadlineElapsed())             // replacement never scanned
        XCTAssertTrue(h.isQuarantined)
    }

    // MARK: - Replacement-op fatal is NOT swallowed (correction #6)

    func test_fatal_duringClosing_passesThrough() {
        let h = closing()
        XCTAssertEqual(h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)), .passThroughToModal)
    }

    func test_fatal_duringReopening_passesThrough() {
        let h = closing()
        _ = h.noteCloseCompleted(status: 0)
        h.noteReplacementOpen(session: SID(raw: 2), op: OID(raw: 2))
        // Even a fatal naming the replacement op is not swallowed here.
        XCTAssertEqual(h.observeFatal(session: SID(raw: 2), op: OID(raw: 2)), .passThroughToModal)
    }

    // MARK: - Deadline / quarantine / reopen refusal

    func test_deadline_whileAwaitingTerminal_quarantines() {
        let h = H(); h.arm(binding())
        XCTAssertTrue(h.deadlineElapsed())
        XCTAssertTrue(h.isQuarantined)
        XCTAssertFalse(h.reopenAllowed)
    }

    func test_deadline_afterDone_isNoOp() {
        let h = closing()
        _ = h.noteCloseCompleted(status: 0)
        h.noteReplacementOpen(session: SID(raw: 2), op: OID(raw: 2))
        _ = h.noteReplacementScanComplete(session: SID(raw: 2), op: OID(raw: 2))
        XCTAssertEqual(h.state, .done)
        XCTAssertFalse(h.deadlineElapsed())            // done is terminal
    }

    func test_quarantine_refusesReopenAndArm_untilReset() {
        let h = H(); h.arm(binding()); h.deadlineElapsed()
        XCTAssertFalse(h.reopenAllowed)
        XCTAssertFalse(h.canArm)
        XCTAssertEqual(h.arm(binding(session: 2, op: 2)), .refusedBusy)
        h.reset()
        XCTAssertEqual(h.state, .idle)
        XCTAssertEqual(h.arm(binding(session: 2, op: 2)), .armed)
    }

    func test_cleanupFailure_duringReopening_quarantines() {
        let h = closing()
        _ = h.noteCloseCompleted(status: 0)
        h.noteCleanupFailure(reason: "verification threw")
        XCTAssertTrue(h.isQuarantined)
    }
}
#endif
