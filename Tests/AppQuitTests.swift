import XCTest
import AppKit
@testable import unison_ui_mac

@MainActor
final class AppQuitTests: XCTestCase {

    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false   // ARC owns it; close() must not also release it
        return w
    }

    func test_dismissSheets_withNoSheet_endsNothing() {
        let w = window()
        w.orderFront(nil)
        defer { w.close() }
        XCTAssertEqual(AppQuit.dismissSheets(), 0)
    }

    func test_dismissSheets_endsAnOpenSheet_andReportsItsCancel() {
        let parent = window()
        parent.orderFront(nil)
        defer { parent.close() }
        let sheet = window()
        var returnCode: NSApplication.ModalResponse?
        parent.beginSheet(sheet) { returnCode = $0 }
        XCTAssertNotNil(parent.attachedSheet)

        XCTAssertEqual(AppQuit.dismissSheets(), 1)

        XCTAssertNil(parent.attachedSheet)
        XCTAssertEqual(returnCode, .cancel, "a dismissed sheet reads as a cancel, which every decision sheet maps to keep")
    }

    func test_quitMenuItem_routesThroughTheSheetAwareQuit() {
        let target = NSObject()
        let menu = MainMenu.build(pickerTarget: target, updaterTarget: NSObject())
        let quit = menu.items.first?.submenu?.items.first { $0.keyEquivalent == "q" }
        XCTAssertEqual(quit?.action, #selector(AppDelegate.quitApplication(_:)))
        XCTAssertTrue(quit?.target === target, "Quit must target the delegate, not the responder chain")
    }
}
