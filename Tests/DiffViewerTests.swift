import XCTest
import AppKit
@testable import unison_ui_mac

/// Pins the unified-diff line classification — the rule that decides
/// which lines render in green (added) / red (removed) / blue (hunk
/// header) / bold (file header). The classification is a pure static
/// on `DiffWindowController`, so we can test it without instantiating
/// the window.
///
/// The order of checks matters: 3-char prefixes (`+++`, `---`, `@@`)
/// must be tested before the 1-char ones (`+`, `-`) — otherwise the
/// file headers would land in green/red instead of bold-no-tint.
final class DiffViewerTests: XCTestCase {

    func test_addedLine_isGreen() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("+new content\n")
        XCTAssertEqual(color, .systemGreen)
        XCTAssertFalse(isBold)
    }

    func test_removedLine_isRed() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("-old content\n")
        XCTAssertEqual(color, .systemRed)
        XCTAssertFalse(isBold)
    }

    func test_hunkHeader_isBlue() {
        // The `@@` lines mark a position change in the diff.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("@@ -1,3 +1,4 @@\n")
        XCTAssertEqual(color, .systemBlue)
        XCTAssertFalse(isBold)
    }

    func test_pliusFileHeader_isBoldNotGreen() {
        // `+++ filename` is the destination-file header, not an added
        // line. Must NOT pick up the green that `+` lines get — would
        // be visually confusing.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("+++ b/foo.txt\n")
        XCTAssertNil(color, "file headers should render in default labelColor")
        XCTAssertTrue(isBold)
    }

    func test_minusFileHeader_isBoldNotRed() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("--- a/foo.txt\n")
        XCTAssertNil(color)
        XCTAssertTrue(isBold)
    }

    func test_contextLine_isDefault() {
        // Lines with a leading space are unchanged context. Default
        // styling — no color tint, no bold.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle(" unchanged line\n")
        XCTAssertNil(color)
        XCTAssertFalse(isBold)
    }

    func test_emptyLine_isDefault() {
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("\n")
        XCTAssertNil(color)
        XCTAssertFalse(isBold)
    }

    func test_arbitraryText_isDefault() {
        // Defensive — if the diff command emits something we don't
        // recognize (e.g. an error message Unison didn't intercept),
        // render it plainly rather than mistaking a leading char.
        let (color, isBold) = DiffWindowController.unifiedDiffLineStyle("Files differ\n")
        XCTAssertNil(color)
        XCTAssertFalse(isBold)
    }
}

/// The Diff window's presentation of an engine result (1.0 UI review P6):
/// the title names the file, the compared files are secondary, the command
/// line is behind Command…, and a `diff` exit status is read for the user.
final class DiffPresentationTests: XCTestCase {

    private let cmd = "diff -u '/private/tmp/x/.unison.a.txt' '/private/tmp/y/a.txt'"
    private let out = "--- /private/tmp/x/.unison.a.txt\n+++ /private/tmp/y/a.txt\n@@ -1 +1 @@\n-one\n+two\n\n\nExited with status 1"

    func test_make_titleIsFileName_endpointsParsed_statusInterpreted() {
        let p = DiffPresentation.make(path: "docs/a.txt", command: cmd, output: out)
        XCTAssertEqual(p.title, "Diff — a.txt")
        XCTAssertEqual(p.path, "docs/a.txt")
        XCTAssertEqual(p.endpoints, ["/private/tmp/x/.unison.a.txt", "/private/tmp/y/a.txt"])
        XCTAssertEqual(p.command, cmd)
        XCTAssertEqual(p.body, "--- /private/tmp/x/.unison.a.txt\n+++ /private/tmp/y/a.txt\n@@ -1 +1 @@\n-one\n+two\n")
        XCTAssertEqual(p.status, "Differences found.")
    }

    func test_splitStatus_recognizesTheThreeEngineForms_andLeavesOtherTextAlone() {
        XCTAssertEqual(DiffPresentation.splitStatus("x\n\nExited with status 2").statusLine, "Exited with status 2")
        XCTAssertEqual(DiffPresentation.splitStatus("x\n\nKilled by signal 9").statusLine, "Killed by signal 9")
        XCTAssertEqual(DiffPresentation.splitStatus("x\n\nStopped by signal 19").statusLine, "Stopped by signal 19")
        let plain = DiffPresentation.splitStatus("x\n\nnot a status")
        XCTAssertNil(plain.statusLine)
        XCTAssertEqual(plain.body, "x\n\nnot a status")
        XCTAssertNil(DiffPresentation.splitStatus("just output").statusLine)
    }

    func test_interpret_standardDiffCodes() {
        XCTAssertEqual(DiffPresentation.interpret(statusLine: "Exited with status 0", command: "diff -u 'a' 'b'"), "No differences.")
        XCTAssertEqual(DiffPresentation.interpret(statusLine: "Exited with status 1", command: "/usr/bin/diff -u 'a' 'b'"), "Differences found.")
        XCTAssertEqual(DiffPresentation.interpret(statusLine: "Exited with status 2", command: "diff 'a' 'b'"), "diff reported a problem (exit status 2).")
        XCTAssertEqual(DiffPresentation.interpret(statusLine: "Killed by signal 9", command: "diff 'a' 'b'"), "Killed by signal 9")
    }

    func test_interpret_customCommand_keepsRawStatus() {
        XCTAssertEqual(DiffPresentation.interpret(statusLine: "Exited with status 1", command: "opendiff 'a' 'b'"), "Exited with status 1")
        XCTAssertFalse(DiffPresentation.isStandardDiff("colordiff -u 'a' 'b'"))
        XCTAssertTrue(DiffPresentation.isStandardDiff("  diff -u 'a' 'b'"))
    }

