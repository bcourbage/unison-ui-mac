import XCTest
@testable import unison_ui_mac

/// Finding #9 — recursive resolution of a profile's effective roots through
/// `include` / `source` / `include?` / `source?`, with conservative
/// reliability so an archive whose roots come from an included file is
/// attributed correctly and never starts as a checked deletion candidate when
/// attribution can't be proven.
///
/// Filesystem cases use scratch fixture directories (never real archives); the
/// awkward-to-simulate cases (unreadable files, unbounded chains) use the
/// injectable `read:` seam.
final class ProfileRootResolverTests: XCTestCase {
    private typealias R = ProfileRootResolver

    private var dir: String!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileRootResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dir = url.path
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> String {
        let path = "\(dir!)/\(name)"
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func resolve(_ profile: String) -> R.Resolution {
        R.resolve(unisonDirectory: dir, profile: profile)
    }

    // MARK: - Direct roots (no directives)

    func test_directRoots_reliable() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\n")
        let r = resolve("p")
        XCTAssertEqual(r.roots, ["/a", "ssh://h//b"])
        XCTAssertTrue(r.reliable)
        XCTAssertTrue(r.issues.isEmpty)
    }

    // MARK: - include / source bring roots from another file (the core fix)

    func test_include_bringsRootsFromIncludedProfile() throws {
        try write("main.prf", "# no roots here\ninclude common\n")
        try write("common.prf", "root = /local\nroot = ssh://host//remote\n")
        let r = resolve("main")
        XCTAssertEqual(r.roots, ["/local", "ssh://host//remote"])
        XCTAssertTrue(r.reliable)
    }

    func test_source_readsLiteralFile_noPrfAppended() throws {
        // `source` never appends `.prf`; the literal file provides the roots.
        try write("main.prf", "source roots.txt\n")
        try write("roots.txt", "root = /x\nroot = /y\n")
        let r = resolve("main")
        XCTAssertEqual(r.roots, ["/x", "/y"])
        XCTAssertTrue(r.reliable)
    }

    func test_include_exactFileExists_notPrfAppended() throws {
        // `include foo` uses `foo` verbatim when it exists (no `.prf`).
        try write("main.prf", "include exact\n")
        try write("exact", "root = /a\nroot = /b\n")          // note: no .prf
        try write("exact.prf", "root = /WRONG\nroot = /WRONG2\n")
        let r = resolve("main")
        XCTAssertEqual(r.roots, ["/a", "/b"], "must prefer the exact file over .prf")
        XCTAssertTrue(r.reliable)
    }

    // MARK: - Optional vs required, missing files

    func test_optionalMissing_silentlySkipped_reliable() throws {
        try write("main.prf", "root = /a\nroot = /b\ninclude? maybe\nsource? gone.txt\n")
        let r = resolve("main")
        XCTAssertEqual(r.roots, ["/a", "/b"])
        XCTAssertTrue(r.reliable, "a missing OPTIONAL include is normal, not unreliable")
    }

    func test_requiredIncludeMissing_unreliable() throws {
        try write("main.prf", "root = /a\ninclude nonexistent\n")
        let r = resolve("main")
        XCTAssertFalse(r.reliable)
        XCTAssertTrue(r.issues.contains(.missingRequired(token: "nonexistent")))
    }

    func test_requiredSourceMissing_unreliable() throws {
        try write("main.prf", "root = /a\nsource gone.txt\n")
        let r = resolve("main")
        XCTAssertFalse(r.reliable)
        XCTAssertTrue(r.issues.contains(.missingRequired(token: "gone.txt")))
    }

    // MARK: - Nested, diamond, repeated, cyclic

    func test_nestedIncludes() throws {
        try write("a.prf", "include b\n")
        try write("b.prf", "root = /r1\ninclude c\n")
        try write("c.prf", "root = /r2\n")
        let r = resolve("a")
        XCTAssertEqual(r.roots, ["/r1", "/r2"])
        XCTAssertTrue(r.reliable)
    }

    func test_diamondInclude_notACycle_reliable() throws {
        // a → b → d and a → c → d. d is read twice (faithful), NOT a cycle.
        try write("a.prf", "include b\ninclude c\n")
        try write("b.prf", "include d\n")
        try write("c.prf", "include d\n")
        try write("d.prf", "root = /shared\n")
        let r = resolve("a")
        XCTAssertEqual(r.roots, ["/shared", "/shared"])
        XCTAssertTrue(r.reliable, "a re-read of an already-closed file is not a cycle")
    }

