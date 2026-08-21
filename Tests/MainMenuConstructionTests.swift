import XCTest
import AppKit
@testable import unison_ui_mac

/// Issue #38 (Medium hardening): the Action ▸ Show Profile Picker item must be
/// constructed with the EXPLICIT AppDelegate target + the compile-time selector.
/// This locks the invariant so a future refactor can't silently drop the target
/// (which — with the controller-owned selector removed — would break the command
/// rather than restore the old race).
@MainActor
final class MainMenuConstructionTests: XCTestCase {

    private func showProfilePickerItem(target: AnyObject) -> NSMenuItem? {
        let main = MainMenu.build(pickerTarget: target, updaterTarget: NSObject())
        guard let action = main.items.first(where: { $0.submenu?.title == "Action" })?.submenu
        else { return nil }
        return action.items.first { $0.title == "Show Profile Picker" }
    }

    func test_showProfilePicker_hasExplicitTarget_andCompileTimeSelector() {
        let target = NSObject()
        guard let item = showProfilePickerItem(target: target) else {
            return XCTFail("Show Profile Picker item not found in the Action menu")
        }
        // Explicit target identity — NOT nil (responder-chain), NOT some other object.
        XCTAssertTrue(item.target === target,
                      "Show Profile Picker must target the passed pickerTarget")
        // The compile-time selector on AppDelegate.
        XCTAssertEqual(item.action, #selector(AppDelegate.showProfilePickerAppAction(_:)))
        XCTAssertEqual(item.keyEquivalent, "p")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func test_otherActionItems_keepResponderChainDispatch() {
        // The narrow fix touches only Show Profile Picker; Go/Stop/Rescan remain
        // responder-chain items (target nil).
        let target = NSObject()
        let main = MainMenu.build(pickerTarget: target, updaterTarget: NSObject())
        let action = main.items.first { $0.submenu?.title == "Action" }?.submenu
        for title in ["Go", "Stop", "Rescan"] {
            let item = action?.items.first { $0.title == title }
            XCTAssertNotNil(item, "\(title) item missing")
            XCTAssertNil(item?.target, "\(title) must keep responder-chain dispatch (nil target)")
        }
    }

    func test_checkForUpdates_targetsUpdaterController_withSparkleSelector() {
        // The App-menu "Check for Updates…" item must carry the EXPLICIT Sparkle
        // updater controller as its target (its own checkForUpdates:/
        // validateMenuItem: drive the command) — not nil, not the picker target.
        let picker = NSObject()
        let updater = NSObject()
        let main = MainMenu.build(pickerTarget: picker, updaterTarget: updater)
        // Find by title across submenus rather than hard-coding the app-name-
        // titled App menu.
        let item = main.items
            .compactMap { $0.submenu }
            .flatMap { $0.items }
            .first { $0.title == "Check for Updates…" }
        guard let item else {
            return XCTFail("Check for Updates… item not found")
        }
        XCTAssertTrue(item.target === updater,
                      "Check for Updates… must target the passed updaterTarget")
        // Sparkle's action selector, compared by name so the test target needn't
        // import Sparkle.
        XCTAssertEqual(item.action, Selector(("checkForUpdates:")))
    }
}
