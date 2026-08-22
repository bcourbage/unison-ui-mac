import XCTest
@testable import unison_ui_mac

/// Issue #35: the engine hands ssh terminal output back through the same channel
/// as a real credential prompt. `ConnectPromptClassifier` decides which it is so
/// a fatal transport error is never re-presented as a password sheet.
final class ConnectPromptClassifierTests: XCTestCase {

    private typealias V = ConnectPromptClassifier.Verdict

    // MARK: terminal evidence is authoritative

    func test_terminated_overrides_everythingIncludingPasswordText() {
        // Even a string that looks exactly like a credential prompt is fatal
        // once the transport child has gone: it's post-mortem output.
        let v = ConnectPromptClassifier.classify(
            prompt: "bcourbage@192.168.2.241's password:", transportTerminated: true)
        XCTAssertEqual(v, .fatal(reason: "bcourbage@192.168.2.241's password:"))
    }

    func test_terminated_withEmptyPrompt_hasFallbackReason() {
        let v = ConnectPromptClassifier.classify(prompt: "   ", transportTerminated: true)
        XCTAssertEqual(v, .fatal(reason: "The remote connection was lost."))
    }

    // MARK: genuine credential prompts (child still alive)

    func test_passwordPrompt_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "bcourbage@192.168.2.241's password:", transportTerminated: false),
            .credential)
    }

    func test_passphrasePrompt_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Enter passphrase for key '/Users/x/.ssh/id_ed25519':",
                transportTerminated: false),
            .credential)
    }

    func test_verificationCodePrompt_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Verification code:", transportTerminated: false),
            .credential)
    }

    /// The legitimate wrong-password re-prompt path (TODO/TC11b) must survive:
    /// "please try again" is not fatal, and the "password:" tail keeps it a
    /// credential request.
    func test_permissionDeniedRetry_combinedWithPrompt_staysCredential() {
        // The denial and the re-prompt arrived in ONE chunk: show it as one
        // credential prompt (the user answers once). Contrast with the standalone
        // case below (issue #63).
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Permission denied, please try again.\r\nPassword:",
                transportTerminated: false),
            .credential)
    }

    // MARK: issue #63 — standalone retry notice folds into the next prompt

    func test_permissionDeniedRetry_standalone_isRetryNotice() {
        // No password prompt in this chunk: not a sheet to answer, a notice to
        // fold into the next (real) prompt.
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Permission denied, please try again.",
                transportTerminated: false),
            .retryNotice("Permission denied, please try again."))
    }

    func test_retryNotice_trimsSurroundingWhitespace() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "\r\nPermission denied, please try again.\r\n",
                transportTerminated: false),
            .retryNotice("Permission denied, please try again."))
    }

    func test_retryNotice_whenTerminated_isFatal_not_retry() {
        // Terminal evidence still wins: a retry line after the child is gone is
        // post-mortem output, not a live retry.
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Permission denied, please try again.", transportTerminated: true),
            .fatal(reason: "Permission denied, please try again."))
    }

    /// The notice is matched by EQUALITY, not by "please try again" substring, so
    /// unrelated keyboard-interactive/MFA text that happens to say "please try
    /// again" is NOT treated as the retry notice. Treating it as `.retryNotice`
    /// would make the driver read again without replying while ssh is waiting for
    /// the verification code, hanging the connect until the watchdog fires.
    func test_mfaPleaseTryAgainStandalone_isCredential_notRetryNotice() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Verification failed. Please try again.",
                transportTerminated: false),
            .credential)
    }

    /// A combined MFA failure + re-prompt chunk is likewise a normal credential
    /// prompt, never the retry notice.
    func test_mfaFailureCombinedWithCodePrompt_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Verification failed. Please try again.\r\nVerification code:",
                transportTerminated: false),
            .credential)
    }

    /// The canonical notice with a trailing password prompt in the same chunk is
    /// still a coalesced credential prompt (equality fails), not the notice.
    func test_permissionDeniedRetry_withTrailingPrompt_notRetryNotice() {
        guard case .credential = ConnectPromptClassifier.classify(
            prompt: "Permission denied, please try again.\r\nbcourbage@host's password:",
            transportTerminated: false) else {
            return XCTFail("expected .credential for a combined notice+prompt chunk")
        }
    }

    // MARK: host-key question

    func test_hostKeyAuthenticity_isHostKeyQuestion() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "The authenticity of host '...' can't be established.\r\n"
                    + "Are you sure you want to continue connecting (yes/no/[fingerprint])?",
                transportTerminated: false),
            .hostKeyQuestion)
    }

    /// Case + surrounding-whitespace variation of the canonical prompt still
    /// classifies as the host-key question (classify() trims + lowercases).
    func test_hostKeyQuestion_caseAndWhitespaceVariant_isHostKeyQuestion() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "\n  ARE YOU SURE you want to continue connecting (yes/no)?  \n",
                transportTerminated: false),
            .hostKeyQuestion)
    }

    // MARK: tightened host-key heuristic — credential prompts that merely mention
    // "authenticity" / "yes/no" must stay .credential (→ a MASKED field), not be
    // downgraded to a plain host-key response.

    func test_passwordPromptMentioningAuthenticity_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Enter password to verify authenticity:", transportTerminated: false),
            .credential)
    }

    func test_passwordPromptMentioningYesNo_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Password (yes/no policy):", transportTerminated: false),
            .credential)
    }

    func test_approveConnectionYesNo_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Approve this connection? yes/no", transportTerminated: false),
            .credential)
    }

    // MARK: supplemental fatal-string classification (child not yet terminated)

    func test_brokenPipe_isFatal_evenIfNotYetTerminated() {
        let prompt = "ssh_dispatch_run_fatal: Connection to 192.168.2.241 port 22: Broken pipe"
        XCTAssertEqual(
            ConnectPromptClassifier.classify(prompt: prompt, transportTerminated: false),
            .fatal(reason: prompt))
    }

    func test_connectionClosed_isFatal() {
        let prompt = "Connection closed by 192.168.2.241 port 22"
        XCTAssertEqual(
            ConnectPromptClassifier.classify(prompt: prompt, transportTerminated: false),
            .fatal(reason: prompt))
    }

    func test_connectionReset_refused_timedOut_areFatal() {
        for text in ["Connection reset by peer",
                     "ssh: connect to host x port 22: Connection refused",
                     "ssh: connect to host x port 22: Operation timed out",
                     "ssh: connect to host x port 22: No route to host"] {
            guard case .fatal = ConnectPromptClassifier.classify(
                prompt: text, transportTerminated: false) else {
                return XCTFail("expected .fatal for \(text)")
            }
        }
    }

    func test_hostKeyChanged_isFatal() {
        let prompt = "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"
        guard case .fatal = ConnectPromptClassifier.classify(
            prompt: prompt, transportTerminated: false) else {
            return XCTFail("expected .fatal")
        }
    }

    // MARK: default

    func test_unrecognizedLiveString_defaultsToCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Please authenticate:", transportTerminated: false),
            .credential)
    }

    // MARK: corrections (issue #35 correction 1)

    /// Keyboard-interactive / PAM text containing "connection to …" must NOT be
    /// classified fatal — this is the regression the removed "connection to "
    /// marker would have caused. It's a live prompt the user answers.
    func test_pamApproveConnection_isCredential_notFatal() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Approve this connection to gateway.example.com from 10.0.0.5?",
                transportTerminated: false),
            .credential)
    }

    /// A Duo-style keyboard-interactive MFA prompt is a credential prompt.
    func test_keyboardInteractiveMFA_isCredential() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Duo two-factor login for bcourbage\r\n\r\n"
                    + "Enter a passcode or select one of the following options:\r\n1. Duo Push",
                transportTerminated: false),
            .credential)
    }

    /// Fatal text carrying auth-method names ("password", "keyboard-interactive")
    /// must be fatal once the child terminated — terminal evidence is
    /// authoritative and the substrings do not flip it to a credential prompt.
    func test_permissionDeniedMethodList_terminated_isFatal() {
        let prompt = "Permission denied (publickey,password,keyboard-interactive)."
        XCTAssertEqual(
            ConnectPromptClassifier.classify(prompt: prompt, transportTerminated: true),
            .fatal(reason: prompt))
    }

    /// A generic "password" substring inside an UNMISTAKABLE fatal transport
    /// message must not suppress the fatal verdict, even without terminal
    /// evidence (fatal-transport is checked before any credential heuristic).
    func test_fatalTransportWithPasswordSubstring_notSuppressed() {
        let prompt = "packet_write_wait: Connection to 10.0.0.5 port 22: "
            + "Broken pipe (while waiting for password)"
        XCTAssertEqual(
            ConnectPromptClassifier.classify(prompt: prompt, transportTerminated: false),
            .fatal(reason: prompt))
    }

    /// ssh_exchange_identification failure (peer reset during banner) is fatal.
    func test_sshExchangeIdentification_isFatal() {
        guard case .fatal = ConnectPromptClassifier.classify(
            prompt: "ssh_exchange_identification: read: Connection reset by peer",
            transportTerminated: false) else {
            return XCTFail("expected .fatal")
        }
    }
}
