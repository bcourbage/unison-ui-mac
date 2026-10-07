import XCTest
@testable import unison_ui_mac

/// Profile picker and form polish (1.0 UI review P1, P2, P3, P9): the empty
/// picker offers a next action, Run follows the selection, long names
/// truncate with a tooltip, a search with no matches says so, and the name
/// is validated inline with Save following the result.
@MainActor
final class ProfilePolishTests: XCTestCase {

    private var dir: String!

    override func setUp() async throws {
        dir = NSTemporaryDirectory() + "ProfilePolishTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func picker(prefs: ProfilePreferences = ProfilePreferences()) -> ProfileWindowController {
        let p = ProfileWindowController(unisonDirectory: dir) { _ in }
        p.preferencesLoader = { prefs }
        p.reloadForTesting()
        return p
    }

    // MARK: - P1 empty picker

    func test_noProfiles_showsCreateAction_andRunDisabled() {
        let p = picker()
        XCTAssertEqual(p.emptyStateForTesting?.text, "No profiles yet")
        XCTAssertEqual(p.emptyStateForTesting?.button, "Create Profile…")
        XCTAssertFalse(p.isRunEnabledForTesting)
        var asked: [Bool] = []
        p.onManageProfiles = { asked.append($0) }
        p.performEmptyStateActionForTesting()
        XCTAssertEqual(asked, [true], "Create Profile… asks for a new profile")
    }

    func test_allHidden_showsManageAction() throws {
        try write("a.prf", "root = /a\nroot = /b\n")
        let p = picker(prefs: ProfilePreferences(hidden: ["a"]))
        XCTAssertEqual(p.emptyStateForTesting?.text, "All profiles are hidden")
        XCTAssertEqual(p.emptyStateForTesting?.button, "Manage Profiles…")
        XCTAssertFalse(p.isRunEnabledForTesting)
        var asked: [Bool] = []
        p.onManageProfiles = { asked.append($0) }
        p.performEmptyStateActionForTesting()
        XCTAssertEqual(asked, [false], "Manage Profiles… opens the editor without a new form")
    }

    func test_withProfiles_noEmptyState_runFollowsSelection() throws {
        try write("a.prf", "root = /a\nroot = /b\n")
        let p = picker()
        XCTAssertNil(p.emptyStateForTesting)
        XCTAssertTrue(p.isRunEnabledForTesting, "reload selects a row by default")
        p.selectRowForTesting(nil)
        XCTAssertFalse(p.isRunEnabledForTesting)
        p.selectRowForTesting(0)
        XCTAssertTrue(p.isRunEnabledForTesting)
    }

    // MARK: - P2 truncation

    func test_pickerCell_truncatesMiddle_withFullNameTooltip() throws {
        let long = "a-very-long-profile-name-that-does-not-fit-the-list-width-at-all"
        try write("\(long).prf", "root = /a\nroot = /b\n")
        let p = picker()
        let cell = try XCTUnwrap(p.cellForTesting(row: 0))
        XCTAssertEqual(cell.textField?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(cell.textField?.toolTip, long)
        XCTAssertEqual(cell.textField?.stringValue, long)
    }

    // MARK: - P3 search with no matches

    func test_search_noMatches_showsTextAndClearRestores() throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: "p", onSaved: { _ in })
        XCTAssertNil(c.noMatchesTextForTesting)
        c.setSearchForTesting("not-a-setting")
        XCTAssertEqual(c.noMatchesTextForTesting, "No settings match “not-a-setting”.")
        XCTAssertNil(c.shownSectionTitleForTesting)
        c.clearSearchForTesting()
        XCTAssertNil(c.noMatchesTextForTesting)
        XCTAssertNotNil(c.shownSectionTitleForTesting, "a section is shown again")
    }

    func test_search_withMatches_showsNoPlaceholder() throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: "p", onSaved: { _ in })
        c.setSearchForTesting("fast")
        XCTAssertNil(c.noMatchesTextForTesting)
        XCTAssertEqual(c.shownSectionTitleForTesting, "Options")
    }

    // MARK: - P9 inline validation

    func test_nameProblem_rules() {
        XCTAssertEqual(ProfileFormWindowController.nameProblem(""), "Profile name required.")
        XCTAssertEqual(ProfileFormWindowController.nameProblem("   "), "Profile name required.")
        XCTAssertEqual(ProfileFormWindowController.nameProblem("a/b"), "Profile names can't contain slashes or colons.")
        XCTAssertEqual(ProfileFormWindowController.nameProblem("a:b"), "Profile names can't contain slashes or colons.")
        XCTAssertNil(ProfileFormWindowController.nameProblem("home"))
    }

    func test_newProfile_saveDisabledUntilNamed_errorOnlyAfterEditing() {
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: nil, onSaved: { _ in })
        XCTAssertFalse(c.isSaveEnabledForTesting, "no name yet")
        XCTAssertNil(c.nameValidationTextForTesting, "a fresh form is not an error yet")
        c.typeNameForTesting("a/b")
        XCTAssertEqual(c.nameValidationTextForTesting, "Profile names can't contain slashes or colons.")
        XCTAssertFalse(c.isSaveEnabledForTesting)
        c.typeNameForTesting("")
        XCTAssertEqual(c.nameValidationTextForTesting, "Profile name required.")
        c.typeNameForTesting("home")
        XCTAssertNil(c.nameValidationTextForTesting)
        XCTAssertTrue(c.isSaveEnabledForTesting)
    }

    func test_existingProfile_saveEnabled_noError() throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: "p", onSaved: { _ in })
        XCTAssertTrue(c.isSaveEnabledForTesting)
        XCTAssertNil(c.nameValidationTextForTesting)
    }

    func test_unsavedProfile_checkRemoteDisabled_withPrerequisiteShown() {
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: nil, onSaved: { _ in })
        XCTAssertFalse(c.isCheckRemoteEnabledForTesting)
        XCTAssertEqual(c.checkStatusForTesting, "Save the profile once before checking its remote command.")
    }

    func test_savedProfile_checkRemoteEnabled() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\n")
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: "p", onSaved: { _ in })
        XCTAssertTrue(c.isCheckRemoteEnabledForTesting)
        XCTAssertNil(c.checkStatusForTesting)
    }
}
