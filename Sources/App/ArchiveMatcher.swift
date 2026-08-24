import Foundation

/// Matches Unison archive files to a profile by comparing the *paths* of
/// their roots, ignoring hostnames.
///
/// Why hostname-agnostic: every archive in the local Unison directory is,
/// by definition, one of this machine's archives (the remote side's
/// archive lives on the remote). But the hostname Unison bakes into an
/// archive's name drifts over time — `Heracles.local` → `Heracles` after
/// a `scutil --set HostName`, etc. Matching on the recorded hostname
/// therefore misses a profile's own archives once the name changes. The
/// *paths* don't drift, so we match on those.
///
/// Precision comes from matching BOTH roots' paths, not just the local
/// one. We know the local path (from the .prf) and, for an ssh root
/// written as `ssh://host//abspath`, the remote path too. Two profiles
/// sharing a local root but pointing at different remotes still match
/// distinct archives, because the remote path differs. When the remote
/// path is the remote *home* (`ssh://host/`, unresolvable offline), that
/// side is treated as a wildcard and the local side pins the match.
enum ArchiveMatcher {

    /// One parsed profile root.
    struct RootSpec: Equatable {
        /// Absolute path, when knowable: always for local roots; for
        /// remote roots only when the .prf gives an absolute path
        /// (`ssh://host//abs`). `nil` means "unknown" (remote home or a
        /// relative remote path) and acts as a wildcard in matching.
        let path: String?
        let isLocal: Bool
    }

    // MARK: - Parsing profile roots

    static func rootSpecs(forRoots roots: [String]) -> [RootSpec] {
        roots.map { raw in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("ssh://") || t.hasPrefix("socket://") {
                return RootSpec(path: remotePath(of: t), isLocal: false)
            }
            if t.hasPrefix("file://") {
                let after = String(t.dropFirst("file://".count))
                // file:///abs → local; file://host/path → remote.
                if after.hasPrefix("/") {
                    return RootSpec(path: localPath(of: after), isLocal: true)
                }
                return RootSpec(path: remotePath(of: t), isLocal: false)
            }
            return RootSpec(path: localPath(of: t), isLocal: true)
        }
    }

