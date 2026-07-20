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
        // Never leak a forced-raise count between tests.
        unison_bridge_test_force_next_callbacks_raise(0)
    }

    override func tearDown() {
        unison_bridge_test_force_next_callbacks_raise(0)
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
