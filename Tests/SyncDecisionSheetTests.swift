import XCTest
import AppKit
@testable import unison_ui_mac

/// Pure coverage for the shared sync-decision content and choice mapping used by
/// BOTH the ordinary window-close path and the incoming command-line request path.
final class SyncDecisionSheetTests: XCTestCase {
    private typealias Sheet = SyncDecisionSheet

    // MARK: window-close context

    func test_windowClose_wording_and_buttons() {
        let c = Sheet.content(for: .windowClose(profile: "home"))
        XCTAssertEqual(c.title, "Close the window while syncing?")
        XCTAssertTrue(c.body.contains("“home” is still synchronizing"), c.body)
        XCTAssertTrue(c.body.contains("can leave the sync running in the background"), c.body)
        XCTAssertTrue(c.body.contains(Sheet.stopCaveat), "shares the Stop caveat")
        XCTAssertEqual(c.buttons.map(\.title),
                       ["Keep Window Open", "Continue in Background", "Stop Syncing & Close"])
        XCTAssertEqual(c.buttons.map(\.choice), [.keep, .background, .stop])
        XCTAssertTrue(c.buttons[0].isDefault)
        XCTAssertFalse(c.buttons[1].isDefault)
        XCTAssertFalse(c.buttons[2].isDefault)
        XCTAssertTrue(c.buttons[2].isDestructive, "Stop is destructive")
        XCTAssertFalse(c.buttons[0].isDestructive)
        XCTAssertEqual(c.dismissChoice, .keep, "dismissal preserves the window")
    }

    // MARK: command-line request context

    func test_commandLineRequest_wording_and_buttons() {
        let c = Sheet.content(for: .commandLineRequest(current: "home", requested: "work"))
        XCTAssertEqual(c.title, "Open “work” while “home” is syncing?")
        XCTAssertTrue(c.body.contains("finish the current sync before opening “work”"), c.body)
        XCTAssertTrue(c.body.contains("stop it and open “work” after cleanup"), c.body)
        XCTAssertTrue(c.body.contains(Sheet.stopCaveat), "shares the Stop caveat")
        XCTAssertEqual(c.buttons.map(\.choice), [.keep, .background, .stop],
                       "same choice order as the window-close context")
        XCTAssertTrue(c.buttons[0].title.hasPrefix("Keep Syncing"))
        XCTAssertTrue(c.buttons[1].title.contains("Finish Sync"))
        XCTAssertTrue(c.buttons[2].title.contains("Stop Sync"))
        XCTAssertTrue(c.buttons[2].isDestructive)
        XCTAssertTrue(c.buttons[0].isDefault)
        XCTAssertEqual(c.dismissChoice, .keep, "dismissal refuses the request")
    }

    /// Long profile names must not blow out the buttons: the consequence stays in
    /// the button, the (long) names live only in the title/body. Guards the layout
    /// decision (commandLineButtonsNameProfile == false).
    func test_commandLineRequest_longNames_keepButtonsShort() {
        let long = String(repeating: "verylongprofilename-", count: 4) + "end"
        let c = Sheet.content(for: .commandLineRequest(current: long, requested: long))
        XCTAssertTrue(c.title.contains(long), "the title carries the full names")
        for b in c.buttons {
            XCTAssertFalse(b.title.contains(long),
                           "button titles must not embed a long profile name: \(b.title)")
            // …but they must still state the consequence.
        }
        XCTAssertTrue(c.buttons[1].title.contains("Open"))
        XCTAssertTrue(c.buttons[2].title.contains("Stop"))
    }

    // MARK: choice mapping (shared by both call sites)

    func test_choiceMapping_buttonsAndDismissal() {
        let c = Sheet.content(for: .windowClose(profile: "p"))
        XCTAssertEqual(Sheet.choice(for: .alertFirstButtonReturn,  content: c), .keep)
        XCTAssertEqual(Sheet.choice(for: .alertSecondButtonReturn, content: c), .background)
        XCTAssertEqual(Sheet.choice(for: .alertThirdButtonReturn,  content: c), .stop)
        // Any non-button response (a programmatic endSheet dismissal) -> keep.
        XCTAssertEqual(Sheet.choice(for: .cancel, content: c), .keep)
        XCTAssertEqual(Sheet.choice(for: .abort,  content: c), .keep)
    }

    /// "Stop" is the consistent verb in every user-facing string here (no "Abort").
    func test_stopVerbConsistency_noAbortInCopy() {
        for context: SyncDecisionContext in [
            .windowClose(profile: "home"),
            .commandLineRequest(current: "home", requested: "work"),
        ] {
            let c = Sheet.content(for: context)
            let all = ([c.title, c.body] + c.buttons.map(\.title)).joined(separator: " ")
            XCTAssertFalse(all.lowercased().contains("abort"), "no 'Abort' in: \(all)")
            XCTAssertTrue(all.contains("Stop"), "uses 'Stop': \(all)")
        }
    }
}
