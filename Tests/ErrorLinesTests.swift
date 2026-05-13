import XCTest
@testable import unison_ui_mac

/// Pins `ReconcileWindowController.errorLines(in:)` — the pure-function
/// classifier that decides which lines of a multi-line `displayStatus`
/// message should accumulate in the persistent error banner. The
/// classifier is intentionally conservative (false-positive over
/// false-negative): better to surface a benign line than miss a real
/// "permission denied".
final class ErrorLinesTests: XCTestCase {

    func test_emptyInput_returnsEmpty() {
        XCTAssertEqual(ReconcileWindowController.errorLines(in: ""), [])
    }

    func test_pureProgressMessage_returnsEmpty() {
        // Normal scan progress output shouldn't trip the filter.
        let text = "Looking for changes\nReconciling changes\nPropagating updates"
        XCTAssertEqual(ReconcileWindowController.errorLines(in: text), [])
    }

    func test_failedKeyword_matchesAnyCase() {
        // Unison emits various casings: "FAILED", "Failed", "failed".
        // All should match.
        let cases = [
            "scan FAILED for /Users/me/docs",
            "Failed to read /var/foo",
            "transfer failed: connection reset",
        ]
        for line in cases {
            XCTAssertEqual(
                ReconcileWindowController.errorLines(in: line),
                [line],
                "expected \(line) to match"
            )
        }
    }

    func test_permissionDenied_isCaught() {
        let line = "open(/etc/passwd): Permission denied"
        XCTAssertEqual(
            ReconcileWindowController.errorLines(in: line),
            [line]
        )
    }

    func test_sshHostKeyVerification_isCaught() {
        // Typical SSH error when the remote's key changed.
        let line = "Host key verification failed for server.example.com"
        XCTAssertEqual(
            ReconcileWindowController.errorLines(in: line).count,
            1,
            "should match on either 'host key verification' or 'failed'"
        )
    }

    func test_connectionRefused_isCaught() {
        let line = "ssh: connect to host: Connection refused"
        XCTAssertEqual(
            ReconcileWindowController.errorLines(in: line),
            [line]
        )
    }

    func test_multipleLines_picksOnlyTheBadOnes() {
        let text = """
            Looking for changes
            scan FAILED for /Users/me/big-file.dat
            Reconciling changes
            transfer failed: connection reset
            Done
            """
        let errors = ReconcileWindowController.errorLines(in: text)
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors[0].contains("FAILED"))
        XCTAssertTrue(errors[1].contains("failed"))
        // Critically: "Looking for changes" / "Reconciling" / "Done"
        // don't slip in.
        XCTAssertFalse(errors.contains { $0.contains("Looking for") })
        XCTAssertFalse(errors.contains { $0.contains("Reconciling") })
    }

    func test_trimsWhitespace() {
        // Status messages sometimes have leading-whitespace lines
        // (alignment in TUI output). The classifier trims before
        // matching, so the returned strings are clean.
        let text = "   FAILED: open(/foo): EACCES   "
        XCTAssertEqual(
            ReconcileWindowController.errorLines(in: text),
            ["FAILED: open(/foo): EACCES"]
        )
    }

    func test_substringMatch_isCaseInsensitive() {
        XCTAssertFalse(
            ReconcileWindowController.errorLines(in: "errorfree path").isEmpty,
            "substring match: 'error' inside 'errorfree' still matches; conservative by design"
        )
        // Documented false-positive: the classifier is intentionally
        // permissive. If this ever becomes annoying we can switch to
        // word-boundary matching, but until then the cost of a
        // spurious surfacing is small.
    }

    func test_utilFatal_isCaught() {
        // OCaml-side Util.Fatal that leaked through Trace rather than
        // hitting our fatalError handler.
        let line = "Util.Fatal: profile not found"
        XCTAssertEqual(
            ReconcileWindowController.errorLines(in: line),
            [line]
        )
    }

    func test_blankLinesAndPureWhitespace_dropOut() {
        // splitSeparator emits "" for blank lines with
        // omittingEmptySubsequences=true on the implementation —
        // verify we don't return them.
        let text = "\n\nFAILED: x\n\n  \n"
        let errors = ReconcileWindowController.errorLines(in: text)
        XCTAssertEqual(errors, ["FAILED: x"])
    }
}
