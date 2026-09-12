import Foundation

/// Routes the transitional launch-command-line inheritance to the FIRST
/// launch-origin profile session that actually opens, matching the #162
/// contract: a graphical launch that supplies options belongs to its first
/// opened profile — the profile named on the command line, or, when none was
/// named and the picker is shown, the first profile the user successfully opens.
/// Every later picker selection is explicitly unscoped, and a handoff request
/// from another process never inherits (it does not consult the router).
///
/// Choosing the override is separate from consuming inheritance: an open that is
/// REFUSED before it is accepted (for example, an outstanding archive-recovery
/// block) must leave inheritance pending, so the user's retry after recovery
/// still inherits. Callers therefore do:
///
///     let overrides = router.overrideForNextOpen()
///     let accepted  = profileSelected(name, overrides: overrides)
///     router.didOpen(overrides, accepted: accepted)
///
/// This is a transitional bridge for the engine's first-load parse of the
/// process argv; it does NOT preserve launch options across a reconnect (see
/// SessionOverrides.inheritLaunch), and is retired once launch options are
/// delivered as explicit args (a later PR). Extracted from AppDelegate so the
/// launch → picker sequence, including a refused-then-retried selection, is
/// testable without AppKit.
struct LaunchOverrideRouter {
    private var inheritancePending: Bool

    /// `launchCanInherit` is false only when the process had no graphical launch
    /// session to inherit from (nothing to route). Defaults true.
    init(launchCanInherit: Bool = true) {
        inheritancePending = launchCanInherit
    }

    /// The override source for the next launch-origin open (named launch profile
    /// or picker selection). Does NOT consume inheritance — call `didOpen` with
    /// the outcome.
    func overrideForNextOpen() -> SessionOverrides {
        inheritancePending ? .inheritLaunch : .explicit([])
    }

    /// Record the outcome of an open that received `overrides`. Inheritance is
    /// consumed only when an `.inheritLaunch` open was actually accepted (entered
    /// opening or was queued); a refusal leaves it pending for the retry.
    mutating func didOpen(_ overrides: SessionOverrides, accepted: Bool) {
        if accepted, case .inheritLaunch = overrides {
            inheritancePending = false
        }
    }
}
