import XCTest
@testable import unison_ui_mac

/// Tests that hit the live OCaml bridge.
///
/// IMPORTANT: when XCTest runs as a unit-test bundle hosted by the app,
/// `AppDelegate.applicationDidFinishLaunching` has already called
/// `unison_bridge_startup()` + `unison_bridge_init0()` before any test
/// method runs. That means:
///   - The OCaml runtime is alive and shared across every test method.
///   - `caml_startup` can only be called once per process — these tests
///     can't re-init the runtime.
///   - State accumulated by prior tests (registered handlers, init1
///     side-effects, archive locks) persists. Tests must be ordered or
///     defensively reset state.
///
/// XCTest runs methods in alphabetical order within a class. Where order
/// matters we prefix with `test_a_`/`test_b_` etc.
final class BridgeTests: XCTestCase {

    // MARK: - Synchronous, read-only entry points

    func test_a_getVersion_returnsNonEmptyVersionString() {
        guard let cstr = unison_bridge_get_version() else {
            XCTFail("unison_bridge_get_version returned NULL — runtime not initialized?")
            return
        }
        let v = String(cString: cstr)
        XCTAssertFalse(v.isEmpty, "version string is empty")
        // Should look like "2.54.0 (ocaml 5.x.y)"
        XCTAssertTrue(v.contains("ocaml"), "version doesn't mention ocaml: \(v)")
    }

    func test_a_unisonDirectory_returnsPathOnDisk() {
        guard let cstr = unison_bridge_unison_directory() else {
            XCTFail("unison_bridge_unison_directory returned NULL")
            return
        }
        let dir = String(cString: cstr)
        XCTAssertFalse(dir.isEmpty)
        XCTAssertTrue(dir.hasPrefix("/"), "expected absolute path: \(dir)")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDir)
        XCTAssertTrue(exists, "unison directory doesn't exist on disk: \(dir)")
        XCTAssertTrue(isDir.boolValue, "unison directory path is not a directory")
    }

    // MARK: - Per-row roots (require init1+init2 to have run)

    func test_b_riOps_failGracefullyWhenNoStateLoaded() {
        // No init1/init2 has run in this test, so g_ri_count is 0.
        // Out-of-range row should return NULL, not crash.
        XCTAssertNil(unison_bridge_ri_set_to_remote(0))
        XCTAssertNil(unison_bridge_ri_set_to_local(99999))
        XCTAssertNil(unison_bridge_ri_set_skip(-1))
        XCTAssertNil(unison_bridge_ri_set_merge(0))
    }

    func test_b_ignoreOps_failGracefullyWhenNoStateLoaded() {
        // Same guard as the ri-set ops: with no reconcile state, the row
        // is out of range so each ignore call should report failure rather
        // than crash. Calling these is safe even when no profile is open
        // (e.g. if a stale menu item is somehow invoked).
        XCTAssertFalse(unison_bridge_ignore_path(0))
        XCTAssertFalse(unison_bridge_ignore_ext(99999))
        XCTAssertFalse(unison_bridge_ignore_name(-1))
    }

    func test_b_canDiff_returnsFalseGracefullyOnOutOfRange() {
        // With no reconcile state loaded, every row index is out of
        // range. canDiff must return false (not crash, not throw).
        XCTAssertFalse(unison_bridge_can_diff(0))
        XCTAssertFalse(unison_bridge_can_diff(99999))
        XCTAssertFalse(unison_bridge_can_diff(-1))
    }
}

/// Stress / perf tests. Promotion of the bring-up 1000-call benchmark
/// to a measured XCTest so regressions are flagged.
final class BridgeStressTests: XCTestCase {

    /// Synchronous round-trip throughput: Swift → C → OCaml worker →
    /// OCaml callback → reply → C → Swift. Each iteration takes a full
    /// pthread mutex+condvar handoff plus an OCaml call.
    ///
    /// Original bring-up baseline (May 2026, M1 Max, Debug build):
    ///   1000 calls in 0.007s = ~141k/sec = ~7 μs/call.
    /// XCTest's perf measure makes this a regression gate.
    func test_perf_getVersionRoundTrip() {
        measure {
            for _ in 0..<1000 {
                _ = unison_bridge_get_version()
            }
        }
    }
}
