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
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0] == "include" {
                let name = parts[1].trimmingCharacters(in: .whitespaces)
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

    /// All `include` directive names, in document order.
    var includes: [String] {
        entries.compactMap { if case let .include(n) = $0 { return n } else { return nil } }
    }

    private var firstKeyValueIndex: Int? {
        entries.firstIndex { if case .keyValue = $0 { return true } else { return false } }
    }

    /// Include names that appear before the first `key = value` pref. These
    /// load before the profile's own settings, so the profile overrides them
    /// (for single-value prefs). With no prefs present, all includes are top.
    var topIncludes: [String] {
        guard let firstKV = firstKeyValueIndex else { return includes }
        return entries[..<firstKV].compactMap {
            if case let .include(n) = $0 { return n } else { return nil }
        }
    }

    /// Include names that appear at/after the first pref — these override the
    /// profile's own single-value prefs.
    var bottomIncludes: [String] {
        guard let firstKV = firstKeyValueIndex else { return [] }
        return entries[firstKV...].compactMap {
            if case let .include(n) = $0 { return n } else { return nil }
        }
    }

    /// Replace all `include` directives: `top` names land before the first
    /// pref line, `bottom` names after the last. Insert bottom first so the
    /// top insertion index stays valid.
    mutating func setIncludes(top: [String], bottom: [String]) {
        entries.removeAll(where: { $0.isInclude })
        let lastKV = entries.lastIndex { if case .keyValue = $0 { return true } else { return false } }
        let bottomAt = lastKV.map { $0 + 1 } ?? entries.count
        entries.insert(contentsOf: bottom.map { Entry.include($0) },
                       at: min(bottomAt, entries.count))
        let topAt = firstKeyValueIndex ?? 0
        entries.insert(contentsOf: top.map { Entry.include($0) }, at: min(topAt, entries.count))
    }

    /// Replace every `include` directive with the given names. New includes
    /// land at the top (before other prefs) so a profile's own scalar
    /// settings, which follow, override the included file's — while
    /// list-valued prefs (ignore/path) accumulate, as Unison intends.
    mutating func setIncludes(_ names: [String]) {
        let firstIdx = entries.firstIndex(where: { $0.isInclude })
        entries.removeAll(where: { $0.isInclude })
        let insertAt = firstIdx ?? 0
        entries.insert(contentsOf: names.map { Entry.include($0) },
                       at: min(insertAt, entries.count))
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
                lines.append("include \(name)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Known keys (helpers shared with the editor UI)

    /// Keys Unison treats as list-valued. We pretty-print them as one
    /// entry per line in the editor.
    static let listValuedKeys: Set<String> = ["root", "path", "ignore", "ignorenot"]
}
