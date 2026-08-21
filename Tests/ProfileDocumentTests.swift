import XCTest
@testable import unison_ui_mac

/// Tests for the .prf parser/serializer. Round-tripping a real-world
/// profile (with comments, blanks, multiple roots, multiple ignores,
/// quoted values, unknown keys) is the headline goal — we must not lose
/// user customizations when the editor opens-and-saves without changes.
final class ProfileDocumentTests: XCTestCase {

    // MARK: - Parsing

    func test_parse_empty_yieldsNoEntries() {
        // Empty file → zero entries. The trailing-newline normalization in
        // parse() keeps round-trips stable: an empty document serializes
        // to "\n" which re-parses to empty.
        XCTAssertEqual(ProfileDocument.parse("").entries, [])
        // Trailing-newline-only file is also empty (no content lines).
        XCTAssertEqual(ProfileDocument.parse("\n").entries, [])
    }

    func test_parse_trailingNewline_doesNotAddSpuriousBlank() {
        // A file ending with `\n` (the conventional form) shouldn't
        // gain a trailing blank entry. Two-line input should produce
        // two entries, not three.
        let doc = ProfileDocument.parse("root = /a\nignore = Name foo\n")
        XCTAssertEqual(doc.entries.count, 2)
        XCTAssertEqual(doc.firstValue(forKey: "root"), "/a")
        XCTAssertEqual(doc.firstValue(forKey: "ignore"), "Name foo")
    }

