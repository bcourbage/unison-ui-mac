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
/// - Uses `ProcessInfo.processInfo.hostName` (equivalent to
///   `gethostname()`). Respects `UNISONLOCALHOSTNAME` env var the
///   same way upstream does.
/// - Local paths are expanded via `expandingTildeInPath` and otherwise
///   passed verbatim. Upstream's `Fspath.canonize` also resolves
///   symlinks; we don't, so a profile that uses a symlinked root
///   would diverge. Rare; documented.
enum ArchiveHash {

    /// Pinned to upstream's current value. Bump if Unison ever ships
    /// a new archive format (a release-notes-level event).
    static let archiveFormat = 23

    /// Successful hash result. The two canonical strings + raw input
    /// are exposed so the UI can show them in the confirm dialog —
    /// the user can cross-check against `unison -showArchiveName <profile>`.
    struct Result: Equatable {
        /// MD5 hex digest. The suffix used in archive filenames.
        let hash: String
        /// The local root's canonical form (`thisRoot`).
        let thisRoot: String
        /// The sorted, comma-joined canonical roots string.
        let rootsName: String
        /// Raw MD5 input — `"<thisRoot>;<rootsName>;<archiveFormat>"`.
        /// Useful for debugging hash mismatches.
        let hashInput: String
    }

    enum Failure: Error, Equatable {
        case profileFileMissing
        case noRoots
        case noLocalRoot
    }

    /// Compute the hash for the given profile's roots. The profile
    /// filename is intentionally NOT part of the input — renaming a
    /// profile (without changing its roots) does not affect the hash,
    /// which is why archives survive rename.
    ///
    /// `hostname` defaults to the system's `gethostname()` value, or
    /// the `UNISONLOCALHOSTNAME` env var if set. Tests override this
    /// to pin against known inputs.
    static func compute(
        unisonDirectory: String,
        profile: String,
        hostname: String = Self.systemHostname
    ) -> Swift.Result<Result, Failure> {
        let url = URL(fileURLWithPath: unisonDirectory)
            .appendingPathComponent("\(profile).prf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(.profileFileMissing)
        }
        return computeFromProfileText(text, hostname: hostname)
    }

    /// Compute the hash from raw .prf text. Broken out so tests can
    /// drive the function without writing temp files to disk.
    static func computeFromProfileText(
        _ text: String,
        hostname: String
    ) -> Swift.Result<Result, Failure> {
        let doc = ProfileDocument.parse(text)
        let rootValues = doc.values(forKey: "root")
        guard !rootValues.isEmpty else { return .failure(.noRoots) }

        let canonicalForms = rootValues.map { canonicalize($0, hostname: hostname) }
        guard let firstLocal = canonicalForms.first(where: { $0.isLocal }) else {
            return .failure(.noLocalRoot)
        }

        // rootsName ordering: upstream uses OCaml's `compare`, which on
        // strings is byte-wise lexicographic. Swift's default String
        // sort is locale-aware; we use `<` on String which is byte-wise
        // for the ASCII characters that appear in canonical roots.
        let sorted = canonicalForms.map(\.canonical).sorted()
        let rootsName = sorted.joined(separator: ", ")
        let thisRoot = firstLocal.canonical

        let input = "\(thisRoot);\(rootsName);\(archiveFormat)"
        let hash = md5Hex(input)
        return .success(Result(
            hash: hash,
            thisRoot: thisRoot,
            rootsName: rootsName,
            hashInput: input
        ))
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
    /// `Os.localCanonicalHostName`: env var override first, then
    /// `gethostname()`. On macOS that's typically the .local name
    /// (e.g. "MacBook.local"), without DNS canonicalization.
    static var systemHostname: String {
        if let override = ProcessInfo.processInfo.environment["UNISONLOCALHOSTNAME"],
           !override.isEmpty {
            return override
        }
        return ProcessInfo.processInfo.hostName
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
