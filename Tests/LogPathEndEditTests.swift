import XCTest
@testable import unison_ui_mac

/// The log-path field's end-of-editing decision. Ending edit fires when the
/// field resigns first responder, including on a tab switch with no edit, so an
/// unchanged value must be ignored — otherwise leaving the Logging tab re-prompts
/// "Apply to all profiles?". The comparison must use the field's own
/// representation (the raw stored string), not the getters that default and
/// expand `~`.
final class LogPathEndEditTests: XCTestCase {
    private typealias C = SettingsWindowController

    func test_unchangedValue_isIgnored() {
        XCTAssertEqual(C.logPathEndEdit(entered: "/Users/x/Library/Application Support/Unison",
                                        stored: "/Users/x/Library/Application Support/Unison"),
                       .ignore)
        XCTAssertEqual(C.logPathEndEdit(entered: "", stored: ""), .ignore)            // unset
        XCTAssertEqual(C.logPathEndEdit(entered: "~/logs", stored: "~/logs"), .ignore) // tilde, unchanged
        XCTAssertEqual(C.logPathEndEdit(entered: "  ~/logs ", stored: "~/logs"), .ignore) // whitespace only
    }

    func test_changedValue_persists() {
        XCTAssertEqual(C.logPathEndEdit(entered: "/new/path", stored: "/old/path"), .persist)
        XCTAssertEqual(C.logPathEndEdit(entered: "/first", stored: ""), .persist)
    }

    /// The field/getter mismatch that made the fix incomplete: `rawStoredLogPath`
    /// returns exactly what the field shows (raw "" or "~/x"), while the getters
    /// supply a default and expand `~`. Using the getter would make an unset or
    /// tilde field look changed and re-prompt on a tab switch.
    func test_rawStoredLogPath_matchesFieldRepresentation_soUnsetAndTildeAreIgnored() {
        let suite = "logpath-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        // Unset: the field shows "", raw returns "", but the getter returns a default.
        XCTAssertEqual(C.rawStoredLogPath(for: .sameDirectory, in: d), "")
        XCTAssertNotEqual(SettingsModel.sharedLogDirectory(in: d), "",
                          "the getter supplies a default path, so it must not be used for the comparison")
        XCTAssertEqual(C.logPathEndEdit(entered: "",
                                        stored: C.rawStoredLogPath(for: .sameDirectory, in: d)),
                       .ignore)

        // Tilde: the field shows "~/logs", raw returns "~/logs", the getter expands it.
        d.set("~/logs", forKey: SettingsModel.sharedLogDirectoryKey)
        XCTAssertEqual(C.rawStoredLogPath(for: .sameDirectory, in: d), "~/logs")
        XCTAssertEqual(SettingsModel.sharedLogDirectory(in: d),
                       ("~/logs" as NSString).expandingTildeInPath,
                       "the getter expands the tilde, so it must not be used for the comparison")
        XCTAssertEqual(C.logPathEndEdit(entered: "~/logs",
                                        stored: C.rawStoredLogPath(for: .sameDirectory, in: d)),
                       .ignore)
    }
}
