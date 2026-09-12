import Foundation

/// The driver's decision for applying a session's overrides to the engine before
/// `init1` (patch 0008's first-load contract). Extracted as a pure function so
/// the production driver (`driveBeginConnect`) and its tests share exactly one
/// implementation.
///
/// The decision is driven by the session's `SessionOverrides`, NOT by whether a
/// vector happens to be empty:
///  - `.inheritLaunch` — the transitional launch case: do not call the setter,
///    leaving the engine's `sessionArgs` at `None` so `do_unisonInit1` parses
///    the process launch command line itself (legacy first load).
///  - `.explicit(v)` — call the setter with `v` (even when empty), so the engine
///    suppresses the process argv and applies exactly `v`. This is what makes an
///    explicitly unscoped session drop any inherited `-path`, and what resets a
///    prior session's scope so it cannot leak. A non-OK setter result must
///    **stop the open** — proceeding into `init1` could open the profile with a
///    stale or omitted scope (finding P1).
enum SessionArgsApply {

    enum Decision: Equatable {
        case proceed
        case fail(status: Int32)
    }

    /// - Parameters:
    ///   - overrides: this session's override source.
    ///   - setter: the bridge setter (`UnisonBridge.setSessionArgs`), returning a
    ///     `UNISON_BRIDGE_*` status. Injected so tests exercise this exact logic.
    static func decide(_ overrides: SessionOverrides,
                       setter: ([String]) -> Int32) -> Decision {
        switch overrides {
        case .inheritLaunch:
            // Preserve the engine's legacy first-load parse of the launch argv.
            return .proceed
        case .explicit(let v):
            let status = setter(v)
            return status == UNISON_BRIDGE_OK ? .proceed : .fail(status: status)
        }
    }
}
