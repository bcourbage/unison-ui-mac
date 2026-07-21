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
    func test_permissionDeniedRetry_staysCredential_notFatal() {
        XCTAssertEqual(
            ConnectPromptClassifier.classify(
                prompt: "Permission denied, please try again.\r\nPassword:",
                transportTerminated: false),
            .credential)
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
}
