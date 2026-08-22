import Foundation

/// The three bridge callbacks that can be an interrupted scan's terminal each
/// map to ONE fixed `InterruptTerminalEvent` (issue #24). This registrar is the
/// single place those callback→event bindings live, as named methods, so they
/// are exercised DIRECTLY in a unit test instead of appearing as free event
/// literals at each `UnisonBridge` callback site — where a mislabel
/// (`.scanFailed` typed as `.init2Completed`) would pass unnoticed and, if
/// stop-in-place were ever re-enabled, launder an unsafe terminal into a
/// reusable engine. Mirrors the extract-and-test idiom of `ScanInterruptPolicy`
/// / `RowCompletionRouter`.
///
/// `observe` is the injected coordinator-facing sink; it returns true iff the
/// coordinator is interrupting this op (so the caller suppresses the normal,
/// non-interruption presentation/routing). The event carried into each call is
/// fixed by the method name and cannot be chosen by the caller.
@MainActor
struct ScanTerminalDispatch {
    typealias SessionID = EngineSessionCoordinator.SessionID
    typealias OperationID = EngineSessionCoordinator.OperationID
    typealias Event = EngineSessionCoordinator.InterruptTerminalEvent

    let observe: (SessionID, OperationID, Event) -> Bool

    /// The scan's init2-complete callback: a clean terminal.
    func init2Completed(_ s: SessionID, _ op: OperationID) -> Bool { observe(s, op, .init2Completed) }
    /// The async scan-state-emission failure callback: unsafe.
    func scanFailed(_ s: SessionID, _ op: OperationID) -> Bool { observe(s, op, .scanFailed) }
    /// A fatal intercepted during the interruption teardown: unsafe.
    func fatal(_ s: SessionID, _ op: OperationID) -> Bool { observe(s, op, .genericFatal) }
}
