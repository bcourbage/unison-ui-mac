import XCTest
@testable import unison_ui_mac

/// Tests for `ArchiveOwnership`: deleting a profile may remove its archive
/// files only when no other current profile uses them. Unison names an
/// archive by its root pair, so two profiles with the same roots share one
/// archive family, and removing it would make the survivor's next run a first
/// synchronization.
final class ArchiveOwnershipTests: XCTestCase {

    private let host = "Heracles"
    private let docs = "/Users/bcourbage/Documents"
    private let backup = "/Users/bcourbage/Backup/Documents"

    private func entry(_ hash: String, thisRoot: String, roots: String) -> ArchiveCleanup.ArchiveEntry {
        ArchiveCleanup.ArchiveEntry(
            url: URL(fileURLWithPath: "/tmp/ar\(hash)"),
            hash: hash, thisRoot: thisRoot, rootsName: roots)
    }

    /// The live local↔local archive family for `docs` ↔ `backup`: one entry
    /// per local root, as Unison writes them.
    private var localPairIndex: [ArchiveCleanup.ArchiveEntry] {
        let pair = "//Heracles/\(backup), //Heracles/\(docs)"
        return [
            entry("docs", thisRoot: "//Heracles/\(docs)", roots: pair),
            entry("backup", thisRoot: "//Heracles/\(backup)", roots: pair),
        ]
    }

    private func profile(_ name: String, _ roots: [String], reliable: Bool = true) -> ArchiveOwnership.Profile {
        ArchiveOwnership.Profile(name: name, roots: roots, rootsReliable: reliable)
    }

    // MARK: - Verdict

    func test_identicalRoots_otherProfileOwnsArchives_removalNotPermitted() {
        let v = ArchiveOwnership.verdict(
            hashes: ["docs", "backup"],
            others: [profile("B", [docs, backup])],
            index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.otherOwners, ["B"])
        XCTAssertEqual(v.unresolvedProfiles, [])
        XCTAssertFalse(v.removalPermitted)
    }

    func test_identicalRoots_inEitherOrder_stillOwned() {
        let v = ArchiveOwnership.verdict(
            hashes: ["docs", "backup"],
            others: [profile("B", [backup, docs])],
            index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.otherOwners, ["B"])
    }

    func test_soleOwner_removalPermitted() {
        let v = ArchiveOwnership.verdict(
            hashes: ["docs", "backup"],
            others: [profile("Pictures", ["/Users/bcourbage/Pictures", "/Volumes/Backup/Pictures"])],
            index: localPairIndex, localHostname: host)
        XCTAssertEqual(v, ArchiveOwnership.Verdict(otherOwners: [], unresolvedProfiles: []))
        XCTAssertTrue(v.removalPermitted)
    }

    func test_noOtherProfiles_removalPermitted() {
        let v = ArchiveOwnership.verdict(hashes: ["docs", "backup"], others: [],
                                         index: localPairIndex, localHostname: host)
        XCTAssertTrue(v.removalPermitted)
    }

    func test_noHashes_removalPermitted() {
        // Nothing to remove; the verdict must not invent an owner.
        let v = ArchiveOwnership.verdict(hashes: [], others: [profile("B", [docs, backup])],
                                         index: localPairIndex, localHostname: host)
        XCTAssertTrue(v.removalPermitted)
    }

    func test_sharedLocalRoot_differentRemotePath_isNotAnOwner() {
        // Two ssh profiles share a local root but sync it against different
        // remote paths; their archives differ, so neither owns the other's.
        let mine = "//Heracles/\(docs), //demeter//srv/docs"
        let index = [entry("mine", thisRoot: "//Heracles/\(docs)", roots: mine)]
        let v = ArchiveOwnership.verdict(
            hashes: ["mine"],
            others: [profile("Other", [docs, "ssh://athena//srv/other-docs"])],
            index: index, localHostname: host)
        XCTAssertEqual(v.otherOwners, [])
        XCTAssertTrue(v.removalPermitted)
    }

    func test_sharedLocalRoot_sameRemotePath_differentHost_countsAsOwner() {
        // Matching is by path only; the remote host is not verifiable offline.
        // Two ssh profiles that differ only in the remote host therefore look
        // alike, and the verdict treats the other one as an owner (fail closed)
        // rather than removing archives it might share.
        let mine = "//Heracles/\(docs), //demeter//srv/docs"
        let index = [entry("mine", thisRoot: "//Heracles/\(docs)", roots: mine)]
        let v = ArchiveOwnership.verdict(
            hashes: ["mine"],
            others: [profile("Other", [docs, "ssh://athena//srv/docs"])],
            index: index, localHostname: host)
        XCTAssertEqual(v.otherOwners, ["Other"])
        XCTAssertFalse(v.removalPermitted)
    }

    func test_unreliableRoots_blockRemoval_evenWithoutAMatch() {
        let v = ArchiveOwnership.verdict(
            hashes: ["docs", "backup"],
            others: [profile("Broken", [], reliable: false)],
            index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.otherOwners, [])
        XCTAssertEqual(v.unresolvedProfiles, ["Broken"])
        XCTAssertFalse(v.removalPermitted)
    }

