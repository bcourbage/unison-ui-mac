import XCTest
@testable import unison_ui_mac

/// Deterministic coverage for the opt-in probe timing recorder
/// (VersionCheck.ProbeTiming) and the executor's timing behavior, plus two
/// test-only seams that delay wait-task entry and exit observation so the
/// diagnostics can be checked against a known cause.
///
/// These are diagnostic tests, not reproductions of the historical intermittent
/// timeout. They add no waitpid caller and change no production deadline or
/// verdict.
final class ProbeTimingTests: XCTestCase {
    private typealias Timing = VersionCheck.ProbeTiming
    private typealias Exec = VersionCheck.SubprocessProbeExecutor

    private func sh(_ script: String) -> VersionCheck.ProbeConfig {
        VersionCheck.ProbeConfig(executable: "/bin/sh", arguments: ["-c", script], host: "local")
    }

    // MARK: capture helpers

    /// Points UUM_PROBE_TIMING_FILE at a fresh temp file for the duration of
    /// `body`, then returns the lines written there. Restores the previous value.
    /// Tests run serially, so the global value is safe to swap and restore.
    private func withTimingFile(_ body: () -> Void) -> [String] {
        let path = NSTemporaryDirectory() + "pt-\(UUID().uuidString).log"
        let prev = getenv("UUM_PROBE_TIMING_FILE").map { String(cString: $0) }
        setenv("UUM_PROBE_TIMING_FILE", path, 1)
        body()
        if let prev { setenv("UUM_PROBE_TIMING_FILE", prev, 1) } else { unsetenv("UUM_PROBE_TIMING_FILE") }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return text.split(separator: "\n").map(String.init)
    }

    /// The largest recorded offset (ms) for a named mark across the given lines.
    /// The late-exit line carries the complete event set, so the max is the
    /// event's real offset.
    private func offset(_ mark: String, _ lines: [String]) -> Double? {
        var best: Double?
        for line in lines {
            for field in line.split(separator: " ") where field.hasPrefix("\(mark)=") {
                if let v = Double(field.dropFirst(mark.count + 1).dropLast(2)) { best = max(best ?? v, v) }
            }
        }
        return best
    }

    private func ids(_ lines: [String]) -> [String] {
        lines.compactMap { line in idOf(line) }
    }

    private func idOf(_ line: String) -> String? {
        line.split(separator: " ").first { $0.hasPrefix("id=") }.map(String.init)
    }

    private func firstLine(inFile path: String, containing s: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n").map(String.init).first { $0.contains(s) }
    }

    /// Polls a file for a line containing `s`, up to a generous timeout (this is
    /// the test's own failure timeout, not a behavioral bound).
    private func waitForLine(inFile path: String, containing s: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = firstLine(inFile: path, containing: s) { return line }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return firstLine(inFile: path, containing: s)
    }

    /// Carries a RawExecResult out of a background dispatch; the surrounding
    /// semaphore provides the happens-before.
    private final class ResultBox: @unchecked Sendable {
        var value: VersionCheck.RawExecResult = .cancelled
    }

    // MARK: 1. recorder scenarios

    func test_recorder_exitBeforeReturn_isOneLine_withExit() {
        let lines = withTimingFile {
            let t = Timing()
            t.begin(executable: "/bin/sh", deadline: 1)
            t.mark("launch"); t.mark("waitTaskEntry"); t.mark("waitUntilExitReturn")
            t.setResult("exited(0)")
            t.emit()                  // exit already recorded: single line
            t.noteWaitTaskComplete()  // nothing to preserve
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("phase=return"))
        XCTAssertTrue(lines[0].contains("waitUntilExitReturn="))
        XCTAssertEqual(Set(ids(lines)).count, 1)
    }

    func test_recorder_exitAfterReturn_emitsCorrelatedLateExit_preservingExit() {
        let lines = withTimingFile {
            let t = Timing()
            t.begin(executable: "/bin/sh", deadline: 1)
            t.mark("launch"); t.mark("waitTaskEntry")
            t.setResult("timedOut")
            t.emit()                  // return WITHOUT the exit observed yet
            t.mark("waitUntilExitReturn"); t.mark("exitedSemaphoreSignal")
            t.noteWaitTaskComplete()  // the exit arrived late: preserve it
        }
        XCTAssertEqual(lines.count, 2)
        let ret = lines.first { $0.contains("phase=return") }
        let late = lines.first { $0.contains("phase=late-exit") }
        XCTAssertNotNil(ret); XCTAssertNotNil(late)
        XCTAssertFalse(ret!.contains("waitUntilExitReturn="), "the return line predates the exit")
        XCTAssertTrue(late!.contains("waitUntilExitReturn="), "the late-exit line preserves the exit event")
        XCTAssertEqual(Set(ids(lines)).count, 1, "return and late-exit share one correlation id")
    }

