import XCTest
import AppKit
@testable import unison_ui_mac

/// Pins the unified-diff line classification — the rule that decides
/// which lines render in green (added) / red (removed) / blue (hunk
/// header) / bold (file header). The classification is a pure static
/// on `DiffWindowController`, so we can test it without instantiating
/// the window.
///
/// The order of checks matters: 3-char prefixes (`+++`, `---`, `@@`)
/// must be tested before the 1-char ones (`+`, `-`) — otherwise the
/// file headers would land in green/red instead of bold-no-tint.
final class DiffViewerTests: XCTestCase {

    func test_addedLine_isGreen() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("+new content\n")
        XCTAssertEqual(color, .systemGreen)
        XCTAssertFalse(isBold)
    }

    func test_removedLine_isRed() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("-old content\n")
        XCTAssertEqual(color, .systemRed)
        XCTAssertFalse(isBold)
    }

    func test_hunkHeader_isBlue() {
        // The `@@` lines mark a position change in the diff.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("@@ -1,3 +1,4 @@\n")
        XCTAssertEqual(color, .systemBlue)
        XCTAssertFalse(isBold)
    }

    func test_pliusFileHeader_isBoldNotGreen() {
        // `+++ filename` is the destination-file header, not an added
        // line. Must NOT pick up the green that `+` lines get — would
        // be visually confusing.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("+++ b/foo.txt\n")
        XCTAssertNil(color, "file headers should render in default labelColor")
        XCTAssertTrue(isBold)
    }

    func test_minusFileHeader_isBoldNotRed() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("--- a/foo.txt\n")
        XCTAssertNil(color)
        XCTAssertTrue(isBold)
    }

    func test_contextLine_isDefault() {
        // Lines with a leading space are unchanged context. Default
        // styling — no color tint, no bold.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle(" unchanged line\n")
        XCTAssertNil(color)
        XCTAssertFalse(isBold)
    }

    func test_emptyLine_isDefault() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("\n")
        XCTAssertNil(color)
        XCTAssertFalse(isBold)
    }

    func test_arbitraryText_isDefault() {
        // Defensive — if the diff command emits something we don't
        // recognize (e.g. an error message Unison didn't intercept),
        // render it plainly rather than mistaking a leading char.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("Files differ\n")
        XCTAssertNil(color)
        XCTAssertFalse(isBold)
    }
}
