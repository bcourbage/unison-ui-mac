import XCTest
@testable import unison_ui_mac

/// Classification by observation only, with stderr fixtures recorded from
/// real ssh sessions (Demeter, 2026-09-07), and the wording rules of the
/// design's Step 5.
final class RemoteVerificationTests: XCTestCase {
    private typealias V = RemoteVerification
    private typealias W = RemoteCheckWording
    private let marker = "unison-ui-mac-check-0123abcd"

    /// Phrases the design forbids: each would turn an observation into a
    /// claim about an execution stage.
    private let forbidden = ["could not start", "no executable", "the command began", "a file exists"]

    private func assertObservationOnly(_ sentences: [String], file: StaticString = #filePath, line: UInt = #line) {
        let text = sentences.joined(separator: " ").lowercased()
        for f in forbidden {
            XCTAssertFalse(text.contains(f), "forbidden phrase \"\(f)\" in: \(text)", file: file, line: line)
        }
        XCTAssertEqual(sentences.last, W.closingAfterFailure, file: file, line: line)
    }

    // MARK: - remote command

    func test_remoteCommand_prefixesPrintfMarker() {
        XCTAssertEqual(V.remoteCommand(marker: marker, versionCommand: "/opt/homebrew/bin/unison -version"),
                       "printf '\(marker)'; /opt/homebrew/bin/unison -version")
    }

    func test_marker_isSafeCharactersOnly() {
        let m = RemoteCheckSession.makeMarker(prefix: V.markerPrefix)
        XCTAssertTrue(m.hasPrefix("unison-ui-mac-check-"))
        XCTAssertTrue(m.unicodeScalars.allSatisfy(ServercmdProposal.isSafe))
        XCTAssertNotEqual(m, RemoteCheckSession.makeMarker(prefix: V.markerPrefix))
    }

    // MARK: - observation

    func test_observe_stripsMarker_evenAfterBanner() {
        let o = V.observe(raw: .exited(status: 0, stdout: "Welcome\n\(marker)unison version 2.54.0 (ocaml 5.5.0)\n", stderr: ""),
                          marker: marker, deadline: 10)
        XCTAssertTrue(o.markerReceived)
        XCTAssertEqual(o.firstStdoutLine, "unison version 2.54.0 (ocaml 5.5.0)")
        XCTAssertEqual(V.verdict(o), .verified(version: "2.54.0", firstLine: "unison version 2.54.0 (ocaml 5.5.0)"))
    }

    func test_observe_noMarker_keepsWholeStdout() {
        let o = V.observe(raw: .exited(status: 255, stdout: "", stderr: "nosuchuser@192.168.2.35: Permission denied (publickey).\n"),
                          marker: marker, deadline: 10)
        XCTAssertFalse(o.markerReceived)
        XCTAssertEqual(o.termination, .exited(status: 255))
        XCTAssertEqual(o.firstStderrLine, "nosuchuser@192.168.2.35: Permission denied (publickey).")
        XCTAssertEqual(V.verdict(o), .notVerified)
    }

    func test_observe_timeout_carriesPartialOutput() {
        let o = V.observe(raw: .timedOut(stdout: "\(marker)partial", stderr: ""), marker: marker, deadline: 10.4)
        XCTAssertTrue(o.markerReceived)
        XCTAssertEqual(o.termination, .deadlineExpired(seconds: 10))
        XCTAssertEqual(o.stdoutAfterMarker, "partial")
    }

    func test_verdict_cancelled_andLaunchFailed() {
        XCTAssertEqual(V.verdict(V.observe(raw: .cancelled, marker: marker, deadline: 10)), .cancelled)
        XCTAssertEqual(V.verdict(V.observe(raw: .launchFailed("no such file"), marker: marker, deadline: 10)), .notVerified)
    }

    func test_verdict_markerWithNonZeroExit_orNonVersionLine_isNotVerified() {
        XCTAssertEqual(V.verdict(V.observe(raw: .exited(status: 127, stdout: marker, stderr: "x"), marker: marker, deadline: 10)), .notVerified)
        XCTAssertEqual(V.verdict(V.observe(raw: .exited(status: 0, stdout: "\(marker)hello\n", stderr: ""), marker: marker, deadline: 10)), .notVerified)
        // A version line without the marker is not verified either: the
        // marker proves the command line the check composed is what ran.
        XCTAssertEqual(V.verdict(V.observe(raw: .exited(status: 0, stdout: "unison version 2.54.0\n", stderr: ""), marker: marker, deadline: 10)), .notVerified)
    }