    func test_recorder_noteBeforeEmit_isOneLine_withExit() {
        // The wait task completes before the executor returns: no separate line,
        // and the exit is included in the single return line.
        let lines = withTimingFile {
            let t = Timing()
            t.begin(executable: "/bin/sh", deadline: 1)
            t.mark("launch"); t.mark("waitTaskEntry"); t.mark("waitUntilExitReturn")
            t.noteWaitTaskComplete()  // primary not emitted yet: no-op
            t.emit()
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("phase=return"))
        XCTAssertTrue(lines[0].contains("waitUntilExitReturn="))
    }

    func test_recorder_exitArrivalRacingEmission_holdInvariants() {
        // The exit ARRIVING (the wait task marking waitUntilExitReturn) races the
        // executor's emission, the interleaving that matters. Under any order:
        // exactly one return line, the exit preserved somewhere (the return line
        // if emission lost the race, else a correlated late-exit line), and no
        // crash. If emission wins and the late-exit path were removed, the exit
        // would be dropped here.
        for _ in 0..<500 {
            let lines = withTimingFile {
                let t = Timing()
                t.begin(executable: "/bin/sh", deadline: 1)
                t.mark("launch"); t.mark("waitTaskEntry")
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { t.mark("waitUntilExitReturn"); t.noteWaitTaskComplete(); g.leave() }
                g.enter(); DispatchQueue.global().async { t.emit(); g.leave() }
                g.wait()
            }
            XCTAssertEqual(lines.filter { $0.contains("phase=return") }.count, 1, "exactly one return line under the race")
            XCTAssertTrue(lines.contains { $0.contains("waitUntilExitReturn=") }, "exit arrival preserved under the race")
            XCTAssertLessThanOrEqual(lines.count, 2, "at most a return line and one late-exit line")
        }
    }

