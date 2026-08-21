import XCTest
@testable import unison_ui_mac

/// Pure-function coverage for `ProgressDescriptor.parse`. The cell's
/// visual state (bar fill, text color/weight) follows directly from
/// the descriptor's fields — so pinning the descriptor for each
/// Unison-emitted progress shape is enough to lock the cell's
/// rendering without an AppKit harness.
final class ProgressDescriptorTests: XCTestCase {

    // MARK: - Idle / empty

    func test_emptyString_isEmptyDescriptor() {
        let d = ProgressDescriptor.parse("")
        XCTAssertNil(d.fraction)
        XCTAssertEqual(d.text, "")
        XCTAssertFalse(d.isFailure)
    }

    func test_whitespaceOnly_isEmptyDescriptor() {
        // Unison occasionally emits "   " between meaningful events;
        // it should render as idle, not as a labeled "blank" cell.
        let d = ProgressDescriptor.parse("   ")
        XCTAssertNil(d.fraction)
        XCTAssertEqual(d.text, "")
    }

    // MARK: - Percentages

    func test_percent_assignsFractionInZeroToOne() {
        XCTAssertEqual(ProgressDescriptor.parse("0%").fraction, 0.0)
        XCTAssertEqual(ProgressDescriptor.parse("35%").fraction, 0.35)
        XCTAssertEqual(ProgressDescriptor.parse("100%").fraction, 1.0)
    }

    func test_percent_clampsToZeroOne() {
        // Defensive — Unison shouldn't emit out-of-range, but if it
        // ever did the cell bar shouldn't overflow its track.
        XCTAssertEqual(ProgressDescriptor.parse("-10%").fraction, 0.0)
        XCTAssertEqual(ProgressDescriptor.parse("250%").fraction, 1.0)
    }

    func test_percent_toleratesLeadingWhitespace() {
        // Unison's status throttler emits " 35%" (with leading space)
        // when the number is one or two digits, so the cell aligns
        // visually in a fixed-width TUI. We accept either form.
        XCTAssertEqual(ProgressDescriptor.parse(" 35%").fraction, 0.35)
        XCTAssertEqual(ProgressDescriptor.parse("  5%").fraction, 0.05)
    }

    func test_percent_textIsPreservedVerbatim() {
        // We render whatever Unison sent (trimmed) so the column reads
        // "35%" rather than "0.35" — matches what the TUI shows.
        XCTAssertEqual(ProgressDescriptor.parse(" 35%").text, "35%")
        XCTAssertEqual(ProgressDescriptor.parse("100%").text, "100%")
    }

    // MARK: - Terminal states

    func test_done_isFullyFilledBar() {
        let d = ProgressDescriptor.parse("done")
        XCTAssertEqual(d.fraction, 1.0)
        XCTAssertEqual(d.text, "done")
        XCTAssertFalse(d.isFailure)
    }

    func test_FAILED_yieldsFailureNoBar() {
        let d = ProgressDescriptor.parse("FAILED")
        XCTAssertNil(d.fraction, "failure rows shouldn't draw a bar")
        XCTAssertEqual(d.text, "FAILED")
        XCTAssertTrue(d.isFailure)
    }

    func test_failureSubstring_matchedCaseInsensitive() {
        // Unison concatenates failure reasons after "FAILED:". Match
        // by substring so we catch any such variant.
        XCTAssertTrue(ProgressDescriptor.parse("FAILED").isFailure)
        XCTAssertTrue(ProgressDescriptor.parse("Failed").isFailure)
        XCTAssertTrue(ProgressDescriptor.parse("failed: permission denied").isFailure)
        XCTAssertTrue(ProgressDescriptor.parse("Permanent FAIL").isFailure)
    }

    // MARK: - Pre-percent labels

    func test_start_hasNoBarYetButShowsLabel() {
        // The "start" label fires before any byte has been transferred,
        // so we have no measurable fraction yet — show the text only.
        let d = ProgressDescriptor.parse("start ")
        XCTAssertNil(d.fraction)
        XCTAssertEqual(d.text, "start")
        XCTAssertFalse(d.isFailure)
    }

    func test_unknownLabel_passesThroughAsText() {
        // Defensive — if a future Unison ever emits a new label
        // (e.g. "queued"), show it rather than dropping the row to idle.
        let d = ProgressDescriptor.parse("queued")
        XCTAssertNil(d.fraction)
        XCTAssertEqual(d.text, "queued")
    }

    // MARK: - Equality

    func test_equatable_distinguishesAllFields() {
        XCTAssertEqual(ProgressDescriptor.empty, .empty)
        XCTAssertNotEqual(ProgressDescriptor.parse("35%"),
                          ProgressDescriptor.parse("36%"))
        XCTAssertNotEqual(ProgressDescriptor.parse("done"),
                          ProgressDescriptor.parse("FAILED"))
    }
}
