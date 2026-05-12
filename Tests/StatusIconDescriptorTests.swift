import XCTest
@testable import unison_ui_mac
import AppKit

/// Pins the status-string → (symbol, color, tooltip) mapping. If anyone
/// renames a status or changes the icon convention, these tests force
/// the decision through code review.
final class StatusIconDescriptorTests: XCTestCase {

    func test_created_isFilledGreenPlus() {
        let d = StatusIconDescriptor.forStatus("Created")
        XCTAssertEqual(d.symbol, "plus.circle.fill")
        XCTAssertEqual(d.color, .systemGreen)
        XCTAssertEqual(d.tooltip, "Created")
    }

    func test_modified_isHollowBlueCircle() {
        let d = StatusIconDescriptor.forStatus("Modified")
        XCTAssertEqual(d.symbol, "circle")
        XCTAssertEqual(d.color, .systemBlue)
    }

    func test_propsChanged_distinguishesFromModifiedWithDashedOutline() {
        let d = StatusIconDescriptor.forStatus("PropsChanged")
        XCTAssertEqual(d.symbol, "circle.dashed",
                       "PropsChanged should be visually distinct from Modified")
        XCTAssertEqual(d.color, .systemBlue)
    }

    func test_deleted_isFilledRedMinus() {
        let d = StatusIconDescriptor.forStatus("Deleted")
        XCTAssertEqual(d.symbol, "minus.circle.fill")
        XCTAssertEqual(d.color, .systemRed)
    }

    func test_emptyString_isQuietGrayDot() {
        let d = StatusIconDescriptor.forStatus("")
        XCTAssertEqual(d.symbol, "circle.fill")
        XCTAssertEqual(d.color, .tertiaryLabelColor)
        XCTAssertLessThan(d.pointSize, 14,
                          "unchanged dot should be smaller than the change icons")
    }

    func test_unknownStatus_fallsBackToQuestionMark() {
        let d = StatusIconDescriptor.forStatus("WeirdNewStatusFromFutureUnison")
        XCTAssertEqual(d.symbol, "questionmark.circle")
        XCTAssertEqual(d.tooltip, "WeirdNewStatusFromFutureUnison",
                       "Unknown status passes through as the tooltip for debuggability")
    }
}
