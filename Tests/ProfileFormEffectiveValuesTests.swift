import XCTest
@testable import unison_ui_mac

/// Hosted-AppKit tests for the Profile Form's effective-value semantics:
/// surfaced scalars show what Unison will use (includes spliced in), Save
/// writes only what changed and places overrides so they win, clearing an
/// inherited value writes the per-key default override, the duplicate-scalar
/// refusal is lifted, the conflict control neutralizes an effective force,
/// and a remote-scalar save in a shared file is disclosed first.
@MainActor
final class ProfileFormEffectiveValuesTests: XCTestCase {
    // setUp/tearDown overrides are nonisolated; the directory is set once there
    // and read from main-actor tests, so it is declared unsafe-nonisolated.
    nonisolated(unsafe) private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pfev-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }

    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }
    private func read(_ name: String) throws -> String { try String(contentsOfFile: "\(dir!)/\(name)", encoding: .utf8) }
    private func make(_ name: String) -> ProfileFormWindowController {
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: name, onSaved: { _ in })
        c.suppressAlertsForTesting = true
        c.disclosureDecisionForTesting = true
        return c
    }

    // MARK: - Display

    func test_inheritedValue_isShown_withProvenanceNote() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "servercmd = /opt/homebrew/bin/unison\nsshargs = -i /k\n")
        let c = make("p")
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison")
        XCTAssertEqual(c.scalarNoteForTesting("servercmd"), "From common.prf, line 1")
        XCTAssertEqual(c.scalarNoteForTesting("sshargs"), "From common.prf, line 2")
        XCTAssertNil(c.scalarNoteForTesting("sshcmd"), "default: no note")
        XCTAssertTrue(c.isSaveEnabledForTesting)
    }

    func test_localValue_hasNoNote() throws {
        try write("p.prf", "root = /a\nroot = /b\nservercmd = /top\n")
        let c = make("p")
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/top")
        XCTAssertNil(c.scalarNoteForTesting("servercmd"))
    }

    // MARK: - Unchanged saves

    func test_unrelatedSave_leavesInheritedValueUnmaterialized_fileByteIdentical() throws {
        let original = "root = /a\nroot = ssh://h//b\ninclude common\nignore = Name x\n"
        try write("p.prf", original)
        try write("common.prf", "servercmd = /inc\nlog = false\nforce = /a\n")
        let c = make("p")
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        XCTAssertEqual(try read("p.prf"), original)
        XCTAssertEqual(try read("common.prf"), "servercmd = /inc\nlog = false\nforce = /a\n", "includes are never edited")
    }

    // MARK: - Explicit change of an inherited value

    func test_changedInheritedValue_isAppendedAfterInclude_withComment_andReloadsAsLocal() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "servercmd = /inc\n")
        let c = make("p")
        c.setRemoteFieldForTesting("servercmd", "/opt/homebrew/bin/unison")
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        XCTAssertEqual(try read("p.prf"),
            "root = /a\nroot = ssh://h//b\ninclude common\n# Overrides common.prf: set here so this value takes effect\nservercmd = /opt/homebrew/bin/unison\n")
        let again = make("p")
        XCTAssertEqual(again.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison")
        XCTAssertNil(again.scalarNoteForTesting("servercmd"), "now Local")
    }

    func test_topLevelLineBeforeInclude_isMovedToEnd_onChange() throws {
        try write("p.prf", "servercmd = /top\nroot = /a\nroot = /b\ninclude common\n")
        try write("common.prf", "servercmd = /inc\n")
        let c = make("p")
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/inc", "the include wins as loaded")
        c.setRemoteFieldForTesting("servercmd", "/new")
        c.invokeSaveForTesting()
        XCTAssertEqual(try read("p.prf"),
            "root = /a\nroot = /b\ninclude common\n# Overrides common.prf: set here so this value takes effect\nservercmd = /new\n")
    }

    // MARK: - Clearing an inherited value

    func test_clearInheritedSshcmd_writesExplicitDefault() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "sshcmd = /opt/ssh\n")
        let c = make("p")
        c.setRemoteFieldForTesting("sshcmd", "")
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        XCTAssertTrue(try read("p.prf").hasSuffix("# Overrides common.prf: set here so this value takes effect\nsshcmd = ssh\n"))
    }

    func test_clearInheritedClientHostName_isRefused_fileUnchanged() throws {
        let original = "root = /a\nroot = ssh://h//b\ninclude common\n"
        try write("p.prf", original)
        try write("common.prf", "clientHostName = box\n")
        let c = make("p")
        c.setRemoteFieldForTesting("clientHostName", "")
        c.invokeSaveForTesting()
        XCTAssertEqual(c.lastAlertForTesting?.text, "This setting can’t be changed here")
        XCTAssertTrue(c.lastAlertForTesting?.info.contains("Remove it from common.prf") ?? false)
        XCTAssertEqual(try read("p.prf"), original)
    }

    func test_clearLocalValue_removesTheLine() throws {
        try write("p.prf", "root = /a\nroot = /b\nsshcmd = /usr/bin/ssh\n")
        let c = make("p")
        c.setRemoteFieldForTesting("sshcmd", "")
        c.invokeSaveForTesting()
        XCTAssertEqual(try read("p.prf"), "root = /a\nroot = /b\n")
    }

    // MARK: - Duplicates (SF5 lifted)

    func test_duplicateScalar_isEditable_showsEffective_unchangedSaveByteIdentical() throws {
        // Roots stay contiguous: the form has always rewritten the root list at
        // the first root's position, which is outside this feature.
        let original = "root = /a\nroot = /b\nservercmd = /one\nignore = Name x\nservercmd = /two\n"
        try write("p.prf", original)
        let c = make("p")
        XCTAssertTrue(c.isSaveEnabledForTesting)
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/two")
        XCTAssertEqual(c.duplicatesBannerForTesting, "This file sets servercmd more than once; saving a change keeps the last value and removes the others.")
        c.invokeSaveForTesting()
        XCTAssertEqual(try read("p.prf"), original)
    }

    func test_duplicateScalar_changed_keepsLastPosition_removesEarlier() throws {
        try write("p.prf", "root = /a\nroot = /b\nservercmd = /one\nignore = Name x\nservercmd = /two\n")
        let c = make("p")
        c.setRemoteFieldForTesting("servercmd", "/three")
        c.invokeSaveForTesting()
        XCTAssertEqual(try read("p.prf"), "root = /a\nroot = /b\nignore = Name x\nservercmd = /three\n")
    }

    // MARK: - Conflict control

    func test_preferOverInheritedForce_neutralizesForce() throws {
        try write("p.prf", "root = /a\nroot = /b\ninclude common\n")
        try write("common.prf", "force = /a\n")
        let c = make("p")
        XCTAssertEqual(c.scalarNoteForTesting("conflict"), "From common.prf, line 1 (force)")
        let idx = try XCTUnwrap(c.conflictChoiceIndexForTesting(key: "prefer", target: "second"))
        c.setConflictSelectionForTesting(idx)
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        let saved = try read("p.prf")
        XCTAssertTrue(saved.contains("prefer = /b\n"), saved)
        XCTAssertTrue(saved.contains("force = \n"), saved)
        guard case .success(let e) = EffectiveProfile.load(profile: "p", unisonDirectory: dir) else { return XCTFail() }
        XCTAssertEqual(e.scalar("force")?.value, "")
        XCTAssertEqual(e.scalar("prefer")?.value, "/b")
    }

    // MARK: - Shared-profile disclosure

    func test_remoteScalarChange_inSharedFile_isDisclosed_andCancelLeavesFile() throws {
        let original = "root = /a\nroot = ssh://h//b\n"
        try write("p.prf", original)
        try write("other.prf", "root = /o\nroot = ssh://bob@otherhost//x\ninclude p\n")
        let c = make("p")
        c.disclosureDecisionForTesting = false
        c.setRemoteFieldForTesting("servercmd", "/x")
        c.invokeSaveForTesting()
        XCTAssertEqual(c.lastDisclosureForTesting, "These profiles include this file and may be affected: other (otherhost).")
        XCTAssertEqual(try read("p.prf"), original, "Cancel leaves the file untouched")
        c.disclosureDecisionForTesting = true
        c.invokeSaveForTesting()
        XCTAssertTrue(try read("p.prf").contains("servercmd = /x\n"))
    }

    func test_nonRemoteChange_inSharedFile_isNotDisclosed() throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        try write("other.prf", "root = /o\nroot = /q\ninclude p\n")
        let c = make("p")
        c.disclosureDecisionForTesting = false
        c.setTriStateForTesting("times", .on)
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastDisclosureForTesting)
        XCTAssertTrue(try read("p.prf").contains("times = true\n"))
    }

    // MARK: - Step 1 failure

    func test_unisonFatalError_disablesEditing_withUnisonsMessage() throws {
        try write("p.prf", "root = /a\nroot = /b\nservercommand = /x\n")
        let c = make("p")
        XCTAssertFalse(c.isSaveEnabledForTesting)
        XCTAssertTrue(c.notEditableReasonForTesting?.contains("`servercommand' is not a valid option") ?? false)
    }
}
