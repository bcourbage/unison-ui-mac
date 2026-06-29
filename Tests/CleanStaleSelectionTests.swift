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
}
