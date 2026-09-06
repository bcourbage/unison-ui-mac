import XCTest
@testable import unison_ui_mac

/// The mode table from docs/cli-launcher-design.md, one test per row plus the
/// edges around it. The policy is pure, so nothing here touches AppKit or the
/// engine.
final class CommandLineInvocationPolicyTests: XCTestCase {

    private typealias P = CommandLineInvocationPolicy
    private let exe = "/Applications/unison-ui-mac.app/Contents/MacOS/unison-ui-mac"

    private func classify(_ args: [String], session: Bool, tty: Bool, test: Bool = false) -> CommandLineInvocation {
        P.classify(arguments: [exe] + args, hasWindowServerSession: session, stdinIsTerminal: tty, isTestHost: test)
    }

    // MARK: engine startup options → command-line mode, argv passed through in full

    func test_serverFlag_isCommandLine_withFullArgv() {
        XCTAssertEqual(classify(["-server"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-server"], notice: nil))
    }

    func test_everyStartupOption_isCommandLine_regardlessOfSessionAndTTY() {
        for flag in ["-server", "-socket", "-version", "-doc", "-help"] {
            for session in [true, false] { for tty in [true, false] {
                XCTAssertEqual(classify([flag, "x"], session: session, tty: tty),
                               .commandLine(arguments: [exe, flag, "x"], notice: nil), "\(flag) s=\(session) t=\(tty)")
            } }
        }
    }

    func test_uargGrammar_equalsForm_andDoubleDash_areRecognized() {
        XCTAssertEqual(classify(["-ui=text", "prof"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui=text", "prof"], notice: nil))
        XCTAssertEqual(classify(["--server"], session: true, tty: true),
                       .commandLine(arguments: [exe, "--server"], notice: nil))
        XCTAssertEqual(classify(["--version=true"], session: true, tty: true),
                       .commandLine(arguments: [exe, "--version=true"], notice: nil))
    }

    func test_mixedStartupOptions_passThrough_upstreamDecidesPrecedence() {
        // Main.init checks -version before -server; the policy must not reorder or drop.
        XCTAssertEqual(classify(["-server", "-version"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-server", "-version"], notice: nil))
    }

    func test_uiText_withSession_isCommandLine_unchanged() {
        XCTAssertEqual(classify(["-ui", "text", "prof"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui", "text", "prof"], notice: nil))
    }

    func test_uiGraphic_withSession_isCommandLine_unchanged() {
        // nonGuiStartup returns for this one and the GUI starts with the runtime up.
        XCTAssertEqual(classify(["-ui", "graphic"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui", "graphic"], notice: nil))
    }

    func test_uiGraphic_withoutSession_becomesText_withNotice_profileKept() {
        // Precedence: the text fallback wins and the profile runs in the text UI.
        let r = classify(["-batch", "-ui", "graphic", "prof"], session: false, tty: false)
        guard case .commandLine(let args, let notice) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(args, [exe, "-batch", "-ui", "text", "prof"])
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("-ui graphic"))
    }

    func test_uiGraphic_equalsForm_withoutSession_becomesText() {
        let r = classify(["-ui=graphic", "prof"], session: false, tty: false)
        guard case .commandLine(let args, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(args, [exe, "-ui=text", "prof"])
    }

    func test_uiWithoutValue_passesThroughForTheEngineToReject() {
        // Upstream prints usage and exits; the policy must not mask that.
        XCTAssertEqual(classify(["-ui"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui"], notice: nil))
    }

    func test_hostFlags_areStripped_inCommandLineModeToo() {
        // An Xcode scheme running `-ui graphic` still carries -NSDocumentRevisionsDebugMode.
        XCTAssertEqual(classify(["-NSDocumentRevisionsDebugMode", "YES", "-ui", "graphic"], session: true, tty: false),
                       .commandLine(arguments: [exe, "-ui", "graphic"], notice: nil))
    }

    // MARK: graphical launches

    func test_noArguments_withSession_isGUI() {
        for tty in [true, false] {
            XCTAssertEqual(classify([], session: true, tty: tty), .gui)
        }
    }

    func test_noArguments_withoutSession_runsTextUsage_notAppKit() {
        XCTAssertEqual(classify([], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text"], notice: nil))
    }

    func test_hostInjectedFlagsOnly_isGUI() {
        let args = ["-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES", "-psn_0_123"]
        XCTAssertEqual(classify(args, session: true, tty: false), .gui)
    }

    func test_testHost_isGUI_whateverTheArguments() {
        XCTAssertEqual(classify(["-server"], session: false, tty: false, test: true), .gui)
        XCTAssertEqual(classify(["prof"], session: true, tty: true, test: true), .gui)
        XCTAssertEqual(classify([], session: false, tty: false, test: true), .gui)
    }

    // MARK: arguments without an engine option

    func test_argumentsWithoutSession_runTextInterface() {
        // ssh / cron / launchd daemon: `unison -batch myprofile` with no -ui.
        XCTAssertEqual(classify(["-batch", "myprofile"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text", "-batch", "myprofile"], notice: nil))
    }

    func test_argumentsWithSession_butNoTerminal_runTextInterface() {
        // A LaunchAgent in a logged-in session: session yes, terminal no.
        XCTAssertEqual(classify(["-batch", "myprofile"], session: true, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text", "-batch", "myprofile"], notice: nil))
    }

    func test_argumentsWithSessionAndTerminal_areUnsupported_notDropped() {
        let r = classify(["myprofile"], session: true, tty: true)
        guard case .unsupported(let message) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(message.contains("myprofile"))
        XCTAssertTrue(message.contains("-ui text"))
    }

    func test_unknownOption_inTerminal_isUnsupported_notGUI() {
        let r = classify(["-bogus"], session: true, tty: true)
        guard case .unsupported(let message) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(message.contains("-bogus"))
    }

    func test_unknownOption_headless_reachesUpstreamParser() {
        // Upstream reports "unknown option" and exits 2; the policy passes it on.
        XCTAssertEqual(classify(["-bogus"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text", "-bogus"], notice: nil))
    }

    func test_mixedHostAndUserArguments_keepOnlyUserArguments() {
        XCTAssertEqual(classify(["-NSDocumentRevisionsDebugMode", "YES", "root1", "root2"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text", "root1", "root2"], notice: nil))
    }

    // MARK: grammar helpers

    func test_optionName() {
        XCTAssertEqual(P.optionName("-ui"), "ui")
        XCTAssertEqual(P.optionName("--ui"), "ui")
        XCTAssertEqual(P.optionName("-ui=text"), "ui")
        XCTAssertEqual(P.optionName("-server=true"), "server")
        XCTAssertNil(P.optionName("text"))
        XCTAssertNil(P.optionName("my profile"))
        XCTAssertNil(P.optionName("-"))
        XCTAssertNil(P.optionName("-=x"))
    }

    func test_replacingUIGraphicWithText() {
        XCTAssertEqual(P.replacingUIGraphicWithText(["-ui", "graphic"]), ["-ui", "text"])
        XCTAssertEqual(P.replacingUIGraphicWithText(["--ui=graphic", "p"]), ["--ui=text", "p"])
        XCTAssertNil(P.replacingUIGraphicWithText(["-ui", "text"]))
        XCTAssertNil(P.replacingUIGraphicWithText(["-ui"]))
        XCTAssertNil(P.replacingUIGraphicWithText(["graphic"]))
    }

    // MARK: host-injected flag stripping

    func test_strip_nsAndAppleFlagsConsumeTheirValue_psnDoesNot() {
        let out = P.stripHostInjected(["-NSFoo", "bar", "-psn_0_1", "keep", "-AppleLanguages", "(fr)", "also"])
        XCTAssertEqual(out, ["keep", "also"])
    }

    func test_strip_trailingFlagWithoutValue_isHarmless() {
        XCTAssertEqual(P.stripHostInjected(["keep", "-NSFoo"]), ["keep"])
    }

    func test_strip_doesNotTouchUnisonFlags() {
        XCTAssertEqual(P.stripHostInjected(["-batch", "-servercmd", "/x/unison"]), ["-batch", "-servercmd", "/x/unison"])
    }
}
