import XCTest
@testable import unison_ui_mac

/// Pure-Swift tests for the StateItem value type. No OCaml runtime needed.
final class StateItemTests: XCTestCase {

    private func sample(direction: String = "<-?->",
                        progress: String = "",
                        bytes: Int64 = 0) -> StateItem {
        StateItem(
            path: "Documents/foo.txt",
            left: "Modified",
            right: "Modified",
            direction: direction,
            sizeBytes: 1024,
            fileType: "FILE",
            progress: progress,
            bytesTransferred: bytes
        )
    }

    func test_with_direction_returnsNewInstanceWithOnlyDirectionChanged() {
        let original = sample(direction: "<-?->")
        let updated = original.with(direction: "---->")

        XCTAssertEqual(updated.direction, "---->")
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
    }

    func test_with_progress_returnsNewInstanceWithProgressAndBytes() {
        let original = sample(progress: "", bytes: 0)
        let updated = original.with(progress: "50%", bytesTransferred: 512)

        XCTAssertEqual(updated.progress, "50%")
        XCTAssertEqual(updated.bytesTransferred, 512)
        // Direction unchanged
        XCTAssertEqual(updated.direction, original.direction)
        XCTAssertEqual(updated.path, original.path)
    }

    func test_with_progress_thenWithDirection_composesCorrectly() {
        let item = sample()
            .with(progress: "100%", bytesTransferred: 2048)
            .with(direction: "---->")
        XCTAssertEqual(item.progress, "100%")
        XCTAssertEqual(item.bytesTransferred, 2048)
        XCTAssertEqual(item.direction, "---->")
    }
}
