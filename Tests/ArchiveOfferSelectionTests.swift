import XCTest
@testable import unison_ui_mac

/// What Reset Archives and Delete Profile decide to offer for a profile,
/// over real archive files in a temporary Unison directory: which archives
/// are selected, when nothing is offered, and when Delete withholds the
/// offer to remove them. A change to how the selection reads the profile
/// must leave every expectation here unchanged.
final class ArchiveOfferSelectionTests: XCTestCase {

    private let host = "Heracles"
    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("aos-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }

    private let docs = "/Users/test/Documents"
    private let backup = "/Users/test/Backup/Documents"
    private let home = "/Users/test/Home"
    private let remoteHome = "ssh://bruno@demeter//Users/bruno/Home"

    private func profile(_ name: String, roots: [String]) throws {
        let text = roots.map { "root = \($0)\n" }.joined()
        try text.write(toFile: "\(dir!)/\(name).prf", atomically: true, encoding: .utf8)
    }

    /// An archive as Unison writes it, with its authentic name, plus a
    /// payload sibling and the lock file.
    @discardableResult
    private func archive(thisRoot: String, rootsName: String, hostnameInHeader _: String? = nil) throws -> String {
        let header = "Unison archive format 23\nArchive for root \(thisRoot) synchronizing roots \(rootsName)\nWritten at 2026-06-28 at 23:19:45 - Unicode case insensitive mode.\n"
        var data = Data(header.utf8); data.append(contentsOf: [0xff, 0x00, 0xfe])
        let hash = ArchiveHash.md5Hex("\(thisRoot);\(rootsName);23")
        try data.write(to: URL(fileURLWithPath: "\(dir!)/ar\(hash)"))
        try Data("fp".utf8).write(to: URL(fileURLWithPath: "\(dir!)/fp\(hash)"))
        try Data().write(to: URL(fileURLWithPath: "\(dir!)/lk\(hash)"))
        return hash
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent).sorted() }

    private func localPairArchives(on h: String = "Heracles") throws -> (docs: String, backup: String) {
        let pair = "//\(h)/\(backup), //\(h)/\(docs)"
        return (try archive(thisRoot: "//\(h)/\(docs)", rootsName: pair),
                try archive(thisRoot: "//\(h)/\(backup)", rootsName: pair))
    }

    private func sshArchive() throws -> String {
        try archive(thisRoot: "//\(host)/\(home)", rootsName: "//\(host)/\(home), //demeter//Users/bruno/Home")
    }

    private func reset(_ name: String) -> Swift.Result<ProfileEditorWindowController.ArchiveLocation, ArchiveHash.Failure> {
        ProfileEditorWindowController.resetArchiveCandidates(profile: name, unisonDirectory: dir, localHostname: host)
    }
    private func deleteOffer(_ name: String) -> ProfileEditorWindowController.DeleteArchiveOffer {
        ProfileEditorWindowController.deleteArchiveOffer(profile: name, unisonDirectory: dir, localHostname: host)
    }

    // MARK: - Reset

    func test_reset_localPair_selectsBothFamilies_withoutLocks() throws {
        try profile("pair", roots: [docs, backup])
        let h = try localPairArchives()
        guard case .success(let loc) = reset("pair") else { return XCTFail("\(reset("pair"))") }
        XCTAssertEqual(loc.hashes, [h.docs, h.backup].sorted())
        XCTAssertEqual(names(loc.files), (["ar\(h.docs)", "ar\(h.backup)", "fp\(h.docs)", "fp\(h.backup)"]).sorted())
        XCTAssertEqual(loc.rootsNames, ["//Heracles/\(backup), //Heracles/\(docs)"])
        XCTAssertFalse(loc.ambiguous)
    }

    func test_reset_sshRoot_selectsTheLocalFamily_fromTheHeaderRoots() throws {
        try profile("remote", roots: [home, remoteHome])
        let h = try sshArchive()
        guard case .success(let loc) = reset("remote") else { return XCTFail("\(reset("remote"))") }
        XCTAssertEqual(loc.hashes, [h])
        XCTAssertEqual(names(loc.files), ["ar\(h)", "fp\(h)"].sorted())
        XCTAssertEqual(loc.rootsNames, ["//Heracles/\(home), //demeter//Users/bruno/Home"])
        XCTAssertFalse(loc.ambiguous)
    }

    func test_reset_gates_offerNothing() throws {
        XCTAssertEqual(reset("missing"), .failure(.profileFileMissing))
        try profile("noroots", roots: [])
        XCTAssertEqual(reset("noroots"), .failure(.noRoots))
        try profile("bothremote", roots: ["ssh://a//x", "ssh://b//y"])
        XCTAssertEqual(reset("bothremote"), .failure(.noLocalRoot))
    }

    func test_reset_noLiveArchive_selectsNothing() throws {
        try profile("pair", roots: [docs, backup])
        guard case .success(let loc) = reset("pair") else { return XCTFail() }
        XCTAssertEqual(loc.files, [])
        XCTAssertEqual(loc.hashes, [])
    }

    func test_reset_archivesUnderAFormerHostname_areNotLive() throws {
        try profile("pair", roots: [docs, backup])
        try localPairArchives(on: "Heracles.local")
        guard case .success(let loc) = reset("pair") else { return XCTFail() }
        XCTAssertEqual(loc.files, [], "stale hostname generations belong to Clean Stale Archives")
    }

    // MARK: - Delete

    func test_delete_soleOwner_offersRemovalOfTheSelectedFiles() throws {
        try profile("pair", roots: [docs, backup])
        let h = try localPairArchives()
        let offer = deleteOffer("pair")
        XCTAssertEqual(offer.hashes, [h.docs, h.backup].sorted())
        XCTAssertEqual(offer.files.count, 4)
        XCTAssertEqual(offer.ownership.otherOwners, [])
        XCTAssertTrue(offer.removalOffered)
    }

    func test_delete_sshRoot_soleOwner_offersRemoval() throws {
        try profile("remote", roots: [home, remoteHome])
        let h = try sshArchive()
        let offer = deleteOffer("remote")
        XCTAssertEqual(offer.hashes, [h])
        XCTAssertTrue(offer.removalOffered)
    }

    func test_delete_withholdsRemoval_whenAnotherProfileSharesTheRoots() throws {
        try profile("pair", roots: [docs, backup])
        try profile("sibling", roots: [backup, docs])
        try localPairArchives()
        let offer = deleteOffer("pair")
        XCTAssertEqual(offer.files.count, 4, "the files are still located and described")
        XCTAssertEqual(offer.ownership.otherOwners, ["sibling"])
        XCTAssertFalse(offer.removalOffered)
    }

    func test_delete_withholdsRemoval_whenAnotherProfileSharesTheSshRoots() throws {
        try profile("remote", roots: [home, remoteHome])
        try profile("sibling", roots: [remoteHome, home])
        try sshArchive()
        let offer = deleteOffer("remote")
        XCTAssertEqual(offer.ownership.otherOwners, ["sibling"])
        XCTAssertFalse(offer.removalOffered)
    }

    func test_delete_noArchivesOrUncomputableHash_offersNothing() throws {
        try profile("pair", roots: [docs, backup])
        XCTAssertFalse(deleteOffer("pair").removalOffered, "no archives on disk")
        try profile("bothremote", roots: ["ssh://a//x", "ssh://b//y"])
        let offer = deleteOffer("bothremote")
        XCTAssertEqual(offer.files, [])
        XCTAssertFalse(offer.removalOffered, "no local root: nothing to offer")
        XCTAssertEqual(deleteOffer("gone").files, [], "profile file already gone")
    }
}
