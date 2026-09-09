import Foundation

// The pure text transforms a write performs on a startup file: add the block,
// rewrite it with a new path, or remove it. No filesystem here; the writer feeds
// these the file's current bytes and places the result. Newline handling follows
// docs/command-line-setup-design.md, "Editable-file bound", rule 7.

enum CommandLineSetupEdit {

    /// The contents after appending `blockText` (its own four lines, no trailing
    /// newline) to a file with no block. A non-empty file without a final newline
    /// gets one first; the block is followed by a single newline. An empty file
    /// (creation) becomes exactly the block plus a newline.
    static func appended(to contents: String, blockText: String) -> String {
        if contents.isEmpty { return blockText + "\n" }
        let separator = contents.hasSuffix("\n") ? "" : "\n"
        return contents + separator + blockText + "\n"
    }

    /// The contents after replacing the block at lines `beginLine...endLine` with
    /// `newBlockText`. Text outside the block is byte-identical.
    static func rewritten(_ contents: String, beginLine: Int, endLine: Int, newBlockText: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        let newLines = newBlockText.components(separatedBy: "\n")
        lines.replaceSubrange(beginLine...endLine, with: newLines)
        return lines.joined(separator: "\n")
    }

    /// The contents after removing the block at lines `beginLine...endLine` and the
    /// newline after the end marker. The newline before the begin marker is kept,
    /// so text outside the block is byte-identical; a file whose block sat at the
    /// end with no final newline keeps a single trailing newline.
    static func removed(_ contents: String, beginLine: Int, endLine: Int) -> String {
        let lines = contents.components(separatedBy: "\n")
        let prefix = beginLine == 0 ? "" : lines[0..<beginLine].joined(separator: "\n") + "\n"
        let suffix = (endLine + 1) <= (lines.count - 1)
            ? lines[(endLine + 1)...].joined(separator: "\n")
            : ""
        return prefix + suffix
    }
}
