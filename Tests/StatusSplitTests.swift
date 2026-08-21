import XCTest
@testable import unison_ui_mac

/// Pure-function coverage for `ReconcileWindowController.splitStatus`.
/// The function decides "is this status message worth showing a Details
/// button for, and if so, what's the truncated first-line form?" —
/// answered wrong, the user either misses important error context or
/// sees a spurious Details button on every single-line message.
final class StatusSplitTests: XCTestCase {

    func test_singleLine_noDisclosure() {
        let r = ReconcileWindowController.splitStatus("Looking for changes")
        XCTAssertEqual(r.firstLine, "Looking for changes")
        XCTAssertEqual(r.fullText, "Looking for changes")
        XCTAssertFalse(r.hasMore)
    }

    func test_emptyInput_yieldsEmptyStrings() {
        let r = ReconcileWindowController.splitStatus("")
        XCTAssertEqual(r.firstLine, "")
        XCTAssertEqual(r.fullText, "")
        XCTAssertFalse(r.hasMore)
    }

    func test_whitespaceOnly_yieldsEmptyStrings() {
        // Pure whitespace shouldn't be treated as multi-line even if
        // there are newlines between empty lines.
        let r = ReconcileWindowController.splitStatus("   \n\n  ")
        XCTAssertEqual(r.firstLine, "")
        XCTAssertFalse(r.hasMore)
    }

    func test_twoLines_disclosesFullText() {
        let msg = "Connection failed\nhost unreachable"
        let r = ReconcileWindowController.splitStatus(msg)
        XCTAssertEqual(r.firstLine, "Connection failed")
        XCTAssertEqual(r.fullText, "Connection failed\nhost unreachable")
        XCTAssertTrue(r.hasMore)
    }

    func test_trimsLeadingTrailingWhitespacePerLine() {
        let msg = "  first  \n   second   \n"
        let r = ReconcileWindowController.splitStatus(msg)
        XCTAssertEqual(r.firstLine, "first")
        XCTAssertTrue(r.hasMore)
    }

    func test_singleLineWithTrailingNewline_isNotMultiLine() {
        // A single content line followed by a stray "\n" shouldn't
        // trigger the Details button — the newline is just terminator.
        let r = ReconcileWindowController.splitStatus("Connecting…\n")
        XCTAssertEqual(r.firstLine, "Connecting…")
        XCTAssertFalse(r.hasMore)
    }

    func test_realWorldSSHFailure_disclosesAllLines() {
        // Shape of a typical Unison SSH connect failure — multi-line
        // stderr piped through `displayStatus`. Must trigger the
        // Details disclosure.
        let msg = """
            ssh: connect to host server port 22: Connection refused
            Lost connection
            Fatal error: Server reported: cannot connect
            """
        let r = ReconcileWindowController.splitStatus(msg)
        XCTAssertEqual(r.firstLine, "ssh: connect to host server port 22: Connection refused")
        XCTAssertTrue(r.hasMore)
        // fullText preserves every non-empty line for the disclosure panel
        XCTAssertTrue(r.fullText.contains("Lost connection"))
        XCTAssertTrue(r.fullText.contains("Fatal error"))
    }

    func test_blankLinesBetweenContent_stillCountsAsMultiLine() {
        // Some Unison messages have a blank line between header and
        // body. Empty lines shouldn't affect the multi-line decision
        // — only non-empty content lines do.
        let r = ReconcileWindowController.splitStatus("header\n\nbody")
        XCTAssertEqual(r.firstLine, "header")
        XCTAssertTrue(r.hasMore)
    }
}
