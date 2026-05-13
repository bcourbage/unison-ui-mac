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
    private var trashedFromTests: [URL] = []

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDir = url.path
        trashedFromTests = []
    }

    override func tearDownWithError() throws {
        // Clean up the temp directory if anything is left.
        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        // Best-effort cleanup of items we moved to Trash. Trash items
        // live at ~/.Trash/<name> on the boot volume; we delete the
        // ones we created here rather than leaving them to clutter.
        let homeTrash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        for url in trashedFromTests {
            let candidate = homeTrash.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: candidate)
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

    func test_findFiles_returnsAllFivePrefixesInUpstreamOrder() throws {
        let hash = "353b9f4733233a1f4d7a58143fa1480d"
        // Create them in shuffled order to prove the result order
        // comes from `archivePrefixes`, not from the filesystem.
        _ = try touch("sc\(hash)")
        _ = try touch("ar\(hash)")
        _ = try touch("tm\(hash)")
        _ = try touch("fp\(hash)")
        _ = try touch("lk\(hash)")
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        let found = cleanup.findFiles(matching: hash)
        XCTAssertEqual(found.map { $0.lastPathComponent },
                       ["ar\(hash)", "fp\(hash)", "lk\(hash)",
                        "tm\(hash)", "sc\(hash)"])
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

    func test_archivePrefixes_matchesUpstreamArchiveVersionOrder() {
        // Order is significant — the UI may rely on it when grouping
        // matches by kind. If upstream's Update.archiveName ever
        // re-orders or extends this list, mirror the change here.
        XCTAssertEqual(ArchiveCleanup.archivePrefixes,
                       ["ar", "fp", "lk", "tm", "sc"])
    }

    func test_findFiles_handlesNonExistentDirectoryGracefully() {
        let cleanup = ArchiveCleanup(unisonDirectory: "\(tempDir!)/does-not-exist")
        XCTAssertEqual(cleanup.findFiles(matching: "abc"), [])
    }

    // MARK: - trash

    func test_trash_movesAllProvidedURLs() throws {
        let hash = "1111111111111111111111111111aaaa"
        let urls = [try touch("ar\(hash)"), try touch("fp\(hash)")]
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        let result = cleanup.trash(urls)
        XCTAssertEqual(result.trashed.count, 2)
        XCTAssertTrue(result.failed.isEmpty)
        // Source files are gone from the Unison directory.
        for url in urls {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "expected \(url.lastPathComponent) to be moved out")
        }
        trashedFromTests.append(contentsOf: urls)
    }

    func test_trash_reportsFailuresWithoutAbortingTheRest() throws {
        let hash = "2222222222222222222222222222bbbb"
        let real = try touch("ar\(hash)")
        let phantom = URL(fileURLWithPath: "\(tempDir!)/does-not-exist-\(hash)")
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        let result = cleanup.trash([real, phantom])
        XCTAssertEqual(result.trashed.count, 1)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.trashed.first, real)
        XCTAssertEqual(result.failed.first?.0, phantom)
        trashedFromTests.append(real)
    }

    func test_trash_emptyInputReturnsEmptyResult() {
        let cleanup = ArchiveCleanup(unisonDirectory: tempDir)
        let result = cleanup.trash([])
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
    }
}
