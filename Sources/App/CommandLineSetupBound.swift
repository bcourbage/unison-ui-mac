import Foundation

// Whether a zsh/bash startup file is inside the editable bound, and if so what
// operation its block state permits. See docs/command-line-setup-design.md,
// "Editable-file bound (zsh and bash)".
//
// The evaluation is pure: the two checks that need the outside world — a `-n`
// parse (a subprocess) and the file's metadata (stat and copyfile) — are passed
// in as results, so the bound's logic is testable without either. Ownership is
// passed in as a predicate on the block text, wired by the caller to the hash
// and the record.

enum CommandLineSetupBound {

    /// What the bound permits for a file, or why it refuses.
    enum Evaluation: Equatable {
        /// No block, and the file (or its absence) is editable: an append or a
        /// creation may add the block.
        case appendable
        /// An owned block is present and may be rewritten with the current path.
        /// `currentDirectory` is the directory the existing block records.
        case rewritable(beginLine: Int, endLine: Int, currentDirectory: String)
        /// A block is present that this app did not write, or that was edited.
        /// Manual setup; the pane shows the file and the block.
        case foreignBlock(reason: String)
        /// Outside the editable bound for another reason. Manual setup.
        case manualSetup(reason: String)
    }

    /// Rule 1: no line contains `<<` except lines byte-equal to a marker. The end
    /// marker contains `<<<` by design and is the sole exception, together with
    /// the begin marker for symmetry. Here-strings and comments containing `<<`
    /// are refused by the same rule; false refusals are accepted.
    static func containsHeredocOutsideMarkers(contents: String) -> Bool {
        for line in contents.components(separatedBy: "\n") {
            guard line.contains("<<") else { continue }
            if line == CommandLineSetupBlock.beginMarker || line == CommandLineSetupBlock.endMarker { continue }
            return true
        }
        return false
    }

    /// Evaluate the bound for a file that exists.
    ///
    /// - `contents`: the whole file text.
    /// - `wholeFileParses`: `zsh -n`/`bash -n` on the whole file exited 0.
    /// - `prefixParses`: the same on the text before the begin marker (empty for a
    ///   file with no block, which parses trivially: pass `true`).
    /// - `metadataOK`: rule 6 held (regular owned file, no immutable flag, copyfile
    ///   cloned its metadata).
    /// - `ownershipMatches`: whether the exact block text is owned by this account.
    static func evaluateExistingFile(contents: String,
                                     wholeFileParses: Bool,
                                     prefixParses: Bool,
                                     metadataOK: Bool,
                                     ownershipMatches: (String) -> Bool) -> Evaluation {
        // Rule 6 gates every edit of an existing file.
        guard metadataOK else {
            return .manualSetup(reason: "the file is not a regular file this account owns, or its metadata could not be preserved")
        }
        // Rule 1.
        if containsHeredocOutsideMarkers(contents: contents) {
            return .manualSetup(reason: "the file contains heredoc syntax (<<), which the app does not edit")
        }
        // Rule 2, whole file.
        guard wholeFileParses else {
            return .manualSetup(reason: "the file does not parse cleanly")
        }
        // Rule 3.
        switch CommandLineSetupBlock.markerArrangement(inContents: contents) {
        case .malformed(let reason):
            return .manualSetup(reason: "the app's markers are malformed: \(reason)")
        case .none:
            return .appendable
        case .single(let beginLine, let endLine):
            // Rule 2, prefix.
            guard prefixParses else {
                return .manualSetup(reason: "the text before the app's block does not parse cleanly")
            }
            let blockText = CommandLineSetupBlock.blockText(inContents: contents, beginLine: beginLine, endLine: endLine)
            // Rule 5.
            guard let directory = CommandLineSetupBlock.templateDirectory(ofBlockText: blockText) else {
                return .foreignBlock(reason: "a block with the app's markers exists but was edited or does not match the app's template")
            }
            // Rule 4.
            guard ownershipMatches(blockText) else {
                return .foreignBlock(reason: "a block with the app's markers exists that this app did not write, or that was edited")
            }
            return .rewritable(beginLine: beginLine, endLine: endLine, currentDirectory: directory)
        }
    }

    /// Evaluate the bound for a file that does not exist: a creation may add the
    /// block, provided the absence check and directory are handled by the writer.
    /// Nothing to parse or clone yet, so the only outcome is `appendable`.
    static func evaluateAbsentFile() -> Evaluation {
        .appendable
    }
}
