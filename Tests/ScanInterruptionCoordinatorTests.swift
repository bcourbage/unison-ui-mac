#if DEBUG
import XCTest
@testable import unison_ui_mac

/// Coordinator **contract** coverage for the Phase 0 scan-interruption wiring
/// (§7). These do NOT execute the AppDelegate driver (no AppKit host); they
/// replay the exact `EngineSessionCoordinator` call sequence the driver
/// performs, against a REAL coordinator, and — for the driver's pending-slot
/// selection — test the extracted pure `ScanInterruptRestartTarget.select`
/// composed with the coordinator. Together these catch the token-identity
/// defects that pure-harness tests cannot:
///
/// - Blocker 1: a quarantine must fail the coordinator with the exact in-flight
///   token, or the coordinator stays stuck in `.scanning`.
/// - Blocker 2: once the original scan token is consumed by
///   `operationFailed(quiescent: true)`, later phases (close, replacement
///   connect/scan) need THEIR own tokens; the original no longer works.
/// - Blocker 3: a replacement scan-FAILED must quarantine, not report success.
@MainActor
final class ScanInterruptionCoordinatorTests: XCTestCase {

    private typealias Coord = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect
    private typealias SID = EngineSessionCoordinator.SessionID
    private typealias OID = EngineSessionCoordinator.OperationID
    private typealias H = ScanInterruptionHarness

    // effect extractors
    private func connectTok(_ es: [Effect]) -> (SID, OID)? {
        for e in es { if case .beginConnect(let s, let op, _) = e { return (s, op) } }
        return nil
    }
    private func scanTok(_ es: [Effect]) -> (SID, OID)? {
        for e in es { if case .beginScan(let s, let op) = e { return (s, op) } }
        return nil
    }
    private func closeTok(_ es: [Effect]) -> (SID, OID)? {
        for e in es { if case .closeConnection(let s, let op) = e { return (s, op) } }
        return nil
    }
    private func hasRestart(_ es: [Effect]) -> Bool {
        es.contains { if case .restartRequired = $0 { return true }; return false }
    }

    /// Drive a real coordinator to `.scanning(s, scanOp)` with a live remote
    /// connection; return (coord, session, scanOp).
    private func scanning() -> (Coord, SID, OID) {
        let c = Coord()
        let e1 = c.requestOpen(profile: "p")
        let (s, connectOp) = connectTok(e1)!
        let e2 = c.connectFinished(s, connectOp, result: .remote(interactive: false))
        let (s2, scanOp) = scanTok(e2)!
        XCTAssertEqual(s, s2)
        XCTAssertTrue(c.currentSession == s)   // in .scanning
        return (c, s, scanOp)
    }

    // MARK: - Blocker 1: quarantine needs the exact scanning token

    func test_quarantineDuringScan_withExactToken_leavesScanning() {
        let (c, s, scanOp) = scanning()
        // What the driver does on quarantine while still scanning.
        let e = c.operationFailed(s, scanOp, reason: "q", engineIsQuiescent: false)
        XCTAssertTrue(hasRestart(e))
        XCTAssertTrue(c.isRestartRequired)         // coordinator LEFT .scanning
    }

    func test_quarantineDuringScan_withWrongToken_staysStuck() {
        // Proves the defect class: a nil/wrong token (what the old
        // armedBinding==nil path effectively produced) fails to move the
        // coordinator, which would hang in .scanning.
        let (c, s, scanOp) = scanning()
        let wrongOp = OID(raw: scanOp.raw &+ 999)
        let e = c.operationFailed(s, wrongOp, reason: "q", engineIsQuiescent: false)
        XCTAssertTrue(e.isEmpty)
        XCTAssertFalse(c.isRestartRequired)
        XCTAssertEqual(c.currentSession, s)        // still stuck in .scanning
    }

    // MARK: - Blocker 2: phase-appropriate tokens after the original is consumed

