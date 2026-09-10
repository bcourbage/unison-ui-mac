import XCTest
@testable import unison_ui_mac

/// The pure line protocol and accept/refuse decision for running-instance
/// routing (req 5 of #122). The socket transport is exercised separately in
/// CommandLineHandoffSocketTests.
final class CommandLineHandoffTests: XCTestCase {

    private typealias Req = CommandLineHandoff.Request
    private typealias Resp = CommandLineHandoff.Response

    // MARK: request codec

    func test_request_roundTrip_plainName() {
        let r = Req(given: "work", rootsSet: 0)
        XCTAssertEqual(r.encoded(), "open\t0\twork\n")
        XCTAssertEqual(Req(line: r.encoded()!), r)
    }

    func test_request_roundTrip_nameWithSpacesAndTabs() {
        // Given is read to end-of-line, so spaces and tabs in a profile name
        // survive the round trip.
        let r = Req(given: "my work\tprofile", rootsSet: 1)
        XCTAssertEqual(Req(line: r.encoded()!), r)
    }

    func test_request_encoded_nilWhenNewlineInName() {
        XCTAssertNil(Req(given: "two\nlines", rootsSet: 0).encoded())
    }

    func test_request_parse_toleratesMissingTrailingNewline() {
        XCTAssertEqual(Req(line: "open\t2\tp"), Req(given: "p", rootsSet: 2))
    }

    func test_request_parse_rejectsMalformed() {
        XCTAssertNil(Req(line: "nope\t0\tp\n"))        // wrong verb
        XCTAssertNil(Req(line: "open\tp\n"))            // too few fields
        XCTAssertNil(Req(line: "open\tx\tp\n"))         // non-integer roots
        XCTAssertNil(Req(line: ""))                      // empty
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

    // MARK: decision

    func test_decide_invalidLaunch_repliesInvalid() {
        let out = CommandLineHandoff.decide(
            launch: .refuse(message: "roots not supported"), activity: .idleAtPicker)
        XCTAssertEqual(out, .reply(.invalid(message: "roots not supported")))
    }

    func test_decide_noProfileLaunch_repliesInvalid() {
        // The client only hands off with a profile, so .showPicker here is a
        // malformed request, not a real picker launch.
        let out = CommandLineHandoff.decide(launch: .showPicker, activity: .idleAtPicker)
        guard case .reply(.invalid) = out else { return XCTFail("expected invalid") }
    }

    func test_decide_idle_opensTheProfile() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "work"), activity: .idleAtPicker)
        XCTAssertEqual(out, .open(name: "work"))
    }

    func test_decide_busy_refusesAndPreservesWork() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "work"), activity: .busy(reason: "scanning for changes"))
        guard case .reply(.refused(let message)) = out else {
            return XCTFail("expected a refusal when busy")
        }
        XCTAssertTrue(message.contains("scanning for changes"))  // says what it kept
        XCTAssertTrue(message.contains("work"))                  // names the request
        XCTAssertTrue(message.contains("-ui text"))              // the terminal escape hatch
    }
}
