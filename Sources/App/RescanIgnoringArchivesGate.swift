import Foundation

/// Authority gate for **Action ▸ Rescan Ignoring Archives…** (Blocker B7).
///
/// The command routes through `reopenCurrentProfileFresh`, which fails any
/// in-flight op with `engineIsQuiescent: true`. That quiescence proof holds
/// ONLY for the post-unwind recoverable-fatal callback path (the OCaml worker
/// has provably unwound before the fatal reaches Swift) — NOT for an arbitrary
/// menu action fired during live work. Invoked while `.opening`, `.scanning`,
/// or `.syncing`, it would bypass the window's sync-close confirmation, tear
/// down a live transport, and start a fresh init while the original worker is
/// still modifying archives.
///
/// So the command is permitted ONLY when the coordinator is exactly `.ready` —
/// a scanned session awaiting the user, no operation in flight — with a
/// reconcile window open on a known profile. A SINGLE decision drives both
/// `validateMenuItem` and the action itself; the action re-checks at its own
/// boundary because menu validation is not an authority boundary (a key
/// equivalent or a programmatic send can reach the action without it).
enum RescanIgnoringArchivesGate {
    static func isAllowed(phase: EngineSessionCoordinator.Phase,
                          hasReconcileWindow: Bool,
                          hasProfile: Bool) -> Bool {
        guard hasReconcileWindow, hasProfile else { return false }
        if case .ready = phase { return true }
        return false
    }
}
