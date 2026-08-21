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
                     canceller: V.ProbeCanceller) -> V.RawExecResult { result }
    }

    /// Blocks until cancellation is requested (waking IMMEDIATELY via the
    /// canceller's semaphore, not a spin), then reports `.cancelled`; gives up
    /// after a bounded wait so a test can never hang.
    private struct BlockingExecutor: V.VersionProbeExecutor {
        func execute(_ config: V.ProbeConfig, deadline: TimeInterval,
                     canceller: V.ProbeCanceller) -> V.RawExecResult {
            if canceller.waitForCancellation(timeout: .now() + 4) { return .cancelled }
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
        // Honors port, sshargs, servercmd, user@host.
        XCTAssertTrue(cfg.arguments.contains("2222"))
        XCTAssertTrue(cfg.arguments.contains("/k/id"))
        XCTAssertTrue(cfg.arguments.contains("me@h"))
        // `--` must come immediately BEFORE the destination (ends ssh's own
        // option parsing); the remote command AFTER the destination must be
        // exactly `servercmd -version` — no stray `--`.
        let args = cfg.arguments
        let dashIdx = args.firstIndex(of: "--")!
        let destIdx = args.firstIndex(of: "me@h")!
        XCTAssertEqual(dashIdx + 1, destIdx, "-- must immediately precede the destination")
        XCTAssertEqual(Array(args[(destIdx + 1)...]), ["unison", "-version"],
                       "remote command must be exactly servercmd -version, no leading --")
        XCTAssertFalse(Array(args[(destIdx + 1)...]).contains("--"),
                       "no `--` may appear in the remote command")
        XCTAssertEqual(cfg.executable, "/usr/bin/ssh")   // bare sshcmd falls back
    }

    /// End-to-end argv check through the REAL SubprocessProbeExecutor using a
    /// temporary fake SSH-compatible executable. The fake parses ssh-style
    /// local options, extracts the destination, and rejects a remote command
    /// with a stray leading `--`. It returns a parseable version only when the
    /// remote command is exactly `servercmd -version`. This FAILS under the old
    /// `destination -- servercmd -version` ordering (the fake sees a leading
    /// `--` remote command and exits nonzero).
    func test_realExecutor_fakeSSH_remoteCommandIsExactlyServercmdVersion() throws {
        let fake = "\(dir!)/fake-ssh"
        let script = """
        #!/bin/sh
        # Emulate ssh argument parsing: consume local options, take the first
        # non-option token as the destination, and treat the REST as the remote
        # command (verbatim, exactly like real ssh).
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) shift 2 ;;
            -p) shift 2 ;;
            -i) shift 2 ;;
            --) shift; break ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        # $1 = destination; the rest = remote command.
        shift            # drop destination
        if [ "$1" = "--" ]; then
          echo "fake-ssh: remote command has a stray leading -- : $*" >&2
          exit 2
        fi
        if [ "$1" = "servercmd" ] && [ "$2" = "-version" ] && [ $# -eq 2 ]; then
          echo "unison version 2.54.0 (ocaml 5.5.0)"
          exit 0
        fi
        echo "fake-ssh: unexpected remote command: $*" >&2
        exit 3
        """
        try script.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)

        let cfg = V.buildConfig(sshcmd: fake, sshargs: nil,
                                sshRoot: V.SSHRoot(user: "me", host: "h", port: nil),
                                servercmd: "servercmd")
        let raw = V.SubprocessProbeExecutor().execute(
            cfg, deadline: 5, canceller: V.ProbeCanceller())
        guard case .exited(let status, let stdout, let stderr) = raw else {
            return XCTFail("expected .exited, got \(raw)")
        }
        XCTAssertEqual(status, 0, "fake ssh must accept the argv; stderr: \(stderr)")
        XCTAssertEqual(V.classifyRaw(.exited(status: status, stdout: stdout, stderr: stderr)),
                       .version("2.54.0"))

        // Guard proof: the SAME fake REJECTS the old ordering
        // (`destination -- servercmd -version`), so this test genuinely fails
        // under the pre-fix argv and isn't a tautology.
        let oldOrder = V.ProbeConfig(
            executable: fake,
            arguments: ["-o", "BatchMode=yes", "me@h", "--", "servercmd", "-version"],
            host: "h")
        let oldRaw = V.SubprocessProbeExecutor().execute(
            oldOrder, deadline: 5, canceller: V.ProbeCanceller())
        guard case .exited(let oldStatus, _, _) = oldRaw else {
            return XCTFail("expected .exited for old-order argv, got \(oldRaw)")
        }
        XCTAssertNotEqual(oldStatus, 0,
                          "the old `destination -- servercmd -version` ordering must be rejected")
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
        let result = exec.execute(cfg, deadline: 0.3, canceller: V.ProbeCanceller())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, .timedOut)
        // If terminate/reap didn't work we'd wait the full 5s.
        XCTAssertLessThan(elapsed, 3.0, "deadline must terminate the child, not wait for it")
    }

    func test_realExecutor_launchFailure() {
        let exec = V.SubprocessProbeExecutor()
        let cfg = V.ProbeConfig(executable: "/nonexistent/ssh", arguments: [], host: "local")
        if case .launchFailed = exec.execute(cfg, deadline: 5, canceller: V.ProbeCanceller()) {} else {
            XCTFail("expected launchFailed")
        }
    }

    func test_realExecutor_cleanExitCapturesStdout() {
        let exec = V.SubprocessProbeExecutor()
        let cfg = V.ProbeConfig(executable: "/bin/echo", arguments: ["unison version 2.54.0"], host: "local")
        let r = exec.execute(cfg, deadline: 5, canceller: V.ProbeCanceller())
        guard case .exited(let status, let stdout, _) = r else { return XCTFail("expected exited, got \(r)") }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(V.classifyRaw(.exited(status: status, stdout: stdout, stderr: "")), .version("2.54.0"))
    }

    func test_realExecutor_cancellationTerminatesPromptly() {
        let exec = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5)
        let cfg = V.ProbeConfig(executable: "/bin/sleep", arguments: ["5"], host: "local")
        let canceller = V.ProbeCanceller()
        // Cancel almost immediately from another thread.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { canceller.cancel() }
        let start = Date()
        let result = exec.execute(cfg, deadline: 30, canceller: canceller)
        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
    }

    // MARK: - Lifecycle corrections (PR #18 review)

    /// Cancel-before-launch: a canceller already cancelled must make the
    /// executor return `.cancelled` WITHOUT launching. Proven by pointing at a
    /// nonexistent executable: if it tried to launch we'd see `.launchFailed`.
    func test_realExecutor_cancelBeforeLaunch_neverLaunches() {
        let exec = V.SubprocessProbeExecutor()
        let cfg = V.ProbeConfig(executable: "/nonexistent/ssh", arguments: [], host: "local")
        let canceller = V.ProbeCanceller()
        canceller.cancel()
        XCTAssertEqual(exec.execute(cfg, deadline: 5, canceller: canceller), .cancelled,
                       "a pre-cancelled probe must not launch (would be .launchFailed)")
    }

    /// Deterministic teardown: `cancel()` fires the registered teardown
    /// SYNCHRONOUSLY on the calling thread (not on a later poll tick).
    func test_probeCanceller_teardownFiresSynchronouslyOnCancel() {
        let canceller = V.ProbeCanceller()
        var torn = false
        canceller.registerTeardown { torn = true }
        XCTAssertFalse(torn)
        canceller.cancel()
        XCTAssertTrue(torn, "teardown must fire synchronously inside cancel()")
    }

    /// A teardown registered AFTER cancel already happened fires immediately
    /// (covers a cancel that raced Process.run()).
    func test_probeCanceller_lateTeardownRegistrationFiresImmediately() {
        let canceller = V.ProbeCanceller()
        canceller.cancel()
        var torn = false
        canceller.registerTeardown { torn = true }
        XCTAssertTrue(torn, "registering a teardown after cancel must fire it now")
    }

    /// cancel() is idempotent: the teardown fires exactly once.
    func test_probeCanceller_cancelIsIdempotent_teardownOnce() {
        let canceller = V.ProbeCanceller()
        var count = 0
        canceller.registerTeardown { count += 1 }
        canceller.cancel(); canceller.cancel(); canceller.cancel()
        XCTAssertEqual(count, 1)
    }

    /// waitForCancellation wakes immediately on cancel and times out otherwise.
    func test_probeCanceller_waitWakesOnCancel_andTimesOut() {
        let c1 = V.ProbeCanceller()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { c1.cancel() }
        XCTAssertTrue(c1.waitForCancellation(timeout: .now() + 2))

        let c2 = V.ProbeCanceller()
        XCTAssertFalse(c2.waitForCancellation(timeout: .now() + 0.1),
                       "no cancel -> wait returns false after the timeout")
    }

    /// Shutdown teardown: after cancel, the Handle's `waitUntilFinished`
    /// returns true within the grace budget (the probe body actually
    /// completed its teardown), so a quitting app doesn't exit mid-teardown.
    func test_run_shutdownWaitUntilFinished_completesAfterCancel() throws {
        try sshProfile()
        let exp = expectation(description: "must NOT deliver after cancel")
        exp.isInverted = true
        let handle = V.run(profile: "p", unisonDirectory: dir, localBridgeVersion: "2.54.0",
                           executor: BlockingExecutor(),
                           isCurrent: { true }) { _ in exp.fulfill() }
        handle.cancel()
        XCTAssertTrue(handle.waitUntilFinished(timeout: .now() + 3),
                      "probe body must finish (teardown complete) shortly after cancel")
        wait(for: [exp], timeout: 0.5)
    }
}
