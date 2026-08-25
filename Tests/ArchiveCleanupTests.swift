import XCTest
@testable import unison_ui_mac

/// Tests for `ArchiveCleanup`. The struct's two responsibilities are:
///   1. Given a hash, find all `<prefix><hash>` files in the Unison
///      directory across the five upstream archive prefixes
///      (`ar`, `fp`, `lk`, `tm`, `sc`), returning URLs in that order
///      and omitting missing files.
///   2. Move a list of URLs to Trash, returning a (trashed, failed) split.
///
/// Tests use a per-test temp directory in NSTemporaryDirectory so they
/// don't conflict with each other or with a real Unison install.
/// `trashItem(at:)` operates on a per-volume Trash and is reversible
/// from Finder — these tests are non-destructive.
final class ArchiveCleanupTests: XCTestCase {

    private var tempDir: String!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDir = url.path
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
    }

    private func touch(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: "\(tempDir!)/\(name)")
        try Data().write(to: url)
        return url
    }

    // MARK: - findFiles

    func test_findFiles_returnsEmptyWhenNoMatchingFiles() {
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        XCTAssertEqual(cleanup.findFiles(matching: "deadbeef"), [])
    }

    func test_findFiles_returnsOnlyMatchingPrefixes() throws {
        let hash = "9813a3ba5a967b85e02e6604ff71799"
        _ = try touch("ar\(hash)")
        _ = try touch("fp\(hash)")
        // lk / tm / sc absent; should be omitted from the result.
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        let found = cleanup.findFiles(matching: hash)
        XCTAssertEqual(found.map { $0.lastPathComponent },
                       ["ar\(hash)", "fp\(hash)"])
    }

    func test_findFiles_returnsPayloadPrefixesInOrder_excludingLock() throws {
        let hash = "353b9f4733233a1f4d7a58143fa1480d"
        // Create them in shuffled order to prove the result order comes from
        // `archivePrefixes`, not the filesystem.
        _ = try touch("sc\(hash)")
        _ = try touch("ar\(hash)")
        _ = try touch("tm\(hash)")
        _ = try touch("fp\(hash)")
        _ = try touch("lk\(hash)")   // the lock must NOT be listed (B3)
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        let found = cleanup.findFiles(matching: hash)
        XCTAssertEqual(found.map { $0.lastPathComponent },
                       ["ar\(hash)", "fp\(hash)", "tm\(hash)", "sc\(hash)"],
                       "lk is the lock, never a payload file to trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/lk\(hash)"),
                      "findFiles never touches the lock")
    }

    func test_findFiles_ignoresFilesForDifferentHashes() throws {
        let target = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let other  = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        _ = try touch("ar\(target)")
        _ = try touch("ar\(other)")
        _ = try touch("fp\(other)")
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        XCTAssertEqual(cleanup.findFiles(matching: target).map { $0.lastPathComponent },
                       ["ar\(target)"])
    }

    func test_findFiles_ignoresUnrelatedFilenames() throws {
        let hash = "abcdef0123456789abcdef0123456789"
        _ = try touch("ar\(hash)")
        _ = try touch("README.txt")          // not a prefix
        _ = try touch("ar\(hash).bak")       // wrong suffix
        _ = try touch("xx\(hash)")           // unknown prefix
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        XCTAssertEqual(cleanup.findFiles(matching: hash).map { $0.lastPathComponent },
                       ["ar\(hash)"])
    }

    func test_archivePrefixes_arePayloadOnly_excludingLock() {
        // Payload prefixes only — `lk` is the interprocess lock, never trashed
        // (B3). Mirrors ArchiveMutationPlan.payloadPrefixes.
        XCTAssertEqual(ArchiveCleanup.archivePrefixes, ["ar", "fp", "tm", "sc"])
        XCTAssertFalse(ArchiveCleanup.archivePrefixes.contains("lk"))
    }

    func test_findFiles_handlesNonExistentDirectoryGracefully() {
        let cleanup = ArchiveCleanup(unisonDirectory: "\(tempDir!)/does-not-exist")
        XCTAssertEqual(cleanup.findFiles(matching: "abc"), [])
    }

    // NOTE: ArchiveCleanup no longer has a `trash(_:)` — destructive mutation is
    // the sole responsibility of the ArchiveMutation transaction (see
    // ArchiveMutationTransactionTests / ArchiveStagingStoreTests). ArchiveCleanup
    // only finds/indexes archives now.

    // MARK: - Header parsing / indexing

    /// Write a realistic archive: a text header (format line + roots
    /// line + written-at line) followed by binary body bytes that are
    /// NOT valid UTF-8 — proving the lenient header parse survives. The
    /// filename is the authentic `ar<MD5(thisRoot;rootsName;format)>`
    /// unless `overrideName` forces a different (tampered) name.
    @discardableResult
    private func writeArchive(thisRoot: String,
                              rootsName: String,
                              format: Int = 23,
                              overrideName: String? = nil) throws -> (url: URL, hash: String) {
        let header = """
            Unison archive format \(format)
            Archive for root \(thisRoot) synchronizing roots \(rootsName)
            Written at 2026-06-28 at 23:19:45 - Unicode case insensitive mode.

            """
        var data = Data(header.utf8)
        data.append(contentsOf: [0xff, 0x00, 0xfe, 0x80, 0x81])  // invalid UTF-8 body
        let hash = ArchiveHash.md5Hex("\(thisRoot);\(rootsName);\(format)")
        let name = overrideName ?? "ar\(hash)"
        let url = URL(fileURLWithPath: "\(tempDir!)/\(name)")
        try data.write(to: url)
        return (url, hash)
    }

    func test_parseArchiveHeader_extractsFormatAndRootsDespiteBinaryBody() throws {
        let written = try writeArchive(
            thisRoot: "//Heracles//Users/bcourbage",
            rootsName: "//Demeter//Users/bcourbage, //Heracles//Users/bcourbage")
        let header = ArchiveCleanup.parseArchiveHeader(at: written.url)
        XCTAssertEqual(header?.format, 23)
        XCTAssertEqual(header?.thisRoot, "//Heracles//Users/bcourbage")
        XCTAssertEqual(header?.rootsName,
                       "//Demeter//Users/bcourbage, //Heracles//Users/bcourbage")
    }

    func test_parseArchiveHeader_longRoots_pushSecondLinePastAKilobyte() throws {
        // Two near-PATH_MAX canonical roots make the second header line far
        // exceed 1 KiB. A fixed one-kilobyte read truncated it and returned nil,
        // silently hiding the archive from cleanup/reset; the header parse must
        // read through the second newline and still extract both roots.
        let longLocal = "//Heracles//Users/bcourbage/" + String(repeating: "a", count: 980)
        let longRemote = "//Demeter//Users/bcourbage/" + String(repeating: "b", count: 980)
        let rootsName = "\(longRemote), \(longLocal)"
        // Sanity: the second line really is past the old 1024-byte bound.
        XCTAssertGreaterThan(
            "Archive for root \(longLocal) synchronizing roots \(rootsName)".utf8.count, 1024)
        let written = try writeArchive(thisRoot: longLocal, rootsName: rootsName)
        let header = ArchiveCleanup.parseArchiveHeader(at: written.url)
        XCTAssertEqual(header?.thisRoot, longLocal)
        XCTAssertEqual(header?.rootsName, rootsName)
    }

    func test_parseArchiveHeader_nonArchiveFile_returnsNil() throws {
        let url = try touch("arNotReally")
        XCTAssertNil(ArchiveCleanup.parseArchiveHeader(at: url))
    }

    func test_indexArchives_includesAuthenticAndIgnoresOthers() throws {
        let a = try writeArchive(
            thisRoot: "//Heracles//Users/bcourbage",
            rootsName: "//Demeter//Users/bcourbage, //Heracles//Users/bcourbage")
        let b = try writeArchive(
            thisRoot: "//Heracles//Users/bcourbage/Pictures",
            rootsName: "//Heracles//Users/bcourbage/Pictures, //x//y")
        _ = try touch("fp\(a.hash)")  // sibling, not an ar — ignored by index
        _ = try touch("Sync.prf")
        let entries = ArchiveCleanup(unisonDirectory: tempDir).indexArchives()
        XCTAssertEqual(Set(entries.map(\.hash)), [a.hash, b.hash])
    }

    func test_indexArchives_excludesTamperedArchive() throws {
        // Authentic header, but the filename hash doesn't match it (e.g.
        // a hand-renamed or corrupt file). Must be excluded.
        _ = try writeArchive(
            thisRoot: "//Heracles//Users/bcourbage",
            rootsName: "//Demeter//Users/bcourbage, //Heracles//Users/bcourbage",
            overrideName: "ar0000000000000000000000000000dead")
        let entries = ArchiveCleanup(unisonDirectory: tempDir).indexArchives()
        XCTAssertTrue(entries.isEmpty)
    }

    func test_indexArchives_authenticUnderDifferentFormat() throws {
        // The integrity check uses the header's own format, so an archive
        // written under an older format still validates.
        let a = try writeArchive(
            thisRoot: "//Heracles//Users/bcourbage",
            rootsName: "//Demeter//Users/bcourbage, //Heracles//Users/bcourbage",
            format: 22)
        let entries = ArchiveCleanup(unisonDirectory: tempDir).indexArchives()
        XCTAssertEqual(entries.map(\.hash), [a.hash])
    }
}
