import XCTest
@testable import unison_ui_mac

/// Tests for the Clean Stale window's default-selection policy: only
/// archives provably this machine's own dead state are checked by default;
/// cross-machine orphans (possible remote-initiated syncs) and uncertain
/// rows are left unchecked, independent of how recently they were modified.
@MainActor
final class CleanStaleSelectionTests: XCTestCase {

    private func defaults(owned: Bool, uncertain: Bool, localOnly: Bool) -> Bool {
        CleanStaleArchivesWindowController.defaultsToChecked(
            owned: owned, uncertain: uncertain, localOnly: localOnly)
    }

    func test_ownedSuperseded_isCheckedByDefault() {
        XCTAssertTrue(defaults(owned: true, uncertain: false, localOnly: false))
    }

    func test_localOnlyOrphan_isCheckedByDefault() {
        XCTAssertTrue(defaults(owned: false, uncertain: false, localOnly: true))
    }

    func test_crossMachineOrphan_isUncheckedByDefault() {
        // The remote-server case: another machine could own it.
        XCTAssertFalse(defaults(owned: false, uncertain: false, localOnly: false))
    }

    func test_uncertain_isNeverCheckedByDefault() {
        XCTAssertFalse(defaults(owned: true, uncertain: true, localOnly: true))
    }

    func test_isLocalOnly_allCurrentHostnameLineage() {
        XCTAssertTrue(CleanStaleArchivesWindowController.isLocalOnly(
            roots: ["//Heracles.local//private/tmp/itest/a", "//Heracles//private/tmp/itest/b"],
            currentLabel: "heracles"))
    }

    func test_isLocalOnly_crossMachine_isFalse() {
        XCTAssertFalse(CleanStaleArchivesWindowController.isLocalOnly(
            roots: ["//Heracles//Users/bcourbage", "//Demeter//Users/bcourbage"],
            currentLabel: "heracles"))
    }

    func test_isLocalOnly_formerMachineName_isFalse() {
        // A former name counts as cross-machine — the safe side.
        XCTAssertFalse(CleanStaleArchivesWindowController.isLocalOnly(
            roots: ["//MacBookPro//Users/bcourbage", "//MacBookPro//x"],
            currentLabel: "heracles"))
    }

    // MARK: - Global uncertainty (Finding #9 review)

    private func rowUncertain(_ finding: Bool, _ global: Bool) -> Bool {
        CleanStaleArchivesWindowController.rowUncertain(
            findingUncertain: finding, globalUncertain: global)
    }

    func test_rowUncertain_globalUncertaintyForcesUncertain() {
        XCTAssertTrue(rowUncertain(false, true), "global uncertainty overrides a certain finding")
        XCTAssertTrue(rowUncertain(true, false))
        XCTAssertFalse(rowUncertain(false, false))
    }

    func test_noDestructivePreselect_underGlobalUncertainty() {
        // The dangerous case: a local-only orphan (owned=false, localOnly=true)
        // would normally be checked by default. When the Unison directory can't
        // be enumerated we don't actually know it's an orphan, so global
        // uncertainty must force it uncertain and therefore NOT preselected.
        let uncertain = rowUncertain(false, /*global*/ true)
        XCTAssertFalse(defaults(owned: false, uncertain: uncertain, localOnly: true),
                       "no archive may be preselected for deletion under global uncertainty")
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
        // Names sorted for stable display.
        XCTAssertTrue(w!.contains("alpha, zed"))
    }

    func test_attributionWarning_noEmDash() {
        let w = CleanStaleArchivesWindowController.attributionWarning(
            enumerationFailed: true, unresolvedProfiles: ["p"])
        XCTAssertNotNil(w)
        XCTAssertFalse(w!.contains("—"))
    }
}
