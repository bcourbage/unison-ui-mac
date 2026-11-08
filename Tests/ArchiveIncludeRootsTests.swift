import XCTest
@testable import unison_ui_mac

/// Issue #196: a profile whose `root =` lines live in an included file must be
/// treated like the equivalent direct-root profile by Reset, Delete and the
/// interrupted-operation gate, and a profile whose includes do not resolve
/// must fail closed on every one of them.
final class ArchiveIncludeRootsTests: XCTestCase {

    private let host = "Heracles"
    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("air-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }

    private let docs = "/Users/test/Documents"
    private let backup = "/Users/test/Backup/Documents"
    private var rootLines: String { "root = \(docs)\nroot = \(backup)\n" }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8)
    }

    /// A profile with its roots written directly.
    private func direct(_ name: String) throws { try write("\(name).prf", rootLines) }
    /// A profile that only includes a non-profile file holding the roots, so
    /// the included file is not itself a profile that owns the archives.
    private func includeBased(_ name: String) throws {
        try write("common.inc", rootLines)
        try write("\(name).prf", "include common.inc\n")
    }
    /// A profile whose include target does not exist.
    private func unresolved(_ name: String) throws { try write("\(name).prf", "include missing.inc\n") }

    private func archivePair() throws -> [String] {
        let pair = "//\(host)/\(backup), //\(host)/\(docs)"
        return try [docs, backup].map { root in
            let thisRoot = "//\(host)/\(root)"
            let header = "Unison archive format 23\nArchive for root \(thisRoot) synchronizing roots \(pair)\nWritten at 2026-06-28 at 23:19:45 - Unicode case insensitive mode.\n"
            var data = Data(header.utf8); data.append(contentsOf: [0xff, 0x00, 0xfe])
            let hash = ArchiveHash.md5Hex("\(thisRoot);\(pair);23")
            try data.write(to: URL(fileURLWithPath: "\(dir!)/ar\(hash)"))
            try Data("fp".utf8).write(to: URL(fileURLWithPath: "\(dir!)/fp\(hash)"))
            return hash
        }
    }

    /// Archives for a local pair at `a` and `b`, with their authentic names.
    @discardableResult
    private func archives(_ a: String, _ b: String) throws -> [String] {
        let pair = [a, b].map { "//\(host)/\($0)" }.sorted().joined(separator: ", ")
        return try [a, b].map { root in
            let thisRoot = "//\(host)/\(root)"
            let header = "Unison archive format 23\nArchive for root \(thisRoot) synchronizing roots \(pair)\nWritten at 2026-06-28 at 23:19:45 - Unicode case insensitive mode.\n"
            var data = Data(header.utf8); data.append(contentsOf: [0xff, 0x00, 0xfe])
            let hash = ArchiveHash.md5Hex("\(thisRoot);\(pair);23")
            try data.write(to: URL(fileURLWithPath: "\(dir!)/ar\(hash)"))
            try Data("fp".utf8).write(to: URL(fileURLWithPath: "\(dir!)/fp\(hash)"))
            return hash
        }
    }

    private func reset(_ name: String) -> Swift.Result<ProfileEditorWindowController.ArchiveLocation, ArchiveHash.Failure> {
        ProfileEditorWindowController.resetArchiveCandidates(profile: name, unisonDirectory: dir, localHostname: host)
    }
    private func deleteOffer(_ name: String) -> ProfileEditorWindowController.DeleteArchiveOffer {
        ProfileEditorWindowController.deleteArchiveOffer(profile: name, unisonDirectory: dir, localHostname: host)
    }

    // MARK: Reset

    func test_reset_includeBasedProfileGetsTheDirectProfilesCandidates() throws {
        let hashes = try archivePair()
        try direct("Direct")
        try includeBased("Inc")

        guard case .success(let viaDirect) = reset("Direct"),
              case .success(let viaInclude) = reset("Inc") else {
            return XCTFail("both profiles should resolve")
        }
        XCTAssertEqual(viaInclude, viaDirect)
        XCTAssertEqual(viaInclude.hashes, hashes.sorted())
    }

    func test_reset_unresolvedIncludeOffersNothing() throws {
        _ = try archivePair()
        try unresolved("Broken")
        XCTAssertEqual(reset("Broken"), .failure(.rootsUnresolved))
    }

    // MARK: Delete

    func test_delete_includeBasedUnsharedArchivesAreOfferedForRemoval() throws {
        let hashes = try archivePair()
        try includeBased("Inc")

        let offer = deleteOffer("Inc")
        XCTAssertEqual(offer.hashes, hashes.sorted())
        XCTAssertTrue(offer.removalOffered)
        XCTAssertFalse(offer.rootsUnresolved)
    }

    func test_delete_includeBasedSharedArchivesNameTheOtherOwner() throws {
        _ = try archivePair()
        try includeBased("Inc")
        try direct("Other")

        let offer = deleteOffer("Inc")
        XCTAssertFalse(offer.files.isEmpty)
        XCTAssertEqual(offer.ownership.otherOwners, ["Other"])
        XCTAssertFalse(offer.removalOffered)
    }

    func test_delete_unresolvedIncludeWithholdsRemovalAndSaysSo() throws {
        _ = try archivePair()
        try unresolved("Broken")

        let offer = deleteOffer("Broken")
        XCTAssertTrue(offer.rootsUnresolved)
        XCTAssertFalse(offer.removalOffered)
        XCTAssertTrue(offer.files.isEmpty)
        let text = ProfileEditorWindowController.archivesUnverifiedText
        XCTAssertTrue(text.contains("could not be resolved"), text)
    }

    // MARK: Which file is the profile

    /// An extensionless `p` and `p.prf` can both exist and describe different
    /// replicas. The engine opens `p`, but the editor's Reset and Delete act on
    /// the selected `p.prf` (the file Delete trashes), so they must read that file.
    func test_editorActions_readTheSelectedPrfFile_notAnExtensionlessSibling() throws {
        let prfHashes = try archives("/Users/test/Prf/A", "/Users/test/Prf/B")
        try archives("/Users/test/Bare/A", "/Users/test/Bare/B")
        try write("P.prf", "root = /Users/test/Prf/A\nroot = /Users/test/Prf/B\n")
        try write("P", "root = /Users/test/Bare/A\nroot = /Users/test/Bare/B\n")

        guard case .success(let location) = reset("P") else { return XCTFail("P.prf should resolve") }
        XCTAssertEqual(location.hashes, prfHashes.sorted())
        XCTAssertEqual(deleteOffer("P").hashes, prfHashes.sorted())
    }

    func test_editorActions_missingPrfIsProfileFileMissing_evenWithAnExtensionlessFile() throws {
        try write("P", rootLines)
        XCTAssertEqual(reset("P"), .failure(.profileFileMissing))
    }

    /// `P.prf` is absent but `P.prf.prf` exists. The engine's lookup would fall
    /// back to it; the editor's actions name `P.prf`, so they must not.
    func test_editorActions_doNotFallBackToADoublePrfFile() throws {
        try archives("/Users/test/Prf/A", "/Users/test/Prf/B")
        try write("P.prf.prf", "root = /Users/test/Prf/A\nroot = /Users/test/Prf/B\n")

        XCTAssertEqual(reset("P"), .failure(.profileFileMissing))
        let offer = deleteOffer("P")
        XCTAssertTrue(offer.files.isEmpty)
        XCTAssertTrue(offer.hashes.isEmpty)
        XCTAssertFalse(offer.removalOffered)
    }

    // MARK: Hashes

    func test_computeAll_followsIncludesLikeTheEquivalentDirectProfile() throws {
        try direct("Direct")
        try includeBased("Inc")
        guard case .success(let a) = ArchiveHash.computeAll(unisonDirectory: dir, profile: "Direct", hostname: host),
              case .success(let b) = ArchiveHash.computeAll(unisonDirectory: dir, profile: "Inc", hostname: host) else {
            return XCTFail("both profiles should resolve")
        }
        XCTAssertEqual(a.hashes, b.hashes)
    }

    func test_computeAll_unresolvedIncludeIsNotNoRoots() throws {
        try unresolved("Broken")
        XCTAssertEqual(ArchiveHash.computeAll(unisonDirectory: dir, profile: "Broken", hostname: host).failureValue,
                       .rootsUnresolved)
    }

    /// `p.prf` exists and sources `p`, which does not exist: that is a missing
    /// include, not a missing profile.
    func test_computeAll_selfSourceWithNoSuchFileIsUnresolvedNotMissing() throws {
        try write("P.prf", "source P\n" + rootLines)
        XCTAssertEqual(ArchiveHash.computeAll(unisonDirectory: dir, profile: "P", hostname: host).failureValue,
                       .rootsUnresolved)
    }

    func test_resetWording_coversMalformedFilesAndCycles() {
        let text = ProfileEditorWindowController.rootsUnresolvedResetText
        XCTAssertTrue(text.contains("could not be resolved"), text)
        XCTAssertTrue(text.contains("malformed"), text)
        XCTAssertTrue(text.contains("loop"), text)
    }

    func test_computeAll_missingProfileIsStillProfileFileMissing() {
        XCTAssertEqual(ArchiveHash.computeAll(unisonDirectory: dir, profile: "Nope", hostname: host).failureValue,
                       .profileFileMissing)
    }
}

private extension Swift.Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f }; return nil }
}