    func test_originalToken_isInert_afterQuiescentConsume() {
        let (c, s, scanOp) = scanning()
        let eClose = c.operationFailed(s, scanOp, reason: "", engineIsQuiescent: true)
        XCTAssertNotNil(closeTok(eClose))          // → .closing, close emitted
        // The original scan token can no longer fail anything.
        XCTAssertTrue(c.operationFailed(s, scanOp, reason: "", engineIsQuiescent: false).isEmpty)
    }

    func test_closeTimeout_needsCloseToken_toRestart() {
        let (c, s, scanOp) = scanning()
        let eClose = c.operationFailed(s, scanOp, reason: "", engineIsQuiescent: true)
        let (cs, closeOp) = closeTok(eClose)!
        _ = c.requestOpen(profile: "p")            // queue the reopen
        // Driver's close-phase quarantine: a non-zero closeCompleted with the
        // CLOSE token escalates to restart-required.
        let e = c.closeCompleted(cs, closeOp, status: 998)
        XCTAssertTrue(hasRestart(e))
        XCTAssertTrue(c.isRestartRequired)
    }

    func test_replacementConnectFailure_needsReplacementToken_toRestart() {
        let (c, s, scanOp) = scanning()
        let eClose = c.operationFailed(s, scanOp, reason: "", engineIsQuiescent: true)
        let (cs, closeOp) = closeTok(eClose)!
        _ = c.requestOpen(profile: "p")
        // Clean close starts the queued replacement open.
        let eReopen = c.closeCompleted(cs, closeOp, status: 0)
        let (rs, rConnectOp) = connectTok(eReopen)!
        XCTAssertNotEqual(rs.raw, s.raw)           // a fresh replacement session
        // Replacement connect failure uses the REPLACEMENT token.
        let e = c.operationFailed(rs, rConnectOp, reason: "", engineIsQuiescent: false)
        XCTAssertTrue(hasRestart(e))
        XCTAssertTrue(c.isRestartRequired)
    }

    func test_happyPath_replacementScanCompletes_reachesReady() {
        let (c, s, scanOp) = scanning()
        let eClose = c.operationFailed(s, scanOp, reason: "", engineIsQuiescent: true)
        let (cs, closeOp) = closeTok(eClose)!
        _ = c.requestOpen(profile: "p")
        let eReopen = c.closeCompleted(cs, closeOp, status: 0)
        let (rs, rConnectOp) = connectTok(eReopen)!
        let eScan = c.connectFinished(rs, rConnectOp, result: .remote(interactive: false))
        let (_, rScanOp) = scanTok(eScan)!
        _ = c.scanCompleted(rs, rScanOp)
        XCTAssertFalse(c.isRestartRequired)
        XCTAssertEqual(c.currentSession, rs)       // reopened session is ready
    }

    // MARK: - Blocker 3: replacement scan-failed must NOT be success