    func test_unreliableButMatching_isReportedAsOwner_notUnresolved() {
        let v = ArchiveOwnership.verdict(
            hashes: ["docs", "backup"],
            others: [profile("B", [docs, backup], reliable: false)],
            index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.otherOwners, ["B"])
        XCTAssertEqual(v.unresolvedProfiles, [])
    }

    func test_ownersAndUnresolved_areSorted() {
        let v = ArchiveOwnership.verdict(
            hashes: ["docs", "backup"],
            others: [profile("Zed", [docs, backup]), profile("Amy", [docs, backup]),
                     profile("Yak", [], reliable: false), profile("Bob", [], reliable: false)],
            index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.otherOwners, ["Amy", "Zed"])
        XCTAssertEqual(v.unresolvedProfiles, ["Bob", "Yak"])
    }

    func test_enumerationFailed_removalNotPermitted() {
        let v = ArchiveOwnership.Verdict(otherOwners: [], unresolvedProfiles: [], enumerationFailed: true)
        XCTAssertFalse(v.removalPermitted)
    }

    // MARK: - Enumerating the other profiles from a Unison directory

    private func makeUnisonDir(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "ArchiveOwnershipTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        for (name, text) in files {
            try text.write(toFile: (dir as NSString).appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
        }
        return dir
    }

    func test_otherProfiles_excludesTheDeletingProfile_andResolvesIncludes() throws {
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "B.prf": "include common\n",
            "common.prf": "root = \(docs)\nroot = \(backup)\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(unisonDirectory: dir, excluding: "A"))
        XCTAssertEqual(others.map(\.name), ["B", "common"])
        let b = try XCTUnwrap(others.first { $0.name == "B" })
        XCTAssertEqual(b.roots, [docs, backup])
        XCTAssertTrue(b.rootsReliable)

        // Roots supplied through an include still make B an owner.
        let v = ArchiveOwnership.verdict(hashes: ["docs", "backup"], others: others,
                                         index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.otherOwners, ["B", "common"])
        XCTAssertFalse(v.removalPermitted)
    }

    func test_otherProfiles_missingInclude_isUnreliable() throws {
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "C.prf": "include missing\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(unisonDirectory: dir, excluding: "A"))
        XCTAssertEqual(others.map(\.name), ["C"])
        XCTAssertFalse(others[0].rootsReliable)
        let v = ArchiveOwnership.verdict(hashes: ["docs", "backup"], others: others,
                                         index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.unresolvedProfiles, ["C"])
        XCTAssertFalse(v.removalPermitted)
    }

    func test_otherProfiles_rootalias_isUnreliable() throws {
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "D.prf": "root = /somewhere/else\nroot = /elsewhere\nrootalias = //old//x -> //new//y\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(unisonDirectory: dir, excluding: "A"))
        XCTAssertEqual(others.map(\.rootsReliable), [false])
    }

    func test_otherProfiles_symlinkedLocalRoot_isUnreliable() throws {
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "E.prf": "root = /somewhere/else\nroot = /elsewhere\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(
            unisonDirectory: dir, excluding: "A", isSymlink: { $0 == "/somewhere/else" }))
        XCTAssertEqual(others.map(\.rootsReliable), [false])
    }

    func test_otherProfiles_cleanUnrelatedProfile_isReliable() throws {
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "F.prf": "root = /somewhere/else\nroot = /elsewhere\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(unisonDirectory: dir, excluding: "A"))
        XCTAssertEqual(others.map(\.rootsReliable), [true])
    }

    func test_otherProfiles_unreadableDirectory_isNil() {
        XCTAssertNil(ArchiveOwnership.otherProfiles(
            unisonDirectory: "/nonexistent/\(UUID().uuidString)", excluding: "A"))
    }

    // MARK: - Confirmation copy

    func test_keptText_singleOwner() {
        let text = ProfileEditorWindowController.archivesKeptText(
            count: 4, ownership: .init(otherOwners: ["B"], unresolvedProfiles: []))
        XCTAssertEqual(text, "Its 4 archive files will be kept: the profile “B”, which has the "
            + "same roots and still uses them to remember the last synchronization.")
    }

    func test_keptText_twoOwners_singleFile() {
        let text = ProfileEditorWindowController.archivesKeptText(
            count: 1, ownership: .init(otherOwners: ["B", "C"], unresolvedProfiles: []))
        XCTAssertEqual(text, "Its archive file will be kept: the profiles “B”, “C”, which have the "
            + "same roots and still use them to remember the last synchronization.")
    }

    func test_keptText_unresolved() {
        let text = ProfileEditorWindowController.archivesKeptText(
            count: 2, ownership: .init(otherOwners: [], unresolvedProfiles: ["C"]))
        XCTAssertTrue(text.hasPrefix("Its 2 archive files will be kept: the roots of “C” could not be resolved"))
        XCTAssertTrue(text.contains("Fix that profile"))
    }

    func test_keptText_enumerationFailed() {
        let text = ProfileEditorWindowController.archivesKeptText(
            count: 2, ownership: .init(otherOwners: [], unresolvedProfiles: [], enumerationFailed: true))
        XCTAssertTrue(text.contains("profile folder could not be read"))
    }
}
