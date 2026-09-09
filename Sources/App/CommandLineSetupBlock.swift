import Foundation
import CryptoKit

// The marked block this app writes into a user's login-shell startup file, and
// the fish file it writes instead, plus the serialization and parsing they need.
// Everything here is pure text: no filesystem, no process. See
// docs/command-line-setup-design.md, "The PATH entry".
//
// The block puts `<bundle>/Contents/SharedSupport/bin` (the directory holding the
// in-bundle `unison` command, see CommandLineSetupBundle) at the front of PATH
// for login shells, so `unison` in Terminal resolves to this app. The app writes
// only this block; text outside it is never touched.

enum CommandLineSetupBlock {

    // MARK: Markers

    /// The begin and end marker lines for the zsh/bash block. A line is a marker
    /// only if it is byte-equal to one of these (leading/trailing text disqualifies
    /// it). The end marker contains `<<` by design; the editable-file bound treats
    /// these two lines as the sole permitted exception to its no-heredoc rule.
    static let beginMarker = "# >>> unison-ui-mac command >>>"
    static let endMarker = "# <<< unison-ui-mac command <<<"

    /// The fixed comment line inside the zsh/bash block.
    static let comment =
        "# Managed by Unison UI for macOS (Settings > Command Line). Text inside this block is rewritten by the app."

    /// The fixed comment line at the top of the fish file.
    static let fishComment =
        "# Managed by Unison UI for macOS (Settings > Command Line). This file is rewritten by the app."

    // MARK: Representability

    /// Whether a PATH directory can be carried by the entry at all. A colon would
    /// split it into two PATH components; a newline cannot sit on one line; and a
    /// path that is not valid UTF-8 cannot be serialized. A Swift `String` is
    /// always valid Unicode, so only the colon and newline can fail here; the
    /// UTF-8 case is documented for callers that hold raw bytes.
    static func isRepresentable(directory: String) -> Bool {
        !directory.contains(":") && !directory.contains("\n") && !directory.contains("\r")
    }

    // MARK: Serialization

    /// A POSIX single-quoted literal of `s`: wrap in `'…'` and write each embedded
    /// `'` as `'\''`. Measured in zsh and bash against `$USER`, `$(…)`, backticks,
    /// an apostrophe, spaces and a semicolon: no expansion, no substitution.
    static func posixSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A fish single-quoted literal of `s`. Inside fish single quotes only `\\`
    /// and `\'` are escapes; everything else is literal. Backslash is escaped
    /// first so the quote-escape's backslash is not doubled.
    static func fishSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    // MARK: Block text

    /// The four-line zsh/bash block for `directory`, joined by newlines with no
    /// trailing newline, or nil when `directory` is unrepresentable. The writer
    /// adds the surrounding newlines when placing it in a file.
    static func blockText(directory: String) -> String? {
        guard isRepresentable(directory: directory) else { return nil }
        return [
            beginMarker,
            comment,
            "export PATH=\(posixSingleQuoted(directory)):\"$PATH\"",
            endMarker,
        ].joined(separator: "\n")
    }

    /// The whole content of the fish file for `directory` (trailing newline
    /// included), or nil when `directory` is unrepresentable.
    static func fishFileText(directory: String) -> String? {
        guard isRepresentable(directory: directory) else { return nil }
        return [
            fishComment,
            "if status is-login",
            "    set -gx PATH \(fishSingleQuoted(directory)) $PATH",
            "end",
            "",
        ].joined(separator: "\n")
    }

    // MARK: Hashing

