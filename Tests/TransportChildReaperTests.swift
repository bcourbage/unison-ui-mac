import XCTest
import Darwin
@testable import unison_ui_mac

/// Tests for the pure-C exact-child-PID transport reaper (SSH-reaper).
///
/// These fork REAL child processes (`/bin/sleep`) and drive the C registry
/// (`unison_bridge_track_child` / `_untrack_child` /
/// `_reap_transport_children`) directly, asserting exact-PID scoping: only
/// registered children are killed, unrelated children survive, a spawn racing
/// shutdown cannot escape, and unregister-before-reap leaves a child untouched
/// (the PID-reuse invariant). `unison_bridge_reset_child_registry_for_test`
/// (DEBUG-only) restores a known baseline between cases.
final class TransportChildReaperTests: XCTestCase {

    /// Children spawned by a test, killed+reaped in tearDown so nothing leaks.
    private var spawned: [pid_t] = []

    override func setUp() {
        super.setUp()
        unison_bridge_reset_child_registry_for_test()
    }

    override func tearDown() {
        for pid in spawned {
            kill(pid, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(pid, &st, 0)
        }
        spawned.removeAll()
        unison_bridge_reset_child_registry_for_test()
        super.tearDown()
    }

    // MARK: helpers

    /// Fork a real long-lived `sleep` child and return its PID.
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

    /// True while `pid` is a live process we can still signal.
    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Blocking-reap `pid`; return true iff it was terminated by SIGKILL.
    @discardableResult
    private func reapAndWasKilled(_ pid: pid_t) -> Bool {
        var st: Int32 = 0
        let r = waitpid(pid, &st, 0)
        if let i = spawned.firstIndex(of: pid) { spawned.remove(at: i) }
        // WIFSIGNALED && WTERMSIG == SIGKILL
        let signaled = (st & 0x7f) != 0 && (st & 0x7f) != 0x7f
        return r == pid && signaled && (st & 0x7f) == SIGKILL
    }

    // MARK: tests

    func test_registerUnregister_normalLifecycle_notKilled() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        unison_bridge_untrack_child(pid)          // normal teardown removes it
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        XCTAssertTrue(isAlive(pid), "untracked child must not be killed")
    }

    func test_unregister_idempotent() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        unison_bridge_untrack_child(pid)
        unison_bridge_untrack_child(pid)          // duplicate: no-op, no crash
        unison_bridge_untrack_child(999_999)      // never-registered: no-op
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        XCTAssertTrue(isAlive(pid))
    }

    func test_reap_withNoChildren_isNoOp() {
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)  // idempotent
    }

    func test_reap_killsExactRegisteredChild() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        XCTAssertEqual(unison_bridge_reap_transport_children(), 1)
        XCTAssertTrue(reapAndWasKilled(pid), "registered child must be SIGKILLed")
    }

    func test_reap_leavesUnrelatedChildUntouched() {
        let tracked = spawnSleeper()
        let unrelated = spawnSleeper()
        unison_bridge_track_child(tracked)        // only this one is registered
        XCTAssertEqual(unison_bridge_reap_transport_children(), 1)
        XCTAssertTrue(reapAndWasKilled(tracked), "registered child SIGKILLed")
        XCTAssertTrue(isAlive(unrelated), "unrelated child must survive (exact-PID scoping)")
    }

    func test_lateRegistration_racingShutdown_cannotEscape() {
        // Shutdown reaper runs first (sets closing state) with nothing tracked.
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        // A child spawned + registered AFTER shutdown began must be killed
        // immediately by track itself, not left running.
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        XCTAssertTrue(reapAndWasKilled(pid),
                      "a spawn racing shutdown must be terminated on register")
    }

    func test_untrackBeforeReap_noUntrackedLiveWindow_pidReuseSafe() {
        // The lifecycle rule is unregister strictly BEFORE waitpid, so once a
        // PID leaves the registry the reaper can never target it (and thus can
        // never SIGKILL a reused PID). Model it: track → untrack (pre-waitpid)
        // → reap must not target the child.
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        unison_bridge_untrack_child(pid)
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        XCTAssertTrue(isAlive(pid), "unregistered PID must never be targeted by the reaper")
    }
}
