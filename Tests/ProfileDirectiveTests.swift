import XCTest
@testable import unison_ui_mac

/// Finding #7 — profile-directive preservation. `source`, `include?`, `source?`,
/// and arbitrary unknown non-`=` lines must survive a load→save round-trip
/// verbatim (previously they were silently turned into `# comments`), and an
/// includes edit must be refused when such ordered pass-through directives are
/// present rather than risk reordering hidden precedence.
///
/// Assertions favor directive/raw lexemes + relative positions; whole-file
/// serialized equality is only asserted for fixtures written in the document's
/// canonical form (`# comment`, `key = value`, one trailing newline).
final class ProfileDirectiveTests: XCTestCase {
    private typealias D = ProfileDocument
    private typealias K = ProfileDocument.Directive.Kind

    private func kinds(_ doc: ProfileDocument) -> [String] {
        doc.entries.map { e in
            switch e {
            case .blank:                  return "blank"
            case .comment(let c):         return "#\(c)"
            case .keyValue(let k, let v): return "\(k)=\(v)"
            case .directive(let d):       return "\(d.kind.keyword)|\(d.argument)|\(d.lexeme ?? "<nil>")"
            case .raw(let s):             return "raw|\(s)"
            }
        }
    }

    // MARK: - Parse + serialize: all four directive kinds, verbatim

    func test_fourDirectiveKinds_parseAndSerializeVerbatim() {
        let text = """
        include Common
        source /etc/unison/base
        include? MaybeMissing
        source? /etc/unison/optional

        """
        let doc = D.parse(text)
        // Correct kinds + logical args.
        let dirs = doc.entries.compactMap { if case let .directive(d) = $0 { return d } else { return nil } }
        XCTAssertEqual(dirs.map(\.kind), [.include, .source, .includeOptional, .sourceOptional])
        XCTAssertEqual(dirs.map(\.argument), ["Common", "/etc/unison/base", "MaybeMissing", "/etc/unison/optional"])
        // Verbatim round-trip.
        XCTAssertEqual(doc.serialized, text)
        // Idempotent.
        XCTAssertEqual(D.parse(doc.serialized).serialized, text)
    }

    // MARK: - Escaping, backslashes, repeats, optional

    func test_escapedSpaces_backslashes_escapedEquals_preservedVerbatim() {
        let text = """
        source /a\\ b/c\\ d
        include Weird\\=Name
        source C:\\\\share
        include? opt\\ ional

        """
        let doc = D.parse(text)
        let dirs = doc.entries.compactMap { if case let .directive(d) = $0 { return d } else { return nil } }
        // Logical args are unescaped exactly as Unison's splitIntoWords would.
        XCTAssertEqual(dirs[0].argument, "/a b/c d")
        XCTAssertEqual(dirs[1].argument, "Weird=Name")
        XCTAssertEqual(dirs[2].argument, "C:\\share")
        XCTAssertEqual(dirs[3].argument, "opt ional")
        // But the on-disk lexeme is preserved byte-for-byte (re-escaping from the
        // logical arg is NOT what happens for untouched directives).
        XCTAssertEqual(doc.serialized, text)
    }

    func test_repeatedDirectives_and_optionalMissing_preservedInOrder() {
        let text = """
        include Common
        include Common
        source? /gone

        """
        let doc = D.parse(text)
        XCTAssertEqual(doc.serialized, text)
        XCTAssertEqual(doc.includes, ["Common", "Common"])   // repeats kept
    }

    // MARK: - Column-zero recognition; leading whitespace / malformed → .raw

    func test_leadingWhitespaceDirective_isRawVerbatim_notADirective() {
        // Unison requires column-zero; a leading-space "include" is NOT a
        // directive (it would be a fatal garbled line). We preserve it as raw,
        // never silently "fix" or comment it.
        let text = "  include Common\n"
        let doc = D.parse(text)
        guard case let .raw(s) = doc.entries.first else { return XCTFail("expected .raw, got \(kinds(doc))") }
        XCTAssertEqual(s, "  include Common")
        XCTAssertEqual(doc.serialized, text)
        XCTAssertTrue(doc.includes.isEmpty, "a leading-whitespace include is not a managed include")
    }

