import XCTest
@testable import unison_ui_mac

/// B1 (comma-ambiguous rootsName), B2 (ancestor-symlink realpath), and SF3
/// (remote side) attribution safety in `ArchiveMatcher`.
final class ArchiveMatcherAttributionTests: XCTestCase {

    // MARK: B2 — realpath resolves ancestor symlinks

    func test_localPath_resolvesAncestorSymlink() throws {
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("matcherB2-" + UUID().uuidString)
        let realDir = (base as NSString).appendingPathComponent("real")
        let sub = (realDir as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let link = (base as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realDir)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let linkedSub = (link as NSString).appendingPathComponent("sub")
        let resolved = ArchiveMatcher.localPath(of: linkedSub)
        let expected = try XCTUnwrap(ArchiveMatcher.realpathResolve(sub))
        XCTAssertEqual(resolved, expected, "realpath resolves the symlinked ancestor")
        XCTAssertNotEqual(resolved, linkedSub, "the un-resolved symlink path is not used")
    }

    /// A profile root written through a symlinked ancestor must still match the
    /// archive Unison recorded under the resolved (canonical) path — otherwise
    /// the profile's own LIVE archive is misread as a confident orphan (B2).
    func test_archives_matchThroughAncestorSymlink() throws {
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("matcherB2m-" + UUID().uuidString)
        let realDir = (base as NSString).appendingPathComponent("real")
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        let link = (base as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realDir)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let canonical = try XCTUnwrap(ArchiveMatcher.realpathResolve(realDir))
        // Archive canonical roots use the RESOLVED path (as Unison stores).
        let rootsName = "//Heracles//tmp/other, //Heracles/\(canonical)"
        let entry = ArchiveCleanup.ArchiveEntry(
            url: URL(fileURLWithPath: "/tmp/arX"), hash: "X",
            thisRoot: "//Heracles/\(canonical)", rootsName: rootsName)
        // Profile root uses the SYMLINK path (as a .prf would).
        let matched = ArchiveMatcher.archives(
            forProfileRoots: [link, "/tmp/other"], in: [entry], localHostname: "Heracles")
        XCTAssertEqual(matched.map(\.hash), ["X"],
                       "the symlinked profile root matches the resolved archive path")
    }

    // MARK: B1 — comma-ambiguous rootsName

    func test_rootsNameIsAmbiguous_detectsCommaInPath() {
        // A root path containing ", " splits into an extra unparseable fragment.
        XCTAssertTrue(ArchiveMatcher.rootsNameIsAmbiguous(
            "//Heracles//Backup, //Heracles//Users/b/Docs, Old"))
        // A clean two-root pair parses to exactly two canonical components.
        XCTAssertFalse(ArchiveMatcher.rootsNameIsAmbiguous(
            "//Heracles//a, //Heracles//b"))
    }

    // MARK: SF3 — remote side = two distinct hosts

    func test_involvesRemoteHost() {
        XCTAssertTrue(ArchiveMatcher.involvesRemoteHost(
            rootsName: "//Demeter//x, //Heracles//y"), "two hosts = remote side")
        XCTAssertFalse(ArchiveMatcher.involvesRemoteHost(
            rootsName: "//Heracles//x, //Heracles//y"), "one host = local↔local")
        XCTAssertFalse(ArchiveMatcher.involvesRemoteHost(
            rootsName: "//MacBookPro//x, //MacBookPro//y"),
            "former machine name, single host = still local↔local")
        XCTAssertTrue(ArchiveMatcher.involvesRemoteHost(
            rootsName: "garbage, //Heracles//y"), "unparseable component fails closed")
    }
}
