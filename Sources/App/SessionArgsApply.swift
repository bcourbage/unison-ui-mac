import Foundation

/// The driver's decision for applying a session's command-line overrides to the
/// engine before `init1` (patch 0008's first-load contract). Extracted as a pure
/// function so the production driver (`driveBeginConnect`) and its tests share
/// exactly one implementation.
///
/// Contract:
///  - On the **very first connect of the process** with **no explicit
///    overrides**, do not call the setter: leave the engine's `sessionArgs` at
///    `None` so `do_unisonInit1` parses the launch command line the legacy way.
///  - Otherwise call the setter with the vector (empty resets, so a prior
///    session's scope cannot leak; a real vector scopes this session). A non-OK
///    setter result must **stop the open** — proceeding into `init1` could open
///    the profile with a stale or omitted scope (finding P1).
enum SessionArgsApply {

    enum Decision: Equatable {
        case proceed
        case fail(status: Int32)
    }

    /// - Parameters:
    ///   - args: this session's overrides (empty for an ordinary open).
    ///   - isFirstConnect: true only for the first engine connect of the process.
    ///   - setter: the bridge setter (`UnisonBridge.setSessionArgs`), returning a
    ///     `UNISON_BRIDGE_*` status. Injected so tests exercise this exact logic.
    static func decide(args: [String],
                       isFirstConnect: Bool,
                       setter: ([String]) -> Int32) -> Decision {
        if isFirstConnect && args.isEmpty {
            // Preserve the engine's legacy first-load parse of the launch argv.
            return .proceed
        }
        let status = setter(args)
        return status == UNISON_BRIDGE_OK ? .proceed : .fail(status: status)
    }
}
