import Foundation

/// Routes the transitional launch-command-line inheritance to the FIRST
/// launch-origin profile session, matching the #162 contract: a graphical launch
/// that supplies options belongs to its first opened profile — the profile named
/// on the command line, or, when none was named and the picker is shown, the
/// first profile the user selects. Every later picker selection is explicitly
/// unscoped, and a handoff request from another process never inherits.
///
/// This is a transitional bridge for the engine's first-load parse of the
/// process argv; it does NOT preserve launch options across a reconnect (see
/// SessionOverrides.inheritLaunch), and is retired once launch options are
/// delivered as explicit args (a later PR).
///
/// Extracted from AppDelegate so the launch → picker sequence is testable without
/// AppKit: the driver calls `forLaunchProfile()` at a named-profile launch and
/// `forPickerSelection()` for each picker pick; a handoff open does not consult
/// the router (it is always `.explicit([])`).
struct LaunchOverrideRouter {
    private var inheritancePending: Bool

    /// `launchCanInherit` is false only when the process had no graphical launch
    /// session to inherit from (there is nothing to route). Defaults true.
    init(launchCanInherit: Bool = true) {
        inheritancePending = launchCanInherit
    }

    /// A profile named on the command line opens as the launch session and claims
    /// the launch inheritance.
    mutating func forLaunchProfile() -> SessionOverrides {
        inheritancePending = false
        return .inheritLaunch
    }

    /// A picker selection. The first one after an unclaimed launch inherits the
    /// launch command line; every later selection is explicitly unscoped.
    mutating func forPickerSelection() -> SessionOverrides {
        if inheritancePending {
            inheritancePending = false
            return .inheritLaunch
        }
        return .explicit([])
    }
}
