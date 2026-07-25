import XCTest
@testable import unison_ui_mac

/// Phase 1a (issue #24): the `ssh -G` parser + transport-ownership classifier,
/// plus the lifecycle-owned subprocess executor. The classifier FAILS CLOSED —
/// only a genuine, complete `ssh -G` result may authorize SIGKILL-based
/// interruption; empty/truncated/garbage output is unsupported (round-2 High).
/// The executor owns a monotonic deadline and a SIGTERM→grace→SIGKILL→reap
/// teardown so a wedged `ssh -G` cannot outlive the bounded call (round-2 Med).
final class SSHTransportQualifierTests: XCTestCase {

    private typealias Q = SSHTransportQualifier
    private typealias Cfg = SSHEffectiveConfig

    /// A complete, direct `ssh -G` config (all witness fields resolved).
    private func complete(controlMaster: String = "none", controlPath: String = "none",
                          proxyCommand: String = "none", proxyJump: String = "none") -> Cfg {
        Cfg(hostname: "demeter.local", user: "bcourbage", port: "22",
            controlMaster: controlMaster, controlPath: controlPath,
            proxyCommand: proxyCommand, proxyJump: proxyJump)
    }

    private let directDump = """
    host demeter
    hostname demeter.local
    user bcourbage
    port 22
    controlmaster none
    controlpath none
    """

    // MARK: - parse

    func test_parse_resolvesWitnessFields() {
        let cfg = Cfg.parse(directDump)
        XCTAssertEqual(cfg.hostname, "demeter.local")
        XCTAssertEqual(cfg.user, "bcourbage")
        XCTAssertEqual(cfg.port, "22")
        XCTAssertEqual(cfg.controlMaster, "none")
        XCTAssertEqual(cfg.controlPath, "none")
    }

    func test_parse_multiplexed() {
        let cfg = Cfg.parse("controlmaster auto\ncontrolpath /tmp/ssh-%r@%h:%p")
        XCTAssertEqual(cfg.controlMaster, "auto")
        XCTAssertEqual(cfg.controlPath, "/tmp/ssh-%r@%h:%p")
    }

    func test_parse_valuelessLineIsSkipped() {
        // A truncated line with a key but no value must not register a field.
        let cfg = Cfg.parse("hostname\nuser bcourbage")
        XCTAssertNil(cfg.hostname)
        XCTAssertEqual(cfg.user, "bcourbage")
    }

    // MARK: - isComplete witness

    func test_isComplete_trueForFullDump() {
        XCTAssertTrue(Cfg.parse(directDump).isComplete)
    }

    func test_isComplete_falseForEmpty() {
        XCTAssertFalse(Cfg().isComplete)
        XCTAssertFalse(Cfg.parse("").isComplete)
    }

    func test_isComplete_falseWhenMissingUser() {
        var cfg = complete(); cfg.user = nil
        XCTAssertFalse(cfg.isComplete)
    }

    func test_isComplete_falseWhenPortNonNumeric() {
        var cfg = complete(); cfg.port = "twenty-two"
        XCTAssertFalse(cfg.isComplete)
    }

    // MARK: - classify: fail closed on incomplete/garbage (round-2 High)

    func test_classify_empty_isUnsupported() {   // REVERSED from the old blessing
        XCTAssertFalse(Q.classify(Cfg(), customSshCmd: false).isSupported)
    }

    func test_classify_garbageOutput_isUnsupported() {
        let cfg = Cfg.parse("total gibberish\nno colon here either\n42")
        XCTAssertFalse(Q.classify(cfg, customSshCmd: false).isSupported)
    }

    func test_classify_incompleteMissingField_isUnsupported() {
        var cfg = complete(); cfg.controlMaster = nil     // witness field absent
        XCTAssertFalse(Q.classify(cfg, customSshCmd: false).isSupported)
    }

    // MARK: - classify: supported

    func test_classify_completeDirect_isSupported() {
        XCTAssertEqual(Q.classify(complete(), customSshCmd: false), .supportedDirect)
    }

    func test_classify_parseThenClassify_directEndToEnd() {
        XCTAssertEqual(Q.classify(Cfg.parse(directDump), customSshCmd: false), .supportedDirect)
    }

    // MARK: - classify: unsupported transport shapes

    func test_classify_controlMaster_unsupported() {
        XCTAssertFalse(Q.classify(complete(controlMaster: "auto"), customSshCmd: false).isSupported)
    }

    func test_classify_controlPath_unsupported() {
        XCTAssertFalse(Q.classify(complete(controlPath: "/tmp/mux"), customSshCmd: false).isSupported)
    }

    func test_classify_proxyCommand_unsupported() {
        XCTAssertFalse(Q.classify(complete(proxyCommand: "nc %h %p"), customSshCmd: false).isSupported)
    }

