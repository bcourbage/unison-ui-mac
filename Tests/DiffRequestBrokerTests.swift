import XCTest
@testable import unison_ui_mac

/// L1 (diff-result identity) — deterministic proof of the app-global
/// `DiffRequestBroker` invariant: a late diff result from an abandoned/replaced
/// session can NEVER be accepted as the result of a new session's request. The
/// property is structural (serialize globally + drain an abandoned result
/// before any new request), not timing-dependent.
final class DiffRequestBrokerTests: XCTestCase {

    private let A: DiffRequestBroker.Owner = 1   // an "old" session
    private let B: DiffRequestBroker.Owner = 2   // a "replacement" session

    // MARK: - Baseline

    func test_normalRequestThenResult_appliesToOwner() {
        var b = DiffRequestBroker()
        XCTAssertEqual(b.request(owner: A), .issue)
        XCTAssertTrue(b.isAwaitingResult)
        XCTAssertEqual(b.deliver(), .apply(owner: A))
        XCTAssertFalse(b.isAwaitingResult)
    }

    func test_secondRequestWhileOutstanding_refused() {
        var b = DiffRequestBroker()
        XCTAssertEqual(b.request(owner: A), .issue)
        // Any second request (same or other owner) is refused while one is
        // outstanding, so the single delivery stays unambiguous.
        XCTAssertEqual(b.request(owner: A), .refuseInFlight)
        XCTAssertEqual(b.request(owner: B), .refuseInFlight)
    }

    func test_deliveryWhenIdle_dropped() {
        var b = DiffRequestBroker()
        XCTAssertEqual(b.deliver(), .dropStale)
    }

    func test_duplicateDelivery_dropped() {
        var b = DiffRequestBroker()
        _ = b.request(owner: A)
        XCTAssertEqual(b.deliver(), .apply(owner: A))
        XCTAssertEqual(b.deliver(), .dropStale)   // late/duplicate second delivery
    }

    func test_requestRaised_clearsPending_andUnblocks() {
        var b = DiffRequestBroker()
        XCTAssertEqual(b.request(owner: A), .issue)
        b.requestRaised(owner: A)                 // run_show_diffs returned false
        XCTAssertFalse(b.isAwaitingResult)
        XCTAssertEqual(b.deliver(), .dropStale)   // a stray result is dropped
        XCTAssertEqual(b.request(owner: A), .issue, "must not be locked out after a raised request")
    }

    func test_requestRaised_ignoresNonOwner() {
        var b = DiffRequestBroker()
        XCTAssertEqual(b.request(owner: A), .issue)
        b.requestRaised(owner: B)                 // not the outstanding owner
        XCTAssertTrue(b.isAwaitingResult, "A's request must remain outstanding")
        XCTAssertEqual(b.deliver(), .apply(owner: A))
    }

    func test_abandonNonOwner_isNoOp() {
        var b = DiffRequestBroker()
        XCTAssertEqual(b.request(owner: A), .issue)
        b.abandon(owner: B)                       // some other session left
        XCTAssertTrue(b.isAwaitingResult)
        XCTAssertFalse(b.isDraining)
        XCTAssertEqual(b.deliver(), .apply(owner: A))
    }

    // MARK: - THE DANGEROUS ORDERING (the L1 invariant)

    /// old request issued → old session invalidated → replacement session
    /// issues a request → old result arrives → old result is REJECTED →
    /// replacement result alone is published. Every step asserted explicitly.
    func test_lateResultOfAbandonedSession_neverAcceptedAsReplacements() {
        var b = DiffRequestBroker()

        // 1. Old session A issues a diff.
        XCTAssertEqual(b.request(owner: A), .issue)

        // 2. A is invalidated (window closed / session replaced) while its
        //    result is still in flight → the broker drains.
        b.abandon(owner: A)
        XCTAssertTrue(b.isDraining)

        // 3. Replacement session B issues a request. It is REFUSED while A's
        //    result is still draining — B is NOT allowed to have an outstanding
        //    request that A's late result could be mistaken for.
        XCTAssertEqual(b.request(owner: B), .refuseDraining)
        XCTAssertFalse(b.isAwaitingResult)

        // 4. A's late result arrives. It is REJECTED (dropped), not applied to
        //    anyone — this is the whole point.
        XCTAssertEqual(b.deliver(), .dropStale)
        XCTAssertFalse(b.isDraining)

        // 5. Now B may issue.
        XCTAssertEqual(b.request(owner: B), .issue)

        // 6. B's result arrives and is applied to B ALONE.
        XCTAssertEqual(b.deliver(), .apply(owner: B))
    }

    /// Even if B's request is (incorrectly, in a hypothetical) attempted right
    /// after abandon and BEFORE the drain, the broker refuses it — so there is
    /// never a window in which A's result could be delivered while B has an
    /// outstanding request. Proven by: no `.issue` for B is ever returned while
    /// draining, and a delivery while draining is always `.dropStale`.
    func test_noIssueForReplacement_whileDraining() {
        var b = DiffRequestBroker()
        _ = b.request(owner: A)
        b.abandon(owner: A)
        // Repeated attempts by B stay refused for as long as A hasn't drained.
        XCTAssertEqual(b.request(owner: B), .refuseDraining)
        XCTAssertEqual(b.request(owner: B), .refuseDraining)
        // A delivery during draining is the abandoned result — dropped.
        XCTAssertEqual(b.deliver(), .dropStale)
    }

    /// Intra-session variant: the SAME session closes its diff window (abandon)
    /// while a result is in flight, then wants a new diff. The old result must
    /// not be applied to the new request. Drain-gating enforces this exactly as
    /// for the cross-session case.
    func test_sameSession_abandonThenReRequest_oldResultNotApplied() {
        var b = DiffRequestBroker()
        _ = b.request(owner: A)
        b.abandon(owner: A)                       // diff window closed
        XCTAssertEqual(b.request(owner: A), .refuseDraining)
        XCTAssertEqual(b.deliver(), .dropStale)   // old result drained
        XCTAssertEqual(b.request(owner: A), .issue)
        XCTAssertEqual(b.deliver(), .apply(owner: A))
    }

    func test_serialAcrossOwners_afterCleanCompletion() {
        var b = DiffRequestBroker()
        _ = b.request(owner: A)
        XCTAssertEqual(b.deliver(), .apply(owner: A))   // A completed normally
        // A different session can now issue; its result is its own.
        XCTAssertEqual(b.request(owner: B), .issue)
        XCTAssertEqual(b.deliver(), .apply(owner: B))
    }
}
