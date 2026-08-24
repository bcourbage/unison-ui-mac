import XCTest
@testable import unison_ui_mac

/// PR-4 round 3: lock the PRODUCTION diff lifecycle sequence (`DiffLifecycle`) with
/// injected scheduler / bridge / presentation sink — no real queue, bridge, or
/// 45-second wait. Covers the reviewer's seven scenarios end to end.
@MainActor
final class DiffLifecycleTests: XCTestCase {

    private final class FakeSink: DiffLifecycleSink {
        var inFlight: [(Bool, UInt64)] = []
        var results: [(String, String, UInt64)] = []
        var errors: [(String, UInt64)] = []
        var appStalls: [String] = []
        var released: [(UInt64, UInt64)] = []
        var windowExistsFor: Set<UInt64> = []
        func diffSetInFlight(_ i: Bool, owner: UInt64) { inFlight.append((i, owner)) }
        func diffShowResult(title: String, text: String, owner: UInt64) { results.append((title, text, owner)) }
        func diffShowError(_ m: String, owner: UInt64) { errors.append((m, owner)) }
        func diffOwnerWindowExists(_ owner: UInt64) -> Bool { windowExistsFor.contains(owner) }
        func diffPresentAppStall(_ m: String) { appStalls.append(m) }
        func diffReleaseEngineOwnership(owner: UInt64, op: UInt64) { released.append((owner, op)) }
    }

    /// A Sendable box so the @Sendable bridge closure can hand the completion back
    /// to the (main-actor) test for manual invocation.
    private final class Box<T>: @unchecked Sendable { var value: T? }

    private let A: UInt64 = 1
    private let B: UInt64 = 2

    private func make(_ sink: FakeSink)
        -> (DiffLifecycle, Box<@MainActor @Sendable (Bool, Bool) -> Void>, () -> (() -> Void)?) {
        let bridgeBox = Box<@MainActor @Sendable (Bool, Bool) -> Void>()
        var fire: (@MainActor @Sendable () -> Void)?
        let lc = DiffLifecycle(
            sink: sink,
            runBridge: { _, completion in bridgeBox.value = completion },
            scheduleWatchdog: { _, f in fire = f; return { fire = nil } },
            stallTimeout: 45)
        return (lc, bridgeBox, { fire })
    }

    // 1. Start → the gate is enabled.
    func test_begin_gatesTheWindow() {
        let sink = FakeSink(); let (lc, _, _) = make(sink)
        XCTAssertTrue(lc.request(owner: A))
        lc.begin(owner: A, op: 10, row: 0)
        XCTAssertEqual(sink.inFlight.count, 1)
        XCTAssertEqual(sink.inFlight.first?.0, true)
        XCTAssertEqual(sink.inFlight.first?.1, A)
    }

    // 2. Callback result then synchronous completion → shown once, no false no-output.
    func test_realCallbackThenCompletion_showsResultOnce() {
        let sink = FakeSink(); let (lc, bridge, _) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        lc.deliverResult(title: "T", text: "the diff")        // the diff callback fired first
        bridge.value?(true, true)                             // then the synchronous return
        XCTAssertEqual(sink.results.map(\.1), ["the diff"], "exactly one result, no 'no output'")
        XCTAssertEqual(sink.inFlight.last?.0, false, "gate cleared")
        XCTAssertEqual(sink.released.map(\.0), [A], "engine ownership released")
    }

    // 3. Success with NO callback → no-output result and broker idle.
    func test_successWithoutCallback_showsNoOutput_andIdles() {
        let sink = FakeSink(); let (lc, bridge, _) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        bridge.value?(true, true)
        XCTAssertEqual(sink.results.map(\.1), ["The diff command produced no output."])
        XCTAssertFalse(lc.isAwaitingResult, "broker resolved to idle")
        XCTAssertEqual(sink.released.map(\.0), [A])
        // A new diff can be issued afterward — not stranded.
        XCTAssertTrue(lc.request(owner: B))
    }

    // 4. Abandon before the return → the (empty) result drains and the broker idles.
    func test_abandonBeforeReturn_drainsToIdle_noResult() {
        let sink = FakeSink(); let (lc, bridge, _) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        lc.abandon(owner: A)
        XCTAssertTrue(lc.isDraining)
        bridge.value?(true, true)
        XCTAssertTrue(sink.results.isEmpty, "an abandoned diff shows nothing")
        XCTAssertFalse(lc.isDraining, "drained back to idle")
        XCTAssertEqual(sink.released.map(\.0), [A], "engine ownership still released")
        XCTAssertTrue(lc.request(owner: B), "future diffs no longer blocked")
    }

