import XCTest
@testable import unison_ui_mac

/// The session runner over the real subprocess executor, with /bin/sh as a
/// stand-in for ssh: child pid exposure, reaping after cancel, partial output
/// at the deadline, the marker round trip, and the ssh argument vector.
final class RemoteCheckSessionTests: XCTestCase {
    private typealias S = RemoteCheckSession

    private func sh(_ script: String) -> VersionCheck.ProbeConfig {
        VersionCheck.ProbeConfig(executable: "/bin/sh", arguments: ["-c", script], host: "local")
    }

    func test_run_exposesChildPID_andCancelReapsIt() async throws {
        let handle = S.Handle()
        let cfg = sh("sleep 30")
        let task = Task.detached {
            await S.run(config: cfg, deadline: 60, handle: handle) { record in
                VersionCheck.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5, onLaunch: record)
            }
        }
        // The pid is recorded from onLaunch right after Process.run().
        var waited = 0
        while handle.childPID == nil && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000); waited += 1
        }
        guard let pid = handle.childPID else { task.cancel(); return XCTFail("pid not recorded") }
        XCTAssertEqual(kill(pid, 0), 0, "child should be alive before cancel")
        handle.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        // Reaped: kill -0 fails with ESRCH (no such process), not EPERM/zombie.
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func test_run_deadline_returnsPartialStdout() async {
        let handle = S.Handle()
        let result = await S.run(config: sh("printf MARK-1; sleep 30"), deadline: 0.5, handle: handle) { record in
            VersionCheck.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5, outputSettle: 0.5, onLaunch: record)
        }
        guard case .timedOut(let stdout, _) = result else { return XCTFail("expected timedOut, got \(result)") }
        // The killed child closes the pipe on death, so EOF is normally reached;
        // either way the text begins with what was received.
        XCTAssertTrue(stdout.hasPrefix("MARK-1"), stdout)
        if let pid = handle.childPID {
            XCTAssertEqual(kill(pid, 0), -1, "child must be gone after the deadline")
        } else {
            XCTFail("pid not recorded")
        }
    }

    func test_run_markerRoundTrip_verifies() async {
        let marker = S.makeMarker(prefix: RemoteVerification.markerPrefix)
        let remote = RemoteVerification.remoteCommand(marker: marker, versionCommand: "echo unison version 2.54.0 \\(ocaml 5.5.0\\)")
        let result = await S.run(config: sh(remote), deadline: RemoteProbeTestSupport.functionalDeadline, handle: S.Handle())
        let o = RemoteVerification.observe(raw: result, marker: marker, deadline: RemoteProbeTestSupport.functionalDeadline)
        XCTAssertTrue(o.markerReceived)
        XCTAssertEqual(RemoteVerification.verdict(o), .verified(version: "2.54.0", firstLine: "unison version 2.54.0 (ocaml 5.5.0)"),
                       "raw=\(result) observation=\(o)")
    }

    func test_run_markerRoundTrip_commandNotFound_is127WithMarker() async {
        let marker = S.makeMarker(prefix: RemoteVerification.markerPrefix)
        let remote = RemoteVerification.remoteCommand(marker: marker, versionCommand: "/nonexistent/unison -version")
        let result = await S.run(config: sh(remote), deadline: RemoteProbeTestSupport.functionalDeadline, handle: S.Handle())
        let o = RemoteVerification.observe(raw: result, marker: marker, deadline: RemoteProbeTestSupport.functionalDeadline)
        XCTAssertTrue(o.markerReceived)
        XCTAssertEqual(o.termination, .exited(status: 127))
        XCTAssertNotNil(o.firstStderrLine)
        XCTAssertEqual(RemoteVerification.verdict(o), .notVerified)
    }

    func test_run_cancelBeforeLaunch_neverLaunches() async {
        let handle = S.Handle()
        handle.cancel()
        let result = await S.run(config: VersionCheck.ProbeConfig(executable: "/nonexistent/ssh", arguments: [], host: "x"),
                                 deadline: 5, handle: handle)
        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(handle.childPID)
    }

    // MARK: - collector lifecycle

    func test_collector_stopsAndReleases_whenADescendantKeepsThePipeOpen() async throws {
        // The child exits at once; a background subshell it started keeps
        // stdout open for 3 s. The executor must return on the child's exit
        // and leave no live collector behind.
        let exec = VersionCheck.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5, outputSettle: 0.2)
        let start = Date()
        let result = exec.execute(sh("(sleep 3; echo late) & echo early; exit 0"), deadline: RemoteProbeTestSupport.functionalDeadline, canceller: VersionCheck.ProbeCanceller())
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "must not wait for the descendant")
        guard case .exited(let status, let stdout, let stderr) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(status, 0)
        // The descendant still held both pipes when collection stopped, so
        // both transcripts carry the incompleteness marker and no truncation marker.
        XCTAssertEqual(stdout, "early\n" + VersionCheck.SubprocessProbeExecutor.incompleteSentinel)
        XCTAssertEqual(stderr, VersionCheck.SubprocessProbeExecutor.incompleteSentinel)
        XCTAssertFalse(stdout.contains(VersionCheck.SubprocessProbeExecutor.truncationSentinel))
    }

    func test_collector_eofReached_hasNoMarker() {
        let exec = VersionCheck.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5, outputSettle: 1.0)
        let result = exec.execute(sh("echo done"), deadline: RemoteProbeTestSupport.functionalDeadline, canceller: VersionCheck.ProbeCanceller())
        guard case .exited(_, let stdout, let stderr) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(stdout, "done\n")
        XCTAssertEqual(stderr, "")
    }

    func test_collector_stoppedBeforeEOF_andCapped_carryBothMarkers() {
        let exec = VersionCheck.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5, outputSettle: 0.2)
        // 2 MiB now, then a descendant keeps stdout open after the child exits.
        let result = exec.execute(sh("head -c 2097152 /dev/zero | tr '\\0' 'x'; (sleep 3) & exit 0"), deadline: RemoteProbeTestSupport.functionalDeadline, canceller: VersionCheck.ProbeCanceller())
        guard case .exited(_, let stdout, _) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(stdout.hasSuffix(VersionCheck.SubprocessProbeExecutor.truncationSentinel + VersionCheck.SubprocessProbeExecutor.incompleteSentinel))
    }

    func test_collector_stop_closesDescriptorAndAllowsDeallocation() throws {
        // Writing to a pipe whose only reader has closed raises SIGPIPE; ignore it
        // for the duration so the write returns EPIPE instead of killing the test.
        let previousSIGPIPE = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previousSIGPIPE) }

        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        var collector: VersionCheck.SubprocessProbeExecutor.PipeCollector? = .init(pipe.fileHandleForReading)
        weak var weak = collector
        pipe.fileHandleForWriting.write("partial".data(using: .utf8)!)
        // Writer stays open: no EOF. snapshot returns what arrived so far, marked incomplete.
        XCTAssertEqual(collector!.snapshot(settle: 0.2), "partial" + VersionCheck.SubprocessProbeExecutor.incompleteSentinel)
        collector!.stop()
        XCTAssertTrue(collector!.isStopped)
        collector = nil

        // stop() cancels the DispatchSource, whose cancel handler closes the read
        // descriptor ASYNCHRONOUSLY on a shared queue, so wait for it. Detect the
        // close by the pipe's reader count, not the raw fd number: once the reader
        // is gone, writing to the pipe fails with EPIPE. This is immune to another
        // thread reusing the fd number, which made the old `fcntl(fd)==-1` check
        // flake under concurrent subprocess-test load. The deadline is generous so
        // a busy cancel-handler queue does not fail a correct implementation.
        func readerClosed() -> Bool { write(writeFD, "x", 1) == -1 && errno == EPIPE }
        let deadline = Date().addingTimeInterval(15)
        while (weak != nil || !readerClosed()) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNil(weak, "collector must not be retained after stop()")
        XCTAssertTrue(readerClosed(), "read descriptor must be closed after stop()")
        try? pipe.fileHandleForWriting.close()
    }

    func test_collector_readError_isMarkedAsFailure_notEOF() {
        let pipe = Pipe()
        var calls = 0
        let collector = VersionCheck.SubprocessProbeExecutor.PipeCollector(pipe.fileHandleForReading) { fd, buf, count in
            calls += 1
            if calls == 1 { return Darwin.read(fd, buf, count) }   // deliver the real first chunk
            errno = EIO; return -1                                  // then fail
        }
        pipe.fileHandleForWriting.write("part".data(using: .utf8)!)
        let text = collector.snapshot(settle: 2.0)
        XCTAssertTrue(text.hasPrefix("part"), text)
        XCTAssertTrue(text.contains(VersionCheck.SubprocessProbeExecutor.readErrorSentinelPrefix + String(cString: strerror(EIO)) + "]"), text)
        XCTAssertFalse(text.contains(VersionCheck.SubprocessProbeExecutor.incompleteSentinel), "a read error is its own state")
        XCTAssertTrue(collector.isStopped, "a read error ends collection")
        try? pipe.fileHandleForWriting.close()
    }

    func test_collector_readErrorBeforeAnyOutput_isNotAnEmptyCompleteCapture() {
        let pipe = Pipe()
        let collector = VersionCheck.SubprocessProbeExecutor.PipeCollector(pipe.fileHandleForReading) { _, _, _ in
            errno = EIO; return -1
        }
        pipe.fileHandleForWriting.write("x".data(using: .utf8)!)   // triggers a read event
        let text = collector.snapshot(settle: 2.0)
        XCTAssertNotEqual(text, "", "the reviewer's fixture: an empty string would look like a complete capture")
        XCTAssertTrue(text.hasPrefix(VersionCheck.SubprocessProbeExecutor.readErrorSentinelPrefix), text)
        try? pipe.fileHandleForWriting.close()
    }

    func test_collector_boundsRetainedOutput() {
        let exec = VersionCheck.SubprocessProbeExecutor(deadlinePollInterval: 0.02, grace: 0.5, outputSettle: 1.0)
        // 3 MiB of output, above the 1 MiB cap.
        let result = exec.execute(sh("head -c 3145728 /dev/zero | tr '\\0' 'x'"), deadline: RemoteProbeTestSupport.functionalDeadline, canceller: VersionCheck.ProbeCanceller())
        guard case .exited(_, let stdout, _) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(stdout.hasSuffix(VersionCheck.SubprocessProbeExecutor.truncationSentinel))
        XCTAssertLessThanOrEqual(stdout.utf8.count, VersionCheck.SubprocessProbeExecutor.outputCap + VersionCheck.SubprocessProbeExecutor.truncationSentinel.utf8.count)
    }

    // MARK: - configuration

    func test_probeConfig_usesDesignArgumentVector() {
        let cmd = RemoteCommand.compose(settings: .init(servercmd: "/opt/homebrew/bin/unison", sshargs: "-i /k"),
                                        root: .shell(shell: "ssh", host: "demeter", user: "bruno", port: nil, path: "/x"),
                                        majorVersion: "2.54")!
        let cfg = S.probeConfig(command: cmd, executable: "/usr/bin/ssh", remoteCommand: "printf 'M'; /opt/homebrew/bin/unison -version")
        XCTAssertEqual(cfg.executable, "/usr/bin/ssh")
        XCTAssertEqual(cfg.host, "demeter")
        XCTAssertEqual(cfg.arguments, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
                                       "-l", "bruno", "demeter", "-e", "none", "-i", "/k",
                                       "printf 'M'; /opt/homebrew/bin/unison -version"])
    }

    func test_resolveShellCommand() {
        XCTAssertEqual(S.resolveShellCommand("/usr/bin/ssh"), .resolved("/usr/bin/ssh"))
        XCTAssertEqual(S.resolveShellCommand("ssh") { $0 == "/usr/bin/ssh" }, .resolved("/usr/bin/ssh"))
        XCTAssertEqual(S.resolveShellCommand("assh") { $0 == "/opt/homebrew/bin/assh" }, .resolved("/opt/homebrew/bin/assh"))
        XCTAssertEqual(S.resolveShellCommand("nossh") { _ in false },
                       .notFound(name: "nossh", searched: S.bareCommandDirectories))
        XCTAssertEqual(S.resolveShellCommand("bin/ssh") { _ in false }, .resolved("bin/ssh"))
        XCTAssertEqual(S.resolveShellCommand("ssh"), .resolved("/usr/bin/ssh"), "the system ssh exists on every Mac")
    }
}
