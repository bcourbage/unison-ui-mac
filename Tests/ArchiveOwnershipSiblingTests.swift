import XCTest
@testable import unison_ui_mac

/// Unison opens the profile named `P` from an extensionless file `P` when one
/// exists, before `P.prf`. Deleting `P.prf` therefore does not remove that
/// profile, and an archive it shares with the deleted `.prf` must not be
/// offered for removal, either at the confirmation or under the lock.
final class ArchiveOwnershipSiblingTests: XCTestCase {

    private let host = "Heracles"
    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("aos2-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }

    private let docs = "/Users/test/Documents"
    private let backup = "/Users/test/Backup/Documents"
    private var rootLines: String { "root = \(docs)\nroot = \(backup)\n" }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8)
    }

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

    private func offer() -> ProfileEditorWindowController.DeleteArchiveOffer {
        ProfileEditorWindowController.deleteArchiveOffer(profile: "P", unisonDirectory: dir, localHostname: host)
    }

    private func recheckPermitsRemoval(_ hashes: [String]) -> Bool {
        let plan = ArchiveMutationPlan(hashes: hashes, fileExists: { _ in true })
        return ArchiveOwnership.revalidateDeletion(plan: plan, unisonDirectory: dir, deleting: "P",
                                                   localHostname: host)
    }

    func test_siblingWithTheSameRoots_ownsTheArchives_atOfferAndRecheck() throws {
        let hashes = try archivePair()
        try write("P.prf", rootLines)
        try write("P", rootLines)

        let o = offer()
        XCTAssertFalse(o.files.isEmpty)
        XCTAssertFalse(o.removalOffered)
        XCTAssertEqual(o.ownership.otherOwners.count, 1)
        XCTAssertEqual(o.ownership.otherOwners.first?.hasPrefix("P"), true, "\(o.ownership.otherOwners)")
        XCTAssertFalse(recheckPermitsRemoval(hashes))
    }

    func test_siblingWithDifferentRoots_doesNotBlockRemoval() throws {
        let hashes = try archivePair()
        try write("P.prf", rootLines)
        // Real directories: a local root that cannot be resolved counts as a
        // possible owner, which is not what this case is about.
        let base = try XCTUnwrap(ArchiveMatcher.realpathResolve(dir))
        for sub in ["A", "B"] {
            try FileManager.default.createDirectory(atPath: base + "/Other/" + sub, withIntermediateDirectories: true)
        }
        try write("P", "root = \(base)/Other/A\nroot = \(base)/Other/B\n")

        XCTAssertTrue(offer().removalOffered)
        XCTAssertTrue(recheckPermitsRemoval(hashes))
    }

    func test_siblingThatCannotBeResolved_blocksRemoval() throws {
        let hashes = try archivePair()
        try write("P.prf", rootLines)
        try write("P", "include missing.inc\n")

        let o = offer()
        XCTAssertFalse(o.removalOffered)
        XCTAssertEqual(o.ownership.unresolvedProfiles.count, 1)
        XCTAssertFalse(recheckPermitsRemoval(hashes))
    }

    func test_siblingThatIsADirectory_blocksRemoval() throws {
        let hashes = try archivePair()
        try write("P.prf", rootLines)
        try FileManager.default.createDirectory(atPath: dir + "/P", withIntermediateDirectories: true)

        XCTAssertFalse(offer().removalOffered)
        XCTAssertFalse(recheckPermitsRemoval(hashes))
    }

    func test_noSibling_isUnchanged() throws {
        let hashes = try archivePair()
        try write("P.prf", rootLines)

        XCTAssertTrue(offer().removalOffered)
        XCTAssertTrue(recheckPermitsRemoval(hashes))
    }
}
