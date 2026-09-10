import XCTest
@testable import unison_ui_mac

/// The log-path field's end-of-editing decision. Ending edit fires when the
/// field resigns first responder, including on a tab switch with no edit, so an
/// unchanged value must be ignored — otherwise leaving the Logging tab re-prompts
/// "Apply to all profiles?".
final class LogPathEndEditTests: XCTestCase {
    private typealias C = SettingsWindowController

    func test_unchangedValue_isIgnored() {
        // The reported bug: a tab switch ends editing with the stored value
        // unchanged; it must not persist or prompt.
        XCTAssertEqual(C.logPathEndEdit(entered: "/Users/x/Library/Application Support/Unison",
                                        stored: "/Users/x/Library/Application Support/Unison"),
                       .ignore)
        XCTAssertEqual(C.logPathEndEdit(entered: "", stored: ""), .ignore)
    }

    func test_changedValue_persists() {
        XCTAssertEqual(C.logPathEndEdit(entered: "/new/path", stored: "/old/path"), .persist)
        XCTAssertEqual(C.logPathEndEdit(entered: "/first", stored: ""), .persist)
    }
}
