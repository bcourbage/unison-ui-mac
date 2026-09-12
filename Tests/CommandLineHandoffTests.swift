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
                     args: [String] = []) -> Req {
        Req(given: given, rootsSet: rootsSet, unisonDirectory: dir,
            installationPath: install, sessionArgs: args)
    }

    // MARK: request codec

    func test_request_roundTrip() {
        let r = req(given: "work", rootsSet: 0, dir: "/u", install: "/A/app")
        XCTAssertEqual(Req(line: r.encoded()!), r)
    }

    func test_request_roundTrip_carriesAllFields() {
        let r = req(given: "p", rootsSet: 2, dir: "/other/config", install: "/B/app",
                    args: ["-path", "Documents"])
        let parsed = Req(line: r.encoded()!)
        XCTAssertEqual(parsed?.given, "p")
        XCTAssertEqual(parsed?.rootsSet, 2)
        XCTAssertEqual(parsed?.unisonDirectory, "/other/config")
        XCTAssertEqual(parsed?.installationPath, "/B/app")
        XCTAssertEqual(parsed?.sessionArgs, ["-path", "Documents"])
    }

    func test_request_roundTrip_sessionArgs_preserveOrderRepeatsAndOddBytes() {
        // base64-per-token, comma-joined: any bytes (tab, comma, newline, spaces,
        // option-like values) and repeats/order round-trip exactly.
        let r = req(args: ["-path", "a,b", "-path", "  ws\t", "-ignore", "Name -x", "-path", "-weird"])
        XCTAssertEqual(Req(line: r.encoded()!)?.sessionArgs,
                       ["-path", "a,b", "-path", "  ws\t", "-ignore", "Name -x", "-path", "-weird"])
    }

    func test_request_roundTrip_emptyArgsIsPlain() {
        let r = req(args: [])
        let parsed = Req(line: r.encoded()!)
        XCTAssertEqual(parsed?.sessionArgs, [])
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
        XCTAssertNil(Req(line: "nope\t0\t\tL3U=\tL0E=\td29yaw==\n"))    // wrong verb
        XCTAssertNil(Req(line: "open\t0\tL3U=\tL0E=\td29yaw==\n"))       // too few fields (5)
        XCTAssertNil(Req(line: "open\tx\t\tL3U=\tL0E=\td29yaw==\n"))     // non-integer roots
        XCTAssertNil(Req(line: "open\t0\t!!!\tL3U=\tL0E=\td29yaw==\n"))  // invalid base64 in args
        XCTAssertNil(Req(line: "open\t0\t\t!!!\tL0E=\td29yaw==\n"))      // invalid base64 in dir
        XCTAssertNil(Req(line: ""))
    }

    func test_request_rejects_nulInDecodedFields() {
        // A NUL survives base64/UTF-8 decoding but truncates at the C string
        // boundary the args + profile name cross, so the receiver would act on a
        // different value than it accepted. The whole line must be rejected.
        func line(args: String, name: String) -> String {
            let dir = Data("/u".utf8).base64EncodedString()
            let inst = Data("/A".utf8).base64EncodedString()
            return "open\t0\t\(args)\t\(dir)\t\(inst)\t\(name)\n"
        }
        let work = Data("work".utf8).base64EncodedString()
        let nulArg = Data("Documents\u{0}Other".utf8).base64EncodedString()
        XCTAssertNil(Req(line: line(args: nulArg, name: work)),
                     "a session arg containing NUL must be rejected")
        let nulName = Data("wo\u{0}rk".utf8).base64EncodedString()
        XCTAssertNil(Req(line: line(args: "", name: nulName)),
                     "a profile name containing NUL must be rejected")
    }

    // MARK: envelope (round 4: the caller's deadline travels with the request)

    func test_envelope_roundTrip() {
        let r = req(given: "work", dir: "/u", install: "/A/app")
        let line = CommandLineHandoff.encodeEnvelope(r, deadlineUptimeNanos: 123_456_789)!
        let decoded = CommandLineHandoff.decodeEnvelope(line)
        XCTAssertEqual(decoded?.deadlineUptimeNanos, 123_456_789)
        XCTAssertEqual(decoded?.request, r)
    }

    func test_envelope_rejectsMalformed() {
        XCTAssertNil(CommandLineHandoff.decodeEnvelope(req().encoded()!))       // no leading nanos field
        XCTAssertNil(CommandLineHandoff.decodeEnvelope("notanumber\t" + req().encoded()!))
        XCTAssertNil(CommandLineHandoff.decodeEnvelope("123\tgarbage\n"))       // bad request part
        XCTAssertNil(CommandLineHandoff.decodeEnvelope(""))
    }

    // MARK: response codec

    func test_response_roundTrip() {
        for r: Resp in [.started, .acceptedWaiting(message: "waiting to open work"),
                        .refused(message: "busy: scanning"), .invalid(message: "no such profile")] {
            XCTAssertEqual(Resp(line: r.encoded()), r)
        }
    }

    func test_response_truncatedOrUnknown_isNil() {
        XCTAssertNil(Resp(line: "ok"))                  // no newline = truncated
        XCTAssertNil(Resp(line: "refuse\tbusy"))        // no newline
        XCTAssertNil(Resp(line: "waiting\tsoon"))       // no newline
        XCTAssertNil(Resp(line: "weird\tthing\n"))      // unknown verb
        XCTAssertNil(Resp(line: ""))
    }

    func test_response_successAndClientMessage() {
        XCTAssertTrue(Resp.started.isSuccess)
        XCTAssertNil(Resp.started.clientMessage)
        // Accepted-and-waiting is a success (the app took the request), but it
        // carries an informational message for the caller.
        XCTAssertTrue(Resp.acceptedWaiting(message: "w").isSuccess)
        XCTAssertEqual(Resp.acceptedWaiting(message: "w").clientMessage, "w")
        XCTAssertFalse(Resp.refused(message: "x").isSuccess)
        XCTAssertEqual(Resp.refused(message: "x").clientMessage, "x")
        XCTAssertFalse(Resp.invalid(message: "y").isSuccess)
        XCTAssertEqual(Resp.invalid(message: "y").clientMessage, "y")
    }

    // MARK: context check (finding 1: faithful transfer)

    private func check(_ r: Req, dir: String = "/u", install: String = "/A/app") -> Resp? {
        CommandLineHandoff.contextCheck(request: r, localUnisonDirectory: dir,
                                        localInstallationPath: install)
    }

    func test_context_compatible_isAccepted() {
        XCTAssertNil(check(req(dir: "/u", install: "/A/app"), dir: "/u", install: "/A/app"))
    }

    func test_context_normalizesUnisonPathsBeforeComparing() {
        XCTAssertNil(check(req(dir: "/u/./sub/..//", install: "/A/app"), dir: "/u", install: "/A/app"))
    }

    func test_context_optionsAreDelivered_notRefused() {
        // The caller's own options are not a reason to refuse: the primary
        // delivers them to the opened session. With a matching installation and
        // Unison directory, a request carrying options is accepted.
        XCTAssertNil(check(req(dir: "/u", install: "/A/app", args: ["-path", "Documents", "-ignore", "Name x"]),
                           dir: "/u", install: "/A/app"),
                     "a request carrying session options must be accepted, not refused")
    }

    func test_context_receiverOwnLaunchIsNotAReason_isAccepted() {
        // The refusal redesign removed the "receiver was launched with options"
        // refusal: sessions are option-scoped, so how the app started does not
        // affect a delivered request. A compatible request is simply accepted.
        XCTAssertNil(check(req(dir: "/u", install: "/A/app"), dir: "/u", install: "/A/app"),
                     "the receiver's own launch is no longer a reason to refuse")
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

    func test_decide_idle_opensTheProfileNow() {
        XCTAssertEqual(CommandLineHandoff.decide(launch: .openProfile(name: "work"), activity: .idleAtPicker),
                       .openNow(name: "work"))
    }

    func test_decide_busyWillWait_acceptsToOpenAfterCleanup() {
        // A scan / reconcile / diff / close in flight can be left safely: the
        // request is accepted to open once the current work finishes.
        XCTAssertEqual(
            CommandLineHandoff.decide(launch: .openProfile(name: "work"),
                                      activity: .busyWillWait(reason: "scanning for changes")),
            .acceptWaiting(name: "work"))
    }

    func test_decide_synchronizing_refuses_pointingToTheApp() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "work"),
            activity: .synchronizing(reason: "synchronizing"))
        guard case .reply(.refused(let m)) = out else { return XCTFail("expected refusal during sync") }
        XCTAssertTrue(m.contains("synchronizing"))
        XCTAssertTrue(m.contains("work"))
        XCTAssertTrue(m.contains("handle the current sync in the app"))
        XCTAssertTrue(m.contains("-ui text"))
    }

    func test_decide_editing_refuses_withCloseEditorGuidance() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "other"),
            activity: .editing(profileDescription: "editing the profile home"))
        guard case .reply(.refused(let m)) = out else { return XCTFail("expected refusal") }
        XCTAssertTrue(m.contains("editing the profile home"))  // names the edited profile
        XCTAssertTrue(m.contains("other"))                     // names the request
        XCTAssertTrue(m.contains("Close the profile editor, then run the command again"))
    }

    func test_decide_restartRequired_refuses_withRecoveryGuidance() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "work"),
            activity: .restartRequired(reason: "needs to be quit and reopened after a connection problem"))
        guard case .reply(.refused(let m)) = out else { return XCTFail("expected refusal") }
        XCTAssertTrue(m.contains("needs to be quit and reopened"))
        XCTAssertTrue(m.contains("work"))
        XCTAssertTrue(m.contains("Quit and reopen it"))
    }

    func test_decide_requestAlreadyPending_refuses() {
        let out = CommandLineHandoff.decide(
            launch: .openProfile(name: "work"),
            activity: .requestAlreadyPending)
        guard case .reply(.refused(let m)) = out else { return XCTFail("expected refusal") }
        XCTAssertTrue(m.contains("already handling another command-line request"))
        XCTAssertTrue(m.contains("work"))
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

    func test_acceptedWaitingResponse_namesProfileAndReason() {
        guard case .acceptedWaiting(let m) =
                CommandLineHandoff.acceptedWaitingResponse(name: "work", reason: "scanning for changes") else {
            return XCTFail("expected an accepted-and-waiting response")
        }
        XCTAssertTrue(m.contains("scanning for changes"))
        XCTAssertTrue(m.contains("work"))
        XCTAssertTrue(m.contains("waiting in the app"))
    }
}
