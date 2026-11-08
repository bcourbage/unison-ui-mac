import Foundation
import CommonCrypto

/// Pure-Swift replication of Unison's `Update.archiveHash` MD5 logic.
///
/// Upstream (src/update.ml line 203 — current as of Unison 2.54):
///
/// ```ocaml
/// let archiveHash fspath =
///   let thisRoot = thisRootsGlobalName fspath in
///   let r = Prefs.read rootsName in
///   let n = Printf.sprintf "%s;%s;%d" thisRoot r archiveFormat in
///   Digest.MD5.to_hex (Digest.MD5.string n)
/// ```
///
/// Inputs:
///   - `thisRoot`  = canonical form of the local root, written as
///                   `//<hostname>/<absolute-fspath>` (the local side
///                   is treated as a "remote" with the local hostname
///                   for hashing — see `storeRootsName` in update.ml).
///   - `rootsName` = the two canonical root strings, sorted with
///                   `compare` (lexicographic), joined with `, ` (comma
///                   + space).
///   - `archiveFormat` = constant `23` (pinned at upstream commit
///                   `745dccd` — May 2026). If upstream bumps this,
///                   our hash drifts; tests will catch the regression
///                   if we update the fixture.
///
/// The resulting MD5 hex digest is the suffix in archive filenames:
/// `ar<hash>`, `fp<hash>`, `lk<hash>`, `tm<hash>`, `sc<hash>`.
///
/// **Why we replicate this instead of asking OCaml**: there's no
/// upstream-registered Callback to compute the hash without first
/// running `init1` for a profile (which involves loading the .prf,
/// resolving roots, potentially opening an SSH connection — slow).
/// Adding a new Callback would require patching `uimacbridge.ml`,
/// which is off-limits for this project. Replicating the function in
/// Swift is the pragmatic alternative; the algorithm is well-isolated
/// and stable in upstream.
///
/// **Limitations**:
/// - Doesn't apply `rootalias` substitutions. If the user's .prf has
///   a `rootalias = …` rule, our hash will diverge for that profile.
///   Documented in the TODO; rare in practice.
/// - Uses POSIX `gethostname(2)` (exactly what upstream's
///   `Os.localCanonicalHostName` calls). Respects `UNISONLOCALHOSTNAME`
///   env var the same way upstream does. NOTE: this is deliberately
///   NOT `ProcessInfo.processInfo.hostName`, which on macOS returns the
///   Bonjour `.local` name (e.g. "Heracles.local") rather than the bare
///   kernel hostname set via `scutil --set HostName` (e.g. "Heracles").
///   The two diverge whenever HostName has no domain, which silently
///   broke archive lookup before this was corrected.
/// - Local paths are expanded via `expandingTildeInPath` and otherwise
///   passed verbatim. Upstream's `Fspath.canonize` also resolves
///   symlinks; we don't, so a profile that uses a symlinked root
///   would diverge. Rare; documented.
enum ArchiveHash {

    /// Pinned to upstream's current value. Bump if Unison ever ships
    /// a new archive format (a release-notes-level event).
    static let archiveFormat = 23

    /// Successful hash result: the digest and the canonical strings it was
    /// computed from, for cross-checking against `unison -showArchiveName <profile>`.
    struct Result: Equatable {
        /// MD5 hex digest. The suffix used in archive filenames.
        let hash: String
        /// The local root's canonical form (`thisRoot`).
        let thisRoot: String
        /// The sorted, comma-joined canonical roots string.
        let rootsName: String
    }

    /// All archive identities for a profile. Unison keeps a SEPARATE
    /// archive per *local* root, each named with that root as `thisRoot`
    /// but sharing the same `rootsName`. A normal local↔remote profile
    /// has exactly one local root (one entry); a local↔local profile
    /// has two (two entries, two hashes). Resetting/cleaning must cover
    /// every entry or it leaves half the reconciliation state behind.
    struct MultiResult: Equatable {
        /// The sorted, comma-joined canonical roots string (shared).
        let rootsName: String
        /// One `Result` per local root; always ≥1 on success.
        let entries: [Result]
        /// Convenience: just the hashes, in entry order.
        var hashes: [String] { entries.map(\.hash) }
    }

    enum Failure: Error, Equatable {
        case profileFileMissing
        case noRoots
        case noLocalRoot
        /// The profile's roots cannot be determined: its file or an included
        /// file is unreadable or malformed, includes loop or are missing, or it
        /// uses `rootalias`. Which archives it uses is unknown.
        case rootsUnresolved
    }

