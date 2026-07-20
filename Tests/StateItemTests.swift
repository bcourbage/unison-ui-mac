import XCTest
@testable import unison_ui_mac

/// Pure-Swift tests for the StateItem value type. No OCaml runtime needed.
final class StateItemTests: XCTestCase {

    private func sample(direction: String = "<-?->",
                        progress: String = "",
                        bytes: Int64 = 0,
                        changedFromDefault: Bool = false) -> StateItem {
        StateItem(
            path: "Documents/foo.txt",
            left: "Modified",
            right: "Modified",
            direction: direction,
            sizeBytes: 1024,
            fileType: "FILE",
            progress: progress,
            bytesTransferred: bytes,
            changedFromDefault: changedFromDefault
        )
    }

    func test_withDirection_changesDirectionAndFlagTogether() {
        let original = sample(direction: "<-?->", changedFromDefault: false)
        // The direction updater must set BOTH the direction and the flag — there
        // is no direction-only updater that could desync them.
        let updated = original.with(direction: "---->", changedFromDefault: true)

        XCTAssertEqual(updated.direction, "---->")
        XCTAssertTrue(updated.changedFromDefault)
        // All other fields preserved
        XCTAssertEqual(updated.path, original.path)
        XCTAssertEqual(updated.left, original.left)
        XCTAssertEqual(updated.right, original.right)
        XCTAssertEqual(updated.sizeBytes, original.sizeBytes)
        XCTAssertEqual(updated.fileType, original.fileType)
        XCTAssertEqual(updated.progress, original.progress)
        XCTAssertEqual(updated.bytesTransferred, original.bytesTransferred)
        // Original unchanged
        XCTAssertEqual(original.direction, "<-?->")
        XCTAssertFalse(original.changedFromDefault)
    }

    func test_withProgress_preservesTrueChangedFromDefault() {
        // A progress update (during sync) must NOT drop a row's changed flag.
        let original = sample(progress: "", bytes: 0, changedFromDefault: true)
        let updated = original.with(progress: "50%", bytesTransferred: 512)

        XCTAssertEqual(updated.progress, "50%")
        XCTAssertEqual(updated.bytesTransferred, 512)
        XCTAssertTrue(updated.changedFromDefault, "progress update must preserve changedFromDefault")
        // Direction unchanged
        XCTAssertEqual(updated.direction, original.direction)
        XCTAssertEqual(updated.path, original.path)
    }

    func test_withProgress_thenWithDirection_composesCorrectly() {
        let item = sample(changedFromDefault: true)
            .with(progress: "100%", bytesTransferred: 2048)
            .with(direction: "---->", changedFromDefault: false)
        XCTAssertEqual(item.progress, "100%")
        XCTAssertEqual(item.bytesTransferred, 2048)
        XCTAssertEqual(item.direction, "---->")
        XCTAssertFalse(item.changedFromDefault)
    }
}
