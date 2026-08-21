import Foundation

/// Resolves the *effective* roots (and rootaliases) of a Unison profile by
/// following `include` / `source` / `include?` / `source?` directives
/// recursively — the same way Unison's `prefs.ml` reads a profile — so that
/// "Clean Stale Archives" can attribute an archive to a profile whose roots
/// live in an included file rather than in the `.prf` itself.
///
/// Before this, profile collection read only the direct `root =` lines, so an
/// active archive whose roots came from an included file looked like a local
/// orphan and could start *checked* for deletion (Finding #9). This resolver
/// closes that gap and, crucially, is **conservative**: if resolution hits any
/// ambiguity it cannot prove past — a missing required file, an unreadable
/// file, a cycle, a bounded-traversal limit, or a malformed/`.raw` line that
/// Unison itself would reject — it reports `reliable == false`. The caller
/// treats an unreliable profile's archives as uncertain so they never start
/// as a confidently attributable, preselected deletion candidate.
///
/// ## Upstream semantics replicated (src/ubase/prefs.ml)
/// - `include f`  : `fileInUnisonDir(f)`; if that exact file exists use it,
///                  else `f.prf`. Missing ⇒ **fatal**.
/// - `source f`   : literal `fileInUnisonDir(f)` (never appends `.prf`).
///                  Missing ⇒ **fatal**.
/// - `include? f` / `source? f` : as above but a missing file is **silently
///                  skipped** (normal, not an error).
/// - Every token is resolved relative to the **Unison directory** (via
///   `Filename.concat`), including for nested includes — NOT relative to the
///   including file. A non-`=`, non-directive, non-comment line is fatal
///   (surfaces here as a `.raw` entry ⇒ unreliable).
///
/// Upstream has no cycle detection (a cyclic include would loop forever); we
/// add both a recursion-stack cycle check and a hard traversal bound so a
/// pathological profile degrades to "unreliable", never a hang.
enum ProfileRootResolver {

    /// The result of resolving a profile.
    struct Resolution: Equatable {
        /// All `root =` values reachable from the profile, in load order
        /// (duplicates preserved — matching what Unison would read).
        var roots: [String]
        /// All `rootalias =` values reachable from the profile. Their presence
        /// is an *attribution* concern handled by the caller (real roots differ
        /// from the `.prf`), separate from resolution `reliable`.
        var rootaliases: [String]
        /// True only when resolution was complete and unambiguous. False if any
        /// `issue` below was recorded.
        var reliable: Bool
        /// Why resolution was not reliable (empty ⇒ reliable). Order-preserving.
        var issues: [Issue]
    }

    enum Issue: Equatable {
        /// A required `include`/`source` target did not exist.
        case missingRequired(token: String)
        /// A file existed but could not be read (permissions, non-text, …).
        case unreadable(path: String)
        /// A file was re-encountered while still open on the include stack.
        case cycle(path: String)
        /// A line Unison would reject (`.raw`) was present — the profile would
        /// not load at all, so its roots cannot be trusted.
        case malformedLine(String)
        /// The traversal bound (file count or depth) was exceeded.
        case boundExceeded
    }

    /// Outcome of attempting to read a resolved path.
    enum ReadResult: Equatable {
        case ok(String)
        case missing
        case unreadable
    }

    /// Safety bounds. A real profile graph is tiny; these only exist to make a
    /// pathological or adversarial profile degrade gracefully to "unreliable"
    /// instead of hanging or exhausting resources.
    static let maxFiles = 256
    static let maxDepth = 64

