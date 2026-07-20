import Foundation

/// In-memory model of a Unison `.prf` file. Format:
///
///   # comment lines start with #
///   key = value
///   key = value   (same key can repeat for list-valued prefs like `ignore`)
///   (blank lines preserved)
///
/// The model preserves original line order, comments, and unknown keys so
/// round-tripping (read → no-op → write) doesn't lose user customizations
/// the editor doesn't know about (e.g. `sshcmd`, `perms`, `logfile`,
/// `servercmd`, `auto`, `rsrc`, `batch`, etc.).
///
/// Known list-valued keys are exposed via `values(forKey:)` /
/// `setValues(_:forKey:)`. Setting a list rewrites every existing entry
/// with that key, inserted at the position of the first old match.
struct ProfileDocument: Equatable {

    /// One of Unison's four inclusion directives (`prefs.ml`). `argument` is the
    /// LOGICAL (unescaped) filename; `lexeme` is the original full line, retained
    /// so an untouched directive serializes byte-for-byte. `lexeme == nil` means
    /// "render canonically" — used when the Includes UI creates or rewrites an
    /// ordinary `include`, which has no reusable original line.
    struct Directive: Equatable {
        enum Kind: Equatable {
            case include          // `include ` — profile name, `.prf` appended, fail if missing
            case source           // `source `  — literal file, fail if missing
            case includeOptional  // `include? ` — profile, missing file silently skipped
            case sourceOptional   // `source? `  — literal file, missing silently skipped

            var keyword: String {
                switch self {
                case .include:         return "include"
                case .source:          return "source"
                case .includeOptional: return "include?"
                case .sourceOptional:  return "source?"
                }
            }
        }
        var kind: Kind
        var argument: String
        var lexeme: String?
    }

    enum Entry: Equatable {
        case blank
        case comment(String)            // text after the leading `#`, with leading space trimmed
        case keyValue(key: String, value: String)
        case directive(Directive)       // include / source / include? / source? (no `=`)
        case raw(String)                // any other non-`=` line, preserved verbatim

        /// True if this entry is a key=value with the given key.
        func matches(key target: String) -> Bool {
            if case let .keyValue(k, _) = self { return k == target }
            return false
        }

        /// An editor-managed ordinary `include` (the only kind the Includes UI
        /// shows/edits). Derived from the kind — there is no separate flag.
        var isInclude: Bool {
            if case let .directive(d) = self, d.kind == .include { return true }
            return false
        }

        /// A directive the Includes UI does NOT manage (`source`/`include?`/
        /// `source?`). These are preserved verbatim and never edited here.
        var isPassThroughDirective: Bool {
            if case let .directive(d) = self, d.kind != .include { return true }
            return false
        }
    }

    /// Lines in original order. Unknown keys + comments survive a
    /// load → save round-trip in place.
    var entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    // MARK: - Parsing

