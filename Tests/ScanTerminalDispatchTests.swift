import XCTest
@testable import unison_ui_mac

/// Locks the callback→event binding (issue #24) — the layer ABOVE
/// `EngineSessionCoordinator.cause(for:)`. Each named registrar method must
/// forward its FIXED interrupt event (and the op identity) unchanged. If a
/// scan-failed callback were bound to `.init2Completed`, it would classify as a
/// clean terminal and, were stop-in-place re-enabled, let an unsafe terminal
/// reach a reusable `.stopped`. Mutating any method's event fails here.
///
/// Residual not covered here (documented, accepted): whether each production
/// `UnisonBridge` callback calls the correspondingly-named method. That binding
/// is now a name-obvious match at the call site rather than a free event
/// literal; fully test-covering it would require driving the whole AppKit/bridge
/// stack.
@MainActor
final class ScanTerminalDispatchTests: XCTestCase {

    private typealias C = EngineSessionCoordinator

    func test_eachCallbackForwardsItsFixedEventAndOp() {
        var seen: [(C.OperationID, C.InterruptTerminalEvent)] = []
        let d = ScanTerminalDispatch { _, op, e in seen.append((op, e)); return true }
        let s = C.SessionID(raw: 9)
        let (op1, op2, op3) = (C.OperationID(raw: 1), C.OperationID(raw: 2), C.OperationID(raw: 3))

        XCTAssertTrue(d.init2Completed(s, op1))
        XCTAssertTrue(d.scanFailed(s, op2))
        XCTAssertTrue(d.fatal(s, op3))

        XCTAssertEqual(seen.map(\.1), [.init2Completed, .scanFailed, .genericFatal],
                       "each callback must forward its fixed event")
        XCTAssertEqual(seen.map(\.0), [op1, op2, op3],
                       "op identity must pass through unchanged")
    }

    /// The registrar returns the sink's verdict verbatim (true iff the
    /// coordinator is interrupting this op → the caller suppresses normal
    /// routing).
    func test_forwardsSinkVerdict() {
        let s = C.SessionID(raw: 1), op = C.OperationID(raw: 1)
        XCTAssertFalse(ScanTerminalDispatch { _, _, _ in false }.scanFailed(s, op))
        XCTAssertTrue(ScanTerminalDispatch { _, _, _ in true }.scanFailed(s, op))
    }
}