    func test_classify_proxyJump_unsupported() {
        XCTAssertFalse(Q.classify(complete(proxyJump: "jump.example.com"), customSshCmd: false).isSupported)
    }

    func test_classify_customSshCmd_unsupported_evenIfConfigComplete() {
        XCTAssertFalse(Q.classify(complete(), customSshCmd: true).isSupported)
    }

    // MARK: - qualify: executor-result routing (fake executor, deterministic)

    private final class FakeExec: SSHConfigExecutor, @unchecked Sendable {
        let result: SSHConfigResult
        private(set) var invoked = false
        init(_ r: SSHConfigResult) { result = r }
        func run(_ config: SSHProbeConfig, deadline: TimeInterval,
                 canceller: VersionCheck.ProbeCanceller) -> SSHConfigResult {
            invoked = true; return result
        }
    }

    private func qualify(_ r: SSHConfigResult, customSshCmd: Bool = false) -> SSHTransportQualification {
        Q.qualify(host: "demeter", customSshCmd: customSshCmd, executor: FakeExec(r))
    }

    func test_qualify_launchFailure_isUnsupported() {
        XCTAssertFalse(qualify(.launchFailed("no such file")).isSupported)
    }

    func test_qualify_timeout_isUnsupported() {
        XCTAssertFalse(qualify(.timedOut).isSupported)
    }

    func test_qualify_cancelled_isUnsupported() {
        XCTAssertFalse(qualify(.cancelled).isSupported)
    }

    func test_qualify_nonzeroExit_isUnsupported() {
        XCTAssertFalse(qualify(.exited(status: 255, stdout: "")).isSupported)
    }

    func test_qualify_emptyOutput_isUnsupported() {   // exit 0 but no resolved config
        XCTAssertFalse(qualify(.exited(status: 0, stdout: "")).isSupported)
    }

    func test_qualify_successfulDirect_isSupported() {
        XCTAssertEqual(qualify(.exited(status: 0, stdout: directDump)), .supportedDirect)
    }

    func test_qualify_successMultiplexed_isUnsupported() {
        let mux = directDump + "\ncontrolmaster auto\ncontrolpath /tmp/mux"
        XCTAssertFalse(qualify(.exited(status: 0, stdout: mux)).isSupported)
    }

    func test_qualify_customSshCmd_shortCircuits_withoutRunning() {
        let fake = FakeExec(.exited(status: 0, stdout: directDump))
        let q = Q.qualify(host: "demeter", customSshCmd: true, executor: fake)
        XCTAssertFalse(q.isSupported)
        XCTAssertFalse(fake.invoked, "custom sshcmd must not spawn ssh -G")
    }

    // MARK: - real subprocess executor: teardown + deadline (deterministic)

    private typealias Exec = SubprocessSSHConfigExecutor
    private func cfg(_ exe: String, _ args: [String]) -> SSHProbeConfig {
        SSHProbeConfig(executable: exe, arguments: args, host: "test")
    }

    func test_executor_launchFailure() {
        let r = Exec().run(cfg("/nonexistent/ssh-binary", []), deadline: 2,
                           canceller: .init())
        guard case .launchFailed = r else { return XCTFail("expected launchFailed, got \(r)") }
    }

    func test_executor_nonzeroExit() {
        let r = Exec().run(cfg("/usr/bin/false", []), deadline: 5, canceller: .init())
        guard case .exited(let status, _) = r else { return XCTFail("expected exited, got \(r)") }
        XCTAssertNotEqual(status, 0)
    }

    func test_executor_emptyOutput() {
        let r = Exec().run(cfg("/usr/bin/true", []), deadline: 5, canceller: .init())
        XCTAssertEqual(r, .exited(status: 0, stdout: ""))
    }

    func test_executor_success_capturesStdout() {
        let r = Exec().run(cfg("/bin/echo", ["unison-ui-qualifier-probe"]), deadline: 5,
                           canceller: .init())
        guard case .exited(0, let out) = r else { return XCTFail("expected exited 0, got \(r)") }
        XCTAssertTrue(out.contains("unison-ui-qualifier-probe"))
    }

    /// A child that outlives the deadline is torn down, and the call returns
    /// promptly (well within deadline + grace) rather than blocking on the
    /// child's full lifetime.
    func test_executor_timeout_tearsDownAndReturnsBounded() {
        let start = Date()
        let r = Exec().run(cfg("/bin/sleep", ["30"]), deadline: 0.3, canceller: .init())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r, .timedOut)
        XCTAssertLessThan(elapsed, 5.0, "timeout teardown must be bounded, took \(elapsed)s")
    }

    func test_executor_preCancelled_doesNotSpawn() {
        let canceller = VersionCheck.ProbeCanceller()
        canceller.cancel()
        let r = Exec().run(cfg("/bin/sleep", ["30"]), deadline: 5, canceller: canceller)
        XCTAssertEqual(r, .cancelled)
    }
}
