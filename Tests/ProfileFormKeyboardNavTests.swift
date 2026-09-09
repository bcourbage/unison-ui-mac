import XCTest
import AppKit
@testable import unison_ui_mac

/// The Profile Editor's keyboard navigation: which sections are key-navigable,
/// that the control sections expose focusable controls, and the focus-order
/// arithmetic. The excluded sections are the large text editors where a literal
/// Tab is legal.
@MainActor
final class ProfileFormKeyboardNavTests: XCTestCase {
    nonisolated(unsafe) private var dir: String!
    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pfkn-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }
    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }

    func test_nextIndex_entersAndWraps() {
        XCTAssertEqual(KeyboardFocus.nextIndex(from: nil, count: 3, backward: false), 0, "forward from outside enters at the first")
        XCTAssertEqual(KeyboardFocus.nextIndex(from: nil, count: 3, backward: true), 2, "backward from outside enters at the last")
        XCTAssertEqual(KeyboardFocus.nextIndex(from: 2, count: 3, backward: false), 0, "forward wraps")
        XCTAssertEqual(KeyboardFocus.nextIndex(from: 0, count: 3, backward: true), 2, "backward wraps")
        XCTAssertNil(KeyboardFocus.nextIndex(from: nil, count: 0, backward: false))
    }

    func test_controlSectionsAreKeyNavigable_withFocusableControls_editorSectionsAreNot() throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\nservercmd = /opt/homebrew/bin/unison\ninclude common\n")
        try write("common.prf", "sshargs = -i /k\n")
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: "p", onSaved: { _ in })
        for section in ["General", "Roots", "File Attributes", "Options", "Includes"] {
            c.showSectionForTesting(title: section)
            XCTAssertTrue(c.keyNavActiveForTesting, "\(section) should be key-navigable")
            XCTAssertFalse(c.keyNavFocusablesForTesting.isEmpty, "\(section) exposes focusable controls")
        }
        for section in ["Paths", "Ignore", "Advanced"] {
            c.showSectionForTesting(title: section)
            XCTAssertFalse(c.keyNavActiveForTesting, "\(section) keeps Tab as a literal tab in its editor")
        }
        c.close()
    }

    func test_fileAttributesFocusables_reachTheTriStatePopups() throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\n")
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: "p", onSaved: { _ in })
        c.showSectionForTesting(title: "File Attributes")
        let popups = c.keyNavFocusablesForTesting.filter { $0 is NSPopUpButton }
        XCTAssertGreaterThanOrEqual(popups.count, 5, "the tri-state popups are reachable by keyboard: \(popups.count)")
        c.close()
    }
}