    /// Expand `~`, resolve symlinks along the WHOLE path via `realpath(3)`
    /// (Blocker B2), and strip a trailing slash. Unison records the canonical
    /// (symlink-resolved) fspath in an archive's roots — e.g. a profile root
    /// `/tmp/sync` is stored as `/private/tmp/sync` because `/tmp` is a symlink.
    /// Matching the un-resolved profile path against that canonical archive path
    /// would miss the profile's own LIVE archive and misclassify it as a
    /// confident orphan. Resolving both sides the same way fixes that.
    ///
    /// When the path can't be resolved (it doesn't exist), fall back to the
    /// lexically cleaned path; the caller treats such a root as
    /// attribution-unreliable (fail closed) rather than confidently matching.
    static func localPath(of root: String,
                          resolve: (String) -> String? = ArchiveMatcher.realpathResolve) -> String {
        let expanded = (root as NSString).expandingTildeInPath
        var s = resolve(expanded) ?? expanded
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// True iff the local `root` resolves to a canonical path different from its
    /// lexical form OR cannot be resolved — i.e. `realpath` matters here (an
    /// ancestor/leaf symlink, or a missing path). Used to mark a profile's
    /// attribution as needing the resolved path, and to fail closed when the
    /// path can't be resolved at all.
    static func localRootNeedsResolution(_ root: String,
                                         resolve: (String) -> String? = ArchiveMatcher.realpathResolve)
        -> (resolvable: Bool, differs: Bool) {
        let expanded = (root as NSString).expandingTildeInPath
        var lexical = expanded
        while lexical.count > 1 && lexical.hasSuffix("/") { lexical.removeLast() }
        guard let resolved0 = resolve(expanded) else { return (false, false) }
        var resolved = resolved0
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return (true, resolved != lexical)
    }

    /// `realpath(3)` wrapper: absolute, symlink-resolved path, or nil if it
    /// can't be resolved (e.g. the path does not exist).
    static func realpathResolve(_ path: String) -> String? {
        return path.withCString { c -> String? in
            guard let r = realpath(c, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
    }

    /// True when an archive's `rootsName` cannot be unambiguously parsed into
    /// canonical `//host//path` components (Blocker B1): upstream joins roots
    /// with `", "` and does NOT escape, so a root path containing `", "` splits
    /// into extra fragments that don't parse as canonical components. Any
    /// unparseable component makes the whole entry ambiguous — it must be marked
    /// uncertain (non-actionable), never confidently classified or preselected.
    static func rootsNameIsAmbiguous(_ rootsName: String) -> Bool {
        componentPaths(ofRootsName: rootsName).contains(where: { $0 == nil })
    }

    /// True when the archive's root-pair spans TWO distinct hosts — i.e. it has
    /// a genuine remote side (Should-fix SF3), whose canonical path is unknowable
    /// offline, so the archive must stay report-only (uncertain). A pair whose
    /// components all share ONE host is local↔local — even under a former machine
    /// name (`//MacBookPro//… , //MacBookPro//…`), whose local paths ARE
    /// verifiable — so it is not treated as remote. An unparseable component is
    /// treated as remote (fail closed).
    static func involvesRemoteHost(rootsName: String) -> Bool {
        let hosts = rootsName.components(separatedBy: ", ").map { host(ofComponent: $0).map(shortLabel) }
        if hosts.contains(where: { $0 == nil }) { return true }
        return Set(hosts.compactMap { $0 }).count > 1
    }

    /// Absolute remote path from a `scheme://[user@]host[:port][/…]` root,
    /// or `nil` when it's the remote home / a relative path (unknowable
    /// offline). Mirrors Unison: `//abs` after the host is absolute, a
    /// single `/rel` is relative-to-home.
    static func remotePath(of root: String) -> String? {
        guard let scheme = root.range(of: "://") else { return nil }
        let authorityAndPath = root[scheme.upperBound...]
        guard let slash = authorityAndPath.firstIndex(of: "/") else { return nil }
        var rest = String(authorityAndPath[slash...])   // starts with "/"
        guard rest != "/" else { return nil }           // bare home
        guard rest.hasPrefix("//") else { return nil }  // single "/" = relative
        while rest.hasPrefix("//") { rest.removeFirst() }
        while rest.count > 1 && rest.hasSuffix("/") { rest.removeLast() }
        return rest
    }

    // MARK: - Parsing archive header roots

    /// Absolute path from a canonical root component (`//host//abs` or
    /// `//host/abs`). Returns `nil` if it doesn't look like one.
    static func fspath(ofComponent component: String) -> String? {
        let t = component.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("//") else { return nil }
        let afterSlashes = t.dropFirst(2)               // host[/…]
        guard let slash = afterSlashes.firstIndex(of: "/") else { return nil }
        var p = String(afterSlashes[slash...])          // "//abs" or "/abs"
        while p.hasPrefix("//") { p.removeFirst() }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The component paths of an archive's `rootsName` (the sorted,
    /// `", "`-joined canonical roots), preserving order and count. An
    /// unparseable component is `nil`.
    static func componentPaths(ofRootsName rootsName: String) -> [String?] {
        rootsName.components(separatedBy: ", ").map { fspath(ofComponent: $0) }
    }

    /// A hostname-independent signature of an archive's root-pair, used to
    /// tell distinct root-pairs apart (current vs. stale copies of the
    /// SAME pair share a signature; different pairs don't).
    static func pathSignature(ofRootsName rootsName: String) -> String {
        componentPaths(ofRootsName: rootsName)
            .map { $0 ?? "?" }
            .sorted()
            .joined(separator: " | ")
    }

    /// Host portion of a canonical component (`//host//path` → `host`).
    static func host(ofComponent component: String) -> String? {
        let t = component.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("//") else { return nil }
        let afterSlashes = t.dropFirst(2)
        guard let slash = afterSlashes.firstIndex(of: "/") else { return nil }
        return String(afterSlashes[..<slash])
    }

    /// First DNS label, lowercased — the hostname's stable identity across
    /// `.local`/`.lan` drift. `Heracles`, `Heracles.local`, `heracles.lan`
    /// all reduce to `heracles`; `MacBookPro` does not.
    static func shortLabel(_ hostname: String) -> String {
        (hostname.split(separator: ".").first.map(String.init) ?? hostname).lowercased()
    }

    // MARK: - Matching

    /// Archives belonging to the profile with the given roots. An archive
    /// matches when:
    ///   - it has the same number of root components as the profile,
    ///   - every *known* profile path appears among the archive's paths
    ///     (as a sub-multiset; unknown remote paths are wildcards),
    ///   - the archive's `thisRoot` is one of the profile's local roots
    ///     (so we only claim archives whose local side is ours), and
    ///   - the archive's `thisRoot` host shares this machine's hostname
    ///     lineage (same first label, case-insensitive).
    ///
    /// The hostname pin is what makes matching robust to *suffix* drift
    /// (`Heracles` ↔ `Heracles.local`) while still excluding archives from
    /// a *different* machine identity (`MacBookPro`) or test fixtures that
    /// happen to reuse the same local path. Those former-machine archives
    /// are true orphans for "Clean stale archives", not part of this
    /// profile's current reconciliation state. Suffix drift matches; a
    /// genuine rename does not (rare, and Clean stale covers it).
    ///
    /// `localHostname` is this machine's hostname (POSIX `gethostname`);
    /// only its first label is used.
    static func archives(forProfileRoots roots: [String],
                         in index: [ArchiveCleanup.ArchiveEntry],
                         localHostname: String) -> [ArchiveCleanup.ArchiveEntry] {
        let specs = rootSpecs(forRoots: roots)
        guard !specs.isEmpty else { return [] }
        let localPaths = Set(specs.filter { $0.isLocal }.compactMap { $0.path })
        guard !localPaths.isEmpty else { return [] }
        let knownPaths = specs.compactMap { $0.path }
        let rootCount = specs.count
        let localLabel = shortLabel(localHostname)

        return index.filter { entry in
            let comps = componentPaths(ofRootsName: entry.rootsName)
            guard comps.count == rootCount else { return false }
            guard let thisRootPath = fspath(ofComponent: entry.thisRoot),
                  localPaths.contains(thisRootPath) else { return false }
            // Local side must be this machine's hostname lineage.
            guard let thisRootHost = host(ofComponent: entry.thisRoot),
                  shortLabel(thisRootHost) == localLabel else { return false }
            // Every known profile path must be present among the archive's
            // component paths (multiset containment).
            var pool = comps.compactMap { $0 }
            for path in knownPaths {
                guard let idx = pool.firstIndex(of: path) else { return false }
                pool.remove(at: idx)
            }
            return true
        }
    }

    /// The *live* archives for a profile — what its next sync actually
    /// uses — which is what a Reset should clear. A Unison run loads only
    /// the archive named for the EXACT current hostname (`gethostname`),
    /// so only those are live. Archives under any other hostname (a
    /// `.local` suffix, a former machine name) are invisible to the next
    /// sync and are therefore stale, never live — they belong to "Clean
    /// stale archives", not Reset. A profile with no current-hostname
    /// archive (e.g. not synced since a rename) simply has no live
    /// archive: its next sync re-scans from scratch regardless.
    static func liveArchives(forProfileRoots roots: [String],
                             in index: [ArchiveCleanup.ArchiveEntry],
                             localHostname: String) -> [ArchiveCleanup.ArchiveEntry] {
        let current = localHostname.lowercased()
        return archives(forProfileRoots: roots, in: index, localHostname: localHostname)
            .filter { host(ofComponent: $0.thisRoot)?.lowercased() == current }
    }
}
