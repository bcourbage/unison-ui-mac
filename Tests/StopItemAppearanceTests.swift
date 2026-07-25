import XCTest
@testable import unison_ui_mac

/// Pure-logic coverage for the Stop toolbar item's phase-aware copy. The
/// decision lives in `StopItemAppearance` so it's testable without an AppKit
/// toolbar-validation harness. See issue #24 follow-up (honest scan-phase
/// copy).
final class StopItemAppearanceTests: XCTestCase {

    // MARK: - Phase mapping

    func test_scanning_notSyncing_isReturnToProfiles() {
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: true, isSyncing: false),
            .returnToProfiles)
    }

    func test_syncing_isStopSync() {
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: false, isSyncing: true),
            .stopSync)
    }

    func test_syncTakesPrecedence_whenBothFlagsSet() {
        // During the scan→sync transition isScanning can still read true; a
        // running sync must win so the item is a real sync-abort, not a
        // return-to-profiles.
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: true, isSyncing: true),
            .stopSync)
    }

    func test_neitherPhase_defaultsToStopSync() {
        // Item is disabled outside sync/scan anyway; the label just shouldn't
        // claim "Return to Profiles" when nothing is connecting.
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: false, isSyncing: false),
            .stopSync)
    }

    // MARK: - Copy is honest and em-dash-free

    func test_returnToProfiles_copy() {
        let a = StopItemAppearance.returnToProfiles
        XCTAssertEqual(a.label, "Return to Profiles")
        XCTAssertEqual(a.toolTip, "Return to the profile list")
        XCTAssertEqual(a.progressSummary, "Returning to profiles…")
        // Must not claim to stop/cancel a sync that isn't running.
        XCTAssertFalse(a.label.lowercased().contains("stop"))
        XCTAssertFalse(a.toolTip.lowercased().contains("synchronization"))
    }

    func test_stopSync_copy() {
        let a = StopItemAppearance.stopSync
        XCTAssertEqual(a.label, "Stop")
        XCTAssertEqual(a.toolTip, "Cancel the running synchronization")
    }

    // MARK: - Icon + tint

    func test_returnToProfiles_icon_isNeutralNavGlyph_normalTint() {
        let a = StopItemAppearance.returnToProfiles
        // A neutral back-navigation glyph, NOT the red stop sign — the action
        // does not interrupt the scan.
        XCTAssertEqual(a.systemSymbol, "chevron.backward")
        XCTAssertNotEqual(a.systemSymbol, "stop.fill")
        XCTAssertEqual(a.tint, .normal)
        XCTAssertNotEqual(a.tint, .destructive)
    }

    func test_stopSync_icon_isRedStop() {
        let a = StopItemAppearance.stopSync
        XCTAssertEqual(a.systemSymbol, "stop.fill")
        XCTAssertEqual(a.tint, .destructive)
    }

    func test_phasesDifferInIconAndTint() {
        // The two phases must be visually distinct, not just relabelled.
        XCTAssertNotEqual(StopItemAppearance.returnToProfiles.systemSymbol,
                          StopItemAppearance.stopSync.systemSymbol)
        XCTAssertNotEqual(StopItemAppearance.returnToProfiles.tint,
                          StopItemAppearance.stopSync.tint)
    }

    func test_noEmDashInAnyCopy() {
        for a in [StopItemAppearance.stopSync, .returnToProfiles, .stopScan] {
            for s in [a.label, a.toolTip, a.progressSummary] {
                XCTAssertFalse(s.contains("—"), "em-dash in user-facing copy: \(s)")
            }
        }
    }

    // MARK: - Phase 1a: genuine Stop Scan (issue #24 Wiring)

    func test_scanning_qualified_isStopScan() {
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: true, isSyncing: false,
                                        scanInterruptAvailable: true),
            .stopScan)
    }

    func test_scanning_notQualified_isReturnToProfiles() {
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: true, isSyncing: false,
                                        scanInterruptAvailable: false),
            .returnToProfiles)
    }

    func test_syncing_ignoresScanInterruptAvailable() {
        // A running sync is always a sync-abort, even if the (stale) scan-
        // interrupt flag is still set during the transition.
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: true, isSyncing: true,
                                        scanInterruptAvailable: true),
            .stopSync)
    }

    func test_stopScan_copy_isHonestAboutInterrupting() {
        let a = StopItemAppearance.stopScan
        XCTAssertEqual(a.label, "Stop Scan")
        XCTAssertEqual(a.progressSummary, "Stopping scan…")
        // It genuinely interrupts, so unlike returnToProfiles it may say "stop".
        XCTAssertTrue(a.label.lowercased().contains("stop"))
    }

    func test_stopScan_icon_isRedStop_destructiveTint() {
        let a = StopItemAppearance.stopScan
        XCTAssertEqual(a.systemSymbol, "stop.fill")
        XCTAssertEqual(a.tint, .destructive)   // stops in-flight engine work
    }

    func test_stopScan_visuallyDistinctFromReturnToProfiles() {
        XCTAssertNotEqual(StopItemAppearance.stopScan.tint,
                          StopItemAppearance.returnToProfiles.tint)
        XCTAssertNotEqual(StopItemAppearance.stopScan.label,
                          StopItemAppearance.returnToProfiles.label)
    }

    func test_forPhase_defaultAvailability_isFalse_returnToProfiles() {
        // Back-compat: omitting the new parameter keeps the honest fallback.
        XCTAssertEqual(
            StopItemAppearance.forPhase(isScanning: true, isSyncing: false),
            .returnToProfiles)
    }
}
