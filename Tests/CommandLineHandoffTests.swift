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
                     plain: Bool = true) -> Req {
        Req(given: given, rootsSet: rootsSet, unisonDirectory: dir, plainRequest: plain)
    }

    // MARK: request codec

    func test_request_roundTrip() {
        let r = req(given: "work", rootsSet: 0, dir: "/u", plain: true)
        XCTAssertEqual(Req(line: r.encoded()!), r)
    }

    func test_request_roundTrip_carriesAllFields() {
        let r = req(given: "p", rootsSet: 2, dir: "/other/config", plain: false)
        let parsed = Req(line: r.encoded()!)
        XCTAssertEqual(parsed?.given, "p")
        XCTAssertEqual(parsed?.rootsSet, 2)
        XCTAssertEqual(parsed?.unisonDirectory, "/other/config")
        XCTAssertEqual(parsed?.plainRequest, false)
    }

    func test_request_base64_survivesTabsAndSpaces() {
        // base64 fields carry any byte, so a directory or name with a tab is exact.
        let r = req(given: "my\twork profile", dir: "/dir\twith/tab")
        XCTAssertEqual(Req(line: r.encoded()!), r)
    }

    func test_request_parse_toleratesMissingTrailingNewline() {
        let line = req(given: "p").encoded()!
        XCTAssertEqual(Req(line: String(line.dropLast())), req(given: "p"))
    }

    func test_request_parse_rejectsMalformed() {
        XCTAssertNil(Req(line: "nope\t0\t1\tL3U=\td29yaw==\n"))  // wrong verb
        XCTAssertNil(Req(line: "open\t0\t1\tL3U=\n"))             // too few fields
        XCTAssertNil(Req(line: "open\tx\t1\tL3U=\td29yaw==\n"))   // non-integer roots
        XCTAssertNil(Req(line: "open\t0\t2\tL3U=\td29yaw==\n"))   // plain flag not 0/1
        XCTAssertNil(Req(line: "open\t0\t1\t!!!\td29yaw==\n"))    // invalid base64
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

    func test_context_sameDirAndPlain_isAccepted() {
        XCTAssertNil(CommandLineHandoff.contextCheck(
            request: req(dir: "/u", plain: true), localUnisonDirectory: "/u"))
    }

    func test_context_normalizesPathsBeforeComparing() {
        XCTAssertNil(CommandLineHandoff.contextCheck(
            request: req(dir: "/u/./sub/..//"), localUnisonDirectory: "/u"))
    }

    func test_context_differentUnisonDirectory_isInvalid() {
        let r = CommandLineHandoff.contextCheck(
            request: req(given: "work", dir: "/other/config"), localUnisonDirectory: "/u")
        guard case .invalid(let m) = r else { return XCTFail("expected invalid on dir mismatch") }
        XCTAssertTrue(m.contains("different Unison directory"))
        XCTAssertTrue(m.contains("/u"))        // names the running app's directory
        XCTAssertTrue(m.contains("work"))
        XCTAssertTrue(m.contains("-ui text"))
    }

    func test_context_extraOptions_isInvalid() {
        let r = CommandLineHandoff.contextCheck(
            request: req(dir: "/u", plain: false), localUnisonDirectory: "/u")
        guard case .invalid(let m) = r else { return XCTFail("expected invalid on extra options") }
        XCTAssertTrue(m.contains("extra command-line options"))
        XCTAssertTrue(m.contains("-ui text"))
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
        XCTAssertTrue(m.contains("Close the profile editor"))
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

    // MARK: plain-request detection (finding 1: only faithfully transferable opens)

    func test_isPlainProfileRequest_bareProfile() {
        XCTAssertTrue(CommandLineHandoff.isPlainProfileRequest(arguments: ["exe", "work"], profile: "work"))
    }

    func test_isPlainProfileRequest_uiSelectorRemoved() {
        XCTAssertTrue(CommandLineHandoff.isPlainProfileRequest(
            arguments: ["exe", "-ui", "graphic", "work"], profile: "work"))
        XCTAssertTrue(CommandLineHandoff.isPlainProfileRequest(
            arguments: ["exe", "-ui=graphic", "work"], profile: "work"))
    }

    func test_isPlainProfileRequest_hostInjectedFlagsIgnored() {
        XCTAssertTrue(CommandLineHandoff.isPlainProfileRequest(
            arguments: ["exe", "-NSDocumentRevisionsDebugMode", "YES", "work"], profile: "work"))
    }

    func test_isPlainProfileRequest_extraOptions_isNotPlain() {
        XCTAssertFalse(CommandLineHandoff.isPlainProfileRequest(
            arguments: ["exe", "work", "-batch"], profile: "work"))
        XCTAssertFalse(CommandLineHandoff.isPlainProfileRequest(
            arguments: ["exe", "-path", "sub", "work"], profile: "work"))
        XCTAssertFalse(CommandLineHandoff.isPlainProfileRequest(
            arguments: ["exe", "-servercmd", "/x/unison", "work"], profile: "work"))
    }
}