    // 5. Watchdog with the owner window present → window error.
    func test_watchdog_withOwnerWindow_routesToWindow() {
        let sink = FakeSink(); sink.windowExistsFor = [A]
        let (lc, _, fire) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        fire()?()
        XCTAssertEqual(sink.errors.count, 1, "stall shown in the owner window")
        XCTAssertTrue(sink.appStalls.isEmpty, "no app-level alert while the window exists")
    }

    // 6. Watchdog without the owner window → app-level alert.
    func test_watchdog_withoutOwnerWindow_routesToAppLevel() {
        let sink = FakeSink()                    // windowExistsFor empty
        let (lc, _, fire) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        fire()?()
        XCTAssertEqual(sink.appStalls.count, 1, "abandoned session → app-level alert")
        XCTAssertTrue(sink.errors.isEmpty)
        fire()?()                                // one-shot / deduplicated
        XCTAssertEqual(sink.appStalls.count, 1)
    }

    // 7. Completion → gate cleared and engine ownership reported for the exact op.
    func test_completion_clearsGate_andReportsTerminalOp() {
        let sink = FakeSink(); let (lc, bridge, _) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 77, row: 0)
        bridge.value?(true, true)
        XCTAssertEqual(sink.inFlight.last?.0, false)
        XCTAssertEqual(sink.released.count, 1)
        XCTAssertEqual(sink.released.first?.0, A)
        XCTAssertEqual(sink.released.first?.1, 77)
    }

    // Bonus: a non-diffable / raised return surfaces an error (not a no-output result).
    func test_notDiffable_showsError_notNoOutput() {
        let sink = FakeSink(); let (lc, bridge, _) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        bridge.value?(false, false)              // canDiff=false → ok=false
        XCTAssertEqual(sink.errors.count, 1)
        XCTAssertTrue(sink.results.isEmpty)
        XCTAssertEqual(sink.released.map(\.0), [A])
    }

    // MARK: - Round 4, SF1: an abandoned/timed-out diff that FAILS still idles

    /// Abandon (window closed) → the bridge later returns ok=false → the broker must
    /// drain back to idle and present NOTHING (never reopen the dismissed window).
    func test_abandonThenFailedReturn_idles_noErrorWindow() {
        let sink = FakeSink(); let (lc, bridge, _) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        lc.abandon(owner: A)
        bridge.value?(true, false)               // stalled remote raised → ok=false
        XCTAssertTrue(sink.errors.isEmpty, "no error window is reopened for an abandoned diff")
        XCTAssertTrue(sink.results.isEmpty)
        XCTAssertFalse(lc.isDraining, "broker drained to idle, not stuck draining")
        XCTAssertEqual(sink.released.map(\.0), [A])
        XCTAssertTrue(lc.request(owner: B), "future diffs work")
    }

    /// Watchdog fired (which abandons) → the bridge later returns ok=false → idle,
    /// and no duplicate terminal error (the watchdog already surfaced the stall).
    func test_watchdogThenFailedReturn_idles_noDuplicateError() {
        let sink = FakeSink()                    // no owner window → app-level stall
        let (lc, bridge, fire) = make(sink)
        _ = lc.request(owner: A)
        lc.begin(owner: A, op: 10, row: 0)
        fire()?()                                // watchdog abandons + app-stall alert
        XCTAssertEqual(sink.appStalls.count, 1)
        bridge.value?(true, false)               // then the diff finally fails
        XCTAssertTrue(sink.errors.isEmpty, "no duplicate terminal error after the stall")
        XCTAssertFalse(lc.isDraining, "drained to idle")
        XCTAssertEqual(sink.released.map(\.0), [A])
        XCTAssertTrue(lc.request(owner: B))
    }

    // MARK: - Round 4, SF2: undoRequest returns straight to idle (not draining)

    func test_undoRequest_afterCoordinatorRefusal_returnsToIdle() {
        let sink = FakeSink(); let (lc, _, _) = make(sink)
        XCTAssertTrue(lc.request(owner: A))      // broker outstanding(A)
        lc.undoRequest(owner: A)                 // coordinator refused ownership
        XCTAssertFalse(lc.isDraining, "an unissued request cancels to idle, never draining")
        XCTAssertFalse(lc.isAwaitingResult)
        XCTAssertTrue(lc.request(owner: B), "a later diff is not permanently refused")
    }
}
