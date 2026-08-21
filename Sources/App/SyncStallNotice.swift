import Foundation

/// Advisory (NON-fatal) notice for the sync/transfer-phase stall detector
/// (issue #34). Pure and testable.
///
/// Progress-callback silence during a transfer is NOT proof the transport is
/// wedged: a healthy transfer — especially of many small files — can be
/// callback-sparse, and the only blob-free signals (global-fraction and per-row
/// byte callbacks) are exactly what goes quiet. A real operation-bound liveness
/// signal would need an engine/transport heartbeat (a vendored-blob change),
/// which is out of scope for this release. So the detector uses the ratified
/// release-safe fallback: it stays advisory only. This notice therefore must
/// NOT claim the connection was lost or instruct the user to abort/quit — it
/// states only that progress has not been observed and the transfer may still
/// be active, and it clears on the next progress event or on completion. The
/// stronger liveness redesign is tracked as a post-release follow-up.
enum SyncStallNotice {
    static func message(seconds: Int) -> String {
        "No sync progress has been observed for \(seconds) seconds. "
            + "The transfer may still be running; this will update if it resumes."
    }
}
