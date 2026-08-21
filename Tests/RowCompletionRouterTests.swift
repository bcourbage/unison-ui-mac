import XCTest
@testable import unison_ui_mac

/// Tests the extracted routing that AppDelegate uses for async row-set
/// completions (scan vs Ignore). This is the "extracted equivalent" of the real
/// AppDelegate routing — the same functions the installed handlers call — so
/// these prove the invariants without a directly-installed bridge test handler.
final class RowCompletionRouterTests: XCTestCase {
    private typealias S = EngineSessionCoordinator.SessionID
    private typealias O = EngineSessionCoordinator.OperationID

    // MARK: - Scan routing

    func test_scan_routesWhenPending() {
        let r = RowCompletionRouter.routeScan(pendingScan: (S(raw: 1), O(raw: 2)))
        XCTAssertEqual(r, .scan(session: S(raw: 1), op: O(raw: 2)))
    }

    func test_scan_dropsWhenNoPending() {
        XCTAssertEqual(RowCompletionRouter.routeScan(pendingScan: nil), .drop)
    }

    // MARK: - Ignore routing

    func test_ignore_routesToLiveSession() {
        let r = RowCompletionRouter.routeIgnore(pendingIgnore: S(raw: 7),
                                                liveSessions: [S(raw: 7)])
        XCTAssertEqual(r, .ignore(session: S(raw: 7)))
    }

    func test_ignore_dropsWhenNoPending() {
        // Stale/duplicate: the token was already consumed (nil) → drop, so a
        // second/duplicate Ignore completion updates nothing.
        XCTAssertEqual(
            RowCompletionRouter.routeIgnore(pendingIgnore: nil, liveSessions: [S(raw: 7)]),
            .drop)
    }

    func test_ignore_dropsWhenSessionNotLive() {
        // Replacement session: the pending Ignore's session is gone (closed or
        // replaced by a new session with a distinct id) → drop, never applied to
        // the replacement.
        XCTAssertEqual(
            RowCompletionRouter.routeIgnore(pendingIgnore: S(raw: 7),
                                            liveSessions: [S(raw: 8)]),
            .drop)
    }

    // MARK: - Independence (the core invariant)

    func test_ignoreCompletion_neverConsumesPendingScan() {
        // A scan is pending (e.g. a rescan was just started) but no Ignore is
        // pending. An Ignore completion routed via routeIgnore must NOT touch the
        // scan — it drops, leaving pendingScan for the real scan completion. This
        // is the "Ignore completion cannot complete a later rescan" guarantee.
        let pendingScan: (S, O)? = (S(raw: 1), O(raw: 9))
        let ignoreRoute = RowCompletionRouter.routeIgnore(pendingIgnore: nil,
                                                          liveSessions: [S(raw: 1)])
        XCTAssertEqual(ignoreRoute, .drop)
        // The scan token is untouched and still routes the scan.
        XCTAssertEqual(RowCompletionRouter.routeScan(pendingScan: pendingScan),
                       .scan(session: S(raw: 1), op: O(raw: 9)))
    }

    func test_scanCompletion_neverProducesIgnoreRoute_andViceVersa() {
        // Type-level guarantee, asserted concretely: routeScan only yields
        // .scan/.drop; routeIgnore only yields .ignore/.drop. Neither can satisfy
        // the other's pending state.
        if case .ignore = RowCompletionRouter.routeScan(pendingScan: (S(raw: 1), O(raw: 1))) {
            XCTFail("routeScan must never yield an .ignore route")
        }
        if case .scan = RowCompletionRouter.routeIgnore(pendingIgnore: S(raw: 1),
                                                        liveSessions: [S(raw: 1)]) {
            XCTFail("routeIgnore must never yield a .scan route")
        }
    }
}
