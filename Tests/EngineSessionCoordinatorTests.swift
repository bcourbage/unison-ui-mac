import XCTest
@testable import unison_ui_mac

/// Deterministic lifecycle tests for the engine coordinator, driven
/// through a fake driver — no AppKit, no bridge, no timing. These pin the
/// abandonment / close-after-completion / close-failure behavior that the
/// ad-hoc booleans got wrong (issue #6, steps 4–5 review).
@MainActor
final class EngineSessionCoordinatorTests: XCTestCase {

    private final class FakeDriver: EngineSessionCoordinator.Driver {
        typealias Token = EngineSessionCoordinator.Token
        var opens: [(token: Token, profile: String)] = []
        var rescans: [Token] = []
        var closes: [Token] = []
        var waiting: [String] = []
        var restarts: [String] = []

        func engineBeginOpen(token: Token, profile: String) { opens.append((token, profile)) }
        func engineBeginRescanReuse(token: Token) { rescans.append(token) }
        func engineCloseConnection(token: Token) { closes.append(token) }
        func engineShowWaiting(profile: String) { waiting.append(profile) }
        func engineRestartRequired(reason: String) { restarts.append(reason) }
    }

    private func makeCoordinator() -> (EngineSessionCoordinator, FakeDriver) {
        let d = FakeDriver()
        let c = EngineSessionCoordinator(driver: d)
        return (c, d)
    }

    // Leave during a scan, pick another profile: the second open must WAIT
    // for the abandoned scan to actually finish, then its connection close,
    // before starting. (The core false-idle bug.)
    func test_abandonedScan_gatesNextOpen_untilScanAndCloseComplete() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)      // scanning(A), open
        c.abandon(reason: "left during scan")          // abandoned, still scanning

        XCTAssertNil(c.requestOpen(profile: "B"))       // queued, not started
        XCTAssertEqual(d.waiting, ["B"])
        XCTAssertEqual(d.opens.count, 1)

        c.scanCompleted(a)                              // abandoned scan finally ends
        XCTAssertEqual(d.closes, [a])                   // close its connection first
        XCTAssertEqual(d.opens.count, 1)                // B still not started

        c.closeCompleted(a, status: 0)                  // close done → idle → start B
        XCTAssertEqual(d.opens.count, 2)
        XCTAssertEqual(d.opens.last?.profile, "B")
    }

    // If the abandoned scan never terminates, the queued open must NEVER
    // race it — the engine stays busy rather than faking idle.
    func test_abandonedScan_neverCompletes_neverRacesQueuedOpen() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        c.abandon(reason: "left")
        XCTAssertNil(c.requestOpen(profile: "B"))
        // A never completes.
        XCTAssertEqual(d.opens.count, 1)                // B never started
        XCTAssertEqual(d.closes, [])
        XCTAssertFalse(c.isIdle)
    }

    // A close failure must not reach idle or start a queued open; it
    // requires restart.
    func test_closeFailure_requiresRestart_andBlocksNewOpens() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")                 // queued
        c.scanCompleted(a)                              // → closing
        c.closeCompleted(a, status: 2)                  // close FAILED
        XCTAssertEqual(d.restarts.count, 1)
        XCTAssertEqual(d.opens.count, 1)                // B NOT started
        XCTAssertNil(c.requestOpen(profile: "C"))       // refused
        XCTAssertEqual(d.restarts.count, 2)
    }

    // "Close (let it run)" / "Abort & Close": leave while syncing → close
    // deferred until sync completion, then queued open starts.
    func test_leaveWhileSyncing_closesAfterSyncCompletes() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        c.scanCompleted(a)                              // ready
        c.syncStarted(a)                                // syncing
        c.abandon(reason: "let it run")                 // abandoned, still syncing
        _ = c.requestOpen(profile: "B")                 // queued
        XCTAssertEqual(d.closes, [])
        c.syncCompleted(a)                              // → close now
        XCTAssertEqual(d.closes, [a])
        XCTAssertEqual(d.opens.count, 1)
        c.closeCompleted(a, status: 0)
        XCTAssertEqual(d.opens.count, 2)                // B starts
    }

    // 2b policy: non-interactive → close on sync-end, window stays ready.
    func test_nonInteractive_closesOnSyncEnd_staysReady() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        c.scanCompleted(a)
        c.syncStarted(a)
        c.syncCompleted(a)                              // not abandoned, non-interactive
        XCTAssertEqual(d.closes, [a])
        XCTAssertEqual(c.phase, .ready(a))
        c.closeCompleted(a, status: 0)
        XCTAssertEqual(c.connection, .none)
        XCTAssertEqual(c.phase, .ready(a))             // window still open
    }

    // 2b policy: interactive → hold through sync-end; close only on leave.
    func test_interactive_holdsThroughSyncEnd_closesOnLeave() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: true)
        c.scanCompleted(a)
        c.syncStarted(a)
        c.syncCompleted(a)
        XCTAssertEqual(d.closes, [])                    // held
        XCTAssertEqual(c.connection, .open(interactive: true))
        c.abandon(reason: "leave")                      // from ready → close now
        XCTAssertEqual(d.closes, [a])
        c.closeCompleted(a, status: 0)
        XCTAssertTrue(c.isIdle)
    }

    // Two picks while busy — last wins.
    func test_twoPicksWhileBusy_lastWins() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")
        _ = c.requestOpen(profile: "C")
        XCTAssertEqual(d.waiting, ["B", "C"])
        c.scanCompleted(a)
        c.closeCompleted(a, status: 0)
        XCTAssertEqual(d.opens.last?.profile, "C")
    }

    // An abandoned/stale token is not "current" for UI, but its terminal
    // callback still releases the lease.
    func test_isCurrent_falseAfterAbandon_butLeaseStillReleases() {
        let (c, _) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        XCTAssertTrue(c.isCurrent(a))
        c.abandon(reason: "left")
        XCTAssertFalse(c.isCurrent(a))                 // UI suppressed
        c.scanCompleted(a)                              // lease still released
        c.closeCompleted(a, status: 0)
        XCTAssertTrue(c.isIdle)
    }

    // Rescan reuses a live connection (init2 only).
    func test_rescan_reusesLiveConnection() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        c.scanCompleted(a)                              // ready, open
        c.requestRescan(profile: "A")
        XCTAssertEqual(d.rescans.count, 1)
        XCTAssertEqual(d.opens.count, 1)               // no reopen
    }

    // Rescan after a non-interactive sync-end close reopens (full open).
    func test_rescan_reopensAfterCloseOnSyncEnd() {
        let (c, d) = makeCoordinator()
        let a = c.requestOpen(profile: "A")!
        c.connectionOpened(a, interactive: false)
        c.scanCompleted(a)
        c.syncStarted(a)
        c.syncCompleted(a)                              // close-on-sync-end
        c.closeCompleted(a, status: 0)                 // connection none, ready
        c.requestRescan(profile: "A")
        XCTAssertEqual(d.rescans.count, 0)             // not reused
        XCTAssertEqual(d.opens.count, 2)               // reopened
    }
}
