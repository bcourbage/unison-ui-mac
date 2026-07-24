import XCTest
@testable import unison_ui_mac

/// Phase 0 scan-interruption spike (issue #24 follow-up): coverage for the
/// Debug-only C primitives `unison_bridge_signal_scan_transport` and
/// `unison_bridge_classify_reap` (docs/scan-interruption-design.md §6/§8).
///
/// The primitive's *refusals* (no child / multiple children / already dead)
/// are deterministic and covered here. The signalled path and the reap
/// classifier are exercised against real `posix_spawn`ed children the test
/// owns and reaps, so zombie-vs-reaped is deterministic (no Foundation
/// background reaper in play). The live ssh-transport behaviour is the subject
/// of the on-VM matrix, not this unit test.
final class ScanTransportSignalTests: XCTestCase {

    private var spawned: [pid_t] = []

    override func setUp() {
        super.setUp()
        unison_bridge_reset_child_registry_for_test()
    }

    override func tearDown() {
        for pid in spawned where isAlive(pid) { kill(pid, SIGKILL) }
        for pid in spawned {
            var st: Int32 = 0
            _ = waitpid(pid, &st, 0)
        }
        spawned.removeAll()
        unison_bridge_reset_child_registry_for_test()
        super.tearDown()
    }

    // MARK: helpers

    private func spawnSleeper() -> pid_t {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] =
            [strdup("sleep"), strdup("300"), nil]
        defer { for p in argv where p != nil { free(p) } }
        let rc = argv.withUnsafeMutableBufferPointer { buf in
            posix_spawn(&pid, "/bin/sleep", nil, nil, buf.baseAddress, environ)
        }
        XCTAssertEqual(rc, 0, "posix_spawn(/bin/sleep) failed: \(rc)")
        spawned.append(pid)
        return pid
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Poll the reap classifier over a bounded grace period, exactly as the
    /// harness will (design §8): a freshly-SIGKILLed child is briefly still
    /// LIVE before the kernel reaps it into a zombie.
    private func settleReapState(pid: Int32, sec: Int64, usec: Int32,
                                 timeout: TimeInterval = 3.0) -> unison_reap_state_t {
        let deadline = Date().addingTimeInterval(timeout)
        var state = unison_bridge_classify_reap(pid, sec, usec)
        while state == UNISON_REAP_LIVE && Date() < deadline {
            usleep(20_000)
            state = unison_bridge_classify_reap(pid, sec, usec)
        }
        return state
    }

    // MARK: - Refusals (deterministic, no signal issued)

    func test_signal_noChild_returnsNoChild() {
        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_NO_CHILD)
    }

    func test_signal_multipleChildren_refusesWithoutKilling() {
        let a = spawnSleeper()
        let b = spawnSleeper()
        unison_bridge_track_child(a)
        unison_bridge_track_child(b)
        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_MULTIPLE_CHILDREN,
                       "must never guess which of >1 children to kill")
        // Neither child was signalled.
        XCTAssertTrue(isAlive(a))
        XCTAssertTrue(isAlive(b))
    }

    func test_signal_deadPid_returnsAlreadyDead() {
        // macOS PID_MAX is 99999; this pid cannot name a live process.
        let ghost: pid_t = 2_000_000
        unison_bridge_track_child(ghost)
        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_ALREADY_DEAD)
    }

    // MARK: - Signalled path + reap classification

    func test_signal_liveChild_signalsThenZombieThenReaped() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)

        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_SIGNALLED)
        XCTAssertEqual(r.pid, Int32(pid))

        // Killed but not yet waitpid'd by anyone → settles to a zombie and
        // stays there (the pid is reserved until we reap it).
        let z = settleReapState(pid: r.pid, sec: r.start_sec, usec: r.start_usec)
        XCTAssertEqual(z, UNISON_REAP_ZOMBIE)

        // We reap it (OCaml's role in production); now the identity is gone.
        var st: Int32 = 0
        XCTAssertEqual(waitpid(pid, &st, 0), pid)
        if let i = spawned.firstIndex(of: pid) { spawned.remove(at: i) }
        let after = unison_bridge_classify_reap(r.pid, r.start_sec, r.start_usec)
        XCTAssertTrue(after == UNISON_REAP_ABSENT || after == UNISON_REAP_REUSED,
                      "after reap the captured identity must not persist (got \(after))")
    }

    // MARK: - classify_reap identity logic

    func test_classifyReap_absentPid_isAbsent() {
        XCTAssertEqual(unison_bridge_classify_reap(2_000_000, 1, 2), UNISON_REAP_ABSENT)
    }

    func test_classifyReap_liveMatchingIdentity_isLive() {
        let pid = spawnSleeper()
        var sec: Int64 = 0, usec: Int32 = 0
        XCTAssertTrue(unison_bridge_capture_identity(Int32(pid), &sec, &usec))
        XCTAssertEqual(unison_bridge_classify_reap(Int32(pid), sec, usec), UNISON_REAP_LIVE)
    }

    func test_classifyReap_liveWrongIdentity_isReused() {
        let pid = spawnSleeper()
        var sec: Int64 = 0, usec: Int32 = 0
        XCTAssertTrue(unison_bridge_capture_identity(Int32(pid), &sec, &usec))
        // Same live pid, deliberately-wrong start identity → looks like the
        // original was reaped and the pid recycled onto a different process.
        XCTAssertEqual(unison_bridge_classify_reap(Int32(pid), sec &+ 1, usec),
                       UNISON_REAP_REUSED)
    }
}