    /// Compute the archive identity for EVERY local root of the profile. The
    /// profile filename is intentionally NOT part of the input, so renaming a
    /// profile (without changing its roots) does not affect the hash, which is
    /// why archives survive rename. `hostname` defaults to the system's
    /// `gethostname()` value, or `UNISONLOCALHOSTNAME` if set; tests override it.
    /// Use this anywhere that deletes or scans
    /// archive files: a local↔local profile has two local archives and
    /// touching only one leaves an inconsistent half-reset behind.
    static func computeAll(
        unisonDirectory: String,
        profile: String,
        hostname: String = Self.systemHostname
    ) -> Swift.Result<MultiResult, Failure> {
        switch effectiveRoots(unisonDirectory: unisonDirectory, profile: profile) {
        case .failure(let failure): return .failure(failure)
        case .success(let roots): return computeAll(forRoots: roots, hostname: hostname)
        }
    }

    /// Which file is "the profile" when a name could mean two.
    enum ProfileLookup {
        /// The engine's lookup: an extensionless file named `profile` wins,
        /// else `profile.prf`. Use this to decide what the engine will open.
        case engine
        /// Exactly `profile.prf`. Use this for actions that name and act on
        /// that file, such as the editor's Reset and Delete.
        case prfFile
    }

    /// The roots a profile actually uses, following `include` and `source`
    /// the way Unison does (`ProfileRootResolver`). A profile whose include
    /// graph cannot be followed completely is `.rootsUnresolved`, never
    /// treated as having no roots or as having only the roots it spells out
    /// itself: every archive action fails closed on it.
    ///
    /// `.profileFileMissing` means the profile file itself is absent. It is
    /// decided by the resolver's own top-level read (`profileFound`), never by its
    /// issue list and never by a second read that could disagree: a
    /// profile that exists but sources a file that is missing (even one named
    /// like itself) is unresolved, not missing.
    static func effectiveRoots(
        unisonDirectory: String,
        profile: String,
        lookup: ProfileLookup = .engine,
        read: (String) -> ProfileRootResolver.ReadResult = ProfileRootResolver.filesystemRead
    ) -> Swift.Result<[String], Failure> {
        let exact = lookup == .prfFile
        let resolution = ProfileRootResolver.resolve(
            unisonDirectory: unisonDirectory,
            profile: exact ? profile + ".prf" : profile,
            exactTopLevelFile: exact,
            read: read)
        guard resolution.profileFound else { return .failure(.profileFileMissing) }
        // A `rootalias` rewrites roots before Unison names the archive, so the
        // archives of an aliased profile cannot be identified from its roots.
        guard resolution.reliable, resolution.rootaliases.isEmpty else {
            return .failure(.rootsUnresolved)
        }
        return .success(resolution.roots)
    }

    /// Why a profile's roots cannot identify local archives, or nil when they
    /// can: there are no roots, or none of them is local. This is the gate
    /// every archive action applies before it touches anything; callers that
    /// need no digest use it directly instead of computing hashes.
    static func eligibilityFailure(forRoots rootValues: [String], hostname: String) -> Failure? {
        guard !rootValues.isEmpty else { return .noRoots }
        guard rootValues.contains(where: { canonicalize($0, hostname: hostname).isLocal }) else {
            return .noLocalRoot
        }
        return nil
    }

    /// Compute the archive identity for every local root from raw .prf
    /// text, so tests can drive the function without writing temp files.
    static func computeAllFromProfileText(
        _ text: String,
        hostname: String
    ) -> Swift.Result<MultiResult, Failure> {
        computeAll(forRoots: ProfileDocument.parse(text).values(forKey: "root"), hostname: hostname)
    }

    /// Compute the archive identity for every local root of `rootValues`.
    static func computeAll(
        forRoots rootValues: [String],
        hostname: String
    ) -> Swift.Result<MultiResult, Failure> {
        if let failure = eligibilityFailure(forRoots: rootValues, hostname: hostname) {
            return .failure(failure)
        }

        let canonicalForms = rootValues.map { canonicalize($0, hostname: hostname) }
        let localForms = canonicalForms.filter { $0.isLocal }

        // rootsName ordering: upstream uses OCaml's `compare`, which on
        // strings is byte-wise lexicographic. Swift's default String
        // sort is locale-aware; we use `<` on String which is byte-wise
        // for the ASCII characters that appear in canonical roots.
        let sorted = canonicalForms.map(\.canonical).sorted()
        let rootsName = sorted.joined(separator: ", ")

        // One archive per local root: same rootsName, different thisRoot.
        let entries = localForms.map { local -> Result in
            let thisRoot = local.canonical
            let input = "\(thisRoot);\(rootsName);\(archiveFormat)"
            return Result(hash: md5Hex(input),
                          thisRoot: thisRoot,
                          rootsName: rootsName)
        }
        return .success(MultiResult(rootsName: rootsName, entries: entries))
    }