    func test_cycle_detected_unreliable_terminates() throws {
        try write("a.prf", "root = /a\ninclude b\n")
        try write("b.prf", "root = /b\ninclude a\n")   // back-edge to a
        let r = resolve("a")
        XCTAssertFalse(r.reliable)
        XCTAssertTrue(r.issues.contains { if case .cycle = $0 { return true } else { return false } })
        // Roots seen before the cycle are still collected; the point is it
        // TERMINATES (no hang) and is flagged unreliable.
        XCTAssertTrue(r.roots.contains("/a"))
    }

    // MARK: - Path resolution relative to the Unison directory

    func test_includeResolvesRelativeToUnisonDir_subdir() throws {
        try write("main.prf", "include sub/common\n")
        try write("sub/common.prf", "root = /deep\nroot = /deep2\n")
        let r = resolve("main")
        XCTAssertEqual(r.roots, ["/deep", "/deep2"])
        XCTAssertTrue(r.reliable)
    }

    func test_escapedSpaceInIncludeName_resolves() throws {
        // `include a\ b` → logical filename "a b" → file "a b.prf".
        try write("main.prf", "include a\\ b\n")
        try write("a b.prf", "root = /sp1\nroot = /sp2\n")
        let r = resolve("main")
        XCTAssertEqual(r.roots, ["/sp1", "/sp2"])
        XCTAssertTrue(r.reliable)
    }

    // MARK: - Malformed / rootalias

    func test_malformedRawLine_unreliable() throws {
        // A non-`=`, non-directive line is `.raw` — Unison would reject the
        // whole profile, so its roots can't be trusted.
        try write("main.prf", "root = /a\nthis is garbage\n")
        let r = resolve("main")
        XCTAssertFalse(r.reliable)
        XCTAssertTrue(r.issues.contains(.malformedLine("this is garbage")))
    }

    func test_malformedDirectiveWithEquals_isRaw_unreliable() throws {
        // `include one = two` is a malformed directive (`.raw`), not key/value.
        try write("main.prf", "include one = two\n")
        let r = resolve("main")
        XCTAssertFalse(r.reliable)
        XCTAssertTrue(r.issues.contains { if case .malformedLine = $0 { return true } else { return false } })
    }

    func test_rootaliasInIncludedFile_surfaced() throws {
        try write("main.prf", "root = /a\nroot = /b\ninclude extra\n")
        try write("extra.prf", "rootalias = //host//a -> //host//b\n")
        let r = resolve("main")
        XCTAssertEqual(r.rootaliases, ["//host//a -> //host//b"])
        // rootalias is an attribution concern for the caller; resolution itself
        // is still structurally reliable.
        XCTAssertTrue(r.reliable)
    }

    // MARK: - Injected reader: unreadable, bounded traversal

    func test_requiredUnreadable_unreliable() {
        let read: (String) -> R.ReadResult = { path in
            if path.hasSuffix("main.prf") { return .ok("root = /a\ninclude secret\n") }
            if path.hasSuffix("secret.prf") { return .unreadable }
            return .missing
        }
        let r = R.resolve(unisonDirectory: dir, profile: "main", read: read)
        XCTAssertFalse(r.reliable)
        XCTAssertTrue(r.issues.contains { if case .unreadable = $0 { return true } else { return false } })
    }

    func test_optionalUnreadable_unreliable() {
        // CORRECTED (Finding #9 review): an existing-but-unreadable OPTIONAL
        // include is NOT proven absent, so it must NOT be treated as skipped.
        // Unison reads profiles as bytes and may still load roots there; we
        // just can't see them. Only a proven-MISSING optional is safely
        // skipped. So the resolution must be flagged unreliable.
        let read: (String) -> R.ReadResult = { path in
            if path.hasSuffix("main.prf") { return .ok("root = /a\nroot = /b\ninclude? secret\n") }
            if path.hasSuffix("secret.prf") { return .unreadable }
            return .missing
        }
        let r = R.resolve(unisonDirectory: dir, profile: "main", read: read)
        XCTAssertFalse(r.reliable,
                       "an existing-but-unreadable OPTIONAL include is not proven absent")
        XCTAssertTrue(r.issues.contains { if case .unreadable = $0 { return true } else { return false } })
    }

