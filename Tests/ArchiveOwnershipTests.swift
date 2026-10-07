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
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(
            unisonDirectory: dir, excluding: "A", resolve: fakeResolve()))
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

    /// A resolver standing in for realpath(3): `aliases` maps a lexical path
    /// to its canonical form; anything else resolves to itself; `missing`
    /// paths fail to resolve.
    private func fakeResolve(aliases: [String: String] = [:], missing: Set<String> = []) -> (String) -> String? {
        { path in
            if missing.contains(path) { return nil }
            return aliases[path] ?? path
        }
    }

    func test_otherProfiles_localRootWrittenThroughSymlink_isUnreliable() throws {
        // The profile writes its root through a symlink. ArchiveMatcher
        // canonicalizes roots, so the canonical path is what gets matched; the
        // reliability check has to look at the path as WRITTEN, because the
        // link can be removed or retargeted later.
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "E.prf": "root = /Users/bcourbage/alias\nroot = /elsewhere\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(
            unisonDirectory: dir, excluding: "A",
            resolve: fakeResolve(aliases: ["/Users/bcourbage/alias": docs])))
        XCTAssertEqual(others.map(\.rootsReliable), [false])
    }

    func test_otherProfiles_realSymlinkOnDisk_isUnreliable() throws {
        // Same as above with a real link on disk and the real resolver.
        let dir = try makeUnisonDir([:])
        let real = (dir as NSString).appendingPathComponent("real")
        let alias = (dir as NSString).appendingPathComponent("alias")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: real)
        try "root = \(alias)\nroot = /elsewhere\n".write(
            toFile: (dir as NSString).appendingPathComponent("E.prf"), atomically: true, encoding: .utf8)
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(unisonDirectory: dir, excluding: "A"))
        XCTAssertEqual(others.map(\.name), ["E"])
        XCTAssertFalse(others[0].rootsReliable)
    }

    func test_otherProfiles_unresolvableLocalRoot_isUnreliable() throws {
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "G.prf": "root = /somewhere/else\nroot = /elsewhere\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(
            unisonDirectory: dir, excluding: "A",
            resolve: fakeResolve(missing: ["/somewhere/else"])))
        XCTAssertEqual(others.map(\.rootsReliable), [false])
    }

    func test_otherProfiles_cleanUnrelatedProfile_isReliable() throws {
        let dir = try makeUnisonDir([
            "A.prf": "root = \(docs)\nroot = \(backup)\n",
            "F.prf": "root = /somewhere/else\nroot = ssh://athena//srv/x\n",
        ])
        let others = try XCTUnwrap(ArchiveOwnership.otherProfiles(
            unisonDirectory: dir, excluding: "A", resolve: fakeResolve()))
        XCTAssertEqual(others.map(\.rootsReliable), [true])
    }

    // MARK: - Unindexed archives

    func test_unindexedHash_blocksRemoval() {
        // The deleting profile's archive is not in the index (unreadable or
        // inauthentic header). Nobody can match it, which must not read as
        // "nobody owns it".
        let v = ArchiveOwnership.verdict(
            hashes: ["docs", "backup", "ghost"],
            others: [],
            index: localPairIndex, localHostname: host)
        XCTAssertEqual(v.unindexedHashes, ["ghost"])
        XCTAssertEqual(v.otherOwners, [])
        XCTAssertFalse(v.removalPermitted)
    }

    // MARK: - Evaluation and the deletion transaction against a real directory

    /// An authentic archive file: `ar<MD5(thisRoot;rootsName;format)>` with a
    /// parseable header, plus an `fp` sibling.
    @discardableResult
    private func writeArchiveFamily(in dir: String, thisRoot: String, rootsName: String) throws -> String {
        let format = 23
        let header = "Unison archive format \(format)\n" +
            "Archive for root \(thisRoot) synchronizing roots \(rootsName)\n" +
            "Written at 2026-06-28 at 23:19:45 - Unicode case insensitive mode.\n"
        let hash = ArchiveHash.md5Hex("\(thisRoot);\(rootsName);\(format)")
        var data = Data(header.utf8)
        data.append(contentsOf: [0xff, 0x00, 0xfe])
        try data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("ar" + hash)))
        try Data([0x01]).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("fp" + hash)))
        return hash
    }

    /// A Unison directory whose roots live inside it (so realpath resolves
    /// them as written), with profiles A and B on identical roots and the
    /// archive family both of them use. Returns the directory and the hashes.
    private func makeSharedFixture(extraProfiles: [String: String] = [:]) throws -> (dir: String, hashes: [String]) {
        let dir = try makeUnisonDir([:])
        // Resolve the temp dir itself so the roots written into the profiles
        // are already canonical (/private/var vs /var on macOS).
        let canonical = try XCTUnwrap(ArchiveMatcher.realpathResolve(dir))
        let left = (canonical as NSString).appendingPathComponent("left")
        let right = (canonical as NSString).appendingPathComponent("right")
        for p in [left, right] {
            try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        }
        var files = ["A.prf": "root = \(left)\nroot = \(right)\n",
                     "B.prf": "root = \(left)\nroot = \(right)\n"]
        for (k, v) in extraProfiles { files[k] = v }
        for (name, text) in files {
            try text.write(toFile: (dir as NSString).appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
        }
        let pair = "//\(host)/\(right), //\(host)/\(left)"
        let h1 = try writeArchiveFamily(in: dir, thisRoot: "//\(host)/\(left)", rootsName: pair)
        let h2 = try writeArchiveFamily(in: dir, thisRoot: "//\(host)/\(right)", rootsName: pair)
        return (dir, [h1, h2].sorted())
    }

    func test_evaluate_identicalRootsOnDisk_namesTheOtherOwner() throws {
        let f = try makeSharedFixture()
        let v = ArchiveOwnership.evaluate(unisonDirectory: f.dir, deleting: "A", hashes: f.hashes, localHostname: host)
        XCTAssertEqual(v.otherOwners, ["B"])
        XCTAssertEqual(v.unindexedHashes, [])
        XCTAssertFalse(v.removalPermitted)
    }

    func test_evaluate_soleOwnerOnDisk_permitsRemoval() throws {
        let f = try makeSharedFixture()
        try FileManager.default.removeItem(atPath: (f.dir as NSString).appendingPathComponent("B.prf"))
        let v = ArchiveOwnership.evaluate(unisonDirectory: f.dir, deleting: "A", hashes: f.hashes, localHostname: host)
        XCTAssertTrue(v.removalPermitted)
    }

    func test_evaluate_corruptArchiveHeader_isUnindexed_andBlocks() throws {
        let f = try makeSharedFixture()
        try FileManager.default.removeItem(atPath: (f.dir as NSString).appendingPathComponent("B.prf"))
        // Overwrite one archive with an unparseable header; its hash is still
        // requested, so the verdict must refuse rather than treat it as unowned.
        try Data("garbage".utf8).write(
            to: URL(fileURLWithPath: (f.dir as NSString).appendingPathComponent("ar" + f.hashes[0])))
        let v = ArchiveOwnership.evaluate(unisonDirectory: f.dir, deleting: "A", hashes: f.hashes, localHostname: host)
        XCTAssertEqual(v.unindexedHashes, [f.hashes[0]])
        XCTAssertFalse(v.removalPermitted)
    }

    // The transaction fakes mirror ArchiveMutationTransactionTests: no real
    // lock files or Trash, but the real revalidate closure runs against the
    // real directory.
    private final class FakeLocking: ArchiveLocking {
        func acquire(hash: String) -> ArchiveLock.AcquireResult { .acquired }
        @discardableResult func release(hash: String) -> Bool { true }
        func identity(hash: String) -> LockIdentity? {
            LockIdentity(dev: 1, ino: UInt64(hash.count), ctimeSec: 0, ctimeNsec: 0)
        }
    }

    private final class FakeStore: ArchivePayloadStore {
        private(set) var staged: [String] = []
        private(set) var committed = false
        var quarantinePath: String? = "/fake/quarantine"
        func beginIntent(_ m: StagingManifest) throws {}
        func recordPlan(_ m: StagingManifest) throws {}
        func stage(_ name: String) throws { staged.append(name) }
        func rollback() throws { staged.removeAll() }
        func discardRecord() throws {}
        func markCommitted() throws {}
        func trashQuarantine() throws { committed = true }
    }

    func test_deletionTransaction_sharedOwner_revalidationRefuses_nothingStaged() throws {
        let f = try makeSharedFixture()
        let store = FakeStore()
        let result = ArchiveMaintenance.mutate(
            operation: "delete-with-archives", hashes: f.hashes, unisonDirectory: f.dir,
            isEngineIdle: { true },
            revalidate: { plan in
                ArchiveOwnership.revalidateDeletion(plan: plan, unisonDirectory: f.dir,
                                                    deleting: "A", localHostname: self.host)
            },
            locking: FakeLocking(), store: store)
        guard case .failure(let error) = result else {
            return XCTFail("expected revalidation to refuse, got \(result)")
        }
        XCTAssertEqual(error as? ArchiveMutationError, .revalidationFailed)
        XCTAssertEqual(store.staged, [])
        XCTAssertFalse(store.committed)
        for h in f.hashes {
            XCTAssertTrue(FileManager.default.fileExists(atPath: (f.dir as NSString).appendingPathComponent("ar" + h)))
        }
    }

    func test_deletionTransaction_profileAddedWhileConfirming_isCaughtUnderLock() throws {
        // The confirmation was computed when A was the sole owner; by the time
        // the transaction runs, a same-root profile C exists. revalidate reads
        // the directory fresh and refuses.
        let f = try makeSharedFixture()
        try FileManager.default.removeItem(atPath: (f.dir as NSString).appendingPathComponent("B.prf"))
        XCTAssertTrue(ArchiveOwnership.evaluate(unisonDirectory: f.dir, deleting: "A",
                                                hashes: f.hashes, localHostname: host).removalPermitted)
        let aText = try String(contentsOfFile: (f.dir as NSString).appendingPathComponent("A.prf"), encoding: .utf8)
        try aText.write(toFile: (f.dir as NSString).appendingPathComponent("C.prf"), atomically: true, encoding: .utf8)
        let store = FakeStore()
        let result = ArchiveMaintenance.mutate(
            operation: "delete-with-archives", hashes: f.hashes, unisonDirectory: f.dir,
            isEngineIdle: { true },
            revalidate: { plan in
                ArchiveOwnership.revalidateDeletion(plan: plan, unisonDirectory: f.dir,
                                                    deleting: "A", localHostname: self.host)
            },
            locking: FakeLocking(), store: store)
        guard case .failure(let error) = result else {
            return XCTFail("expected revalidation to refuse, got \(result)")
        }
        XCTAssertEqual(error as? ArchiveMutationError, .revalidationFailed)
        XCTAssertEqual(store.staged, [])
    }

    func test_deletionTransaction_soleOwner_stagesTheWholeFamily() throws {
        let f = try makeSharedFixture()
        try FileManager.default.removeItem(atPath: (f.dir as NSString).appendingPathComponent("B.prf"))
        let store = FakeStore()
        let result = ArchiveMaintenance.mutate(
            operation: "delete-with-archives", hashes: f.hashes, unisonDirectory: f.dir,
            isEngineIdle: { true },
            revalidate: { plan in
                ArchiveOwnership.revalidateDeletion(plan: plan, unisonDirectory: f.dir,
                                                    deleting: "A", localHostname: self.host)
            },
            locking: FakeLocking(), store: store)
        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        let expected = f.hashes.flatMap { ["ar" + $0, "fp" + $0] }.sorted()
        XCTAssertEqual(store.staged.sorted(), expected)
        XCTAssertTrue(store.committed)
    }

    func test_deletionTransaction_missingArchive_revalidationRefuses() throws {
        let f = try makeSharedFixture()
        try FileManager.default.removeItem(atPath: (f.dir as NSString).appendingPathComponent("B.prf"))
        try FileManager.default.removeItem(atPath: (f.dir as NSString).appendingPathComponent("ar" + f.hashes[1]))
        let store = FakeStore()
        let result = ArchiveMaintenance.mutate(
            operation: "delete-with-archives", hashes: f.hashes, unisonDirectory: f.dir,
            isEngineIdle: { true },
            revalidate: { plan in
                ArchiveOwnership.revalidateDeletion(plan: plan, unisonDirectory: f.dir,
                                                    deleting: "A", localHostname: self.host)
            },
            locking: FakeLocking(), store: store)
        guard case .failure(let error) = result else {
            return XCTFail("expected revalidation to refuse, got \(result)")
        }
        XCTAssertEqual(error as? ArchiveMutationError, .revalidationFailed)
        XCTAssertEqual(store.staged, [])
    }

    // MARK: - Reset copy

    func test_sharedOwnersNote_empty_single_multiple() {
        XCTAssertEqual(ProfileEditorWindowController.sharedOwnersNote([]), "")
        XCTAssertEqual(ProfileEditorWindowController.sharedOwnersNote(["B"]),
            "\nThe profile “B” has the same roots and shares these archive files, so "
            + "its next sync will also rebuild from scratch.\n")
        XCTAssertEqual(ProfileEditorWindowController.sharedOwnersNote(["B", "C"]),
            "\nThe profiles “B”, “C” have the same roots and share these archive files, so "
            + "their next sync will also rebuild from scratch.\n")
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

    func test_keptText_unindexed() {
        let text = ProfileEditorWindowController.archivesKeptText(
            count: 2, ownership: .init(otherOwners: [], unresolvedProfiles: [], unindexedHashes: ["x"]))
        XCTAssertTrue(text.contains("an archive header could not be read"))
    }

    func test_keptText_enumerationFailed() {
        let text = ProfileEditorWindowController.archivesKeptText(
            count: 2, ownership: .init(otherOwners: [], unresolvedProfiles: [], enumerationFailed: true))
        XCTAssertTrue(text.contains("profile folder could not be read"))
    }
}
