import XCTest
@testable import unison_ui_mac

/// Finding #13 — privacy-safe diagnostics. The crash-report copy no longer
/// claims "no personal data" and instead names what a `.ips` can contain; and
/// dynamic, user-controlled values in logs are `.private` while only
/// operational metadata (version numbers) stays `.public`. os_log redaction
/// isn't observable at runtime, so the logging posture is guarded with a
/// source-level regression scan.
final class PrivacyDiagnosticsTests: XCTestCase {

    // MARK: - Crash-report copy (testable constants)

    func test_crashAlert_doesNotClaimNoPersonalData() {
        XCTAssertFalse(CrashReportCopy.alertInfo.lowercased().contains("no personal data"))
        XCTAssertFalse(CrashReportCopy.issueContext(reportName: "x.ips")
            .lowercased().contains("no personal data"))
    }

    func test_crashAlert_namesWhatItCanContain() {
        for text in [CrashReportCopy.alertInfo,
                     CrashReportCopy.issueContext(reportName: "unison-ui-mac-2026.ips")] {
            let lower = text.lowercased()
            XCTAssertTrue(lower.contains("account name"), text)
            XCTAssertTrue(lower.contains("file path"), text)
            XCTAssertTrue(lower.contains("process argument"), text)
        }
    }

    func test_crashAlert_keepsFinderReviewStep() {
        XCTAssertTrue(CrashReportCopy.alertInfo.contains("Finder"))
        XCTAssertTrue(CrashReportCopy.alertInfo.lowercased().contains("review"))
    }

    func test_crashIssueContext_includesReportName() {
        XCTAssertTrue(CrashReportCopy.issueContext(reportName: "unison-ui-mac-9.ips")
            .contains("unison-ui-mac-9.ips"))
    }

    func test_crashCopy_noEmDash() {
        // Bruno's convention: no em-dashes in user-facing copy.
        XCTAssertFalse(CrashReportCopy.alertInfo.contains("—"))
        XCTAssertFalse(CrashReportCopy.issueContext(reportName: "x").contains("—"))
    }

    // MARK: - Source-level regression scan of the logging privacy posture

    private func source(_ relativePath: String) throws -> String {
        // <repo>/Tests/PrivacyDiagnosticsTests.swift → repo root.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_traceLogWrite_isPrivateByDefault() throws {
        let src = try source("Sources/App/TraceLog.swift")
        XCTAssertTrue(src.contains(#"logger.info("\(message, privacy: .private)")"#),
                      "TraceLog.write must log its composed message as .private")
        XCTAssertFalse(src.contains(#"logger.info("\(message, privacy: .public)")"#),
                       "TraceLog.write must not log the composed message as .public")
    }

    func test_versionCheckLogging_userControlledValuesArePrivate() throws {
        let src = try source("Sources/App/AppDelegate.swift")
        // User-controlled values must be private.
        for priv in [#"\(profile, privacy: .private)"#,
                     #"\(reason, privacy: .private)"#,
                     #"\(host, privacy: .private)"#] {
            XCTAssertTrue(src.contains(priv), "expected \(priv) in AppDelegate logging")
        }
        // ...and must NOT be logged publicly anywhere.
        for leak in [#"\(profile, privacy: .public)"#,
                     #"\(reason, privacy: .public)"#,
                     #"\(host, privacy: .public)"#] {
            XCTAssertFalse(src.contains(leak), "user-controlled value logged publicly: \(leak)")
        }
    }
}
