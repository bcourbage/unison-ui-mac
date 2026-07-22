import XCTest
@testable import unison_ui_mac

/// Issue #35 correction 1: the restart/fatal modal must anchor to a VISIBLE
/// window, never to a closed-but-retained picker.
final class RestartModalAnchorTests: XCTestCase {

    private typealias A = RestartModalAnchor

    func test_firstVisibleSessionWindowWins() {
        XCTAssertEqual(A.choose(candidatesVisible: [true], pickerVisible: true), .window(0))
    }

    func test_invisibleSessionWindowsSkipped_picksLaterVisible() {
        XCTAssertEqual(A.choose(candidatesVisible: [false, true], pickerVisible: true), .window(1))
    }

    func test_pickerWhenNoVisibleSession() {
        XCTAssertEqual(A.choose(candidatesVisible: [false], pickerVisible: true), .picker)
        XCTAssertEqual(A.choose(candidatesVisible: [], pickerVisible: true), .picker)
    }

    /// The key correction: a session window is visible but the picker is not
    /// (closed-but-retained) → anchor to the session window, not the picker.
    func test_sessionVisiblePickerNot_prefersSession() {
        XCTAssertEqual(A.choose(candidatesVisible: [true], pickerVisible: false), .window(0))
    }

    func test_appModalWhenNothingVisible() {
        XCTAssertEqual(A.choose(candidatesVisible: [false, false], pickerVisible: false), .appModal)
        XCTAssertEqual(A.choose(candidatesVisible: [], pickerVisible: false), .appModal)
    }
}
