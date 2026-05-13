import XCTest
@testable import unison_ui_mac

/// Verifies the IgnoreAction enum's invariants — labels match the legacy
/// app's Edit-menu titles, tags are stable + unique (they encode the action
/// in the menu wiring), and `all`/`from(tag:)` round-trip.
final class IgnoreActionTests: XCTestCase {

    func test_all_containsAllThreeActions() {
        XCTAssertEqual(IgnoreAction.all.count, 3)
        XCTAssertEqual(Set(IgnoreAction.all.map(\.label)),
                       ["Ignore Path", "Ignore Extension", "Ignore Name"])
    }

    func test_labels_matchLegacyMenuTitles() {
        // The legacy uimac MainMenu.xib uses these exact titles. Keeping
        // them identical means users coming from the legacy app find the
        // same menu items here.
        XCTAssertEqual(IgnoreAction.path.label, "Ignore Path")
        XCTAssertEqual(IgnoreAction.ext.label,  "Ignore Extension")
        XCTAssertEqual(IgnoreAction.name.label, "Ignore Name")
    }

    func test_menuTags_areStableAndUnique() {
        // Tags are persisted into NSMenuItem.tag and read back by the
        // dispatch handler — changing them silently breaks the wiring.
        XCTAssertEqual(IgnoreAction.path.menuTag, 101)
        XCTAssertEqual(IgnoreAction.ext.menuTag,  102)
        XCTAssertEqual(IgnoreAction.name.menuTag, 103)

        let tags = IgnoreAction.all.map(\.menuTag)
        XCTAssertEqual(tags.count, Set(tags).count,
                       "Menu tags must be unique across all actions")
    }

    func test_menuTags_dontCollideWithDirectionActionTags() {
        // DirectionAction uses 1..4 (see directionActionTag in
        // ReconcileToolbar.swift). IgnoreAction uses 101+. They live in
        // different menus today but a future shared-menu refactor would
        // depend on this.
        for ignoreAction in IgnoreAction.all {
            XCTAssertGreaterThan(ignoreAction.menuTag, 100,
                                 "IgnoreAction tags should sit above the DirectionAction range")
        }
    }

    func test_fromTag_roundTripsForAllActions() {
        for action in IgnoreAction.all {
            XCTAssertEqual(IgnoreAction.from(tag: action.menuTag), action)
        }
    }

    func test_fromTag_returnsNilForUnknownTag() {
        XCTAssertNil(IgnoreAction.from(tag: 0))
        XCTAssertNil(IgnoreAction.from(tag: 999))
        // DirectionAction's tag range (1..4) must not accidentally
        // resolve to an IgnoreAction.
        for tag in 1...4 {
            XCTAssertNil(IgnoreAction.from(tag: tag))
        }
    }
}
