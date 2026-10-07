import XCTest
@testable import unison_ui_mac

/// Backticked examples in profile-editor help strings render as code (1.0
/// UI review P10); the markers never reach the screen.
final class HelpTextTests: XCTestCase {

    func test_segments_splitTextAndCode() {
        XCTAssertEqual(HelpText.segments("Examples: `Name *.tmp`, `Path build`."),
                       [.text("Examples: "), .code("Name *.tmp"), .text(", "), .code("Path build"), .text(".")])
    }

    func test_segments_noMarkers_isOneText() {
        XCTAssertEqual(HelpText.segments("plain help"), [.text("plain help")])
    }

    func test_segments_unmatchedMarker_isKeptAsText() {
        XCTAssertEqual(HelpText.segments("a `b"), [.text("a `b")])
    }

    func test_segments_codeAtStartAndEnd() {
        XCTAssertEqual(HelpText.segments("`key = value` pref"), [.code("key = value"), .text(" pref")])
        XCTAssertEqual(HelpText.segments("see `ignorenot`"), [.text("see "), .code("ignorenot")])
    }

    @MainActor
    func test_attributed_dropsMarkers_andUsesMonospaceForCode() {
        let font = NSFont.systemFont(ofSize: 11)
        let a = HelpText.attributed("Use `Path build` here.", font: font, color: .secondaryLabelColor)
        XCTAssertEqual(a.string, "Use Path build here.")
        let codeRange = (a.string as NSString).range(of: "Path build")
        let codeFont = a.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(codeFont?.isFixedPitch ?? false, "code spans are monospaced")
        let textFont = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(textFont, font)
    }
}
