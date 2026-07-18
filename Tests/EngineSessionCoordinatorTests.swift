import XCTest
@testable import unison_ui_mac

/// Deterministic lifecycle tests for the engine coordinator, asserting the
/// effects each transition returns — no AppKit, no bridge, no timing.
/// These pin the abandonment / close-after-completion / close-failure
/// behavior the ad-hoc booleans got wrong (issue #6, steps 4–5 review).
@MainActor
final class EngineSessionCoordinatorTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    /// Extract the token a `.beginOpen` / `.beginRescanReuse` effect carries.
    private func startedToken(_ effects: [Effect]) -> C.Token? {
        for e in effects {
            switch e {
            case .beginOpen(let t, _), .beginRescanReuse(let t): return t
            default: continue
            }
        }
        return nil
    }

    // Open a profile through to .ready with a non-interactive connection.
    private func openToReady(_ c: C, _ profile: String = "A") -> C.Token {
        let t = startedToken(c.requestOpen(profile: profile))!
        _ = c.connectionOpened(t, interactive: false)
        _ = c.scanCompleted(t)
        return t
    }

    // Leave during a scan, pick another profile: the second open WAITS for
    // the abandoned scan to finish, then its connection to close, before
    // starting. (The core false-idle bug.)
    func test_abandonedScan_gatesNextOpen_untilScanAndCloseComplete() {
        let c = C()
        let a = startedToken(c.requestOpen(profile: "A"))!
        _ = c.connectionOpened(a, interactive: false)      // scanning(A), open
        XCTAssertEqual(c.abandon(reason: "left during scan"), [])  // no effect; deferred

        XCTAssertEqual(c.requestOpen(profile: "B"), [.showWaiting(profile: "B")])

        XCTAssertEqual(c.scanCompleted(a), [.closeConnection(token: a)])  // close first
        // B still not started.
        XCTAssertEqual(c.closeCompleted(a, status: 0), [.beginOpen(token: C.Token(raw: 2), profile: "B")])
    }

    // If the abandoned scan never terminates, the queued open must NEVER
    // race it — the engine stays busy.
    func test_abandonedScan_neverCompletes_neverRacesQueuedOpen() {
        let c = C()
        let a = startedToken(c.requestOpen(profile: "A"))!
        _ = c.connectionOpened(a, interactive: false)
        _ = c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")     // queued
        // A never completes.
        XCTAssertFalse(c.isIdle)
        if case .scanning(let t) = c.phase { XCTAssertEqual(t, a) } else { XCTFail("expected scanning(A)") }
    }

    // A close failure must not reach idle or start a queued open; it
    // requires restart and blocks new opens.
    func test_closeFailure_requiresRestart_andBlocksNewOpens() {
        let c = C()
        let a = startedToken(c.requestOpen(profile: "A"))!
        _ = c.connectionOpened(a, interactive: false)
        _ = c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")                 // queued
        XCTAssertEqual(c.scanCompleted(a), [.closeConnection(token: a)])
        XCTAssertEqual(c.closeCompleted(a, status: 2), [.restartRequired(reason: "close returned status 2")])
        // B not started; new opens refused with restartRequired.
        XCTAssertEqual(c.requestOpen(profile: "C"), [.restartRequired(reason: "close returned status 2")])
    }

    // "Close (let it run)" / "Abort & Close": leave while syncing → close
    // deferred until sync completion, then queued open starts.
    func test_leaveWhileSyncing_closesAfterSyncCompletes() {
        let c = C()
        let a = openToReady(c)
        _ = c.syncStarted(a)                            // syncing
        _ = c.abandon(reason: "let it run")             // deferred
        _ = c.requestOpen(profile: "B")                 // queued
        XCTAssertEqual(c.syncCompleted(a), [.closeConnection(token: a)])
        XCTAssertEqual(c.closeCompleted(a, status: 0), [.beginOpen(token: C.Token(raw: 2), profile: "B")])
    }

    // 2b policy: non-interactive → close on sync-end, window stays ready.
    func test_nonInteractive_closesOnSyncEnd_staysReady() {
        let c = C()
        let a = openToReady(c)
        _ = c.syncStarted(a)
        XCTAssertEqual(c.syncCompleted(a),
                       [.presentSyncResults(token: a), .closeConnection(token: a)])
        XCTAssertEqual(c.phase, .ready(a))
        XCTAssertEqual(c.closeCompleted(a, status: 0), [])   // no queued open
        XCTAssertEqual(c.connection, .none)
        XCTAssertEqual(c.phase, .ready(a))                   // window still open
    }

    // 2b policy: interactive → hold through sync-end; close only on leave.
    func test_interactive_holdsThroughSyncEnd_closesOnLeave() {
        let c = C()
        let a = startedToken(c.requestOpen(profile: "A"))!
        _ = c.connectionOpened(a, interactive: true)
        _ = c.scanCompleted(a)
        _ = c.syncStarted(a)
        XCTAssertEqual(c.syncCompleted(a), [.presentSyncResults(token: a)])  // held
        XCTAssertEqual(c.connection, .open(interactive: true))
        XCTAssertEqual(c.abandon(reason: "leave"), [.closeConnection(token: a)])
        XCTAssertEqual(c.closeCompleted(a, status: 0), [])
        XCTAssertTrue(c.isIdle)
    }

    // Two picks while busy — last wins.
    func test_twoPicksWhileBusy_lastWins() {
        let c = C()
        let a = startedToken(c.requestOpen(profile: "A"))!
        _ = c.connectionOpened(a, interactive: false)
        _ = c.abandon(reason: "left")
        _ = c.requestOpen(profile: "B")
        _ = c.requestOpen(profile: "C")
        _ = c.scanCompleted(a)
        XCTAssertEqual(c.closeCompleted(a, status: 0), [.beginOpen(token: C.Token(raw: 2), profile: "C")])
    }

    // An abandoned/stale token isn't "current" for UI, but its terminal
    // event still releases the lease.
    func test_isCurrent_falseAfterAbandon_butLeaseStillReleases() {
        let c = C()
        let a = startedToken(c.requestOpen(profile: "A"))!
        _ = c.connectionOpened(a, interactive: false)
        XCTAssertTrue(c.isCurrent(a))
        _ = c.abandon(reason: "left")
        XCTAssertFalse(c.isCurrent(a))                 // UI suppressed
        _ = c.scanCompleted(a)                          // lease still released
        _ = c.closeCompleted(a, status: 0)
        XCTAssertTrue(c.isIdle)
    }

    // Stale terminal event (wrong token) is ignored.
    func test_staleToken_ignored() {
        let c = C()
        let a = openToReady(c)
        let bogus = C.Token(raw: 999)
        XCTAssertEqual(c.scanCompleted(bogus), [])     // not active → ignored
        XCTAssertEqual(c.phase, .ready(a))
    }

    // Rescan reuses a live connection (init2 only).
    func test_rescan_reusesLiveConnection() {
        let c = C()
        let a = openToReady(c)
        let effects = c.requestRescan(profile: "A")
        XCTAssertEqual(effects.count, 1)
        if case .beginRescanReuse = effects.first { } else { XCTFail("expected beginRescanReuse") }
        _ = a
    }

    // Rescan after a non-interactive sync-end close reopens (full open).
    func test_rescan_reopensAfterCloseOnSyncEnd() {
        let c = C()
        let a = openToReady(c)
        _ = c.syncStarted(a)
        _ = c.syncCompleted(a)                          // close-on-sync-end
        _ = c.closeCompleted(a, status: 0)              // connection none, ready
        let effects = c.requestRescan(profile: "A")
        if case .beginOpen = effects.first { } else { XCTFail("expected beginOpen (reopen)") }
    }
}
