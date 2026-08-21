import XCTest
@testable import unison_ui_mac

/// Finding #6 (exception containment) + Finding #1 (GC rooting) coverage.
///
/// These hit the live OCaml bridge, which the test host has already started
/// (see the note atop BridgeTests). Two deterministic fault-injection hooks,
/// compiled only under `UNISON_DEBUG_HOOKS` (Debug), make the failure paths
/// exercisable without a raising OCaml stub in the vendored blob:
///
///   - `unison_bridge_test_force_next_callbacks_raise(n)` makes the next `n`
///     OCaml callbacks dispatched through the shared exn wrappers behave as if
///     they raised. Crucially, the wrapper short-circuits BEFORE invoking the
///     real OCaml function, so a forced raise never actually runs a scan / sync
///     / close — it only exercises our C-side handling, status translation,
///     request completion, worker survival, and the Swift return contract.
///   - `unison_bridge_test_reload_under_gc(row, …)` reproduces reloadTable's
///     rooting discipline against the real progress callbacks with a moving
///     collection interposed (Finding #1).
///
/// Determinism: every bridge entry point below blocks its caller until the
/// OCaml worker finishes the dispatched fn, so a force-then-call pair on one
/// thread is strictly sequential — the forged raise is consumed by exactly the
/// call under test. No sync is running in these tests, so no stray reloadTable
/// callback can consume the counter.
final class BridgeExceptionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Never leak injection state between tests.
        unison_bridge_test_force_next_callbacks_raise(0)
        unison_bridge_test_force_raise_at_ordinal(0)
    }

    override func tearDown() {
        unison_bridge_test_force_next_callbacks_raise(0)
        unison_bridge_test_force_raise_at_ordinal(0)
        // Ensure no dummy preconnection survives into another test.
        unison_bridge_test_set_fake_preconn(false)
        super.tearDown()
    }

    // MARK: - The injection mechanism itself

    func test_forceRaise_counterDrainsExactlyOnePerCallback() {
        unison_bridge_test_force_next_callbacks_raise(2)
        XCTAssertEqual(unison_bridge_test_pending_forced_raises(), 2)
        // get_version routes through exactly one wrapper call.
        _ = unison_bridge_get_version()
        XCTAssertEqual(unison_bridge_test_pending_forced_raises(), 1,
                       "one callback should consume exactly one forced raise")
        _ = unison_bridge_get_version()
        XCTAssertEqual(unison_bridge_test_pending_forced_raises(), 0)
    }

    // MARK: - Read-only entry points: raise → safe sentinel, not garbage

    func test_forceRaise_getVersion_returnsNilNotGarbage() {
        unison_bridge_test_force_next_callbacks_raise(1)
        XCTAssertNil(unison_bridge_get_version(),
                     "a raised get_version must return NULL, never a bogus string")
        // Worker survived: the very next call succeeds normally.
        guard let v = unison_bridge_get_version() else {
            return XCTFail("bridge worker did not survive an injected raise")
        }
        XCTAssertTrue(String(cString: v).contains("ocaml"))
    }

    func test_forceRaise_unisonDirectory_returnsNilNotGarbage() {
        unison_bridge_test_force_next_callbacks_raise(1)
        XCTAssertNil(unison_bridge_unison_directory(),
                     "a raised unison_directory must return NULL, never a bogus path")
        XCTAssertNotNil(unison_bridge_unison_directory(),
                        "worker must recover for the next call")
    }

    // MARK: - Phase ops: raise → explicit non-OK status (never a false success)

    func test_forceRaise_closeConnection_returnsExnStatusNotZero() {
        unison_bridge_test_force_next_callbacks_raise(1)
        let status = unison_bridge_close_connection()
        XCTAssertNotEqual(status, 0,
            "a raised close MUST NOT be misreported as a successful (0) close")
        XCTAssertEqual(status, UNISON_BRIDGE_ERR_EXN,
            "a raised close should surface the exn status the driver routes to restart")
        // Real close afterwards is a clean no-op → worker survived.
        XCTAssertEqual(unison_bridge_close_connection(), 0)
    }

    func test_forceRaise_init2_returnsExnStatusNotOK() {
        unison_bridge_test_force_next_callbacks_raise(1)
        let status = unison_bridge_init2()
        XCTAssertNotEqual(status, UNISON_BRIDGE_OK,
            "a raised scan MUST NOT be misreported as a successful dispatch")
        XCTAssertEqual(status, UNISON_BRIDGE_ERR_EXN)
    }

    func test_forceRaise_synchronize_returnsExnStatusNotOK() {
        unison_bridge_test_force_next_callbacks_raise(1)
        let status = unison_bridge_synchronize()
        XCTAssertNotEqual(status, UNISON_BRIDGE_OK,
            "a raised sync start MUST NOT be misreported as a successful launch")
        XCTAssertEqual(status, UNISON_BRIDGE_ERR_EXN)
    }

    func test_forceRaise_init1_returnsExnStatusNotOK() {
        // The forced raise short-circuits before the real unisonInit1 runs, so
        // no profile is actually loaded — we only assert the status contract.
        unison_bridge_test_force_next_callbacks_raise(1)
        let status = "no-such-profile".withCString { unison_bridge_init1($0) }
        XCTAssertNotEqual(status, UNISON_BRIDGE_OK,
            "a raised connect init MUST NOT be misreported as a successful dispatch")
        XCTAssertEqual(status, UNISON_BRIDGE_ERR_EXN)
    }

    func test_forceRaise_init0_returnsExnStatusThenRecovers() {
        // init0 already ran successfully at host-app startup; a forced raise here
        // short-circuits before re-invoking it, so this only exercises the status
        // contract and does not disturb the live runtime.
        unison_bridge_test_force_next_callbacks_raise(1)
        XCTAssertEqual(unison_bridge_init0(), UNISON_BRIDGE_ERR_EXN,
            "a raised init0 MUST report failure, never OK")
        // A real init0 afterwards re-wires the status displayer cleanly.
        XCTAssertEqual(unison_bridge_init0(), UNISON_BRIDGE_OK,
            "worker must recover; init0 is idempotent")
    }

    func test_forceRaise_abort_returnsExnStatusNotOK() {
        unison_bridge_test_force_next_callbacks_raise(1)
        XCTAssertEqual(unison_bridge_abort_sync(), UNISON_BRIDGE_ERR_EXN,
            "a raised abort MUST NOT claim the cancellation was requested")
        // Worker survived; a real abort (no sync running) is a clean flag-flip.
        XCTAssertEqual(unison_bridge_abort_sync(), UNISON_BRIDGE_OK)
    }

    // MARK: - Credential contracts (Blocker 3): exn ≠ "no more prompts"

    func test_connectionPrompt_noPreconn_reportsNoneNotDone() {
        // With no preconnection, the result is NONE (not DONE) — so the driver
        // never mistakes it for "prompts finished" and calls connection_end.
        var p: UnsafePointer<CChar>? = nil
        XCTAssertEqual(unison_bridge_connection_prompt(&p), UNISON_PROMPT_NONE)
        XCTAssertNil(p)
    }

    func test_forceRaise_connectionPrompt_reportsExnNotDone() {
        // A prompt exception MUST surface as EXN, never DONE — a DONE here would
        // falsely authorize connection finalization (connection_end).
        unison_bridge_test_set_fake_preconn(true)
        unison_bridge_test_force_next_callbacks_raise(1)
        var p: UnsafePointer<CChar>? = nil
        let r = unison_bridge_connection_prompt(&p)
        unison_bridge_test_set_fake_preconn(false)
        XCTAssertEqual(r, UNISON_PROMPT_EXN,
            "a raised prompt must be EXN, never observed as normal completion (DONE)")
        XCTAssertNotEqual(r, UNISON_PROMPT_DONE)
        XCTAssertNil(p)
    }

    func test_forceRaise_connectionReply_reportsExnStatus() {
        unison_bridge_test_set_fake_preconn(true)
        unison_bridge_test_force_next_callbacks_raise(1)
        let rc = unison_bridge_connection_reply("secret-not-inspected")
        unison_bridge_test_set_fake_preconn(false)
        XCTAssertEqual(rc, UNISON_REPLY_EXN,
            "a raised reply must report EXN so the driver stops the loop and cleans up")
    }

    func test_connectionReply_noPreconn_reportsNone() {
        XCTAssertEqual(unison_bridge_connection_reply("x"), UNISON_REPLY_NONE)
    }

    // MARK: - Ordinal targeting drains exactly the Kth wrapper call

    func test_ordinalInjection_firesOnlyOnTargetCall() {
        // Arm the 3rd wrapper call to raise; the 1st/2nd succeed, the 3rd fails,
        // the 4th succeeds again (single-shot).
        unison_bridge_test_force_raise_at_ordinal(3)
        XCTAssertNotNil(unison_bridge_get_version(), "call 1 should succeed")
        XCTAssertNotNil(unison_bridge_get_version(), "call 2 should succeed")
        XCTAssertNil(unison_bridge_get_version(), "call 3 (target) should raise")
        XCTAssertNotNil(unison_bridge_get_version(), "call 4 should succeed (single-shot)")
    }

    // MARK: - Finding #1: a known young value survives a relocating collection

    func test_rootedYoungValue_survivesRelocatingCollection() {
        let known = "progress-42%-\u{2713}-known-young-value"
        var buf = [CChar](repeating: 0, count: 1024)
        var moved = false
        let ok = unison_bridge_test_root_survives_gc(known, &buf, buf.count, &moved)
        XCTAssertTrue(ok, "rooting probe did not complete")
        XCTAssertEqual(String(cString: buf), known,
            "a CAMLlocal-rooted young value must read back byte-identical after GC")
        XCTAssertTrue(moved,
            "the fresh young block must actually relocate (major heap) — proving the "
            + "test exercises real root tracking, not a value that never moved")
    }

    // MARK: - Worker liveness across many injected faults (no strand / deadlock)

    func test_forceRaise_repeatedInjection_workerNeverStranded() {
        // Alternate a forced raise with an unforced success, many times. If any
        // injected raise stranded the parked caller or lost the worker, a later
        // call would hang and the overall test would time out (XCTest bound).
        for i in 0..<200 {
            unison_bridge_test_force_next_callbacks_raise(1)
            XCTAssertNil(unison_bridge_get_version(), "iteration \(i): forced raise")
            XCTAssertNotNil(unison_bridge_get_version(), "iteration \(i): recovery")
        }
        XCTAssertEqual(unison_bridge_test_pending_forced_raises(), 0)
    }

    func test_forceRaise_concurrentCallersSurviveInjection() {
        // Faults injected while many threads hammer the single-slot handoff must
        // not deadlock it. Each forced raise returns nil; unforced calls return
        // a value; every caller must complete (else the wait times out).
        let callers = 8
        let iterations = 100
        let done = expectation(description: "all callers complete under fault injection")
        done.expectedFulfillmentCount = callers

        // A separate thread continuously arms single raises. The exact call that
        // consumes each raise is nondeterministic here — that's fine: the point
        // is that no combination strands the worker or wedges the handoff. The
        // thread fulfills `armingDone` when it returns, so we can quiesce it
        // deterministically before clearing the counter (no leak into the next
        // test, whose setUp also clears it as a second line of defence).
        let stopArming = NSLock()
        var shouldStop = false
        let armingDone = expectation(description: "arming thread returned")
        DispatchQueue.global().async {
            while true {
                stopArming.lock(); let done = shouldStop; stopArming.unlock()
                if done { break }
                unison_bridge_test_force_next_callbacks_raise(1)
            }
            armingDone.fulfill()
        }
        for _ in 0..<callers {
            DispatchQueue.global().async {
                for _ in 0..<iterations {
                    // May be nil (consumed a raise) or non-nil — both are fine;
                    // completing at all is what we assert.
                    _ = unison_bridge_get_version()
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 30)
        stopArming.lock(); shouldStop = true; stopArming.unlock()
        wait(for: [armingDone], timeout: 5)
        unison_bridge_test_force_next_callbacks_raise(0)
    }

    // NOTE: the Finding #1 GC-rooting probe test lives in BridgeTests
    // (test_e_reloadRow_progressValueSurvivesCollection) rather than here,
    // because it drives a real init1/init2 that populates global OCaml
    // reconcile state (g_ri_count). BridgeTests owns the alphabetical ordering
    // that keeps state-mutating tests after the "no state loaded" assertions;
    // running a fixture scan from this earlier-sorting class would corrupt
    // those. Every test in THIS class is state-clean: the forced-raise wrappers
    // short-circuit before invoking OCaml, so no scan/sync/close ever runs.
}