    // MARK: - Canonicalization

    /// Convert a root string from the .prf into the form used by
    /// upstream's `root2string`:
    ///   - Plain absolute path:    `//<hostname>/<abs>`
    ///   - `ssh://user@host/path`: passes through as-is
    ///   - `socket://host:port/`:  passes through as-is
    ///   - `file:///path`:         treated as local (`//<hostname>/<abs>`)
    ///   - `file://host/path`:     treated as remote (passes through)
    ///
    /// Returns `(canonical, isLocal)` — `isLocal` drives whether the
    /// archive cleanup can touch this root from the running machine.
    static func canonicalize(
        _ root: String,
        hostname: String
    ) -> (canonical: String, isLocal: Bool) {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remote schemes pass through verbatim. Upstream's `Common.root2string`
        // emits these exactly as the user typed them, modulo internal
        // parsing; we don't need to re-parse them since we never combine
        // them with the local hostname.
        if trimmed.hasPrefix("ssh://") || trimmed.hasPrefix("socket://") {
            return (trimmed, false)
        }
        if trimmed.hasPrefix("file://") {
            // file://host/path = remote with host; file:///path = local
            // (three slashes — empty host). Distinguish by whether
            // the character right after `file://` is another `/`.
            let afterScheme = trimmed.dropFirst("file://".count)
            if afterScheme.hasPrefix("/") {
                // Local form. The path part still has its leading `/`.
                let path = (String(afterScheme) as NSString).expandingTildeInPath
                return (localCanonical(absolutePath: path, hostname: hostname), true)
            }
            // Remote form — pass through.
            return (trimmed, false)
        }
        // Bare path — local. Expand `~` and trim trailing slash so the
        // canonicalization is stable.
        let abs = (trimmed as NSString).expandingTildeInPath
        return (localCanonical(absolutePath: abs, hostname: hostname), true)
    }

    /// Upstream emits `"//"^host^"/"^fspath`. When `fspath` is an
    /// absolute path (starts with `/`), the result has a double slash
    /// between host and path: `//host//Users/...`. We replicate that
    /// here. Also trims trailing slashes so `/tmp/a` and `/tmp/a/`
    /// canonicalize the same way.
    private static func localCanonical(absolutePath: String,
                                        hostname: String) -> String {
        var path = absolutePath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // Insert a `/` between host and path; if path starts with `/`
        // we end up with `//host//path…`, matching upstream exactly.
        return "//\(hostname)/\(path)"
    }

    // MARK: - Hostname

    /// The hostname Unison hashes against. Matches upstream's
    /// `Os.localCanonicalHostName`: env var override first, then POSIX
    /// `gethostname(2)`. This is the bare kernel hostname (e.g.
    /// "Heracles"), NOT the Bonjour `.local` name returned by
    /// `ProcessInfo.processInfo.hostName` — using the latter produced
    /// the wrong archive hash whenever HostName carried no domain.
    static var systemHostname: String {
        if let override = ProcessInfo.processInfo.environment["UNISONLOCALHOSTNAME"],
           !override.isEmpty {
            return override
        }
        return posixHostname()
    }

    /// POSIX `gethostname(2)` — the exact call behind OCaml's
    /// `Unix.gethostname()`, which Unison uses to name archive files.
    /// `_SC_HOST_NAME_MAX` is the portable buffer size; we add room for
    /// the NUL terminator. Falls back to `ProcessInfo.hostName` only if
    /// the syscall fails (it effectively never does).
    private static func posixHostname() -> String {
        let cap = Int(sysconf(Int32(_SC_HOST_NAME_MAX))) + 1
        var buffer = [CChar](repeating: 0, count: max(cap, 256))
        guard gethostname(&buffer, buffer.count) == 0 else {
            return ProcessInfo.processInfo.hostName
        }
        return String(cString: buffer)
    }

    // MARK: - MD5

    /// MD5 hex digest of a string, lowercase. CommonCrypto's MD5 is
    /// deprecated for cryptographic purposes (collision-prone) but
    /// we're matching an existing on-disk filename scheme — not
    /// authenticating anything — so the deprecation is irrelevant.
    static func md5Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
