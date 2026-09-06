import XCTest
@testable import unison_ui_mac

/// The launch-kind decision and the engine argv from docs/cli-launcher-design.md.
/// What the engine then does with that argv is upstream's `unisonNonGuiStartup`
/// and is exercised against the real bundle by scripts/smoke-cli.sh, not here.
final class CommandLineInvocationPolicyTests: XCTestCase {

    private typealias P = CommandLineInvocationPolicy
    private let exe = "/Applications/unison-ui-mac.app/Contents/MacOS/unison-ui-mac"

    private func kind(_ args: [String], launcher: Bool, session: Bool, test: Bool = false) -> LaunchKind {
        P.launchKind(arguments: [exe] + args, launchedByLauncher: launcher, hasWindowServerSession: session, isTestHost: test)
    }

    // MARK: launch kind

    func test_launcherMarker_isShell_whateverTheArguments() {
        XCTAssertEqual(kind([], launcher: true, session: true), .shell)
        XCTAssertEqual(kind(["-server", "__new-rpc-mode"], launcher: true, session: false), .shell)
        XCTAssertEqual(kind(["-ui", "graphic"], launcher: true, session: true), .shell)
    }

    func test_testHost_isGUI_evenThroughTheLauncher() {
        XCTAssertEqual(kind(["-server"], launcher: true, session: false, test: true), .gui)
        XCTAssertEqual(kind([], launcher: false, session: true, test: true), .gui)
    }

    func test_noSession_isShell_evenWithoutMarkerOrArguments() {
        // `ssh host /path/to/bundle/Contents/MacOS/unison-ui-mac` with servercmd
        // pointing at the executable: no marker, no session.
        XCTAssertEqual(kind([], launcher: false, session: false), .shell)
        XCTAssertEqual(kind(["-server", "__new-rpc-mode"], launcher: false, session: false), .shell)
    }

    func test_directInvocationWithArguments_inSession_isShell() {
        XCTAssertEqual(kind(["-batch", "p"], launcher: false, session: true), .shell)
        XCTAssertEqual(kind(["-ui", "graphic"], launcher: false, session: true), .shell)
    }

    func test_finderStyleLaunch_isGUI() {
        XCTAssertEqual(kind([], launcher: false, session: true), .gui)
        XCTAssertEqual(kind(["-psn_0_123"], launcher: false, session: true), .gui)
    }

    func test_xcodeAndXCTestStyleFlags_isGUI() {
        let args = ["-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES"]
        XCTAssertEqual(kind(args, launcher: false, session: true), .gui)
    }

    func test_hostFlagFollowedByAnOption_isShell() {
        // `-NSFoo -server`: the option is not a host flag's value.
        XCTAssertEqual(kind(["-NSFoo", "-server"], launcher: false, session: true), .shell)
    }

    // MARK: engine argv

    func test_engineArguments_prependUITextAndKeepEverythingElseIntact() {
        XCTAssertEqual(P.engineArguments([exe]), [exe, "-ui", "text"])
        XCTAssertEqual(P.engineArguments([exe, "-server", "__new-rpc-mode"]), [exe, "-ui", "text", "-server", "__new-rpc-mode"])
        // The caller's later -ui wins in upstream's scanner; the policy does not touch it.
        XCTAssertEqual(P.engineArguments([exe, "-ui", "graphic", "p"]), [exe, "-ui", "text", "-ui", "graphic", "p"])
        // Option-value boundaries are the engine's business.
        let tricky = ["-label", "-server", "-batch", "p"]
        XCTAssertEqual(P.engineArguments([exe] + tricky), [exe, "-ui", "text"] + tricky)
        let host = ["-NSDocumentRevisionsDebugMode", "YES", "-ui", "graphic"]
        XCTAssertEqual(P.engineArguments([exe] + host), [exe, "-ui", "text"] + host)
    }

    // MARK: graphical continuation

    func test_graphicalContinuation_needsASession() {
        XCTAssertEqual(P.graphicalContinuation(hasWindowServerSession: true), .proceed)
        guard case .refuse(let message) = P.graphicalContinuation(hasWindowServerSession: false) else {
            return XCTFail("expected refusal without a session")
        }
        XCTAssertTrue(message.contains("-ui graphic"))
        XCTAssertTrue(message.contains("-ui text"))
    }

    // MARK: host-injected flag detection

    func test_withoutHostInjected_consumesValueOnlyWhenNotAnOption() {
        XCTAssertEqual(P.withoutHostInjected(["-NSFoo", "bar", "-psn_0_1", "keep", "-AppleLanguages", "(fr)", "also"]),
                       ["keep", "also"])
        XCTAssertEqual(P.withoutHostInjected(["-NSFoo", "-server"]), ["-server"])
        XCTAssertEqual(P.withoutHostInjected(["keep", "-NSFoo"]), ["keep"])
    }

    func test_withoutHostInjected_doesNotTouchUnisonFlags() {
        XCTAssertEqual(P.withoutHostInjected(["-batch", "-servercmd", "/x/unison"]), ["-batch", "-servercmd", "/x/unison"])
    }

    func test_launcherMarkerName() {
        XCTAssertEqual(P.launcherMarker, "UNISON_UI_MAC_LAUNCHER")
    }
}