    // MARK: - wording: failures (recorded stderr fixtures)

    private func failure(_ raw: VersionCheck.RawExecResult, path: String? = nil,
                         discovery: RemoteDiscovery.Record? = nil) -> [String] {
        W.failure(V.observe(raw: raw, marker: marker, deadline: 10), executablePath: path, discovery: discovery)
    }

    func test_wording_batchModeAuthentication() {
        let s = failure(.exited(status: 255, stdout: "", stderr: "nosuchuser@192.168.2.35: Permission denied (publickey).\n"))
        XCTAssertEqual(s[0], "No start marker was received before ssh exited (status 255, nosuchuser@192.168.2.35: Permission denied (publickey).).")
        XCTAssertEqual(s[1], "Execution status is unknown.")
        XCTAssertEqual(s[2], "A synchronization may still connect if it can answer a prompt; this check cannot.")
        assertObservationOnly(s)
    }

    func test_wording_hostKey() {
        let s = failure(.exited(status: 255, stdout: "", stderr: "Host key verification failed.\n"))
        XCTAssertEqual(s[0], "No start marker was received before ssh exited (status 255, Host key verification failed.).")
        assertObservationOnly(s)
    }

    func test_wording_connectionRefused() {
        let s = failure(.exited(status: 255, stdout: "", stderr: "ssh: connect to host 192.168.2.35 port 1: Connection refused\n"))
        XCTAssertEqual(s[0], "No start marker was received before ssh exited (status 255, ssh: connect to host 192.168.2.35 port 1: Connection refused).")
        assertObservationOnly(s)
    }

    func test_wording_noMarker_deadlineExpired() {
        let s = failure(.timedOut(stdout: "", stderr: ""))
        XCTAssertEqual(s[0], "No start marker was received before the 10-second deadline.")
        XCTAssertEqual(s[1], "Execution status is unknown.")
        assertObservationOnly(s)
    }

    func test_wording_markerThenDeadline() {
        let s = failure(.timedOut(stdout: "\(marker)Starting", stderr: ""))
        XCTAssertEqual(s[0], "The remote shell emitted the start marker; the 10-second deadline expired. Output received so far: Starting. Whether the executable started is not established.")
        assertObservationOnly(s)
        let none = failure(.timedOut(stdout: marker, stderr: ""))
        XCTAssertTrue(none[0].contains("Output received so far: nothing."))
    }

    func test_wording_marker127_withoutDiscoveryRecord_addsNoFileSentence() {
        // Recorded: `printf 'UUM-1'; /nonexistent/unison -version` on Demeter (zsh login shell).
        let disc = RemoteDiscovery.Record(complete: true, uname: "Darwin", present: [], absent: ["/nonexistent/unison"], commandV: "")
        let s = failure(.exited(status: 127, stdout: marker, stderr: "zsh:1: no such file or directory: /nonexistent/unison\n"),
                        path: "/nonexistent/unison", discovery: disc)
        XCTAssertEqual(s[0], "The remote shell emitted the start marker; the command line then exited with status 127; stderr: zsh:1: no such file or directory: /nonexistent/unison.")
        XCTAssertEqual(s[1], "During discovery no file was found at /nonexistent/unison.")
        assertObservationOnly(s)
    }

    func test_wording_marker127_withDiscoveryRecord_addsDependencySentence() {
        let disc = RemoteDiscovery.Record(complete: true, uname: "Darwin",
                                          present: [.init(path: "/usr/local/bin/unison", kind: .regular, resolvedPath: nil, versionLine: nil)],
                                          absent: [], commandV: "")
        let s = failure(.exited(status: 127, stdout: marker, stderr: "sh: /usr/local/bin/unison: cannot execute\n"),
                        path: "/usr/local/bin/unison", discovery: disc)
        XCTAssertEqual(s[1], "During discovery a file was found at /usr/local/bin/unison; status 127 with this stderr can also mean a dependency of that file is missing.")
        assertObservationOnly(s)
    }

    func test_wording_marker127_withoutAnyDiscovery_addsNothing() {
        let s = failure(.exited(status: 127, stdout: marker, stderr: "sh: unison: not found\n"), path: "unison", discovery: nil)
        XCTAssertEqual(s.count, 2)
        assertObservationOnly(s)
    }

