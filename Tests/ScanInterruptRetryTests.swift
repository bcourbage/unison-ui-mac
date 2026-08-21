import XCTest
@testable import unison_ui_mac

/// Round-4: the post-interruption lock-retry authority is an IDENTITY-BOUND
/// lease, so a leaked/stale lease can never authorize a retry for a different
/// profile / replacement session / superseded operation. These prove the
/// accept/reject decision for duplicate, stale, wrong-profile, wrong-operation,
/// wrong-session, and exhausted cases, plus the bounded retry chain.
///
/// Driver-integration properties (verified by the AppDelegate wiring +
/// live-demo, not re-unit-tested here because they need an AppKit/bridge
/// harness): the lease is cleared/cancelled on return-to-picker
/// (driveCloseInterruptWindow), restart-required (driveRestartRequired — the
/// close-failure path), ordinary leave, scan success, and shutdown; the
/// deferred reopen is a retained DispatchWorkItem cancelled by that clear
/// (delayed-work cancellation); and the retry fails the op + consumes
/// `pendingScan` synchronously so a racing scan-failed for the same op is
/// dropped (scan-failed/init2 race — the coordinator's exact-token rejection is
/// covered in the Foundation suite).
final class ScanInterruptRetryTests: XCTestCase {

    private typealias Lease = ScanInterruptRetryLease
    private typealias Policy = ScanInterruptRetryPolicy
    private typealias SID = EngineSessionCoordinator.SessionID
    private typealias OID = EngineSessionCoordinator.OperationID

    private let sA = SID(raw: 1), sB = SID(raw: 2)
    private let oA = OID(raw: 10), oB = OID(raw: 20)

    private func lease(_ profile: String = "P", _ s: SID? = nil, _ o: OID? = nil,
                       retries: Int = 3) -> Lease {
        Lease(profile: profile, session: s ?? sA, op: o ?? oA, retriesLeft: retries)
    }

    // MARK: - accepts()

    func test_accepts_exactIdentity() {
        XCTAssertTrue(lease().accepts(profile: "P", session: sA, op: oA))
    }
    func test_accepts_wrongProfile() {
        XCTAssertFalse(lease().accepts(profile: "OTHER", session: sA, op: oA))
    }
    func test_accepts_wrongSession() {
        XCTAssertFalse(lease().accepts(profile: "P", session: sB, op: oA))
    }
    func test_accepts_wrongOperation() {
        XCTAssertFalse(lease().accepts(profile: "P", session: sA, op: oB))
    }
    func test_accepts_exhaustedBudget() {
        XCTAssertFalse(lease(retries: 0).accepts(profile: "P", session: sA, op: oA))
    }

    func test_decremented() {
        XCTAssertEqual(lease(retries: 3).decremented().retriesLeft, 2)
    }

    // MARK: - decideLockFatal()

    func test_decide_validMatch_retriesDecremented() {
        let d = Policy.decideLockFatal(lease: lease(retries: 3), retryInFlight: false,
                                       profile: "P", session: sA, op: oA)
        XCTAssertEqual(d, .retry(lease(retries: 2)))
    }

    func test_decide_noLease_notInFlight_passesThrough() {
        // Stale / unrelated legit lock with no retry pending → honest modal.
        XCTAssertEqual(Policy.decideLockFatal(lease: nil, retryInFlight: false,
                                              profile: "P", session: sA, op: oA), .passThrough)
    }

    func test_decide_gapStraggler_inFlight_noPendingIdentity_suppresses() {
        // Duplicate / late fatal for the just-consumed transport, arriving in the
        // gap between an accepted retry and the reopened scan (pendingScan already
        // taken → nil identity) → ack silently, no spurious modal.
        XCTAssertEqual(Policy.decideLockFatal(lease: nil, retryInFlight: true,
                                              profile: "P", session: nil, op: nil), .suppress)
    }

    func test_decide_exhausted_realReconnectInFlight_passesThrough() {
        // THE EXHAUSTION FIX: budget spent, so the reopened reconnect binds no
        // lease, but it IS a real scan (pending identity present) that hit the
        // lock again → surface the honest modal, do NOT silently suppress into a
        // window-less limbo.
        XCTAssertEqual(Policy.decideLockFatal(lease: nil, retryInFlight: true,
                                              profile: "P", session: sA, op: oA), .passThrough)
    }

    func test_decide_wrongProfile_notInFlight_passesThrough() {
        // The round-4 leak: a lease from a prior profile must NOT authorize a
        // retry for a different profile.
        XCTAssertEqual(Policy.decideLockFatal(lease: lease("PREV"), retryInFlight: false,
                                              profile: "NEW", session: sA, op: oA), .passThrough)
    }

    func test_decide_wrongProfile_inFlight_realReconnect_passesThrough() {
        // Even mid-reopen, a real pending scan whose identity doesn't match the
        // lease is NOT a gap straggler → honest modal.
        XCTAssertEqual(Policy.decideLockFatal(lease: lease("PREV"), retryInFlight: true,
                                              profile: "NEW", session: sA, op: oA), .passThrough)
    }

    func test_decide_wrongOperation_notInFlight_passesThrough() {
        XCTAssertEqual(Policy.decideLockFatal(lease: lease(), retryInFlight: false,
                                              profile: "P", session: sA, op: oB), .passThrough)
    }

    func test_decide_wrongSession_inFlight_realReconnect_passesThrough() {
        // Replacement session, real pending scan → not a straggler → modal.
        XCTAssertEqual(Policy.decideLockFatal(lease: lease(), retryInFlight: true,
                                              profile: "P", session: sB, op: oA), .passThrough)
    }

    func test_decide_exhaustedLease_notInFlight_passesThrough() {
        // Budget spent → honest modal, not another retry.
        XCTAssertEqual(Policy.decideLockFatal(lease: lease(retries: 0), retryInFlight: false,
                                              profile: "P", session: sA, op: oA), .passThrough)
    }

    func test_decide_missingPendingIdentity_notInFlight_passesThrough() {
        // No reopen in flight and no pending op → not a straggler → modal.
        XCTAssertEqual(Policy.decideLockFatal(lease: lease(), retryInFlight: false,
                                              profile: "P", session: nil, op: nil), .passThrough)
    }

    // MARK: - bounded retry chain → exhaustion

    func test_boundedChain_retriesThenExhausts() {
        // Simulate the driver chain: each accepted fatal yields the decremented
        // lease that binds the next reconnect; after `max` retries the lease is
        // exhausted and the next lock passes through to the modal.
        var current: Lease? = lease(retries: 3)
        var retries = 0
        for _ in 0..<10 {
            let d = Policy.decideLockFatal(lease: current, retryInFlight: false,
                                           profile: "P", session: sA, op: oA)
            switch d {
            case .retry(let next):
                retries += 1
                // The next reconnect binds a lease with the same identity + carried budget.
                current = Lease(profile: "P", session: sA, op: oA, retriesLeft: next.retriesLeft)
            case .passThrough:
                current = nil
            case .suppress:
                XCTFail("no reopen in flight in this simulation")
            }
            if current == nil { break }
        }
        XCTAssertEqual(retries, 3, "exactly the budget of retries, then exhaustion → passThrough")
    }
}
