import XCTest
@testable import unison_ui_mac

/// Verifies the DirectionAction enum's identifier + label invariants so a
/// rename or reorder can't silently break toolbar wiring. Covers both
/// the toolbar subset (`toolbarActions`) and the full menu set
/// (`menuActions`) including the menu-only force-older / force-newer
/// variants added in the P2 Force/Merge pass.
final class DirectionActionTests: XCTestCase {

    // MARK: - toolbarActions (segmented group)

    func test_toolbarActions_containsTheFourSegmentedItems() {
        XCTAssertEqual(DirectionAction.toolbarActions.count, 4)
        XCTAssertEqual(Set(DirectionAction.toolbarActions.map(\.toolbarIdentifier.rawValue)),
                       ["dir.toSecond", "dir.toFirst", "dir.skip", "dir.merge"])
    }

    func test_toolbarActions_omitsMenuOnlyForceVariants() {
        // Force older/newer live on the Edit menu but not on the
        // toolbar — they're useful enough to expose but rare enough
        // that they don't earn toolbar real estate.
        XCTAssertFalse(DirectionAction.toolbarActions.contains(.forceOlder))
        XCTAssertFalse(DirectionAction.toolbarActions.contains(.forceNewer))
    }

    // MARK: - menuActions (full Edit-menu set)

    func test_menuActions_containsAllSix() {
        XCTAssertEqual(DirectionAction.menuActions.count, 6)
        XCTAssertEqual(Set(DirectionAction.menuActions),
                       Set(DirectionAction.allCases))
    }

    func test_menuActions_readingOrder_matchesLegacyAppActionMenu() {
        // Legacy app's Action menu order: direction first, alternatives
        // next, mtime variants last. Tests pin the order so a casual
        // reordering of the array can't change muscle memory.
        XCTAssertEqual(DirectionAction.menuActions,
                       [.toFirst, .toSecond, .skip, .merge, .forceOlder, .forceNewer])
    }

    // MARK: - Identifiers

    func test_toolbarIdentifiers_areStableAndUnique() {
        // Stable identifiers matter — they're persisted in
        // NSUserDefaults via autosavesConfiguration on the toolbar.
        // Changing them would lose the user's customization. The
        // ReconcileToolbar.v4 → v5 bump in May 2026 reset autosaves
        // because the direction-group's subitem set became profile-
        // dependent (Merge hidden when no `merge` pref).
        let ids = DirectionAction.allCases.map(\.toolbarIdentifier.rawValue)
        XCTAssertEqual(ids.count, Set(ids).count, "Toolbar identifiers must be unique")

        XCTAssertEqual(DirectionAction.toSecond.toolbarIdentifier.rawValue,   "dir.toSecond")
        XCTAssertEqual(DirectionAction.toFirst.toolbarIdentifier.rawValue,    "dir.toFirst")
        XCTAssertEqual(DirectionAction.skip.toolbarIdentifier.rawValue,       "dir.skip")
        XCTAssertEqual(DirectionAction.merge.toolbarIdentifier.rawValue,      "dir.merge")
        XCTAssertEqual(DirectionAction.forceOlder.toolbarIdentifier.rawValue, "dir.forceOlder")
        XCTAssertEqual(DirectionAction.forceNewer.toolbarIdentifier.rawValue, "dir.forceNewer")
    }

    func test_workflowIdentifiers_areDistinctFromDirectionIdentifiers() {
        let workflow = [DirectionAction.goIdentifier,
                        DirectionAction.stopIdentifier,
                        DirectionAction.rescanIdentifier]
        let directions = Set(DirectionAction.allCases.map(\.toolbarIdentifier))
        for w in workflow {
            XCTAssertFalse(directions.contains(w),
                           "\(w.rawValue) collides with a direction identifier")
        }
        XCTAssertEqual(Set(workflow.map(\.rawValue)).count, workflow.count,
                       "Workflow identifiers must be unique")
    }

    // MARK: - Menu tags

    func test_menuTags_areStableAndUnique() {
        // Tags travel from MainMenu (set on NSMenuItem) through the
        // responder chain to the controller's directionMenuAction(_:),
        // which round-trips them back to a DirectionAction via
        // `from(menuTag:)`. Stability matters; collisions silently break
        // the dispatch.
        let tags = DirectionAction.allCases.map(\.menuTag)
        XCTAssertEqual(tags.count, Set(tags).count, "Menu tags must be unique")

        XCTAssertEqual(DirectionAction.toSecond.menuTag,   1)
        XCTAssertEqual(DirectionAction.toFirst.menuTag,    2)
        XCTAssertEqual(DirectionAction.skip.menuTag,       3)
        XCTAssertEqual(DirectionAction.merge.menuTag,      4)
        XCTAssertEqual(DirectionAction.forceOlder.menuTag, 5)
        XCTAssertEqual(DirectionAction.forceNewer.menuTag, 6)
    }

    func test_fromMenuTag_roundTrips() {
        for action in DirectionAction.allCases {
            XCTAssertEqual(DirectionAction.from(menuTag: action.menuTag), action)
        }
    }

    func test_fromMenuTag_returnsNilForUnknown() {
        XCTAssertNil(DirectionAction.from(menuTag: 0))
        XCTAssertNil(DirectionAction.from(menuTag: 99))
        // IgnoreAction tags (101+) should not resolve to a direction.
        for tag in [101, 102, 103] {
            XCTAssertNil(DirectionAction.from(menuTag: tag))
        }
    }

    func test_menuTags_dontCollideWithIgnoreActionTags() {
        // DirectionAction lives in 1..6; IgnoreAction in 101..103.
        for action in DirectionAction.allCases {
            XCTAssertLessThan(action.menuTag, 100,
                              "DirectionAction tags must stay below the IgnoreAction range")
        }
    }

    // MARK: - Labels + symbols

    func test_labels_areNonEmpty() {
        for action in DirectionAction.allCases {
            XCTAssertFalse(action.label.isEmpty, "\(action) has empty label")
            XCTAssertFalse(action.systemSymbol.isEmpty, "\(action) has empty SF symbol")
        }
    }
}
