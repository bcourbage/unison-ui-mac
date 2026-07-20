import XCTest
@testable import unison_ui_mac

/// Findings #8 + #12 — SSH version-probe safety: host-trust policy, a true
/// wall-clock deadline with terminate-and-reap, probe/session identity so a
/// stale result can't update a replacement, cancellation, and distinct failure
/// classification. Orchestration is exercised with deterministic fake
/// executors; the real terminate/reap path is exercised against `/bin/sleep`.
final class VersionProbeTests: XCTestCase {
    private typealias V = VersionCheck

    private var dir: String!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VersionProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dir = url.path
    }
    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func writeProfile(_ name: String, _ contents: String) throws {
        try contents.write(toFile: "\(dir!)/\(name).prf", atomically: true, encoding: .utf8)
    }

    // MARK: - Fake executors (Sendable)

    private struct StubExecutor: V.VersionProbeExecutor {
        let result: V.RawExecResult
        func execute(_ config: V.ProbeConfig, deadline: TimeInterval,
                     isCancelled: @escaping () -> Bool) -> V.RawExecResult { result }
    }

    /// Waits until cancellation is requested (then reports `.cancelled`), or
    /// gives up after a bounded spin so a test can never hang.
    private struct BlockingExecutor: V.VersionProbeExecutor {
        func execute(_ config: V.ProbeConfig, deadline: TimeInterval,
                     isCancelled: @escaping () -> Bool) -> V.RawExecResult {
            for _ in 0..<400 {
                if isCancelled() { return .cancelled }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return .timedOut
        }
    }

    // MARK: - Finding #8: buildConfig trust policy + argv

    func test_buildConfig_usesStrictYes_notAcceptNew() {
        let root = V.SSHRoot(user: "me", host: "h", port: 2222)
        let cfg = V.buildConfig(sshcmd: nil, sshargs: "-i /k/id", sshRoot: root, servercmd: "unison")
        XCTAssertTrue(cfg.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertFalse(cfg.arguments.contains("StrictHostKeyChecking=accept-new"))
        // BatchMode + our -o options come FIRST (before profile sshargs), so
        // they win over anything sshargs sets.
        let sIdx = cfg.arguments.firstIndex(of: "StrictHostKeyChecking=yes")!
        let argsIdx = cfg.arguments.firstIndex(of: "-i")!
        XCTAssertLessThan(sIdx, argsIdx, "our -o options must precede profile sshargs")
        // Honors port, sshargs, servercmd, user@host, and the `--` separator.
        XCTAssertTrue(cfg.arguments.contains("2222"))
        XCTAssertTrue(cfg.arguments.contains("/k/id"))
        XCTAssertTrue(cfg.arguments.contains("me@h"))
        XCTAssertEqual(cfg.arguments.suffix(3), ["--", "unison", "-version"])
        XCTAssertEqual(cfg.executable, "/usr/bin/ssh")   // bare sshcmd falls back
    }

    func test_buildConfig_absoluteSshcmdHonored() {
        let root = V.SSHRoot(user: nil, host: "h", port: nil)
        let cfg = V.buildConfig(sshcmd: "/opt/bin/ssh", sshargs: nil, sshRoot: root, servercmd: "unison")
        XCTAssertEqual(cfg.executable, "/opt/bin/ssh")
        XCTAssertEqual(cfg.arguments.last, "-version")
        XCTAssertTrue(cfg.arguments.contains("h"))
    }

    // MARK: - Finding #8/#12: classifyRaw distinguishes failure kinds

    func test_classifyRaw_versionOnCleanExit() {
        XCTAssertEqual(V.classifyRaw(.exited(status: 0, stdout: "unison version 2.54.0 (ocaml 5)", stderr: "")),
                       .version("2.54.0"))
    }
    func test_classifyRaw_unparseableOnCleanExitNoVersion() {
        XCTAssertEqual(V.classifyRaw(.exited(status: 0, stdout: "hello", stderr: "")),
                       .unparseable("hello"))
    }
    func test_classifyRaw_hostKeyRejection() {
        let r = V.classifyRaw(.exited(status: 255, stdout: "", stderr: "Host key verification failed.\r\n"))
        XCTAssertEqual(r, .hostKeyRejected(stderr: "Host key verification failed.\r\n"))
    }
    func test_classifyRaw_changedHostKey() {
        let r = V.classifyRaw(.exited(status: 255, stdout: "",
            stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"))
        if case .hostKeyRejected = r {} else { XCTFail("expected hostKeyRejected, got \(r)") }
    }
    func test_classifyRaw_authFailure() {
        let r = V.classifyRaw(.exited(status: 255, stdout: "", stderr: "Permission denied (publickey)."))
        if case .authFailed = r {} else { XCTFail("expected authFailed, got \(r)") }
    }
    func test_classifyRaw_genericSshFailure() {
        let r = V.classifyRaw(.exited(status: 255, stdout: "", stderr: "kex_exchange_identification: connection reset"))
        XCTAssertEqual(r, .sshFailed(exitCode: 255, stderr: "kex_exchange_identification: connection reset"))
    }
    func test_classifyRaw_timeoutCancelLaunch() {
        XCTAssertEqual(V.classifyRaw(.timedOut), .timedOut)
        XCTAssertEqual(V.classifyRaw(.cancelled), .cancelled)
        XCTAssertEqual(V.classifyRaw(.launchFailed("x")), .launchFailed("x"))
    }

    // MARK: - runSync end-to-end with a stub executor (an ssh:// profile)

    private func sshProfile(local: String = "2.54.0") throws {
        try writeProfile("p", "root = /local\nroot = ssh://host//remote\n")
    }

    func test_runSync_match() throws {
        try sshProfile()
        let o = V.runSync(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
                          executor: StubExecutor(result: .exited(status: 0, stdout: "unison version 2.54.0", stderr: "")))
        XCTAssertEqual(o, .match(version: "2.54.0"))
    }

    func test_runSync_incompatibleMismatch() throws {
        try sshProfile()
        let o = V.runSync(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
                          executor: StubExecutor(result: .exited(status: 0, stdout: "2.51.0", stderr: "")))
        XCTAssertEqual(o, .mismatch(local: "2.54.0", remote: "2.51.0", host: "host"))
    }

    func test_runSync_timeout_isProbeFailed() throws {
        try sshProfile()
        let o = V.runSync(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
                          deadline: 7, executor: StubExecutor(result: .timedOut))
        guard case .probeFailed(let reason) = o else { return XCTFail("expected probeFailed, got \(o)") }
        XCTAssertTrue(reason.contains("timed out"), reason)
    }

    func test_runSync_hostKeyRejection_isProbeFailed_notTrusted() throws {
        try sshProfile()
        let o = V.runSync(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
                          executor: StubExecutor(result: .exited(status: 255, stdout: "", stderr: "Host key verification failed.")))
        guard case .probeFailed(let reason) = o else { return XCTFail("expected probeFailed, got \(o)") }
        XCTAssertTrue(reason.lowercased().contains("host key"), reason)
    }

    func test_runSync_authFailure_isProbeFailed() throws {
        try sshProfile()
        let o = V.runSync(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
                          executor: StubExecutor(result: .exited(status: 255, stdout: "", stderr: "Permission denied (publickey).")))
        guard case .probeFailed(let reason) = o else { return XCTFail("expected probeFailed, got \(o)") }
        XCTAssertTrue(reason.contains("auth"), reason)
    }

    // MARK: - Finding #12: identity + cancellation (async `run`)

    func test_run_currentIdentity_delivers() throws {
        try sshProfile()
        let exp = expectation(description: "delivered")
        V.run(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
              executor: StubExecutor(result: .exited(status: 0, stdout: "2.54.0", stderr: "")),
              isCurrent: { true }) { outcome in
            XCTAssertEqual(outcome, .match(version: "2.54.0"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func test_run_staleIdentity_dropsResult() throws {
        try sshProfile()
        let exp = expectation(description: "must NOT deliver")
        exp.isInverted = true
        V.run(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
              executor: StubExecutor(result: .exited(status: 0, stdout: "2.54.0", stderr: "")),
              isCurrent: { false }) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 0.6)
    }

    func test_run_cancelled_dropsLateResult() throws {
        try sshProfile()
        let exp = expectation(description: "must NOT deliver after cancel")
        exp.isInverted = true
        let handle = V.run(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
                           executor: BlockingExecutor(),
                           isCurrent: { true }) { _ in exp.fulfill() }
        handle.cancel()   // request teardown; executor observes and returns .cancelled
        wait(for: [exp], timeout: 0.8)
    }

    // MARK: - Real subprocess executor: deadline actually terminates+reaps

    func test_realExecutor_timeoutTerminatesPromptly() {
        let exec = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5)
        let cfg = V.ProbeConfig(executable: "/bin/sleep", arguments: ["5"], host: "local")
        let start = Date()
        let result = exec.execute(cfg, deadline: 0.3, isCancelled: { false })
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, .timedOut)
        // If terminate/reap didn't work we'd wait the full 5s.
        XCTAssertLessThan(elapsed, 3.0, "deadline must terminate the child, not wait for it")
    }

    func test_realExecutor_launchFailure() {
        let exec = V.SubprocessProbeExecutor()
        let cfg = V.ProbeConfig(executable: "/nonexistent/ssh", arguments: [], host: "local")
        if case .launchFailed = exec.execute(cfg, deadline: 5, isCancelled: { false }) {} else {
            XCTFail("expected launchFailed")
        }
    }

    func test_realExecutor_cleanExitCapturesStdout() {
        let exec = V.SubprocessProbeExecutor()
        let cfg = V.ProbeConfig(executable: "/bin/echo", arguments: ["unison version 2.54.0"], host: "local")
        let r = exec.execute(cfg, deadline: 5, isCancelled: { false })
        guard case .exited(let status, let stdout, _) = r else { return XCTFail("expected exited, got \(r)") }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(V.classifyRaw(.exited(status: status, stdout: stdout, stderr: "")), .version("2.54.0"))
    }

    func test_realExecutor_cancellationTerminatesPromptly() {
        let exec = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5)
        let cfg = V.ProbeConfig(executable: "/bin/sleep", arguments: ["5"], host: "local")
        let cancel = V.Handle()
        // Cancel almost immediately from another thread.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancel.cancel() }
        let start = Date()
        let result = exec.execute(cfg, deadline: 30, isCancelled: { cancel.isCancelled })
        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
    }
}
