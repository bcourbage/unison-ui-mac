import XCTest
@testable import unison_ui_mac

/// The omitted-`-ui` default and its one-time migration. The migration reads the
/// same keys `CommandLineSetupPreference` writes, so these tests exercise the two
/// together against an isolated defaults suite rather than the real domain.
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

    // MARK: fresh account → graphic

    func test_freshAccount_resolvesToGraphic_andPersistsIt() {
        XCTAssertNil(defaults.string(forKey: D.key))
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
        // Persisted, so a later preference write cannot flip the resolved default.
        XCTAssertEqual(defaults.string(forKey: D.key), "graphic")
    }

    // MARK: upgraded account → text

    func test_accountWithKeepPreference_resolvesToText() {
        defaults.set(true, forKey: CommandLineSetupPreference.keepKey)
        XCTAssertEqual(D.resolved(defaults: defaults), .text)
        XCTAssertEqual(defaults.string(forKey: D.key), "text")
    }

    func test_accountWithKeepPreferenceOff_stillResolvesToText() {
        // The value of the old preference does not matter, only that the account
        // ran a version whose omitted default was text.
        defaults.set(false, forKey: CommandLineSetupPreference.keepKey)
        XCTAssertEqual(D.resolved(defaults: defaults), .text)
    }

    func test_accountWithLegacyDoNotAskKey_resolvesToText() {
        defaults.set(true, forKey: CommandLineSetupPreference.legacyDoNotAskKey)
        XCTAssertEqual(D.resolved(defaults: defaults), .text)
    }

    func test_accountWithLegacyDoNotAskKeyFalse_resolvesToText() {
        defaults.set(false, forKey: CommandLineSetupPreference.legacyDoNotAskKey)
        XCTAssertEqual(D.resolved(defaults: defaults), .text)
    }

    // MARK: an already-stored value is authoritative

    func test_storedGraphic_isRespected_evenWithUpgradeMarkers() {
        defaults.set("graphic", forKey: D.key)
        defaults.set(true, forKey: CommandLineSetupPreference.keepKey)
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
    }

    func test_storedText_isRespected_onFreshLookingAccount() {
        defaults.set("text", forKey: D.key)
        XCTAssertEqual(D.resolved(defaults: defaults), .text)
    }

    func test_unrecognizedStoredValue_fallsBackToMigration() {
        defaults.set("verbose", forKey: D.key)
        // No upgrade markers → treated as a fresh account.
        XCTAssertEqual(D.resolved(defaults: defaults), .graphic)
    }

    // MARK: current() reads without persisting

    func test_current_doesNotPersist_soSettingsDoesNotMigrate() {
        XCTAssertNil(defaults.string(forKey: D.key))
        XCTAssertEqual(D.current(defaults: defaults), .graphic)
        // No write: an account that only opened Settings is still unresolved.
        XCTAssertNil(defaults.string(forKey: D.key))
    }

    func test_current_matchesResolved_onUpgradedAccount() {
        defaults.set(true, forKey: CommandLineSetupPreference.keepKey)
        XCTAssertEqual(D.current(defaults: defaults), .text)
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
