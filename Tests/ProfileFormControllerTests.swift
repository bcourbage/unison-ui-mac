import XCTest
@testable import unison_ui_mac

/// Hosted-AppKit regressions for the controller write-path defects (review round 2):
///   B4  — a profile that couldn't be read must not be overwritten by a blank form;
///         Save is disabled AND the authoritative saveAction guard refuses.
///   SF6 — turning default-enabled logging OFF writes `log = false`; an unrelated
///         save keeps an explicit logfile; a Browse-chosen folder is saved.
@MainActor
final class ProfileFormControllerTests: XCTestCase {

    private func tempDir() throws -> String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("pfc-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private func prfPath(_ dir: String, _ name: String) -> String {
        (dir as NSString).appendingPathComponent(name + ".prf")
    }
    private func make(_ dir: String, _ name: String) -> ProfileFormWindowController {
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: name, onSaved: { _ in })
        c.suppressAlertsForTesting = true
        return c
    }

    // MARK: - B4

    func test_b4_nonUTF8Profile_disablesSave_andGuardRefusesOverwrite() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = prfPath(dir, "bad")
        // 0xFF is not valid UTF-8; keep a trailing newline so it's a plausible file.
        let rawBytes = Data([0xFF, 0x0A])
        try rawBytes.write(to: URL(fileURLWithPath: path))

        let c = make(dir, "bad")
        XCTAssertFalse(c.isSaveEnabledForTesting, "Save is disabled for an unreadable profile")
        XCTAssertNotNil(c.notEditableReasonForTesting)

        // Direct action dispatch must NOT bypass the guard: nothing is written.
        c.invokeSaveForTesting()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), rawBytes,
                       "the original bytes are unchanged — the guard refused the overwrite")
        XCTAssertNotNil(c.lastAlertForTesting, "the refusal was surfaced")
    }

    // MARK: - SF6

    func test_sf6_absentLog_turnedOff_writesLogFalse() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = prfPath(dir, "p")
        try "root = /tmp/a\nroot = /tmp/b\n".write(toFile: path, atomically: true, encoding: .utf8)

        let c = make(dir, "p")
        c.setLogCheckboxForTesting(on: false)   // user explicitly turns logging off
        c.invokeSaveForTesting()

        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("log = false"),
                      "an explicit OFF must record log = false (absent would still default ON)")
    }

    func test_sf6_unrelatedSave_preservesExplicitLogfile() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = prfPath(dir, "p")
        try "root = /tmp/a\nroot = /tmp/b\nlogfile = /custom/unison.log\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        let c = make(dir, "p")            // do NOT touch logging controls
        c.invokeSaveForTesting()

        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("logfile = /custom/unison.log"),
                      "an unrelated save keeps the custom logfile")
        XCTAssertFalse(saved.contains("log = false"), "log was not touched")
    }

    func test_sf6_browseChosenFolder_isSaved() throws {
        let oldMode = SettingsModel.loggingMode()
        SettingsModel.setLoggingMode(.perProfile)
        defer { SettingsModel.setLoggingMode(oldMode) }

        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = prfPath(dir, "p")
        try "root = /tmp/a\nroot = /tmp/b\n".write(toFile: path, atomically: true, encoding: .utf8)

        let c = make(dir, "p")            // log defaults ON (absent log)
        c.applyChosenLogFolder("/chosen/logdir")   // the Browse completion path
        c.invokeSaveForTesting()

        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("logfile = /chosen/logdir/"),
                      "the Browse-chosen folder is written, not discarded:\n\(saved)")
    }
}
