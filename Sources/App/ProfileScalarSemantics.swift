import Foundation

/// Where a surfaced scalar's effective value comes from.
enum ScalarProvenance: Equatable {
    /// No assignment in the top-level file or its includes; Unison's default applies.
    case `default`
    /// The winning assignment is in the top-level file, at this line.
    case local(line: Int)
    /// The winning assignment is in an included file.
    case inherited(file: String, line: Int)
}

/// The effective value and provenance of one surfaced scalar at load time.
struct ScalarState: Equatable {
    let key: String
    /// Nil when no assignment exists anywhere (Default provenance).
    let value: String?
    let provenance: ScalarProvenance
}

/// Effective-value semantics for the scalar settings the Profile Editor
/// surfaces with a dedicated control. The editor shows what Unison will use
/// (the last assignment in spliced order across the top-level file and its
/// includes) and, on Save, writes only what the user changed, placed so the
/// written line wins:
///
/// - an existing top-level line is rewritten in place when no include after
///   it sets the key, and moved to the end of the file when one does;
/// - an absent line is appended at the end;
/// - a line appended or moved to override an include is preceded by one
///   generated comment naming the include; the comment is recognized by its
///   text and reused, so repeated saves do not accumulate comments;
/// - clearing a value writes an explicit assignment that reproduces Unison's
///   default for that key whenever any include sets the key, because removing
///   the top-level lines would let the include's value take effect; with no
///   include setting the key the top-level lines are removed. Keys whose
///   default is computed are refused.
///
/// Included files are never edited.
enum ProfileScalarSemantics {

    // MARK: - Provenance

    /// The effective state of `key` for a profile whose top-level file is
    /// `topLevelPath` (the same path `EffectiveProfile.files.first` reports).
    static func state(for key: String, effective: EffectiveProfile, topLevelPath: String) -> ScalarState {
        guard let scalar = effective.scalar(key) else {
            return ScalarState(key: key, value: nil, provenance: .default)
        }
        let loc = scalar.winner.location
        if samePath(loc.path, topLevelPath) {
            return ScalarState(key: key, value: scalar.value, provenance: .local(line: loc.line))
        }
        return ScalarState(key: key, value: scalar.value,
                           provenance: .inherited(file: displayName(loc.path), line: loc.line))
    }

    /// The included file whose assignment of `key` would win over a top-level
    /// line written in place: the last assignment of `key` in spliced order
    /// when it is not in the top-level file. Nil when the top-level file's own
    /// assignment is last, or when no include sets the key.
    static func overridingInclude(for key: String, effective: EffectiveProfile, topLevelPath: String) -> String? {
        guard let last = effective.list(key).last else { return nil }
        if samePath(last.location.path, topLevelPath) { return nil }
        return displayName(last.location.path)
    }

    /// The included file whose assignment of `key` would become effective if
    /// every top-level line for the key were removed: the last include
    /// assignment in spliced order, wherever the top-level lines sit. Nil when
    /// no include sets the key.
    static func includeSetting(_ key: String, effective: EffectiveProfile, topLevelPath: String) -> String? {
        let fromIncludes = effective.list(key).filter { !samePath($0.location.path, topLevelPath) }
        guard let last = fromIncludes.last else { return nil }
        return displayName(last.location.path)
    }

    // MARK: - Generated comment

    /// Text (without the leading `#`) of the comment written above a line
    /// that overrides an include.
    static func generatedComment(include: String) -> String {
        "Overrides \(include): set here so this value takes effect"
    }

    static func isGeneratedComment(_ text: String) -> Bool {
        text.hasPrefix("Overrides ") && text.hasSuffix(": set here so this value takes effect")
    }

    // MARK: - Default overrides

    enum DefaultOverride: Equatable {
        /// Write this value as a top-level assignment to reproduce the default.
        case assignment(String)
        /// The default cannot be expressed as a local override.
        case refused(reason: String)
    }

