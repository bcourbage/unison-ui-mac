import XCTest
@testable import unison_ui_mac

/// Pure-logic coverage for the Profiles toolbar item's phase-dependent help
/// text (issue #117). The label and position never change; only the help text
/// varies, and each variant must map to the correct phase.
final class ProfilesHelpTests: XCTestCase {

    // MARK: - Phase mapping

    func test_idle_whenNeitherScanningNorSyncing() {
        XCTAssertEqual(
            ProfilesHelp.forPhase(isScanning: false, isSyncing: false), .idle)
    }

    func test_connectingOrScanning_whenScanningNotSyncing() {
        XCTAssertEqual(
            ProfilesHelp.forPhase(isScanning: true, isSyncing: false),
            .connectingOrScanning)
    }

    func test_synchronizing_whenSyncing() {
        XCTAssertEqual(
            ProfilesHelp.forPhase(isScanning: false, isSyncing: true), .synchronizing)
    }

    /// Sync takes precedence over scan during the transition (matches the gate
    /// and StopItemAppearance ordering).
    func test_syncTakesPrecedenceOverScan() {
        XCTAssertEqual(
            ProfilesHelp.forPhase(isScanning: true, isSyncing: true), .synchronizing)
    }

    // MARK: - Copy content

    func test_eachVariant_hasDistinctNonEmptyText() {
        let texts = [ProfilesHelp.idle, .connectingOrScanning, .synchronizing]
            .map(\.toolTip)
        for t in texts { XCTAssertFalse(t.isEmpty) }
        XCTAssertEqual(Set(texts).count, texts.count, "each phase must read differently")
    }

    func test_allVariants_nameTheProfilesDestination() {
        for h in [ProfilesHelp.idle, .connectingOrScanning, .synchronizing] {
            XCTAssertTrue(h.toolTip.contains("Return to Profiles"),
                          "help should name the destination in every phase")
        }
    }

    func test_scanVariant_statesBackgroundContinuation() {
        XCTAssertTrue(
            ProfilesHelp.connectingOrScanning.toolTip.contains("background"),
            "scan-phase help must say the connection or scan continues in the background")
    }

    func test_syncVariant_warnsOfConfirmation() {
        XCTAssertTrue(
            ProfilesHelp.synchronizing.toolTip.contains("confirmation"),
            "sync-phase help must warn a confirmation appears")
    }

    func test_accessibilityHelp_tracksTooltip() {
        for h in [ProfilesHelp.idle, .connectingOrScanning, .synchronizing] {
            XCTAssertEqual(h.accessibilityHelp, h.toolTip)
        }
    }
}
