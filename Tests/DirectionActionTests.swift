import XCTest
@testable import unison_ui_mac

/// Verifies the DirectionAction enum's identifier + label invariants so a
/// rename or reorder can't silently break toolbar wiring.
final class DirectionActionTests: XCTestCase {

    func test_all_containsAllFourActions() {
        XCTAssertEqual(DirectionAction.all.count, 4)
        XCTAssertEqual(Set(DirectionAction.all.map(\.toolbarIdentifier.rawValue)),
                       ["dir.toRemote", "dir.toLocal", "dir.skip", "dir.merge"])
    }

    func test_toolbarIdentifiers_areStableAndUnique() {
        // Stable identifiers matter — they're persisted in
        // NSUserDefaults via autosavesConfiguration on the toolbar.
        // Changing them would lose the user's customization.
        let ids = DirectionAction.all.map(\.toolbarIdentifier.rawValue)
        XCTAssertEqual(ids.count, Set(ids).count, "Toolbar identifiers must be unique")

        XCTAssertEqual(DirectionAction.toRemote.toolbarIdentifier.rawValue, "dir.toRemote")
        XCTAssertEqual(DirectionAction.toLocal.toolbarIdentifier.rawValue,  "dir.toLocal")
        XCTAssertEqual(DirectionAction.skip.toolbarIdentifier.rawValue,     "dir.skip")
        XCTAssertEqual(DirectionAction.merge.toolbarIdentifier.rawValue,    "dir.merge")
    }

    func test_workflowIdentifiers_areDistinctFromDirectionIdentifiers() {
        let workflow = [DirectionAction.goIdentifier,
                        DirectionAction.stopIdentifier,
                        DirectionAction.rescanIdentifier]
        let directions = Set(DirectionAction.all.map(\.toolbarIdentifier))
        for w in workflow {
            XCTAssertFalse(directions.contains(w),
                           "\(w.rawValue) collides with a direction identifier")
        }
        XCTAssertEqual(Set(workflow.map(\.rawValue)).count, workflow.count,
                       "Workflow identifiers must be unique")
    }

    func test_labels_areNonEmpty() {
        for action in DirectionAction.all {
            XCTAssertFalse(action.label.isEmpty, "\(action) has empty label")
            XCTAssertFalse(action.systemSymbol.isEmpty, "\(action) has empty SF symbol")
        }
    }
}
