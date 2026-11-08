import XCTest
@testable import unison_ui_mac

/// The open gate for a profile while interrupted archive operations exist
/// (issue #196). A confirmed match identifies the records that belong to the
/// profile; a profile whose roots cannot be resolved might overlap any of them,
/// so it is blocked too, but without claiming any one record as its own.
final class ProfileStagingGateTests: XCTestCase {

    private let host = "Heracles"
    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("psg-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8)
    }
    private let roots = "root = /Users/test/Documents\nroot = /Users/test/Backup/Documents\n"

    private func record(_ q: String, hashes: [String]) -> AbandonedStaging {
        var m = StagingManifest(operation: "reset", hashes: hashes, payloadFiles: [],
                                createdAtISO8601: "2026-11-01T00:00:00Z")
        m.phase = StagingManifest.phaseStaging
        return AbandonedStaging(quarantineDir: q, manifest: m)
    }

    /// The archive hashes of a local pair, computed from the roots written out
    /// here, never through the profile lookup under test, so a lookup regression
    /// cannot change both sides of an assertion.
    private func rootHashes(_ a: String, _ b: String) throws -> [String] {
        let computed = try XCTUnwrap(
            { () -> ArchiveHash.MultiResult? in
                if case .success(let c) = ArchiveHash.computeAll(forRoots: [a, b], hostname: host) { return c }
                return nil
            }(), "fixture roots must yield archive hashes")
        return computed.hashes
    }
    private let docs = "/Users/test/Documents"
    private let backup = "/Users/test/Backup/Documents"

    private func gate(_ profile: String, _ records: [AbandonedStaging],
                      resolve: (String) -> String? = { $0 }) -> ProfileStagingGate {
        let blocked = Set(records.flatMap { $0.manifest.hashes })
        return ProfileStagingGate.evaluate(profile: profile, unisonDirectory: dir, blockedHashes: blocked,
                                           blockingRecords: records, hostname: host, resolve: resolve)
    }

    // MARK: confirmed

    func test_confirmedMatch_returnsOnlyTheMatchingRecords() throws {
        try write("Direct.prf", roots)
        let mine = record("/q/mine", hashes: try rootHashes(docs, backup))
        let other = record("/q/other", hashes: ["feedfacefeedfacefeedfacefeedface"])
        XCTAssertEqual(gate("Direct", [mine, other]), .confirmed([mine]))
    }

    func test_includeBasedProfile_isBlockedExactlyLikeTheDirectProfile() throws {
        try write("Direct.prf", roots)
        try write("common.inc", roots)
        try write("Inc.prf", "include common.inc\n")
        let mine = record("/q/mine", hashes: try rootHashes(docs, backup))
        XCTAssertEqual(gate("Inc", [mine]), gate("Direct", [mine]))
        XCTAssertEqual(gate("Inc", [mine]), .confirmed([mine]))
    }

    func test_resolvedProfileWithNoOverlap_isClear() throws {
        try write("Direct.prf", roots)
        let other = record("/q/other", hashes: ["feedfacefeedfacefeedfacefeedface"])
        XCTAssertEqual(gate("Direct", [other]), .clear)
    }

    // MARK: unresolved

    func test_unresolvedProfile_withBlockingRecords_isBlockedWithoutClaimingAnyRecord() throws {
        try write("Broken.prf", "include missing.inc\n")
        let a = record("/q/a", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        let b = record("/q/b", hashes: ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        let result = gate("Broken", [a, b])
        XCTAssertEqual(result, .unresolved([a, b]))
        XCTAssertTrue(result.blocksOpening)
    }

    func test_unresolvedProfile_withNoBlockingRecords_opensNormally() throws {
        try write("Broken.prf", "include missing.inc\n")
        XCTAssertEqual(gate("Broken", []), .clear)
    }

    /// `P.prf` sources `P`, which does not exist. The failed read is a missing
    /// include, not a missing profile, so the profile must stay blocked.
    func test_selfSourceWithNoSuchFile_isUnresolvedNotClear() throws {
        try write("P.prf", "source P\n" + roots)
        let r = record("/q/r", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertEqual(gate("P", [r]), .unresolved([r]))
    }

    /// The gate follows the engine's lookup: an extensionless `P` wins over `P.prf`.
    func test_gate_usesTheEnginesProfileLookup() throws {
        try write("P", roots)
        try write("P.prf", "root = /Users/test/Other/A\nroot = /Users/test/Other/B\n")
        let r = record("/q/r", hashes: try rootHashes(docs, backup))
        XCTAssertEqual(gate("P", [r]), .confirmed([r]))
    }

    /// `rootalias` rewrites the roots before Unison names the archive, so the
    /// hash computed from the written roots cannot be trusted to match.
    func test_rootalias_isUnresolvedNotClear() throws {
        try write("Aliased.prf", roots + "rootalias = //Heracles//Users/test/Documents -> //Other//Users/test/Documents\n")
        let r = record("/q/r", hashes: try rootHashes(docs, backup))
        XCTAssertEqual(gate("Aliased", [r]), .unresolved([r]))
    }

    /// Unison names an archive from the canonical path; a symlinked local root
    /// would hash differently here, so it cannot be matched and stays blocked.
    func test_symlinkedLocalRoot_isUnresolvedNotClear() throws {
        try write("Linked.prf", roots)
        let r = record("/q/r", hashes: try rootHashes(docs, backup))
        let resolve: (String) -> String? = { $0 == self.docs ? "/Users/test/Real/Documents" : $0 }
        XCTAssertEqual(gate("Linked", [r], resolve: resolve), .unresolved([r]))
    }

    func test_unresolvableLocalRoot_isUnresolvedNotClear() throws {
        try write("Gone.prf", roots)
        let r = record("/q/r", hashes: try rootHashes(docs, backup))
        XCTAssertEqual(gate("Gone", [r], resolve: { _ in nil }), .unresolved([r]))
    }

    func test_includeCycle_isUnresolved() throws {
        try write("A.prf", "include B\n")
        try write("B.prf", "include A\n")
        let r = record("/q/r", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertEqual(gate("A", [r]), .unresolved([r]))
    }

    // MARK: unchanged cases

    func test_profileWithNoLocalRoot_isClear() throws {
        try write("Remote.prf", "root = ssh://a@h//x\nroot = ssh://a@h//y\n")
        let r = record("/q/r", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertEqual(gate("Remote", [r]), .clear)
    }

    func test_missingProfile_isClear() {
        let r = record("/q/r", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertEqual(gate("Nope", [r]), .clear)
    }

    // MARK: wording

    func test_picker_unresolvedContextDoesNotClaimTheProfilesOwnArchives() {
        let confirmed = ProfileStagingGate.confirmed([]).recoveryContext
        let unresolved = ProfileStagingGate.unresolved([]).recoveryContext
        XCTAssertTrue(confirmed.contains("This profile's archives"), confirmed)
        XCTAssertFalse(unresolved.contains("This profile's archives"), unresolved)
        XCTAssertTrue(unresolved.contains("could not be resolved"), unresolved)
    }

    func test_cli_refusalWordingMatchesWhatIsKnown() {
        let confirmed = ProfileStagingGate.confirmed([]).refusalMessage(profile: "P")
        let unresolved = ProfileStagingGate.unresolved([]).refusalMessage(profile: "P")
        XCTAssertTrue(confirmed.contains("its archives are held by"), confirmed)
        XCTAssertFalse(unresolved.contains("its archives are held by"), unresolved)
        XCTAssertTrue(unresolved.contains("could not be resolved"), unresolved)
        XCTAssertTrue(unresolved.contains("Complete that recovery in the running app"), unresolved)
    }
}
