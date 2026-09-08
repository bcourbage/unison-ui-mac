import XCTest
@testable import unison_ui_mac

/// Effective-value semantics for surfaced scalars: provenance, save
/// placement with the generated comment, per-key default overrides, the
/// coupled conflict control, and the shared-profile scan.
final class ProfileScalarSemanticsTests: XCTestCase {
    private typealias S = ProfileScalarSemantics
    private var dir: String!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileScalarSemanticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dir = url.path
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }

    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }
    private func read(_ name: String) throws -> String { try String(contentsOfFile: "\(dir!)/\(name)", encoding: .utf8) }
    private func top(_ profile: String) -> String { "\(dir!)/\(profile).prf" }
    private func effective(_ profile: String) throws -> EffectiveProfile {
        switch EffectiveProfile.load(profile: profile, unisonDirectory: dir) {
        case .success(let e): return e
        case .failure(let err): XCTFail(err.message); throw err
        }
    }
    /// Load, apply, serialize, and return the saved text.
    private func save(_ profile: String, _ body: (inout ProfileDocument, EffectiveProfile) -> Void) throws -> String {
        let eff = try effective(profile)
        var doc = ProfileDocument.parse(try read("\(profile).prf"))
        body(&doc, eff)
        let text = doc.serialized
        try write("\(profile).prf", text)
        return text
    }

    // MARK: - Provenance

    func test_provenance_default_local_inherited() throws {
        try write("p.prf", "root = /a\nroot = /b\nsshcmd = /usr/bin/ssh\ninclude common\n")
        try write("common.prf", "servercmd = /opt/homebrew/bin/unison\n")
        let e = try effective("p")
        XCTAssertEqual(S.state(for: "sshargs", effective: e, topLevelPath: top("p")), .init(key: "sshargs", value: nil, provenance: .default))
        XCTAssertEqual(S.state(for: "sshcmd", effective: e, topLevelPath: top("p")), .init(key: "sshcmd", value: "/usr/bin/ssh", provenance: .local(line: 3)))
        XCTAssertEqual(S.state(for: "servercmd", effective: e, topLevelPath: top("p")),
                       .init(key: "servercmd", value: "/opt/homebrew/bin/unison", provenance: .inherited(file: "common.prf", line: 1)))
    }

    func test_provenance_topLevelAfterInclude_isLocal() throws {
        try write("p.prf", "include common\nservercmd = /top\n")
        try write("common.prf", "servercmd = /inc\n")
        let e = try effective("p")
        XCTAssertEqual(S.state(for: "servercmd", effective: e, topLevelPath: top("p")).provenance, .local(line: 2))
        XCTAssertNil(S.overridingInclude(for: "servercmd", effective: e, topLevelPath: top("p")))
    }

    func test_overridingInclude_whenIncludeSetsAfterTopLevel() throws {
        try write("p.prf", "servercmd = /top\ninclude common\n")
        try write("common.prf", "servercmd = /inc\n")
        let e = try effective("p")
        XCTAssertEqual(S.overridingInclude(for: "servercmd", effective: e, topLevelPath: top("p")), "common.prf")
    }

    // MARK: - Set

    func test_set_local_inPlace_whenNoIncludeAfter() throws {
        try write("p.prf", "include common\nservercmd = /top\nroot = /a\nroot = /b\n")
        try write("common.prf", "servercmd = /inc\n")
        let text = try save("p") { doc, e in
            XCTAssertEqual(S.apply(.set("/new"), forKey: "servercmd", to: &doc, effective: e, topLevelPath: self.top("p")), .written)
        }
        XCTAssertEqual(text, "include common\nservercmd = /new\nroot = /a\nroot = /b\n")
    }

    func test_set_absent_appendsAtEnd_afterIncludes_withComment() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\nignore = Name x\n")
        try write("common.prf", "servercmd = /inc\n")
        let text = try save("p") { doc, e in
            S.apply(.set("/opt/homebrew/bin/unison"), forKey: "servercmd", to: &doc, effective: e, topLevelPath: self.top("p"))
        }
        XCTAssertEqual(text, "root = /a\nroot = ssh://h//b\ninclude common\nignore = Name x\n# Overrides common.prf: set here so this value takes effect\nservercmd = /opt/homebrew/bin/unison\n")
        XCTAssertEqual(try effective("p").scalar("servercmd")?.value, "/opt/homebrew/bin/unison")
    }

    func test_set_absent_noInclude_appendsPlainly() throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        let text = try save("p") { doc, e in
            S.apply(.set("/x"), forKey: "servercmd", to: &doc, effective: e, topLevelPath: self.top("p"))
        }
        XCTAssertEqual(text, "root = /a\nroot = /b\nservercmd = /x\n")
    }

    func test_set_movesLineToEnd_whenIncludeAfterItSetsTheKey_keepingUserComment() throws {
        try write("p.prf", "# my server\nservercmd = /top\ninclude common\nroot = /a\nroot = /b\n")
        try write("common.prf", "servercmd = /inc\n")
        let text = try save("p") { doc, e in
            S.apply(.set("/new"), forKey: "servercmd", to: &doc, effective: e, topLevelPath: self.top("p"))
        }
        XCTAssertEqual(text, "include common\nroot = /a\nroot = /b\n# my server\n# Overrides common.prf: set here so this value takes effect\nservercmd = /new\n")
        XCTAssertEqual(try effective("p").scalar("servercmd")?.value, "/new")
    }

    func test_repeatedSaves_doNotAccumulateGeneratedComments() throws {
        try write("p.prf", "servercmd = /top\ninclude common\n")
        try write("common.prf", "servercmd = /inc\n")
        _ = try save("p") { doc, e in S.apply(.set("/one"), forKey: "servercmd", to: &doc, effective: e, topLevelPath: self.top("p")) }
        // Now the line is at the end and wins; a second change rewrites in place.
        let text = try save("p") { doc, e in S.apply(.set("/two"), forKey: "servercmd", to: &doc, effective: e, topLevelPath: self.top("p")) }
        XCTAssertEqual(text.components(separatedBy: "# Overrides common.prf").count - 1, 1)
        XCTAssertEqual(text, "include common\n# Overrides common.prf: set here so this value takes effect\nservercmd = /two\n")
    }

    func test_set_withDuplicates_keepsLastPosition_removesEarlier() throws {
        try write("p.prf", "servercmd = /one\nroot = /a\nservercmd = /two\nroot = /b\n")
        let text = try save("p") { doc, e in S.apply(.set("/three"), forKey: "servercmd", to: &doc, effective: e, topLevelPath: self.top("p")) }
        XCTAssertEqual(text, "root = /a\nservercmd = /three\nroot = /b\n")
    }

    // MARK: - Clear

    func test_clear_local_removesLine() throws {
        try write("p.prf", "root = /a\nroot = /b\nsshcmd = /usr/bin/ssh\n")
        let text = try save("p") { doc, e in
            XCTAssertEqual(S.apply(.clear, forKey: "sshcmd", to: &doc, effective: e, topLevelPath: self.top("p")), .written)
        }
        XCTAssertEqual(text, "root = /a\nroot = /b\n")
    }

    func test_clear_inherited_writesPerKeyDefaultOverride() throws {
        try write("common.prf", "servercmd = /inc\nsshcmd = /opt/ssh\nsshargs = -i k\nlog = false\nperms = 0\nfastcheck = true\nlogfile = /tmp/x.log\n")
        let cases: [(String, String)] = [
            ("servercmd", "servercmd = "), ("sshcmd", "sshcmd = ssh"), ("sshargs", "sshargs = "),
            ("log", "log = true"), ("perms", "perms = 1023"), ("fastcheck", "fastcheck = default"), ("logfile", "logfile = unison.log"),
        ]
        for (key, expectedLine) in cases {
            try write("p.prf", "root = /a\nroot = /b\ninclude common\n")
            let text = try save("p") { doc, e in
                XCTAssertEqual(S.apply(.clear, forKey: key, to: &doc, effective: e, topLevelPath: self.top("p")), .written, key)
            }
            XCTAssertTrue(text.hasSuffix("# Overrides common.prf: set here so this value takes effect\n\(expectedLine)\n"), "\(key): \(text)")
            let e = try effective("p")
            XCTAssertEqual(e.scalar(key)?.winner.location.path, top("p"), key)
            XCTAssertEqual(S.state(for: key, effective: e, topLevelPath: top("p")).provenance, .local(line: 5), key)
        }
    }

    func test_clear_inherited_computedDefault_isRefused() throws {
        try write("p.prf", "root = /a\nroot = /b\ninclude common\n")
        try write("common.prf", "clientHostName = box\n")
        let before = try read("p.prf")
        let text = try save("p") { doc, e in
            guard case .refused(let reason) = S.apply(.clear, forKey: "clientHostName", to: &doc, effective: e, topLevelPath: self.top("p")) else { return XCTFail("expected refusal") }
            XCTAssertTrue(reason.contains("Remove it from common.prf"), reason)
            XCTAssertTrue(reason.contains("may affect other profiles"), reason)
        }
        XCTAssertEqual(text, before)
    }

    func test_defaultOverrideTable_matchesUpstreamDefaults() {
        XCTAssertEqual(S.defaultOverride(for: "servercmd", include: "c"), .assignment(""))
        XCTAssertEqual(S.defaultOverride(for: "sshcmd", include: "c"), .assignment("ssh"))
        XCTAssertEqual(S.defaultOverride(for: "times", include: "c"), .assignment("false"))
        XCTAssertEqual(S.defaultOverride(for: "confirmbigdel", include: "c"), .assignment("true"))
        XCTAssertEqual(S.defaultOverride(for: "rsrc", include: "c"), .assignment("default"))
        XCTAssertEqual(S.defaultOverride(for: "prefer", include: "c"), .assignment(""))
        guard case .refused = S.defaultOverride(for: "clientHostName", include: "c") else { return XCTFail() }
    }

    // MARK: - Conflict control

    func test_conflict_preferOverInheritedForce_neutralizesForce() throws {
        try write("p.prf", "root = /a\nroot = /b\ninclude common\n")
        try write("common.prf", "force = /a\n")
        let text = try save("p") { doc, e in
            S.applyConflict(.prefer("/b"), to: &doc, effective: e, topLevelPath: self.top("p"))
        }
        XCTAssertTrue(text.contains("prefer = /b\n"), text)
        XCTAssertTrue(text.contains("# Overrides common.prf: set here so this value takes effect\nforce = \n"), text)
        let e = try effective("p")
        XCTAssertEqual(e.scalar("force")?.value, "")
        XCTAssertEqual(e.scalar("prefer")?.value, "/b")
    }

    func test_conflict_noneOverInheritedBoth_neutralizesBoth() throws {
        try write("p.prf", "root = /a\nroot = /b\ninclude common\nforcepartial = Name x -> /a\n")
        try write("common.prf", "force = /a\nprefer = /b\n")
        let text = try save("p") { doc, e in
            S.applyConflict(.none, to: &doc, effective: e, topLevelPath: self.top("p"))
        }
        let e = try effective("p")
        XCTAssertEqual(e.scalar("force")?.value, "")
        XCTAssertEqual(e.scalar("prefer")?.value, "")
        XCTAssertTrue(text.contains("forcepartial = Name x -> /a\n"), "partial rules untouched")
    }

    func test_conflict_noneWithLocalOnly_removesLines() throws {
        try write("p.prf", "root = /a\nroot = /b\nforce = /a\n")
        let text = try save("p") { doc, e in S.applyConflict(.none, to: &doc, effective: e, topLevelPath: self.top("p")) }
        XCTAssertEqual(text, "root = /a\nroot = /b\n")
    }

    func test_conflict_force_leavesPreferAlone() throws {
        try write("p.prf", "root = /a\nroot = /b\nprefer = /b\n")
        let text = try save("p") { doc, e in S.applyConflict(.force("/a"), to: &doc, effective: e, topLevelPath: self.top("p")) }
        XCTAssertEqual(text, "root = /a\nroot = /b\nprefer = /b\nforce = /a\n")
    }

    // MARK: - Consumer scan

    func test_consumerScan_directAndTransitive_withHosts_andUnresolved() throws {
        try write("edited.prf", "servercmd = /x\n")
        try write("a.prf", "root = /a\nroot = ssh://alice@hostA//x\ninclude edited\n")
        try write("b.prf", "root = /b\nroot = ssh://hostB//y\ninclude mid\n")
        try write("mid.prf", "include edited\n")
        try write("c.prf", "root = /c\nroot = /d\n")
        try write("broken.prf", "garbled line\n")
        let r = ProfileConsumerScan.scan(unisonDirectory: dir, targetPath: top("edited"), excludingProfile: "edited")
        XCTAssertEqual(r.consumers.map(\.profile), ["a", "b", "mid"])
        XCTAssertEqual(r.consumers.map(\.host), ["hostA", "hostB", nil])
        XCTAssertEqual(r.unresolved, ["broken"])
        XCTAssertEqual(ProfileConsumerScan.disclosure(r),
                       "These profiles include this file and may be affected: a (hostA), b (hostB), mid.\nCould not be resolved: broken.")
    }

    func test_consumerScan_onlyUnresolved_stillDiscloses() throws {
        try write("edited.prf", "servercmd = /x\n")
        try write("broken.prf", "include nothere\n")
        let r = ProfileConsumerScan.scan(unisonDirectory: dir, targetPath: top("edited"), excludingProfile: "edited")
        XCTAssertTrue(r.consumers.isEmpty)
        XCTAssertEqual(r.unresolved, ["broken"])
        XCTAssertEqual(ProfileConsumerScan.disclosure(r), "Could not be resolved: broken.")
    }

    func test_consumerScan_nothing_isNil() throws {
        try write("edited.prf", "servercmd = /x\n")
        try write("c.prf", "root = /c\nroot = /d\n")
        let r = ProfileConsumerScan.scan(unisonDirectory: dir, targetPath: top("edited"), excludingProfile: "edited")
        XCTAssertTrue(r.isEmpty)
        XCTAssertNil(ProfileConsumerScan.disclosure(r))
    }
}
