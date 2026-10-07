import XCTest
@testable import unison_ui_mac

/// Engine warning, fatal and restart alerts (1.0 UI review P4, P5): short
/// bodies, the complete diagnostic in a scrolling details area with Copy
/// Details, stage-neutral buttons, nothing truncated.
@MainActor
final class EngineDialogsTests: XCTestCase {

    private let firstSyncWarning = """
        No archive files were found for these roots, whose canonical names are:
        \t/Users/someone/Documents
        \t/Volumes/Backup/Documents
        This can happen either because this is the first time you have synchronized these roots, or because you have upgraded Unison to a new version with a different archive format.

        Update detection may take a while on this run if the replicas are large.

        Unison will assume that the 'last synchronized state' of both replicas was completely empty.
        """

    private func textView(in alert: NSAlert) -> NSTextView? {
        func find(_ v: NSView?) -> NSTextView? {
            guard let v else { return nil }
            if let t = v as? NSTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return find(alert.accessoryView)
    }

    private func copyButton(in alert: NSAlert) -> CopyTextButton? {
        func find(_ v: NSView?) -> CopyTextButton? {
            guard let v else { return nil }
            if let b = v as? CopyTextButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return find(alert.accessoryView)
    }

    // MARK: - Warning (P5)

    func test_warning_summaryIsFirstLine_fullTextInDetails() {
        let a = EngineDialogs.warningAlert(text: firstSyncWarning)
        XCTAssertEqual(a.messageText, "Unison warning")
        XCTAssertEqual(a.informativeText,
                       "No archive files were found for these roots, whose canonical names are:")
        let tv = textView(in: a)
        XCTAssertNotNil(tv, "long warning text goes to the details area")
        XCTAssertEqual(tv?.string, firstSyncWarning)
        XCTAssertEqual(tv?.isEditable, false)
        XCTAssertEqual(tv?.isSelectable, true)
    }

    func test_warning_singleLine_hasNoDetailsArea() {
        let a = EngineDialogs.warningAlert(text: "Contacting server...")
        XCTAssertEqual(a.informativeText, "Contacting server...")
        XCTAssertNil(a.accessoryView)
    }

    func test_warning_buttonTitles_areStageNeutral() {
        XCTAssertEqual(EngineDialogs.continueButton, "Continue")
        XCTAssertEqual(EngineDialogs.cancelButton, "Cancel")
    }

    // MARK: - Fatal (P4)

    func test_fatal_keepsCompletePath() {
        let path = "/Users/someone/Library/Application Support/Unison/" + String(repeating: "x", count: 300)
        let msg = "Archives are locked.\nThe archive lock file is \(path)\nRemove it if no other Unison is running."
        let a = EngineDialogs.fatalAlert(text: msg)
        XCTAssertEqual(a.messageText, "Unison error")
        XCTAssertEqual(a.informativeText, "Archives are locked.")
        XCTAssertEqual(textView(in: a)?.string, msg)
        XCTAssertTrue(textView(in: a)?.string.contains(path) ?? false)
    }

    // MARK: - Restart notice (P4)

    func test_restart_bodyIsRecoveryStep_reasonInDetailsUntruncated() {
        let reason = "fatal error: " + String(repeating: "path-segment/", count: 60)
        XCTAssertGreaterThan(reason.count, 200, "longer than the old 200-character cut")
        let a = EngineDialogs.restartAlert(reason: reason, remoteCheckOffered: false)
        XCTAssertEqual(a.messageText, "Unison needs to be restarted")
        XCTAssertEqual(a.informativeText, "Quit Unison and open it again to continue.")
        XCTAssertFalse(a.informativeText.contains("path-segment"), "the body does not repeat the error")
        XCTAssertEqual(textView(in: a)?.string, reason)
    }

    func test_restart_emptyReason_noDetails() {
        let a = EngineDialogs.restartAlert(reason: "", remoteCheckOffered: false)
        XCTAssertNil(a.accessoryView)
        XCTAssertEqual(a.informativeText, "Quit Unison and open it again to continue.")
    }

    func test_restart_remoteCheckOffer_appended() {
        let a = EngineDialogs.restartAlert(reason: "x", remoteCheckOffered: true)
        XCTAssertEqual(a.informativeText,
            "Quit Unison and open it again to continue. You can check the remote command for this profile first.")
    }

    // MARK: - Copy Details

    func test_copyDetails_writesFullTextToPasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("EngineDialogsTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let view = EngineDialogs.detailsAccessory(text: firstSyncWarning, pasteboard: pb)
        func find(_ v: NSView) -> CopyTextButton? {
            if let b = v as? CopyTextButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        let button = find(view)
        XCTAssertEqual(button?.title, "Copy Details")
        button?.copyText(nil)
        XCTAssertEqual(pb.string(forType: .string), firstSyncWarning)
    }

    func test_alerts_carryCopyDetailsButton() {
        XCTAssertNotNil(copyButton(in: EngineDialogs.warningAlert(text: firstSyncWarning)))
        XCTAssertNotNil(copyButton(in: EngineDialogs.restartAlert(reason: "why", remoteCheckOffered: false)))
    }

    func test_summaryLine_skipsLeadingBlankLines() {
        XCTAssertEqual(EngineDialogs.summaryLine(of: "\n\n  first  \nsecond"), "first")
        XCTAssertEqual(EngineDialogs.summaryLine(of: "only"), "only")
    }
}