    func test_executor_cancellation_realRecord_containsCancelSIGTERM() {
        // Drive the REAL executor's cancellation path (not a hand-built record),
        // so removing the executor's cancelSIGTERM mark would fail this test.
        let path = NSTemporaryDirectory() + "cancel-\(UUID().uuidString).log"
        let prevOn = getenv("UUM_PROBE_TIMING").map { String(cString: $0) }
        let prevFile = getenv("UUM_PROBE_TIMING_FILE").map { String(cString: $0) }
        setenv("UUM_PROBE_TIMING", "1", 1)
        setenv("UUM_PROBE_TIMING_FILE", path, 1)
        defer {
            if let prevOn { setenv("UUM_PROBE_TIMING", prevOn, 1) } else { unsetenv("UUM_PROBE_TIMING") }
            if let prevFile { setenv("UUM_PROBE_TIMING_FILE", prevFile, 1) } else { unsetenv("UUM_PROBE_TIMING_FILE") }
            try? FileManager.default.removeItem(atPath: path)
        }
        let launched = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let exec = Exec(deadlinePollInterval: 0.02, grace: 0.3, outputSettle: 0.3,
                        onLaunch: { _ in launched.signal() })
        let canceller = VersionCheck.ProbeCanceller()
        // Controlled child: prints a line, then stays alive so it is cancelled
        // while running. Its stdout closes only when the cancel kills it, so the
        // cancel signal precedes the EOF.
        let cfg = sh("printf READY; sleep 10")
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = exec.execute(cfg, deadline: 30, canceller: canceller)
            done.signal()
        }
        XCTAssertEqual(launched.wait(timeout: .now() + 10), .success, "child launched")
        canceller.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "executor returned after cancel")
        XCTAssertEqual(box.value, .cancelled)

        let lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        XCTAssertTrue(lines.contains { $0.contains("result=cancelled") && $0.contains("cancelSIGTERM=") },
                      "the executor's own cancellation record contains cancelSIGTERM")
        if let cancel = offset("cancelSIGTERM", lines), let eof = offset("stdoutEOF", lines) {
            XCTAssertLessThanOrEqual(cancel, eof, "the cancel signal precedes the EOF it caused")
        }
    }

    func test_recorder_correlationIds_areDistinctPerInstance() {
        let lines = withTimingFile {
            for _ in 0..<3 {
                let t = Timing(); t.begin(executable: "/bin/sh", deadline: 1)
                t.mark("launch"); t.mark("waitUntilExitReturn"); t.emit()
            }
        }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(Set(ids(lines)).count, 3, "each probe has a distinct id")
    }

    // MARK: 2. timing disabled

    func test_timingDisabled_writesNoRecord_andBehaviorUnchanged() {
        let prevOn = getenv("UUM_PROBE_TIMING").map { String(cString: $0) }
        let prevFile = getenv("UUM_PROBE_TIMING_FILE").map { String(cString: $0) }
        let path = NSTemporaryDirectory() + "disabled-\(UUID().uuidString).log"
        unsetenv("UUM_PROBE_TIMING")               // disable for this test
        setenv("UUM_PROBE_TIMING_FILE", path, 1)   // set, but disabled must ignore it
        defer {
            if let prevOn { setenv("UUM_PROBE_TIMING", prevOn, 1) } else { unsetenv("UUM_PROBE_TIMING") }
            if let prevFile { setenv("UUM_PROBE_TIMING_FILE", prevFile, 1) } else { unsetenv("UUM_PROBE_TIMING_FILE") }
            try? FileManager.default.removeItem(atPath: path)
        }
        let exec = Exec(deadlinePollInterval: 0.02, grace: 0.3, outputSettle: 0.3)

        guard case .exited(let s, let out, _) = exec.execute(sh("printf hi"), deadline: 5,
                                                             canceller: VersionCheck.ProbeCanceller())
        else { return XCTFail("success path changed") }
        XCTAssertEqual(s, 0); XCTAssertEqual(out, "hi")

        guard case .timedOut = exec.execute(sh("printf x; sleep 5"), deadline: 0.3,
                                            canceller: VersionCheck.ProbeCanceller())
        else { return XCTFail("timeout path changed") }

        let c = VersionCheck.ProbeCanceller(); c.cancel()
        XCTAssertEqual(exec.execute(sh("echo hi"), deadline: 5, canceller: c), .cancelled)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "timing disabled must write no file")
    }

    // MARK: 3. test-only delay seams

    private enum Stage { case entry, exit }

    /// Runs the executor with a seam that BLOCKS until the executor has already
    /// returned, then releases it and waits (generously) for the late-exit line.
    /// The executor returning while the hook is still blocked is the proof that
    /// its return is independent of the delayed background task — no timing
    /// threshold. A return that instead waited for the background task would
    /// block here and fail the test's own 10 s guard.
    private func runBlockingSeam(_ stage: Stage)
        -> (returnLine: String?, lateLine: String?, result: VersionCheck.RawExecResult) {
        let path = NSTemporaryDirectory() + "seam-\(UUID().uuidString).log"
        let prevOn = getenv("UUM_PROBE_TIMING").map { String(cString: $0) }
        let prev = getenv("UUM_PROBE_TIMING_FILE").map { String(cString: $0) }
        setenv("UUM_PROBE_TIMING", "1", 1)
        setenv("UUM_PROBE_TIMING_FILE", path, 1)
        defer {
            if let prevOn { setenv("UUM_PROBE_TIMING", prevOn, 1) } else { unsetenv("UUM_PROBE_TIMING") }
            if let prev { setenv("UUM_PROBE_TIMING_FILE", prev, 1) } else { unsetenv("UUM_PROBE_TIMING_FILE") }
            try? FileManager.default.removeItem(atPath: path)
        }
        let release = DispatchSemaphore(value: 0)
        let hook: @Sendable () -> Void = { release.wait() }
        var exec = Exec(deadlinePollInterval: 0.02, grace: 0.2, outputSettle: 0.2)
        switch stage {
        case .entry: exec.waitTaskEntryHook = hook
        case .exit:  exec.exitObservationHook = hook
        }
        let cfg = sh("echo done")
        // Returns while the hook is still blocked (deadline + reap fire without
        // the wait task signalling). The primary line is written in execute()'s
        // defer, so it is already on disk here.
        let result = exec.execute(cfg, deadline: 0.3, canceller: VersionCheck.ProbeCanceller())
        let returnLine = firstLine(inFile: path, containing: "phase=return")
        release.signal()   // the wait task now finishes and writes the late line
        let lateLine = waitForLine(inFile: path, containing: "phase=late-exit", timeout: 10)
        return (returnLine, lateLine, result)
    }

    func test_seam_delayedWaitTaskEntry_returnsIndependently_lateRecordShowsEntry() {
        let (ret, late, result) = runBlockingSeam(.entry)
        guard case .timedOut = result else { return XCTFail("\(result)") }
        XCTAssertNotNil(ret, "the return line was written before the wait task was released")
        XCTAssertNotNil(late, "the late-exit line is written once the hook is released")
        guard let ret, let late else { return }
        // The delayed stage is wait-task ENTRY: the return line predates the
        // entry mark; the late line carries it (and the exit).
        XCTAssertFalse(ret.contains("waitTaskEntry="), "the wait task had not entered when the executor returned")
        XCTAssertTrue(late.contains("waitTaskEntry="), "entry is recorded once the hook is released")
        XCTAssertTrue(late.contains("waitUntilExitReturn="), "the exit is preserved in the late record")
        XCTAssertEqual(idOf(ret), idOf(late), "return and late-exit share a correlation id")
    }

    func test_seam_delayedExitObservation_returnsIndependently_lateRecordShowsExit() {
        let (ret, late, result) = runBlockingSeam(.exit)
        guard case .timedOut = result else { return XCTFail("\(result)") }
        XCTAssertNotNil(ret); XCTAssertNotNil(late)
        guard let ret, let late else { return }
        // The delayed stage is EXIT observation: entry was recorded before the
        // return; the exit appears only in the late record.
        XCTAssertTrue(ret.contains("waitTaskEntry="), "the wait task entered promptly")
        XCTAssertFalse(ret.contains("waitUntilExitReturn="), "the exit was not observed by return")
        XCTAssertTrue(late.contains("waitUntilExitReturn="), "the exit is preserved in the late record")
        XCTAssertEqual(idOf(ret), idOf(late), "return and late-exit share a correlation id")
    }
}
