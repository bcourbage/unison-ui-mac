import XCTest
import AppKit
@testable import unison_ui_mac

/// The open gate's two consumers in AppDelegate: the picker selection and the
/// command-line handoff. An unresolved profile must not be opened or admitted
/// while interrupted operations hold archives.
@MainActor
final class StagingGateWiringTests: XCTestCase {

    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("sgw-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "include missing.inc\n".write(toFile: dir + "/Broken.prf", atomically: true, encoding: .utf8)
        AppDelegate.testRecoveryPromptSuppressed = true
    }
    override func tearDownWithError() throws {
        AppDelegate.testRecoveryPromptSuppressed = false
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func heldRecord() -> AbandonedStaging {
        var m = StagingManifest(operation: "reset", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
                                payloadFiles: [], createdAtISO8601: "2026-11-01T00:00:00Z")
        m.phase = StagingManifest.phaseStaging
        return AbandonedStaging(quarantineDir: "/q/held", manifest: m)
    }

    private func delegate(holding: Bool) -> AppDelegate {
        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        if holding { d.setAbandonedStagingForTesting([heldRecord()]) }
        return d
    }

    func test_picker_unresolvedProfile_isNotOpenedWhileArchivesAreHeld() {
        let d = delegate(holding: true)
        XCTAssertFalse(d.profileSelectedForTesting("Broken", args: []))
        XCTAssertEqual(d.engineForTesting.phase, .idle, "the engine must not be asked to open it")
        XCTAssertFalse(d.engineForTesting.openRequestPending)
    }

    func test_cli_unresolvedProfile_isRefusedWithoutAdmittingTheRequest() {
        let d = delegate(holding: true)
        let request = CommandLineHandoff.Request(given: "Broken", rootsSet: 0, unisonDirectory: dir,
                                                 installationPath: Bundle.main.bundlePath, sessionArgs: [])
        let served = d.handleCommandLineHandoffForTesting(
            request, deadline: CommandLineHandoffSocket.Deadline(seconds: 30))

        guard case .reply(.refused(let message)) = served else {
            return XCTFail("expected a refusal, got \(served)")
        }
        XCTAssertTrue(message.contains("could not be resolved"), message)
        XCTAssertFalse(message.contains("its archives are held by"), message)
        XCTAssertEqual(d.engineForTesting.phase, .idle)
        XCTAssertFalse(d.engineForTesting.commandLineRequestPending)
    }
}