    /// Per-key rule for "use Unison's default" when an include sets the key,
    /// from the upstream defaults at the vendored commit.
    static func defaultOverride(for key: String, include: String) -> DefaultOverride {
        switch key {
        case "servercmd", "sshargs", "prefer", "force":
            return .assignment("")
        case "sshcmd":
            return .assignment("ssh")
        case "times", "owner", "group", "dontchmod", "auto":
            return .assignment("false")
        case "log", "confirmbigdel":
            return .assignment("true")
        case "perms":
            return .assignment("1023")
        case "fastcheck", "rsrc":
            return .assignment("default")
        case "logfile":
            return .assignment("unison.log")
        default:
            return .refused(reason:
                "This app cannot express Unison's default for this setting as a local override. "
                + "Remove it from \(include) to use the default; that may affect other profiles that include it.")
        }
    }

    // MARK: - Applying a change

    enum Change: Equatable {
        case set(String)
        /// Use Unison's default.
        case clear
    }

    enum WriteOutcome: Equatable {
        case written
        case refused(String)
    }

    /// Apply one user change for `key` to the top-level document. `effective`
    /// is the profile as loaded (top-level plus includes); `topLevelPath` is
    /// its top-level file. Callers apply only keys whose control value differs
    /// from the loaded effective value; unchanged controls are never written.
    @discardableResult
    static func apply(_ change: Change, forKey key: String, to doc: inout ProfileDocument,
                      effective: EffectiveProfile, topLevelPath: String) -> WriteOutcome {
        let include = overridingInclude(for: key, effective: effective, topLevelPath: topLevelPath)
        switch change {
        case .set(let value):
            if let include {
                moveToEnd(key: key, value: value, overriding: include, in: &doc)
            } else {
                doc.setValue(value, forKey: key)
            }
            return .written
        case .clear:
            // Removing the top-level lines is enough only when no include sets
            // the key at all; otherwise the include's value would become
            // effective, so the default must be written as an override.
            guard let include = includeSetting(key, effective: effective, topLevelPath: topLevelPath) else {
                doc.setValue(nil, forKey: key)
                return .written
            }
            switch defaultOverride(for: key, include: include) {
            case .assignment(let value):
                moveToEnd(key: key, value: value, overriding: include, in: &doc)
                return .written
            case .refused(let reason):
                return .refused(reason)
            }
        }
    }

    /// Remove every top-level line for `key`, keeping the user comments that
    /// sat directly above the last one, and append: the kept comments, one
    /// generated comment, and the new line.
    private static func moveToEnd(key: String, value: String, overriding include: String, in doc: inout ProfileDocument) {
        var keptComments: [String] = []
        if let last = doc.entries.lastIndex(where: { $0.matches(key: key) }) {
            var j = last - 1
            var above: [String] = []
            while j >= 0, case let .comment(c) = doc.entries[j] {
                if !isGeneratedComment(c) { above.insert(c, at: 0) }
                j -= 1
            }
            keptComments = above
            // Remove the generated comment directly above any occurrence, then the lines.
            var remove = Set<Int>()
            for (i, e) in doc.entries.enumerated() where e.matches(key: key) {
                remove.insert(i)
                var k = i - 1
                while k >= 0, case let .comment(c) = doc.entries[k] {
                    if isGeneratedComment(c) { remove.insert(k) }
                    else if i == last { remove.insert(k) }   // user comments above the last line move with it
                    k -= 1
                }
            }
            for idx in remove.sorted(by: >) { doc.entries.remove(at: idx) }
        }
        // Drop a trailing blank so the block sits directly after the last content line.
        for c in keptComments { doc.entries.append(.comment(c)) }
        doc.entries.append(.comment(generatedComment(include: include)))
        doc.entries.append(.keyValue(key: key, value: value))
    }

    // MARK: - Conflict control (force / prefer)

    enum ConflictSelection: Equatable {
        case none
        case prefer(String)
        case force(String)
    }

