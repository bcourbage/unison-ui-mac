import XCTest
@testable import unison_ui_mac

/// The pure line protocol and accept/refuse decision for running-instance
/// routing (req 5 of #122). The socket transport is exercised separately in
/// CommandLineHandoffSocketTests.
final class CommandLineHandoffTests: XCTestCase {

    private typealias Req = CommandLineHandoff.Request
    private typealias Resp = CommandLineHandoff.Response

    private func req(given: String = "work", rootsSet: Int = 0,
                     dir: String = "/Users/x/Library/Application Support/Unison",
                     install: String = "/Applications/unison-ui-mac.app",
                     plain: Bool = true) -> Req {
        Req(given: given, rootsSet: rootsSet, unisonDirectory: dir,
            installationPath: install, plainRequest: plain)
    }

    // MARK: request codec

    func test_request_roundTrip() {
        let r = req(given: "work", rootsSet: 0, dir: "/u", install: "/A/app", plain: true)
        XCTAssertEqual(Req(line: r.encoded()!), r)
    }

    func test_request_roundTrip_carriesAllFields() {
        let r = req(given: "p", rootsSet: 2, dir: "/other/config", install: "/B/app", plain: false)
        let parsed = Req(line: r.encoded()!)
        XCTAssertEqual(parsed?.given, "p")
        XCTAssertEqual(parsed?.rootsSet, 2)
        XCTAssertEqual(parsed?.unisonDirectory, "/other/config")
        XCTAssertEqual(parsed?.installationPath, "/B/app")
        XCTAssertEqual(parsed?.plainRequest, false)
    }

    func test_request_base64_survivesTabsAndSpaces() {
        // base64 fields carry any byte, so a directory, path or name with a tab is exact.
        let r = req(given: "my\twork profile", dir: "/dir\twith/tab", install: "/A B/my.app")
        XCTAssertEqual(Req(line: r.encoded()!), r)
    }

    func test_request_parse_toleratesMissingTrailingNewline() {
        let line = req(given: "p").encoded()!
        XCTAssertEqual(Req(line: String(line.dropLast())), req(given: "p"))
    }

    func test_request_parse_rejectsMalformed() {
        XCTAssertNil(Req(line: "nope\t0\t1\tL3U=\tL0E=\td29yaw==\n"))  // wrong verb
        XCTAssertNil(Req(line: "open\t0\t1\tL3U=\td29yaw==\n"))         // too few fields (5)
        XCTAssertNil(Req(line: "open\tx\t1\tL3U=\tL0E=\td29yaw==\n"))   // non-integer roots
        XCTAssertNil(Req(line: "open\t0\t2\tL3U=\tL0E=\td29yaw==\n"))   // plain flag not 0/1
        XCTAssertNil(Req(line: "open\t0\t1\t!!!\tL0E=\td29yaw==\n"))    // invalid base64
        XCTAssertNil(Req(line: ""))
    }

    // MARK: response codec

    func test_response_roundTrip() {
        for r: Resp in [.started, .refused(message: "busy: scanning"), .invalid(message: "no such profile")] {
            XCTAssertEqual(Resp(line: r.encoded()), r)
        }
    }

    func test_response_truncatedOrUnknown_isNil() {
        XCTAssertNil(Resp(line: "ok"))                  // no newline = truncated
        XCTAssertNil(Resp(line: "refuse\tbusy"))        // no newline
        XCTAssertNil(Resp(line: "weird\tthing\n"))      // unknown verb
        XCTAssertNil(Resp(line: ""))
    }

    func test_response_successAndClientMessage() {
        XCTAssertTrue(Resp.started.isSuccess)
        XCTAssertNil(Resp.started.clientMessage)
        XCTAssertFalse(Resp.refused(message: "x").isSuccess)
        XCTAssertEqual(Resp.refused(message: "x").clientMessage, "x")
        XCTAssertFalse(Resp.invalid(message: "y").isSuccess)
        XCTAssertEqual(Resp.invalid(message: "y").clientMessage, "y")
    }

    // MARK: context check (finding 1: faithful transfer)

    private func check(_ r: Req, dir: String = "/u", install: String = "/A/app",
                       receiverClean: Bool = true) -> Resp? {
        CommandLineHandoff.contextCheck(request: r, localUnisonDirectory: dir,
                                        localInstallationPath: install, receiverLaunchWasClean: receiverClean)
    }

    func test_context_compatible_isAccepted() {
        XCTAssertNil(check(req(dir: "/u", install: "/A/app", plain: true),
                           dir: "/u", install: "/A/app", receiverClean: true))
    }

    func test_context_normalizesUnisonPathsBeforeComparing() {
        XCTAssertNil(check(req(dir: "/u/./sub/..//", install: "/A/app"), dir: "/u", install: "/A/app"))
    }

    func test_context_receiverLaunchedWithOptions_isInvalid() {
        // Upstream reparses the process command line on every profile load, so a
        // primary launched with options cannot faithfully serve any handoff.
        guard case .invalid(let m)? = check(req(), receiverClean: false) else {
            return XCTFail("expected invalid when the receiver's own launch was not clean")
        }
        XCTAssertTrue(m.contains("command-line options that would affect other profiles"))
    }

