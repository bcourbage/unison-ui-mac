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

    enum Entry: Equatable {
        case blank
        case comment(String)            // text after the leading `#`, with leading space trimmed
        case keyValue(key: String, value: String)
        case include(String)            // `include <name>` directive (no `=`)

        /// True if this entry is a key=value with the given key.
        func matches(key target: String) -> Bool {
            if case let .keyValue(k, _) = self { return k == target }
            return false
        }

        var isInclude: Bool {
            if case .include = self { return true }
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
        var normalized = text
        if normalized.hasSuffix("\n") { normalized.removeLast() }
        // Empty input → empty document. (Without this short-circuit,
        // Swift's split returns `[""]` for an empty string, which would
        // emit a spurious blank entry.)
        if normalized.isEmpty { return doc }
        // split(omittingEmptySubsequences: false) keeps blank lines so we
        // can preserve them.
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
            // key = value. Unison's parser is whitespace-tolerant around `=`.
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    doc.entries.append(.keyValue(key: key, value: value))
                    continue
                }
            }
            // `include <name>` directive — pulls in another prefs file at
            // parse time. No `=`, so it must be handled before the
            // preserve-as-comment fallback or it would be commented out.
            // Unison parses the line with backslash-escaping (Util.splitIntoWords
            // with esc='\\'), so a name with spaces is written `include a\ b`.
            // We strip the keyword and unescape, storing the *logical* name.
            if trimmed == "include" || trimmed.hasPrefix("include ") {
                let raw = String(trimmed.dropFirst("include".count))
                    .drop(while: { $0 == " " })
                let name = ProfileDocument.unescapeWord(String(raw))
                if !name.isEmpty {
                    doc.entries.append(.include(name))
                    continue
                }
            }
            // Fallback — preserve verbatim as a comment so we never lose
            // data even if the file has something we don't understand.
            doc.entries.append(.comment(trimmed))
        }
        return doc
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

    /// All `include` directive names, in document order.
    var includes: [String] {
        entries.compactMap { if case let .include(n) = $0 { return n } else { return nil } }
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
            guard case let .include(n) = entries[i] else { return nil }
            var comment = ""
            if i > 0, case let .comment(c) = entries[i - 1] { comment = c }
            return IncludeEntry(name: n, comment: comment)
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

    /// Replace all `include` directives. `top` entries land before the first
    /// pref line, `bottom` after the last. Each entry's non-empty comment is
    /// written as a `#` line directly above its `include`. The old includes
    /// and the comments directly above them are removed first.
    mutating func setIncludes(top: [IncludeEntry], bottom: [IncludeEntry]) {
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
                out.append(.include(inc.name))
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
            case .include(let name):
                lines.append("include \(ProfileDocument.escapeWord(name))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Word escaping (mirrors Unison's Util.splitIntoWords, esc='\\')

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
}
