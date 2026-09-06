import XCTest
@testable import unison_ui_mac

/// The mode table from docs/cli-launcher-design.md, one test per row plus the
/// edges around it. The policy is pure, so nothing here touches AppKit or the
/// engine.
final class CommandLineInvocationPolicyTests: XCTestCase {

    private typealias P = CommandLineInvocationPolicy
    private let exe = "/Applications/unison-ui-mac.app/Contents/MacOS/unison-ui-mac"

    // MARK: engine startup flags → command-line mode, argv passed through in full

    func test_serverFlag_isCommandLine_withFullArgv() {
        let r = P.classify(arguments: [exe, "-server"], hasWindowServerSession: false, isTestHost: false)
        XCTAssertEqual(r, .commandLine(arguments: [exe, "-server"], notice: nil))
    }

    func test_everyStartupFlag_isCommandLine_regardlessOfSession() {
        for flag in ["-server", "-socket", "-version", "-doc", "-help"] {
            for session in [true, false] {
                let r = P.classify(arguments: [exe, flag, "x"], hasWindowServerSession: session, isTestHost: false)
                XCTAssertEqual(r, .commandLine(arguments: [exe, flag, "x"], notice: nil), "\(flag) session=\(session)")
            }
        }
    }

    func test_uiText_withSession_isCommandLine_unchanged() {
        let r = P.classify(arguments: [exe, "-ui", "text", "prof"], hasWindowServerSession: true, isTestHost: false)
        XCTAssertEqual(r, .commandLine(arguments: [exe, "-ui", "text", "prof"], notice: nil))
    }

    func test_uiGraphic_withSession_isCommandLine_unchanged() {
        // nonGuiStartup returns for this one and the GUI starts with the runtime up.
        let r = P.classify(arguments: [exe, "-ui", "graphic"], hasWindowServerSession: true, isTestHost: false)
        XCTAssertEqual(r, .commandLine(arguments: [exe, "-ui", "graphic"], notice: nil))
    }

    func test_uiGraphic_withoutSession_becomesText_withNotice() {
        let r = P.classify(arguments: [exe, "-batch", "-ui", "graphic", "prof"],
                           hasWindowServerSession: false, isTestHost: false)
        guard case .commandLine(let args, let notice) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(args, [exe, "-batch", "-ui", "text", "prof"])
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("-ui graphic"))
    }

    func test_uiWithoutValue_passesThroughForTheEngineToReject() {
        // Upstream prints usage and exits 1; the policy must not mask that.
        let r = P.classify(arguments: [exe, "-ui"], hasWindowServerSession: false, isTestHost: false)
        XCTAssertEqual(r, .commandLine(arguments: [exe, "-ui"], notice: nil))
    }

    // MARK: graphical launches

    func test_noArguments_isGUI() {
        for session in [true, false] {
            XCTAssertEqual(P.classify(arguments: [exe], hasWindowServerSession: session, isTestHost: false), .gui)
        }
    }

    func test_hostInjectedFlagsOnly_isGUI() {
        let args = [exe, "-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES", "-psn_0_123"]
        XCTAssertEqual(P.classify(arguments: args, hasWindowServerSession: true, isTestHost: false), .gui)
    }

    func test_testHost_isGUI_whateverTheArguments() {
        let args = [exe, "-server"]
        XCTAssertEqual(P.classify(arguments: args, hasWindowServerSession: false, isTestHost: true), .gui)
        XCTAssertEqual(P.classify(arguments: [exe, "prof"], hasWindowServerSession: true, isTestHost: true), .gui)
    }

    // MARK: arguments without an engine flag

    func test_argumentsWithoutSession_runTextInterface() {
        // launchd/cron: `unison -batch myprofile` with no -ui.
        let r = P.classify(arguments: [exe, "-batch", "myprofile"], hasWindowServerSession: false, isTestHost: false)
        XCTAssertEqual(r, .commandLine(arguments: [exe, "-ui", "text", "-batch", "myprofile"], notice: nil))
    }

    func test_argumentsWithSession_areUnsupported_notDropped() {
        let r = P.classify(arguments: [exe, "myprofile"], hasWindowServerSession: true, isTestHost: false)
        guard case .unsupported(let message) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(message.contains("myprofile"))
        XCTAssertTrue(message.contains("-ui text"))
    }

    func test_mixedHostAndUserArguments_keepOnlyUserArguments() {
        let r = P.classify(arguments: [exe, "-NSDocumentRevisionsDebugMode", "YES", "root1", "root2"],
                           hasWindowServerSession: false, isTestHost: false)
        XCTAssertEqual(r, .commandLine(arguments: [exe, "-ui", "text", "root1", "root2"], notice: nil))
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
