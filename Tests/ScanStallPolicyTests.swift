import XCTest
@testable import unison_ui_mac

/// Issue #33: the scan-stall timer must be phase-aware. `ScanStallPolicy` is the
/// pure decision: fatal only with reliable "waiting on remote transport"
/// evidence; otherwise keep waiting (a local/TCC pause is not a remote wedge).
final class ScanStallPolicyTests: XCTestCase {

    private typealias P = ScanStallPolicy

    // MARK: remote-wait marker detection

    func test_marker_matchesFormattedStatusLine() {
        // As it reaches the status handler: formatStatus pads the major status
        // and appends the minor ("Waiting for changes from server").
        let formatted = "Looking for changes           Waiting for changes from server"
        XCTAssertTrue(P.marksRemoteWait(formatted))
    }

    func test_marker_matchesBareMinor() {
        XCTAssertTrue(P.marksRemoteWait("Waiting for changes from server"))
    }

    func test_marker_doesNotMatchLocalWalkStatuses() {
        for s in ["Looking for changes",
                  "scanning... Photos Library.photoslibrary",
                  "Reconciling changes",
                  "Connected [ssh://host//path]",
                  "Updating synchronizer state",
                  ""] {
            XCTAssertFalse(P.marksRemoteWait(s), "must not match local/other status: \(s)")
        }
    }

    // MARK: decision

    func test_action_remoteWaitSeen_isFatal() {
        XCTAssertEqual(P.actionOnStall(sawRemoteWait: true), .restartRequired)
    }

    func test_action_noRemoteWait_keepsWaiting() {
        XCTAssertEqual(P.actionOnStall(sawRemoteWait: false), .keepWaiting)
    }
}
