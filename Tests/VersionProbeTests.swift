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
            return .timedOut(stdout: "", stderr: "")
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

    // MARK: - #149: owned-subprocess lifecycle (exit observation + coordinated teardown)

    private func sh(_ script: String) -> V.ProbeConfig {
        V.ProbeConfig(executable: "/bin/sh", arguments: ["-c", script], host: "local")
    }

    /// A nonzero exit status must be carried out of the owned child unchanged.
    /// This exercises `OwnedChildProcess.exitStatus()` (waitpid status → code),
    /// which replaced reading `Process.terminationStatus`.
    func test_realExecutor_nonzeroExitStatus_isCarried() {
        let raw = V.SubprocessProbeExecutor().execute(
            sh("printf out; printf err 1>&2; exit 7"), deadline: 10, canceller: V.ProbeCanceller())
        guard case .exited(let status, let stdout, let stderr) = raw else { return XCTFail("\(raw)") }
        XCTAssertEqual(status, 7, "the child's own nonzero status is reported verbatim")
        XCTAssertEqual(stdout, "out")
        XCTAssertEqual(stderr, "err")
    }

    /// An immediate clean exit is observed and reported without waiting out the
    /// deadline. The deadline is generous; a regression that failed to observe the
    /// exit would instead time out.
    func test_realExecutor_immediateCleanExit_isObserved() {
        let started = Date()
        let raw = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02).execute(
            sh("printf hi"), deadline: 30, canceller: V.ProbeCanceller())
        guard case .exited(let status, let stdout, _) = raw else { return XCTFail("\(raw)") }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(stdout, "hi")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "a child that exits in milliseconds must be observed promptly, not at the deadline")
    }

    /// COORDINATION INVARIANT (no signal after ownership released), deterministic.
    /// The exit-observation hook FIRST acknowledges it has been entered (which
    /// happens only AFTER the reap set `reaped`), then blocks. The test waits for
    /// that acknowledgment — establishing the ordering "child reaped" precedes any
    /// teardown, with no reliance on a deadline race — and then triggers teardown
    /// explicitly via cancel. Every teardown signal must be skipped: the injected
    /// `killFn` must record ZERO calls. Defeat proof: make `signalIfOwned` signal
    /// unconditionally (ignore `reaped`) and this records calls after reaping.
    func test_ownership_noSignalIsSentAfterReap() {
        let kills = KillRecorder()
        let hookEntered = DispatchSemaphore(value: 0)   // fires after the reap, before observation is released
        let release = DispatchSemaphore(value: 0)
        var exec = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.2, outputSettle: 0.2)
        exec.killFn = { pid, sig in kills.record(pid, sig); return 0 }   // count only; no real signal needed
        exec.exitObservationHook = { hookEntered.signal(); release.wait() }
        let canceller = V.ProbeCanceller()
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = exec.execute(self.sh("echo done"), deadline: 30, canceller: canceller)
            done.signal()
        }
        // Establish the ordering: the child has been reaped (the hook runs only
        // after the reap) before we do anything else.
        XCTAssertEqual(hookEntered.wait(timeout: .now() + 10), .success, "the child was reaped and observation is held open")
        // Now trigger teardown deterministically. Every signal must be skipped
        // because the child is already reaped.
        canceller.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "executor returned after cancel")
        guard case .cancelled = box.value else { release.signal(); return XCTFail("expected .cancelled, got \(box.value)") }
        XCTAssertEqual(kills.count(), 0, "no signal may be sent once the child has been reaped (PID could be reused)")
        release.signal()
    }

    /// [P1] Ownership must survive the executor returning and dropping its
    /// reference before the reaper runs. The reaper runs on a serial queue we
    /// block until AFTER the executor has returned, so the child is unreaped and
    /// the executor's own reference is gone. If ownership were held only by the
    /// executor (weak exit callbacks), the child would deallocate here and never
    /// be reaped. The self-retain keeps it alive; once we release the queue the
    /// reap runs and the observation hook fires — proving the owner survived and
    /// reaped the child. Defeat proof: remove the `selfRetain` assignment and this
    /// hook never fires (the owner deallocated).
    func test_ownership_survivesExecutorReturn_andStillReaps() {
        let reaper = DispatchQueue(label: "test.reaper.serial")   // serial
        let blockReaper = DispatchSemaphore(value: 0)
        reaper.async { blockReaper.wait() }                        // hog the queue: the reap cannot run yet
        let reapedByOwner = DispatchSemaphore(value: 0)
        var exec = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.1, outputSettle: 0.1)
        exec.reaperQueue = reaper
        exec.exitObservationHook = { reapedByOwner.signal() }      // runs only if the owner survived to reap
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = exec.execute(self.sh("echo done"), deadline: 0.3, canceller: V.ProbeCanceller())
            done.signal()
        }
        // Executor times out and returns (child unreaped: the reaper queue is
        // blocked), dropping its reference to the owned child.
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "executor returned while the reaper was blocked")
        guard case .timedOut = box.value else { blockReaper.signal(); return XCTFail("expected .timedOut, got \(box.value)") }
        // Release the reaper. The child must still be reaped by the owner.
        blockReaper.signal()
        XCTAssertEqual(reapedByOwner.wait(timeout: .now() + 10), .success,
                       "the owner survived the executor's return and reaped the child")
    }

    /// [P2] When `waitpid` reports the child is gone but yields no status (ECHILD
    /// or an unexpected error), the probe must be reported as a FAILURE, never as a
    /// clean exit with a fabricated status of 0 that could be classified as a
    /// verified version. The injected `waitpidFn` reaps the real child (so nothing
    /// leaks) but reports ECHILD to the executor.
    func test_realExecutor_missingExitStatus_isReportedAsFailure() {
        var exec = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.3, outputSettle: 0.3)
        // Fabricate the "gone but no status" (ECHILD) case ONLY after waitpid has
        // actually reaped this child (r == pid). While the child is still running
        // the owner makes an early probe that returns 0; pass that (and any real
        // error) through unchanged, so we neither drop ownership early nor leave
        // the child unreaped — the real reap still happens via this same call.
        exec.waitpidForTesting = { pid, st, opt in
            let r = Darwin.waitpid(pid, st, opt)
            if r == pid { errno = ECHILD; return -1 }   // reaped for real → now report no-status
            return r                                      // 0 (still running) or -1/errno passed through
        }
        // A child whose exit is DELAYED, so the early-probe (waitpid == 0) path is
        // exercised before the real exit. It prints a valid version and exits 0 —
        // which, with a fabricated status of 0, would otherwise be misclassified as
        // verified.
        let raw = exec.execute(sh("sleep 0.5; echo unison version 2.54.0"), deadline: 10, canceller: V.ProbeCanceller())
        guard case .launchFailed(let message) = raw else {
            return XCTFail("expected .launchFailed for unknown status, got \(raw)")
        }
        XCTAssertTrue(message.contains("status unavailable"), "message names the missing status: \(message)")
        // And it must NOT be classifiable as a version despite the version output.
        if case .version = V.classifyRaw(raw) { XCTFail("unknown status must never classify as a verified version") }
    }

    /// [P3] A launch-preparation failure (here, argv duplication) must fail BEFORE
    /// spawning: no child is launched (so `onLaunch` never fires) and the command
    /// is never run with truncated arguments. The injected `dup` fails on the
    /// second argument.
    func test_spawn_argvDuplicationFailure_launchesNoChild() {
        let launched = LaunchFlag()
        var exec = V.SubprocessProbeExecutor(onLaunch: { _ in launched.set() })
        let calls = Counter()
        exec.dupForTesting = { s in
            let n = calls.next()
            return n == 2 ? nil : strdup(s)   // fail duplicating the second argv entry
        }
        let raw = exec.execute(
            V.ProbeConfig(executable: "/bin/echo", arguments: ["a", "b", "c"], host: "local"),
            deadline: 5, canceller: V.ProbeCanceller())
        guard case .launchFailed = raw else { return XCTFail("expected .launchFailed, got \(raw)") }
        XCTAssertFalse(launched.wasSet(), "no child may launch when argv preparation failed")
    }

    /// The complementary case: while the child is ALIVE (TERM-resistant), teardown
    /// DOES signal it — SIGTERM then SIGKILL — and the child is terminated and
    /// reaped. Proves the coordination gate does not over-suppress: signals are
    /// sent while we own the PID. The child self-limits (~10s) so nothing lingers
    /// and the test never signals a saved PID. Defeat proof: remove the SIGKILL
    /// escalation and the child stays alive across the reaping poll.
    func test_ownership_signalsSentAndChildReaped_whileAlive() {
        let kills = KillRecorder()
        let pidBox = PidBox()
        var exec = V.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.3, outputSettle: 0.5,
                                             onLaunch: { pidBox.set($0) })
        exec.killFn = { pid, sig in kills.record(pid, sig); return Darwin.kill(pid, sig) }  // count AND deliver
        let cfg = sh("trap '' TERM; printf READY; i=0; while [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done")
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = exec.execute(cfg, deadline: 0.4, canceller: V.ProbeCanceller())
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success, "executor returned via SIGKILL escalation")
        let pid = pidBox.get()
        guard case .timedOut(let stdout, _) = box.value else { return XCTFail("expected .timedOut, got \(box.value)") }
        XCTAssertGreaterThan(pid, 0, "child pid captured")
        XCTAssertTrue(stdout.contains("READY"), "child installed its TERM-ignoring trap and ran (resisted SIGTERM)")
        XCTAssertTrue(kills.sent(SIGTERM), "SIGTERM was sent while the child was alive")
        XCTAssertTrue(kills.sent(SIGKILL), "SIGKILL escalation was sent while the child was alive")
        // Terminated + reaped: the pid no longer resolves. kill(pid, 0) sends no
        // signal; poll briefly for the asynchronous reap after our SIGKILL.
        var reaped = false
        for _ in 0..<200 {   // ~4s, safely inside the child's ~10s self-limit
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { reaped = true; break }
            usleep(20_000)
        }
        XCTAssertTrue(reaped, "the TERM-resistant child was SIGKILLed and reaped (its pid no longer resolves)")
    }

    private final class ResultBox: @unchecked Sendable {
        var value: V.RawExecResult = .cancelled
    }
    private final class PidBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: pid_t = 0
        func set(_ v: pid_t) { lock.lock(); value = v; lock.unlock() }
        func get() -> pid_t { lock.lock(); defer { lock.unlock() }; return value }
    }
    /// Records the signals the executor's teardown issues (via the killFn seam).
    private final class KillRecorder: @unchecked Sendable {
        private let lock = NSLock(); private var sigs: [Int32] = []
        func record(_ pid: pid_t, _ sig: Int32) { lock.lock(); sigs.append(sig); lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return sigs.count }
        func sent(_ sig: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return sigs.contains(sig) }
    }
    private final class LaunchFlag: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        func wasSet() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
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
        XCTAssertEqual(V.classifyRaw(.timedOut(stdout: "", stderr: "")), .timedOut)
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
                          deadline: 7, executor: StubExecutor(result: .timedOut(stdout: "", stderr: "")))
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
        guard case .timedOut = result else { return XCTFail("expected .timedOut, got \(result)") }
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
