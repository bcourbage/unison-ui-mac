import XCTest
@testable import unison_ui_mac

/// Phase 1a (issue #24): DIRECT coverage of the PRODUCTION C safety-boundary
/// primitives `unison_bridge_signal_scan_transport` and
/// `unison_bridge_classify_reap` (UnisonBridgeC.c). Ported from the Phase 0
/// spike (PR #49) into the Foundation PR so these promoted production functions
/// have PERMANENT regression coverage — PR #49 remains unmerged and cannot serve
/// as that coverage.
///
/// Refusals (no child / multiple children / already dead) are deterministic.
/// The signalled path and reap classifier run against real `posix_spawn`ed
/// children the test owns and reaps, so signalled → zombie → reaped is
/// deterministic (no Foundation background reaper in play). Live ssh-transport
/// behaviour remains the subject of the attended on-VM matrix, not this unit.
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
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("300"), nil]
        defer { for p in argv where p != nil { free(p) } }
        let rc = argv.withUnsafeMutableBufferPointer { buf in
            posix_spawn(&pid, "/bin/sleep", nil, nil, buf.baseAddress, environ)
        }
        XCTAssertEqual(rc, 0, "posix_spawn(/bin/sleep) failed: \(rc)")
        spawned.append(pid)
        return pid
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Poll the reap classifier over a bounded grace, exactly as the harness
    /// will (design §8): a freshly-SIGKILLed child is briefly still LIVE before
    /// the kernel turns it into a zombie.
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
        let a = spawnSleeper(); let b = spawnSleeper()
        unison_bridge_track_child(a); unison_bridge_track_child(b)
        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_MULTIPLE_CHILDREN,
                       "must never guess which of >1 children to kill")
        XCTAssertTrue(isAlive(a), "neither child may be signalled")
        XCTAssertTrue(isAlive(b), "neither child may be signalled")
    }

    // Gone child → ALREADY_DEAD WITHOUT a captured identity.
    func test_signal_deadPid_returnsAlreadyDead_noIdentity() {
        let ghost: pid_t = 2_000_000        // > macOS PID_MAX (99999): cannot be live
        unison_bridge_track_child(ghost)
        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_ALREADY_DEAD)
        XCTAssertEqual(r.identity_valid, 0, "a gone pid has no captured start identity")
    }

    // Zombie child → ALREADY_DEAD WITH a captured identity (the reviewer's
    // acceptance case: a zombie still resolves via sysctl, so identity is valid).
    func test_signal_zombieChild_returnsAlreadyDead_withIdentity() {
        let pid = spawnSleeper()
        var sec: Int64 = 0, usec: Int32 = 0
        XCTAssertTrue(unison_bridge_capture_identity(Int32(pid), &sec, &usec))
        kill(pid, SIGKILL)                  // dies; we deliberately do NOT reap it
        let z = settleReapState(pid: Int32(pid), sec: sec, usec: usec)
        XCTAssertEqual(z, UNISON_REAP_ZOMBIE, "precondition: an unreaped zombie")
        unison_bridge_track_child(pid)
        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_ALREADY_DEAD)
        XCTAssertEqual(r.identity_valid, 1, "a zombie still has a captured start identity")
        XCTAssertEqual(r.pid, Int32(pid))
        XCTAssertEqual(r.start_sec, sec)
        XCTAssertEqual(r.start_usec, usec)
    }

    // MARK: - Signalled path + reap classification (the real transition)

    func test_signal_liveChild_signalled_withIdentity_thenZombieThenReaped() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)

        let r = unison_bridge_signal_scan_transport()
        XCTAssertEqual(r.outcome, UNISON_SIGNAL_SIGNALLED)
        XCTAssertEqual(r.pid, Int32(pid))
        XCTAssertEqual(r.identity_valid, 1, "a live signalled child returns a valid identity")

        // Killed but not yet reaped → settles to a zombie and stays there (the
        // pid is reserved until we reap it).
        let z = settleReapState(pid: r.pid, sec: r.start_sec, usec: r.start_usec)
        XCTAssertEqual(z, UNISON_REAP_ZOMBIE)

        // Reap it (OCaml's role in production); the identity must not persist.
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
