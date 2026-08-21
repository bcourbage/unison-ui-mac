import XCTest
@testable import unison_ui_mac

/// Two Profile Editor fixes (0.1.8):
///  1. Sidebar search must match a section's technical pref keys
///     (e.g. `fastcheck`), not only the visible field labels.
///  2. On save, bottom `include` directives must stay below later-added
///     Advanced keys — `setIncludes` has to run after the key writes.
///
/// `@MainActor` because `sectionKeys` reads the controller's main-actor
/// key-list constants.
@MainActor
final class ProfileEditorFixesTests: XCTestCase {

    // MARK: - 1. Search by technical pref key

    func test_sectionKeys_options_containsFastcheck() {
        // The reported case: searching "fastcheck" should reach Options.
        XCTAssertTrue(
            ProfileFormWindowController.sectionKeys(forTitle: "Options").contains("fastcheck"))
    }

    func test_sectionKeys_roots_containsRootAndSshKeys() {
        let keys = ProfileFormWindowController.sectionKeys(forTitle: "Roots")
        XCTAssertTrue(keys.contains("root"))
        XCTAssertTrue(keys.contains("sshargs"))
        XCTAssertTrue(keys.contains("servercmd"))
    }

    func test_sectionKeys_areLowercased_forCaseInsensitiveMatch() {
        // remoteKeys has the mixed-case "clientHostName"; search lowercases
        // the query, so the key list must be lowercased to match.
        XCTAssertTrue(
            ProfileFormWindowController.sectionKeys(forTitle: "Roots").contains("clienthostname"))
    }

    func test_sectionKeys_fileAttributesAndIgnore() {
        XCTAssertTrue(
            ProfileFormWindowController.sectionKeys(forTitle: "File Attributes").contains("dontchmod"))
        XCTAssertTrue(
            ProfileFormWindowController.sectionKeys(forTitle: "Ignore").contains("ignorenot"))
    }

    func test_sectionKeys_unknownOrKeyless_section_isEmpty() {
        XCTAssertTrue(ProfileFormWindowController.sectionKeys(forTitle: "General").isEmpty)
        XCTAssertTrue(ProfileFormWindowController.sectionKeys(forTitle: "Advanced").isEmpty)
    }

    // MARK: - 2. Bottom include stays last after a key is added

    func test_setIncludes_afterAddingKey_keepsBottomIncludeBelow() {
        // Reproduce the save flow: a bottom include already exists, then a
        // new Advanced key is appended (lands at EOF, i.e. *below* the
        // include), then includes are re-asserted. The include must end up
        // below the new key — the fix calls setIncludes last so it does.
        var doc = ProfileDocument.parse("root = /a\ninclude Shared.prf\n")
        doc.setValues(["true"], forKey: "newpref")   // appends after the include
        doc.setIncludes(
            top: [],
            bottom: [ProfileDocument.IncludeEntry(name: "Shared.prf", comment: "")])

        let lines = doc.serialized.split(separator: "\n").map(String.init)
        let keyIdx = lines.firstIndex { $0.hasPrefix("newpref") }
        let incIdx = lines.firstIndex { $0.hasPrefix("include ") }
        XCTAssertNotNil(keyIdx)
        XCTAssertNotNil(incIdx)
        XCTAssertLessThan(keyIdx!, incIdx!,
                          "bottom include must remain below the newly-added key")
    }

    func test_setIncludes_topStaysAboveFirstPref() {
        // Sanity: top includes are unaffected — still before the first pref.
        var doc = ProfileDocument.parse("root = /a\nignore = Name x\n")
        doc.setIncludes(
            top: [ProfileDocument.IncludeEntry(name: "Common.prf", comment: "")],
            bottom: [])
        let lines = doc.serialized.split(separator: "\n").map(String.init)
        let incIdx = lines.firstIndex { $0.hasPrefix("include ") }
        let rootIdx = lines.firstIndex { $0.hasPrefix("root") }
        XCTAssertNotNil(incIdx)
        XCTAssertNotNil(rootIdx)
        XCTAssertLessThan(incIdx!, rootIdx!, "top include must stay above the first pref")
    }
}
