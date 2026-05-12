import XCTest
@testable import unison_ui_mac

final class ArchiveRecoveryTests: XCTestCase {

    private var tempDir: String!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDir = url.path
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(atPath: tempDir) }
    }

    private func touch(_ name: String) throws {
        try Data().write(to: URL(fileURLWithPath: "\(tempDir!)/\(name)"))
    }

    /// The exact message text the user reported seeing.
    private let realMessage = """
        Warning: inconsistent state.
        The archive file is missing on some hosts.
        For safety, the remaining copies should be deleted.
        Archive are9813a3ba5a967b85e02e6604ff71799 on host Heracles.local should be DELETED
        Archive ar353b9f4733233a1f4d7a58143fa1480d on host Heracles.local is MISSING
        Please delete archive files as appropriate and try again
        or invoke Unison with -ignorearchives flag.
        """

    func test_parse_returnsNilForUnrelatedMessages() {
        XCTAssertNil(ArchiveRecovery.parse(message: "Sync failed: connection refused",
                                           unisonDirectory: tempDir))
        XCTAssertNil(ArchiveRecovery.parse(message: "",
                                           unisonDirectory: tempDir))
        // "Archive ... is MISSING" alone (no "should be DELETED") shouldn't match.
        XCTAssertNil(ArchiveRecovery.parse(
            message: "Archive arabc on host X is MISSING",
            unisonDirectory: tempDir))
    }

    func test_parse_extractsBothArchivesButOnlyKeepsLocalOrphan() throws {
        // The "kept" archive exists locally; the "missing" one does not.
        try touch("are9813a3ba5a967b85e02e6604ff71799")
        try touch("fpe9813a3ba5a967b85e02e6604ff71799")

        guard let recovery = ArchiveRecovery.parse(message: realMessage,
                                                   unisonDirectory: tempDir) else {
            XCTFail("expected a recovery result")
            return
        }
        XCTAssertTrue(recovery.hasLocalOrphans)
        // Only one archive ("should be DELETED") is in the message — the other
        // is "is MISSING", which we don't try to delete.
        XCTAssertEqual(recovery.remoteOnlyOrphans.count, 0,
                       "the archive that exists locally shouldn't be classified as remote-only")
        let localPaths = Set(recovery.localOrphans.map(\.lastPathComponent))
        XCTAssertEqual(localPaths,
                       ["are9813a3ba5a967b85e02e6604ff71799",
                        "fpe9813a3ba5a967b85e02e6604ff71799"])
    }

    func test_parse_classifiesAsRemoteWhenArchiveNotPresentLocally() {
        // No files created — the archive named in "should be DELETED" lives
        // somewhere else (i.e., on the remote host we can't reach).
        guard let recovery = ArchiveRecovery.parse(message: realMessage,
                                                   unisonDirectory: tempDir) else {
            XCTFail("expected a recovery result")
            return
        }
        XCTAssertFalse(recovery.hasLocalOrphans)
        XCTAssertEqual(recovery.remoteOnlyOrphans,
                       ["are9813a3ba5a967b85e02e6604ff71799"])
    }

    func test_deleteLocalOrphans_removesEveryListedFile() throws {
        try touch("are9813a3ba5a967b85e02e6604ff71799")
        try touch("fpe9813a3ba5a967b85e02e6604ff71799")
        try touch("lke9813a3ba5a967b85e02e6604ff71799")  // stale lock file

        guard let recovery = ArchiveRecovery.parse(message: realMessage,
                                                   unisonDirectory: tempDir) else {
            XCTFail("expected a recovery result")
            return
        }
        XCTAssertEqual(recovery.localOrphans.count, 3,
                       "should include matching ar/fp/lk siblings")
        let deleted = recovery.deleteLocalOrphans()
        XCTAssertEqual(deleted.count, 3)
        for path in deleted {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "file at \(path) was reported deleted but still exists")
        }
    }

    func test_parse_multipleHosts_separatesLocalFromRemote() throws {
        let multiHost = """
            Archive ar1111111111111111111111111111111 on host Heracles.local should be DELETED
            Archive ar2222222222222222222222222222222 on host Demeter.local should be DELETED
            """
        // Heracles.local one exists locally; Demeter.local one doesn't.
        try touch("ar1111111111111111111111111111111")

        guard let recovery = ArchiveRecovery.parse(message: multiHost,
                                                   unisonDirectory: tempDir) else {
            XCTFail("expected a recovery result")
            return
        }
        let localNames = Set(recovery.localOrphans.map(\.lastPathComponent))
        XCTAssertEqual(localNames, ["ar1111111111111111111111111111111"])
        XCTAssertEqual(recovery.remoteOnlyOrphans, ["ar2222222222222222222222222222222"])
    }
}