    /// The ownership hash of a block's exact text (the four lines as they appear
    /// in the file, begin marker through end marker, joined by newlines, no
    /// trailing newline). The same normalization is used when writing and when
    /// reading an existing block back, so the record round-trips.
    static func hash(ofBlockText text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Marker grammar

    /// How the marker lines are arranged in a file, deciding which write is legal.
    enum MarkerArrangement: Equatable {
        /// No marker line anywhere: an append may add the block.
        case none
        /// Exactly one begin marker followed later by exactly one end marker, both
        /// whole lines. The payload lines are `blockLines` (begin through end,
        /// inclusive), for a rewrite or removal.
        case single(beginLine: Int, endLine: Int)
        /// Any other arrangement (a lone marker, reversed order, duplicates, a
        /// marker mid-line). Refused.
        case malformed(reason: String)
    }

    /// Classify the marker lines of `contents`. Splitting on "\n" keeps a final
    /// empty element for a trailing newline, which does not affect marker counts.
    static func markerArrangement(inContents contents: String) -> MarkerArrangement {
        let lines = contents.components(separatedBy: "\n")
        var beginLines: [Int] = []
        var endLines: [Int] = []
        for (i, line) in lines.enumerated() {
            if line == beginMarker { beginLines.append(i) }
            if line == endMarker { endLines.append(i) }
        }
        switch (beginLines.count, endLines.count) {
        case (0, 0):
            return .none
        case (1, 1):
            guard beginLines[0] < endLines[0] else {
                return .malformed(reason: "the end marker comes before the begin marker")
            }
            return .single(beginLine: beginLines[0], endLine: endLines[0])
        default:
            return .malformed(reason: "the file has \(beginLines.count) begin and \(endLines.count) end markers")
        }
    }

    /// The exact text of the block delimited by a `.single` arrangement in
    /// `contents` (begin line through end line, joined by newlines, no trailing
    /// newline), for hashing and template matching.
    static func blockText(inContents contents: String, beginLine: Int, endLine: Int) -> String {
        let lines = contents.components(separatedBy: "\n")
        return lines[beginLine...endLine].joined(separator: "\n")
    }

    // MARK: Template match

    /// The bundle `bin` directory recorded by an existing block, or nil when the
    /// block does not match this app's template. A match requires the four lines
    /// in order: the begin marker, the fixed comment, an `export PATH=<single
    /// quoted>:"$PATH"` line, and the end marker. The single-quoted directory is
    /// decoded back (undoing `'\''`) and returned.
    static func templateDirectory(ofBlockText block: String) -> String? {
        let lines = block.components(separatedBy: "\n")
        guard lines.count == 4,
              lines[0] == beginMarker,
              lines[1] == comment,
              lines[3] == endMarker else { return nil }
        let prefix = "export PATH="
        let suffix = ":\"$PATH\""
        guard lines[2].hasPrefix(prefix), lines[2].hasSuffix(suffix) else { return nil }
        let quoted = String(lines[2].dropFirst(prefix.count).dropLast(suffix.count))
        return decodePosixSingleQuoted(quoted)
    }

    /// The bundle `bin` directory recorded by a fish file, or nil when the file is
    /// not this app's template. Whitespace is exact; a trailing newline is
    /// optional.
    static func fishTemplateDirectory(ofFileContents contents: String) -> String? {
        var lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 4,
              lines[0] == fishComment,
              lines[1] == "if status is-login",
              lines[3] == "end" else { return nil }
        let prefix = "    set -gx PATH "
        let suffix = " $PATH"
        guard lines[2].hasPrefix(prefix), lines[2].hasSuffix(suffix) else { return nil }
        let quoted = String(lines[2].dropFirst(prefix.count).dropLast(suffix.count))
        return decodeFishSingleQuoted(quoted)
    }

    /// Decode a POSIX single-quoted literal produced by `posixSingleQuoted`, or
    /// nil when it is not one. `posixSingleQuoted` encodes an embedded `'` as the
    /// shell concatenation `'\''` (close the quote, an escaped quote, reopen), so
    /// decoding strips the outer quotes and turns each `'\''` back into `'`.
    static func decodePosixSingleQuoted(_ s: String) -> String? {
        guard s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 else { return nil }
        let inner = String(s.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }

    /// Decode a fish single-quoted literal produced by `fishSingleQuoted`, or nil
    /// when it is not one.
    static func decodeFishSingleQuoted(_ s: String) -> String? {
        guard s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 else { return nil }
        let inner = Array(s.dropFirst().dropLast())
        var out = ""
        var i = 0
        while i < inner.count {
            if inner[i] == "\\" {
                guard i + 1 < inner.count, inner[i + 1] == "\\" || inner[i + 1] == "'" else { return nil }
                out.append(inner[i + 1])
                i += 2
            } else {
                out.append(inner[i])
                i += 1
            }
        }
        return out
    }
}