    func test_optionalInvalidUTF8File_unreliable_notSkipped() throws {
        // A real optional include whose bytes are not valid UTF-8. It EXISTS
        // and Unison would read it (Latin-1), so we cannot decode it but must
        // not treat it as absent: resolution is unreliable.
        try write("main.prf", "root = /a\ninclude? bad\n")
        let badPath = "\(dir!)/bad.prf"
        // 0xFF 0xFE 0xFF is invalid UTF-8 but a perfectly real file.
        try Data([0xFF, 0xFE, 0xFF, 0x0A]).write(to: URL(fileURLWithPath: badPath))
        let r = resolve("main")
        XCTAssertFalse(r.reliable, "an existing invalid-UTF-8 optional include must be unreliable")
        XCTAssertTrue(r.issues.contains { if case .unreadable = $0 { return true } else { return false } })
    }

    func test_includeExactPathIsDirectory_noPrfFallback_unreliable() throws {
        // `include foo` where `foo` exists as a DIRECTORY and `foo.prf` also
        // exists. Upstream uses the exact path because it exists, which
        // suppresses the `.prf` fallback and then fails to read it. We must
        // NOT silently fall back to the valid `foo.prf` and call it reliable.
        try write("main.prf", "include shared\n")
        try FileManager.default.createDirectory(
            atPath: "\(dir!)/shared", withIntermediateDirectories: true)
        try write("shared.prf", "root = /WRONG\nroot = /WRONG2\n")
        let r = resolve("main")
        XCTAssertFalse(r.reliable,
                       "an existing directory at the exact include path suppresses .prf fallback")
        XCTAssertTrue(r.issues.contains { if case .unreadable = $0 { return true } else { return false } })
        XCTAssertFalse(r.roots.contains("/WRONG"),
                       "must NOT read the .prf when the exact path exists as a directory")
    }

    func test_bomPrefixedProfile_parsesRootsReliably() throws {
        // A UTF-8 BOM at the very start of a profile must not make the first
        // directive/line parse as `.raw`.
        let bom = "\u{FEFF}"
        try write("main.prf", bom + "root = /a\ninclude common\n")
        try write("common.prf", bom + "root = /b\n")
        let r = resolve("main")
        XCTAssertEqual(r.roots, ["/a", "/b"], "BOM must be stripped, roots parse normally")
        XCTAssertTrue(r.reliable)
    }

    // MARK: - filesystemRead classification (missing vs unreadable)

    func test_filesystemRead_directory_isUnreadable_notMissing() throws {
        let p = "\(dir!)/adir"
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        XCTAssertEqual(R.filesystemRead(p), .unreadable)
    }

    func test_filesystemRead_missingPath_isMissing() {
        XCTAssertEqual(R.filesystemRead("\(dir!)/does-not-exist"), .missing)
    }

    func test_filesystemRead_fifo_isUnreadable_withoutHanging() throws {
        // A FIFO exists but opening it to read would block forever. The reader
        // must classify it as unreadable WITHOUT opening it. If this test hangs,
        // the non-regular-file guard regressed.
        let p = "\(dir!)/afifo"
        guard mkfifo(p, 0o600) == 0 else {
            throw XCTSkip("mkfifo unavailable in this environment")
        }
        XCTAssertEqual(R.filesystemRead(p), .unreadable)
    }

    func test_filesystemRead_regularUTF8_isOk() throws {
        let p = try write("plain.prf", "root = /a\n")
        XCTAssertEqual(R.filesystemRead(p), .ok("root = /a\n"))
    }

    func test_unboundedChain_hitsBound_unreliable_terminates() {
        // Every file includes a brand-new deeper file forever. Distinct paths
        // (not a cycle), so only the traversal bound stops it.
        var n = 0
        let read: (String) -> R.ReadResult = { _ in
            n += 1
            return .ok("include chain\(n)\n")
        }
        let r = R.resolve(unisonDirectory: dir, profile: "chain0", read: read)
        XCTAssertFalse(r.reliable)
        XCTAssertTrue(r.issues.contains(.boundExceeded))
        XCTAssertLessThanOrEqual(n, R.maxFiles + R.maxDepth + 2, "traversal must be bounded")
    }
}
