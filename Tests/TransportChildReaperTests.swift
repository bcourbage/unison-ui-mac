import XCTest
import Darwin
@testable import unison_ui_mac

/// Tests for the pure-C exact-child-PID transport reaper (SSH-reaper).
///
/// These fork REAL child processes (`/bin/sleep`) and drive the C registry
/// (`unison_bridge_track_child` / `_retire_child` / `_reap_transport_children`)
/// directly. The contract under test:
///   - `track` records the exact pid (deduplicated);
///   - `retire` SIGKILLs the exact pid AND removes it atomically under the
///     mutex — the child is dead before it leaves the registry, so there is no
///     window where a live child is untracked, and no reused pid is signalled;
///   - `reap` (shutdown) SIGKILLs every still-registered pid.
/// `unison_bridge_reset_child_registry_for_test` (Debug-only) restores a known
/// baseline between cases.
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
        let signaled = (st & 0x7f) != 0 && (st & 0x7f) != 0x7f   // WIFSIGNALED
        return r == pid && signaled && (st & 0x7f) == SIGKILL    // WTERMSIG == SIGKILL
    }

    // MARK: tests

    /// retire SIGKILLs the exact child AND removes it, so the reaper then finds
    /// nothing. (kill-before-removal; the removed pid is a killed child.)
    func test_retire_killsExactChild_andRemovesIt() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        unison_bridge_retire_child(pid)
        XCTAssertTrue(reapAndWasKilled(pid), "retire must SIGKILL the child")
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0,
                       "retired pid must be gone from the registry")
    }

    /// Duplicate track followed by ONE retire must leave no stale entry.
    func test_duplicateTrack_singleRetire_noStaleEntry() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        unison_bridge_track_child(pid)          // dedup: second track is a no-op
        unison_bridge_retire_child(pid)         // one retire fully removes it
        XCTAssertTrue(reapAndWasKilled(pid))
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0,
                       "no stale duplicate must remain after one retire")
    }

    /// retire is idempotent and never signals a pid it no longer tracks (so it
    /// can't hit a reused pid). Second retire is a pure no-op.
    func test_retire_idempotent_doesNotSignalUntrackedPid() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        unison_bridge_retire_child(pid)         // kills + removes
        unison_bridge_retire_child(pid)         // no-op: not registered
        XCTAssertTrue(reapAndWasKilled(pid))
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
    }

    /// Models shutdown racing retirement: once retire has removed a pid, a
    /// subsequent reap does not target it (no double-handling), and the child
    /// has already been sent SIGKILL by retire and is irrevocably terminating.
    func test_retireThenReap_reaperDoesNotDoubleTarget() {
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        unison_bridge_retire_child(pid)
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        XCTAssertTrue(reapAndWasKilled(pid))
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
        unison_bridge_track_child(tracked)      // only this one is registered
        XCTAssertEqual(unison_bridge_reap_transport_children(), 1)
        XCTAssertTrue(reapAndWasKilled(tracked), "registered child SIGKILLed")
        XCTAssertTrue(isAlive(unrelated), "unrelated child must survive (exact-PID scoping)")
    }

    func test_reap_withNoChildren_isNoOp_andIdempotent() {
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
    }

    func test_lateRegistration_afterShutdown_cannotEscape() {
        // Shutdown reaper runs first (sets closing) with nothing tracked.
        XCTAssertEqual(unison_bridge_reap_transport_children(), 0)
        // A child spawned + registered AFTER shutdown began must be killed
        // immediately by track itself, not left running.
        let pid = spawnSleeper()
        unison_bridge_track_child(pid)
        XCTAssertTrue(reapAndWasKilled(pid),
                      "a spawn racing shutdown must be terminated on register")
    }

    /// Genuinely concurrent shutdown-vs-retire on the SAME tracked child.
    /// `retire(pid)` and `reap()` run on two threads with a synchronized start
    /// and race for the registry mutex. Whichever wins SIGKILLs the child; the
    /// loser finds it already gone and does nothing (no double-kill, no
    /// reused-pid signal, no hang). The assertions are on OUTCOMES, not timing,
    /// and hold for either ordering; many iterations shake out hangs/leaks.
    func test_concurrentRetireAndReap_sameChild_isSafe() {
        for _ in 0..<50 {
            unison_bridge_reset_child_registry_for_test()
            let tracked = spawnSleeper()
            let unrelated = spawnSleeper()          // never registered
            unison_bridge_track_child(tracked)

            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            for op in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    start.wait()                     // release both together
                    if op == 0 { unison_bridge_retire_child(tracked) }
                    else       { _ = unison_bridge_reap_transport_children() }
                    group.leave()
                }
            }
            start.signal(); start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success,
                           "concurrent retire/reap hung")

            // The tracked child was SIGKILLed exactly once (by whichever won)
            // and is reapable; the registry is empty; the unrelated child lives.
            XCTAssertTrue(reapAndWasKilled(tracked),
                          "tracked child must be SIGKILLed under either ordering")
            XCTAssertEqual(unison_bridge_reap_transport_children(), 0,
                           "registry must be empty after concurrent retire+reap")
            XCTAssertTrue(isAlive(unrelated), "unrelated child must survive")

            kill(unrelated, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(unrelated, &st, 0)
            if let i = spawned.firstIndex(of: unrelated) { spawned.remove(at: i) }
        }
    }
}
