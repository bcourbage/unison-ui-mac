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

    private func hashes(of profile: String) throws -> [String] {
        guard case .success(let c) = ArchiveHash.computeAll(unisonDirectory: dir, profile: profile, hostname: host) else {
            throw XCTSkip("fixture profile \(profile) must resolve")
        }
        return c.hashes
    }

    private func gate(_ profile: String, _ records: [AbandonedStaging]) -> ProfileStagingGate {
        let blocked = Set(records.flatMap { $0.manifest.hashes })
        return ProfileStagingGate.evaluate(profile: profile, unisonDirectory: dir, blockedHashes: blocked,
                                           blockingRecords: records, hostname: host)
    }

    // MARK: confirmed

    func test_confirmedMatch_returnsOnlyTheMatchingRecords() throws {
        try write("Direct.prf", roots)
        let mine = record("/q/mine", hashes: try hashes(of: "Direct"))
        let other = record("/q/other", hashes: ["feedfacefeedfacefeedfacefeedface"])
        XCTAssertEqual(gate("Direct", [mine, other]), .confirmed([mine]))
    }

    func test_includeBasedProfile_isBlockedExactlyLikeTheDirectProfile() throws {
        try write("Direct.prf", roots)
        try write("common.inc", roots)
        try write("Inc.prf", "include common.inc\n")
        let mine = record("/q/mine", hashes: try hashes(of: "Direct"))
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
        XCTAssertTrue(confirmed.contains("its archives are being recovered"), confirmed)
        XCTAssertFalse(unresolved.contains("its archives are being recovered"), unresolved)
        XCTAssertTrue(unresolved.contains("could not be resolved"), unresolved)
        XCTAssertTrue(unresolved.contains("Complete that recovery in the running app"), unresolved)
    }
}
