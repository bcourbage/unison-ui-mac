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
        // Guard so a count-mismatch surfaces as a clean
        // XCTAssertEqual failure rather than degrading into a SIGTRAP
        // on the subsequent `errors[0]` subscript when the array is
        // empty. (Hit this for real once after a buggy regex
        // refactor — the bounds-check crash buried the actual
        // assertion under a confusing crash report.)
        guard errors.count == 2 else { return }
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
        // Single-word markers ("error", "fail", etc.) are matched
        // with word boundaries (\b) so they don't false-positive on
        // identifiers. "errorfree" is one word — "error" is a
        // prefix, no boundary between it and "free" — so no match.
        // Bare "Error:" / "ERROR " / etc. still match (the boundary
        // is the `:` or space after).
        XCTAssertTrue(
            ReconcileWindowController.errorLines(in: "errorfree path").isEmpty,
            "single-word markers use word boundaries: 'errorfree' must NOT match"
        )
        XCTAssertFalse(
            ReconcileWindowController.errorLines(in: "Error: bad").isEmpty,
            "'Error:' is a word-boundary match"
        )
    }

    func test_pathContainingErrorWord_doesNotFalsePositive() {
        // User-reported case: status messages of the form
        // "Propagating changes  <path>" got falsely classified as
        // errors when the path contained "Error" in a filename
        // (e.g. ErrorLinesTests.swift in this very repo). Word-
        // boundary matching prevents that.
        let lines = [
            "Propagating changes  Documents/Sources/unison-ui-mac/Tests/ErrorLinesTests.swift",
            "Propagating changes  build/Debug/ErrorLinesTests.o",
            "Propagating changes  build/Debug/ErrorLinesTests.swiftdeps",
            "Propagating changes  build/Index.noindex/DataStore/v5/records/JY/ErrorLinesTests.swift-1TO02C067SEJY",
            "Propagating changes  build/Index.noindex/DataStore/v5/units/ErrorLinesTests.o-WIDNWSC5B6H3",
        ]
        for line in lines {
            XCTAssertTrue(
                ReconcileWindowController.errorLines(in: line).isEmpty,
                "expected NO false-positive on path-with-Error-substring: \(line)"
            )
        }
    }

    func test_failSubstring_doesNotFalsePositiveInsideIdentifier() {
        // Same pattern as the "error" case — "fail" embedded in a
        // word shouldn't trigger.
        XCTAssertTrue(
            ReconcileWindowController.errorLines(in: "default_log_path").isEmpty,
            "'default' contains 'fail' as substring but not as a word"
        )
        // …but bare "FAIL" / "Failed:" must still match.
        XCTAssertFalse(
            ReconcileWindowController.errorLines(in: "scan FAILED").isEmpty
        )
        XCTAssertFalse(
            ReconcileWindowController.errorLines(in: "Failed: nope").isEmpty
        )
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

    func test_abortedKeyword_isCaught() {
        // Unison's "Transfer aborted" message (e.g. source file
        // modified during sync) needs to count toward the error
        // banner. This is the user-reported failure mode that
        // initially wasn't being captured because "aborted" wasn't
        // on the keyword list.
        let cases = [
            "The source file foo has been modified during synchronization.  Transfer aborted.",
            "Aborted by user request",
        ]
        for line in cases {
            XCTAssertEqual(
                ReconcileWindowController.errorLines(in: line).count,
                1,
                "expected 'aborted' to match in: \(line)"
            )
        }
    }

    func test_couldntKeyword_isCaught() {
        // "couldn't open file" is a common Unison wording for
        // permission/race errors. The list catches both the formal
        // "could not" and the contraction "couldn't".
        XCTAssertFalse(
            ReconcileWindowController.errorLines(in: "couldn't open file /tmp/x").isEmpty
        )
    }

    // MARK: - detailsIndicateFailure / failureReason

    func test_detailsIndicateFailure_recognizesTransferAborted() {
        let details = """
            Photos Library.photoslibrary/database/Photos.sqlite-shm
            The source file ... has been modified during synchronization.  Transfer aborted.
            """
        XCTAssertTrue(ReconcileWindowController.detailsIndicateFailure(details))
    }

    func test_detailsIndicateFailure_recognizesFailedColon() {
        XCTAssertTrue(ReconcileWindowController.detailsIndicateFailure(
            "Failed: connection reset"))
    }

    func test_detailsIndicateFailure_recognizesPermissionDenied() {
        XCTAssertTrue(ReconcileWindowController.detailsIndicateFailure(
            "open(/etc/shadow): Permission denied"))
    }

    func test_detailsIndicateFailure_rejectsNormalSuccessDetails() {
        // Per-row details on a successful sync look like file
        // metadata — sizes, mtimes, no failure phrasing. Must NOT
        // trip the classifier.
        let normal = """
            path/to/file.txt
            Type: file
            Modified: 2026-05-13 09:30:00
            Size: 1.2 MB
            """
        XCTAssertFalse(ReconcileWindowController.detailsIndicateFailure(normal))
    }

    func test_detailsIndicateFailure_doesNotMatchUserSkipped() {
        // "Skipped" is used for user-initiated direction skips —
        // those aren't failures. Important false-negative case:
        // don't synthesize FAILED on rows the user deliberately
        // skipped before Go.
        let userSkipped = """
            path/to/file.txt
            Status: skipped by user
            """
        XCTAssertFalse(ReconcileWindowController.detailsIndicateFailure(userSkipped))
    }

    func test_failureReason_extractsTheLineContainingTheMarker() {
        let details = """
            Photos Library.photoslibrary/database/Photos.sqlite-shm
            The source file ... has been modified during synchronization.  Transfer aborted.
            """
        let reason = ReconcileWindowController.failureReason(from: details)
        XCTAssertTrue(reason.contains("Transfer aborted"),
                      "expected reason to be the marker-bearing line: \(reason)")
        XCTAssertFalse(reason.contains("\n"),
                       "reason should be a single line")
    }

    func test_failureReason_fallsBackToLastLineWhenNoMarker() {
        // If somehow a multi-line string has no failure marker
        // (shouldn't normally reach this function — detailsIndicateFailure
        // gates it — but defensive), return something rather than
        // crash. The last non-empty line is the natural fallback.
        let details = "line one\nline two\nline three"
        XCTAssertEqual(
            ReconcileWindowController.failureReason(from: details),
            "line three"
        )
    }

    func test_failureReason_emptyInput_returnsPlaceholder() {
        let reason = ReconcileWindowController.failureReason(from: "")
        XCTAssertEqual(reason, "transfer error")
    }
}
