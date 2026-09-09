import XCTest
import AppKit
@testable import unison_ui_mac

/// The two entry points into Check Remote Command outside the editor form:
/// the failed-connection offer in the reconcile window and the picker's
/// context menu, plus the Profile Editor's routing into the form.
@MainActor
final class RemoteCheckEntryPointsTests: XCTestCase {
    nonisolated(unsafe) private var dir: String!
    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rcep-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }
    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }

    private func reconcile(profile: String) -> ReconcileWindowController {
        ReconcileWindowController(
            profile: profile, mergeConfigured: false,
            onClose: {}, onRescanRequested: {},
            onSyncStart: {}, onSyncExit: { _ in }, onEngineUncertain: { _ in },
            onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused },
            onDiffAbandon: {})
    }

    // MARK: Reconcile window offer

    func test_restartRequired_shortHeadline_reasonAndOfferBehindDetails() {
        let w = reconcile(profile: "Sync-Demeter")
        XCTAssertFalse(w.remoteCheckOfferedForTesting)
        w.showRestartRequired(reason: "sync abort could not be requested (status 3)")
        XCTAssertEqual(w.summaryTextForTesting, "Unison must be restarted to continue.")
        XCTAssertEqual(w.statusDetailsTextForTesting, "sync abort could not be requested (status 3)\n\nQuit Unison and open the profile again.")
        XCTAssertFalse(w.remoteCheckOfferedForTesting, "no offer without the caller's decision")

        let reason = "Couldn’t connect to the remote (no progress for 60 seconds). The connection may be stuck."
        w.showRestartRequired(reason: reason, connectFailure: true, offerRemoteCheck: true)
        XCTAssertEqual(w.summaryTextForTesting, "Could not connect to the remote. Unison must be restarted to continue.")
        XCTAssertEqual(w.statusDetailsTextForTesting, reason + "\n\nQuit Unison and open the profile again.")
        XCTAssertTrue(w.remoteCheckOfferedForTesting)
        var requested: [String] = []
        w.onRemoteCheckRequested = { requested.append($0) }
        w.requestRemoteCheckForTesting()
        XCTAssertEqual(requested, ["Sync-Demeter"], "the offer opens the exact profile that failed")
    }

    // MARK: Picker context menu

    func test_pickerMenu_hasRunAndCheck_andActsOnTheClickedRow() throws {
        try write("alpha.prf", "root = /a\nroot = ssh://h//b\n")
        try write("beta.prf", "root = /a\nroot = /b\n")
        var ran: [String] = []
        let picker = ProfileWindowController(unisonDirectory: dir) { ran.append($0) }
        XCTAssertEqual(picker.contextMenuTitlesForTesting, ["Run", "Check Remote Command…"])
        var checked: [String] = []
        picker.onRemoteCheckRequested = { checked.append($0) }
        picker.performContextCommandForTesting(title: "Check Remote Command…", row: 1)
        picker.performContextCommandForTesting(title: "Run", row: 0)
        XCTAssertEqual(checked, ["beta"])
        XCTAssertEqual(ran, ["alpha"])
    }

    // MARK: Profile Editor routing into the form

    private func waitForCheckStatus(_ form: ProfileFormWindowController) async {
        for _ in 0..<100 {
            if let s = form.checkStatusForTesting, !s.isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_openFormForRemoteCheck_opensTheProfileAtRoots_andRunsStep1() async throws {
        try write("local.prf", "root = /a\nroot = /b\n")
        let editor = ProfileEditorWindowController(unisonDirectory: dir) {}
        editor.suppressAlertsForTesting = true
        editor.openFormForRemoteCheck(profile: "local")
        guard let form = editor.formControllerForTesting else { return XCTFail("no form opened") }
        XCTAssertEqual(form.editingProfileName, "local")
        XCTAssertEqual(form.shownSectionTitleForTesting, "Roots")
        await waitForCheckStatus(form)
        XCTAssertEqual(form.checkStatusForTesting, "Neither root is an ssh:// root; there is no remote command to check.")
        form.close()
    }

    func test_openFormForRemoteCheck_doesNotDiscardAnUnsavedNewProfile() async throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        let editor = ProfileEditorWindowController(unisonDirectory: dir) {}
        editor.suppressAlertsForTesting = true
        editor.openNewFormForTesting()
        guard let newForm = editor.formControllerForTesting else { return XCTFail("no new form") }
        XCTAssertNil(newForm.editingProfileName, "a new profile has no name yet")
        newForm.setRemoteFieldForTesting("sshargs", "-i /unsaved")
        editor.openFormForRemoteCheck(profile: "p")
        XCTAssertTrue(editor.formControllerForTesting === newForm, "the unsaved new profile is not replaced")
        XCTAssertEqual(newForm.remoteFieldForTesting("sshargs"), "-i /unsaved", "its edits survive")
        XCTAssertEqual(editor.lastEntryAlertForTesting, "Finish the new profile first")
        newForm.close()
    }

    func test_openFormForRemoteCheck_reusesAnEditorOnTheSameProfile_andBlocksOnAnother() async throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        try write("q.prf", "root = /a\nroot = /b\n")
        let editor = ProfileEditorWindowController(unisonDirectory: dir) {}
        editor.suppressAlertsForTesting = true
        editor.openFormForRemoteCheck(profile: "p")
        guard let first = editor.formControllerForTesting else { return XCTFail("no form opened") }
        first.setRemoteFieldForTesting("sshargs", "-i /unsaved")
        editor.openFormForRemoteCheck(profile: "p")
        XCTAssertTrue(editor.formControllerForTesting === first, "the open editor is reused")
        XCTAssertEqual(first.remoteFieldForTesting("sshargs"), "-i /unsaved", "its edits survive")
        editor.openFormForRemoteCheck(profile: "q")
        XCTAssertTrue(editor.formControllerForTesting === first, "an editor on another profile is not replaced")
        XCTAssertEqual(editor.lastEntryAlertForTesting, "Finish editing “p” first")
        first.close()
    }
}