    func test_malformedDirectiveLooking_isRaw() {
        // "include" with two filename words → not [keyword; file] → malformed →
        // .raw (Unison would fatal; we preserve).
        let text = "include one two\n"
        let doc = D.parse(text)
        guard case let .raw(s) = doc.entries.first else { return XCTFail("expected .raw, got \(kinds(doc))") }
        XCTAssertEqual(s, "include one two")
        XCTAssertEqual(doc.serialized, text)
    }

    func test_arbitraryUnknownNonEqualsLine_preservedVerbatimNotCommented() {
        let text = "this is not a preference line\n"
        let doc = D.parse(text)
        guard case let .raw(s) = doc.entries.first else { return XCTFail("expected .raw, got \(kinds(doc))") }
        XCTAssertEqual(s, "this is not a preference line")
        // NOT turned into "# this is not a preference line".
        XCTAssertEqual(doc.serialized, text)
    }

    // MARK: - Malformed directive-looking lines containing `=` must NOT fall
    //         through to key/value parsing (they stay .raw, verbatim)

    func test_malformedDirectiveWithEquals_staysRaw_notKeyValue() {
        // Once a line matches an exact directive prefix, failing the two-word rule
        // makes it .raw. It must never be reinterpreted as `key = value`, even
        // though it contains `=`. Covers all four directive prefixes.
        for line in ["include one = two",
                     "source one = two",
                     "include? one = two",
                     "source? one = two"] {
            let text = line + "\n"
            let doc = D.parse(text)
            guard case let .raw(s) = doc.entries.first else {
                return XCTFail("expected .raw for \(line), got \(kinds(doc))")
            }
            XCTAssertEqual(s, line)
            // Verbatim serialization — no key/value canonicalization applied.
            XCTAssertEqual(doc.serialized, text)
            // And explicitly: it is NOT a keyValue entry.
            if case .keyValue = doc.entries.first! {
                XCTFail("\(line) must not become a keyValue entry")
            }
        }
    }

    // MARK: - CRLF handling (Util.removeTrailingCR: strip one trailing \r)

    func test_crlf_allFourDirectiveKindsRecognized_argsHaveNoTrailingCR() {
        let text = "include Common\r\nsource /etc/base\r\ninclude? Maybe\r\nsource? /opt\r\n"
        let doc = D.parse(text)
        let dirs = doc.entries.compactMap { if case let .directive(d) = $0 { return d } else { return nil } }
        XCTAssertEqual(dirs.map(\.kind), [.include, .source, .includeOptional, .sourceOptional])
        // Logical arguments must be free of the trailing carriage return.
        XCTAssertEqual(dirs.map(\.argument), ["Common", "/etc/base", "Maybe", "/opt"])
        for d in dirs {
            XCTAssertFalse(d.argument.contains("\r"), "argument must not retain CR: \(d.argument)")
        }
    }

    func test_crlf_directiveLexemeRetainsLineEnding() {
        // The structural line (CR stripped) drives recognition, but the preserved
        // lexeme keeps the original CRLF so the file round-trips byte-for-byte.
        let text = "source /etc/base\r\n"
        let doc = D.parse(text)
        guard case let .directive(d) = doc.entries.first else {
            return XCTFail("expected .directive, got \(kinds(doc))")
        }
        XCTAssertEqual(d.argument, "/etc/base")
        XCTAssertEqual(d.lexeme, "source /etc/base\r")
        XCTAssertEqual(doc.serialized, text)
    }

    func test_crlf_rawLexemeRetainsLineEnding() {
        let text = "this is raw\r\n"
        let doc = D.parse(text)
        guard case let .raw(s) = doc.entries.first else {
            return XCTFail("expected .raw, got \(kinds(doc))")
        }
        // The raw lexeme keeps its CR so the byte-for-byte round-trip holds.
        XCTAssertEqual(s, "this is raw\r")
        XCTAssertEqual(doc.serialized, text)
    }

