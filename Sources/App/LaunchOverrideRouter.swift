import Foundation

/// Delivers a graphical launch's own command-line options (extracted by the
/// engine, patch 0009) to the FIRST launch-origin profile session that actually
/// opens, matching the #162 contract: a launch that supplies options belongs to
/// its first opened profile — the profile named on the command line, or, when
/// none was named and the picker is shown, the first profile the user
/// successfully opens. Every later picker selection is explicitly unscoped, and
/// a handoff request from another process never consults the router.
///
/// Choosing the args is separate from consuming them: an open that is REFUSED
/// before it is accepted (for example, an outstanding archive-recovery block)
/// must leave the launch args pending, so the user's retry after recovery still
/// receives them. Callers do:
///
///     let args = router.argsForNextOpen()
///     let accepted = profileSelected(name, args: args)
///     router.didOpen(accepted: accepted)
///
/// Unlike the transitional `.inheritLaunch` it replaces, the launch options are
/// delivered as EXPLICIT session args, so they are re-applied on every (re)load
/// and survive a reconnect (retiring the earlier reconnect limitation).
/// Extracted from AppDelegate so the launch → picker sequence, including a
/// refused-then-retried selection, is testable without AppKit.
struct LaunchOverrideRouter {
    /// The launch session's own args, until claimed by the first accepted open.
    /// `nil` means nothing to deliver (no graphical launch options, or already
    /// claimed); an empty array is treated the same for delivery.
    private var pendingLaunchArgs: [String]?

    init(launchArgs: [String]? = nil) {
        pendingLaunchArgs = launchArgs
    }

    /// The args for the next launch-origin open (named launch profile or picker
    /// selection). Does NOT consume — call `didOpen` with the outcome.
    func argsForNextOpen() -> [String] {
        pendingLaunchArgs ?? []
    }

    /// Record the outcome of a launch-origin open. The pending launch args are
    /// consumed once an open is accepted (entered opening or was queued); a
    /// refusal leaves them pending for the retry. Later opens (nothing pending)
    /// are unaffected.
    mutating func didOpen(accepted: Bool) {
        if accepted { pendingLaunchArgs = nil }
    }
}
