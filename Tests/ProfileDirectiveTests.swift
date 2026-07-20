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

    private func item(_ n: String, _ top: Bool, _ c: String = "") -> D.IncludeUIItem {
        D.IncludeUIItem(name: n, top: top, comment: c)
    }

    func test_includeDecision_unchanged_skips() {
        let loaded = [item("Common", true), item("Shared", false)]
        XCTAssertEqual(D.includeSaveDecision(loaded: loaded, edited: loaded,
                                             hasPassThroughDirectives: false), .unchanged)
        // Unchanged wins even if pass-throughs exist — nothing is rebuilt.
        XCTAssertEqual(D.includeSaveDecision(loaded: loaded, edited: loaded,
                                             hasPassThroughDirectives: true), .unchanged)
    }

    func test_includeDecision_changedNoPassThrough_applies() {
        let loaded = [item("Common", true)]
        let edited = [item("Common", true), item("Extra", false)]
        XCTAssertEqual(D.includeSaveDecision(loaded: loaded, edited: edited,
                                             hasPassThroughDirectives: false), .applyTopBottom)
    }

    func test_includeDecision_changedWithPassThrough_refuses() {
        let loaded = [item("Common", true)]
        let edited = [item("Common", false)]   // moved Top→Bottom = a change
        XCTAssertEqual(D.includeSaveDecision(loaded: loaded, edited: edited,
                                             hasPassThroughDirectives: true), .refusePassThrough)
    }

    func test_hasPassThroughDirectives_flag() {
        XCTAssertFalse(D.parse("include Common\nroot = /a\n").hasPassThroughDirectives)
        XCTAssertTrue(D.parse("source /x\n").hasPassThroughDirectives)
        XCTAssertTrue(D.parse("include? m\n").hasPassThroughDirectives)
        XCTAssertTrue(D.parse("source? m\n").hasPassThroughDirectives)
    }

    // MARK: - setIncludes never consumes a raw's / pass-through's comment

    func test_setIncludes_doesNotStealCommentOwnedByRaw() {
        // Layout: raw, then a comment, then an include. The comment sits directly
        // above the include, but a `.raw` sits directly above the comment, so its
        // ownership is ambiguous → setIncludes must NOT remove it.
        var doc = D.parse("""
        weird raw directive-ish
        # belongs to the raw?
        include Common

        """)
        doc.setIncludes(top: [D.IncludeEntry(name: "Common", comment: "")], bottom: [])
        let ks = kinds(doc)
        XCTAssertTrue(ks.contains("raw|weird raw directive-ish"))
        XCTAssertTrue(ks.contains("#belongs to the raw?"), "comment above a raw must survive")
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