    func test_crlf_keyValueParsedFromStructuralLine() {
        // key/value recognition also uses the CR-stripped structural line, so the
        // value must not carry a trailing carriage return.
        let text = "root = /a\r\n"
        let doc = D.parse(text)
        guard case let .keyValue(k, v) = doc.entries.first else {
            return XCTFail("expected .keyValue, got \(kinds(doc))")
        }
        XCTAssertEqual(k, "root")
        XCTAssertEqual(v, "/a")
        XCTAssertFalse(v.contains("\r"))
    }

    // MARK: - Escaped leading/trailing-space include: untouched ⇒ verbatim

    func test_escapedLeadingTrailingSpaceInclude_roundTripsVerbatim() {
        // An include whose filename has escaped leading/trailing spaces is lossy to
        // display but must round-trip byte-for-byte when untouched (the on-disk
        // lexeme is preserved, never re-canonicalized).
        let text = "include \\ leading\\ and\\ trailing\\ \n"
        let doc = D.parse(text)
        let dirs = doc.entries.compactMap { if case let .directive(d) = $0 { return d } else { return nil } }
        XCTAssertEqual(dirs.count, 1)
        XCTAssertEqual(dirs[0].kind, .include)
        XCTAssertEqual(dirs[0].argument, " leading and trailing ")   // logical, unescaped
        XCTAssertEqual(doc.serialized, text)                          // lexeme verbatim
    }

    // MARK: - Directives before, between, and after key-value entries

    func test_directivesInterleavedWithPrefs_keepPositions() {
        let text = """
        source /before
        root = /a
        include? Mid
        root = /b
        source? /after

        """
        let doc = D.parse(text)
        XCTAssertEqual(kinds(doc), [
            "source|/before|source /before",
            "root=/a",
            "include?|Mid|include? Mid",
            "root=/b",
            "source?|/after|source? /after",
        ])
        XCTAssertEqual(doc.serialized, text)
    }

    // MARK: - Unchanged ordinary include retains lexeme incl. bare (no .prf)

    func test_bareInclude_retainsLexeme_noPrfAppendedOnUntouchedRoundTrip() {
        let text = "include ./sub/base\n"
        let doc = D.parse(text)
        // Logical arg is the bare name; serialization keeps the lexeme (no `.prf`
        // appended, which the old canonical path would have done).
        XCTAssertEqual(doc.includes, ["./sub/base"])
        XCTAssertEqual(doc.serialized, text)
    }

    // MARK: - Managed edit leaves directives + raw unchanged in position

    func test_managedRootIgnoreEdit_leavesDirectivesAndRawUntouched() {
        let text = """
        source /before
        root = /old
        # a raw-adjacent note
        junk raw line
        ignore = Name *.tmp

        """
        var doc = D.parse(text)
        doc.setValues(["/new1", "/new2"], forKey: "root")   // managed field edit
        doc.setValues(["Name *.o"], forKey: "ignore")
        // Directive + raw survive verbatim and in their relative order.
        XCTAssertEqual(kinds(doc), [
            "source|/before|source /before",
            "root=/new1",
            "root=/new2",
            "#a raw-adjacent note",
            "raw|junk raw line",
            "ignore=Name *.o",
        ])
    }

    // MARK: - Includes UI decision (the pure test seam)

    // The decision now depends only on an explicit editor-dirty flag plus whether
    // the document holds unmanaged ordered content — never on a lossy projection.

    func test_includeDecision_notEdited_isUnchanged() {
        // Untouched editor ⇒ .unchanged regardless of document content.
        XCTAssertEqual(D.includeSaveDecision(includesEdited: false,
            hasUnmanagedOrderedEntries: false, hasExtensionlessInclude: false), .unchanged)
        XCTAssertEqual(D.includeSaveDecision(includesEdited: false,
            hasUnmanagedOrderedEntries: true, hasExtensionlessInclude: true), .unchanged)
    }

    func test_includeDecision_editedNoUnmanaged_applies() {
        XCTAssertEqual(D.includeSaveDecision(includesEdited: true,
            hasUnmanagedOrderedEntries: false, hasExtensionlessInclude: false), .applyTopBottom)
    }

    func test_includeDecision_editedWithUnmanaged_refuses() {
        XCTAssertEqual(D.includeSaveDecision(includesEdited: true,
            hasUnmanagedOrderedEntries: true, hasExtensionlessInclude: false), .refuseUnmanaged)
    }

