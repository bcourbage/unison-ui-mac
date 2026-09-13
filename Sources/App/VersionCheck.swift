import Foundation

/// Probes the Unison version on the remote machine of an `ssh://…`
/// profile and reports whether it matches the locally-embedded
/// version. Mismatches drive an alert in the AppDelegate; the user
/// can dismiss with "Don't Remind Me Again for this host" which
/// persists the suppression to `UserDefaults`.
///
/// **Why a separate SSH subprocess instead of asking OCaml?**
/// Unison's internal RPC handshake does exchange versions, but there's
/// no upstream-registered callback to query the cached remote version
/// from the C bridge. We could patch `uimacbridge.ml` to add one, but
/// patching upstream is off-limits for this project. The subprocess
/// is a workable alternative — fast for key-based SSH (the common
/// case), and we run it with `BatchMode=yes` so we silently bail
/// rather than double-prompting the user for a password.
///
/// **Compatibility caveats**:
/// - Honors the profile's `sshcmd` (when an absolute path) and `sshargs`
///   so the probe authenticates like Unison's real connection — notably
///   an `-i <key>` in `sshargs`, without which a key-only host fails
///   `publickey` in the probe while the sync succeeds. `sshargs` is split
///   on whitespace, so an argument with embedded spaces isn't handled; a
///   bare (non-absolute) `sshcmd` falls back to `/usr/bin/ssh`.
/// - Doesn't handle `socket://` profiles. Those skip the check (the
///   socket protocol doesn't have a `-version` shortcut we can use
///   the same way).
/// - Doesn't consider the OCaml-compiler version mismatch flagged
///   in upstream's compatibility notes (Unison 2.52+ tolerates
///   different OCaml versions on each side). We only compare the
///   Unison version number itself.
enum VersionCheck {

    /// Outcome of a version comparison. Returned to AppDelegate, which
    /// decides whether to show the alert.
    ///
    /// **Why mismatch is split into two cases.** Unison 2.52.0
    /// introduced the "new wire protocol" with feature negotiation;
    /// any pair of versions >= 2.52.0 interoperates regardless of
    /// which exact minor release each side runs. The earlier outcome
    /// model fired `.mismatch` on any non-equal pair — over-strict,
    /// and noisy for the common case of a remote one minor version
    /// behind/ahead. The split lets the UI stay quiet for the
    /// compatible-but-different case while still alerting on the
    /// real wire-protocol break (cross-2.52).
    enum Outcome: Equatable {
        /// Versions are byte-equal. Nothing to surface.
        case match(version: String)
        /// Versions differ but are on the same side of the 2.52.0
        /// wire-protocol boundary, so they negotiate and interoperate.
        /// AppDelegate logs but doesn't alert.
        case compatibleMismatch(local: String, remote: String)
        /// Versions straddle the 2.52.0 boundary. The two wire
        /// protocols don't interoperate; sync will fail with cryptic
        /// RPC errors. AppDelegate surfaces the alert (unless
        /// `Suppression.isSuppressed(...)` returns true for this triple).
        case mismatch(local: String, remote: String, host: String)
        /// Profile had no SSH-remote root, so there's nothing to check.
        case noRemoteRoot
        /// Probe was attempted but couldn't determine the remote
        /// version (SSH failed, command not found on remote, output
        /// didn't parse). Logged at .versionCheck for diagnosis;
        /// AppDelegate doesn't surface anything to the user — Unison's
        /// own connection error will speak to that if there's a real
        /// problem.
        case probeFailed(reason: String)
    }

    // MARK: - Compatibility classification

    /// Wire-protocol compatibility verdict for a pair of dotted
    /// version strings (e.g. `"2.54.0"` and `"2.53.8"`). Internal
    /// stage between `parseVersionString` and `Outcome`; tested
    /// directly so the boundary cases are nailed down.
    enum Compatibility: Equatable {
        /// Identical strings — the easy case.
        case exactMatch
        /// Both versions are >= 2.52.0; new wire protocol with
        /// feature negotiation handles the diff.
        case compatibleNewProtocol(local: String, remote: String)
        /// Both versions are < 2.52.0; old wire protocol on both
        /// sides. Rare path (anyone still on 2.51.x running this
        /// UI?) but defensible to treat as compatible since the old
        /// protocol negotiates within its own generation.
        case compatibleOldProtocol(local: String, remote: String)
        /// One side is pre-2.52.0 and the other is >= 2.52.0. The
        /// real wire-protocol break — sync cannot succeed without
        /// updating the older side.
        case incompatibleAcrossBoundary(local: String, remote: String)
    }

    /// Classify a (local, remote) pair into one of the four buckets
    /// above. Used by `runSync` to pick between `.match`,
    /// `.compatibleMismatch`, and `.mismatch` outcomes.
    ///
    /// Defensive on parse failure: if either version can't be parsed
    /// into a semver triple, treat it as "new protocol" — better to
    /// suppress a possibly-spurious alert than to alarm the user.
    /// The path to a parse failure here is already a "shouldn't
    /// happen" case (both strings come from `parseVersionString`
    /// which only returns matches against a strict regex).
    static func classify(local: String, remote: String) -> Compatibility {
        if local == remote {
            return .exactMatch
        }
        let localPre = isPre252(local)
        let remotePre = isPre252(remote)
        if localPre == remotePre {
            return localPre
                ? .compatibleOldProtocol(local: local, remote: remote)
                : .compatibleNewProtocol(local: local, remote: remote)
        }
        return .incompatibleAcrossBoundary(local: local, remote: remote)
    }