    /// Resolve `profile` (a profile name WITHOUT the `.prf` extension) within
    /// `unisonDirectory`. `read` is injectable for tests; it defaults to the
    /// filesystem.
    static func resolve(
        unisonDirectory: String,
        profile: String,
        read: (String) -> ReadResult = ProfileRootResolver.filesystemRead
    ) -> Resolution {
        var roots: [String] = []
        var aliases: [String] = []
        var issues: [Issue] = []
        var stack: [String] = []          // canonical paths currently open (cycle detection)
        var openSet = Set<String>()
        var fileCount = 0
        var bounded = false

        func canonical(_ path: String) -> String {
            (path as NSString).standardizingPath
        }
        // Replicates `Util.fileInUnisonDir` = `Filename.concat unisonDir token`,
        // POSIX-normalized. An absolute-looking token collapses under the base
        // (matching OCaml + POSIX), so includes never escape to an arbitrary
        // absolute path the way a naive join might allow.
        func joined(_ token: String) -> String {
            canonical(unisonDirectory + "/" + token)
        }

        // Visit one directive/target. `addExt` mirrors upstream's `add_ext`
        // (`.prf` fallback), `required` mirrors non-`?` vs `?`.
        func visit(token: String, addExt: Bool, required: Bool) {
            if bounded { return }

            // Resolve the on-disk path exactly as `profilePathname` does.
            let base = joined(token)
            let path: String
            let result: ReadResult
            if !addExt {
                path = base
                result = read(base)
            } else {
                let baseResult = read(base)
                if baseResult == .missing {
                    path = joined(token + ".prf")
                    result = read(path)
                } else {
                    path = base
                    result = baseResult
                }
            }

            switch result {
            case .missing:
                if required { issues.append(.missingRequired(token: token)) }
                // optional-missing is normal (Unison silently skips): no issue.
            case .unreadable:
                // An existing-but-unreadable target is NOT proven absent, so —
                // unlike `.missing` — it is unsafe to skip even when OPTIONAL.
                // Two ways a read comes back `.unreadable`:
                //   (a) a regular file we can't decode as UTF-8. Unison reads
                //       profiles as bytes (Latin-1), so it may still load roots
                //       from a file we reject; we just can't see them.
                //   (b) the path exists but is a directory / FIFO / device /
                //       socket. Its mere existence changes resolution (for an
                //       `include` it suppresses the `.prf` fallback), and there
                //       are no roots we can read from it.
                // In both cases the roots are unknown, so attribution must stay
                // uncertain regardless of `required`. Only a proven `.missing`
                // optional target is safely skipped (handled above).
                issues.append(.unreadable(path: path))
            case .ok(let text):
                let cpath = canonical(path)
                if openSet.contains(cpath) {
                    issues.append(.cycle(path: cpath))
                    return
                }
                if fileCount >= maxFiles || stack.count >= maxDepth {
                    if !bounded { issues.append(.boundExceeded) }
                    bounded = true
                    return
                }
                fileCount += 1
                stack.append(cpath)
                openSet.insert(cpath)
                expand(text)
                stack.removeLast()
                openSet.remove(cpath)
            }
        }

        // Walk a parsed file's entries in order, collecting roots/aliases and
        // recursing into directives at their point of inclusion.
        func expand(_ text: String) {
            let doc = ProfileDocument.parse(text)
            for entry in doc.entries {
                if bounded { return }
                switch entry {
                case .keyValue(let key, let value):
                    if key == "root" { roots.append(value) }
                    else if key == "rootalias" { aliases.append(value) }
                case .directive(let d):
                    switch d.kind {
                    case .include:         visit(token: d.argument, addExt: true,  required: true)
                    case .source:          visit(token: d.argument, addExt: false, required: true)
                    case .includeOptional: visit(token: d.argument, addExt: true,  required: false)
                    case .sourceOptional:  visit(token: d.argument, addExt: false, required: false)
                    }
                case .raw(let line):
                    // Unison would reject this line and fail to load the whole
                    // profile — its roots cannot be trusted.
                    issues.append(.malformedLine(line))
                case .comment, .blank:
                    break
                }
            }
        }

        // The top-level profile is read exactly like `include <profile>`
        // (add_ext, required).
        visit(token: profile, addExt: true, required: true)

        return Resolution(roots: roots,
                          rootaliases: aliases,
                          reliable: issues.isEmpty,
                          issues: issues)
    }

    /// Default reader. The classification is deliberately precise because the
    /// caller treats `.missing` (optional ⇒ safely skipped) very differently
    /// from `.unreadable` (⇒ unreliable):
    ///
    /// - Path does not exist (symlinks followed) ⇒ `.missing`.
    /// - Path exists but is a **directory** ⇒ `.unreadable`. It is NOT missing:
    ///   its existence is what upstream sees, and for an `include` that
    ///   suppresses the `.prf` fallback. There are no profile roots to read.
    /// - Path exists but is **not a regular file** (FIFO, device, socket) ⇒
    ///   `.unreadable`, decided WITHOUT opening it. Opening a FIFO or device
    ///   could block indefinitely or have side effects; we only need to know
    ///   it exists and is not a readable profile.
    /// - A regular file we can decode as UTF-8 ⇒ `.ok`. A UTF-8 BOM, if
    ///   present, is stripped by the decoder (and defensively below), so a
    ///   BOM-prefixed profile parses like any other.
    /// - A regular file we cannot decode as UTF-8 (bad encoding, permissions)
    ///   ⇒ `.unreadable` — never `.missing`. Unison reads profiles as bytes,
    ///   so such a file may still carry roots we simply can't see.
    static func filesystemRead(_ path: String) -> ReadResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // fileExists follows symlinks and reports directory-ness of the target.
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .missing
        }
        if isDir.boolValue {
            return .unreadable
        }
        // Exists and is not a directory. Confirm it is a REGULAR file before
        // opening it, so a FIFO / device / socket at this path is classified
        // without a blocking open. `stat` follows symlinks, matching open().
        guard isRegularFile(path) else {
            return .unreadable
        }
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unreadable
        }
        // Defensively strip a leading UTF-8 BOM (U+FEFF). Foundation's UTF-8
        // decoder normally removes it, but stripping here guarantees the first
        // directive/line is never misparsed as `.raw` because of a BOM.
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return .ok(text)
    }

    /// Whether the path (after following symlinks) is a regular file. Uses
    /// `stat`, so it never opens the target — safe for FIFOs/devices.
    private static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }
}