    /// Parse a .prf string into entries. Lenient: malformed `key = value`
    /// lines (e.g. a value-less `key =`) are accepted with an empty value;
    /// lines that are neither comments nor key=value are treated as raw
    /// comments so we never destroy user content on save.
    static func parse(_ text: String) -> ProfileDocument {
        var doc = ProfileDocument()
        // Strip exactly one trailing newline so the conventional
        // "file ends with \n" doesn't add a phantom blank entry.
        // `split(omittingEmptySubsequences: false)` on "a\n" produces
        // ["a", ""], whereas we want ["a"]. Without this strip a
        // round-trip (parse → serialize → parse) would gain a blank
        // line every cycle.
        // Work at the Unicode SCALAR level for line splitting. Swift merges a
        // CRLF ("\r\n") into a single extended grapheme `Character`, so a
        // Character/Substring `split(separator: "\n")` would neither break CRLF
        // lines nor let us detect the trailing `\r` — it would silently fold the
        // CR into the newline. Splitting on the LF scalar (U+000A) keeps each
        // line's trailing CR attached as a lone `\r`, which `removeTrailingCR`
        // then strips. This mirrors Unison reading lines then `Util.removeTrailingCR`.
        var scalars = Array(text.unicodeScalars)
        if scalars.isEmpty { return doc }
        // Drop exactly one trailing newline terminator (matches the previous
        // `removeLast()` of a trailing "\n"); a lone "\n" file → empty document.
        if scalars.last == "\n" { scalars.removeLast() }
        if scalars.isEmpty { return doc }
        var rawLines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in scalars {
            if scalar == "\n" {
                rawLines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        rawLines.append(String(current))
        for line in rawLines {
            // `line` is the ORIGINAL lexeme (kept for verbatim directive/raw
            // serialization, including any trailing `\r`). `structural` is the
            // line Unison actually parses: exactly one trailing `\r` removed
            // (`Util.removeTrailingCR`). All recognition + word-splitting uses
            // `structural`; serialization of preserved entries uses `line`.
            let structural = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let trimmed = structural.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                doc.entries.append(.blank)
                continue
            }
            if trimmed.hasPrefix("#") {
                // Drop just the '#' (not subsequent characters, so `## hi`
                // round-trips with one leading `#` lost — acceptable).
                let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                doc.entries.append(.comment(body))
                continue
            }
            // Inclusion directives (`include`/`source`/`include?`/`source?`).
            // Mirror Unison (prefs.ml): recognition is on the RAW (structural)
            // line at column zero (leading whitespace ⇒ NOT a directive), and the
            // argument is one escape-aware word. Tri-state:
            //   .valid     → store `.directive` (lexeme = original `line`);
            //   .malformed → the line matched a directive prefix but did NOT
            //                produce exactly two words; store `.raw` and DO NOT
            //                fall through to key/value parsing (so e.g.
            //                `include one = two` is raw, not a key named
            //                "include one");
            //   .notDirective → fall through.
            // Checked before `=` so `include foo=bar` reads as a directive,
            // exactly as Unison does.
            switch ProfileDocument.classifyDirective(structuralLine: structural) {
            case .valid(let kind, let argument):
                doc.entries.append(.directive(Directive(kind: kind, argument: argument, lexeme: line)))
                continue
            case .malformed:
                doc.entries.append(.raw(line))
                continue
            case .notDirective:
                break
            }
            // key = value. Unison's parser is whitespace-tolerant around `=`.
            if let eq = structural.firstIndex(of: "=") {
                let key = structural[..<eq].trimmingCharacters(in: .whitespaces)
                let value = structural[structural.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    doc.entries.append(.keyValue(key: key, value: value))
                    continue
                }
            }
            // Anything else — a malformed directive, a non-`=` line Unison would
            // itself reject, etc. — is preserved verbatim as `.raw`. NEVER turned
            // into a comment (which would silently disable it) or normalized.
            doc.entries.append(.raw(line))
        }
        return doc
    }

    /// Tri-state classification of a structural line against the four inclusion
    /// directives. Distinguishes "this isn't a directive at all" from "this
    /// matched a directive prefix but is malformed" — the latter must become
    /// `.raw` and must NOT fall through to key/value parsing (a line like
    /// `include one = two` is a malformed directive, not a key `include one`).
    enum DirectiveClassification: Equatable {
        case notDirective
        case valid(kind: Directive.Kind, argument: String)
        case malformed
    }

    /// Classify a structural line (one trailing `\r` already removed). Mirrors
    /// `prefs.ml`: `Util.startswith` for each exact `"<keyword> "` prefix
    /// (column-zero, trailing space), then an escape-aware split that must yield
    /// exactly two words `[keyword; filename]`. The caller supplies the original
    /// lexeme when building the `.directive`.
    static func classifyDirective(structuralLine line: String) -> DirectiveClassification {
        let prefixes: [(String, Directive.Kind)] = [
            ("include? ", .includeOptional),
            ("source? ",  .sourceOptional),
            ("include ",  .include),
            ("source ",   .source),
        ]
        for (prefix, kind) in prefixes where line.hasPrefix(prefix) {
            let words = ProfileDocument.splitIntoWordsUnison(line)
            guard words.count == 2 else { return .malformed }
            return .valid(kind: kind, argument: words[1])
        }
        return .notDirective
    }

    // MARK: - Accessors

    /// All values for a key, in document order. Returns empty array when
    /// the key isn't present.
    func values(forKey key: String) -> [String] {
        entries.compactMap {
            if case let .keyValue(k, v) = $0, k == key { return v }
            return nil
        }
    }

    /// First (or only) value for a key, or nil. Convenience for
    /// known-single-value keys like `auto` or `batch`.
    func firstValue(forKey key: String) -> String? {
        values(forKey: key).first
    }

    /// Replace every entry with `key` with the given list of values, in
    /// order. Inserts at the position of the first previous match (or
    /// end of file if no previous match). Empty `values` removes all
    /// entries for the key.
    mutating func setValues(_ values: [String], forKey key: String) {
        let firstIdx = entries.firstIndex(where: { $0.matches(key: key) })
        entries.removeAll(where: { $0.matches(key: key) })
        let insertAt = firstIdx ?? entries.count
        let newEntries = values.map { Entry.keyValue(key: key, value: $0) }
        entries.insert(contentsOf: newEntries, at: min(insertAt, entries.count))
    }

    /// Set a single-valued key. Convenience over setValues for the common
    /// case. Pass nil to remove the key entirely.
    mutating func setValue(_ value: String?, forKey key: String) {
        if let value {
            setValues([value], forKey: key)
        } else {
            setValues([], forKey: key)
        }
    }

    /// Apply a mutually-exclusive conflict preference (`force` / `prefer`)
    /// in place. `key` is `"force"` or `"prefer"`; nil clears both.
    ///
    /// The chosen key is written with a single `setValue`, so it keeps its
    /// existing position; only the *other* key is cleared. Clearing both
    /// first and then re-adding would append the line at end-of-file — and
    /// with a bottom `include` present, that moved the line past the
    /// include so `setIncludes` then deleted the comment directly above it
    /// (the dropped `# path = …` regression). Setting in place avoids it.
    mutating func setConflict(key: String?, value: String?) {
        guard let key else {
            setValue(nil, forKey: "force")
            setValue(nil, forKey: "prefer")
            return
        }
        setValue(value, forKey: key)
        setValue(nil, forKey: key == "force" ? "prefer" : "force")
    }

    /// Like `values(forKey:)` but also surfaces `#` comment lines that sit
    /// directly above a value (as `# text`), so a freeform editor box can
    /// show and round-trip per-entry comments. A blank line between a comment
    /// and a value breaks the association (the comment is then left alone).
    func valuesWithComments(forKey key: String) -> [String] {
        var out: [String] = []
        for (i, e) in entries.enumerated() {
            guard case let .keyValue(k, v) = e, k == key else { continue }
            var comments: [String] = []
            var j = i - 1
            while j >= 0, case let .comment(c) = entries[j] {
                comments.append("# " + c); j -= 1
            }
            out.append(contentsOf: comments.reversed())
            out.append(v)
        }
        return out
    }

    /// Replace a key's values from box lines, treating `#`-prefixed lines as
    /// comments that attach to the value below them. Removes the old values
    /// and the comments directly above each, then inserts the rebuilt block
    /// where the key's first value was.
    mutating func setValuesWithComments(_ lines: [String], forKey key: String) {
        var newEntries: [Entry] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") {
                newEntries.append(.comment(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                newEntries.append(.keyValue(key: key, value: t))
            }
        }
        var remove = Set<Int>()
        for (i, e) in entries.enumerated() {
            guard case let .keyValue(k, _) = e, k == key else { continue }
            remove.insert(i)
            var j = i - 1
            while j >= 0, case .comment = entries[j], !remove.contains(j) {
                remove.insert(j); j -= 1
            }
        }
        let insertAt = remove.min() ?? entries.count
        for idx in remove.sorted(by: >) { entries.remove(at: idx) }
        entries.insert(contentsOf: newEntries, at: min(insertAt, entries.count))
    }

    /// All ordinary `include` directive names (logical/unescaped), in order.
    /// Pass-through directives (`source`/`include?`/`source?`) are excluded — the
    /// Includes UI neither shows nor manages them.
    var includes: [String] {
        entries.compactMap {
            if case let .directive(d) = $0, d.kind == .include { return d.argument }
            return nil
        }
    }

    /// True if the document contains a pass-through directive
    /// (`source`/`include?`/`source?`) the Includes UI does not manage.
    var hasPassThroughDirectives: Bool {
        entries.contains { $0.isPassThroughDirective }
    }

    /// True if the document contains any UNMANAGED ORDERED content the Includes
    /// UI cannot represent or safely re-order: a pass-through directive OR any
    /// `.raw` line. An includes edit is refused when this holds, and the
    /// low-level rebuild (`setIncludes`) refuses to run, so ordered content is
    /// never silently moved.
    var hasUnmanagedOrderedEntries: Bool {
        entries.contains { $0.isPassThroughDirective }
            || entries.contains { if case .raw = $0 { return true } else { return false } }
    }

    private var firstKeyValueIndex: Int? {
        entries.firstIndex { if case .keyValue = $0 { return true } else { return false } }
    }

    /// One include directive plus the optional comment line directly above it.
    struct IncludeEntry: Equatable {
        var name: String
        var comment: String   // empty = no comment line
    }

    /// `include` entries within an index range, each carrying the comment
    /// line directly above it (if any).
    private func includeList(in range: Range<Int>) -> [IncludeEntry] {
        range.compactMap { i -> IncludeEntry? in
            guard case let .directive(d) = entries[i], d.kind == .include else { return nil }
            var comment = ""
            if i > 0, case let .comment(c) = entries[i - 1] { comment = c }
            return IncludeEntry(name: d.argument, comment: comment)
        }
    }

    /// Includes before the first `key = value` pref. They load before the
    /// profile's own settings, so the profile overrides them (single-value
    /// prefs). With no prefs present, all includes are top.
    var topIncludes: [IncludeEntry] {
        guard let firstKV = firstKeyValueIndex else { return includeList(in: 0..<entries.count) }
        return includeList(in: 0..<firstKV)
    }

    /// Includes at/after the first pref — these override the profile's own
    /// single-value prefs.
    var bottomIncludes: [IncludeEntry] {
        guard let firstKV = firstKeyValueIndex else { return [] }
        return includeList(in: firstKV..<entries.count)
    }

    /// Replace ordinary `include` directives (kind == .include only). `top`
    /// entries land before the first pref line, `bottom` after the last. Each
    /// entry's non-empty comment is written as a `#` line directly above its
    /// `include`. The old ordinary includes and the comment directly above each
    /// are removed first, then rebuilt exactly once.
    ///
    /// SAFETY GUARD (Finding #7): this refuses — returns `false` without
    /// mutating anything — when the document contains unmanaged ordered content
    /// (a pass-through directive OR any `.raw` line), because a rebuild would
    /// reorder content the Includes UI cannot represent. The document-level API
    /// therefore cannot be bypassed to move ordered content, regardless of what
    /// the caller passes. On a permitted rebuild it returns `true`. Because a
    /// rebuild only runs when there is NO unmanaged content, the comment directly
    /// above a removed include is unambiguously that include's — no ownership
    /// heuristic is needed.
    @discardableResult
    mutating func setIncludes(top: [IncludeEntry], bottom: [IncludeEntry]) -> Bool {
        guard !hasUnmanagedOrderedEntries else { return false }

        var remove = Set<Int>()
        for (i, e) in entries.enumerated() where e.isInclude {
            remove.insert(i)
            if i > 0, case .comment = entries[i - 1], !remove.contains(i - 1) {
                remove.insert(i - 1)
            }
        }
        for idx in remove.sorted(by: >) { entries.remove(at: idx) }

        func build(_ list: [IncludeEntry]) -> [Entry] {
            var out: [Entry] = []
            for inc in list {
                let c = inc.comment.trimmingCharacters(in: .whitespaces)
                if !c.isEmpty { out.append(.comment(c)) }
                // UI-created/edited include ⇒ no reusable lexeme ⇒ render
                // canonically from the logical name (escaped on serialize).
                out.append(.directive(Directive(kind: .include, argument: inc.name, lexeme: nil)))
            }
            return out
        }
        let lastKV = entries.lastIndex { if case .keyValue = $0 { return true } else { return false } }
        let bottomAt = lastKV.map { $0 + 1 } ?? entries.count
        entries.insert(contentsOf: build(bottom), at: min(bottomAt, entries.count))

        let topAt = firstKeyValueIndex ?? 0
        var topBlock = build(top)
        // Fence the top block off from a preceding comment (typically the
        // file header) with a blank line, so the header isn't re-read as the
        // first include's comment on the next load. Load and the remove phase
        // above both treat a blank line as a boundary, so this round-trips
        // cleanly and doesn't accumulate blanks on repeated saves.
        if !topBlock.isEmpty, topAt > 0, case .comment = entries[topAt - 1] {
            topBlock.insert(.blank, at: 0)
        }
        entries.insert(contentsOf: topBlock, at: min(topAt, entries.count))
        return true
    }

    // MARK: - Serialization

    /// Render back to .prf text. Trailing newline is included so the file
    /// ends cleanly. Round-trip stable: `parse(s).serialized == s` for
    /// well-formed input (modulo trailing-newline normalization and the
    /// `# ` formatting of comments).
    var serialized: String {
        var lines: [String] = []
        lines.reserveCapacity(entries.count)
        for entry in entries {
            switch entry {
            case .blank:
                lines.append("")
            case .comment(let body):
                lines.append(body.isEmpty ? "#" : "# " + body)
            case .keyValue(let key, let value):
                lines.append("\(key) = \(value)")
            case .directive(let d):
                if let lexeme = d.lexeme {
                    // Untouched directive parsed from disk — emit byte-for-byte
                    // (preserves escaping, `.prf`-less names, exact spacing).
                    lines.append(lexeme)
                } else {
                    // UI-created/edited ordinary include — render canonically.
                    lines.append("\(d.kind.keyword) \(ProfileDocument.escapeWord(d.argument))")
                }
            case .raw(let text):
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Word escaping (mirrors Unison's Util.splitIntoWords, esc='\\')

    /// Split a line into escape-aware words exactly as Unison's
    /// `Util.splitIntoWords` does (esc = `\`, separator = space): a `\` makes the
    /// next char literal, a trailing `\` is dropped ("ignore final esc"), and
    /// runs of separators collapse (no empty words). The returned words are
    /// already UNESCAPED. Used to parse a directive's single filename argument
    /// and to require exactly `[keyword; filename]`.
    static func splitIntoWordsUnison(_ s: String) -> [String] {
        let chars = Array(s)
        let n = chars.count
        let esc: Character = "\\"
        let sep: Character = " "
        var words: [String] = []
        var i = 0
        while i < n {
            if chars[i] == sep { i += 1; continue }        // betweenwords: skip separators
            var word = ""
            while i < n && chars[i] != sep {               // inword
                if chars[i] == esc {
                    if i + 1 >= n { i += 1 }                // ignore final esc
                    else { word.append(chars[i + 1]); i += 2 }
                } else {
                    word.append(chars[i]); i += 1
                }
            }
            words.append(word)
        }
        return words
    }

    /// Escape a word so Unison reads it back as a single token: backslash and
    /// space (the escape char and the word separator) are prefixed with `\`.
    /// `File System Ignores` → `File\ System\ Ignores`.
    static func escapeWord(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "\\" || ch == " " { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Inverse of `escapeWord`: a `\` makes the following character literal
    /// (Unison's rule — any char, not just space/backslash). A trailing `\`
    /// is dropped, matching Unison's "ignore final esc".
    static func unescapeWord(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var it = s.makeIterator()
        while let ch = it.next() {
            if ch == "\\" {
                if let next = it.next() { out.append(next) }
                // trailing backslash: drop it
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Known keys (helpers shared with the editor UI)

    /// Keys Unison treats as list-valued. We pretty-print them as one
    /// entry per line in the editor.
    static let listValuedKeys: Set<String> = ["root", "path", "ignore", "ignorenot"]

    // MARK: - Includes UI reconciliation (Finding #7)

    /// The save-path decision for the Includes UI (Finding #7):
    ///   - `.unchanged`   — the user did not edit the Includes section; do NOT
    ///                      call setIncludes, so every include lexeme, directive,
    ///                      raw line, comment, and position is preserved exactly
    ///                      (even when the includes' displayed form is lossy).
    ///   - `.applyTopBottom` — includes were edited and the document has NO
    ///                      unmanaged ordered content; the Top/Bottom rebuild is
    ///                      safe (canonical rendering of the edited includes).
    ///   - `.refuseUnmanaged` — includes were edited AND the document contains
    ///                      unmanaged ordered content (`source`/`include?`/
    ///                      `source?` or any `.raw` line); refuse the save rather
    ///                      than reorder content the UI cannot represent.
    enum IncludeSaveDecision: Equatable { case unchanged, applyTopBottom, refuseUnmanaged }

    /// Pure decision used by the real save path AND the tests. No-op detection is
    /// driven by the editor's explicit dirty flag (`includesEdited`), NOT by
    /// comparing a lossy display projection — so an untouched Includes section
    /// always chooses `.unchanged` even if its displayed representation can't be
    /// reconstructed byte-for-byte.
    static func includeSaveDecision(includesEdited: Bool,
                                    hasUnmanagedOrderedEntries: Bool) -> IncludeSaveDecision {
        guard includesEdited else { return .unchanged }
        return hasUnmanagedOrderedEntries ? .refuseUnmanaged : .applyTopBottom
    }
}
