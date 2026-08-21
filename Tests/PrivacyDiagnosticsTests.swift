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

    private func repoRoot() -> URL {
        // <repo>/Tests/PrivacyDiagnosticsTests.swift → repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every `.swift` file under `Sources/` (recursively), as (relativePath, contents).
    private func allAppSources() throws -> [(path: String, text: String)] {
        let root = repoRoot()
        let sources = root.appendingPathComponent("Sources")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sources,
                                     includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else {
            // A missing/unreadable Sources tree is itself a failure for this
            // guard — never silently pass by scanning nothing.
            XCTFail("could not enumerate \(sources.path)")
            return []
        }
        var out: [(String, String)] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            out.append((rel, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(out.isEmpty, "expected to scan at least one Swift source")
        return out
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
        // Positive check: the concrete version-check sites keep user-controlled
        // values private.
        for priv in [#"\(profile, privacy: .private)"#,
                     #"\(reason, privacy: .private)"#,
                     #"\(host, privacy: .private)"#] {
            XCTAssertTrue(src.contains(priv), "expected \(priv) in AppDelegate logging")
        }
    }

    /// Broadened regression tripwire (correction to the earlier three-spelling,
    /// single-file scan): across ALL Swift sources, no interpolation of a
    /// KNOWN user-controlled / sensitive identifier may be logged
    /// `privacy: .public`.
    ///
    /// SCOPE — read honestly: this is a name-based tripwire over a curated
    /// denylist of identifier spellings, not an exhaustive proof of the logging
    /// posture. os_log privacy cannot be verified statically for arbitrary
    /// expressions (a sensitive value assigned to an off-list local, or
    /// interpolated through a helper, would not be caught). It exists to catch
    /// the common regression — someone marking a path/host/error/etc `.public`
    /// — not to certify every call site. The genuinely-public sites today are
    /// Unison version strings only (`v`, `local`, `remote`), which are
    /// deliberately off this list.
    func test_noKnownUserControlledValueLoggedPublicly_anySource() throws {
        // Curated: values that are user-controlled or otherwise sensitive and
        // must never be public. Intentionally excludes operational metadata
        // (counts, enum/state labels, version numbers).
        let sensitiveIdentifiers = [
            "profile", "profileName", "reason", "host", "hostname", "server",
            "path", "paths", "root", "roots", "dir", "directory",
            "file", "filename", "url", "name", "displayName",
            "user", "username", "account", "password", "secret", "token",
            "cred", "credential", "key",
            "error", "err", "message", "msg", "reasonText", "detail", "details",
            "output", "stdout", "stderr", "command", "cmd", "arg", "args",
            "line", "content", "text", "marker",
        ]
        for (path, text) in try allAppSources() {
            for ident in sensitiveIdentifiers {
                let leak = "\\(\(ident), privacy: .public)"
                XCTAssertFalse(text.contains(leak),
                               "\(path): sensitive value logged publicly: \(leak)")
            }
        }
    }
}
