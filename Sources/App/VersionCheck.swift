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
        case timedOut
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
        args.append(contentsOf: tokenizeSSHArgs(sshargs))
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

    /// The real executor: a `Process` with a TRUE wall-clock deadline and a
    /// terminate-then-kill teardown that reaps the exact child so a wedged
    /// probe can't leave a lingering `ssh`/ProxyCommand behind.
    struct SubprocessProbeExecutor: VersionProbeExecutor {
        var deadlinePollInterval: TimeInterval = 0.05
        var grace: TimeInterval = VersionCheck.terminateGrace

        func execute(_ config: ProbeConfig,
                     deadline: TimeInterval,
                     canceller: ProbeCanceller) -> RawExecResult {
            // Cancellation BEFORE launch: never spawn a child we've already
            // been told to abandon.
            if canceller.isCancelled { return .cancelled }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: config.executable)
            process.arguments = config.arguments
            let outPipe = Pipe(); let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do { try process.run() } catch {
                return .launchFailed(error.localizedDescription)
            }

            // Wait for natural exit on a background thread; the main flow waits
            // for exit / cancellation / deadline so it can never block forever.
            let exited = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                exited.signal()
            }

            func reapExactChild() {
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
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + grace)
                }
            }
            func closePipes() {
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
            }

            // Register a DETERMINISTIC teardown: the instant cancel() runs
            // (including on the main thread from applicationWillTerminate), the
            // child is SIGTERM'd synchronously — not on a later poll tick. If a
            // cancel raced Process.run(), registerTeardown fires it right now.
            canceller.registerTeardown { process.terminate() }

            // Cancellation that arrived DURING/just-after launch: tear down now.
            if canceller.isCancelled {
                reapExactChild(); canceller.clearTeardown(); closePipes(); return .cancelled
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
                    reapExactChild(); canceller.clearTeardown(); closePipes(); return .cancelled
                }
                if exited.wait(timeout: .now() + deadlinePollInterval) == .success {
                    // Natural exit. `-version` output is tiny, so reading now
                    // can't deadlock on a full pipe buffer.
                    canceller.clearTeardown()
                    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    closePipes()
                    return .exited(
                        status: process.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "")
                }
                if DispatchTime.now() >= deadlineAt {
                    reapExactChild(); canceller.clearTeardown(); closePipes(); return .timedOut
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

    /// Split a Unison `sshargs` string into argv tokens (whitespace-
    /// delimited; empty for nil/blank). Pure + tested. Caveat: a simple
    /// split — an argument containing embedded spaces (e.g. a key path
    /// with a space) isn't handled, which matches the common real-world
    /// case where keys live at space-free paths.
    static func tokenizeSSHArgs(_ sshargs: String?) -> [String] {
        guard let sshargs else { return [] }
        return sshargs.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
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
