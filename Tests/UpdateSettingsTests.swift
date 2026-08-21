import XCTest
import AppKit
@testable import unison_ui_mac

/// Regression coverage for the Settings ▸ Updates tab and its Sparkle toggles.
/// The hosted test process injects no live updater, so without these the tab and
/// its wiring are never exercised by the suite. Driven through the public window
/// and view hierarchy (not private state) so a dropped target/action or a swapped
/// setter is actually caught: `performClick` fires the real action, and the fake
/// records which preference it moved.
@MainActor
final class UpdateSettingsTests: XCTestCase {

    /// Minimal `UpdatePreferences` double that records exactly which property
    /// each toggle writes.
    private final class FakeUpdatePreferences: UpdatePreferences {
        var automaticallyChecksForUpdates: Bool
        var sendsSystemProfile: Bool
        init(auto: Bool, profile: Bool) {
            automaticallyChecksForUpdates = auto
            sendsSystemProfile = profile
        }
    }

    private func makeController(_ prefs: (any UpdatePreferences)?)
        -> SettingsWindowController {
        SettingsWindowController(
            unisonDirectory: FileManager.default.temporaryDirectory.path,
            updatePreferences: prefs)
    }

    private func tabLabels(_ wc: SettingsWindowController) -> [String] {
        let tabVC = wc.window?.contentViewController as? NSTabViewController
        return tabVC?.tabViewItems.map { $0.label } ?? []
    }

    /// Recursively find the first NSButton whose title has `prefix`, inside the
    /// "Updates" tab's view.
    private func button(in wc: SettingsWindowController,
                        titlePrefix prefix: String) -> NSButton? {
        let tabVC = wc.window?.contentViewController as? NSTabViewController
        guard let root = tabVC?.tabViewItems
            .first(where: { $0.label == "Updates" })?.viewController?.view
        else { return nil }
        func search(_ v: NSView) -> NSButton? {
            for sub in v.subviews {
                if let b = sub as? NSButton, b.title.hasPrefix(prefix) { return b }
                if let hit = search(sub) { return hit }
            }
            return nil
        }
        return search(root)
    }

    func test_noUpdater_omitsUpdatesTab() {
        let wc = makeController(nil)
        XCTAssertFalse(tabLabels(wc).contains("Updates"),
                       "Updates tab must be absent when there is no updater")
    }

    func test_withUpdater_tabPresentAndInitialStatesReflected() {
        let fake = FakeUpdatePreferences(auto: true, profile: false)
        let wc = makeController(fake)
        XCTAssertTrue(tabLabels(wc).contains("Updates"),
                      "Updates tab must be present when an updater exists")
        XCTAssertEqual(button(in: wc, titlePrefix: "Automatically")?.state, .on,
                       "auto-check box must reflect the updater's initial value")
        XCTAssertEqual(button(in: wc, titlePrefix: "Include an anonymous")?.state, .off,
                       "system-profile box must reflect the updater's initial value")
    }

    func test_eachToggleChangesOnlyItsOwnPreference() {
        let fake = FakeUpdatePreferences(auto: false, profile: false)
        let wc = makeController(fake)

        guard let autoBox = button(in: wc, titlePrefix: "Automatically"),
              let profileBox = button(in: wc, titlePrefix: "Include an anonymous")
        else { return XCTFail("Updates checkboxes not found") }

        // Turn auto-check on: only that preference moves.
        autoBox.performClick(nil)
        XCTAssertTrue(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(fake.sendsSystemProfile)

        // Turn the system profile on: only that preference moves; auto-check holds.
        profileBox.performClick(nil)
        XCTAssertTrue(fake.sendsSystemProfile)
        XCTAssertTrue(fake.automaticallyChecksForUpdates)

        // Turn auto-check back off: still isolated.
        autoBox.performClick(nil)
        XCTAssertFalse(fake.automaticallyChecksForUpdates)
        XCTAssertTrue(fake.sendsSystemProfile)
    }
}
