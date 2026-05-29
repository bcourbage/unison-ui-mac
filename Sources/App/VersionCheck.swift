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
/// - Doesn't follow Unison's full SSH option set (`sshcmd`, `sshargs`).
///   We invoke `/usr/bin/ssh` directly with a minimal arg list. If
///   the user has aggressive customization in their .prf, the probe
///   may fail differently than Unison's actual connection — we just
///   skip with a log line.
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
    static func run(
        profile: String,
        unisonDirectory: String,
        localBridgeVersion: String,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = runSync(
                profile: profile,
                unisonDirectory: unisonDirectory,
                localBridgeVersion: localBridgeVersion
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(outcome) }
            }
        }
    }

    /// Synchronous variant — used by `run` after dispatching to a
    /// background queue. Exposed for tests so they can drive the
    /// logic with a known .prf text without async overhead.
    static func runSync(
        profile: String,
        unisonDirectory: String,
        localBridgeVersion: String
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

        guard let localVersion = parseVersionString(localBridgeVersion) else {
            return .probeFailed(reason: "couldn't parse local bridge version: \(localBridgeVersion)")
        }

        guard let remoteVersion = probeRemoteVersion(sshRoot: sshRoot, servercmd: servercmd) else {
            return .probeFailed(reason: "ssh probe of \(sshRoot.host) returned no parseable version")
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

    // MARK: - SSH probe

    /// Spawns `/usr/bin/ssh [-p port] [-o BatchMode=yes] [user@]host <servercmd> -version`,
    /// captures stdout, parses out the version number. Returns nil on
    /// any failure (timeout, non-zero exit, unparseable output).
    ///
    /// `BatchMode=yes` is the safety belt: if the remote requires a
    /// password, SSH bails immediately rather than prompting. We'd
    /// rather skip the check than double-prompt the user.
    ///
    /// Visible for tests (output-parser exercised separately).
    static func probeRemoteVersion(sshRoot: SSHRoot, servercmd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = ["-o", "BatchMode=yes",
                              "-o", "ConnectTimeout=5",
                              "-o", "StrictHostKeyChecking=accept-new"]
        if let port = sshRoot.port {
            args.append("-p")
            args.append(String(port))
        }
        args.append(sshRoot.user.map { "\($0)@\(sshRoot.host)" } ?? sshRoot.host)
        // Use `--` to separate ssh's args from the remote command, so a
        // servercmd path with a leading dash (unlikely but possible)
        // doesn't get reinterpreted by ssh.
        args.append("--")
        args.append(servercmd)
        args.append("-version")
        process.arguments = args

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Discard stderr — we don't surface it; failure-mode logging
        // happens at the .versionCheck category from the caller.
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return parseVersionString(output)
    }

    // MARK: - Version string parsing

    /// Extracts the dotted-numeric version from one of these shapes:
    ///   - "unison version 2.54.0"
    ///   - "unison version 2.54.0 (ocaml 5.4.1)"
    ///   - "2.54.0 (ocaml 4.14.3)"   ← what `unison_bridge_get_version` returns
    ///
    /// Returns just the `X.Y[.Z]` part. Returns nil if no recognizable
    /// version pattern is found.
    static func parseVersionString(_ raw: String) -> String? {
        let pattern = #"(\d+\.\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        guard let match = regex.firstMatch(
            in: raw,
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
