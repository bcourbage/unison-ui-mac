import XCTest
import AppKit
@testable import unison_ui_mac

/// Targeted tests for the only pieces of `PathCellView` that are pure
/// logic rather than AppKit drawing:
///   - `configureAsFile` / `configureAsFolder` populate the text field
///     and image view from their arguments.
///   - The tooltip rule: a hover tooltip is set only when a fullPath is
///     provided AND differs from the displayed name; otherwise it's
///     cleared (so a recycled cell can't leak a stale tooltip from a
///     previous binding).
///
/// The remaining ~80% of `PathCellView` (constraints + symbol
/// configurations + colors) is verified visually; AppKit layout
/// constants aren't useful to assert against in unit tests.
///
/// `@MainActor` because every test touches NSView APIs (init, textField,
/// imageView, toolTip), which are main-actor-isolated under Swift 6
/// strict concurrency. Required for the older Xcode 16.x toolchain that
/// CI runs under; newer Xcode tolerates the implicit hop, but the
/// annotation is semantically accurate either way.
@MainActor
final class PathCellViewTests: XCTestCase {

    private func makeCell() -> PathCellView {
        PathCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    }

    // MARK: - configureAsFile

    func test_configureAsFile_setsNameAndDocumentIcon() {
        let cell = makeCell()
        cell.configureAsFile(name: "notes.txt")
        XCTAssertEqual(cell.textField?.stringValue, "notes.txt")
        XCTAssertNotNil(cell.imageView?.image)
    }

    func test_configureAsFolder_setsNameAndFolderIcon() {
        let cell = makeCell()
        cell.configureAsFolder(name: "Documents")
        XCTAssertEqual(cell.textField?.stringValue, "Documents")
        XCTAssertNotNil(cell.imageView?.image)
    }

    // MARK: - Tooltip rule

    func test_tooltip_unsetWhenFullPathIsNil() {
        let cell = makeCell()
        cell.configureAsFile(name: "photo.jpg", fullPath: nil)
        XCTAssertNil(cell.toolTip)
    }

    func test_tooltip_unsetWhenFullPathEqualsDisplayedName() {
        let cell = makeCell()
        cell.configureAsFile(name: "README.md", fullPath: "README.md")
        XCTAssertNil(cell.toolTip)
    }

    func test_tooltip_setWhenFullPathDiffersFromDisplayedName() {
        let cell = makeCell()
        cell.configureAsFile(name: "deeply-truncated…name.swift",
                             fullPath: "src/views/very/deeply/nested/full-name.swift")
        XCTAssertEqual(cell.toolTip, "src/views/very/deeply/nested/full-name.swift")
    }

    func test_tooltip_clearedOnReconfigureWithoutFullPath() {
        // Recycled cell scenario: a previous binding set a tooltip,
        // the next binding has no fullPath. Ensure the stale tooltip
        // doesn't survive the rebinding.
        let cell = makeCell()
        cell.configureAsFile(name: "a.txt", fullPath: "deep/a.txt")
        XCTAssertEqual(cell.toolTip, "deep/a.txt")

        cell.configureAsFile(name: "b.txt", fullPath: nil)
        XCTAssertNil(cell.toolTip)
    }

    func test_tooltip_appliesToFolderConfigToo() {
        let cell = makeCell()
        cell.configureAsFolder(name: "Pictures",
                               fullPath: "Library/Application Support/Pictures")
        XCTAssertEqual(cell.toolTip, "Library/Application Support/Pictures")
    }
}
