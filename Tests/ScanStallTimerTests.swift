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

    // MARK: - Phase-aware policy integration (issue #33)
    //
    // Mirrors AppDelegate's scan-stall glue exactly: a per-op `sawRemoteWait`
    // flag latched by the remote-wait marker, timer reset on each status, and an
    // (s,op)-guarded fire that consults `ScanStallPolicy` — fatal only when
    // waiting on the remote, else keep waiting (re-arm) without mutating state.

    private enum Outcome: Equatable { case fatal(UInt64, UInt64); case keptWaiting }

    /// Faithful stand-in for the AppDelegate glue, so the orderings below test
    /// the shipped decision path rather than a re-implementation of it.
    @MainActor
    private final class Harness {
        let fake = FakeScheduler()
        var timer: ScanStallTimer!
        var pendingOp: (S, O)?
        var sawRemoteWait = false
        private(set) var outcomes: [Outcome] = []

        init() {
            timer = ScanStallTimer(timeout: 120, scheduler: fake.fn) { [weak self] s, o in
                self?.onFire(s, o)
            }
        }
        func armScan(_ s: S, _ o: O) {           // pendingScan.didSet (new op)
            pendingOp = (s, o); sawRemoteWait = false; timer.arm(s, o)
        }
        func status(_ msg: String) {             // installStatusHandler
            guard pendingOp != nil else { return }
            if ScanStallPolicy.marksRemoteWait(msg) { sawRemoteWait = true }
            timer.reset()
        }
        func abandon() { /* UI left: op retained, timer retained (issue #24) */ }
        func scanCompleted() { pendingOp = nil; timer.disarm() }
        private func onFire(_ s: S, _ o: O) {    // handleScanStall
            guard let p = pendingOp, p == (s, o) else { return }   // stale-op guard
            switch ScanStallPolicy.actionOnStall(sawRemoteWait: sawRemoteWait) {
            case .restartRequired:
                pendingOp = nil; timer.disarm(); outcomes.append(.fatal(s.raw, o.raw))
            case .keepWaiting:
                timer.arm(s, o); outcomes.append(.keptWaiting)
            }
        }
    }

    /// Delayed-local-walk / TCC proxy: silence with NO remote-wait marker is a
    /// local pause, not a remote wedge → keep waiting, never fatal, re-armed.
    func test_localWalkStall_isNotFatal_keepsWaiting() {
        let h = Harness()
        h.armScan(S(raw: 1), O(raw: 1))
        h.status("Looking for changes")                 // local phase
        h.status("scanning... Photos Library.photoslibrary")
        h.fake.fireNow()                                 // 120s of TCC silence
        XCTAssertEqual(h.outcomes, [.keptWaiting])
        XCTAssertTrue(h.timer.isArmed, "re-armed to keep watching")
        h.fake.fireNow()                                 // still paused
        XCTAssertEqual(h.outcomes, [.keptWaiting, .keptWaiting], "still not fatal")
    }

    /// After the local walk finishes and the engine waits on the remote, silence
    /// IS a wedge → fatal restart-required for the exact op.
    func test_remoteWaitStall_isFatal() {
        let h = Harness()
        h.armScan(S(raw: 2), O(raw: 5))
        h.status("scanning... docs")                     // local phase
        h.status("Looking for changes            Waiting for changes from server")
        h.fake.fireNow()                                 // server frozen → silence
        XCTAssertEqual(h.outcomes, [.fatal(2, 5)])
        XCTAssertFalse(h.timer.isArmed)
    }

    /// Local pause first (keep waiting), THEN the walk finishes and the remote
    /// wedges → fatal. Exercises the phase transition within one op.
    func test_localPauseThenRemoteWedge_transitionsToFatal() {
        let h = Harness()
        h.armScan(S(raw: 3), O(raw: 7))
        h.status("scanning... big-local-tree")
        h.fake.fireNow()                                 // local pause
        XCTAssertEqual(h.outcomes, [.keptWaiting])
        h.status("Waiting for changes from server")      // local done, now remote
        h.fake.fireNow()                                 // remote wedge
        XCTAssertEqual(h.outcomes, [.keptWaiting, .fatal(3, 7)])
    }

    /// A fire for an op that already ended (completed) is a no-op — stale/late
    /// expiry never fabricates a fatal.
    func test_staleFire_afterCompletion_isNoOp() {
        let h = Harness()
        h.armScan(S(raw: 4), O(raw: 1))
        h.status("Waiting for changes from server")
        h.scanCompleted()                                // init2 done → disarm
        h.fake.fireNow()                                 // stale timer (already cleared)
        XCTAssertEqual(h.outcomes, [], "no outcome for a completed scan")
    }

    /// Abandonment (UI left) retains the op + timer (issue #24). A remote wedge
    /// after abandonment still fires fatal for the exact op.
    func test_abandonedScan_remoteWedge_stillFatal() {
        let h = Harness()
        h.armScan(S(raw: 5), O(raw: 2))
        h.status("Waiting for changes from server")
        h.abandon()                                      // user returned to picker
        h.fake.fireNow()
        XCTAssertEqual(h.outcomes, [.fatal(5, 2)])
    }

    /// A new scan op resets the phase flag: a prior op's remote-wait must not
    /// make a fresh op's local pause fatal.
    func test_newOp_resetsRemoteWaitPhase() {
        let h = Harness()
        h.armScan(S(raw: 6), O(raw: 1))
        h.status("Waiting for changes from server")      // op1 reached remote wait
        h.scanCompleted()
        h.armScan(S(raw: 6), O(raw: 2))                  // op2: fresh
        h.status("scanning... local")                    // local phase only
        h.fake.fireNow()
        XCTAssertEqual(h.outcomes, [.keptWaiting], "op2 local pause is not fatal")
    }
}
