import Foundation

/// Classifies a string handed back by the engine's connect prompt loop
/// (`openConnectionPrompt`) into what it actually is (issue #35).
///
/// The embedded engine surfaces ssh's terminal output through the SAME channel
/// as a genuine credential request: a login-grace timeout, a broken pipe, or a
/// "Connection closed by host" all arrive as a `Some "<text>"` prompt, exactly
/// like "Password:". Presenting a fatal transport error as another password
/// sheet is the defect in #35 — the user answers a prompt that cannot succeed,
/// and the connect then hangs.
///
/// Classification priority (per the issue's binding technical caution —
/// child-exit / transport status is the authority, string matching only a
/// supplement):
///   1. `transportTerminated` (the tracked ssh child has gone/zombied) is
///      authoritative: any prompt arriving now is post-mortem output → `.fatal`,
///      no matter what the string looks like.
///   2. An UNMISTAKABLE ssh transport-failure phrase → `.fatal`. Checked BEFORE
///      any credential heuristic, so a stray "password" substring inside a fatal
///      message (e.g. an auth-method list) can never flip it back to a prompt.
///      The phrase list is deliberately precise: only strings that cannot occur
///      in a real credential/host-key prompt.
///   3. A host-key authenticity yes/no question → `.hostKeyQuestion` (an
///      editable, non-secure response — preserves the legacy behavior).
///   4. Everything else → `.credential`, shown verbatim. This preserves genuine
///      password / passphrase / MFA / keyboard-interactive / PAM prompts (e.g.
///      "Approve this connection to …") and the wrong-password RE-PROMPT, none
///      of which we need to positively enumerate: anything not proven fatal or a
///      host-key question is safe to present as a prompt.
///
/// Deliberately NOT fatal here: "Permission denied, please try again." — that
/// precedes a genuine re-prompt (rule 2b folds it into the next prompt). We
/// never infer auth exhaustion from the string: when ssh actually gives up it
/// EXITS, and that surfaces either as rule 1 (the tracked child has terminated
/// by the next read) or, if the child hasn't been reaped yet, through the
/// existing connection-end failure handling — not as another prompt to answer.
/// The former overly broad "connection to " marker was removed precisely
/// because it matched benign keyboard-interactive text like "Approve this
/// connection to …".
enum ConnectPromptClassifier {

    enum Verdict: Equatable {
        case credential
        case hostKeyQuestion
        /// ssh's retryable failure line (e.g. "Permission denied, please try
        /// again.") standing alone, WITHOUT the re-prompt in the same read. It is
        /// not itself a credential request; the driver must fold it into the
        /// message of the next (genuine) prompt instead of presenting its own
        /// sheet (issue #63).
        case retryNotice(String)
        case fatal(reason: String)
    }

    static func classify(prompt: String, transportTerminated: Bool) -> Verdict {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Terminal evidence wins outright.
        if transportTerminated {
            return .fatal(reason: trimmed.isEmpty ? "The remote connection was lost." : trimmed)
        }

        // 2. Unmistakable transport failure — checked before any credential
        //    consideration so a "password" substring cannot suppress it.
        if isFatalTransportText(lower) {
            return .fatal(reason: trimmed)
        }

        // 2b. ssh's password retry notice precedes a genuine re-prompt. The GUI
        //     prompt reader (`Terminal.termInput`) does a single read per prompt
        //     with no settle/accumulation, so this line arrives as its own chunk,
        //     separate from the following "password:" prompt — presenting it as
        //     its own sheet makes the user answer a phantom prompt (#63). Fold it
        //     into the next real prompt instead. Matched by EQUALITY, so only the
        //     bare notice qualifies: a chunk that ALSO carries the
        //     password/passphrase prompt stays a normal (coalesced) credential
        //     prompt, and unrelated "please try again" wording is left alone.
        if isRetryNotice(lower) {
            return .retryNotice(trimmed)
        }

        // 3. Host-key yes/no question (matches PasswordSheet's own heuristic).
        if isHostKeyQuestion(lower) {
            return .hostKeyQuestion
        }

        // 4. Default: present verbatim as a credential prompt.
        return .credential
    }

    /// ssh's exact standalone password retry notice. Matched by EQUALITY (after
    /// the caller's whitespace trim + lowercasing), not a substring, on purpose:
    ///   - A combined "Permission denied, please try again.\r\nPassword:" chunk
    ///     is NOT equal, so it stays a normal (coalesced) credential prompt.
    ///   - Other "please try again" wording — notably keyboard-interactive/MFA
    ///     text like "Verification failed. Please try again." followed by
    ///     "Verification code:" — is NOT equal, so it is never mistaken for this
    ///     notice and read-without-replying (which would hang ssh waiting for the
    ///     code until the connect watchdog fires).
    /// This is the literal string OpenSSH prints between password attempts.
    private static let retryNotice = "permission denied, please try again."

    private static func isRetryNotice(_ lower: String) -> Bool {
        return lower == retryNotice
    }

    private static func isHostKeyQuestion(_ lower: String) -> Bool {
        return lower.contains("authenticity")
            || lower.contains("(yes/no")
            || lower.contains("yes/no)")
    }

    /// ssh terminal output that means the transport died or was refused — none
    /// of these can appear in a genuine credential or host-key prompt. Kept
    /// precise on purpose (no generic "connection to " / "port 22" substrings,
    /// which also match benign keyboard-interactive prompts).
    private static func isFatalTransportText(_ lower: String) -> Bool {
        let markers = [
            "broken pipe",
            "connection closed",
            "connection reset",
            "connection refused",
            "connection timed out",
            "ssh_dispatch_run_fatal",
            "ssh_exchange_identification",
            "kex_exchange_identification",
            "no route to host",
            "network is unreachable",
            "host key verification failed",
            "remote host identification has changed",
            "operation timed out",
        ]
        return markers.contains { lower.contains($0) }
    }
}
