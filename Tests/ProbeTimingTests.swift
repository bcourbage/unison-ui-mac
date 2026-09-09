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
        lines.compactMap { line in line.split(separator: " ").first { $0.hasPrefix("id=") }.map(String.init) }
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

    func test_recorder_concurrentEmitAndNote_holdInvariants() {
        // emit() and noteWaitTaskComplete() racing must never crash, never
        // produce two return lines, and never drop the exit event.
        for _ in 0..<200 {
            let lines = withTimingFile {
                let t = Timing()
                t.begin(executable: "/bin/sh", deadline: 1)
                t.mark("launch"); t.mark("waitTaskEntry"); t.mark("waitUntilExitReturn")
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { t.emit(); g.leave() }
                g.enter(); DispatchQueue.global().async { t.noteWaitTaskComplete(); g.leave() }
                g.wait()
            }
            XCTAssertEqual(lines.filter { $0.contains("phase=return") }.count, 1, "exactly one return line")
            XCTAssertTrue(lines.contains { $0.contains("waitUntilExitReturn=") }, "exit preserved")
            XCTAssertEqual(lines.count, 1, "exit already recorded, so no late-exit line")
        }
    }

    func test_recorder_cancellation_recordsCancelSIGTERM_beforeEOF() {
        let lines = withTimingFile {
            let t = Timing()
            t.begin(executable: "/bin/sh", deadline: 60)
            t.mark("launch"); t.mark("waitTaskEntry")
            t.mark("cancelSIGTERM")        // the cancel-triggered signal
            t.mark("stdoutEOF")            // output closed as a consequence
            t.mark("waitUntilExitReturn")  // the reaped child's exit, seen before return
            t.setResult("cancelled")
            t.emit(); t.noteWaitTaskComplete()
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("result=cancelled"))
        XCTAssertTrue(lines[0].contains("cancelSIGTERM="))
        let cancel = offset("cancelSIGTERM", lines), eof = offset("stdoutEOF", lines)
        XCTAssertNotNil(cancel); XCTAssertNotNil(eof)
        XCTAssertLessThanOrEqual(cancel ?? .infinity, eof ?? 0, "the cancel signal precedes the EOF it caused")
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

    /// Runs the executor with the given seam configured, capturing this probe's
    /// timing lines. Polls (bounded) for the late-exit line the background task
    /// writes after the executor returns, so the record is complete before the
    /// env is restored.
    private func runSeam(_ configure: (inout Exec) -> Void)
        -> (lines: [String], result: VersionCheck.RawExecResult, elapsed: TimeInterval) {
        let path = NSTemporaryDirectory() + "seam-\(UUID().uuidString).log"
        // Enable the executor's timing explicitly (do not depend on another test
        // class's bootstrap having run first), and point it at our temp file.
        let prevOn = getenv("UUM_PROBE_TIMING").map { String(cString: $0) }
        let prev = getenv("UUM_PROBE_TIMING_FILE").map { String(cString: $0) }
        setenv("UUM_PROBE_TIMING", "1", 1)
        setenv("UUM_PROBE_TIMING_FILE", path, 1)
        var exec = Exec(deadlinePollInterval: 0.02, grace: 0.2, outputSettle: 0.2)
        configure(&exec)
        let start = Date()
        let result = exec.execute(sh("echo done"), deadline: 0.3, canceller: VersionCheck.ProbeCanceller())
        let elapsed = Date().timeIntervalSince(start)
        let poll = Date().addingTimeInterval(3)
        while Date() < poll {
            if let t = try? String(contentsOfFile: path, encoding: .utf8), t.contains("phase=late-exit") { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if let prevOn { setenv("UUM_PROBE_TIMING", prevOn, 1) } else { unsetenv("UUM_PROBE_TIMING") }
        if let prev { setenv("UUM_PROBE_TIMING_FILE", prev, 1) } else { unsetenv("UUM_PROBE_TIMING_FILE") }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return (text.split(separator: "\n").map(String.init), result, elapsed)
    }

    func test_seam_delayedWaitTaskEntry_returnsBounded_diagnosisShowsLateEntry() {
        let (lines, result, elapsed) = runSeam { $0.waitTaskEntryHook = { Thread.sleep(forTimeInterval: 1.2) } }
        guard case .timedOut = result else { return XCTFail("\(result)") }
        XCTAssertLessThan(elapsed, 2.5, "the executor return is bounded, not blocked on the delayed wait task")
        let entry = offset("waitTaskEntry", lines)
        XCTAssertNotNil(entry, "wait-task entry is recorded (via the late-exit line)")
        XCTAssertGreaterThan(entry ?? 0, 1000, "wait-task ENTRY is the delayed stage")
    }

    func test_seam_delayedExitObservation_returnsBounded_diagnosisShowsLateExit() {
        let (lines, result, elapsed) = runSeam { $0.exitObservationHook = { Thread.sleep(forTimeInterval: 1.2) } }
        guard case .timedOut = result else { return XCTFail("\(result)") }
        XCTAssertLessThan(elapsed, 2.5, "the executor return is bounded")
        let entry = offset("waitTaskEntry", lines)
        let exitReturn = offset("waitUntilExitReturn", lines)
        XCTAssertNotNil(entry); XCTAssertLessThan(entry ?? .infinity, 300, "wait-task entry was prompt")
        XCTAssertNotNil(exitReturn, "the exit observation is recorded via the late-exit line")
        XCTAssertGreaterThan(exitReturn ?? 0, 1000, "EXIT OBSERVATION is the delayed stage")
        XCTAssertTrue(lines.contains { $0.contains("phase=late-exit") }, "a correlated late-exit line was written")
    }
}
