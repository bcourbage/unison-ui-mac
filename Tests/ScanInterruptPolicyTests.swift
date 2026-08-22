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

    // MARK: - Master switch (terminal-causality fix): stop-in-place disabled
    //
    // `interruptReady` now folds in `stopInPlaceEnabled`, held OFF because no
    // terminal event carries an authenticated transport-interruption cause (a
    // `scanFailed`/fatal racing the SIGKILL is indistinguishable from the kill's
    // own transport EOF, and would launder a restart-required engine into a
    // reusable `.stopped`). While disabled, `interruptReady` is false for EVERY
    // (qualified, sawRemoteWait) combination, and — because Stop Scan, Profiles,
    // and window-close all consume it — all three route to the honest
    // Return-to-Profiles path. The finding-#3 qualified∧remoteWait distinction is
    // retained behind the switch (the pure routing functions below still honor a
    // hypothetical `qualified: true`), but it is dormant in the shipping app.

    func test_interruptReady_disabledByMasterSwitch_falseForAllInputs() {
        XCTAssertFalse(P.stopInPlaceEnabled, "shipping default: stop-in-place is disabled")
        for q in [true, false] {
            for w in [true, false] {
                XCTAssertFalse(P.interruptReady(qualified: q, sawRemoteWait: w),
                               "disabled → interruptReady must be false (qualified: \(q), remoteWait: \(w))")
            }
        }
    }

    func test_disabled_stopScanAffordanceInactive_evenQualifiedAndTransportBlocked() {
        // The driver feeds `interruptReady` as `qualified:`. With the switch off,
        // even a qualified, transport-blocked scan does NOT expose Stop Scan.
        let ready = P.interruptReady(qualified: true, sawRemoteWait: true)
        XCTAssertFalse(P.stopScanAvailable(phase: .scanning(s, op), qualified: ready))
    }

    func test_disabled_profilesAndWindowClose_routeLeaveImmediately() {
        // Profiles and window-close both consult `leaveRouting`/`allowWindowClose`
        // with `interruptReady` — disabled → honest immediate leave, close allowed,
        // not handled by the (dead) interruption path.
        let ready = P.interruptReady(qualified: true, sawRemoteWait: true)
        let phase: Phase = .scanning(s, op)
        XCTAssertEqual(P.leaveRouting(phase: phase, qualified: ready), .leaveImmediately)
        XCTAssertTrue(P.allowWindowClose(phase: phase, qualified: ready))
        XCTAssertFalse(P.profilesHandledByInterruption(phase: phase, qualified: ready))
    }

    func test_disabled_signalRefused_noSIGKILL_evenWithExactPendingOp() {
        // The authoritative pre-SIGKILL checkpoint: disabled → refused even when
        // the signal targets the exact pending op.
        let ready = P.interruptReady(qualified: true, sawRemoteWait: true)
        XCTAssertFalse(P.signalAuthorized(interruptReady: ready, pendingScanMatches: true))
    }

    // The pure `signalAuthorized` contract itself (independent of the switch):
    // proceed only when interruptible-in-place AND the exact pending op matches.
    func test_signalAuthorized_pureContract_requiresBothInputs() {
        XCTAssertTrue(P.signalAuthorized(interruptReady: true, pendingScanMatches: true))
        XCTAssertFalse(P.signalAuthorized(interruptReady: false, pendingScanMatches: true))
        XCTAssertFalse(P.signalAuthorized(interruptReady: true, pendingScanMatches: false))
        XCTAssertFalse(P.signalAuthorized(interruptReady: false, pendingScanMatches: false))
    }

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

    // MARK: - Finding 1: windowShouldClose must VETO during interruption

    func test_allowWindowClose_vetoedForQualifiedScanning() {
        // The close is vetoed so the window + cached qualification are retained
        // until the coordinator's .closeWindow fires (else the second signal-time
        // qualification check would fail and the last-window-close could quit).
        XCTAssertFalse(P.allowWindowClose(phase: .scanning(s, op), qualified: true))
    }

    func test_allowWindowClose_vetoedWhileInterrupting() {
        let p: Phase = .interruptingScan(s, op, .signalling(terminalObserved: false), .stopInPlace)
        XCTAssertFalse(P.allowWindowClose(phase: p, qualified: true))
    }

    func test_allowWindowClose_allowedForUnqualifiedScan() {
        XCTAssertTrue(P.allowWindowClose(phase: .scanning(s, op), qualified: false))
    }

    func test_allowWindowClose_allowedInConnectAndReady() {
        XCTAssertTrue(P.allowWindowClose(phase: .opening(s, op), qualified: true))
        XCTAssertTrue(P.allowWindowClose(phase: .ready(s), qualified: true))
    }

    // MARK: - Round 3 correction 1: Profiles during sync cannot bypass confirmation

    func test_profilesDuringSync_notHandled_soFallsBackToPerformClose() {
        // During a running sync, Profiles must NOT be handled by the interruption
        // path — so returnToPicker() falls back to performClose(), which routes
        // through windowShouldClose and cannot bypass the three-way sync
        // confirmation.
        XCTAssertFalse(P.profilesHandledByInterruption(phase: .syncing(s, op), qualified: true))
    }

    func test_leaveRouting_syncing_leavesImmediately() {
        XCTAssertEqual(P.leaveRouting(phase: .syncing(s, op), qualified: true), .leaveImmediately)
    }

    func test_profilesDuringQualifiedScan_isHandledByInterruption() {
        XCTAssertTrue(P.profilesHandledByInterruption(phase: .scanning(s, op), qualified: true))
    }

    func test_profilesDuringInterruption_isHandled() {
        let p: Phase = .interruptingScan(s, op, .signalling(terminalObserved: false), .stopInPlace)
        XCTAssertTrue(P.profilesHandledByInterruption(phase: p, qualified: true))
    }

    func test_profilesWhenUnqualifiedScan_notHandled() {
        XCTAssertFalse(P.profilesHandledByInterruption(phase: .scanning(s, op), qualified: false))
    }

    // MARK: - Live-matrix finding: transient "archives are locked" recognition

    func test_isArchiveLockFatal_recognizesUnisonLockMessage() {
        let msg = """
        Warning: the archives are locked.
        If no other instance of unison is running, the locks should be removed.
        The file /Users/x/Library/Application Support/Unison/lk98490 on host Demeter should be deleted
        """
        XCTAssertTrue(P.isArchiveLockFatal(msg))
    }

    func test_isArchiveLockFatal_caseInsensitive() {
        XCTAssertTrue(P.isArchiveLockFatal("The Archives Are Locked."))
    }

    func test_isArchiveLockFatal_ignoresUnrelatedFatals() {
        XCTAssertFalse(P.isArchiveLockFatal("Lost connection with the server"))
        XCTAssertFalse(P.isArchiveLockFatal("archive files are missing on one replica"))
        XCTAssertFalse(P.isArchiveLockFatal(""))
    }
}
