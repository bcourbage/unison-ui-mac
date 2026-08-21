import XCTest
@testable import unison_ui_mac

/// Issue #34: the sync-stall notice must be advisory, not alarming. It must not
/// claim the connection was lost or tell the user to abort/quit.
final class SyncStallNoticeTests: XCTestCase {

    func test_message_isAdvisory_notAlarming() {
        let m = SyncStallNotice.message(seconds: 45).lowercased()
        // States progress not observed + transfer may still be active.
        XCTAssertTrue(m.contains("no sync progress has been observed"))
        XCTAssertTrue(m.contains("may still be running"))
        XCTAssertTrue(m.contains("45"))
        // Must NOT instruct abort/quit or assert a lost/wedged connection.
        for banned in ["lost", "quit", "wedged", "stuck", "abort", "recover", "restart", "can't be stopped"] {
            XCTAssertFalse(m.contains(banned), "advisory notice must not contain \"\(banned)\"")
        }
    }
}
