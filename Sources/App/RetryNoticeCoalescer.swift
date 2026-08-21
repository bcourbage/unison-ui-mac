import Foundation

/// Issue #63: coalesces ssh's standalone "Permission denied, please try again."
/// retry notice into the *next* credential prompt, so the user answers one sheet
/// per real attempt instead of a phantom extra one.
///
/// The GUI's prompt reader (`Terminal.termInput`) does a single read per prompt
/// with no settle, so the retry notice arrives as its own chunk, ahead of the
/// re-prompt. `ConnectPromptClassifier` tags that chunk `.retryNotice`; the
/// driver (`drivePromptLoop`) then reads the next prompt WITHOUT replying and
/// folds the held notice into that prompt's sheet message.
///
/// This is the pure state seam for that behavior. The driver owns one instance
/// and asks it what to show at each prompt, which keeps the lifecycle invariant
/// testable without driving the async connect loop:
///   - a held notice is presented exactly once, then cleared;
///   - a credential prompt with nothing held is shown unchanged;
///   - the notice is bound to the `(SessionID, OperationID)` it was captured
///     for, so it can never leak into a different connection — a fold requested
///     for any other op drops it. `reset()` (called at the start of every
///     connect) makes that explicit even without the binding.
struct RetryNoticeCoalescer {
    typealias SessionID = EngineSessionCoordinator.SessionID
    typealias OperationID = EngineSessionCoordinator.OperationID

    private var pending: (session: SessionID, op: OperationID, notice: String)?

    /// A new connect starts clean — nothing carried over from a prior one.
    mutating func reset() {
        pending = nil
    }

    /// True while a notice is being held (for logging / assertions).
    var hasPending: Bool { pending != nil }

    /// Record ssh's retry notice for `(s, op)`. The driver then reads the next
    /// prompt without replying; the held notice is surfaced when that prompt
    /// arrives. An empty notice is ignored (nothing to show).
    mutating func hold(_ notice: String, for s: SessionID, _ op: OperationID) {
        let trimmed = notice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { pending = nil; return }
        pending = (s, op, trimmed)
    }

    /// Fold any notice held for `(s, op)` into `prompt`, consuming it. Returns
    /// the notice-prefixed message when one is held for this exact op, else
    /// `prompt` unchanged. Consumes unconditionally: a notice held for a
    /// different op is stale and is dropped rather than carried forward.
    mutating func fold(into prompt: String, for s: SessionID, _ op: OperationID) -> String {
        defer { pending = nil }
        guard let p = pending, p.session == s, p.op == op else { return prompt }
        return p.notice + "\n" + prompt
    }
}