    // SF4: an edited includes section with an extensionless include refuses
    // (unmanaged takes precedence when both hold).
    func test_includeDecision_editedWithExtensionless_refuses() {
        XCTAssertEqual(D.includeSaveDecision(includesEdited: true,
            hasUnmanagedOrderedEntries: false, hasExtensionlessInclude: true), .refuseExtensionless)
        XCTAssertEqual(D.includeSaveDecision(includesEdited: true,
            hasUnmanagedOrderedEntries: true, hasExtensionlessInclude: true), .refuseUnmanaged)
    }

    func test_hasUnmanagedOrderedEntries_flag() {
        // Ordinary includes + managed key/values are fully manageable.
        XCTAssertFalse(D.parse("include Common\nroot = /a\n").hasUnmanagedOrderedEntries)
        // Pass-through directives count as unmanaged ordered content.
        XCTAssertTrue(D.parse("source /x\n").hasUnmanagedOrderedEntries)
        XCTAssertTrue(D.parse("include? m\n").hasUnmanagedOrderedEntries)
        XCTAssertTrue(D.parse("source? m\n").hasUnmanagedOrderedEntries)
        // Any raw (unrecognized / malformed) line also counts.
        XCTAssertTrue(D.parse("some raw junk\n").hasUnmanagedOrderedEntries)
    }

    // MARK: - setIncludes is a hard no-op when unmanaged content is present

    func test_setIncludes_refusesWhenUnmanagedContentPresent() {
        // A `.raw` line makes the whole document unmanaged-ordered. The low-level
        // rebuild must refuse (return false) and leave the document byte-identical,
        // so no comment — the raw's or the include's — is ever disturbed.
        let text = """
        weird raw directive-ish
        # belongs to the raw?
        include Common

        """
        var doc = D.parse(text)
        let applied = doc.setIncludes(top: [D.IncludeEntry(name: "Common", comment: "")], bottom: [])
        XCTAssertFalse(applied, "setIncludes must refuse when unmanaged content is present")
        XCTAssertEqual(doc.serialized, text, "document must be untouched on refusal")
    }

    func test_setIncludes_commentPrecedingUnmanagedDirectiveUntouched() {
        // A comment sits directly above a pass-through directive. Because the
        // document is unmanaged-ordered, setIncludes refuses and the comment stays.
        let text = """
        include Common
        # notes for the source below
        source /etc/base

        """
        var doc = D.parse(text)
        let applied = doc.setIncludes(top: [D.IncludeEntry(name: "Common", comment: "")], bottom: [])
        XCTAssertFalse(applied)
        XCTAssertEqual(doc.serialized, text)
    }

    func test_setIncludes_rebuildsManagedCommentExactlyOnce() {
        // Fully managed document (includes + key/values only): rebuild is permitted.
        // Each managed include's directly-associated comment must appear exactly
        // once after the rebuild — never duplicated, never dropped onto a neighbor.
        var doc = D.parse("""
        # comment for Common
        include Common
        root = /a

        """)
        // IncludeEntry.comment holds the comment BODY (no leading '#'); serialize
        // re-adds "# ".
        let applied = doc.setIncludes(
            top: [D.IncludeEntry(name: "Common", comment: "comment for Common")],
            bottom: [])
        XCTAssertTrue(applied)
        let occurrences = doc.serialized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 == "# comment for Common" }
            .count
        XCTAssertEqual(occurrences, 1, "the managed include's comment must occur exactly once")
    }

    // MARK: - Pass-through directives + unchanged includes survive a save

    func test_unchangedIncludes_withPassThroughs_everythingPreserved() {
        // Simulate the production skip path: includes unchanged (decision would be
        // .unchanged) ⇒ setIncludes is NOT called ⇒ the whole document, including
        // source/include? and their comments, round-trips verbatim.
        let text = """
        # header
        include Common
        root = /a
        # notes for the source below
        source /etc/base
        include? Optional

        """
        let doc = D.parse(text)
        // No mutation to includes (production skips setIncludes on .unchanged).
        XCTAssertEqual(doc.serialized, text)
        XCTAssertEqual(D.parse(doc.serialized).serialized, text)   // idempotent
    }
}
