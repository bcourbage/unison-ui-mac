import XCTest
@testable import unison_ui_mac

/// The mode table from docs/cli-launcher-design.md, one test per row plus the
/// edges around it. The policy is pure, so nothing here touches AppKit or the
/// engine. What these tests prove is the argv the policy hands over and the
/// mode it picks; what the engine then does with that argv is upstream's
/// behavior and is exercised by scripts/smoke-cli.sh, not here.
final class CommandLineInvocationPolicyTests: XCTestCase {

    private typealias P = CommandLineInvocationPolicy
    private let exe = "/Applications/unison-ui-mac.app/Contents/MacOS/unison-ui-mac"

    private func classify(_ args: [String], session: Bool, tty: Bool, test: Bool = false) -> CommandLineInvocation {
        P.classify(arguments: [exe] + args, hasWindowServerSession: session, stdinIsTerminal: tty, isTestHost: test)
    }

    // MARK: engine startup options → command-line mode, argv passed through intact

    func test_serverFlag_isCommandLine_withFullArgv() {
        XCTAssertEqual(classify(["-server", "__new-rpc-mode"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-server", "__new-rpc-mode"]))
    }

    func test_everyStartupOption_isCommandLine_regardlessOfSessionAndTTY() {
        for flag in ["-server", "-socket", "-version", "-doc", "-help"] {
            for session in [true, false] { for tty in [true, false] {
                XCTAssertEqual(classify([flag, "x"], session: session, tty: tty),
                               .commandLine(arguments: [exe, flag, "x"]), "\(flag) s=\(session) t=\(tty)")
            } }
        }
    }

    func test_equalsForm_isRecognized() {
        XCTAssertEqual(classify(["-ui=text", "prof"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui=text", "prof"]))
        XCTAssertEqual(classify(["-version=true"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-version=true"]))
    }

    func test_doubleDash_isNotAnEngineOption_matchingUpstream() {
        // Upstream registers "-server" and matches exactly, so "--server" is an
        // unknown option there. In Terminal it is refused; headless it reaches
        // the engine, which reports it.
        let r = classify(["--server"], session: true, tty: true)
        guard case .unsupported(let message) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(message.contains("--server"))
        XCTAssertEqual(classify(["--server"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text", "--server"]))
    }

    func test_mixedStartupOptions_passThrough_upstreamDecidesPrecedence() {
        // Main.init checks -version before -server; the policy must not reorder or drop.
        XCTAssertEqual(classify(["-server", "-version"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-server", "-version"]))
    }

    func test_uiText_withSession_isCommandLine_unchanged() {
        XCTAssertEqual(classify(["-ui", "text", "prof"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui", "text", "prof"]))
    }

    func test_uiGraphic_withSession_isCommandLine_unchanged() {
        // nonGuiStartup returns for this one and the GUI starts with the runtime up.
        XCTAssertEqual(classify(["-ui", "graphic"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui", "graphic"]))
    }

    func test_uiGraphic_withoutSession_isRefused_notRewritten() {
        for args in [["-ui", "graphic", "prof"], ["-ui=graphic", "prof"], ["-batch", "-ui", "graphic"]] {
            let r = classify(args, session: false, tty: false)
            guard case .unsupported(let message) = r else { return XCTFail("\(args): \(r)") }
            XCTAssertTrue(message.contains("-ui graphic"), message)
            XCTAssertTrue(message.contains("-ui text"), message)
        }
    }

    func test_uiWithoutValue_passesThroughForTheEngineToReject() {
        // Upstream prints usage and exits; the policy must not mask that.
        XCTAssertEqual(classify(["-ui"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui"]))
    }

    func test_optionValueBoundaries_areNeverEdited() {
        // The policy does not know which token is a value; it must not touch any.
        let a1 = ["-ui", "text", "-label", "-NSFoo", "p"]
        XCTAssertEqual(classify(a1, session: true, tty: true), .commandLine(arguments: [exe] + a1))
        let a2 = ["-NSFoo", "-server"]
        XCTAssertEqual(classify(a2, session: false, tty: false), .commandLine(arguments: [exe] + a2))
        let a3 = ["-label", "-ui", "graphic", "p"]
        XCTAssertEqual(classify(a3, session: true, tty: true), .commandLine(arguments: [exe] + a3))
    }

    func test_hostFlags_reachTheEngineIntact_inCommandLineMode() {
        // An Xcode scheme running `-ui graphic` also carries -NSDocumentRevisionsDebugMode;
        // the engine rejects it with usage. Nothing is silently removed.
        let args = ["-NSDocumentRevisionsDebugMode", "YES", "-ui", "graphic"]
        XCTAssertEqual(classify(args, session: true, tty: false), .commandLine(arguments: [exe] + args))
    }

    // MARK: graphical launches

    func test_noArguments_withSession_isGUI() {
        for tty in [true, false] {
            XCTAssertEqual(classify([], session: true, tty: tty), .gui)
        }
    }

    func test_noArguments_withoutSession_handsToTextInterface_notAppKit() {
        // The text interface then behaves like upstream's bare `unison`: default
        // profile if present, usage otherwise. The policy only chooses the UI.
        XCTAssertEqual(classify([], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text"]))
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
        XCTAssertEqual(classify(["-batch", "myprofile"], session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text", "-batch", "myprofile"]))
    }

    func test_argumentsWithSession_butNoTerminal_runTextInterface() {
        // A LaunchAgent in a logged-in session: session yes, terminal no.
        XCTAssertEqual(classify(["myprofile"], session: true, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text", "myprofile"]))
    }

    func test_batch_runsTextInterface_evenInTerminal() {
        // A script started from Terminal inherits the tty; `-batch` states its intent.
        XCTAssertEqual(classify(["-batch", "myprofile"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui", "text", "-batch", "myprofile"]))
        XCTAssertEqual(classify(["-batch=true", "myprofile"], session: true, tty: true),
                       .commandLine(arguments: [exe, "-ui", "text", "-batch=true", "myprofile"]))
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
                       .commandLine(arguments: [exe, "-ui", "text", "-bogus"]))
    }

    func test_hostFlagsPlusUserArguments_headless_allReachTheEngine() {
        let args = ["-NSDocumentRevisionsDebugMode", "YES", "root1", "root2"]
        XCTAssertEqual(classify(args, session: false, tty: false),
                       .commandLine(arguments: [exe, "-ui", "text"] + args))
    }

    // MARK: grammar helpers

    func test_optionName_matchesUpstreamExactly() {
        XCTAssertEqual(P.optionName("-ui"), "ui")
        XCTAssertEqual(P.optionName("-ui=text"), "ui")
        XCTAssertEqual(P.optionName("-server=true"), "server")
        XCTAssertNil(P.optionName("--ui"), "upstream registers single-dash names only")
        XCTAssertNil(P.optionName("text"))
        XCTAssertNil(P.optionName("my profile"))
        XCTAssertNil(P.optionName("-"))
        XCTAssertNil(P.optionName("-=x"))
    }

    func test_selectsGraphicUI() {
        XCTAssertTrue(P.selectsGraphicUI(["-ui", "graphic"]))
        XCTAssertTrue(P.selectsGraphicUI(["-ui=graphic", "p"]))
        XCTAssertFalse(P.selectsGraphicUI(["-ui", "text"]))
        XCTAssertFalse(P.selectsGraphicUI(["-ui"]))
        XCTAssertFalse(P.selectsGraphicUI(["graphic"]))
        XCTAssertFalse(P.selectsGraphicUI(["--ui", "graphic"]))
    }

    // MARK: host-injected flag detection (decision only)

    func test_withoutHostInjected_consumesValueOnlyWhenNotAnOption() {
        XCTAssertEqual(P.withoutHostInjected(["-NSFoo", "bar", "-psn_0_1", "keep", "-AppleLanguages", "(fr)", "also"]),
                       ["keep", "also"])
        XCTAssertEqual(P.withoutHostInjected(["-NSFoo", "-server"]), ["-server"])
        XCTAssertEqual(P.withoutHostInjected(["keep", "-NSFoo"]), ["keep"])
    }

    func test_withoutHostInjected_doesNotTouchUnisonFlags() {
        XCTAssertEqual(P.withoutHostInjected(["-batch", "-servercmd", "/x/unison"]), ["-batch", "-servercmd", "/x/unison"])
    }
}
