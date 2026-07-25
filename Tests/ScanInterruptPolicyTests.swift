import XCTest
@testable import unison_ui_mac

/// Deterministic coverage for the WIRING policy decisions (issue #24): the
/// phase-bound Stop-Scan capability (Blocker 1), reap-poll continuation
/// (Blocker 3), and Profiles/window-close routing (Blocker 2).
final class ScanInterruptPolicyTests: XCTestCase {

    private typealias P = ScanInterruptPolicy
    private typealias Phase = EngineSessionCoordinator.Phase
    private typealias Reap = EngineSessionCoordinator.ReapState
    private typealias SID = EngineSessionCoordinator.SessionID
    private typealias OID = EngineSessionCoordinator.OperationID
    private typealias Ident = EngineSessionCoordinator.TransportIdentity

    private let s = SID(raw: 1)
    private let op = OID(raw: 2)
    private let idA = Ident(pid: 100, startSec: 5, startUsec: 6)

    // MARK: - Blocker 1: capability is bound to the exact .scanning phase

    func test_stopScanAvailable_onlyWhenScanningAndQualified() {
        XCTAssertTrue(P.stopScanAvailable(phase: .scanning(s, op), qualified: true))
    }

    func test_stopScanUnavailable_whenScanningButNotQualified() {
        XCTAssertFalse(P.stopScanAvailable(phase: .scanning(s, op), qualified: false))
    }

    func test_stopScanUnavailable_duringConnectPhase_evenIfQualified() {
        // Qualification can resolve while still .opening (connect). The item must
        // NOT be a genuine Stop Scan there — requestScanInterruption would reject.
        XCTAssertFalse(P.stopScanAvailable(phase: .opening(s, op), qualified: true))
    }

    func test_stopScanUnavailable_inOtherPhases_evenIfQualified() {
        let phases: [Phase] = [
            .idle, .ready(s), .stopped(s),
            .interruptingScan(s, op, .signalling(terminalObserved: false), .stopInPlace),
            .closing(s, op, .toIdle), .restartRequired("x"),
        ]
        for p in phases {
            XCTAssertFalse(P.stopScanAvailable(phase: p, qualified: true),
                           "must be unavailable in \(p)")
        }
    }

    // MARK: - Blocker 3: LIVE/ZOMBIE/UNKNOWN poll until grace; ABSENT/REUSED resolve

    func test_reap_absentOrReused_resolveImmediately() {
        for r: Reap in [.absent, .reused] {
            XCTAssertFalse(P.reapShouldKeepPolling(r, elapsed: 0, grace: 2),
                           "\(r) proves the child is gone → resolve now")
        }
    }

    func test_reap_liveZombieUnknown_keepPollingWithinGrace() {
        for r: Reap in [.live, .zombie, .unknown] {
            XCTAssertTrue(P.reapShouldKeepPolling(r, elapsed: 0.5, grace: 2),
                          "\(r) is inconclusive → keep polling within grace")
        }
    }

    func test_reap_zombie_isNotRejectedImmediately() {
        // Regression for Blocker 3: a ZOMBIE must NOT resolve immediately (it did
        // before, going straight to restart-required).
        XCTAssertTrue(P.reapShouldKeepPolling(.zombie, elapsed: 0.1, grace: 2))
    }

    func test_reap_inconclusive_stopsPollingAfterGrace() {
        for r: Reap in [.live, .zombie, .unknown] {
            XCTAssertFalse(P.reapShouldKeepPolling(r, elapsed: 2.0, grace: 2),
                           "\(r) resolves (to the coordinator) once grace expires")
        }
    }

    // MARK: - Blocker 2: Profiles / window-close routing

    func test_leaveRouting_qualifiedScanning_interruptsReturnToPicker() {
        XCTAssertEqual(P.leaveRouting(phase: .scanning(s, op), qualified: true),
                       .interruptReturnToPicker)
    }

    func test_leaveRouting_unqualifiedScanning_leavesImmediately() {
        XCTAssertEqual(P.leaveRouting(phase: .scanning(s, op), qualified: false),
                       .leaveImmediately)
    }

    func test_leaveRouting_interrupting_abandonUpgrade() {
        let p: Phase = .interruptingScan(s, op, .awaitingReap(idA), .stopInPlace)
        XCTAssertEqual(P.leaveRouting(phase: p, qualified: true), .abandonUpgrade)
        // Even if the cached qualification is unknown/false, an in-flight
        // interruption still upgrades rather than leaving immediately.
        XCTAssertEqual(P.leaveRouting(phase: p, qualified: false), .abandonUpgrade)
    }

    func test_leaveRouting_connectPhase_leavesImmediately() {
        // During connect there is no scan to interrupt — honest immediate leave.
        XCTAssertEqual(P.leaveRouting(phase: .opening(s, op), qualified: true),
                       .leaveImmediately)
    }

    func test_leaveRouting_ready_leavesImmediately() {
        XCTAssertEqual(P.leaveRouting(phase: .ready(s), qualified: true), .leaveImmediately)
    }
}