    /// Write the combined conflict control. Upstream gives a nonempty `force`
    /// precedence over `prefer` (`recon.ml` `lookupPreferredRoot`), so
    /// selecting Prefer also neutralizes an effective nonempty `force`, and
    /// selecting None neutralizes whichever of the two is effective and
    /// nonempty. `forcepartial` and `preferpartial` are not touched.
    @discardableResult
    static func applyConflict(_ selection: ConflictSelection, to doc: inout ProfileDocument,
                              effective: EffectiveProfile, topLevelPath: String) -> [WriteOutcome] {
        func effectiveNonEmpty(_ key: String) -> Bool {
            !(effective.scalar(key)?.value.isEmpty ?? true)
        }
        var outcomes: [WriteOutcome] = []
        switch selection {
        case .force(let target):
            outcomes.append(apply(.set(target), forKey: "force", to: &doc, effective: effective, topLevelPath: topLevelPath))
        case .prefer(let target):
            outcomes.append(apply(.set(target), forKey: "prefer", to: &doc, effective: effective, topLevelPath: topLevelPath))
            if effectiveNonEmpty("force") {
                outcomes.append(apply(.clear, forKey: "force", to: &doc, effective: effective, topLevelPath: topLevelPath))
            }
        case .none:
            for key in ["force", "prefer"] where effectiveNonEmpty(key) {
                outcomes.append(apply(.clear, forKey: key, to: &doc, effective: effective, topLevelPath: topLevelPath))
            }
        }
        return outcomes
    }

    // MARK: - Helpers

    static func samePath(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }

    /// The path with every symlink resolved (`realpath(3)`), falling back to
    /// the standardized spelling when it does not exist.
    static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if let r = realpath(path, &buffer) { return String(cString: r) }
        return (path as NSString).standardizingPath
    }

    static func displayName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Which other profiles include a given file, for the shared-profile
/// disclosure shown before a save that changes a remote scalar.
enum ProfileConsumerScan {

    struct Result: Equatable {
        /// Profiles that include the target directly or transitively, with the
        /// host of their first ssh root when they have one.
        let consumers: [(profile: String, host: String?)]
        /// Profiles whose resolution failed; they may or may not include the target.
        let unresolved: [String]

        var isEmpty: Bool { consumers.isEmpty && unresolved.isEmpty }

        static func == (l: Result, r: Result) -> Bool {
            l.consumers.map(\.profile) == r.consumers.map(\.profile)
                && l.consumers.map(\.host) == r.consumers.map(\.host)
                && l.unresolved == r.unresolved
        }
    }

    /// Scan every `.prf` in `unisonDirectory` other than `excludingProfile`
    /// and report which ones read `targetPath`. Paths are compared with
    /// symlinks resolved, so a profile that reaches the target through
    /// `source alias` or an aliased directory is a consumer.
    static func scan(unisonDirectory: String, targetPath: String, excludingProfile: String,
                     read: @escaping (String) -> ProfileRootResolver.ReadResult = ProfileRootResolver.filesystemRead) -> Result {
        let target = ProfileScalarSemantics.canonicalPath(targetPath)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: unisonDirectory)) ?? [])
            .filter { $0.hasSuffix(".prf") }
            .map { String($0.dropLast(4)) }
            .filter { $0 != excludingProfile }
            .sorted()
        var consumers: [(profile: String, host: String?)] = []
        var unresolved: [String] = []
        for name in names {
            switch EffectiveProfile.load(profile: name, unisonDirectory: unisonDirectory, read: read) {
            case .success(let profile):
                let reads = profile.files.contains { ProfileScalarSemantics.canonicalPath($0) == target }
                if reads {
                    let host = profile.roots.lazy.compactMap { root -> String? in
                        if case .shell(_, let h, _, _, _) = try? UnisonRoot.parse(root) { return h }
                        return nil
                    }.first
                    consumers.append((profile: name, host: host))
                }
            case .failure:
                unresolved.append(name)
            }
        }
        return Result(consumers: consumers, unresolved: unresolved)
    }

    /// The disclosure text, or nil when nothing needs disclosing.
    static func disclosure(_ result: Result) -> String? {
        guard !result.isEmpty else { return nil }
        var lines: [String] = []
        if !result.consumers.isEmpty {
            let list = result.consumers.map { c in c.host.map { "\(c.profile) (\($0))" } ?? c.profile }
            lines.append("These profiles include this file and may be affected: " + list.joined(separator: ", ") + ".")
        }
        if !result.unresolved.isEmpty {
            lines.append("Could not be resolved: " + result.unresolved.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}
