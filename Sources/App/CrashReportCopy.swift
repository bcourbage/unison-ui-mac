import Foundation

/// User-facing copy for the post-crash report prompt (Finding #13).
///
/// The previous copy told the user twice that the macOS crash report contains
/// "no personal data." That is inaccurate: a `.ips` crash report is a technical
/// stack trace, but it can include the user's account name, filesystem paths,
/// process arguments, loaded paths, and system details. The copy now says so
/// plainly and directs the user to review the revealed report in Finder before
/// attaching it. Extracted here (out of the AppKit alert) so the wording is
/// unit-testable. No em-dashes in user-facing copy.
enum CrashReportCopy {
    /// Informative text for the "quit unexpectedly last time" alert.
    static let alertInfo =
        "Sending the crash report helps find and fix the problem. A macOS crash "
        + "report is a technical stack trace, but it can include your account "
        + "name, file paths, process arguments, and system details.\n\n"
        + "“Report…” opens a pre-filled GitHub issue and reveals the crash report "
        + "in Finder so you can review it before attaching; just drag it into the issue."

    /// Body inserted into the pre-filled GitHub issue. `reportName` is the
    /// `.ips` filename that was revealed in Finder.
    static func issueContext(reportName: String) -> String {
        "The app crashed on a previous launch. The macOS crash report "
        + "(`\(reportName)`) has been revealed in Finder. Please review it (it can "
        + "contain your account name, file paths, process arguments, and system "
        + "details) and drag it into this issue."
    }
}
