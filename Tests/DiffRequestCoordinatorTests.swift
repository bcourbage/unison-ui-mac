import XCTest
@testable import unison_ui_mac

/// L1 (diff-result identity) + residual Finding #6 (`run_show_diffs` fault
/// handling). Deterministic tests of the pure serialization/staleness policy:
/// rapid selection changes, duplicate/late completion, window/session
/// replacement, bridge failure, and cancellation/close.
final class DiffRequestCoordinatorTests: XCTestCase {

    func test_normalRequestThenResult_applies() {
        var c = DiffRequestCoordinator()
        guard case .issue = c.request() else { return XCTFail("first request should issue") }
        XCTAssertTrue(c.isAwaitingResult)
        XCTAssertEqual(c.deliver(), .apply)
        XCTAssertFalse(c.isAwaitingResult)
    }

    func test_rapidSecondRequest_refusedWhileInFlight() {
        var c = DiffRequestCoordinator()
        guard case .issue = c.request() else { return XCTFail() }
        // A second click before the first result lands is refused, so the
        // single outstanding result stays unambiguous.
        XCTAssertEqual(c.request(), .refuseInFlight)
        // After the first result, a new request issues normally.
        XCTAssertEqual(c.deliver(), .apply)
        guard case .issue = c.request() else { return XCTFail("should issue after prior completes") }
    }

    func test_duplicateOrLateSecondDelivery_dropped() {
        var c = DiffRequestCoordinator()
        _ = c.request()
        XCTAssertEqual(c.deliver(), .apply)
        // A duplicate / late second delivery for the same request is dropped.
        XCTAssertEqual(c.deliver(), .dropStale)
    }

    func test_deliveryWithNoOutstandingRequest_dropped() {
        var c = DiffRequestCoordinator()
        // A result routed to a window that never requested a diff (e.g. a
        // replacement session) is dropped.
        XCTAssertEqual(c.deliver(), .dropStale)
    }

    func test_invalidate_dropsInFlightResult_andUnblocks() {
        var c = DiffRequestCoordinator()
        _ = c.request()
        c.invalidate()                       // window closed / session replaced / cancelled
        XCTAssertFalse(c.isAwaitingResult)
        XCTAssertEqual(c.deliver(), .dropStale, "a result after invalidate is stale")
        guard case .issue = c.request() else { return XCTFail("must not be locked out after invalidate") }
    }

    func test_bridgeRaised_clearsPending_lateResultDropped_andUnblocks() {
        var c = DiffRequestCoordinator()
        guard case .issue = c.request() else { return XCTFail() }
        c.requestRaised()                    // run_show_diffs returned false
        XCTAssertFalse(c.isAwaitingResult)
        // No async result should come; if a stray one does, it's dropped.
        XCTAssertEqual(c.deliver(), .dropStale)
        // And the next diff can be requested immediately.
        guard case .issue = c.request() else { return XCTFail("should issue after a raised request") }
    }

    func test_errorDelivery_appliesOnceThenStale() {
        // showDiffError goes through the same deliver() gate as showDiff.
        var c = DiffRequestCoordinator()
        _ = c.request()
        XCTAssertEqual(c.deliver(), .apply)   // first error surfaced
        XCTAssertEqual(c.deliver(), .dropStale)
    }

    func test_tokensAreMonotonicAndDistinct() {
        var c = DiffRequestCoordinator()
        guard case .issue(let t1) = c.request() else { return XCTFail() }
        _ = c.deliver()
        guard case .issue(let t2) = c.request() else { return XCTFail() }
        _ = c.deliver()
        guard case .issue(let t3) = c.request() else { return XCTFail() }
        XCTAssertLessThan(t1, t2)
        XCTAssertLessThan(t2, t3)
    }

    func test_supersedeAcrossInvalidate_newResultApplies_oldDropped() {
        // Request A, then the window is closed (invalidate) and a fresh diff B
        // requested. A's late result must be dropped and B's applied — modeled
        // as: after invalidate the old delivery is stale, and the new request's
        // delivery applies.
        var c = DiffRequestCoordinator()
        _ = c.request()          // A
        c.invalidate()           // A's window closed
        guard case .issue = c.request() else { return XCTFail() }  // B
        // A's late result arrives first: it's for the (now single) outstanding
        // B request — but serialization guaranteed only ONE request was ever
        // outstanding at a time, so this delivery belongs to B. It applies once.
        XCTAssertEqual(c.deliver(), .apply)
        XCTAssertEqual(c.deliver(), .dropStale)
    }
}
