import XCTest
@testable import unison_ui_mac

/// Pins the "should we offer to send a crash report?" decision: the newest
/// report strictly newer than the last one we already offered. Guards the
/// two behaviors that matter — never re-ask for an already-handled crash,
/// and always pick the most recent when several exist.
final class CrashReportScannerTests: XCTestCase {

    private typealias Report = CrashReportScanner.Report

    private func date(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }

    func test_noCandidates_returnsNil() {
        XCTAssertNil(CrashReportScanner.newestUnhandled([], since: date(100)))
        XCTAssertNil(CrashReportScanner.newestUnhandled([], since: nil))
    }

    func test_nilMarker_returnsNewest() {
        let r = CrashReportScanner.newestUnhandled([
            Report(name: "a.ips", modified: date(10)),
            Report(name: "b.ips", modified: date(30)),
            Report(name: "c.ips", modified: date(20)),
        ], since: nil)
        XCTAssertEqual(r?.name, "b.ips")
    }

    func test_markerOlderThanNewest_returnsNewest() {
        let r = CrashReportScanner.newestUnhandled([
            Report(name: "old.ips", modified: date(50)),
            Report(name: "new.ips", modified: date(150)),
        ], since: date(100))
        XCTAssertEqual(r?.name, "new.ips")
    }

    func test_markerEqualToNewest_returnsNil() {
        // Already handled exactly this report — don't re-offer.
        let r = CrashReportScanner.newestUnhandled([
            Report(name: "x.ips", modified: date(100)),
        ], since: date(100))
        XCTAssertNil(r)
    }

    func test_markerNewerThanAll_returnsNil() {
        let r = CrashReportScanner.newestUnhandled([
            Report(name: "x.ips", modified: date(40)),
            Report(name: "y.ips", modified: date(90)),
        ], since: date(100))
        XCTAssertNil(r)
    }

    func test_picksMostRecentAmongNewerOnes() {
        let r = CrashReportScanner.newestUnhandled([
            Report(name: "handled.ips", modified: date(50)),   // <= marker, ignored
            Report(name: "newer1.ips", modified: date(120)),
            Report(name: "newest.ips", modified: date(200)),
            Report(name: "newer2.ips", modified: date(160)),
        ], since: date(100))
        XCTAssertEqual(r?.name, "newest.ips")
    }
}
