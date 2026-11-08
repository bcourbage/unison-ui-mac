import XCTest
@testable import unison_ui_mac

/// Issue #195: the profile picker had no minimum size, so a narrow frame the
/// user dragged to was saved and restored on the next launch, truncating
/// profile names and clipping Quit and Run.
@MainActor
final class ProfileWindowMinimumSizeTests: XCTestCase {

    private let defaultsKey = "NSWindow Frame ProfileWindow"

    private func makeDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "picker-min-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "root = /a\nroot = /b\n".write(toFile: dir + "/Sync.prf", atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// The autosaved frame is real app state, so a test that writes one puts
    /// back whatever was there.
    private func stashSavedFrame() {
        let saved = UserDefaults.standard.object(forKey: defaultsKey)
        addTeardownBlock {
            if let saved {
                UserDefaults.standard.set(saved, forKey: self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: self.defaultsKey)
            }
        }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ v: NSView) {
            if let b = v as? NSButton, ["Quit", "Run"].contains(b.title) { found.append(b) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    func test_savedNarrowFrame_isRaisedToTheMinimumOnRestore() throws {
        stashSavedFrame()
        // The format NSWindow writes: x y w h, then the screen's x y w h.
        UserDefaults.standard.set("200 200 110 150 0 0 1920 1080", forKey: defaultsKey)

        let picker = ProfileWindowController(unisonDirectory: try makeDirectory()) { _ in }
        let window = try XCTUnwrap(picker.window)
        let content = window.contentRect(forFrameRect: window.frame).size

        let minimum = ProfileWindowController.minimumContentSize
        XCTAssertGreaterThanOrEqual(content.width, minimum.width)
        XCTAssertGreaterThanOrEqual(content.height, minimum.height)
        XCTAssertEqual(window.contentMinSize, minimum)
    }

    /// AppKit applies the minimum to the user's drag, not to programmatic
    /// `setContentSize`, so the contract to pin is the limit the drag consults,
    /// in both its content and frame forms, on a fresh launch with no saved frame.
    func test_freshWindow_dragLimitIsTheMinimum() throws {
        stashSavedFrame()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let picker = ProfileWindowController(unisonDirectory: try makeDirectory()) { _ in }
        let window = try XCTUnwrap(picker.window)
        let minimum = ProfileWindowController.minimumContentSize

        XCTAssertEqual(window.contentMinSize, minimum)
        XCTAssertGreaterThanOrEqual(window.minSize.width, minimum.width)
        XCTAssertGreaterThanOrEqual(window.minSize.height, minimum.height)
    }

    func test_atTheMinimum_quitAndRunAreFullyVisible() throws {
        stashSavedFrame()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let picker = ProfileWindowController(unisonDirectory: try makeDirectory()) { _ in }
        let window = try XCTUnwrap(picker.window)
        let contentView = try XCTUnwrap(window.contentView)

        window.setContentSize(ProfileWindowController.minimumContentSize)
        contentView.layoutSubtreeIfNeeded()

        let bar = buttons(in: contentView)
        XCTAssertEqual(Set(bar.map(\.title)), ["Quit", "Run"])
        for button in bar {
            let frame = contentView.convert(button.bounds, from: button)
            XCTAssertTrue(contentView.bounds.contains(frame),
                          "\(button.title) is clipped: \(frame) outside \(contentView.bounds)")
            XCTAssertGreaterThanOrEqual(button.frame.width, button.fittingSize.width,
                                        "\(button.title) is narrower than its title needs")
        }
    }
}
