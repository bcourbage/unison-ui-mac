import XCTest
import AppKit
@testable import unison_ui_mac

/// Regression guard for the recurring "NSTextView inside an NSScrollView"
/// trap. The visible symptom (blank text / un-scrollable long content)
/// only reproduces in older-SDK / Release builds, which the Debug test
/// runner never exercises — but the *cause* is the set of geometry
/// properties `ScrollableTextView` applies, and those are identical in
/// Debug and Release. So asserting on the configuration is a faithful
/// proxy: if someone weakens the factory (drops `isVerticallyResizable`,
/// flips `widthTracksTextView`, zeroes `maxSize`…), these tests fail in
/// Debug even though the rendering bug would only have surfaced in
/// Release. All four scrollable text views in the app route through this
/// helper, so this one file covers them transitively.
@MainActor
final class ScrollableTextViewTests: XCTestCase {

    // MARK: - Properties common to both modes

    func test_configure_setsNonZeroFrame() {
        let (_, text) = ScrollableTextView.make(
            mode: .wrap, initialSize: NSSize(width: 300, height: 120))
        // A zero/implicit frame is the original footgun — nothing draws.
        XCTAssertEqual(text.frame.size, NSSize(width: 300, height: 120))
    }

    func test_configure_isVerticallyResizable_bothModes() {
        // The single most important property: without it the view can't
        // grow to fit content and the scroll view won't scroll.
        for mode in [ScrollableTextView.Mode.wrap, .noWrap] {
            let (_, text) = ScrollableTextView.make(
                mode: mode, initialSize: NSSize(width: 200, height: 100))
            XCTAssertTrue(text.isVerticallyResizable, "mode \(mode)")
        }
    }

    func test_configure_maxSizeUnbounded_bothModes() {
        for mode in [ScrollableTextView.Mode.wrap, .noWrap] {
            let (_, text) = ScrollableTextView.make(
                mode: mode, initialSize: NSSize(width: 200, height: 100))
            XCTAssertEqual(text.maxSize.width, CGFloat.greatestFiniteMagnitude, "mode \(mode)")
            XCTAssertEqual(text.maxSize.height, CGFloat.greatestFiniteMagnitude, "mode \(mode)")
        }
    }

    func test_configure_wiresDocumentViewAndVerticalScroller() {
        for mode in [ScrollableTextView.Mode.wrap, .noWrap] {
            let (scroll, text) = ScrollableTextView.make(
                mode: mode, initialSize: NSSize(width: 200, height: 100))
            XCTAssertTrue(scroll.documentView === text, "mode \(mode)")
            XCTAssertTrue(scroll.hasVerticalScroller, "mode \(mode)")
        }
    }

    // MARK: - Wrap mode (vertical scroll, fixed width)

    func test_wrapMode_widthTracksAndNoHorizontalScroll() {
        let (scroll, text) = ScrollableTextView.make(
            mode: .wrap, initialSize: NSSize(width: 400, height: 80))
        XCTAssertFalse(text.isHorizontallyResizable)
        XCTAssertEqual(text.autoresizingMask, [.width])
        XCTAssertTrue(text.textContainer?.widthTracksTextView ?? false)
        // Container width is bounded to the initial width (so text wraps),
        // height unbounded (so it grows + scrolls).
        XCTAssertEqual(text.textContainer?.containerSize.width, 400)
        XCTAssertEqual(text.textContainer?.containerSize.height, CGFloat.greatestFiniteMagnitude)
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }

    // MARK: - No-wrap mode (both scrollers, content-driven width)

    func test_noWrapMode_horizontalResizeAndScroller() {
        let (scroll, text) = ScrollableTextView.make(
            mode: .noWrap, initialSize: NSSize(width: 700, height: 500))
        XCTAssertTrue(text.isHorizontallyResizable)
        XCTAssertEqual(text.autoresizingMask, [.width, .height])
        XCTAssertFalse(text.textContainer?.widthTracksTextView ?? true)
        // Container unbounded in BOTH dimensions so long lines don't wrap.
        XCTAssertEqual(text.textContainer?.containerSize.width, CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(text.textContainer?.containerSize.height, CGFloat.greatestFiniteMagnitude)
        XCTAssertTrue(scroll.hasHorizontalScroller)
    }

    // MARK: - configure() on caller-owned instances

    func test_configure_appliesToExistingInstances() {
        // The stored-property call sites pass their own instances rather
        // than using make(); make sure that path is wired identically.
        // (Frame size isn't asserted here: an unsized scroll view resizes
        // its document view on assignment via the .width autoresizing
        // mask — the resizing *properties*, checked above, are the real
        // invariant. Exact framing is covered by make() in
        // test_configure_setsNonZeroFrame.)
        let text = NSTextView()
        let scroll = NSScrollView()
        ScrollableTextView.configure(
            text: text, scroll: scroll, mode: .wrap,
            initialSize: NSSize(width: 250, height: 90))
        XCTAssertTrue(scroll.documentView === text)
        XCTAssertTrue(text.isVerticallyResizable)
        XCTAssertFalse(text.isHorizontallyResizable)
    }
}
