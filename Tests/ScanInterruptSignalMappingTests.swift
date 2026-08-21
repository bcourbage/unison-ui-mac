import XCTest
@testable import unison_ui_mac

/// Phase 1a (issue #24): the pure C→coordinator mapping. The `ALREADY_DEAD`
/// identity split is a reviewer acceptance point.
final class ScanInterruptSignalMappingTests: XCTestCase {

    private typealias SR = EngineSessionCoordinator.SignalResult
    private typealias RS = EngineSessionCoordinator.ReapState
    private typealias Id = EngineSessionCoordinator.TransportIdentity

    private func result(_ outcome: unison_signal_outcome_t, valid: Int32,
                        pid: Int32 = 4242, sec: Int64 = 100, usec: Int32 = 200)
    -> unison_scan_signal_result_t {
        unison_scan_signal_result_t(outcome: outcome, pid: pid, start_sec: sec,
                                    start_usec: usec, identity_valid: valid)
    }

    func test_signalled_withIdentity() {
        XCTAssertEqual(SR.from(result(UNISON_SIGNAL_SIGNALLED, valid: 1)),
                       .signalled(Id(pid: 4242, startSec: 100, startUsec: 200)))
    }

    func test_signalled_withoutIdentity_isUnprovable() {
        XCTAssertEqual(SR.from(result(UNISON_SIGNAL_SIGNALLED, valid: 0)), .unprovableIdentity)
    }

    // Acceptance point: ALREADY_DEAD → withIdentity ONLY when identity is valid.
    func test_alreadyDead_withValidIdentity_isWithIdentity() {
        XCTAssertEqual(SR.from(result(UNISON_SIGNAL_ALREADY_DEAD, valid: 1)),
                       .alreadyDeadWithIdentity(Id(pid: 4242, startSec: 100, startUsec: 200)))
    }

    func test_alreadyDead_withoutValidIdentity_isNoIdentity() {
        XCTAssertEqual(SR.from(result(UNISON_SIGNAL_ALREADY_DEAD, valid: 0)), .alreadyDeadNoIdentity)
    }

    func test_refusalOutcomes() {
        XCTAssertEqual(SR.from(result(UNISON_SIGNAL_NO_CHILD, valid: 0)), .noChild)
        XCTAssertEqual(SR.from(result(UNISON_SIGNAL_MULTIPLE_CHILDREN, valid: 0)), .multipleChildren)
        XCTAssertEqual(SR.from(result(UNISON_SIGNAL_FAILED, valid: 0)), .signalFailed)
    }

    func test_reapMapping() {
        XCTAssertEqual(RS.from(UNISON_REAP_ABSENT), .absent)
        XCTAssertEqual(RS.from(UNISON_REAP_REUSED), .reused)
        XCTAssertEqual(RS.from(UNISON_REAP_ZOMBIE), .zombie)
        XCTAssertEqual(RS.from(UNISON_REAP_LIVE), .live)
        XCTAssertEqual(RS.from(UNISON_REAP_UNKNOWN), .unknown)
    }
}
