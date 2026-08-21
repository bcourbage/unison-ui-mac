import XCTest
@testable import unison_ui_mac

/// Issue #63: the classifier decides *what* a prompt is; `RetryNoticeCoalescer`
/// owns the stateful part the driver relies on — a held notice is shown on the
/// next prompt exactly once, then cleared, and can never leak into another
/// connection. These exercise that sequence directly (the async connect loop
/// can't be driven headlessly).
final class RetryNoticeCoalescerTests: XCTestCase {

    private typealias S = EngineSessionCoordinator.SessionID
    private typealias O = EngineSessionCoordinator.OperationID

    private let s = S(raw: 0)
    private let op = O(raw: 0)
    private let notice = "Permission denied, please try again."

    // MARK: fold-in happens once

    func test_heldNotice_isFoldedIntoNextPrompt_once() {
        var c = RetryNoticeCoalescer()
        c.hold(notice, for: s, op)
        XCTAssertTrue(c.hasPending)

        let first = c.fold(into: "Password:", for: s, op)
        XCTAssertEqual(first, notice + "\nPassword:")
        XCTAssertFalse(c.hasPending, "the notice must be consumed by the first fold")

        // A second prompt in the same connect gets no leftover notice.
        let second = c.fold(into: "Password:", for: s, op)
        XCTAssertEqual(second, "Password:")
    }

    func test_noPending_returnsPromptUnchanged() {
        var c = RetryNoticeCoalescer()
        XCTAssertEqual(c.fold(into: "Password:", for: s, op), "Password:")
        XCTAssertFalse(c.hasPending)
    }

    // MARK: lifecycle — a new connect cannot inherit a stale notice

    func test_reset_dropsPending_soNewConnectCannotInherit() {
        var c = RetryNoticeCoalescer()
        c.hold(notice, for: s, op)
        c.reset()
        XCTAssertFalse(c.hasPending)
        XCTAssertEqual(c.fold(into: "Password:", for: s, op), "Password:")
    }

    func test_emptyNotice_isNotHeld() {
        var c = RetryNoticeCoalescer()
        c.hold("   \r\n ", for: s, op)
        XCTAssertFalse(c.hasPending)
        XCTAssertEqual(c.fold(into: "Password:", for: s, op), "Password:")
    }

    // MARK: binding — a notice never crosses into a different (session, op)

    func test_notice_boundToOp_isNotFoldedIntoADifferentOp() {
        var c = RetryNoticeCoalescer()
        c.hold(notice, for: S(raw: 1), O(raw: 7))

        // A prompt for a DIFFERENT op must not receive the notice…
        let other = c.fold(into: "Password:", for: S(raw: 2), O(raw: 9))
        XCTAssertEqual(other, "Password:")
        // …and the stale notice is dropped, not carried to the original op.
        XCTAssertFalse(c.hasPending)
        XCTAssertEqual(c.fold(into: "Password:", for: S(raw: 1), O(raw: 7)), "Password:")
    }

    func test_notice_boundToSession_notFoldedIntoSameOpDifferentSession() {
        var c = RetryNoticeCoalescer()
        c.hold(notice, for: S(raw: 1), O(raw: 0))
        // Same OperationID value, different SessionID: must not match.
        XCTAssertEqual(c.fold(into: "Password:", for: S(raw: 2), O(raw: 0)), "Password:")
    }

    // MARK: re-prompt storm stays one-notice-per-attempt

    func test_secondRetry_replacesFirst_stillFoldedOnce() {
        var c = RetryNoticeCoalescer()
        c.hold(notice, for: s, op)
        // ssh denies again before the user answered: a fresh notice replaces the
        // held one (still exactly one notice folded into the next prompt).
        c.hold(notice, for: s, op)
        XCTAssertEqual(c.fold(into: "Password:", for: s, op), notice + "\nPassword:")
        XCTAssertFalse(c.hasPending)
    }
}
