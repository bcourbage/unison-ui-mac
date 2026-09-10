import XCTest
@testable import unison_ui_mac

/// The omitted-`-ui` default: graphical when nothing is saved, a saved choice
/// otherwise, with no per-account migration. Exercised against an isolated
/// defaults suite rather than the real domain.
final class CommandLineDefaultInterfaceTests: XCTestCase {

    private typealias D = CommandLineDefaultInterface

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CommandLineDefaultInterfaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: no saved preference → graphic

    func test_noSavedPreference_resolvesToGraphic_andPersistsIt() {
        XCTAssertNil(defaults.string(forKey: D.key))
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
        // Persisted, so the stored value matches what a bare `unison` used.
        XCTAssertEqual(defaults.string(forKey: D.key), "graphic")
    }

    // MARK: a saved value is honored, whatever the account history

    func test_savedGraphic_isRespected() {
        defaults.set("graphic", forKey: D.key)
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
    }

    func test_savedText_isRespected() {
        defaults.set("text", forKey: D.key)
        XCTAssertEqual(D.resolved(defaults: defaults), .text)
    }

    func test_unrecognizedStoredValue_fallsBackToGraphic() {
        defaults.set("verbose", forKey: D.key)
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
    }

    // MARK: no migration — prior command-line-setup keys do not force text

    func test_priorCommandLineSetupKeys_doNotForceText() {
        // Keys an earlier version may have written must not change the default;
        // an account without a saved interface preference still gets graphical.
        defaults.set(true, forKey: CommandLineSetupPreference.keepKey)
        defaults.set(true, forKey: CommandLineSetupPreference.legacyDoNotAskKey)
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
    }

    // MARK: current() reads without persisting

    func test_current_doesNotPersist() {
        XCTAssertNil(defaults.string(forKey: D.key))
        XCTAssertEqual(D.current(defaults: defaults), .graphic)
        // No write: an account that only opened Settings has nothing saved.
        XCTAssertNil(defaults.string(forKey: D.key))
    }

    // MARK: explicit set

    func test_set_overwritesTheStoredValue() {
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
        D.set(.text, defaults: defaults)
        XCTAssertEqual(D.resolved(defaults: defaults), .text)
        D.set(.graphic, defaults: defaults)
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
    }

    // MARK: launch-time resolution is skipped under the test host and the smoke

    func test_shouldResolveOnLaunch_trueForANormalLaunch() {
        XCTAssertTrue(D.shouldResolveOnLaunch(environment: [:]))
        XCTAssertTrue(D.shouldResolveOnLaunch(environment: ["PATH": "/usr/bin"]))
    }

    func test_shouldResolveOnLaunch_falseUnderXCTest() {
        XCTAssertFalse(D.shouldResolveOnLaunch(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    func test_shouldResolveOnLaunch_falseUnderLaunchSmoke() {
        // The macOS-baseline smoke launches the release-built app and must not
        // persist the preference into the real defaults domain.
        XCTAssertFalse(D.shouldResolveOnLaunch(environment: ["UNISON_UI_SMOKE": "1"]))
    }

    // MARK: uiArgument matches Unison's interface names

    func test_uiArgument_matchesUnisonInterfaceNames() {
        XCTAssertEqual(D.graphic.uiArgument, "graphic")
        XCTAssertEqual(D.text.uiArgument, "text")
    }

    // MARK: the resolved default feeds engineArguments

    func test_resolvedDefault_drivesEngineArguments() {
        let exe = "/Applications/unison-ui-mac.app/Contents/MacOS/unison-ui-mac"
        let fresh = D.resolved(defaults: defaults).uiArgument
        XCTAssertEqual(CommandLineInvocationPolicy.engineArguments([exe, "work"], defaultInterface: fresh),
                       [exe, "-ui", "graphic", "work"])
    }
}
