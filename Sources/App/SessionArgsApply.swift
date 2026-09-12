import Foundation

/// The driver's decision for applying a session's overrides to the engine before
/// `init1`. Extracted as a pure function so the production driver
/// (`driveBeginConnect`) and its tests share one implementation.
///
/// Every session now carries an explicit argument vector (the transitional
/// `.inheritLaunch` is retired; a launch's own options are delivered as explicit
/// args by `LaunchOverrideRouter`). So the driver ALWAYS calls the setter, even
/// for an empty vector — an empty vector suppresses any inherited process-argv
/// scope and resets a prior session's scope. A non-OK setter result must **stop
/// the open**: proceeding into `init1` could open the profile with a stale or
/// omitted scope (finding P1).
enum SessionArgsApply {

    enum Decision: Equatable {
        case proceed
        case fail(status: Int32)
    }

    /// - Parameters:
    ///   - args: this session's overrides (empty for an unscoped session).
    ///   - setter: the bridge setter (`UnisonBridge.setSessionArgs`), returning a
    ///     `UNISON_BRIDGE_*` status. Injected so tests exercise this exact logic.
    static func decide(_ args: [String], setter: ([String]) -> Int32) -> Decision {
        let status = setter(args)
        return status == UNISON_BRIDGE_OK ? .proceed : .fail(status: status)
    }
}
