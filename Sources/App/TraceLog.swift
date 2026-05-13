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

    /// Append a message to the log. The first argument is treated as a
    /// public string — we're an interactive dev tool, not a privacy-
    /// sensitive production app, so `%{public}@` is the right default.
    /// If you need to log a value that might contain a credential, use
    /// `Logger.info(_:)` directly with an explicit redaction.
    func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
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
/// All entries use `.public` privacy because this is a developer-
/// facing diagnostic stream, not a privacy-sensitive end-user trace.
/// If we ever start logging passphrases / SSH keys / file content, we
/// MUST switch those individual call sites to `.private` (the default
/// when no explicit modifier is given) — but right now nothing here
/// crosses that line.
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
