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

    func test_quotedArguments_handlesEscapedQuote_andUnquotedCommand() {
        XCTAssertEqual(DiffPresentation.quotedArguments(in: "diff -u '/a/it'\\''s.txt' '/b/x'"), ["/a/it's.txt", "/b/x"])
        XCTAssertEqual(DiffPresentation.quotedArguments(in: "diff -u a b"), [])
        XCTAssertEqual(DiffPresentation.quotedArguments(in: "diff -u 'unterminated"), [])
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
