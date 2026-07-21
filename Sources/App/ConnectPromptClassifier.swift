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
///      authoritative: any prompt arriving now is post-mortem output → `.fatal`.
///   2. A host-key authenticity yes/no question → `.hostKeyQuestion` (an
///      editable, non-secure response — preserves the legacy behavior).
///   3. A string that positively reads as a credential request ("password",
///      "passphrase", a verification/one-time code) → `.credential`, so a
///      legitimate wrong-password RE-PROMPT is never mistaken for a fatal.
///   4. A string that clearly reads as an ssh transport failure (and did NOT
///      read as a credential request) → `.fatal` — the supplement, covering the
///      brief window before the child registers as terminated.
///   5. Anything else → `.credential` (display verbatim), preserving today's
///      behavior for anything not positively identified as fatal.
///
/// Deliberately NOT treated as fatal here: "Permission denied, please try
/// again." — that precedes a genuine re-prompt. True auth exhaustion makes ssh
/// EXIT, which rule 1 catches via the terminated child; we never need to guess
/// it from the string.
enum ConnectPromptClassifier {

    enum Verdict: Equatable {
        case credential
        case hostKeyQuestion
        case fatal(reason: String)
    }

    static func classify(prompt: String, transportTerminated: Bool) -> Verdict {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Terminal evidence wins outright.
        if transportTerminated {
            return .fatal(reason: trimmed.isEmpty ? "The remote connection was lost." : trimmed)
        }

        // 2. Host-key yes/no question (matches PasswordSheet's own heuristic).
        if lower.contains("authenticity")
            || lower.contains("(yes/no")
            || lower.contains("yes/no)") {
            return .hostKeyQuestion
        }

        // 3. A positive credential request — never let the fatal supplement
        //    swallow a legitimate re-prompt.
        if looksLikeCredentialRequest(lower) {
            return .credential
        }

        // 4. Supplemental: an unmistakable ssh transport failure.
        if isFatalTransportText(lower) {
            return .fatal(reason: trimmed)
        }

        // 5. Default: display verbatim as a credential prompt.
        return .credential
    }

    /// A prompt that positively asks for a secret the user can type.
    private static func looksLikeCredentialRequest(_ lower: String) -> Bool {
        // Deliberately specific multi-word markers: a bare short token like
        // "otp" could appear inside a hostname in a fatal string and wrongly
        // suppress the fatal verdict.
        return lower.contains("password")
            || lower.contains("passphrase")
            || lower.contains("verification code")
            || lower.contains("one-time password")
            || lower.contains("authentication code")
    }

    /// ssh terminal output that means the transport died — never part of a
    /// genuine credential prompt. Kept conservative on purpose.
    private static func isFatalTransportText(_ lower: String) -> Bool {
        let markers = [
            "broken pipe",
            "connection closed",
            "connection reset",
            "connection refused",
            "connection timed out",
            "connection to ",
            "ssh_dispatch_run_fatal",
            "kex_exchange_identification",
            "no route to host",
            "host key verification failed",
            "remote host identification has changed",
            "network is unreachable",
            "operation timed out",
        ]
        return markers.contains { lower.contains($0) }
    }
}
