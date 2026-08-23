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
            // connection_prompt has no preconnection here → must report NONE
            // (not AVAILABLE), concurrently, without crashing.
            var pptr: UnsafePointer<CChar>? = nil
            let pr = unison_bridge_connection_prompt(&pptr)
            if v != versionRef || d != dirRef || pr != UNISON_PROMPT_NONE || pptr != nil {
                lock.lock(); mismatches += 1; lock.unlock()
            }
        }
        XCTAssertEqual(mismatches, 0,
            "concurrent callers saw corrupted/unstable return content")
    }

    // MARK: - Per-row roots (require init1+init2 to have run)

    func test_b_riOps_failGracefullyWhenNoStateLoaded() {
        // No init1/init2 has run in this test, so g_ri_count is 0. An out-of-
        // range row is a validation failure (INVALID) — no mutation, no crash,
        // and NOT the DIRTY result that would force restart-required.
        var buf = [CChar](repeating: 0, count: 16)
        XCTAssertEqual(unison_bridge_ri_set_to_remote(0, &buf, buf.count, nil), UNISON_OP_INVALID)
        XCTAssertEqual(unison_bridge_ri_set_to_local(99999, &buf, buf.count, nil), UNISON_OP_INVALID)
        XCTAssertEqual(unison_bridge_ri_set_skip(-1, &buf, buf.count, nil), UNISON_OP_INVALID)
        XCTAssertEqual(unison_bridge_ri_set_merge(0, &buf, buf.count, nil), UNISON_OP_INVALID)
        // On a non-OK result the out buffer must be the empty string, never stale.
        XCTAssertEqual(String(cString: buf), "")
    }

    func test_b_ignoreOps_failGracefullyWhenNoStateLoaded() {
        // Same guard as the ri-set ops: with no reconcile state, the row is out
        // of range → INVALID (no mutation), never DIRTY. Calling these is safe
        // even when no profile is open (e.g. a stale menu item is invoked).
        XCTAssertEqual(unison_bridge_ignore_path(0), UNISON_OP_INVALID)
        XCTAssertEqual(unison_bridge_ignore_ext(99999), UNISON_OP_INVALID)
        XCTAssertEqual(unison_bridge_ignore_name(-1), UNISON_OP_INVALID)
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
        //
        // Blocker 5: abort now returns a status. With the `abortAll` callback
        // registered (current blob), the flag-flip succeeds → OK. A non-OK here
        // would mean the callback is missing (stale blob) or raised — either way
        // the caller must not claim cancellation was requested.
        XCTAssertEqual(unison_bridge_abort_sync(), UNISON_BRIDGE_OK,
            "abort dispatch should succeed (abortAll registered); non-OK = stale blob")
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

    /// **Finding #1 — GC rooting.** `reloadTable` reads a progress `value` that
    /// must stay rooted across a second, allocating callback. This drives the
    /// `unison_bridge_test_reload_under_gc` probe, which reproduces reloadTable's
    /// CAMLlocal2 rooting against the real per-row progress/bytes callbacks but
    /// forces a moving minor collection between obtaining the progress value and
    /// reading its `String_val`. With the rooting present the value is relocated
    /// and the read stays valid; without it the read would hit freed memory
    /// (crash or garbage). Runs as `test_e_` so it executes AFTER the "no state
    /// loaded" assertions and after `test_c` — it populates reconcile state.
    func test_e_reloadRow_progressValueSurvivesCollection() throws {
        let fixture = try IntegrationFixture(name: "gcroot")
        try fixture.populate(
            aFiles: ["only-in-a.txt": "alpha\n", "shared-diff.txt": "a\n"],
            bFiles: ["only-in-b.txt": "beta\n",  "shared-diff.txt": "b\n"]
        )

        let scanned = expectation(description: "init2 complete for gc test")
        var rowCount = 0
        UnisonBridge.installInit1CompleteHandler { needsPrompt in
            XCTAssertFalse(needsPrompt, "local-only profile shouldn't need prompts")
            _ = unison_bridge_init2()
        }
        UnisonBridge.installInit2CompleteHandler { items in
            rowCount = items.count
            scanned.fulfill()
        }
        fixture.profileName.withCString { _ = unison_bridge_init1($0) }
        wait(for: [scanned], timeout: 15.0)
        XCTAssertGreaterThan(rowCount, 0, "fixture should have produced rows")

        // Probe every row repeatedly (heap-layout dependent regressions may only
        // trip on some iterations). Surviving with a readable string each time
        // is the assertion.
        for _ in 0..<10 {
            for row in 0..<rowCount {
                var buf = [CChar](repeating: 0, count: 1024)
                let ok = unison_bridge_test_reload_under_gc(Int32(row), &buf, buf.count)
                XCTAssertTrue(ok, "reload-under-gc probe failed for row \(row)")
                // Decoding a NUL-terminated C string that survived relocation;
                // a dangling read would crash above or yield garbage here.
                _ = String(cString: buf)
            }
        }
    }

    /// Drive a local fixture through init1 + init2 and return the row count.
    /// The bridge completion handlers are process-global and installed ONCE by
    /// the host app at startup (`installPermanentBridgeHandlers`), NOT per
    /// session — so overwriting them here replaces the app's handlers for the
    /// rest of the process. That's acceptable in this hosted-XCTest bundle
    /// because tests run sequentially and each test that needs a handler installs
    /// its own; a test that relies on the app's real routing must not run after
    /// one that clobbered it. (Where a test replaces a handler with an XCTFail
    /// stub, it restores a benign one before returning.)
    @discardableResult
    private func scanFixtureRows(_ fixture: IntegrationFixture) -> Int {
        scanFixtureItems(fixture).count
    }

    /// Like `scanFixtureRows` but returns the emitted `[StateItem]` (row order ==
    /// g_ri_roots index), so tests can map path→row and record each row's scanned
    /// recommendation direction + changedFromDefault (false right after a scan).
    private func scanFixtureItems(_ fixture: IntegrationFixture) -> [StateItem] {
        let scanned = expectation(description: "init2 complete for fixture")
        var captured: [StateItem] = []
        UnisonBridge.installInit1CompleteHandler { needsPrompt in
            XCTAssertFalse(needsPrompt, "local-only profile shouldn't need prompts")
            _ = unison_bridge_init2()
        }
        UnisonBridge.installInit2CompleteHandler { items in
            captured = items
            scanned.fulfill()
        }
        fixture.profileName.withCString { _ = unison_bridge_init1($0) }
        wait(for: [scanned], timeout: 15.0)
        return captured
    }

    /// **Blocker 4 — mutation-stage failure classification.** Inject a raise at a
    /// SPECIFIC callback ordinal (not merely the first) and prove a per-row
    /// direction mutation reports DIRTY whether the raise strikes at the setter
    /// (stage 1) or the direction readback (stage 2) — both are at/after mutation
    /// — while the engine survives for a subsequent clean set.
    func test_f_rowMutation_dirtyAtEachMutationStage() throws {
        let fixture = try IntegrationFixture(name: "mutfail")
        try fixture.populate(
            aFiles: ["a.txt": "x\n", "both.txt": "a\n"],
            bFiles: ["b.txt": "y\n", "both.txt": "b\n"])
        let rows = scanFixtureRows(fixture)
        XCTAssertGreaterThan(rows, 0)
        var buf = [CChar](repeating: 0, count: 16)

        // Stage 1: the setter (1st wrapper call) raises → DIRTY.
        unison_bridge_test_force_raise_at_ordinal(1)
        XCTAssertEqual(unison_bridge_ri_set_to_remote(0, &buf, buf.count, nil), UNISON_OP_FAILED_DIRTY)
        XCTAssertEqual(String(cString: buf), "", "no stale direction handed back on failure")

        // Stage 2: the setter runs, the direction readback (2nd wrapper) raises →
        // still DIRTY (the row WAS mutated; we just can't read the new direction).
        unison_bridge_test_force_raise_at_ordinal(2)
        XCTAssertEqual(unison_bridge_ri_set_to_local(0, &buf, buf.count, nil), UNISON_OP_FAILED_DIRTY)

        // Worker survived: a clean set now succeeds and returns a direction.
        unison_bridge_test_force_raise_at_ordinal(0)
        XCTAssertEqual(unison_bridge_ri_set_to_remote(0, &buf, buf.count, nil), UNISON_OP_OK)
        XCTAssertFalse(String(cString: buf).isEmpty)

        // Ignore: the path read (1st wrapper) is read-only → CLEAN (nothing
        // changed); a raise at the pattern-persist step (2nd wrapper) is DIRTY.
        unison_bridge_test_force_raise_at_ordinal(1)
        XCTAssertEqual(unison_bridge_ignore_path(0), UNISON_OP_FAILED_CLEAN)
        unison_bridge_test_force_raise_at_ordinal(2)
        XCTAssertEqual(unison_bridge_ignore_ext(0), UNISON_OP_FAILED_DIRTY)
        unison_bridge_test_force_raise_at_ordinal(0)
    }

    /// **Blocker 1 + 2 — failed publication rolls back roots and reports
    /// terminally.** A first scan publishes N roots. A second scan whose state
    /// emission fails (forced raise at emit's first accessor) must: (a) deliver
    /// the terminal async scan-failure callback rather than the completion
    /// handler, and (b) leave the previously-published roots intact (rollback).
    func test_g_failedPublish_rollsBackRootsAndReportsTerminal() throws {
        let fixture = try IntegrationFixture(name: "rollback")
        try fixture.populate(
            aFiles: ["a.txt": "x\n", "both.txt": "a\n"],
            bFiles: ["b.txt": "y\n", "both.txt": "b\n"])
        let rows = scanFixtureRows(fixture)
        XCTAssertGreaterThan(rows, 0)
        XCTAssertEqual(Int(unison_bridge_test_ri_count()), rows,
                       "a successful scan publishes its roots")

        let failed = expectation(description: "terminal async scan failure delivered")
        UnisonBridge.installInit2CompleteHandler { _ in
            XCTFail("init2 completion must NOT fire when state emission fails")
        }
        UnisonBridge.installScanFailedHandler { failed.fulfill() }

        // Ordinal 2: wrapper #1 is init2's own dispatch (must succeed so the scan
        // launches); wrapper #2 is emit_state_items' first accessor — force THAT
        // to raise so publication fails after the scan completes.
        unison_bridge_test_force_raise_at_ordinal(2)
        _ = unison_bridge_init2()
        wait(for: [failed], timeout: 15.0)
        unison_bridge_test_force_raise_at_ordinal(0)

        XCTAssertEqual(Int(unison_bridge_test_ri_count()), rows,
            "a failed publication must preserve the previously-published roots (rollback)")
        // Reinstall a benign init2 handler so later suites aren't tripped by the
        // XCTFail stub above.
        UnisonBridge.installInit2CompleteHandler { _ in }
    }

    /// **Ignore publication fix.** A successful Ignore must deliver its fresh rows
    /// through the DEDICATED ignore consumer (never the scan/init2 handler) and
    /// update g_ri_roots to match. Asserts: the ignore handler fires with the
    /// filtered rows, the init2 handler does NOT fire, and the published root
    /// count matches the delivered row count (rows and roots agree).
    func test_h_successfulIgnore_deliversViaIgnoreHandler_rootsMatchRows() throws {
        let fixture = try IntegrationFixture(name: "ignoreok")
        try fixture.populate(
            aFiles: ["only-a.txt": "x\n", "both.txt": "a\n"],
            bFiles: ["only-b.txt": "y\n", "both.txt": "b\n"])
        let rows = scanFixtureRows(fixture)
        XCTAssertGreaterThan(rows, 1)

        let delivered = expectation(description: "ignore completion delivered")
        var ignoredRows: [StateItem] = []
        UnisonBridge.installInit2CompleteHandler { _ in
            XCTFail("scan/init2 handler must NOT fire for an Ignore completion")
        }
        UnisonBridge.installIgnoreCompleteHandler { items in
            ignoredRows = items
            delivered.fulfill()
        }
        // Ignore row 0's exact path → that row is filtered out of theState.
        let result = unison_bridge_ignore_path(0)
        XCTAssertEqual(result, UNISON_OP_OK)
        wait(for: [delivered], timeout: 15.0)

        XCTAssertEqual(ignoredRows.count, rows - 1,
                       "the ignored row should be dropped from the delivered set")
        XCTAssertEqual(Int(unison_bridge_test_ri_count()), ignoredRows.count,
                       "published roots must match the delivered rows")
        UnisonBridge.installInit2CompleteHandler { _ in }
        UnisonBridge.installIgnoreCompleteHandler { _ in }
    }

    /// **emit hardening — missing consumer.** With no completion consumer, emit
    /// must NOT install the candidate roots: the previous publication (rows +
    /// roots) is preserved. Exercised via the Debug suppress-consumer hook; the
    /// Ignore mutated theState first, so the result is DIRTY (engine moved) while
    /// the roots stay at the old count.
    func test_i_emitMissingConsumer_preservesOldPublication() throws {
        let fixture = try IntegrationFixture(name: "noconsumer")
        try fixture.populate(
            aFiles: ["only-a.txt": "x\n", "both.txt": "a\n"],
            bFiles: ["only-b.txt": "y\n", "both.txt": "b\n"])
        let rows = scanFixtureRows(fixture)
        XCTAssertGreaterThan(rows, 0)

        unison_bridge_test_suppress_consumer(1)
        let result = unison_bridge_ignore_path(0)
        unison_bridge_test_suppress_consumer(0)

        XCTAssertEqual(result, UNISON_OP_FAILED_DIRTY,
            "publish with no consumer must fail (DIRTY — mutation already happened)")
        XCTAssertEqual(Int(unison_bridge_test_ri_count()), rows,
            "no consumer → roots not installed → previous publication preserved")
    }

    /// **emit hardening — allocation failure.** A failed strdup mid-marshal must
    /// free the partial output + candidate roots and preserve the previous
    /// publication (roots unchanged).
    func test_j_emitStrdupFailure_preservesOldPublication() throws {
        let fixture = try IntegrationFixture(name: "strdupfail")
        try fixture.populate(
            aFiles: ["only-a.txt": "x\n", "both.txt": "a\n"],
            bFiles: ["only-b.txt": "y\n", "both.txt": "b\n"])
        let rows = scanFixtureRows(fixture)
        XCTAssertGreaterThan(rows, 0)

        // Fail the first strdup in the Ignore's emit marshal.
        unison_bridge_test_fail_strdup_at(1)
        let result = unison_bridge_ignore_path(0)
        unison_bridge_test_fail_strdup_at(0)

        XCTAssertEqual(result, UNISON_OP_FAILED_DIRTY,
            "a failed allocation during publish must fail (DIRTY)")
        XCTAssertEqual(Int(unison_bridge_test_ri_count()), rows,
            "allocation failure must preserve the previously-published roots")
        UnisonBridge.installInit2CompleteHandler { _ in }
        UnisonBridge.installIgnoreCompleteHandler { _ in }
    }

    // MARK: - Finding #2: per-row Revert engine inverse

    private func rowOf(_ path: String, _ items: [StateItem]) -> Int? {
        items.firstIndex { $0.path == path }
    }

    /// Revert a row via the bridge, returning (result, restored direction, changed).
    private func revert(_ row: Int) -> (unison_op_result_t, String, Bool) {
        var buf = [CChar](repeating: 0, count: 16)
        var changed = false
        let r = unison_bridge_ri_revert(Int32(row), &buf, buf.count, &changed)
        return (r, String(cString: buf), changed)
    }

    /// A fresh scan. Rows:
    ///   only-a → "---->", only-b → "<----"
    ///   both.txt    → conflict "<-?->", DISTINCT mtimes (A older, B newer) so
    ///                 Force resolves to a definite side (Force-changes case)
    ///   both-eq.txt → conflict "<-?->", EQUAL mtimes so Force Older/Newer are
    ///                 ignored by the engine (deterministic Force-equals-default)
    private func makeReconFixture(_ name: String) throws -> ([StateItem], IntegrationFixture) {
        let fixture = try IntegrationFixture(name: name)
        try fixture.populate(
            aFiles: ["only-a.txt": "alpha\n", "both.txt": "a-side\n", "both-eq.txt": "a-eq\n"],
            bFiles: ["only-b.txt": "beta\n",  "both.txt": "b-side\n", "both-eq.txt": "b-eq\n"])
        func setMtime(_ path: String, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        let older = Date(timeIntervalSince1970: 1_000_000_000)
        let newer = Date(timeIntervalSince1970: 1_000_100_000)
        let same  = Date(timeIntervalSince1970: 1_000_050_000)
        try setMtime(fixture.aRoot.appendingPathComponent("both.txt").path, older)
        try setMtime(fixture.bRoot.appendingPathComponent("both.txt").path, newer)
        try setMtime(fixture.aRoot.appendingPathComponent("both-eq.txt").path, same)
        try setMtime(fixture.bRoot.appendingPathComponent("both-eq.txt").path, same)
        let items = scanFixtureItems(fixture)
        return (items, fixture)
    }

    /// Every direction action, applied then reverted, restores the exact scanned
    /// recommendation. Each action's returned (direction, changedFromDefault) is
    /// asserted BEFORE reverting, so the test cannot pass through a no-op
    /// mutation. Includes an action-equals-default case (Second on a row whose
    /// default is already ---->) and a deterministic Force-equals-default case
    /// (Force on the EQUAL-mtime conflict row `both-eq.txt`, where the engine
    /// ignores Older/Newer → the direction stays at the default).
    func test_k_actionsThenRevert_restoreRecommendation() throws {
        let (items, _) = try makeReconFixture("revert6")
        guard let onlyA = rowOf("only-a.txt", items) else { return XCTFail("no only-a row") }
        XCTAssertEqual(items[onlyA].direction, "---->", "only-a recommendation")
        XCTAssertFalse(items[onlyA].changedFromDefault, "fresh scan row is unchanged")

        // (action, expected post-action direction, expected changed) on only-a.
        let cases: [(DirectionAction, String, Bool)] = [
            (.toFirst, "<----", true),    // divergent
            (.toSecond, "---->", false),  // action equals the default → not changed
            (.skip,    "<-?->", true),
            (.merge,   "<-M->", true),
        ]
        for (action, expectDir, expectChanged) in cases {
            let (sr, sdir, schanged) = action.invoke(row: Int32(onlyA))
            XCTAssertEqual(sr, UNISON_OP_OK, "\(action) should apply")
            XCTAssertEqual(sdir, expectDir, "\(action) should yield \(expectDir)")
            XCTAssertEqual(schanged, expectChanged, "\(action) changed flag")
            let (rr, rdir, rchanged) = revert(onlyA)
            XCTAssertEqual(rr, UNISON_OP_OK, "revert after \(action)")
            XCTAssertEqual(rdir, "---->", "revert after \(action) restores the recommendation")
            XCTAssertFalse(rchanged, "reverted row is back to default")
        }

        // Force that ACTUALLY changes direction: on the conflict row with
        // distinct mtimes, Force resolves to a definite side (away from <-?->).
        guard let both = rowOf("both.txt", items) else { return XCTFail("no both row") }
        XCTAssertEqual(items[both].direction, "<-?->", "both-sides-differ is a conflict")
        for action in [DirectionAction.forceOlder, .forceNewer] {
            let (sr, sdir, schanged) = action.invoke(row: Int32(both))
            XCTAssertEqual(sr, UNISON_OP_OK)
            XCTAssertNotEqual(sdir, "<-?->", "\(action) with distinct mtimes must change the direction")
            XCTAssertTrue(schanged, "\(action) diverges from the conflict default")
            let (rr, rdir, rchanged) = revert(both)
            XCTAssertEqual(rr, UNISON_OP_OK)
            XCTAssertEqual(rdir, "<-?->", "revert after \(action) restores the conflict recommendation")
            XCTAssertFalse(rchanged)
        }

        // Deterministic Force-EQUALS-default: on the EQUAL-mtime conflict row the
        // engine ignores Older/Newer, so the direction stays at the default and
        // changed stays false — and revert is a clean OK no-op.
        guard let bothEq = rowOf("both-eq.txt", items) else { return XCTFail("no both-eq row") }
        XCTAssertEqual(items[bothEq].direction, "<-?->", "equal-mtime differ is still a conflict")
        for action in [DirectionAction.forceOlder, .forceNewer] {
            let (sr, sdir, schanged) = action.invoke(row: Int32(bothEq))
            XCTAssertEqual(sr, UNISON_OP_OK)
            XCTAssertEqual(sdir, "<-?->", "\(action) with equal mtimes leaves the default")
            XCTAssertFalse(schanged, "\(action)-equals-default reports not changed")
            let (rr, rdir, rchanged) = revert(bothEq)
            XCTAssertEqual(rr, UNISON_OP_OK)
            XCTAssertEqual(rdir, "<-?->")
            XCTAssertFalse(rchanged)
        }
    }

    /// Skip over an ORIGINAL conflict: both the default and the skip render as
    /// "<-?->", but the engine sees skip-requested as changed (structural
    /// compare), and revert restores the ORIGINAL conflict (changed=false).
    func test_l_skipOverConflict_restoresOriginalConflict() throws {
        let (items, _) = try makeReconFixture("revertconflict")
        guard let both = rowOf("both.txt", items) else { return XCTFail("no both row") }
        XCTAssertEqual(items[both].direction, "<-?->", "both-sides-differ should be a conflict")
        XCTAssertFalse(items[both].changedFromDefault)

        let (sr, sdir, schanged) = DirectionAction.skip.invoke(row: Int32(both))
        XCTAssertEqual(sr, UNISON_OP_OK)
        XCTAssertEqual(sdir, "<-?->", "skip on a conflict still renders <-?->")
        XCTAssertTrue(schanged,
            "skip-requested must be seen as CHANGED even though it renders like the default conflict")

        let (rr, rdir, rchanged) = revert(both)
        XCTAssertEqual(rr, UNISON_OP_OK)
        XCTAssertEqual(rdir, "<-?->", "revert restores the original conflict rendering")
        XCTAssertFalse(rchanged, "revert restores the ORIGINAL conflict (no longer changed)")
    }

    /// Per-row revert building blocks (NOT the window batch loop, which is a
    /// private @MainActor method with no automated UI harness): two independent
    /// rows revert to their own recommendations, and an injected raise on one
    /// row's revert reports DIRTY while the engine/worker survives for the next.
    func test_m_perRowRevert_independentSuccessAndInjectedFailure() throws {
        let (items, _) = try makeReconFixture("revertmulti")
        guard let a = rowOf("only-a.txt", items), let b = rowOf("only-b.txt", items) else {
            return XCTFail("missing rows")
        }
        let defA = items[a].direction, defB = items[b].direction
        // Change both, then revert both — independent successes to each own default.
        XCTAssertEqual(DirectionAction.skip.invoke(row: Int32(a)).result, UNISON_OP_OK)
        XCTAssertEqual(DirectionAction.skip.invoke(row: Int32(b)).result, UNISON_OP_OK)
        XCTAssertEqual(revert(a).1, defA)
        XCTAssertEqual(revert(b).1, defB)

        // Inject a raise at the revert setter (ordinal 1) → DIRTY; engine survives.
        XCTAssertEqual(DirectionAction.skip.invoke(row: Int32(a)).result, UNISON_OP_OK)
        unison_bridge_test_force_raise_at_ordinal(1)
        XCTAssertEqual(revert(a).0, UNISON_OP_FAILED_DIRTY)
        unison_bridge_test_force_raise_at_ordinal(0)
        // A clean revert now works (worker survived).
        XCTAssertEqual(revert(a).0, UNISON_OP_OK)
    }

    /// Exception injection at each revert stage → DIRTY (never a silent no-op /
    /// false changed): the setter (1), direction readback (2), changed readback (3).
    func test_n_revertExceptionAtEachStage_isDirty() throws {
        let (items, _) = try makeReconFixture("revertexn")
        guard let a = rowOf("only-a.txt", items) else { return XCTFail("no only-a row") }
        for ordinal in 1...3 {
            XCTAssertEqual(DirectionAction.skip.invoke(row: Int32(a)).result, UNISON_OP_OK)
            unison_bridge_test_force_raise_at_ordinal(Int32(ordinal))
            XCTAssertEqual(revert(a).0, UNISON_OP_FAILED_DIRTY,
                "a raise at revert stage \(ordinal) must be DIRTY")
            unison_bridge_test_force_raise_at_ordinal(0)
            _ = revert(a)   // clean up to default for the next iteration
        }
    }

    /// An out-of-range row reverts to a no-op INVALID (never DIRTY).
    func test_o_revertInvalidRow_isNoOp() throws {
        _ = try makeReconFixture("revertinvalid")
        XCTAssertEqual(revert(99999).0, UNISON_OP_INVALID)
        XCTAssertEqual(revert(-1).0, UNISON_OP_INVALID)
    }

    /// changedFromDefault is carried by scan emission (all false on a fresh scan)
    /// and by Ignore re-publication after reindexing: a row changed before an
    /// Ignore still reports changed=true in the post-Ignore item set.
    func test_p_changedFromDefault_carriedThroughScanAndIgnoreReindex() throws {
        let (items, _) = try makeReconFixture("revertemit")
        for it in items { XCTAssertFalse(it.changedFromDefault, "fresh scan: nothing changed") }
        guard let onlyA = rowOf("only-a.txt", items),
              let onlyB = rowOf("only-b.txt", items) else { return XCTFail("missing rows") }

        // Change only-a (skip), then Ignore only-b → re-emits the (reindexed) set.
        XCTAssertEqual(DirectionAction.skip.invoke(row: Int32(onlyA)).result, UNISON_OP_OK)

        let republished = expectation(description: "ignore re-publication")
        var afterItems: [StateItem] = []
        UnisonBridge.installIgnoreCompleteHandler { rows in afterItems = rows; republished.fulfill() }
        XCTAssertEqual(unison_bridge_ignore_path(Int32(onlyB)), UNISON_OP_OK)
        wait(for: [republished], timeout: 15.0)
        UnisonBridge.installIgnoreCompleteHandler { _ in }

        // only-b is gone; only-a survives and must still report changed=true at
        // its NEW index.
        guard let a2 = rowOf("only-a.txt", afterItems) else {
            return XCTFail("only-a should survive the ignore of only-b")
        }
        XCTAssertTrue(afterItems[a2].changedFromDefault,
            "a changed row must still report changedFromDefault after reindexing")
        XCTAssertNil(rowOf("only-b.txt", afterItems), "ignored row should be gone")
        // Restore to default so later tests aren't affected by lingering skip.
        _ = revert(a2)
    }

    /// Consolidated engine-level equivalent of the manual Revert smoke: apply a
    /// distinct action to each of three DIFFERENT rows — a plain direction on
    /// `only-a`, Force on the distinct-mtime conflict (`both.txt`, so Force truly
    /// resolves a side), and Skip on the equal-mtime conflict (`both-eq.txt`) —
    /// while leaving `only-b` untargeted. Reverting all three restores each to its
    /// recommendation with changedFromDefault == false, and the restored
    /// direction is exactly what a sync would propagate (the engine's readback).
    ///
    /// This is a bridge/engine test only. It does NOT drive the private
    /// `ReconcileWindowController` batch loop, observe visual badges, or observe
    /// menu greying — those GUI/window behaviors are not automatable here (see
    /// the PR description's automation limitation).
    func test_q_multiRowRevertSmoke_restoresRecommendations() throws {
        let (items, _) = try makeReconFixture("revertsmoke")
        guard let onlyA  = rowOf("only-a.txt", items),
              let both   = rowOf("both.txt", items),
              let bothEq = rowOf("both-eq.txt", items) else { return XCTFail("missing rows") }
        // only-b is deliberately not looked up or touched by this test.
        let defA = items[onlyA].direction, defBoth = items[both].direction
        let defBothEq = items[bothEq].direction

        // Plain direction on only-a.
        let (aR, _, aChanged) = DirectionAction.toFirst.invoke(row: Int32(onlyA))
        XCTAssertEqual(aR, UNISON_OP_OK); XCTAssertTrue(aChanged)
        // Force on the distinct-mtime conflict → resolves to a definite side.
        let (fR, fDir, fChanged) = DirectionAction.forceNewer.invoke(row: Int32(both))
        XCTAssertEqual(fR, UNISON_OP_OK)
        XCTAssertNotEqual(fDir, "<-?->", "Force with distinct mtimes must resolve a side")
        XCTAssertTrue(fChanged)
        // Skip on the equal-mtime conflict.
        let (sR, sDir, sChanged) = DirectionAction.skip.invoke(row: Int32(bothEq))
        XCTAssertEqual(sR, UNISON_OP_OK)
        XCTAssertEqual(sDir, "<-?->"); XCTAssertTrue(sChanged, "skip diverges from the conflict default")

        // Revert all three targeted rows → each restored to its recommendation,
        // no longer changed, and the readback direction is what a sync would use.
        for (row, def) in [(onlyA, defA), (both, defBoth), (bothEq, defBothEq)] {
            let (rr, rdir, rchanged) = revert(row)
            XCTAssertEqual(rr, UNISON_OP_OK)
            XCTAssertEqual(rdir, def, "revert restores the recommendation (sync would propagate this)")
            XCTAssertFalse(rchanged, "reverted row is back to default")
        }

        // Post-Revert eligibility, as SPLIT evidence (not a UI observation):
        //   (a) the engine reports changedFromDefault == false (asserted above);
        //   (b) the pure predicate returns false once no override is present;
        //   (c) code inspection: revertSelectionAction removes the row's override
        //       on success (see ReconcileWindowController), so hasOverride is false
        //       after a real Revert — this test cannot observe that step.
        XCTAssertFalse(RowSelectionRules.isRevertible(changedFromDefault: false, hasOverride: false))

        // only-b: no operation in this test targeted it. Cross-row isolation is
        // guaranteed by the indexed bridge implementation (each op addresses a
        // single g_ri_roots[row]) and the independent per-row tests above — NOT
        // by a live readback here, so no such assertion is made.
    }

    // MARK: - Finding #10: real sync-completion snapshot bridge boundary

    /// Run the REAL snapshot marshaller (over the just-scanned rooted rows) once
    /// and return the delivered (ok, rows). Exercises OCaml accessors → C strdup
    /// → Swift handler — the actual completion path, not `SyncCompletionModel`.
    private func runSyncSnapshotOnce() -> (ok: Bool, rows: [SyncSnapshotRow]) {
        let exp = expectation(description: "sync snapshot delivered")
        var result: (Bool, [SyncSnapshotRow]) = (false, [])
        UnisonBridge.installSyncCompleteHandler { ok, rows in result = (ok, rows); exp.fulfill() }
        unison_bridge_test_run_sync_snapshot()
        wait(for: [exp], timeout: 5.0)
        return result
    }

    func test_g_syncSnapshot_realBoundary_okExactRowsPlausibleFields() throws {
        let fixture = try IntegrationFixture(name: "syncsnap")
        try fixture.populate(aFiles: ["a.txt": "x\n", "both.txt": "a\n"],
                             bFiles: ["b.txt": "y\n", "both.txt": "b\n"])
        let items = scanFixtureItems(fixture)
        XCTAssertGreaterThan(items.count, 0)
        let (ok, rows) = runSyncSnapshotOnce()
        XCTAssertTrue(ok, "real marshaller must deliver ok=true")
        XCTAssertEqual(rows.count, items.count, "exact row count")
        for r in rows {
            // `unisonRiToDetails` always emits at least the row's path.
            XCTAssertFalse(r.details.isEmpty, "details is populated")
        }
        UnisonBridge.installSyncCompleteHandler { _, _ in }   // restore benign
    }

    func test_g_syncSnapshot_accessorRaiseEachFieldAfterFirstRow_unavailableNoPartial() throws {
        let fixture = try IntegrationFixture(name: "syncsnapaccessor")
        try fixture.populate(aFiles: ["a.txt": "x\n", "c.txt": "z\n"],
                             bFiles: ["b.txt": "y\n", "c.txt": "zz\n"])
        let items = scanFixtureItems(fixture)
        XCTAssertGreaterThan(items.count, 1)
        // Raise each accessor field in turn AT ROW 1 (after row 0 was fully
        // marshalled): 0 = progress, 1 = details, 2 = bytes.
        for field: Int32 in 0...2 {
            unison_bridge_test_fail_snapshot_accessor_at(1, field)
            let (ok, rows) = runSyncSnapshotOnce()
            XCTAssertFalse(ok, "field \(field) raise → results unavailable")
            XCTAssertEqual(rows.count, 0, "field \(field): no partial rows published")
            // Runtime still usable: a clean run now succeeds.
            let (ok2, rows2) = runSyncSnapshotOnce()
            XCTAssertTrue(ok2, "field \(field): clean snapshot after the failure")
            XCTAssertEqual(rows2.count, items.count)
        }
        UnisonBridge.installSyncCompleteHandler { _, _ in }
    }

    /// Run the production array snapshot path (deliver_sync_snapshot_array —
    /// the exact syncComplete boundary) once, over a fresh array built from the
    /// rooted scan rows.
    private func runSyncSnapshotFromArrayOnce() -> (ok: Bool, rows: [SyncSnapshotRow]) {
        let exp = expectation(description: "array snapshot delivered")
        var result: (Bool, [SyncSnapshotRow]) = (false, [])
        UnisonBridge.installSyncCompleteHandler { ok, rows in result = (ok, rows); exp.fulfill() }
        unison_bridge_test_run_sync_snapshot_from_array()
        wait(for: [exp], timeout: 5.0)
        return result
    }

    /// **Blocker B6 — GC rooting in the sync-completion snapshot.** The array
    /// path must survive a minor collection that relocates the young stateItem
    /// array mid-iteration. Verified red on `4359c7a`: `syncComplete` captured
    /// `state` by value in the marshaller block, so forcing a GC between rows
    /// read the pre-move array address (garbage row data / crash). Fixed by
    /// capturing `&state` and dereferencing per row.
    func test_g_syncSnapshot_arrayPath_survivesForcedMinorGCBetweenRows() throws {
        let fixture = try IntegrationFixture(name: "syncsnapgc")
        // Need more than one row so a collection actually fires BETWEEN rows.
        try fixture.populate(
            aFiles: ["a1.txt": "x\n", "a2.txt": "y\n", "both.txt": "a\n"],
            bFiles: ["b1.txt": "p\n", "both.txt": "b\n"])
        let items = scanFixtureItems(fixture)
        XCTAssertGreaterThan(items.count, 1, "need >1 row to GC between rows")

        // Baseline through the production array path, no forced GC.
        let baseline = runSyncSnapshotFromArrayOnce()
        XCTAssertTrue(baseline.ok)
        XCTAssertEqual(baseline.rows.count, items.count)

        // Force a minor collection between every row: the rooted array relocates,
        // yet the marshaller must still read correct data.
        unison_bridge_test_force_gc_between_snapshot_rows(true)
        defer { unison_bridge_test_force_gc_between_snapshot_rows(false) }
        let underGC = runSyncSnapshotFromArrayOnce()
        XCTAssertTrue(underGC.ok, "snapshot ok under forced relocation")
        XCTAssertEqual(underGC.rows.count, items.count, "exact rows under forced GC")
        XCTAssertEqual(underGC.rows.map(\.details), baseline.rows.map(\.details),
                       "row details identical under forced relocation")
        XCTAssertEqual(underGC.rows.map(\.progress), baseline.rows.map(\.progress),
                       "row progress identical under forced relocation")
        UnisonBridge.installSyncCompleteHandler { _, _ in }   // restore benign
    }

    /// The REAL public completion path end-to-end: `unison_bridge_synchronize()`
    /// → vendored `unisonSynchronize` → `do_unisonSynchronize` → `syncComplete
    /// !theState` (patch 0005) → C marshaller → Swift handler. Uses conflict-free
    /// one-sided files so the sync propagates cleanly, and asserts the files
    /// actually moved between roots.
    func test_h_realSync_propagatesFiles_andDeliversSnapshot() throws {
        let fixture = try IntegrationFixture(name: "realsync")
        try fixture.populate(aFiles: ["only-a.txt": "AAA\n"],
                             bFiles: ["only-b.txt": "BBB\n"])
        let scanned = scanFixtureItems(fixture)
        XCTAssertGreaterThan(scanned.count, 0)

        let done = expectation(description: "real syncComplete delivered")
        var deliveries = 0
        var captured: (ok: Bool, rows: [SyncSnapshotRow]) = (false, [])
        UnisonBridge.installSyncCompleteHandler { ok, rows in
            deliveries += 1
            captured = (ok, rows)
            done.fulfill()
        }
        // Invoke the REAL OCaml caller (NOT the test seam).
        XCTAssertEqual(unison_bridge_synchronize(), UNISON_BRIDGE_OK,
                       "synchronize dispatch should launch cleanly")
        wait(for: [done], timeout: 30.0)

        XCTAssertEqual(deliveries, 1, "exactly one completion arrives")
        XCTAssertTrue(captured.ok, "completion is ok=true")
        XCTAssertEqual(captured.rows.count, scanned.count,
                       "snapshot count matches the scanned rows")
        for r in captured.rows { XCTAssertFalse(r.details.isEmpty, "details populated") }
        XCTAssertTrue(captured.rows.contains { $0.progress == "done" },
                      "a propagated one-sided row reports done")

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: fixture.bRoot.appendingPathComponent("only-a.txt").path),
                      "A's file was propagated to B")
        XCTAssertTrue(fm.fileExists(atPath: fixture.aRoot.appendingPathComponent("only-b.txt").path),
                      "B's file was propagated to A")
        UnisonBridge.installSyncCompleteHandler { _, _ in }
    }

    func test_g_syncSnapshot_allocFailureAfterFirstRow_unavailableNoPartial() throws {
        let fixture = try IntegrationFixture(name: "syncsnapalloc")
        try fixture.populate(aFiles: ["a.txt": "x\n", "c.txt": "z\n"],
                             bFiles: ["b.txt": "y\n", "c.txt": "zz\n"])
        let items = scanFixtureItems(fixture)
        XCTAssertGreaterThan(items.count, 1)
        // Per row the marshaller does 2 strdups (progress, details); K=3 fails
        // row 1's progress — after row 0 was fully built.
        unison_bridge_test_fail_strdup_at(3)
        let (ok, rows) = runSyncSnapshotOnce()
        XCTAssertFalse(ok, "a string-copy failure → results unavailable")
        XCTAssertEqual(rows.count, 0, "no partial rows published")
        let (ok2, rows2) = runSyncSnapshotOnce()
        XCTAssertTrue(ok2, "runtime usable after the injected failure")
        XCTAssertEqual(rows2.count, items.count)
        UnisonBridge.installSyncCompleteHandler { _, _ in }
    }

    /// L1 point 2 — GENUINE `run_show_diffs` fault injection through the REAL
    /// bridge exception path, then proof the engine stays usable.
    ///
    /// This drives the real `unison_bridge_run_show_diffs` → `_ocaml_run_show_diffs`
    /// → `bridge_call2_exn` on a really-scanned, really-diffable row. The
    /// `unison_bridge_test_force_next_callbacks_raise(1)` hook makes that exn
    /// wrapper report a raise (short-circuiting before OCaml), so we exercise
    /// the wrapper's real raise handling — NOT a pure `requestRaised()` unit
    /// test. Asserts precisely: the real bridge fault returns FALSE; NO result
    /// or error callback is published (neither `displayDiff` nor
    /// `displayDiffErr` fires); the broker's pending state is cleared through
    /// `requestRaised`; and a subsequent real diff on the same row SUCCEEDS (the
    /// worker survived the forced raise). This test does NOT observe the UI
    /// error presentation: the `AppDelegate` `.raised` mapping and the Reconcile
    /// window's `showError` branch are verified by code inspection, not an
    /// AppKit UI harness.
    func test_r_runShowDiffs_realBridgeRaise_thenEngineUsable() throws {
        let fixture = try IntegrationFixture(name: "diff-raise")
        // shared-diff.txt exists on BOTH replicas with DIFFERENT content → a
        // genuinely diffable row (canDiff == true).
        try fixture.populate(aFiles: ["shared-diff.txt": "version a\n"],
                             bFiles: ["shared-diff.txt": "version b\n"])
        // Give the profile a real `diff` command so a successful diff produces
        // output through `displayDiff` (not a "no diff command" error).
        let prf = try String(contentsOf: fixture.profileURL, encoding: .utf8)
        try (prf + "\ndiff = diff -u\n").write(to: fixture.profileURL,
                                               atomically: true, encoding: .utf8)

        // Drive init1 + init2 to populate the real reconcile state.
        let scanned = expectation(description: "init2 complete")
        var items: [StateItem] = []
        UnisonBridge.installInit1CompleteHandler { needsPrompt in
            XCTAssertFalse(needsPrompt, "local-only profile shouldn't need a prompt")
            unison_bridge_init2()
        }
        UnisonBridge.installInit2CompleteHandler { captured in
            items = captured
            scanned.fulfill()
        }
        fixture.profileName.withCString { unison_bridge_init1($0) }
        wait(for: [scanned], timeout: 20.0)

        guard let row = items.firstIndex(where: { $0.path == "shared-diff.txt" }) else {
            return XCTFail("expected a shared-diff.txt row; got \(items.map(\.path))")
        }
        XCTAssertTrue(unison_bridge_can_diff(Int32(row)),
                      "shared-diff.txt (differing content both sides) must be diffable")

        // Record diff deliveries so we can assert NONE arrives on the fault
        // path and one arrives on the success path.
        var diffDeliveries = 0
        var diffErrDeliveries = 0
        var lastDiffText = ""
        let successDelivered = expectation(description: "diff result delivered on success")
        UnisonBridge.installDiffHandler { _, text in
            diffDeliveries += 1
            lastDiffText = text
            successDelivered.fulfill()
        }
        UnisonBridge.installDiffErrHandler { _ in diffErrDeliveries += 1 }

        // --- Fault path: force the next exn-wrapper dispatch to raise. --------
        // Drive the broker's pending state exactly as AppDelegate's
        // `requestDiff` does around the bridge call: request → issue →
        // run_show_diffs → (false) → requestRaised. NOTE: this exercises the
        // BROKER state transition, not the AppKit UI. The `.raised` result that
        // AppDelegate maps this false return to, and the Reconcile window's
        // `showError` branch it drives, are verified by code inspection (no UI
        // harness) — this test only asserts the broker/bridge contract.
        var broker = DiffRequestBroker()
        let owner: DiffRequestBroker.Owner = 42
        XCTAssertEqual(broker.request(owner: owner), .issue)

        unison_bridge_test_force_next_callbacks_raise(1)
        let faultOK = unison_bridge_run_show_diffs(Int32(row))
        XCTAssertFalse(faultOK, "a raised diff dispatch must return false through the real wrapper")
        XCTAssertEqual(unison_bridge_test_pending_forced_raises(), 0,
                       "the run_show_diffs dispatch consumed exactly the forced raise")

        // Pending state cleared through requestRaised: the broker returns to
        // idle and a new request is immediately allowed.
        broker.requestRaised(owner: owner)
        XCTAssertFalse(broker.isAwaitingResult)
        XCTAssertEqual(broker.request(owner: owner), .issue, "cleared → usable")
        broker.requestRaised(owner: owner)   // reset for the success path below

        // No stale result published: the forced raise short-circuits before
        // OCaml, so neither displayDiff nor displayDiffErr fired. Give the main
        // queue a beat to prove nothing is in flight.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(diffDeliveries, 0, "no diff result may be published on the fault path")
        XCTAssertEqual(diffErrDeliveries, 0, "no diff error may be published on the fault path")

        // --- Engine usable: a subsequent REAL diff on the same row succeeds. --
        XCTAssertEqual(unison_bridge_test_pending_forced_raises(), 0, "no leftover forced raise")
        XCTAssertEqual(broker.request(owner: owner), .issue)
        let okAgain = unison_bridge_run_show_diffs(Int32(row))
        XCTAssertTrue(okAgain, "the worker survived the forced raise; a real diff dispatches")
        wait(for: [successDelivered], timeout: 20.0)
        XCTAssertEqual(broker.deliver(), .apply(owner: owner))
        XCTAssertEqual(diffDeliveries, 1, "exactly one diff result on the success path")
        XCTAssertFalse(lastDiffText.isEmpty, "the real diff produced output")
    }
}

// MARK: - Integration fixture helper
//
// Builds a tiny throwaway profile + replica pair under
// /tmp/unison-ui-mac-itest/<run-uuid>/<name>/ so the marshaling test
// has known, isolated content. Cleans up in deinit (tests don't see
// a tearDown call after init2 anyway, so deinit on the local var is
// the cleanup hook).

// Shared with BridgeExceptionTests (module-internal, not private).
final class IntegrationFixture {
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
