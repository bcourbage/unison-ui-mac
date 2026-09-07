import XCTest
@testable import unison_ui_mac

/// `EffectiveProfile.load` against the grammar of `src/ubase/prefs.ml`
/// (`readAFile` / `parseLines` / `processLines`, upstream v2.54.0).
final class EffectiveProfileTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EffectiveProfileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dir = url.path
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8)
    }

    private func load(_ profile: String) -> Result<EffectiveProfile, EffectiveProfile.LoadError> {
        EffectiveProfile.load(profile: profile, unisonDirectory: dir)
    }

    private func loaded(_ profile: String, file: StaticString = #filePath, line: UInt = #line) throws -> EffectiveProfile {
        switch load(profile) {
        case .success(let p): return p
        case .failure(let e): XCTFail("unexpected failure: \(e.message)", file: file, line: line); throw e
        }
    }

    private func fatal(_ profile: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch load(profile) {
        case .success: XCTFail("expected a fatal error", file: file, line: line); return nil
        case .failure(.fatal(let m)): return m
        case .failure(let other): XCTFail("expected .fatal, got \(other)", file: file, line: line); return nil
        }
    }

    private func loc(_ profile: String) -> String {
        "Profile \"\(profile)\" (file \"\(dir!)/\(profile).prf\")"
    }

    // MARK: - Assignments and provenance

    func test_directAssignments_withLocations() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\nservercmd=/opt/homebrew/bin/unison\n")
        let p = try loaded("p")
        XCTAssertEqual(p.roots, ["/a", "ssh://h//b"])
        let s = p.scalar("servercmd")
        XCTAssertEqual(s?.value, "/opt/homebrew/bin/unison")
        XCTAssertEqual(s?.winner.location, ProfileLocation(locName: loc("p"), path: "\(dir!)/p.prf", line: 3))
        XCTAssertEqual(s?.overridden, [])
        XCTAssertEqual(p.files, ["\(dir!)/p.prf"])
        XCTAssertNil(p.scalar("sshargs"))
        XCTAssertNil(p.bool("addversionno"))
    }

    func test_bomAndCRLF_areAccepted() throws {
        try write("p.prf", "\u{FEFF}root = /a\r\nroot = ssh://h//b\r\nservercmd = x\r\n")
        let p = try loaded("p")
        XCTAssertEqual(p.roots, ["/a", "ssh://h//b"])
        XCTAssertEqual(p.scalar("servercmd")?.value, "x")
    }

    func test_commentsAndBlankLines_areSkipped_evenWithLeadingWhitespace() throws {
        try write("p.prf", "\n   \n# comment\n  \t# indented comment\nroot = /a\nroot = /b\n")
        XCTAssertEqual(try loaded("p").roots, ["/a", "/b"])
    }

    func test_valueKeepsInnerSpacesAndTrimsEnds() throws {
        try write("p.prf", "sshargs =   -i /k  -o A=1  \n")
        XCTAssertEqual(try loaded("p").scalar("sshargs")?.value, "-i /k  -o A=1")
    }

    func test_lastAssignmentWins_acrossInclude_withOverriddenListed() throws {
        try write("p.prf", "servercmd = /first\ninclude common\n")
        try write("common.prf", "servercmd = /second\n")
        let s = try loaded("p").scalar("servercmd")
        XCTAssertEqual(s?.value, "/second")
        XCTAssertEqual(s?.winner.location.path, "\(dir!)/common.prf")
        XCTAssertEqual(s?.winner.location.locName, loc("common"))
        XCTAssertEqual(s?.overridden.map(\.value), ["/first"])
        XCTAssertEqual(s?.overridden.first?.location.line, 1)
    }

    func test_topLevelAssignmentAfterInclude_overridesTheInclude() throws {
        try write("p.prf", "include common\nservercmd = /top\n")
        try write("common.prf", "servercmd = /inc\n")
        let s = try loaded("p").scalar("servercmd")
        XCTAssertEqual(s?.value, "/top")
        XCTAssertEqual(s?.overridden.map(\.location.path), ["\(dir!)/common.prf"])
    }

    func test_listsAccumulate_acrossInclude_inSplicedOrder() throws {
        try write("p.prf", "ignore = Name a\ninclude common\nignore = Name c\n")
        try write("common.prf", "ignore = Name b\n")
        XCTAssertEqual(try loaded("p").list("ignore").map(\.value), ["Name a", "Name b", "Name c"])
    }

    func test_aliasAssignments_matchTheirTarget() throws {
        try write("p.prf", "mirror = Name a\nbackup = Name b\nbackupversions = 3\n")
        let p = try loaded("p")
        XCTAssertEqual(p.list("backup").map(\.value), ["Name a", "Name b"])
        XCTAssertEqual(p.list("mirror").map(\.value), ["Name a", "Name b"])
        XCTAssertEqual(p.scalar("maxbackups")?.value, "3")
        XCTAssertEqual(p.scalar("maxbackups")?.winner.name, "backupversions")
    }

    func test_boolAccessor() throws {
        try write("p.prf", "addversionno = true\n")
        XCTAssertEqual(try loaded("p").bool("addversionno"), true)
        try write("q.prf", "addversionno = false\n")
        XCTAssertEqual(try loaded("q").bool("addversionno"), false)
    }

    // MARK: - Directives

    func test_include_prefersExactFileName_thenAppendsPrf() throws {
        try write("p.prf", "include common\n")
        try write("common.prf", "root = /from-prf\nroot = /x\n")
        XCTAssertEqual(try loaded("p").roots, ["/from-prf", "/x"])

        try write("q.prf", "include common.prf\n")
        XCTAssertEqual(try loaded("q").roots, ["/from-prf", "/x"])

        try write("exact", "root = /exact\nroot = /y\n")
        try write("exact.prf", "root = /prf\nroot = /z\n")
        try write("r.prf", "include exact\n")
        XCTAssertEqual(try loaded("r").roots, ["/exact", "/y"])
    }

    func test_source_readsLiteralName_andLocNameIsFile() throws {
        try write("p.prf", "source extra.settings\n")
        try write("extra.settings", "servercmd = /s\n")
        let s = try loaded("p").scalar("servercmd")
        XCTAssertEqual(s?.value, "/s")
        XCTAssertEqual(s?.winner.location.locName, "File \"\(dir!)/extra.settings\"")
    }

    func test_optionalDirectives_skipMissingTargets() throws {
        try write("p.prf", "include? nothere\nsource? nothere-either\nroot = /a\nroot = /b\n")
        XCTAssertEqual(try loaded("p").roots, ["/a", "/b"])
    }

    func test_missingInclude_isFatal_withUpstreamWording() throws {
        try write("p.prf", "root = /a\ninclude nothere\n")
        XCTAssertEqual(fatal("p"),
            "Included from profile \"p\" (file \"\(dir!)/p.prf\"), line 2:\n"
            + "Profile nothere not found (looking for file \(dir!)/nothere.prf)")
    }

    func test_missingSource_isFatal_withUpstreamWording() throws {
        try write("p.prf", "source nothere\n")
        XCTAssertEqual(fatal("p"),
            "Included from profile \"p\" (file \"\(dir!)/p.prf\"), line 1:\n"
            + "Preference file \(dir!)/nothere not found")
    }

    func test_nestedIncludeError_isWrappedAtEachLevel() throws {
        try write("p.prf", "include mid\n")
        try write("mid.prf", "\ninclude deep\n")
        XCTAssertEqual(fatal("p"),
            "Included from profile \"p\" (file \"\(dir!)/p.prf\"), line 1:\n"
            + "Included from profile \"mid\" (file \"\(dir!)/mid.prf\"), line 2:\n"
            + "Profile deep not found (looking for file \(dir!)/deep.prf)")
    }

    func test_garbledInclude_isFatal() throws {
        try write("p.prf", "include one two\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 1:\nGarbled 'include' directive: include one two")
    }

    func test_leadingWhitespaceBeforeInclude_isAGarbledLine() throws {
        try write("p.prf", "root = /a\n  include common\n")
        try write("common.prf", "root = /b\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 2:\nGarbled line (no '='):   include common")
    }

    func test_escapedSpaceInDirectiveArgument() throws {
        try write("p.prf", "include My\\ Settings\n")
        try write("My Settings.prf", "root = /a\nroot = /b\n")
        XCTAssertEqual(try loaded("p").roots, ["/a", "/b"])
    }

    func test_missingTopLevelProfile_isFatal() {
        XCTAssertEqual(fatal("absent"), "Profile absent not found (looking for file \(dir!)/absent.prf)")
    }

    func test_inclusionCycle_isReportedAsNotEstablished() throws {
        try write("p.prf", "include q\n")
        try write("q.prf", "include p\n")
        guard case .failure(.notEstablished(let m)) = load("p") else { return XCTFail("expected notEstablished") }
        XCTAssertTrue(m.contains("includes itself"), m)
    }

    func test_inclusionDepth_isBoundedAtSixteen() throws {
        // p includes c1, c1 includes c2, … : depth 16 loads, depth 17 does not.
        for i in 1...16 { try write("c\(i).prf", i < 16 ? "include c\(i + 1)\n" : "root = /a\nroot = /b\n") }
        try write("p.prf", "include c1\n")           // p + c1…c16 = 17 files deep
        guard case .failure(.notEstablished(let m)) = load("p") else { return XCTFail("expected notEstablished") }
        XCTAssertTrue(m.contains("inclusion depth exceeds 16"), m)
        try write("q.prf", "include c2\n")           // q + c2…c16 = 16 files deep
        XCTAssertEqual(try loaded("q").roots, ["/a", "/b"])
    }

    func test_totalFileReads_areBounded_forExponentialAcyclicGraphs() throws {
        // Each file includes the next one twice: 13 files would mean 2^13-1
        // reads upstream. The loader stops at the 65th read, well inside the
        // depth bound, and counts every read against the same budget.
        for i in 1...13 { try write("e\(i).prf", i < 13 ? "include e\(i + 1)\ninclude e\(i + 1)\n" : "servercmd = /x\n") }
        var reads = 0
        let r = EffectiveProfile.load(profile: "e1", unisonDirectory: dir) { path in
            let result = ProfileRootResolver.filesystemRead(path)
            if result != .missing { reads += 1 }
            return result
        }
        guard case .failure(.notEstablished(let m)) = r else { return XCTFail("expected notEstablished") }
        XCTAssertTrue(m.contains("more than 64 files"), m)
        // 64 successful opens plus the existence probes profilePathname makes.
        XCTAssertLessThan(reads, 200)
    }

    func test_repeatedInclude_withinBounds_isReadTwice() throws {
        try write("p.prf", "include c\ninclude c\n")
        try write("c.prf", "ignore = Name x\n")
        let p = try loaded("p")
        XCTAssertEqual(p.list("ignore").map(\.value), ["Name x", "Name x"])
        XCTAssertEqual(p.files, ["\(dir!)/p.prf", "\(dir!)/c.prf", "\(dir!)/c.prf"])
    }

    func test_unreadableFile_isNotEstablished() {
        let r = EffectiveProfile.load(profile: "p", unisonDirectory: "/u") { path in
            path.hasSuffix("p.prf") ? .unreadable : .missing
        }
        guard case .failure(.notEstablished(let m)) = r else { return XCTFail("expected notEstablished") }
        XCTAssertTrue(m.contains("could not be read as text"), m)
    }

    // MARK: - Processing

    func test_unknownOption_isFatal_withUpstreamWording() throws {
        try write("p.prf", "root = /a\nservercommand = x\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 2: `servercommand' is not a valid option")
    }

    func test_unknownOptionInsideInclude_namesTheIncludedFile() throws {
        try write("p.prf", "include common\n")
        try write("common.prf", "\n\nbogus = 1\n")
        XCTAssertEqual(fatal("p"), "\(loc("common")), line 3: `bogus' is not a valid option")
    }

    func test_pseudoPreference_isNotAValidOption() throws {
        try write("p.prf", "rootsName = x\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 1: `rootsName' is not a valid option")
    }

    func test_commandLineOnlyOption_isFatal_withUpstreamWording() throws {
        try write("p.prf", "ui = text\n")
        XCTAssertEqual(fatal("p"),
            "\(loc("p")), line 1: \"ui\" is a command line-only option; it must not be present in a profile.")
        try write("q.prf", "host = example\n")
        XCTAssertEqual(fatal("q"),
            "\(loc("q")), line 1: \"host\" is a command line-only option; it must not be present in a profile.")
    }

    func test_garbledLineWithoutEquals_isFatal() throws {
        try write("p.prf", "root /a\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 1:\nGarbled line (no '='): root /a")
    }

    func test_booleanValue_mustBeTrueOrFalse() throws {
        try write("p.prf", "addversionno = yes\n")
        XCTAssertEqual(fatal("p"), "addversionno expects a boolean value, but \nyes is not a boolean")
    }

    func test_integerValue_followsOCamlIntOfString() throws {
        try write("p.prf", "maxthreads = 1_0\nretry = -3\nheight = 0x1F\n")
        let p = try loaded("p")
        XCTAssertEqual(p.scalar("maxthreads")?.value, "1_0")
        try write("q.prf", "maxthreads = ten\n")
        XCTAssertEqual(fatal("q"), "maxthreads expects an integer value, but\nten is not an integer")
    }

    func test_isOCamlInt_syntax() {
        for ok in ["0", "42", "-7", "+3", "1_000", "0x1f", "0o17", "0b101", "0u5", "0_", "0X1F", "-0x1"] {
            XCTAssertTrue(EffectiveProfile.isOCamlInt(ok), ok)
        }
        for bad in ["", "-", "+", "x", "1.5", "_1", "0x", "0xg", "1 ", " 1", "0b2", "0o8", "1__2_a"] {
            XCTAssertFalse(EffectiveProfile.isOCamlInt(bad), bad)
        }
    }

    func test_isOCamlInt_range_matchesOCaml5IntOfString() {
        // Measured with `ocaml` 5.5.0 on 2026-09-07: the 63-bit int.
        XCTAssertTrue(EffectiveProfile.isOCamlInt("4611686018427387903"))    // max_int
        XCTAssertFalse(EffectiveProfile.isOCamlInt("4611686018427387904"))   // max_int + 1
        XCTAssertTrue(EffectiveProfile.isOCamlInt("-4611686018427387904"))   // min_int
        XCTAssertFalse(EffectiveProfile.isOCamlInt("-4611686018427387905"))
        XCTAssertFalse(EffectiveProfile.isOCamlInt("999999999999999999999999999999999999"))
        XCTAssertFalse(EffectiveProfile.isOCamlInt("99999999999999999999")) // > UInt64 too
        // Prefixed literals are unsigned: magnitudes below 2^63 are accepted
        // (and wrap), with either sign.
        XCTAssertTrue(EffectiveProfile.isOCamlInt("0x7fffffffffffffff"))
        XCTAssertFalse(EffectiveProfile.isOCamlInt("0x8000000000000000"))
        XCTAssertTrue(EffectiveProfile.isOCamlInt("-0x7fffffffffffffff"))
        XCTAssertTrue(EffectiveProfile.isOCamlInt("0u9223372036854775807"))
        XCTAssertFalse(EffectiveProfile.isOCamlInt("0u9223372036854775808"))
    }

    func test_integerOverflow_isFatal_withUpstreamWording() throws {
        try write("p.prf", "maxthreads = 999999999999999999999999999999999999\n")
        XCTAssertEqual(fatal("p"),
            "maxthreads expects an integer value, but\n999999999999999999999999999999999999 is not an integer")
    }

    // MARK: - Error ordering

    func test_parseTimeError_precedesProcessingError() throws {
        // Line 1 would fail processing (unknown option); line 3 fails parsing.
        try write("p.prf", "bogus = 1\nroot = /a\nroot /b\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 3:\nGarbled line (no '='): root /b")
    }

    func test_ofTwoParseErrors_theLaterLineIsReported() throws {
        try write("p.prf", "garbled one\nroot = /a\ngarbled two\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 3:\nGarbled line (no '='): garbled two")
    }

    func test_ofTwoProcessingErrors_theEarlierLineIsReported() throws {
        try write("p.prf", "first = 1\nsecond = 2\n")
        XCTAssertEqual(fatal("p"), "\(loc("p")), line 1: `first' is not a valid option")
    }

    // MARK: - Helpers

    func test_rawLines() {
        XCTAssertEqual(EffectiveProfile.rawLines(of: ""), [])
        XCTAssertEqual(EffectiveProfile.rawLines(of: "a\nb\n"), ["a", "b"])
        XCTAssertEqual(EffectiveProfile.rawLines(of: "a\nb"), ["a", "b"])
        XCTAssertEqual(EffectiveProfile.rawLines(of: "a\n\nb\n"), ["a", "", "b"])
        XCTAssertEqual(EffectiveProfile.rawLines(of: "\u{FEFF}a\n"), ["a"])
    }

    func test_trimWhitespace_andRemoveTrailingCR() {
        XCTAssertEqual(EffectiveProfile.trimWhitespace(" \t x y \r\n"), "x y")
        XCTAssertEqual(EffectiveProfile.removeTrailingCR("x\r\r"), "x\r")
        XCTAssertEqual(EffectiveProfile.uncapitalizeASCII("Profile \"p\""), "profile \"p\"")
        XCTAssertEqual(EffectiveProfile.uncapitalizeASCII("Éa"), "Éa")
    }
}