    func test_wording_markerNonZero_otherStatus() {
        let s = failure(.exited(status: 1, stdout: marker, stderr: "Fatal error: bad option\n"))
        XCTAssertEqual(s[0], "The remote shell emitted the start marker; the command line then exited with status 1; stderr: Fatal error: bad option.")
        assertObservationOnly(s)
    }

    func test_wording_markerExitZero_notAVersionLine() {
        let s = failure(.exited(status: 0, stdout: "\(marker)hello world\n", stderr: ""))
        XCTAssertEqual(s[0], "The remote shell emitted the start marker; the command line printed hello world, which is not a Unison version line.")
        assertObservationOnly(s)
    }

    func test_wording_launchFailed_andCancelled() {
        let s = failure(.launchFailed("The file “ssh” doesn’t exist."))
        XCTAssertTrue(s[0].hasPrefix("The local ssh command could not be started: "))
        XCTAssertEqual(s[1], "Execution status is unknown.")
        assertObservationOnly(s)
        XCTAssertEqual(failure(.cancelled), [W.cancelled])
    }

    // MARK: - wording: observations on success

    func test_wording_connection_executable_identity_boundary() {
        XCTAssertEqual(W.connection(host: "demeter", user: "bruno"), "ssh connected to demeter as bruno without prompting.")
        XCTAssertEqual(W.connection(host: "demeter", user: nil), "ssh connected to demeter without prompting.")
        let link = RemoteDiscovery.Candidate(path: "/opt/homebrew/bin/unison",
                                             kind: .symlink(storedTarget: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"),
                                             resolvedPath: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool", versionLine: nil)
        XCTAssertEqual(W.executable(link, host: "demeter"), [
            "/opt/homebrew/bin/unison on demeter is a symlink whose stored target is /Applications/unison-ui-mac.app/Contents/MacOS/cltool.",
            "Fully resolved by the remote: /Applications/unison-ui-mac.app/Contents/MacOS/cltool.",
        ])
        let file = RemoteDiscovery.Candidate(path: "/usr/bin/unison", kind: .regular, resolvedPath: "/usr/bin/unison", versionLine: nil)
        XCTAssertEqual(W.executable(file, host: "h"), ["/usr/bin/unison on h is a regular file."])
        XCTAssertEqual(W.versionPrinted(remoteCommand: "/opt/homebrew/bin/unison -version", line: "unison version 2.54.0 (ocaml 5.5.0)"),
                       "/opt/homebrew/bin/unison -version printed unison version 2.54.0 (ocaml 5.5.0).")
        XCTAssertEqual(W.identityByPath("/Applications/unison-ui-mac.app/Contents/MacOS/cltool"), "That path is inside a unison-ui-mac.app bundle (by path).")
        XCTAssertNil(W.identityByPath("/usr/local/bin/unison"))
        XCTAssertEqual(W.protocolBoundary(local: "2.54.0", remote: "2.53.5", host: "demeter"),
                       "2.54.0 (this Mac) and 2.53.5 (demeter) are on the same side of the 2.52 boundary.")
        XCTAssertEqual(W.protocolBoundary(local: "2.54.0", remote: "2.51.5", host: "demeter"),
                       "2.54.0 (this Mac) and 2.51.5 (demeter) are on opposite sides of the 2.52 boundary and cannot connect.")
        XCTAssertTrue(W.pathDecidedByRemote(host: "demeter").contains("cannot see that PATH"))
        XCTAssertTrue(W.commandV("", host: "demeter").contains("resolved no unison"))
        XCTAssertTrue(W.commandV("/usr/local/bin/unison", host: "demeter").contains("resolves unison to /usr/local/bin/unison"))
    }

    func test_noWording_usesFirstPerson() {
        var all: [String] = [W.executionStatusUnknown, W.promptNote, W.closingAfterVersion, W.closingAfterFailure, W.cancelled,
                             W.pathDecidedByRemote(host: "h"), W.commandV("", host: "h"), W.commandV("/x", host: "h")]
        all += failure(.exited(status: 255, stdout: "", stderr: "x"))
        all += failure(.timedOut(stdout: marker, stderr: ""))
        for s in all {
            XCTAssertFalse(s.contains(" I ") || s.hasPrefix("I ") || s.contains(" we ") || s.contains("—"), s)
        }
    }
}
