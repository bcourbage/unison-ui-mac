import XCTest
@testable import unison_ui_mac

/// Clean Stale window helpers that remain pure: per-row uncertainty folding and
/// the attribution warning banner. (Preselection is now driven by
/// `ArchiveStaleScanner.Finding.actionable` — see ArchiveStaleScannerTests — so
/// the former `defaultsToChecked`/`isLocalOnly` heuristics and their tests are
/// gone: orphans and "probably old" copies are non-actionable, never preselected.)
@MainActor
final class CleanStaleSelectionTests: XCTestCase {

    private func rowUncertain(_ finding: Bool, _ global: Bool) -> Bool {
        CleanStaleArchivesWindowController.rowUncertain(
            findingUncertain: finding, globalUncertain: global)
    }

    func test_rowUncertain_globalUncertaintyForcesUncertain() {
        XCTAssertTrue(rowUncertain(false, true), "global uncertainty overrides a certain finding")
        XCTAssertTrue(rowUncertain(true, false))
        XCTAssertFalse(rowUncertain(false, false))
    }

    func test_attributionWarning_nilWhenClean() {
        XCTAssertNil(CleanStaleArchivesWindowController.attributionWarning(
            enumerationFailed: false, unresolvedProfiles: []))
    }

    func test_attributionWarning_enumerationFailure_mentionsUnreadableDirectory() {
        let w = CleanStaleArchivesWindowController.attributionWarning(
            enumerationFailed: true, unresolvedProfiles: [])
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.contains("could not be read"))
        XCTAssertTrue(w!.lowercased().contains("uncertain"))
        XCTAssertTrue(w!.lowercased().contains("none are preselected"))
    }

    func test_attributionWarning_unresolvedProfiles_areNamed_andMentionIncludes() {
        let w = CleanStaleArchivesWindowController.attributionWarning(
            enumerationFailed: false, unresolvedProfiles: ["zed", "alpha"])
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.contains("unresolved or unreadable includes"))
        XCTAssertTrue(w!.contains("alpha, zed"))
    }

    func test_attributionWarning_noEmDash() {
        let w = CleanStaleArchivesWindowController.attributionWarning(
            enumerationFailed: true, unresolvedProfiles: ["p"])
        XCTAssertNotNil(w)
        XCTAssertFalse(w!.contains("—"))
    }
}
