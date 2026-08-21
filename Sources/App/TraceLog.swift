import Foundation
import os

/// Compatibility shim — forwards to `os.Logger` (macOS Unified Logging)
/// under category "general". Existing `TraceLog.shared.write(...)` call
/// sites continue to compile unchanged; the messages now show up in
/// Console.app (filter on subsystem `net.courbage.unison-ui-mac`)
/// instead of `/tmp/unison-ui-mac.log`.
///
/// **For new code, prefer the structured `Log` namespace below** — it
/// lets you pick a category (`Log.lifecycle`, `Log.bridge`, etc.) so
/// you can filter live streams with
/// `log stream --predicate 'category == "bridge"'` or similar.
///
/// **What you give up**: the at-rest text log file at /tmp. Unified
/// Logging persists messages in a system store; you read it with
/// Console.app or `log show --predicate 'subsystem == "..."'`. For
/// live tail use `log stream`. The text file path is no longer written.
final class TraceLog {
    nonisolated(unsafe) static let shared = TraceLog()

    private let logger: Logger

    init() {
        // Default category for the old TraceLog API. New call sites
        // should reach into `Log.*` for a specific category.
        self.logger = Logger(subsystem: Log.subsystem, category: "general")
    }

    /// Append a message to the log.
    ///
    /// PRIVACY (Finding #13): the message is a pre-composed string that in
    /// practice interpolates user-controlled values — profile names, filesystem
    /// paths, hostnames, counts, status text — so it is logged as `%{private}@`.
    /// The dynamic text is redacted to `<private>` wherever the log is read —
    /// Console.app, `log show`/`log stream`, a sysdiagnose, or a log archive —
    /// REGARDLESS of build configuration. Redaction is a property of the
    /// os_log format directive, not of who is watching: it is NOT lifted by
    /// running a Debug build, by attaching Console to the process, or by
    /// "actively debugging". The value shows in full only when private-data
    /// logging has been explicitly enabled on the machine (e.g. an
    /// `Enable-Private-Data` configuration profile, or `log config --mode
    /// private_data:on`) — an authorized, deliberately-configured debugging
    /// environment, never the default. This `%{private}@` default is the
    /// conservative choice: `TraceLog` can't tell an operational constant apart
    /// from a path once they're concatenated. For a line that is genuinely
    /// non-sensitive and worth keeping public at rest, use the structured
    /// `Log.*` API with a public string LITERAL and explicit per-value privacy
    /// instead of composing here.
    func write(_ message: String) {
        logger.info("\(message, privacy: .private)")
    }
}

/// Structured logging namespace. One `Logger` per logical category —
/// matches the kinds of events the app emits. Filtering examples in
/// Console.app (subsystem field) and from the command line:
///
///     log stream --predicate 'subsystem == "net.courbage.unison-ui-mac"'
///     log stream --predicate 'subsystem == "net.courbage.unison-ui-mac" AND category == "bridge"'
///     log show --predicate 'subsystem == "net.courbage.unison-ui-mac"' --last 1h
///
/// PRIVACY POLICY (Finding #13): a message's string LITERAL is always public
/// (it is the os_log format string). For INTERPOLATED values, the default is
/// `.private` (redacted in shared diagnostic material) — so user-controlled
/// values (paths, profile names, hostnames, usernames, command output, error
/// text) must be left at the default OR marked `\(x, privacy: .private)`
/// explicitly. Only genuinely non-sensitive OPERATIONAL metadata — counts,
/// enum/state labels, Unison version numbers — should be marked
/// `\(x, privacy: .public)`. When in doubt, leave it private.
enum Log {
    /// Reverse-DNS subsystem for the whole app. Keep stable — users'
    /// saved Console.app filters and stream predicates reference it.
    static let subsystem = "net.courbage.unison-ui-mac"

    /// App lifecycle: launch, picker open, profile pick, reconcile
    /// open/close, sync start/complete, app quit.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// OCaml↔Swift bridge events: callback registration, bridge call
    /// failures, init1/init2 boundaries, ri-set ops, ignore actions.
    static let bridge = Logger(subsystem: subsystem, category: "bridge")

    /// Reconcile-window state changes: row redraws, direction
    /// overrides applied, summary updates, sync UI resets.
    static let reconcile = Logger(subsystem: subsystem, category: "reconcile")

    /// Status messages forwarded from OCaml's `displayStatus`. High
    /// volume during sync — filter on this category specifically to
    /// see what Unison is doing without bridge noise mixed in.
    static let ocamlStatus = Logger(subsystem: subsystem, category: "ocaml-status")

    /// Version-check subprocess + result. Low volume (one per
    /// profile open with a remote root).
    static let versionCheck = Logger(subsystem: subsystem, category: "version-check")
}
