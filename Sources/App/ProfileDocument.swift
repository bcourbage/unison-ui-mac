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

        /// True if this entry is a key=value with the given key.
        func matches(key target: String) -> Bool {
            if case let .keyValue(k, _) = self { return k == target }
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
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Known keys (helpers shared with the editor UI)

    /// Keys Unison treats as list-valued. We pretty-print them as one
    /// entry per line in the editor.
    static let listValuedKeys: Set<String> = ["root", "path", "ignore", "ignorenot"]
}