    func test_parse_simpleKeyValuePairs() {
        let doc = ProfileDocument.parse("""
            root = /tmp/a
            root = /tmp/b
            batch = true
            """)
        XCTAssertEqual(doc.values(forKey: "root"), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(doc.firstValue(forKey: "batch"), "true")
    }

    func test_parse_whitespaceAroundEquals_isTolerated() {
        let doc = ProfileDocument.parse("""
            key1=value1
            key2 =value2
            key3= value3
            key4   =   value4
            """)
        XCTAssertEqual(doc.firstValue(forKey: "key1"), "value1")
        XCTAssertEqual(doc.firstValue(forKey: "key2"), "value2")
        XCTAssertEqual(doc.firstValue(forKey: "key3"), "value3")
        XCTAssertEqual(doc.firstValue(forKey: "key4"), "value4")
    }

    func test_parse_commentsAndBlanks_arePreservedInOrder() {
        let text = """
            # Unison preferences file

            # Roots
            root = /tmp/a
            """
        let doc = ProfileDocument.parse(text)
        XCTAssertEqual(doc.entries, [
            .comment("Unison preferences file"),
            .blank,
            .comment("Roots"),
            .keyValue(key: "root", value: "/tmp/a"),
        ])
    }

    func test_parse_quotedValues_preserveTheirQuotingVerbatim() {
        // Unison treats `ignore = Name {.DS_Store}` as a raw string —
        // we shouldn't unwrap braces or quotes; just store the rhs as-is.
        let doc = ProfileDocument.parse("""
            ignore = Name {.DS_Store}
            ignore = Name "*.tmp"
            ignore = Path foo/bar
            """)
        XCTAssertEqual(doc.values(forKey: "ignore"), [
            "Name {.DS_Store}",
            "Name \"*.tmp\"",
            "Path foo/bar",
        ])
    }

    func test_parse_malformedLine_preservedVerbatimAsRaw() {
        // Finding #7: a line that's not blank, not a comment, not a directive,
        // and has no `=` is preserved VERBATIM as `.raw` (previously it was
        // turned into a comment, which silently disabled real directives). It
        // must survive a round-trip byte-for-byte, never `# `-prefixed.
        let doc = ProfileDocument.parse("this is not valid\n")
        XCTAssertEqual(doc.entries.first, .raw("this is not valid"))
        XCTAssertEqual(doc.serialized, "this is not valid\n")
    }

    // MARK: - Mutations

    func test_setValues_inEmptyDoc_appendsEntries() {
        var doc = ProfileDocument()
        doc.setValues(["one", "two"], forKey: "ignore")
        XCTAssertEqual(doc.values(forKey: "ignore"), ["one", "two"])
    }

    func test_setValues_replacesAllExistingEntriesForKey() {
        var doc = ProfileDocument.parse("""
            ignore = a
            ignore = b
            ignore = c
            other = x
            """)
        doc.setValues(["new1", "new2"], forKey: "ignore")
        XCTAssertEqual(doc.values(forKey: "ignore"), ["new1", "new2"])
        // Other keys untouched
        XCTAssertEqual(doc.firstValue(forKey: "other"), "x")
    }

    func test_setValues_emptyArray_removesAllEntriesForKey() {
        var doc = ProfileDocument.parse("ignore = a\nignore = b\n")
        doc.setValues([], forKey: "ignore")
        XCTAssertTrue(doc.values(forKey: "ignore").isEmpty)
    }

    func test_setValues_preservesPositionOfFirstOldMatch() {
        // Comment-bracketed key should keep its position when rewritten.
        var doc = ProfileDocument.parse("""
            # Roots
            root = /a
            # Paths
            path = sub
            # Ignores
            ignore = old1
            ignore = old2
            # End
            """)
        doc.setValues(["new1", "new2", "new3"], forKey: "ignore")
        // The "# Ignores" and "# End" comments are still in their original
        // positions; the ignore block grew from 2 to 3 entries.
        let kinds = doc.entries.map { entry -> String in
            switch entry {
            case .blank:                       return "blank"
            case .comment(let c):              return "# \(c)"
            case .keyValue(let k, let v):      return "\(k)=\(v)"
            case .directive(let d):            return "\(d.kind.keyword) \(d.argument)"
            case .raw(let s):                  return "raw \(s)"
            }
        }
        XCTAssertEqual(kinds, [
            "# Roots",
            "root=/a",
            "# Paths",
            "path=sub",
            "# Ignores",
            "ignore=new1",
            "ignore=new2",
            "ignore=new3",
            "# End",
        ])
    }

    // MARK: - Round-trip

    func test_roundTrip_preservesUnknownKeysAndComments() {
        // Snapshot of the kind of profile a real user has: a mix of
        // headers, known list-valued keys, single-value keys, and
        // advanced settings the editor doesn't expose.
        let original = """
            # Unison preferences file

            # Roots of the synchronization
            root = /Users/bob/
            root = ssh://bob@server/

            sshcmd = /usr/bin/ssh
            sshargs = -i /Users/bob/.ssh/id_rsa

            # Paths to synchronize
            path = Documents
            path = Pictures

            # Paths to ignore
            ignore = Name {.DS_Store}
            ignore = Path Documents/Drafts

            ignorenot = Path Documents/Important

            auto = true
            batch = true
            servercmd = /opt/homebrew/bin/unison
            """
        let doc = ProfileDocument.parse(original)
        // Round-trip should reproduce all keys including the advanced ones.
        XCTAssertEqual(doc.values(forKey: "root"), ["/Users/bob/", "ssh://bob@server/"])
        XCTAssertEqual(doc.values(forKey: "path"), ["Documents", "Pictures"])
        XCTAssertEqual(doc.values(forKey: "ignore"),
                       ["Name {.DS_Store}", "Path Documents/Drafts"])
        XCTAssertEqual(doc.values(forKey: "ignorenot"), ["Path Documents/Important"])
        XCTAssertEqual(doc.firstValue(forKey: "sshcmd"), "/usr/bin/ssh")
        XCTAssertEqual(doc.firstValue(forKey: "sshargs"), "-i /Users/bob/.ssh/id_rsa")
        XCTAssertEqual(doc.firstValue(forKey: "auto"), "true")
        XCTAssertEqual(doc.firstValue(forKey: "batch"), "true")
        XCTAssertEqual(doc.firstValue(forKey: "servercmd"), "/opt/homebrew/bin/unison")

        // Re-parsing the serialized form should reproduce the same doc
        // (structurally — comments/blanks/keys all equivalent).
        let reparsed = ProfileDocument.parse(doc.serialized)
        XCTAssertEqual(reparsed.entries, doc.entries)
    }

    func test_roundTrip_afterEdit_keepsUntouchedKeysIntact() {
        let original = """
            root = /a
            sshcmd = /usr/bin/ssh
            ignore = Name old
            auto = true
            """
        var doc = ProfileDocument.parse(original)
        doc.setValues(["Name new1", "Path new2"], forKey: "ignore")

        // sshcmd and auto must survive the ignore-edit unchanged.
        XCTAssertEqual(doc.firstValue(forKey: "sshcmd"), "/usr/bin/ssh")
        XCTAssertEqual(doc.firstValue(forKey: "auto"), "true")
        XCTAssertEqual(doc.firstValue(forKey: "root"), "/a")
        XCTAssertEqual(doc.values(forKey: "ignore"), ["Name new1", "Path new2"])
    }

    // MARK: - Known list-valued keys

    func test_listValuedKeys_matchesUnisonsConventions() {
        // Multi-valued in Unison: root, path, ignore, ignorenot. These
        // are the ones the editor renders as multi-line fields.
        XCTAssertEqual(ProfileDocument.listValuedKeys,
                       ["root", "path", "ignore", "ignorenot"])
    }

    // MARK: - include directives + word escaping

    func test_include_parse_andSerialize_roundTrip() {
        let doc = ProfileDocument.parse("include Common.prf\nroot = /a\n")
        XCTAssertEqual(doc.topIncludes.map(\.name), ["Common.prf"])
        XCTAssertEqual(doc.serialized, "include Common.prf\nroot = /a\n")
    }

    func test_include_escapedSpaces_parseUnescapes_serializeReEscapes() {
        // Unison reads `include a\ b` as the single word "a b".
        let doc = ProfileDocument.parse("include File\\ System\\ Ignores.prf\n")
        XCTAssertEqual(doc.topIncludes.map(\.name), ["File System Ignores.prf"])
        XCTAssertEqual(doc.serialized, "include File\\ System\\ Ignores.prf\n")
    }

    func test_escapeWord_unescapeWord_roundTrip() {
        for s in ["plain", "with space", "back\\slash", "a b\\c d", ""] {
            XCTAssertEqual(
                ProfileDocument.unescapeWord(ProfileDocument.escapeWord(s)), s,
                "round-trip failed for \(s.debugDescription)")
        }
        XCTAssertEqual(ProfileDocument.escapeWord("File System Ignores"),
                       "File\\ System\\ Ignores")
    }

    // MARK: - setIncludes: file-header fence (regression)

    func test_setIncludes_topInclude_doesNotStealFileHeader() {
        // A Top include is inserted just before the first pref. Without a
        // fence it would land directly under the file-header comment and,
        // on reload, claim that comment as its own. A blank line must
        // separate them.
        var doc = ProfileDocument.parse("# My profile header\nroot = /a\n")
        doc.setIncludes(
            top: [ProfileDocument.IncludeEntry(name: "Common.prf", comment: "")],
            bottom: [])
        // Header survives, and the include carries no comment on reload.
        let reloaded = ProfileDocument.parse(doc.serialized)
        XCTAssertEqual(reloaded.topIncludes.map(\.name), ["Common.prf"])
        XCTAssertEqual(reloaded.topIncludes.first?.comment, "")
        XCTAssertTrue(doc.serialized.contains("# My profile header"))
    }

    func test_setIncludes_topInclude_keepsItsOwnComment() {
        var doc = ProfileDocument.parse("# header\nroot = /a\n")
        doc.setIncludes(
            top: [ProfileDocument.IncludeEntry(name: "Common.prf", comment: "shared ignores")],
            bottom: [])
        let reloaded = ProfileDocument.parse(doc.serialized)
        XCTAssertEqual(reloaded.topIncludes.first?.comment, "shared ignores")
        XCTAssertTrue(doc.serialized.contains("# header"))
    }

    // MARK: - setConflict (force/prefer) — position-preserving (regression)

    func test_setConflict_setsInPlace_withoutMovingTheLine() {
        // The regression: re-applying `force` must not move it to EOF (which,
        // past a bottom include, let setIncludes eat a neighbouring comment).
        var doc = ProfileDocument.parse("# above\nforce = /old\nauto = true\n")
        doc.setConflict(key: "force", value: "/new")
        // force keeps its slot: still before `auto`, comment still above it.
        XCTAssertEqual(doc.serialized,
                       "# above\nforce = /new\nauto = true\n")
    }

    func test_setConflict_clearsTheOtherKey() {
        var doc = ProfileDocument.parse("prefer = newer\n")
        doc.setConflict(key: "force", value: "/x")
        XCTAssertEqual(doc.firstValue(forKey: "force"), "/x")
        XCTAssertNil(doc.firstValue(forKey: "prefer"))
    }

    func test_setConflict_nilClearsBoth() {
        var doc = ProfileDocument.parse("force = /x\nprefer = newer\nauto = true\n")
        doc.setConflict(key: nil, value: nil)
        XCTAssertNil(doc.firstValue(forKey: "force"))
        XCTAssertNil(doc.firstValue(forKey: "prefer"))
        XCTAssertEqual(doc.firstValue(forKey: "auto"), "true")
    }
}