    func test_fileOperands_handlesEscapedQuote_andUnquotedCommand() {
        XCTAssertEqual(DiffPresentation.fileOperands(in: "diff -u '/a/it'\\''s.txt' '/b/x'"), ["/a/it's.txt", "/b/x"])
        XCTAssertEqual(DiffPresentation.fileOperands(in: "diff -u a b"), [], "unquoted words are not the engine's paths")
        XCTAssertEqual(DiffPresentation.fileOperands(in: "diff -u 'unterminated"), [])
    }

    func test_fileOperands_ignoresQuotedOptionValues() {
        // Review finding: labels were taken for files.
        XCTAssertEqual(DiffPresentation.fileOperands(in: "diff -u -L 'Original' -L 'Updated' '/a/f1' '/b/f2'"),
                       ["/a/f1", "/b/f2"])
        XCTAssertEqual(DiffPresentation.fileOperands(in: "diff -u -L 'Original' '/a/f1'"), [],
                       "one path is not a pair; nothing is claimed")
        XCTAssertEqual(DiffPresentation.fileOperands(in: "diff -u '/a' '/b' '/c'"), [],
                       "three paths are ambiguous; nothing is claimed")
    }

    func test_pipeline_isNotStandardDiff_statusStaysRaw() {
        // Review finding: exit 0 of `diff … | cat` is the pipeline's, not diff's.
        for cmd in ["diff -u '/a' '/b' | cat", "diff -u '/a' '/b'; true", "diff -u '/a' '/b' && echo ok",
                    "diff -u '/a' '/b' > /tmp/out", "diff -u '/a' '/b' || true", "diff -u `echo '/a'` '/b'",
                    "diff -u $(echo '/a') '/b'", "diff -u '/a' '/b' &"] {
            XCTAssertFalse(DiffPresentation.isStandardDiff(cmd), cmd)
            XCTAssertEqual(DiffPresentation.interpret(statusLine: "Exited with status 0", command: cmd),
                           "Exited with status 0", cmd)
        }
        XCTAssertTrue(DiffPresentation.isStandardDiff("diff -u '/a|b' '/c;d'"), "operators inside quotes are text")
        XCTAssertTrue(DiffPresentation.isStandardDiff("diff -u -L 'x | y' '/a' '/b'"))
    }

    func test_newline_separatesCommands_quotedAndContinuationDoNot() {
        // Review finding: an unquoted newline is a command separator; the
        // status of `diff …\ntrue` is true's.
        let twoCommands = "diff -u '/a' '/b'\ntrue"
        XCTAssertFalse(DiffPresentation.isStandardDiff(twoCommands))
        XCTAssertEqual(DiffPresentation.interpret(statusLine: "Exited with status 0", command: twoCommands),
                       "Exited with status 0")
        XCTAssertFalse(DiffPresentation.isStandardDiff("diff -u '/a' '/b'\r\ntrue"))
        // A newline inside quotes is text, and backslash-newline continues the line.
        XCTAssertTrue(DiffPresentation.isStandardDiff("diff -u -L 'two\nlines' '/a' '/b'"))
        XCTAssertTrue(DiffPresentation.isStandardDiff("diff -u \\\n'/a' '/b'"))
        XCTAssertEqual(DiffPresentation.tokenize("diff \\\n-u").map(\.text), ["diff", "-u"])
        XCTAssertEqual(DiffPresentation.fileOperands(in: "diff -u \\\n'/a' '/b'"), ["/a", "/b"])
    }

    func test_tokenize_quotesAndOperators() {
        let t = DiffPresentation.tokenize("diff -u 'a b' \"c d\" e\\ f | cat")
        XCTAssertEqual(t.map(\.text), ["diff", "-u", "a b", "c d", "e f", "|", "cat"])
        XCTAssertEqual(t.map(\.quoted), [false, false, true, true, false, false, false])
        XCTAssertEqual(t.map(\.isOperator), [false, false, false, false, false, true, false])
    }

    @MainActor
    func test_window_showsNameEndpointsStatus_andHidesThemOnError() {
        let w = DiffWindowController()
        w.surfaceForLoading(path: "docs/a.txt")
        XCTAssertEqual(w.windowTitleForTesting, "Diff — a.txt")
        XCTAssertEqual(w.headerForTesting, "Generating diff for docs/a.txt…")
        XCTAssertFalse(w.commandButtonVisibleForTesting)
        w.showDiff(title: cmd, text: out)
        XCTAssertEqual(w.windowTitleForTesting, "Diff — a.txt")
        XCTAssertEqual(w.headerForTesting, "docs/a.txt")
        XCTAssertEqual(w.endpointsForTesting, "/private/tmp/x/.unison.a.txt\n/private/tmp/y/a.txt")
        XCTAssertEqual(w.statusForTesting, "Differences found.")
        XCTAssertTrue(w.commandButtonVisibleForTesting)
        XCTAssertFalse(w.bodyForTesting.contains("Exited with status"), "the status line is not in the diff body")
        w.showError("Can't diff: path doesn't refer to a file in both replicas")
        XCTAssertEqual(w.windowTitleForTesting, "Diff — error")
        XCTAssertNil(w.endpointsForTesting)
        XCTAssertNil(w.statusForTesting)
        XCTAssertFalse(w.commandButtonVisibleForTesting)
        w.close()
    }
}
