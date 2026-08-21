import XCTest
@testable import unison_ui_mac

/// Round 3 correction 2: the qualification probe registry separates
/// "current probe by session" from "all live probes", so a cancelled or
/// superseded probe stays tracked (and thus cancel/wait-able at shutdown) until
/// its subprocess actually completes.
final class ScanInterruptProbeRegistryTests: XCTestCase {

    private typealias SID = EngineSessionCoordinator.SessionID
    private func probe(_ session: UInt64, _ gen: UInt64) -> ScanInterruptQualProbe {
        ScanInterruptQualProbe(session: SID(raw: session), generation: gen)
    }

    func test_supersession_oldStaysLiveUntilComplete() {
        let r = ScanInterruptProbeRegistry()
        let p1 = probe(1, 1), p2 = probe(1, 2)
        r.register(p1)
        XCTAssertEqual(r.liveCount, 1)
        r.register(p2)                              // supersedes p1
        XCTAssertTrue(p1.canceller.isCancelled, "superseded probe must be cancelled")
        XCTAssertFalse(p2.canceller.isCancelled)
        XCTAssertTrue(r.isCurrent(p2))
        XCTAssertFalse(r.isCurrent(p1))
        XCTAssertEqual(r.liveCount, 2, "superseded probe RETAINED until its teardown completes")
        r.complete(p1)                              // p1's subprocess finishes
        XCTAssertEqual(r.liveCount, 1)
        XCTAssertTrue(r.isCurrent(p2), "p1 completion must not disturb its successor")
    }

    func test_leaveThenTerminate_cancelledProbeRetainedForShutdown() {
        let r = ScanInterruptProbeRegistry()
        let p = probe(1, 1)
        r.register(p)
        r.cancelCurrent(session: SID(raw: 1))       // leave / window close
        XCTAssertTrue(p.canceller.isCancelled)
        XCTAssertFalse(r.isCurrent(p), "cancelled probe is no longer current")
        XCTAssertEqual(r.allLive.count, 1, "retained live so shutdown can cancel+wait its reap")
        // shutdown discipline: cancel all live (already cancelled here), then the
        // worker's completion removes it.
        for probe in r.allLive { probe.canceller.cancel() }
        r.complete(p)
        XCTAssertEqual(r.liveCount, 0)
    }

    func test_staleCompletion_doesNotClearSuccessor() {
        let r = ScanInterruptProbeRegistry()
        let p1 = probe(1, 1), p2 = probe(1, 2)
        r.register(p1)
        r.register(p2)
        r.complete(p1)                              // the stale/superseded probe finishes late
        XCTAssertTrue(r.isCurrent(p2), "successor stays current")
        XCTAssertEqual(r.liveCount, 1, "only the stale probe was dropped from live")
    }

    func test_allLive_spansSessions() {
        let r = ScanInterruptProbeRegistry()
        r.register(probe(1, 1))
        r.register(probe(2, 1))
        XCTAssertEqual(r.allLive.count, 2)
    }

    func test_completeUnknownProbe_isNoOp() {
        let r = ScanInterruptProbeRegistry()
        r.complete(probe(9, 9))                     // never registered
        XCTAssertEqual(r.liveCount, 0)
    }
}
