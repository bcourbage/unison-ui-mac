import XCTest
import AppKit
@testable import unison_ui_mac

/// The open gate's two consumers in AppDelegate: the picker selection and the
/// command-line handoff. An unresolved profile must not be opened or admitted
/// while interrupted operations hold archives.
@MainActor
final class StagingGateWiringTests: XCTestCase {

    /// A Unison directory holding one profile whose include does not exist.
    private func makeDirectory() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("sgw-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "include missing.inc\n".write(toFile: dir + "/Broken.prf", atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// Skip the recovery prompt (its modal would block the suite) for one test.
    private func suppressRecoveryPrompt() {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }
    }

    private func heldRecord() -> AbandonedStaging {
        var m = StagingManifest(operation: "reset", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
                                payloadFiles: [], createdAtISO8601: "2026-11-01T00:00:00Z")
        m.phase = StagingManifest.phaseStaging
        return AbandonedStaging(quarantineDir: "/q/held", manifest: m)
    }

    private func delegate(holding: Bool, dir: String) -> AppDelegate {
        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        if holding { d.setAbandonedStagingForTesting([heldRecord()]) }
        return d
    }

    func test_picker_unresolvedProfile_isNotOpenedWhileArchivesAreHeld() throws {
        suppressRecoveryPrompt()
        let d = delegate(holding: true, dir: try makeDirectory())
        XCTAssertFalse(d.profileSelectedForTesting("Broken", args: []))
        XCTAssertEqual(d.engineForTesting.phase, .idle, "the engine must not be asked to open it")
        XCTAssertFalse(d.engineForTesting.openRequestPending)
    }

    func test_cli_unresolvedProfile_isRefusedWithoutAdmittingTheRequest() throws {
        suppressRecoveryPrompt()
        let dir = try makeDirectory()
        let d = delegate(holding: true, dir: dir)
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

    // MARK: launch ordering

    /// A directory with a held staging record on disk, a profile that cannot be
    /// resolved (so it is blocked while anything is held), and an unrelated one.
    private func makeHeldDirectory() throws -> String {
        let dir = try XCTUnwrap(ArchiveMatcher.realpathResolve(try makeDirectory()))
        let q = dir + "/" + AbandonedStagingScan.quarantinePrefix + "held"
        try FileManager.default.createDirectory(atPath: q, withIntermediateDirectories: true)
        var m = StagingManifest(operation: "reset", hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
                                payloadFiles: [], createdAtISO8601: "2026-11-01T00:00:00Z")
        m.phase = StagingManifest.phaseStaging
        try JSONEncoder().encode(m).write(to: URL(fileURLWithPath: q + "/" + AbandonedStagingScan.manifestName))
        for r in ["ua", "ub"] {
            try FileManager.default.createDirectory(atPath: dir + "/" + r, withIntermediateDirectories: true)
        }
        // The gate trusts a root only when its path is already canonical.
        let real = dir
        try "root = \(real)/ua\nroot = \(real)/ub\n".write(toFile: dir + "/Other.prf", atomically: true, encoding: .utf8)
        return dir
    }

    private func request(_ name: String, dir: String) -> CommandLineHandoff.Request {
        CommandLineHandoff.Request(given: name, rootsSet: 0, unisonDirectory: dir,
                                   installationPath: Bundle.main.bundlePath, sessionArgs: [])
    }

    /// The launch-state load runs before the listener starts and the picker is
    /// shown, so a request served first still sees the held archives. Without
    /// the load the held record is invisible and the blocked profile opens.
    func test_launchStateLoad_makesHeldArchivesVisibleToTheFirstRequest() throws {
        suppressRecoveryPrompt()
        let dir = try makeHeldDirectory()
        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        d.loadLaunchStateBeforeRoutingForTesting()
        // If a regression admits the request, do not start engine work on the
        // shared hosted-test engine; the assertion below still fails on `.started`.
        d.suppressEngineEffectsForTesting = true

        let served = d.handleCommandLineHandoffForTesting(
            request("Broken", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .reply(.refused(let message)) = served else {
            return XCTFail("the held profile must be refused from the first request, got \(served)")
        }
        XCTAssertTrue(message.contains("could not be resolved"), message)
        XCTAssertEqual(d.engineForTesting.phase, .idle)
    }

    /// Control: a profile unrelated to the held archives is still admitted.
    func test_launchStateLoad_doesNotBlockAnUnrelatedProfile() throws {
        suppressRecoveryPrompt()
        let dir = try makeHeldDirectory()
        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        d.loadLaunchStateBeforeRoutingForTesting()
        d.suppressEngineEffectsForTesting = true

        let served = d.handleCommandLineHandoffForTesting(
            request("Other", dir: dir), deadline: CommandLineHandoffSocket.Deadline(seconds: 30))
        guard case .reply(.started) = served, d.engineForTesting.phase != .idle else {
            return XCTFail("an unrelated profile must still open, got \(served)")
        }
    }

    /// A profile with a remote root is refused from a command-line request while
    /// archives are held, because its archives cannot be identified from its roots.
    func test_cli_remoteRootProfile_isRefusedWhileArchivesAreHeld() throws {
        suppressRecoveryPrompt()
        let dir = try makeDirectory()
        try "root = /Users/test/Documents\nroot = ssh://alice@server//data\n"
            .write(toFile: dir + "/Remote.prf", atomically: true, encoding: .utf8)
        let d = delegate(holding: true, dir: dir)
        let request = CommandLineHandoff.Request(given: "Remote", rootsSet: 0, unisonDirectory: dir,
                                                 installationPath: Bundle.main.bundlePath, sessionArgs: [])
        let served = d.handleCommandLineHandoffForTesting(
            request, deadline: CommandLineHandoffSocket.Deadline(seconds: 30))

        guard case .reply(.refused(let message)) = served else {
            return XCTFail("expected a refusal, got \(served)")
        }
        XCTAssertTrue(message.contains("remote root"), message)
        XCTAssertEqual(d.engineForTesting.phase, .idle)
        XCTAssertFalse(d.engineForTesting.commandLineRequestPending)
    }

    func test_picker_remoteRootProfile_isNotOpenedWhileArchivesAreHeld() throws {
        suppressRecoveryPrompt()
        let dir = try makeDirectory()
        try "root = /Users/test/Documents\nroot = ssh://alice@server//data\n"
            .write(toFile: dir + "/Remote.prf", atomically: true, encoding: .utf8)
        let d = delegate(holding: true, dir: dir)
        XCTAssertFalse(d.profileSelectedForTesting("Remote", args: []))
        XCTAssertEqual(d.engineForTesting.phase, .idle)
    }
}
