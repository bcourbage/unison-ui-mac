import Foundation

/// Phase-aware policy for what the init2/scan-stall timer does when it fires
/// (issue #33). Pure and deterministically testable — no clock, no AppKit.
///
/// ## Why phase-awareness is needed
/// The scan-stall timer (issue #24) fires after `scanStallTimeout` of no scan
/// status. Silence alone is NOT evidence that the remote transport is wedged: a
/// local-replica walk can legitimately go silent for a long time — most visibly
/// when it blocks on a macOS TCC authorization prompt (e.g. a Photo Library
/// under `~/Pictures`), but also on a very large local tree. Escalating that to
/// a fatal restart-required is a false positive (issue #33).
///
/// ## The reliable "waiting on remote transport" signal
/// Update detection (`Update.findUpdates`) processes roots in canonical order,
/// which is **[Local, Remote]** — `Common.compareRoots` sorts `Local` before
/// `Remote`. `Lwt_util.map_with_waiting_action` invokes the remote root's
/// "waiting action" only AFTER the local root's update detection completes, and
/// that waiting action emits `Trace.statusDetail "Waiting for changes from
/// server"` (upstream `update.ml`). It reaches the app's status handler as a
/// substring of the formatted status line.
///
/// Therefore observing that marker means the local walk (including every
/// TCC-gated local access) has already finished and the client is now blocked
/// on the remote round-trip. Only then is prolonged silence reliable evidence of
/// a wedged remote transport, and only then may the stall be treated as fatal.
/// Before the marker, a stall is a local/TCC pause and must NOT mutate
/// coordinator state.
///
/// This keys on the engine's status text at the pinned vendored commit
/// (`91421d0`); the vendored-bump checklist should re-verify the marker string.
enum ScanStallPolicy {

    /// What to do when the scan-stall timer fires.
    enum Action: Equatable {
        /// Reliable evidence the op is waiting on remote transport → fatal,
        /// route to restart-required (issue #24 recovery, unchanged).
        case restartRequired
        /// Still in (or not past) the local-replica walk — a local/TCC pause,
        /// not a remote wedge. Do NOT touch coordinator state; keep waiting
        /// (re-arm) so a genuine remote wedge later still fires.
        case keepWaiting
    }

    /// True iff `statusMessage` is the "now waiting on the remote" marker, which
    /// upstream emits only after the local-replica walk has completed.
    static func marksRemoteWait(_ statusMessage: String) -> Bool {
        statusMessage.contains("Waiting for changes from server")
    }

    /// The decision when the timer fires: fatal only with reliable remote-wait
    /// evidence; otherwise keep waiting without mutating engine/coordinator
    /// state.
    static func actionOnStall(sawRemoteWait: Bool) -> Action {
        sawRemoteWait ? .restartRequired : .keepWaiting
    }
}