    func test_context_extraOptions_isInvalid() {
        guard case .invalid(let m)? = check(req(plain: false)) else {
            return XCTFail("expected invalid on extra options")
        }
        XCTAssertTrue(m.contains("extra command-line options"))
    }

    func test_context_differentInstallation_isInvalid() {
        guard case .invalid(let m)? = check(req(given: "work", install: "/B/app"), install: "/A/app") else {
            return XCTFail("expected invalid on installation mismatch")
        }
        XCTAssertTrue(m.contains("different copy of the app"))
        XCTAssertTrue(m.contains("/A/app"))
        XCTAssertTrue(m.contains("work"))
    }

    func test_context_differentUnisonDirectory_isInvalid() {
        // Same installation so the directory check (which comes after it) is reached.
        guard case .invalid(let m)? = check(req(given: "work", dir: "/other/config", install: "/A/app"),
                                            dir: "/u", install: "/A/app") else {
            return XCTFail("expected invalid on dir mismatch")
        }
        XCTAssertTrue(m.contains("different Unison directory"))
        XCTAssertTrue(m.contains("/u"))
        XCTAssertTrue(m.contains("work"))
    }

    // MARK: decision

    func test_decide_invalidLaunch_repliesInvalid() {
        XCTAssertEqual(CommandLineHandoff.decide(launch: .refuse(message: "roots not supported"),
                                                 activity: .idleAtPicker),
                       .reply(.invalid(message: "roots not supported")))
    }

    func test_decide_noProfileLaunch_repliesInvalid() {
        guard case .reply(.invalid) = CommandLineHandoff.decide(launch: .showPicker, activity: .idleAtPicker) else {
            return XCTFail("expected invalid")
        }
    }

    func test_decide_idle_opensTheProfile() {
        XCTAssertEqual(CommandLineHandoff.decide(launch: .openProfile(name: "work"), activity: .idleAtPicker),
                       .open(name: "work"))
    }

    func test_decide_busyEngine_refuses_withWaitGuidance() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "work"),
            activity: .busy(reason: "scanning for changes", resolution: .waitForCompletion))
        guard case .reply(.refused(let m)) = out else { return XCTFail("expected refusal") }
        XCTAssertTrue(m.contains("scanning for changes"))
        XCTAssertTrue(m.contains("work"))
        XCTAssertTrue(m.contains("Wait for it to finish"))
        XCTAssertTrue(m.contains("-ui text"))
    }

    func test_decide_busyEditor_refuses_withCloseEditorGuidance() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "other"),
            activity: .busy(reason: "editing the profile home", resolution: .closeEditor))
        guard case .reply(.refused(let m)) = out else { return XCTFail("expected refusal") }
        XCTAssertTrue(m.contains("editing the profile home"))  // names the edited profile
        XCTAssertTrue(m.contains("other"))                     // names the request
        XCTAssertTrue(m.contains("Close the profile editor, then run the command again"))
    }

    // MARK: open outcome (finding 4)

    func test_responseForOpenAttempt() {
        XCTAssertEqual(CommandLineHandoff.responseForOpenAttempt(enteredOpening: true, name: "w"), .started)
        guard case .refused(let m) = CommandLineHandoff.responseForOpenAttempt(enteredOpening: false, name: "w") else {
            return XCTFail("expected refusal when nothing opened")
        }
        XCTAssertTrue(m.contains("did not start w"))
        XCTAssertTrue(m.contains("-ui text"))
    }

    // MARK: clean-launch detection (finding 1: only faithfully transferable opens)

    func test_isClean_bareProfile() {
        XCTAssertTrue(CommandLineHandoff.isCleanGraphicalLaunch(arguments: ["exe", "work"], launchProfile: "work"))
    }

    func test_isClean_uiSelectorRemoved() {
        XCTAssertTrue(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "-ui", "graphic", "work"], launchProfile: "work"))
        XCTAssertTrue(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "-ui=graphic", "work"], launchProfile: "work"))
    }

    func test_isClean_hostInjectedFlagsIgnored() {
        XCTAssertTrue(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "-NSDocumentRevisionsDebugMode", "YES", "work"], launchProfile: "work"))
    }

    func test_isClean_noProfile_finderLaunchIsClean() {
        // A Finder launch (no profile, only host-injected flags) is clean.
        XCTAssertTrue(CommandLineHandoff.isCleanGraphicalLaunch(arguments: ["exe"], launchProfile: nil))
        XCTAssertTrue(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "-psn_0_1", "-NSFoo", "bar"], launchProfile: nil))
    }

    func test_isClean_extraOptions_isNotClean() {
        XCTAssertFalse(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "work", "-batch"], launchProfile: "work"))
        XCTAssertFalse(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "-path", "sub", "work"], launchProfile: "work"))
        XCTAssertFalse(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "-servercmd", "/x/unison", "work"], launchProfile: "work"))
        // Options with no profile (the receiver's own launch context) are not clean.
        XCTAssertFalse(CommandLineHandoff.isCleanGraphicalLaunch(
            arguments: ["exe", "-path", "sub"], launchProfile: nil))
    }
}
