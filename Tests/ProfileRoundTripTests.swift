import XCTest
@testable import unison_ui_mac

/// PR-3 profile round-trip fixes at the model/pure-logic level. Each test targets
/// one reviewed defect and fails on pre-fix `main`:
///   B5  — a `#`-leading value (e.g. `path = #recycle`) must not become a comment.
///   SF4 — an extensionless include must not be rewritten to `<name>.prf`.
///   SF5 — duplicate scalar keys read last-wins; the form refuses editing them.
///   SF6 — Unison's `log` default is true (absent `log` is ON).
final class ProfileRoundTripTests: XCTestCase {

    private typealias D = ProfileDocument

    // MARK: - B5: a `#`-leading value survives the freeform box as a VALUE

    func test_b5_hashLeadingValue_roundTripsAsValue_notComment() {
        let doc = D.parse("root = /a\nroot = /b\npath = #recycle\n")
        // The box escapes the leading '#' so it reads back as a value.
        let box = doc.valuesWithComments(forKey: "path")
        XCTAssertEqual(box, ["\\#recycle"], "a #-leading value is escaped in the box")

        var edited = doc
        edited.setValuesWithComments(box, forKey: "path")
        XCTAssertEqual(edited.values(forKey: "path"), ["#recycle"],
                       "the escaped box line round-trips back to the literal value")
        XCTAssertTrue(edited.serialized.contains("path = #recycle"),
                      "the path restriction survives — not turned into a comment")
    }

    func test_b5_realCommentAboveValue_stillRoundTrips() {
        let doc = D.parse("# keep me\npath = docs\n")
        let box = doc.valuesWithComments(forKey: "path")
        XCTAssertEqual(box, ["# keep me", "docs"])
        var edited = doc
        edited.setValuesWithComments(box, forKey: "path")
        XCTAssertEqual(edited.values(forKey: "path"), ["docs"])
        XCTAssertTrue(edited.serialized.contains("# keep me"), "a real comment is preserved")
    }

    func test_b5_hashValueWithCommentAbove_bothPreserved() {
        var doc = D.parse("x = 1\n")
        doc.setValuesWithComments(["# the recycle bin", "\\#recycle"], forKey: "path")
        XCTAssertEqual(doc.values(forKey: "path"), ["#recycle"])
        let s = doc.serialized
        XCTAssertTrue(s.contains("# the recycle bin"))
        XCTAssertTrue(s.contains("path = #recycle"))
    }

    // MARK: - SF4: extensionless include detection

    func test_sf4_extensionlessInclude_isDetected() {
        XCTAssertTrue(D.parse("include common\n").hasExtensionlessInclude)
        XCTAssertTrue(D.parse("include base.conf\n").hasExtensionlessInclude,
                      "a non-.prf extension is still unsafe to strip/re-append")
        XCTAssertFalse(D.parse("include common.prf\n").hasExtensionlessInclude)
        XCTAssertFalse(D.parse("root = /a\n").hasExtensionlessInclude)
        // Pass-through directives are not ordinary includes → not counted here.
        XCTAssertFalse(D.parse("source literal.txt\n").hasExtensionlessInclude)
    }

    // MARK: - SF5: last-wins scalar reads + duplicate detection + effective write

    func test_sf5_lastValue_isEffectiveScalar() {
        let doc = D.parse("fastcheck = true\nfastcheck = false\n")
        XCTAssertEqual(doc.firstValue(forKey: "fastcheck"), "true")
        XCTAssertEqual(doc.lastValue(forKey: "fastcheck"), "false",
                       "Unison's effective value is the LAST occurrence")
    }

    func test_sf5_duplicatedScalarKeys_detected() {
        let doc = D.parse("fastcheck = true\nfastcheck = false\nauto = true\n")
        XCTAssertEqual(doc.duplicatedScalarKeys(among: ["fastcheck", "auto"]), ["fastcheck"])
        XCTAssertEqual(doc.duplicatedScalarKeys(among: ["auto"]), [],
                       "a key present once is not a duplicate")
    }

    func test_sf5_setValue_replacesEffectiveOccurrence_dropsEarlierDuplicates() {
        var doc = D.parse("root = /r\nfastcheck = true\ninclude a.prf\nfastcheck = false\n")
        doc.setValue("false", forKey: "fastcheck")
        // Collapsed to ONE entry, kept at the LAST (effective) position — after the
        // include — so ordering semantics are preserved, not moved to the first.
        XCTAssertEqual(doc.values(forKey: "fastcheck"), ["false"])
        let e = doc.entries
        let fcIdx = e.firstIndex { $0.matches(key: "fastcheck") }!
        let incIdx = e.firstIndex { if case .directive = $0 { return true } else { return false } }!
        XCTAssertGreaterThan(fcIdx, incIdx, "the effective occurrence stays after the include")
    }

    // MARK: - SF6: Unison `log` default is true

    func test_sf6_logEnabled_defaultsTrueWhenAbsent() {
        XCTAssertTrue(ProfileFormWindowController.logEnabled(nil), "absent log → Unison default true")
        XCTAssertTrue(ProfileFormWindowController.logEnabled("true"))
        XCTAssertFalse(ProfileFormWindowController.logEnabled("false"))
        XCTAssertFalse(ProfileFormWindowController.logEnabled("  FALSE "))
        XCTAssertTrue(ProfileFormWindowController.logEnabled("true"))
    }
}
