import XCTest
@testable import unison_ui_mac

/// Issue #34: deterministic timer/state tests for the advisory sync-stall
/// detector, using an injected scheduler (no real 45s waits). Verifies it is
/// non-fatal (only `onStall`/`onResume` fire — never a state mutation) and that
/// a healthy silent window clears cleanly.
@MainActor
final class SyncStallDetectorTests: XCTestCase {

    private final class FakeScheduler {
        private var body: (() -> Void)?
        private(set) var schedules = 0
        private(set) var cancels = 0
        var isPending: Bool { body != nil }
        lazy var fn: SyncStallDetector.Scheduler = { [weak self] _, body in
            guard let self else { return .init(cancel: {}) }
            self.schedules += 1; self.body = body
            return SyncStallDetector.Handle { self.cancels += 1; self.body = nil }
        }
        func fireNow() { let b = body; body = nil; b?() }
    }

    private struct Events { var stalls = 0; var resumes = 0 }

    private func make(_ fake: FakeScheduler, _ ev: @escaping () -> Void = {})
        -> (SyncStallDetector, () -> Events) {
        var e = Events()
        let d = SyncStallDetector(timeout: 45, scheduler: fake.fn,
                                  onStall: { e.stalls += 1 },
                                  onResume: { e.resumes += 1 })
        return (d, { e })
    }

    func test_start_arms() {
        let fake = FakeScheduler()
        let (d, _) = make(fake)
        XCTAssertFalse(d.isArmed)
        d.start()
        XCTAssertTrue(d.isArmed)
        XCTAssertEqual(fake.schedules, 1)
    }

    func test_fire_isAdvisory_stallOnly_noResume() {
        let fake = FakeScheduler()
        let (d, ev) = make(fake)
        d.start()
        fake.fireNow()
        XCTAssertTrue(d.isStalled)
        XCTAssertEqual(ev().stalls, 1)
        XCTAssertEqual(ev().resumes, 0, "fire is advisory: no resume, and no state mutation of any kind")
    }

    /// Healthy silent window regression: notice appears, then progress resumes →
    /// notice clears and the detector re-arms; a later completion is clean.
    func test_healthySilentWindow_thenResume_thenComplete_clearsCleanly() {
        let fake = FakeScheduler()
        let (d, ev) = make(fake)
        d.start()
        fake.fireNow()                       // 45s silence → advisory notice
        XCTAssertTrue(d.isStalled)
        d.noteProgress()                     // transfer resumes
        XCTAssertFalse(d.isStalled, "notice cleared on resume")
        XCTAssertEqual(ev().resumes, 1)
        XCTAssertTrue(d.isArmed, "re-armed to keep watching")
        d.stop()                             // sync completes
        XCTAssertFalse(d.isStalled)
        XCTAssertFalse(d.isArmed, "completion clears cleanly")
    }

    func test_noteProgress_whenNotStalled_reArms_noResume() {
        let fake = FakeScheduler()
        let (d, ev) = make(fake)
        d.start()
        let before = fake.schedules
        d.noteProgress()
        XCTAssertEqual(fake.schedules, before + 1, "re-armed")
        XCTAssertEqual(ev().resumes, 0, "no resume when not stalled")
    }

    func test_stop_disarms_andStaleFireIsNoOp() {
        let fake = FakeScheduler()
        let (d, ev) = make(fake)
        d.start()
        d.stop()
        XCTAssertFalse(d.isArmed)
        fake.fireNow()                       // stale timer that slipped through
        XCTAssertEqual(ev().stalls, 0, "no stall after stop (guarded on running)")
        XCTAssertFalse(d.isStalled)
    }

    func test_noteProgress_afterStop_isNoOp() {
        let fake = FakeScheduler()
        let (d, _) = make(fake)
        d.start(); d.stop()
        let s = fake.schedules
        d.noteProgress()
        XCTAssertEqual(fake.schedules, s, "no-op when not running")
    }
}
