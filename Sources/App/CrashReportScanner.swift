import Foundation

/// Decides whether a new macOS crash report warrants prompting the user
/// to send it. Pure + unit-testable: the directory enumeration and the
/// AppKit prompt live in `AppDelegate`; this just picks the newest report
/// that postdates the last one we already offered.
///
/// Why a marker rather than "any report exists": the app should ask about
/// a crash exactly once, and never re-surface old reports on every launch.
/// `AppDelegate` persists the chosen report's modification date and passes
/// it back as `lastHandled` next time.
enum CrashReportScanner {

    struct Report: Equatable {
        let name: String
        let modified: Date
    }

    /// The newest report strictly newer than `lastHandled`, or nil if
    /// there's nothing newer. With `lastHandled == nil` it returns the
    /// newest candidate — but `AppDelegate` seeds the marker to "now" on
    /// first run instead of calling with nil, so crash reports that
    /// predate this feature are never surfaced.
    static func newestUnhandled(_ candidates: [Report],
                                since lastHandled: Date?) -> Report? {
        guard let newest = candidates.max(by: { $0.modified < $1.modified }) else {
            return nil
        }
        if let lastHandled, newest.modified <= lastHandled { return nil }
        return newest
    }
}
