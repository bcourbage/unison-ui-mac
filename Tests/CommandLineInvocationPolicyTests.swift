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

    func test_engineArguments_prependDefaultUIAndKeepEverythingElseIntact() {
        XCTAssertEqual(P.engineArguments([exe], defaultInterface: "text"), [exe, "-ui", "text"])
        XCTAssertEqual(P.engineArguments([exe, "-server", "__new-rpc-mode"], defaultInterface: "text"),
                       [exe, "-ui", "text", "-server", "__new-rpc-mode"])
        // The caller's later -ui wins in upstream's scanner; the policy does not touch it.
        XCTAssertEqual(P.engineArguments([exe, "-ui", "graphic", "p"], defaultInterface: "text"),
                       [exe, "-ui", "text", "-ui", "graphic", "p"])
        // Option-value boundaries are the engine's business.
        let tricky = ["-label", "-server", "-batch", "p"]
        XCTAssertEqual(P.engineArguments([exe] + tricky, defaultInterface: "text"), [exe, "-ui", "text"] + tricky)
        let host = ["-NSDocumentRevisionsDebugMode", "YES", "-ui", "graphic"]
        XCTAssertEqual(P.engineArguments([exe] + host, defaultInterface: "text"), [exe, "-ui", "text"] + host)
    }

    func test_engineArguments_graphicDefault_isInjected_andExplicitUIStillWins() {
        // New-user default: `unison p` becomes `-ui graphic p`.
        XCTAssertEqual(P.engineArguments([exe, "p"], defaultInterface: "graphic"), [exe, "-ui", "graphic", "p"])
        // An explicit `-ui text` after the default wins (last value), so a script
        // that asks for text gets text regardless of the preference.
        XCTAssertEqual(P.engineArguments([exe, "-ui", "text", "p"], defaultInterface: "graphic"),
                       [exe, "-ui", "graphic", "-ui", "text", "p"])
        // -server is untouched; it runs before -ui in the engine either way.
        XCTAssertEqual(P.engineArguments([exe, "-server", "__new-rpc-mode"], defaultInterface: "graphic"),
                       [exe, "-ui", "graphic", "-server", "__new-rpc-mode"])
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

    // MARK: profile handoff to the picker (upstream's profilePathname rule)

    private func handoff(_ given: String, files: Set<String>) -> CommandLineProfileHandoff {
        CommandLineProfileHandoff.resolve(given: given) { files.contains($0) }
    }

    func test_handoff_plainName_selectsIt() {
        XCTAssertEqual(handoff("p", files: ["p.prf"]), .select(pickerName: "p"))
    }

    func test_handoff_suffixedName_selectsStrippedName_whenNoCollision() {
        XCTAssertEqual(handoff("p.prf", files: ["p.prf"]), .select(pickerName: "p"))
    }

    func test_handoff_suffixedName_refused_whenExtensionlessFileAlsoExists() {
        // `p.prf` given → upstream opens p.prf; picker's `p` → upstream opens `p`.
        guard case .refuse(let reason) = handoff("p.prf", files: ["p.prf", "p"]) else {
            return XCTFail("expected refusal on p / p.prf collision")
        }
        XCTAssertTrue(reason.contains("p.prf"))
        XCTAssertTrue(reason.contains("would open p"))
    }

    func test_handoff_plainName_withExtensionlessFile_isConsistent() {
        // Both the given string and the picker name resolve to the same file `p`.
        XCTAssertEqual(handoff("p", files: ["p.prf", "p"]), .select(pickerName: "p"))
    }

    func test_handoff_doubleSuffix() {
        // `p.prf.prf` given → file p.prf.prf; picker name `p.prf` → file p.prf. Different.
        guard case .refuse = handoff("p.prf.prf", files: ["p.prf.prf", "p.prf"]) else {
            return XCTFail("expected refusal")
        }
    }

    func test_launcherMarkerName() {
        XCTAssertEqual(P.launcherMarker, "UNISON_UI_MAC_LAUNCHER")
    }

    // MARK: graphical launch disposition

    private func launch(rootsSet: Int, profile: String?,
                        files: Set<String> = [], listed: Set<String> = []) -> CommandLineGraphicalLaunch {
        CommandLineGraphicalLaunch.resolve(
            rootsSet: rootsSet, profile: profile,
            fileExists: { files.contains($0) }, isListed: { listed.contains($0) })
    }

    func test_launch_noProfile_showsPicker() {
        XCTAssertEqual(launch(rootsSet: 0, profile: nil), .showPicker)
    }

    func test_launch_rootsPresent_refuses() {
        guard case .refuse(let m) = launch(rootsSet: 1, profile: nil) else {
            return XCTFail("expected refusal for roots")
        }
        XCTAssertTrue(m.contains("roots given on the command line"))
        XCTAssertTrue(m.contains("-ui text"))
    }

    func test_launch_rootsUndetermined_refuses_evenWithAProfile() {
        // Undetermined must not fall through to opening a profile.
        guard case .refuse(let m) = launch(rootsSet: 2, profile: "p", files: ["p.prf"], listed: ["p"]) else {
            return XCTFail("expected refusal when roots are undetermined")
        }
        XCTAssertTrue(m.contains("could not report its command-line roots"))
    }

    func test_launch_suppliedListedProfile_opensAndScans() {
        XCTAssertEqual(launch(rootsSet: 0, profile: "p", files: ["p.prf"], listed: ["p"]),
                       .openProfile(name: "p"))
        // A `.prf`-suffixed name resolves to the same stripped picker name.
        XCTAssertEqual(launch(rootsSet: 0, profile: "p.prf", files: ["p.prf"], listed: ["p"]),
                       .openProfile(name: "p"))
    }

    func test_launch_hiddenOrUnlistedProfile_refuses() {
        // The file exists (upstream validated it) but the picker does not list it.
        guard case .refuse(let m) = launch(rootsSet: 0, profile: "p", files: ["p.prf"], listed: []) else {
            return XCTFail("expected refusal for an unlisted profile")
        }
        XCTAssertTrue(m.contains("not shown in the profile picker"))
        XCTAssertTrue(m.contains("-ui text"))
    }

    func test_launch_ambiguousHandoff_refuses_withoutOpening() {
        // `p.prf` given with both `p` and `p.prf` present: the picker's `p` would
        // open a different file, so refuse rather than open the wrong profile.
        guard case .refuse(let m) = launch(rootsSet: 0, profile: "p.prf",
                                           files: ["p.prf", "p"], listed: ["p"]) else {
            return XCTFail("expected refusal on the p / p.prf ambiguity")
        }
        XCTAssertTrue(m.contains("would open p"))
    }

    // MARK: option-launch isolation for GUI opens

    private func mayOpen(clean: Bool, launch: String?, requested: String) -> Bool {
        CommandLineGraphicalLaunch.mayOpenAfterOptionLaunch(
            launchWasClean: clean, launchProfile: launch, requested: requested)
    }

    func test_cleanLaunch_opensAnyProfile() {
        XCTAssertTrue(mayOpen(clean: true, launch: "first", requested: "second"))
        XCTAssertTrue(mayOpen(clean: true, launch: nil, requested: "anything"))
    }

    func test_optionLaunch_opensOnlyItsOwnProfile() {
        XCTAssertTrue(mayOpen(clean: false, launch: "first", requested: "first"))
        XCTAssertFalse(mayOpen(clean: false, launch: "first", requested: "second"))
    }

    func test_optionLaunch_withNoProfile_opensNothing() {
        // `unison -path X` with no profile: every open would inherit the options.
        XCTAssertFalse(mayOpen(clean: false, launch: nil, requested: "any"))
    }
}
