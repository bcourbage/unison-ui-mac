import XCTest
@testable import unison_ui_mac

/// Pure-logic coverage for the Stop toolbar/menu item's presentation. The
/// decision lives in `StopItemAppearance` so it's testable without an AppKit
/// toolbar-validation harness.
///
/// Post issue #117 the item is sync-only: the title is always "Stop", and both
/// enablement (at the call site) and the destructive tint derive from a single
/// `canStop` verdict, so a disabled Stop can never be painted red.
final class StopItemAppearanceTests: XCTestCase {

    // MARK: - Title is constant

    func test_title_isAlwaysStop() {
        XCTAssertEqual(StopItemAppearance(canStop: true).title, "Stop")
        XCTAssertEqual(StopItemAppearance(canStop: false).title, "Stop")
    }

    func test_symbol_isAlwaysStopFill() {
        XCTAssertEqual(StopItemAppearance(canStop: true).systemSymbol, "stop.fill")
        XCTAssertEqual(StopItemAppearance(canStop: false).systemSymbol, "stop.fill")
    }

    // MARK: - Tint tracks the single verdict

    func test_canStop_isDestructive() {
        XCTAssertEqual(StopItemAppearance(canStop: true).tint, .destructive)
    }

    func test_cannotStop_isNeutral() {
        XCTAssertEqual(StopItemAppearance(canStop: false).tint, .normal)
    }

    /// The whole point of #117 refinement #2: presentation is a pure function of
    /// the gate verdict, so tint and enablement cannot disagree. A disabled item
    /// (canStop == false) is never destructive.
    func test_tint_isNeverDestructiveWhenDisabled() {
        XCTAssertNotEqual(StopItemAppearance(canStop: false).tint, .destructive)
    }

    // MARK: - Copy is non-empty in both states

    func test_toolTip_isPresentInBothStates() {
        for canStop in [true, false] {
            XCTAssertFalse(StopItemAppearance(canStop: canStop).toolTip.isEmpty)
        }
    }
}