    func test_replacementScanFailed_quarantinesHarness_notDone() {
        // Harness in reopening with a recorded replacement.
        let h = H()
        h.arm(.init(session: SID(raw: 1), op: OID(raw: 1), pid: 1, startSec: 0, startUsec: 0, armedAt: 0))
        _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1))
        _ = h.resolveReap(UNISON_REAP_ABSENT)
        _ = h.noteCloseCompleted(status: 0)
        h.noteReplacementOpen(session: SID(raw: 2), op: OID(raw: 2))
        // scan-FAILED for the replacement identity.
        XCTAssertEqual(h.noteReplacementScanFailed(session: SID(raw: 2), op: OID(raw: 2)), .quarantined)
        XCTAssertTrue(h.isQuarantined)
        XCTAssertFalse(h.reopenAllowed)
    }

    func test_replacementScanFailed_wrongIdentity_isIgnored() {
        let h = H()
        h.arm(.init(session: SID(raw: 1), op: OID(raw: 1), pid: 1, startSec: 0, startUsec: 0, armedAt: 0))
        _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1))
        _ = h.resolveReap(UNISON_REAP_ABSENT)
        _ = h.noteCloseCompleted(status: 0)
        h.noteReplacementOpen(session: SID(raw: 2), op: OID(raw: 2))
        XCTAssertEqual(h.noteReplacementScanFailed(session: SID(raw: 9), op: OID(raw: 9)), .ignore)
        XCTAssertFalse(h.isQuarantined)            // unrelated failure ignored
    }

    // MARK: - coordinator-restart accounting

    func test_noteCoordinatorRestart_quarantinesActiveCycle() {
        for setup: (H) -> Void in [
            { h in h.arm(self.b()) },                                   // awaitingTerminal
            { h in h.arm(self.b()); _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1)) }, // awaitingReap
            { h in h.arm(self.b()); _ = h.observeFatal(session: SID(raw: 1), op: OID(raw: 1))
                   _ = h.resolveReap(UNISON_REAP_ABSENT) },             // closing
        ] {
            let h = H(); setup(h)
            h.noteCoordinatorRestart()
            XCTAssertTrue(h.isQuarantined)
        }
    }

    func test_noteCoordinatorRestart_ignoredWhenIdleOrDone() {
        let idle = H(); idle.noteCoordinatorRestart(); XCTAssertFalse(idle.isQuarantined)
    }

    private func b() -> H.Binding {
        .init(session: SID(raw: 1), op: OID(raw: 1), pid: 1, startSec: 0, startUsec: 0, armedAt: 0)
    }

    // MARK: - Pending-slot selection helper (the driver's quarantine choice)

    func test_selectTarget_scanning_failsScanToken_leavesScanning() {
        let (c, s, scanOp) = scanning()
        let t = ScanInterruptRestartTarget.select(scan: (s, scanOp), connect: nil, close: nil)
        XCTAssertEqual(t, .failOp(s, scanOp))
        guard case .failOp(let fs, let fop) = t else { return XCTFail() }
        XCTAssertTrue(hasRestart(c.operationFailed(fs, fop, reason: "", engineIsQuiescent: false)))
        XCTAssertTrue(c.isRestartRequired)
    }

    func test_selectTarget_connect_failsConnectToken() {
        // A replacement in the opening (connect) phase.
        let c = Coord()
        let e1 = c.requestOpen(profile: "p")
        let (s, connectOp) = connectTok(e1)!
        let t = ScanInterruptRestartTarget.select(scan: nil, connect: (s, connectOp), close: nil)
        XCTAssertEqual(t, .failOp(s, connectOp))
        guard case .failOp(let fs, let fop) = t else { return XCTFail() }
        XCTAssertTrue(hasRestart(c.operationFailed(fs, fop, reason: "", engineIsQuiescent: false)))
    }

    func test_selectTarget_close_failsCloseToken() {
        let (c, s, scanOp) = scanning()
        let eClose = c.operationFailed(s, scanOp, reason: "", engineIsQuiescent: true)
        let (cs, closeOp) = closeTok(eClose)!
        _ = c.requestOpen(profile: "p")
        let t = ScanInterruptRestartTarget.select(scan: nil, connect: nil, close: (cs, closeOp))
        XCTAssertEqual(t, .failClose(cs, closeOp))
        guard case .failClose(let fs, let fop) = t else { return XCTFail() }
        XCTAssertTrue(hasRestart(c.closeCompleted(fs, fop, status: 998)))
        XCTAssertTrue(c.isRestartRequired)
    }

    func test_selectTarget_priority_scanBeatsConnectBeatsClose() {
        let s = SID(raw: 1), a = OID(raw: 1), b2 = OID(raw: 2), d = OID(raw: 3)
        XCTAssertEqual(ScanInterruptRestartTarget.select(
            scan: (s, a), connect: (s, b2), close: (s, d)), .failOp(s, a))
        XCTAssertEqual(ScanInterruptRestartTarget.select(
            scan: nil, connect: (s, b2), close: (s, d)), .failOp(s, b2))
        XCTAssertEqual(ScanInterruptRestartTarget.select(
            scan: nil, connect: nil, close: (s, d)), .failClose(s, d))
        XCTAssertEqual(ScanInterruptRestartTarget.select(
            scan: nil, connect: nil, close: nil), .abandon)
    }
}
#endif
