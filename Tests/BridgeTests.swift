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

    // MARK: - Thread-local return storage (PR #7 review finding 2)
    //
    // get_version / unison_directory / connection_prompt return pointers into
    // per-thread (`_Thread_local`) buffers. Content-equality alone can't prove
    // this — every call returns the SAME string, so a shared process-global
    // `static` would look fine. The decisive check is the buffer ADDRESS: a
    // distinct thread must get a distinct return buffer; a shared static hands
    // back the same address to every thread.

    /// A distinct thread must receive a distinct return-buffer address, and
    /// identical content. Would FAIL if the storage were a shared `static`.
    func test_a_getVersion_returnBufferIsThreadLocal() {
        guard let mainPtr = unison_bridge_get_version() else {
            XCTFail("get_version returned NULL — runtime not initialized?"); return
        }
        let reference = String(cString: mainPtr)
        let mainAddr = UnsafeRawPointer(mainPtr)

        let done = expectation(description: "bg thread call")
        var bgAddr: UnsafeRawPointer?
        var bgContent: String?
        let t = Thread {
            if let p = unison_bridge_get_version() {
                bgAddr = UnsafeRawPointer(p)
                bgContent = String(cString: p)
            }
            done.fulfill()
        }
        t.start()
        wait(for: [done], timeout: 5)

        XCTAssertEqual(bgContent, reference, "content must be identical across threads")
        XCTAssertNotNil(bgAddr)
        XCTAssertNotEqual(mainAddr, bgAddr,
            "get_version return buffer is shared across threads — not _Thread_local")
    }

    func test_a_unisonDirectory_returnBufferIsThreadLocal() {
        guard let mainPtr = unison_bridge_unison_directory() else {
            XCTFail("unison_directory returned NULL"); return
        }
        let reference = String(cString: mainPtr)
        let mainAddr = UnsafeRawPointer(mainPtr)

        let done = expectation(description: "bg thread call")
        var bgAddr: UnsafeRawPointer?
        var bgContent: String?
        let t = Thread {
            if let p = unison_bridge_unison_directory() {
                bgAddr = UnsafeRawPointer(p)
                bgContent = String(cString: p)
            }
            done.fulfill()
        }
        t.start()
        wait(for: [done], timeout: 5)

        XCTAssertEqual(bgContent, reference, "content must be identical across threads")
        XCTAssertNotNil(bgAddr)
        XCTAssertNotEqual(mainAddr, bgAddr,
            "unison_directory return buffer is shared across threads — not _Thread_local")
    }

    /// Under heavy concurrency every caller must read back a complete, correct
    /// copy — validates the copied CONTENTS, not merely a non-null pointer.
    func test_a_readOnlyEntryPoints_concurrentCallersGetCorrectCopies() {
        let versionRef = String(cString: unison_bridge_get_version()!)
        let dirRef = String(cString: unison_bridge_unison_directory()!)

        let lock = NSLock()
        var mismatches = 0
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            // Copy immediately into a Swift String (owns its own storage).
            let v = unison_bridge_get_version().map { String(cString: $0) }
            let d = unison_bridge_unison_directory().map { String(cString: $0) }
            // connection_prompt has no preconnection here → must stay NULL,
            // concurrently, without crashing.
            let p = unison_bridge_connection_prompt()
            if v != versionRef || d != dirRef || p != nil {
                lock.lock(); mismatches += 1; lock.unlock()
            }
        }
        XCTAssertEqual(mismatches, 0,
            "concurrent callers saw corrupted/unstable return content")
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

    func test_b_abortSync_isNoOpWhenNothingIsRunning() {
        // The C bridge dispatches `Abort.all` on the OCaml thread,
        // which sets the global `abortAll` flag. With no sync in
        // flight, this is a no-op flag-flip — no checkpoint will
        // observe it. Verify it doesn't crash and returns promptly.
        // (Real abort behavior — interrupting a sync mid-transfer —
        // requires a running sync to exercise; that's manual smoke
        // testing territory, not unit.)
        unison_bridge_abort_sync()
        // If we got here, the callback dispatch worked. If the
        // `abortAll` callback weren't registered in the local
        // upstream patch, the bridge would print "abortAll not
        // registered" to stderr; the call still returns.
    }

    func test_b_closeConnection_isRegisteredAndSafeNoOp() {
        // With no remote connection established (no init1/init2 has run
        // yet in alphabetical order), closing must be a clean no-op:
        //   - status != -1 proves the `closeConnection` OCaml callback is
        //     actually registered in the vendored blob (a stale blob would
        //     return the -1 "not registered" sentinel).
        //   - status == 0 is the "ok, nothing to close" result.
        let status = unison_bridge_close_connection()
        XCTAssertNotEqual(status, -1,
            "closeConnection callback missing from blob — rebuild with patches/0002")
        XCTAssertEqual(status, 0, "expected clean no-op close, got \(status)")
    }

    /// connection_end / connection_cancel are now status-returning (findings
    /// 1 & 2). With no pending preconnection (no init1 with a prompt has run in
    /// alphabetical order):
    ///   - connection_end reports -1 ("nothing to finalize"), NOT a false 0.
    ///   - connection_cancel reports 0 (cancelling nothing is an idempotent
    ///     success), so an abandoned connect with no live preconnection resolves
    ///     cleanly. The success (0) and OCaml-exception (2) real-preconnection
    ///     paths are exercised by the live matrix, not this in-process unit.
    func test_b_connectionEnd_noPreconn_reportsNothingToFinalize() {
        XCTAssertEqual(unison_bridge_connection_end(), -1,
            "connection_end with no preconnection must report -1, not a false success")
    }

    func test_b_connectionCancel_noPreconn_isIdempotentSuccess() {
        XCTAssertEqual(unison_bridge_connection_cancel(), 0,
            "cancelling with nothing pending must be a benign success (0)")
    }

    // MARK: - End-to-end init1 + init2 against a controlled fixture
    //
    // Tests in this section depend on running AFTER test_b_* so the
    // "no state loaded" assertions above pass. After init2 completes
    // here, g_ri_count is non-zero — any test that assumes "no state
    // loaded" must run earlier in alphabetical order.

    /// Drives init1 + init2 against a freshly-built temp profile +
    /// temp replica directories, then verifies the marshaled
    /// `[StateItem]` array reflects the on-disk differences:
    ///
    ///   A/ contains  "only-in-a.txt"        → leftOnly file
    ///   B/ contains  "only-in-b.txt"        → rightOnly file
    ///   Both contain "shared-same.txt"      → unchanged (not in items)
    ///   Both contain "shared-diff.txt"      → different content
    ///
    /// Expectations:
    ///   - 3 items total (only-in-a, only-in-b, shared-diff)
    ///   - left/right status fields populated per Unison conventions
    ///   - direction strings parseable by DirectionVisual (`---->`,
    ///     `<----`, etc.)
    ///   - path strings non-empty and Unicode-protect-survivable
    func test_c_init2Marshaling_producesWellFormedItems() throws {
        let fixture = try IntegrationFixture(name: "marshaling")
        try fixture.populate(
            aFiles: ["only-in-a.txt": "alpha\n",
                     "shared-same.txt": "same\n",
                     "shared-diff.txt": "version a\n"],
            bFiles: ["only-in-b.txt": "beta\n",
                     "shared-same.txt": "same\n",
                     "shared-diff.txt": "version b\n"]
        )

        let init2Done = expectation(description: "init2 complete")
        var capturedItems: [StateItem] = []

        UnisonBridge.installInit1CompleteHandler { needsPrompt in
            // Local-only profile — should never need an SSH prompt.
            // If it does, our fixture is misconfigured.
            XCTAssertFalse(needsPrompt, "local-only profile shouldn't need prompts")
            unison_bridge_init2()
        }
        UnisonBridge.installInit2CompleteHandler { items in
            capturedItems = items
            init2Done.fulfill()
        }

        fixture.profileName.withCString { unison_bridge_init1($0) }
        wait(for: [init2Done], timeout: 15.0)

        // Three rows: only-in-a, only-in-b, shared-diff.
        // shared-same is unchanged, not reported.
        let pathsByRow = Dictionary(uniqueKeysWithValues:
            capturedItems.enumerated().map { ($1.path, $0) })
        XCTAssertEqual(capturedItems.count, 3,
                       "expected 3 items, got paths: \(capturedItems.map(\.path))")
        XCTAssertNotNil(pathsByRow["only-in-a.txt"])
        XCTAssertNotNil(pathsByRow["only-in-b.txt"])
        XCTAssertNotNil(pathsByRow["shared-diff.txt"])

        // Every item has structural sanity.
        for item in capturedItems {
            XCTAssertFalse(item.path.isEmpty, "empty path: \(item)")
            XCTAssertFalse(item.direction.isEmpty,
                           "empty direction for \(item.path)")
            // Direction must be one of OCaml's known strings or empty.
            // DirectionVisual handles unknown direction with a fall-
            // through, but the marshaling layer should hand us a
            // known one for these fixture cases.
            let known = ["---->", "<----", "<-?->", "<-M->"]
            XCTAssertTrue(known.contains(item.direction),
                          "unexpected direction '\(item.direction)' for \(item.path)")
            // fileType for ordinary files comes back as lowercase
            // "file" — pinned here so a future upstream casing change
            // would surface as a test failure (the GUI displays this
            // string verbatim in the Type column).
            XCTAssertEqual(item.fileType.lowercased(), "file",
                           "expected file type for \(item.path), got \(item.fileType)")
            // sizeBytes ≥ 0. Our fixture files are tiny.
            XCTAssertGreaterThanOrEqual(item.sizeBytes, 0)
        }

        // The directional semantics for "exists only in A" should
        // propagate from A to B: direction = "---->" (right arrow,
        // first → second). Same for the mirror case.
        if let row = pathsByRow["only-in-a.txt"] {
            XCTAssertEqual(capturedItems[row].direction, "---->",
                           "only-in-a should propagate first → second")
            XCTAssertEqual(capturedItems[row].left, "Created",
                           "only-in-a should be Created on the first side")
        }
        if let row = pathsByRow["only-in-b.txt"] {
            XCTAssertEqual(capturedItems[row].direction, "<----",
                           "only-in-b should propagate second → first")
            XCTAssertEqual(capturedItems[row].right, "Created",
                           "only-in-b should be Created on the second side")
        }
    }

    /// **Re-entrance test**: install a status handler that calls back
    /// into the bridge from the handler body. The 3-worker design in
    /// `callbackThreadCreate` exists specifically so this doesn't
    /// deadlock — with a single OCaml worker, the inner bridge call
    /// would wait for a worker that's blocked on the outer status
    /// callback.
    ///
    /// We trigger the outer status via `unison_bridge_test_status`
    /// (synthetic — no OCaml round-trip needed; just invokes the
    /// registered handler synchronously). The handler hops to main
    /// via the trampoline, where we then call `unison_bridge_get_version`
    /// (a real Swift→OCaml round-trip). If the worker pool design is
    /// right, both complete; if not, this times out.
    func test_d_reentrance_handlerCanCallBackIntoBridge() throws {
        let handlerRan = expectation(description: "outer status handler ran")
        var innerVersion: String?

        UnisonBridge.installStatusHandler { _ in
            // Re-enter the bridge from inside the status-handler
            // callback. If we deadlock, the wait below times out.
            if let v = unison_bridge_get_version() {
                innerVersion = String(cString: v)
            }
            handlerRan.fulfill()
        }

        unison_bridge_test_status("re-entrance smoke test")
        wait(for: [handlerRan], timeout: 5.0)

        // Restore the AppDelegate's status handler so subsequent
        // tests / live runs aren't broken. (The test bundle hosts
        // into the running app, so swapping the global handler is
        // visible everywhere.)
        UnisonBridge.installStatusHandler { _ in /* swallow */ }

        XCTAssertNotNil(innerVersion,
                        "inner unison_bridge_get_version returned nil — bridge deadlocked or failed?")
        XCTAssertTrue(innerVersion?.contains("ocaml") == true,
                      "version string from re-entrant call malformed: \(innerVersion ?? "<nil>")")
    }
}