    /// True if `version` is strictly less than 2.52.0. Returns false
    /// for unparseable input (defensive: an unknown version is
    /// optimistically treated as new-protocol so we don't false-
    /// positive an incompatibility warning on garbage data).
    static func isPre252(_ version: String) -> Bool {
        guard let s = parseSemver(version) else { return false }
        if s.major < 2 { return true }
        if s.major > 2 { return false }
        return s.minor < 52
    }

    /// Parse a dotted-numeric version string into (major, minor, patch).
    /// Two-component forms like `"2.51"` get patch = 0; trailing junk
    /// after the third component is ignored. Returns nil if fewer
    /// than two components or if any component isn't a non-negative
    /// integer.
    static func parseSemver(_ version: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0
        else { return nil }
        let patch: Int
        if parts.count >= 3 {
            patch = Int(parts[2]) ?? 0
        } else {
            patch = 0
        }
        return (major, minor, patch)
    }

    // MARK: - Public entry point

    /// Run the version check for the given profile. Reads the .prf to
    /// find the first SSH-remote root + the `servercmd` pref (defaults
    /// to `unison` if not set). Spawns `ssh` to query the remote.
    /// Result is delivered via `completion` on the main queue.
    ///
    /// Safe to call on any thread; internally hops to a background
    /// queue for the subprocess and the main queue for completion.
    /// Returns a `Handle` the caller stores so it can `cancel()` the probe on
    /// abandonment, profile replacement, or shutdown. `isCurrent` is checked on
    /// the main queue immediately before delivery: a probe whose session is no
    /// longer current (e.g. the same profile was reopened as a new session)
    /// delivers NOTHING, so stale output can never update a replacement.
    @discardableResult
    static func run(
        profile: String,
        unisonDirectory: String,
        localBridgeVersion: String,
        deadline: TimeInterval = VersionCheck.defaultDeadline,
        executor: VersionProbeExecutor = SubprocessProbeExecutor(),
        isCurrent: @escaping @MainActor () -> Bool = { true },
        completion: @escaping @MainActor (Outcome) -> Void
    ) -> Handle {
        let handle = Handle()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = runSync(
                profile: profile,
                unisonDirectory: unisonDirectory,
                localBridgeVersion: localBridgeVersion,
                deadline: deadline,
                executor: executor,
                canceller: handle.canceller
            )
            // The probe body (including any teardown) has returned; unblock a
            // shutdown that is waiting for deterministic teardown.
            handle.markFinished()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Drop the result if the probe was cancelled (abandoned /
                    // profile replaced / shutdown) or its session is no longer
                    // current. A stale probe must never surface an alert or
                    // update state for a replacement profile.
                    guard !handle.isCancelled, isCurrent() else { return }
                    completion(outcome)
                }
            }
        }
        return handle
    }

    /// Synchronous variant — used by `run` after dispatching to a
    /// background queue. Exposed for tests so they can drive the
    /// logic with a known .prf text without async overhead.
    static func runSync(
        profile: String,
        unisonDirectory: String,
        localBridgeVersion: String,
        deadline: TimeInterval = VersionCheck.defaultDeadline,
        executor: VersionProbeExecutor = SubprocessProbeExecutor(),
        canceller: ProbeCanceller = ProbeCanceller()
    ) -> Outcome {
        let url = URL(fileURLWithPath: unisonDirectory)
            .appendingPathComponent("\(profile).prf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .probeFailed(reason: "couldn't read .prf at \(url.path)")
        }
        let doc = ProfileDocument.parse(text)
        let roots = doc.values(forKey: "root")
        // Find the first ssh:// root. socket:// is skipped — there's no
        // straightforward way to probe a socket-mode Unison server.
        guard let sshRoot = roots.compactMap(SSHRoot.parse).first else {
            return .noRemoteRoot
        }
        let servercmd = doc.firstValue(forKey: "servercmd") ?? "unison"
        // Honor the profile's SSH customization so the probe authenticates
        // exactly like the real sync (an `-i <key>` in sshargs is the
        // common case — without it the probe fails publickey while the
        // sync succeeds).
        let sshcmd = doc.firstValue(forKey: "sshcmd")
        let sshargs = doc.firstValue(forKey: "sshargs")

        guard let localVersion = parseVersionString(localBridgeVersion) else {
            return .probeFailed(reason: "couldn't parse local bridge version: \(localBridgeVersion)")
        }

        func clip(_ s: String) -> String {
            String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        }
        let config = buildConfig(sshcmd: sshcmd, sshargs: sshargs,
                                 sshRoot: sshRoot, servercmd: servercmd)
        let raw = executor.execute(config, deadline: deadline, canceller: canceller)

        let remoteVersion: String
        switch classifyRaw(raw) {
        case .version(let v):
            remoteVersion = v
        case .timedOut:
            return .probeFailed(reason: "ssh probe to \(sshRoot.host) timed out after \(Int(deadline))s")
        case .cancelled:
            return .probeFailed(reason: "ssh probe to \(sshRoot.host) cancelled")
        case .hostKeyRejected(let stderr):
            // Deliberately not trusted here — the real Unison connection owns
            // host-key confirmation. Advisory probe skips.
            return .probeFailed(reason: "host key for \(sshRoot.host) not trusted by advisory probe: \(clip(stderr))")
        case .authFailed(let stderr):
            return .probeFailed(reason: "ssh auth failed for \(sshRoot.host): \(clip(stderr))")
        case .sshFailed(let code, let stderr):
            return .probeFailed(reason: "ssh to \(sshRoot.host) exited \(code): \(clip(stderr))")
        case .launchFailed(let message):
            return .probeFailed(reason: "couldn't launch ssh: \(message)")
        case .unparseable(let output):
            return .probeFailed(reason: "ssh ran but output had no version: \(clip(output))")
        }

        switch classify(local: localVersion, remote: remoteVersion) {
        case .exactMatch:
            return .match(version: localVersion)
        case .compatibleNewProtocol(let l, let r),
             .compatibleOldProtocol(let l, let r):
            return .compatibleMismatch(local: l, remote: r)
        case .incompatibleAcrossBoundary(let l, let r):
            return .mismatch(local: l, remote: r, host: sshRoot.host)
        }
    }

    // MARK: - SSH URL parsing

    /// Parsed shape of an `ssh://user@host:port/path` root URL.
    /// Tests drive `SSHRoot.parse(_:)` directly.
    struct SSHRoot: Equatable {
        let user: String?
        let host: String
        let port: Int?

        /// Returns nil for non-ssh URLs (e.g. local paths, socket://,
        /// file://). Lenient parser — accepts missing user, missing
        /// port, missing path; rejects only the obviously-malformed.
        static func parse(_ root: String) -> SSHRoot? {
            let trimmed = root.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ssh://") else { return nil }
            let rest = trimmed.dropFirst("ssh://".count)
            // Path starts at the first `/` (which could also be the
            // root-level `/`). We only care about the authority part.
            let pathStart = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = Substring(rest[..<pathStart])
            if authority.isEmpty { return nil }
            var user: String? = nil
            if let at = authority.firstIndex(of: "@") {
                user = String(authority[..<at])
                authority = authority[authority.index(after: at)...]
            }
            // Optional port — last `:` separates host:port, but only
            // if the part after parses as an int.
            var host = String(authority)
            var port: Int? = nil
            if let colon = host.lastIndex(of: ":") {
                let portPart = host[host.index(after: colon)...]
                if let p = Int(portPart) {
                    port = p
                    host = String(host[..<colon])
                }
            }
            guard !host.isEmpty else { return nil }
            return SSHRoot(user: user, host: host, port: port)
        }
    }

    // MARK: - SSH probe (lifecycle-owned subprocess)

    /// Everything needed to launch the probe subprocess. Built purely from the
    /// profile (so argument construction, incl. the trust policy, is testable),
    /// then handed to an executor.
    struct ProbeConfig: Equatable {
        let executable: String
        let arguments: [String]
        /// Remote host, for logging/classification (already reflected in argv).
        let host: String
    }

    /// Raw result of executing the subprocess, before version/trust
    /// classification. The executor is responsible ONLY for launching, applying
    /// the wall-clock deadline, honoring cancellation, and terminating+reaping
    /// the exact child — it does not interpret ssh's output.
    enum RawExecResult: Equatable {
        /// Process exited on its own within the deadline.
        case exited(status: Int32, stdout: String, stderr: String)
        /// The wall-clock deadline (measured from just after launch) elapsed;
        /// the ssh child was SIGTERM'd, then SIGKILL'd, and best-effort reaped
        /// (its ProxyCommand/remote descendants are not guaranteed reaped).
        /// Carries whatever the child had written before it was torn down.
        case timedOut(stdout: String, stderr: String)
        /// Cancellation was requested; the ssh child was SIGTERM'd (synchronously
        /// at cancel time), then SIGKILL'd if needed, and best-effort reaped
        /// (same descendant caveat as `timedOut`).
        case cancelled
        /// The process could not be launched at all.
        case launchFailed(String)
    }

    /// Classified probe outcome — the distinct cases the review requires us to
    /// tell apart (timeout, cancellation, host-key rejection, auth failure,
    /// launch failure, malformed output) rather than collapsing to one string.
    enum ProbeOutcome: Equatable {
        case version(String)
        case timedOut
        case cancelled
        case hostKeyRejected(stderr: String)
        case authFailed(stderr: String)
        case sshFailed(exitCode: Int32, stderr: String)
        case launchFailed(String)
        case unparseable(String)
    }

    /// Executes a probe subprocess. Injectable so tests can drive timeout,
    /// cancellation, late completion, and stale identity deterministically
    /// without spawning `ssh`.
    protocol VersionProbeExecutor: Sendable {
        func execute(_ config: ProbeConfig,
                     deadline: TimeInterval,
                     canceller: ProbeCanceller) -> RawExecResult
    }

    /// Default wall-clock deadline for the probe's REMOTE work (I/O + remote
    /// exit), measured from just after the local `ssh` spawn returns — it does
    /// not include the (synchronous, fast) local launch. `ConnectTimeout=5`
    /// bounds only TCP/SSH connect; a wedged ProxyCommand or a hung remote
    /// `servercmd -version` needs this outer bound (Finding #12).
    static let defaultDeadline: TimeInterval = 20
    /// Grace between SIGTERM and SIGKILL when tearing a child down.
    static let terminateGrace: TimeInterval = 2

    /// Build the ssh argv for the probe. Our `-o` options come FIRST so ssh
    /// honors them over anything in the profile's `sshargs`.
    ///
    /// FINDING #8: `StrictHostKeyChecking=yes` (NOT `accept-new`). The advisory
    /// probe must never write a host key or otherwise change trust; an unknown
    /// or changed host makes the probe fail (→ we skip), leaving host-key
    /// confirmation to the real Unison connection alone. Placing it first means
    /// it wins even if the profile's `sshargs` tries to set `accept-new`, so the
    /// probe is never more permissive than the real connection.
    static func buildConfig(sshcmd: String?, sshargs: String?,
                            sshRoot: SSHRoot, servercmd: String) -> ProbeConfig {
        // A bare (non-absolute) sshcmd can't be resolved reliably from a GUI
        // app's PATH, so fall back to the system ssh.
        let sshExecutable = (sshcmd?.hasPrefix("/") == true) ? sshcmd! : "/usr/bin/ssh"
        var args: [String] = ["-o", "BatchMode=yes",
                              "-o", "ConnectTimeout=5",
                              "-o", "StrictHostKeyChecking=yes"]
        args.append(contentsOf: PrefsTokenizer.splitIntoWords(sshargs ?? ""))
        if let port = sshRoot.port {
            args.append("-p"); args.append(String(port))
        }
        // `--` ends SSH's OWN option parsing and must come BEFORE the
        // destination: ssh treats the first non-option token as the
        // destination and EVERYTHING after it as the remote command, verbatim.
        // Putting `--` after the destination (the previous ordering) made the
        // remote command literally `-- servercmd -version`, i.e. ssh asked the
        // remote shell to run `--` — wrong. With `--` before the destination,
        // ssh's options stop there, the next token is the destination, and the
        // remote command is exactly `servercmd -version`. (`--` also protects a
        // destination that begins with `-` from being read as an ssh option.)
        args.append("--")
        args.append(sshRoot.user.map { "\($0)@\(sshRoot.host)" } ?? sshRoot.host)
        args.append(servercmd)
        args.append("-version")
        return ProbeConfig(executable: sshExecutable, arguments: args, host: sshRoot.host)
    }

    /// Classify a raw execution result into a `ProbeOutcome`. Pure + tested.
    /// Host-key vs auth failures are distinguished from ssh's stderr; with
    /// `StrictHostKeyChecking=yes` an unknown/changed host prints a recognizable
    /// "Host key verification failed" line.
    static func classifyRaw(_ raw: RawExecResult) -> ProbeOutcome {
        switch raw {
        case .timedOut:            return .timedOut
        case .cancelled:           return .cancelled
        case .launchFailed(let m): return .launchFailed(m)
        case .exited(let status, let stdout, let stderr):
            if status == 0 {
                if let v = parseVersionString(stdout) { return .version(v) }
                return .unparseable(stdout)
            }
            let lower = stderr.lowercased()
            if lower.contains("host key verification failed")
                || lower.contains("remote host identification has changed")
                || lower.contains("no matching host key")
                || (lower.contains("host key") && lower.contains("changed")) {
                return .hostKeyRejected(stderr: stderr)
            }
            if lower.contains("permission denied")
                || lower.contains("authentication failed")
                || lower.contains("too many authentication failures")
                || lower.contains("publickey") {
                return .authFailed(stderr: stderr)
            }
            return .sshFailed(exitCode: status, stderr: stderr)
        }
    }

    /// Opt-in lifecycle timing for one probe execution. Enabled only when
    /// UUM_PROBE_TIMING is set in the environment; otherwise every instance is
    /// nil and every call a no-op, so production behavior is unchanged and no
    /// extra thread or syscall is introduced. It records MONOTONIC elapsed times
    /// (mach uptime) for the probe's lifecycle events.
    ///
    /// It writes a `phase=return` line when the executor returns. If that line
    /// went out WITHOUT a `terminationHandlerFired` (the executor gave up before
    /// the Process terminationHandler had observed the exit), a second
    /// `phase=late-exit` line is written when that handler finally fires,
    /// correlated by `id=`, so a delayed exit report is preserved rather than
    /// lost. A `phase=return` line with no matching `late-exit` line means only
    /// that NO LATE EXIT WAS RECORDED BEFORE OBSERVATION ENDED; it does not prove
    /// the handler never fired, since it may fire after the process stops
    /// recording (for example after the test bundle finishes). The normal path,
    /// where the exit is observed before return, stays a single line.
    ///
    /// It records an id, event names, elapsed milliseconds, and the result kind
    /// ONLY. It deliberately records no command arguments and no captured output,
    /// so enabling it cannot leak what was run or what came back. Its purpose is
    /// to separate scheduling delay from delayed exit observation when a probe
    /// whose output is already complete still reaches its deadline. It logs
    /// successful runs too, so a probe exceeding the former 10s bound stays
    /// visible even when a generous deadline lets the test pass.
    final class ProbeTiming: @unchecked Sendable {
        static func fromEnvironment() -> ProbeTiming? {
            // getenv (live) rather than ProcessInfo.environment (a cached
            // snapshot), so a test that sets the variable in-process is seen.
            getenv("UUM_PROBE_TIMING") != nil ? ProbeTiming() : nil
        }
        // A process-unique id correlating a probe's return line with its
        // late-exit line.
        private static let idLock = NSLock()
        // Guarded by idLock; nonisolated(unsafe) states that the lock, not the
        // compiler, provides the synchronization.
        nonisolated(unsafe) private static var idSeq = 0
        private static func nextID() -> Int { idLock.lock(); defer { idLock.unlock() }; idSeq += 1; return idSeq }

        let id = ProbeTiming.nextID()
        private let start = DispatchTime.now().uptimeNanoseconds
        private let lock = NSLock()
        private var events: [(String, UInt64)] = []
        private var label = ""
        private var resultKind = "unset"
        private var primaryEmitted = false
        private var primaryHadExit = false

        func begin(executable: String, deadline: TimeInterval) {
            // Basename only, and no host: the remote hostname is potentially
            // sensitive, and the arguments (the -c script) and output are never
            // recorded. In production the basename is just `ssh`.
            let name = (executable as NSString).lastPathComponent
            lock.lock(); label = "\(name) deadline=\(deadline)s"; lock.unlock()
        }
        /// Records the monotonic offset of one event. Safe to call from any
        /// thread (the wait task, a collector's read queue, the executor loop).
        func mark(_ event: String) {
            let ns = DispatchTime.now().uptimeNanoseconds &- start
            lock.lock(); events.append((event, ns)); lock.unlock()
        }
        func setResult(_ kind: String) { lock.lock(); resultKind = kind; lock.unlock() }

        /// The primary line, written once when the executor returns.
        func emit() {
            lock.lock()
            if primaryEmitted { lock.unlock(); return }
            primaryEmitted = true
            primaryHadExit = events.contains { $0.0 == "terminationHandlerFired" }
            let evs = events, l = label, r = resultKind
            lock.unlock()
            writeLine(phase: "return", events: evs, label: l, result: r)
        }

        /// Called at the very end of the Process terminationHandler. If the
        /// executor already returned WITHOUT observing the exit, the handler's
        /// late marks (terminationHandlerFired, exitedSemaphoreSignal) would
        /// otherwise be lost, so emit a correlated late-exit line preserving them.
        /// If the exit was observed before return, or the executor has not
        /// returned yet, do nothing.
        func noteWaitTaskComplete() {
            lock.lock()
            let emitLate = primaryEmitted && !primaryHadExit
            let evs = events, l = label, r = resultKind
            lock.unlock()
            if emitLate { writeLine(phase: "late-exit", events: evs, label: l, result: r) }
        }

        private func writeLine(phase: String, events evs: [(String, UInt64)], label l: String, result r: String) {
            var line = "UUM-PROBE-TIMING id=\(id) phase=\(phase) \(l) result=\(r)"
            for (name, ns) in evs { line += String(format: " %@=%.1fms", name, Double(ns) / 1_000_000) }
            let data = Data((line + "\n").utf8)
            FileHandle.standardError.write(data)
            // A test host's stderr is buffered into the .xcresult, not echoed on
            // the console, so also append to UUM_PROBE_TIMING_FILE when set: a
            // small O_APPEND write is atomic, so concurrent probes interleave
            // whole lines. A CI step reads this file to surface the timeline.
            if let c = getenv("UUM_PROBE_TIMING_FILE") {
                let path = String(cString: c)
                let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
                if fd >= 0 { _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; close(fd) }
            }
        }
    }

    /// The real executor: a `Process` with a TRUE wall-clock deadline and a
    /// terminate-then-kill teardown that reaps the exact child so a wedged
    /// probe can't leave a lingering `ssh`/ProxyCommand behind.
    struct SubprocessProbeExecutor: VersionProbeExecutor {
        var deadlinePollInterval: TimeInterval = 0.05
        var grace: TimeInterval = VersionCheck.terminateGrace
        /// How long to wait, after the child is gone, for its pipes to reach
        /// EOF before taking the output collected so far and stopping the
        /// collectors. On a natural exit EOF normally follows within
        /// milliseconds, but the read handler runs on a global queue and can
        /// be scheduled late under load, so the bound is generous; a
        /// ProxyCommand or other descendant that inherited the pipes can keep
        /// them open, and after this wait they are closed anyway with the
        /// transcript marked incomplete.
        var outputSettle: TimeInterval = 5.0
        /// Called once with the child's pid right after a successful launch,
        /// so a caller can record which process the session owns.
        var onLaunch: (@Sendable (pid_t) -> Void)? = nil
        /// Test-only seam, nil in production (no init parameter, so a normal
        /// construction leaves it unset). `exitObservationHook` runs INSIDE the
        /// Process `terminationHandler`, before the `terminationHandlerFired`
        /// mark and the `exited` signal. A test assigns it a block so exit
        /// observation is delayed against a known cause, proving the executor's
        /// deadline return is independent of when the exit is observed — without
        /// adding a waitpid caller or changing any deadline or verdict.
        var exitObservationHook: (@Sendable () -> Void)? = nil

        init(deadlinePollInterval: TimeInterval = 0.05,
             grace: TimeInterval = VersionCheck.terminateGrace,
             outputSettle: TimeInterval = 5.0,
             onLaunch: (@Sendable (pid_t) -> Void)? = nil) {
            self.deadlinePollInterval = deadlinePollInterval
            self.grace = grace
            self.outputSettle = outputSettle
            self.onLaunch = onLaunch
        }

        /// Upper bound on bytes kept per stream. `-version` output and the
        /// discovery record are a few hundred bytes; anything beyond this is
        /// counted, dropped, and marked with a trailing sentinel line.
        static let outputCap = 1 << 20
        /// Appended when bytes beyond `outputCap` were dropped.
        static let truncationSentinel = "\n[output truncated]"
        /// Appended when collection stopped before the writer closed the
        /// pipe (the settle wait expired with a descendant still holding
        /// it), so a partial transcript is never presented as complete.
        static let incompleteSentinel = "\n[collection stopped before end of output]"
        /// Appended when a read error ended collection; the errno follows.
        static let readErrorSentinelPrefix = "\n[output collection failed: "

        /// Collects one pipe through a dispatch read source. Bytes arrive in
        /// the event handler (the descriptor is non-blocking) and are kept
        /// under a lock up to `outputCap`. EOF cancels the source. `stop()`
        /// cancels it too, so a descendant that inherited the write end
        /// cannot keep a reader alive after the executor has returned: the
        /// cancel handler closes the descriptor and releases the collector.
        /// Nothing is parked on a thread and no retention outlives `stop()`.
        final class PipeCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = Data()
            private var dropped = 0
            private let eof = DispatchSemaphore(value: 0)
            private var eofSignalled = false
            /// True only when a read returned 0 bytes. A read error does not
            /// count as EOF; neither does `stop()`.
            private var reachedEOF = false
            /// The errno of the read error that ended collection, if any.
            private var readError: Int32?
            private let source: DispatchSourceRead
            private let fd: Int32
            /// The read call; injectable so a read failure can be exercised.
            private let readCall: (Int32, UnsafeMutableRawPointer, Int) -> Int
            /// Fired once, at the moment collection ends on its own: EOF (a
            /// zero-byte read, `atEOF` true) or a read error (`atEOF` false,
            /// errno given). Not fired by `stop()`. Used only by opt-in timing;
            /// nil in production, so there is no per-byte or per-event overhead.
            private let onFinish: (@Sendable (_ atEOF: Bool, _ error: Int32?) -> Void)?

            init(_ handle: FileHandle,
                 read readCall: @escaping (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) },
                 onFinish: (@Sendable (_ atEOF: Bool, _ error: Int32?) -> Void)? = nil) {
                self.readCall = readCall
                self.onFinish = onFinish
                fd = handle.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                source = DispatchSource.makeReadSource(fileDescriptor: fd,
                                                       queue: DispatchQueue.global(qos: .utility))
                source.setEventHandler { [weak self] in self?.drain() }
                // Close through the FileHandle, which then knows it is closed
                // and will not close the (possibly reused) number again on
                // deallocation.
                source.setCancelHandler { try? handle.close() }
                source.resume()
            }

            private func drain() {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = buffer.withUnsafeMutableBytes { readCall(fd, $0.baseAddress!, $0.count) }
                    if n > 0 {
                        lock.lock()
                        let room = SubprocessProbeExecutor.outputCap - bytes.count
                        if room > 0 { bytes.append(contentsOf: buffer[0..<min(n, room)]) }
                        dropped += max(0, n - max(0, room))
                        lock.unlock()
                        continue
                    }
                    if n == 0 { finish(atEOF: true, error: nil); return }         // EOF: the only complete ending
                    let err = errno
                    if err == EAGAIN || err == EINTR { return }                  // wait for the next event
                    finish(atEOF: false, error: err); return                       // read error: ended, not complete
                }
            }

            private func finish(atEOF: Bool, error: Int32?) {
                lock.lock()
                let first = !eofSignalled
                eofSignalled = true
                if atEOF { reachedEOF = true }
                if let error, readError == nil { readError = error }
                lock.unlock()
                // Cancel before waking a waiting snapshot, so a caller that
                // wakes on the semaphore already observes the source stopped.
                source.cancel()
                if first { onFinish?(atEOF, error); eof.signal() }
            }

            /// Waits up to `settle` for EOF, then returns everything kept,
            /// with the sentinel appended when bytes were dropped.
            /// Four states are distinguished in the returned text: EOF
            /// reached (no marker), bytes dropped at the size cap
            /// (`truncationSentinel`), a read error ending collection
            /// (`readErrorSentinelPrefix` + strerror), and collection stopped
            /// before EOF (`incompleteSentinel`); the cap marker combines with
            /// either of the other two. Only a zero-byte read is EOF.
            /// Markers are trailing lines, so first-line parsing is unaffected.
            func snapshot(settle: TimeInterval) -> String {
                _ = eof.wait(timeout: .now() + settle)
                lock.lock(); defer { lock.unlock() }
                var text = String(decoding: bytes, as: UTF8.self)
                if dropped > 0 { text += SubprocessProbeExecutor.truncationSentinel }
                if let readError {
                    text += SubprocessProbeExecutor.readErrorSentinelPrefix + String(cString: strerror(readError)) + "]"
                } else if !reachedEOF {
                    text += SubprocessProbeExecutor.incompleteSentinel
                }
                return text
            }

            /// Stops collecting and closes the descriptor. Idempotent. Called
            /// by the executor before it returns, on every path.
            func stop() {
                lock.lock()
                let first = !eofSignalled
                eofSignalled = true
                lock.unlock()
                if !source.isCancelled { source.cancel() }
                if first { eof.signal() }
            }

            var isStopped: Bool { source.isCancelled }
        }

        /// Carries the child's termination status out of the
        /// `terminationHandler` (which runs on Foundation's process-monitor
        /// queue) to the executor thread. The `exited` semaphore provides the
        /// happens-before: a status read after a successful `exited` wait is the
        /// one the handler set before signalling. `@unchecked Sendable`: the one
        /// field is lock-guarded.
        final class ExitStatusBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Int32 = 0
            func set(_ v: Int32) { lock.lock(); value = v; lock.unlock() }
            func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
        }

        func execute(_ config: ProbeConfig,
                     deadline: TimeInterval,
                     canceller: ProbeCanceller) -> RawExecResult {
            // Opt-in lifecycle timing (nil unless UUM_PROBE_TIMING is set), so
            // every mark below is a no-op in production. One line is emitted on
            // return, on every path.
            let timing = ProbeTiming.fromEnvironment()
            timing?.begin(executable: config.executable, deadline: deadline)
            defer { timing?.emit() }

            // Cancellation BEFORE launch: never spawn a child we've already
            // been told to abandon.
            if canceller.isCancelled { timing?.setResult("cancelledBeforeLaunch"); return .cancelled }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: config.executable)
            process.arguments = config.arguments
            let outPipe = Pipe(); let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Observe natural exit through the Process's own terminationHandler,
            // registered BEFORE launch. Foundation invokes it exactly once, from
            // its internal process-monitor source, after the child has terminated
            // and its status is set — with no dependency on this executor pumping
            // a run loop, which is what a background `waitUntilExit()` relied on
            // and the suspected cause of #149's delayed exit observation. The
            // handler records the status and signals `exited`; it never signals a
            // pid, so a late fire after the executor has already returned (a
            // timeout that outran the child) is harmless. Foundation reaps the
            // child as it fires the handler, so we add no competing waitpid.
            let exited = DispatchSemaphore(value: 0)
            let exitStatus = ExitStatusBox()
            let exitHook = exitObservationHook   // nil in production; local copy so the @Sendable closure need not capture self
            process.terminationHandler = { proc in
                exitHook?()
                exitStatus.set(proc.terminationStatus)
                timing?.mark("terminationHandlerFired")
                exited.signal()
                timing?.mark("exitedSemaphoreSignal")
                // If the executor already returned WITHOUT observing this exit (a
                // timeout that outran the child), emit a correlated late-exit line
                // so the delayed exit is preserved rather than lost.
                timing?.noteWaitTaskComplete()
            }

            do { try process.run() } catch {
                timing?.setResult("launchFailed")
                return .launchFailed(error.localizedDescription)
            }
            timing?.mark("launch")
            onLaunch?(process.processIdentifier)
            let out = PipeCollector(outPipe.fileHandleForReading,
                                    onFinish: timing.map { t -> @Sendable (Bool, Int32?) -> Void in
                                        { atEOF, _ in t.mark(atEOF ? "stdoutEOF" : "stdoutReadError") } })
            let err = PipeCollector(errPipe.fileHandleForReading,
                                    onFinish: timing.map { t -> @Sendable (Bool, Int32?) -> Void in
                                        { atEOF, _ in t.mark(atEOF ? "stderrEOF" : "stderrReadError") } })

            // The main flow below waits for exit (via the `exited` semaphore the
            // terminationHandler signals) / cancellation / deadline, so it can
            // never block forever.
            func reapExactChild() {
                timing?.mark("teardownSIGTERM")
                // SIGTERM, then SIGKILL after a grace period. We wait so the
                // ssh child itself is best-effort reaped (no zombie). NOTE: this
                // reaps ONLY the direct ssh child; a ProxyCommand or the remote
                // `servercmd` are ssh's own descendants and are not guaranteed
                // reaped here (ssh forwards the signal, but we don't wait on
                // them). The final SIGKILL wait result is intentionally not
                // asserted: if even SIGKILL+grace hasn't reaped, we return
                // rather than block forever.
                process.terminate()
                if exited.wait(timeout: .now() + grace) == .timedOut {
                    timing?.mark("teardownSIGKILL")
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + grace)
                }
            }
            func collected() -> (String, String) {
                let result = (out.snapshot(settle: outputSettle), err.snapshot(settle: outputSettle))
                out.stop(); err.stop()
                timing?.mark("collectDone")
                return result
            }

            // Register a DETERMINISTIC teardown: the instant cancel() runs
            // (including on the main thread from applicationWillTerminate), the
            // child is SIGTERM'd synchronously — not on a later poll tick. If a
            // cancel raced Process.run(), registerTeardown fires it right now.
            // Mark this cancellation-triggered SIGTERM separately from the reap's
            // own, so an EOF that a cancel caused is not read as natural
            // completion that preceded any intervention.
            canceller.registerTeardown { timing?.mark("cancelSIGTERM"); process.terminate() }

            // Cancellation that arrived DURING/just-after launch: tear down now.
            if canceller.isCancelled {
                reapExactChild(); canceller.clearTeardown(); out.stop(); err.stop()
                timing?.setResult("cancelled"); return .cancelled
            }

            // Deadline is measured from HERE — just after the local spawn
            // returned. It bounds remote I/O + exit, NOT the (synchronous,
            // fast) local launch, which already happened above.
            let deadlineAt = DispatchTime.now() + deadline
            while true {
                // Cancellation FIRST: a SIGTERM'd child will also signal
                // `exited`, and we must report .cancelled (not .exited with a
                // signal status) when the reason we stopped was a cancel.
                if canceller.isCancelled {
                    reapExactChild(); canceller.clearTeardown(); out.stop(); err.stop()
                    timing?.setResult("cancelled"); return .cancelled
                }
                if exited.wait(timeout: .now() + deadlinePollInterval) == .success {
                    timing?.mark("exitObservedInLoop")
                    canceller.clearTeardown()
                    // The exit may be the result of a cancel that fired during
                    // this wait (its teardown SIGTERMs the child). Report that
                    // as .cancelled, not as an exit with a signal status.
                    if canceller.isCancelled {
                        out.stop(); err.stop(); timing?.setResult("cancelled"); return .cancelled
                    }
                    let (stdout, stderr) = collected()
                    let status = exitStatus.get()
                    timing?.setResult("exited(\(status))")
                    return .exited(status: status, stdout: stdout, stderr: stderr)
                }
                if DispatchTime.now() >= deadlineAt {
                    timing?.mark("deadlineDetected")
                    reapExactChild(); canceller.clearTeardown()
                    let (stdout, stderr) = collected()
                    timing?.setResult("timedOut")
                    return .timedOut(stdout: stdout, stderr: stderr)
                }
            }
        }
    }

    /// Bridges cancellation from a `Handle` to the executor. Unlike a bare
    /// `() -> Bool` poll, it can fire a teardown action SYNCHRONOUSLY the
    /// instant `cancel()` runs — so a cancel (including from
    /// `applicationWillTerminate`) tears the child down deterministically,
    /// rather than being "noticed on the next background poll tick". It also
    /// exposes a semaphore-backed wait so the executor never busy-spins.
    /// `@unchecked Sendable`: all mutable state is lock-guarded.
    final class ProbeCanceller: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        private var _teardown: (() -> Void)?
        private let signal = DispatchSemaphore(value: 0)
        private var signalled = false

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

        /// Register the action that tears the child down (SIGTERM). Fired
        /// synchronously HERE if cancellation already happened (so a cancel
        /// that raced `Process.run()` still tears down), otherwise stored and
        /// fired by `cancel()`.
        func registerTeardown(_ action: @escaping () -> Void) {
            lock.lock()
            if _cancelled { lock.unlock(); action(); return }
            _teardown = action
            lock.unlock()
        }

        /// Drop the teardown once the child has been reaped, so a later cancel
        /// can't signal a dead/reused pid.
        func clearTeardown() { lock.lock(); _teardown = nil; lock.unlock() }

        /// Block until cancellation or `timeout`. Wakes IMMEDIATELY on cancel
        /// (semaphore), never polls. Returns true iff cancelled.
        func waitForCancellation(timeout: DispatchTime) -> Bool {
            if isCancelled { return true }
            _ = signal.wait(timeout: timeout)
            return isCancelled
        }

        /// Idempotent. Marks cancelled, wakes any waiter, and fires the
        /// registered teardown synchronously (outside the lock, since it may
        /// block on the child's reap).
        func cancel() {
            lock.lock()
            if _cancelled { lock.unlock(); return }
            _cancelled = true
            let teardown = _teardown
            _teardown = nil
            if !signalled { signalled = true; signal.signal() }
            lock.unlock()
            teardown?()
        }
    }

    /// A running probe. `cancel()` is safe from any thread and any number of
    /// times; it deterministically requests teardown of the in-flight
    /// subprocess and suppresses delivery of the now-abandoned result.
    /// `waitUntilFinished` lets shutdown block (bounded) until the probe's
    /// teardown actually completes. `@unchecked Sendable`: state is either the
    /// lock-guarded canceller or a semaphore.
    final class Handle: @unchecked Sendable {
        let canceller = ProbeCanceller()
        private let finished = DispatchSemaphore(value: 0)
        var isCancelled: Bool { canceller.isCancelled }
        func cancel() { canceller.cancel() }
        /// Signalled once by `run` when the probe body (including any teardown)
        /// has returned.
        func markFinished() { finished.signal() }
        /// Bounded wait for the probe body to finish — used at shutdown so the
        /// child is reaped, not merely signalled. True iff it finished in time.
        @discardableResult
        func waitUntilFinished(timeout: DispatchTime) -> Bool {
            finished.wait(timeout: timeout) == .success
        }
    }

    // MARK: - Version string parsing

    /// Extracts the dotted-numeric version from one of these shapes:
    ///   - "unison version 2.54.0"
    ///   - "unison version 2.54.0 (ocaml 5.4.1)"
    ///   - "2.54.0 (ocaml 4.14.3)"   ← what `unison_bridge_get_version` returns
    ///
    /// Returns just the `X.Y[.Z]` part. Returns nil if no recognizable
    /// version pattern is found.
    ///
    /// The remote probe runs `unison -version` over SSH, whose output can be
    /// preceded by a login banner (MOTD) that itself mentions a version — even one
    /// phrased "Unison version 2.51 will be retired". Anchoring to the label
    /// anywhere isn't enough (it would take the banner's number), so we work
    /// LINE BY LINE and take the LAST line that BEGINS with Unison's own
    /// "unison version" label: the command's own output follows the banner. Only
    /// if no line carries that label do we accept a bare version, and then only a
    /// line that STARTS with it — the `2.54.0 (ocaml …)` form the local bridge
    /// returns (last such line wins). A dotted number mid-line is never accepted.
    /// The strict form the remote check requires: a line that starts with
    /// Unison's own label, `unison version X.Y[.Z]`, optionally followed by
    /// more text such as `(ocaml 5.5.0)`. A bare number, or a number inside
    /// another program's sentence, is not a Unison version line. Returns the
    /// dotted version, or nil.
    static func parseUnisonVersionLine(_ line: String) -> String? {
        firstCapture(#"(?i)^\s*unison\s+version\s+(\d+\.\d+(?:\.\d+)?)(?:\s|$)"#, in: line)
    }

    static func parseVersionString(_ raw: String) -> String? {
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        // Labelled lines first; the last one is the real command response.
        var labelled: String?
        for line in lines {
            if let v = firstCapture(#"(?i)^\s*unison\s+version\s+(\d+\.\d+(?:\.\d+)?)"#, in: line) {
                labelled = v
            }
        }
        if let labelled { return labelled }
        // Bare local form: a version leading a line (last such line wins).
        var bare: String?
        for line in lines {
            if let v = firstCapture(#"^\s*(\d+\.\d+(?:\.\d+)?)"#, in: line) {
                bare = v
            }
        }
        return bare
    }

    /// Return capture group 1 of the first match of `pattern` in `s`, or nil.
    private static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let match = regex.firstMatch(
            in: s,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Suppression state

    /// "Don't remind me again" persistence. Keyed by `(host, local,
    /// remote)` — if the user upgrades either side, the triple
    /// changes and we re-prompt. Storage shape: a flat `[String]`
    /// under `UserDefaults.standard` to keep things diffable in
    /// `defaults read` output.
    enum Suppression {
        static let key = "versionMismatch.suppressed"

        /// Token used as the array element. Hosts can't contain `|`
        /// in any normal SSH config, so it's a safe field separator.
        static func token(host: String, local: String, remote: String) -> String {
            "\(host)|\(local)|\(remote)"
        }

        static func isSuppressed(
            host: String, local: String, remote: String,
            defaults: UserDefaults = .standard
        ) -> Bool {
            let list = defaults.stringArray(forKey: key) ?? []
            return list.contains(token(host: host, local: local, remote: remote))
        }

        static func suppress(
            host: String, local: String, remote: String,
            defaults: UserDefaults = .standard
        ) {
            let t = token(host: host, local: local, remote: remote)
            var list = defaults.stringArray(forKey: key) ?? []
            if !list.contains(t) {
                list.append(t)
                defaults.set(list, forKey: key)
            }
        }
    }
}
