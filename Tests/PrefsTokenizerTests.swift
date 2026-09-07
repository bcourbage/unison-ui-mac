import XCTest
@testable import unison_ui_mac

/// `PrefsTokenizer.splitIntoWords` against `Util.splitIntoWords`
/// (src/ubase/util.ml, upstream v2.54.0), one case per branch of the OCaml
/// function plus the shapes that matter for `sshargs` and `servercmd`.
final class PrefsTokenizerTests: XCTestCase {
    private func words(_ s: String) -> [String] { PrefsTokenizer.splitIntoWords(s) }

    func test_empty_andBlank_produceNoWords() {
        XCTAssertEqual(words(""), [])
        XCTAssertEqual(words("   "), [])
    }

    func test_runsOfSpaces_produceNoEmptyWords() {
        XCTAssertEqual(words("  a   b  "), ["a", "b"])
    }

    func test_tab_isNotASeparator() {
        XCTAssertEqual(words("-i\t/key   -p  2222"), ["-i\t/key", "-p", "2222"])
    }

    func test_escapeMidWord_isConsumed() {
        XCTAssertEqual(words("a\\bc"), ["abc"])
    }

    func test_escapedSpace_staysInsideTheWord() {
        XCTAssertEqual(words("My\\ Dir/unison -server"), ["My Dir/unison", "-server"])
    }

    func test_escapedBackslash_yieldsOneBackslash() {
        XCTAssertEqual(words("a\\\\b"), ["a\\b"])
    }

    func test_trailingLoneBackslash_isDropped() {
        XCTAssertEqual(words("abc\\"), ["abc"])
    }

    func test_loneBackslash_isAnEmptyWord() {
        // inword is entered before the escape is found to be final, so the
        // word it started is kept, empty. Upstream behaves the same.
        XCTAssertEqual(words("\\"), [""])
        XCTAssertEqual(words("a \\"), ["a", ""])
    }

    func test_typicalSshargs() {
        XCTAssertEqual(
            words("-i /Users/bcourbage/.ssh/Demeter -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"),
            ["-i", "/Users/bcourbage/.ssh/Demeter",
             "-o", "ServerAliveInterval=30",
             "-o", "StrictHostKeyChecking=accept-new"])
    }

    func test_quotes_areOrdinaryCharacters() {
        XCTAssertEqual(words("\"My Dir\"/unison -server"), ["\"My", "Dir\"/unison", "-server"])
    }

    func test_customSeparator() {
        XCTAssertEqual(PrefsTokenizer.splitIntoWords("a:b\\:c::d", separator: ":"), ["a", "b:c", "d"])
    }

    func test_joinedForRemoteShell_usesSingleSpaces() {
        XCTAssertEqual(PrefsTokenizer.joinedForRemoteShell(["My Dir/unison", "-server", "__new-rpc-mode"]),
                       "My Dir/unison -server __new-rpc-mode")
    }
}
