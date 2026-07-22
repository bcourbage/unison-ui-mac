import XCTest
@testable import unison_ui_mac

/// Issue #35 scenario 6: the Debug-only `connection_cancel` failure hook. Armed
/// by the `UNISON_TEST_FORCE_CANCEL_FAIL=1` environment variable, it forces the
/// reported cancel status to "failed" (2), driving the non-quiescent
/// restart-required path. Compiled out entirely in Release.
final class ConnectionCancelHookTests: XCTestCase {

    override func tearDown() {
        unsetenv("UNISON_TEST_FORCE_CANCEL_FAIL")
        super.tearDown()
    }

    /// With no preconnection, cancel is a benign success (0); the armed hook
    /// overrides the reported status to 2. Disarming (clearing the env) restores
    /// the benign 0 — confirming the hook is env-gated and not sticky.
    func test_forceCancelFail_env_overridesThenRestores() {
        setenv("UNISON_TEST_FORCE_CANCEL_FAIL", "1", 1)
        XCTAssertEqual(unison_bridge_connection_cancel(), 2, "armed hook forces cancel-failed")
        unsetenv("UNISON_TEST_FORCE_CANCEL_FAIL")
        XCTAssertEqual(unison_bridge_connection_cancel(), 0, "disarmed → benign success")
    }

    /// Any value other than "1" leaves the hook inert.
    func test_forceCancelFail_env_otherValueInert() {
        setenv("UNISON_TEST_FORCE_CANCEL_FAIL", "0", 1)
        XCTAssertEqual(unison_bridge_connection_cancel(), 0)
    }
}