// MARK: - Integration fixture helper
//
// Builds a tiny throwaway profile + replica pair under
// /tmp/unison-ui-mac-itest/<run-uuid>/<name>/ so the marshaling test
// has known, isolated content. Cleans up in deinit (tests don't see
// a tearDown call after init2 anyway, so deinit on the local var is
// the cleanup hook).

private final class IntegrationFixture {
    let aRoot: URL
    let bRoot: URL
    let profileURL: URL
    let profileName: String

    init(name: String) throws {
        let runRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unison-ui-mac-itest")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let baseName = "\(name)-\(UUID().uuidString.prefix(8))"
        self.aRoot = runRoot.appendingPathComponent("a")
        self.bRoot = runRoot.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: aRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bRoot, withIntermediateDirectories: true)

        // Profile must live in the Unison directory so init1 finds it by
        // basename. Under XCTest that directory is an isolated temp dir
        // (AppDelegate redirects $UNISON before bridge startup when hosted by
        // XCTest), so this never lands among the user's real profiles. The
        // UUID-suffixed name is belt-and-suspenders. Cleaned up in deinit.
        guard let unisonDir = unison_bridge_unison_directory().map({ String(cString: $0) }) else {
            throw IntegrationFixtureError.unisonDirectoryUnavailable
        }
        self.profileName = "uimac-itest-\(baseName)"
        self.profileURL = URL(fileURLWithPath: unisonDir)
            .appendingPathComponent("\(profileName).prf")
        let prfText = """
            # auto-generated integration test fixture; safe to delete
            root = \(aRoot.path)
            root = \(bRoot.path)
            batch = true
            """
        try prfText.write(to: profileURL, atomically: true, encoding: .utf8)
    }

    func populate(aFiles: [String: String], bFiles: [String: String]) throws {
        for (name, content) in aFiles {
            try content.write(to: aRoot.appendingPathComponent(name),
                              atomically: true, encoding: .utf8)
        }
        for (name, content) in bFiles {
            try content.write(to: bRoot.appendingPathComponent(name),
                              atomically: true, encoding: .utf8)
        }
    }

    deinit {
        // Best-effort cleanup. If a test crashed mid-run we'll leave
        // artifacts under /tmp/unison-ui-mac-itest/ — those auto-purge
        // on reboot or manually with `rm -rf /tmp/unison-ui-mac-itest`.
        try? FileManager.default.removeItem(at: profileURL)
        try? FileManager.default.removeItem(at: aRoot.deletingLastPathComponent())
        // Unison may have written archive files under the Unison
        // directory keyed off the roots — those are cheap to leave
        // and the user's `Reset Archives` button can clean them up.
    }

    enum IntegrationFixtureError: Error {
        case unisonDirectoryUnavailable
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

    /// Concurrent callers into the single-slot handoff. Regression guard for
    /// the termination deadlock: the main thread (applicationWillTerminate)
    /// and the connect queue (prompt loop) both call run_on_ocaml_thread at
    /// once. The pre-fix bridge shared one condvar across two mutexes and
    /// lost wakeups under exactly this contention, wedging the app on quit.
    ///
    /// This hammers a read-only entry point from many threads simultaneously;
    /// with the bug it can hang (caught by the expectation timeout), with the
    /// per-request-condvar fix every call must complete.
    func test_concurrentCallers_allComplete() {
        let callers = 16
        let iterationsPerCaller = 200
        let done = expectation(description: "all concurrent callers finish")
        done.expectedFulfillmentCount = callers

        for _ in 0..<callers {
            DispatchQueue.global().async {
                for _ in 0..<iterationsPerCaller {
                    // Non-null result also confirms no wakeup was lost mid-call.
                    XCTAssertNotNil(unison_bridge_get_version())
                }
                done.fulfill()
            }
        }

        // Generous bound: 16×200 = 3200 handoffs complete in well under a
        // second when healthy. A hang means the deadlock has regressed.
        wait(for: [done], timeout: 30)
    }
}
