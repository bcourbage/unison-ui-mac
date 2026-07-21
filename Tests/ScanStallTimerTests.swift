import XCTest
@testable import unison_ui_mac

/// Integration-seam tests for the init2/scan stall timer (issue #24). Uses an
/// injected scheduler so arm/reset/disarm/fire are exercised deterministically
/// — no real 120s waits, no timing flake.
@MainActor
final class ScanStallTimerTests: XCTestCase {

    private typealias S = EngineSessionCoordinator.SessionID
    private typealias O = EngineSessionCoordinator.OperationID

    /// Captures the most recent scheduled fire so a test can trigger it on
    /// demand, and counts schedule/cancel calls.
    private final class FakeScheduler {
        private(set) var schedules = 0
        private(set) var cancels = 0
        private var body: (() -> Void)?
        var isPending: Bool { body != nil }
        lazy var fn: ScanStallTimer.Scheduler = { [weak self] _, body in
            guard let self else { return .init(cancel: {}) }
            self.schedules += 1
            self.body = body
            return ScanStallTimer.Handle { self.cancels += 1; self.body = nil }
        }
        func fireNow() { let b = body; body = nil; b?() }
    }

    private func makeTimer(_ fake: FakeScheduler,
                           fired: @escaping (S, O) -> Void) -> ScanStallTimer {
        ScanStallTimer(timeout: 120, scheduler: fake.fn, onFire: fired)
    }

    func test_arm_schedulesAndIsArmed() {
        let fake = FakeScheduler()
        let t = makeTimer(fake) { _, _ in }
        XCTAssertFalse(t.isArmed)
        t.arm(S(raw: 1), O(raw: 2))
        XCTAssertTrue(t.isArmed)
        XCTAssertEqual(fake.schedules, 1)
    }

    func test_reset_reArms_cancellingPrevious() {
        let fake = FakeScheduler()
        let t = makeTimer(fake) { _, _ in }
        t.arm(S(raw: 1), O(raw: 2))
        t.reset()                       // scan progress
        XCTAssertEqual(fake.schedules, 2, "reset re-schedules")
        XCTAssertEqual(fake.cancels, 1, "reset cancels the prior fire")
        XCTAssertTrue(t.isArmed)
    }

    func test_reset_isNoOpWhenNotArmed() {
        let fake = FakeScheduler()
        let t = makeTimer(fake) { _, _ in }
        t.reset()
        XCTAssertEqual(fake.schedules, 0)
        XCTAssertFalse(t.isArmed)
    }

    func test_disarm_cancels_andClears() {
        let fake = FakeScheduler()
        let t = makeTimer(fake) { _, _ in }
        t.arm(S(raw: 1), O(raw: 2))
        t.disarm()                      // scan terminal (completion/failure)
        XCTAssertEqual(fake.cancels, 1)
        XCTAssertFalse(t.isArmed)
        XCTAssertFalse(fake.isPending)
    }

    func test_disarm_isIdempotent() {
        let fake = FakeScheduler()
        let t = makeTimer(fake) { _, _ in }
        t.arm(S(raw: 1), O(raw: 2)); t.disarm(); t.disarm()
        XCTAssertFalse(t.isArmed)
    }

    func test_expiry_firesWithExactOp_andClears() {
        let fake = FakeScheduler()
        var fired: [(UInt64, UInt64)] = []
        let t = makeTimer(fake) { s, o in fired.append((s.raw, o.raw)) }
        t.arm(S(raw: 7), O(raw: 9))
        fake.fireNow()
        XCTAssertEqual(fired.map { "\($0.0)/\($0.1)" }, ["7/9"], "fires with the exact armed op")
        XCTAssertFalse(t.isArmed, "cleared after firing")
    }

    func test_reArmToNewOp_firesLatestOp() {
        let fake = FakeScheduler()
        var fired: [(UInt64, UInt64)] = []
        let t = makeTimer(fake) { s, o in fired.append((s.raw, o.raw)) }
        t.arm(S(raw: 1), O(raw: 2))
        t.arm(S(raw: 1), O(raw: 3))     // replacement op (new scan)
        fake.fireNow()
        XCTAssertEqual(fired.map { "\($0.0)/\($0.1)" }, ["1/3"])
    }
}
