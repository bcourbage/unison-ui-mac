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

    func test_noEmDashInAnyCopy() {
        for a in [StopItemAppearance.stopSync, .returnToProfiles] {
            for s in [a.label, a.toolTip, a.progressSummary] {
                XCTAssertFalse(s.contains("—"), "em-dash in user-facing copy: \(s)")
            }
        }
    }
}
