import XCTest
@testable import unison_ui_mac

/// The Check Remote Command control in the Profile Editor over a stubbed ssh
/// executor: Step 1 failures shown under the field, the discovery menu,
/// verification results in the status line and report, the proposal filling
/// the field, invalidation on edits, and the Save-time re-derivation.
@MainActor
final class ProfileFormRemoteCheckTests: XCTestCase {
    nonisolated(unsafe) private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pfrc-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }
    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }
    private func read(_ name: String) throws -> String { try String(contentsOfFile: "\(dir!)/\(name)", encoding: .utf8) }

    /// Answers discovery with a record and verification with a version line, echoing the marker from argv.
    private final class Remote: VersionCheck.VersionProbeExecutor, @unchecked Sendable {
        var version = "unison version 2.54.0 (ocaml 5.5.0)"
        var sessions = 0
        func execute(_ config: VersionCheck.ProbeConfig, deadline: TimeInterval, canceller: VersionCheck.ProbeCanceller) -> VersionCheck.RawExecResult {
            sessions += 1
            let remote = config.arguments.last ?? ""
            if let r = remote.range(of: "M=") {
                let m = String(remote[r.upperBound...].prefix { $0 != ";" })
                return .exited(status: 0, stdout: "\(m) BEGIN\nuname: Darwin\npath: /opt/homebrew/bin/unison\nkind: regular\nversion: \(version)\nabsent: /usr/local/bin/unison\ncommandv: \n\(m) END\n", stderr: "")
            }
            if let r = remote.range(of: "printf '") {
                let m = String(remote[r.upperBound...].prefix { $0 != "'" })
                return .exited(status: 0, stdout: "\(m)\(version)\n", stderr: "")
            }
            return .launchFailed("unexpected command")
        }
    }

    private func make(_ name: String, remote: Remote) -> ProfileFormWindowController {
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: name, onSaved: { _ in })
        c.suppressAlertsForTesting = true
        c.disclosureDecisionForTesting = true
        c.engineVersionForTesting = "2.54.0 (ocaml 5.5.0)"
        c.checkExecutorFactoryForTesting = { _ in remote }
        return c
    }

    func test_step1Failure_showsUnderField_andRunsNoSession() async throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        let remote = Remote()
        let c = make("p", remote: remote)
        let d = await c.runCheck()
        XCTAssertNil(d)
        XCTAssertEqual(c.checkStatusForTesting, "Neither root is an ssh:// root; there is no remote command to check.")
        XCTAssertEqual(remote.sessions, 0)
    }

    func test_discovery_thenKeepCurrent_reportsNoChange() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\nservercmd = /opt/homebrew/bin/unison\n")
        let remote = Remote()
        let c = make("p", remote: remote)
        let d = await c.runCheck()
        XCTAssertEqual(d?.succeeded, true)
        XCTAssertEqual(c.checkMenuForTesting, [
            .candidate(path: "/opt/homebrew/bin/unison", versionLine: "unison version 2.54.0 (ocaml 5.5.0)", storedTarget: nil),
            .keepCurrent,
        ])
        XCTAssertEqual(c.checkStatusForTesting, "Choose the command to verify on demeter.")
        await c.chooseCandidate(.keepCurrent)
        XCTAssertEqual(c.checkStatusForTesting, "This check found no change to make.")
        XCTAssertEqual(c.checkReportForTesting.first, "This check found no change to make.")
        XCTAssertEqual(c.checkReportForTesting.last, "Only a synchronization confirms the server protocol; run the profile to test that.")
        XCTAssertTrue(c.checkReportForTesting.contains("ssh connected to demeter as bruno without prompting."))
        XCTAssertFalse(c.checkReportForTesting.joined().contains("inside a unison-ui-mac.app bundle"))
        XCTAssertEqual(remote.sessions, 2)
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison", "unchanged")
    }

    func test_candidate_fillsField_andSaveWritesIt() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\ninclude common\n")
        try write("common.prf", "sshargs = -i /k\n")
        let remote = Remote()
        let c = make("p", remote: remote)
        _ = await c.runCheck()
        XCTAssertEqual(c.checkMenuForTesting?.first, .currentEffect("Remote PATH decides which unison runs"))
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison")
        XCTAssertEqual(c.checkStatusForTesting, "The command you selected started over ssh and reported its version. Remote unison is set to it; Save to keep the change.")
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        XCTAssertEqual(try read("p.prf"), "root = /a\nroot = ssh://bruno@demeter//x\ninclude common\nservercmd = /opt/homebrew/bin/unison\n")
    }

    func test_incompatibleRemote_noProposal_boundaryHeadline() async throws {
        try write("p.prf", "root = /a\nroot = ssh://demeter//x\n")
        let remote = Remote(); remote.version = "unison version 2.51.5"
        let c = make("p", remote: remote)
        _ = await c.runCheck()
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "", "no proposal applied")
        XCTAssertEqual(c.checkStatusForTesting, "The command started over ssh and reported version 2.51.5. 2.51.5 (demeter) and 2.54.0 (this Mac) are on opposite sides of the 2.52 boundary and cannot connect.")
        XCTAssertEqual(c.checkResultForTesting?.compatible, false)
    }

    func test_editingAParticipatingField_invalidatesTheResult() async throws {
        try write("p.prf", "root = /a\nroot = ssh://demeter//x\nservercmd = /opt/homebrew/bin/unison\n")
        let c = make("p", remote: Remote())
        _ = await c.runCheck()
        await c.chooseCandidate(.keepCurrent)
        XCTAssertNotNil(c.checkResultForTesting)
        c.setRootFieldForTesting(second: "ssh://other//x")
        XCTAssertNil(c.checkResultForTesting)
        XCTAssertNil(c.checkMenuForTesting)
        XCTAssertEqual(c.checkStatusForTesting, "Not checked since the last change.")
    }

    func test_includeChangedAfterCheck_saveReportsChange_andStillSaves() async throws {
        try write("p.prf", "root = /a\nroot = ssh://demeter//x\ninclude common\n")
        try write("common.prf", "sshargs = -i /k\n")
        let c = make("p", remote: Remote())
        _ = await c.runCheck()
        await c.chooseCandidate(.keepCurrent)
        XCTAssertNotNil(c.checkResultForTesting)
        try write("common.prf", "sshargs = -i /other\n")
        c.setTriStateForTesting("times", .on)
        c.invokeSaveForTesting()
        XCTAssertEqual(c.checkStatusForTesting, "The remote command changed since it was checked.")
        XCTAssertNil(c.checkResultForTesting)
        XCTAssertTrue(try read("p.prf").contains("times = true\n"), "save proceeded")
    }

    func test_proposalSettingAddversionnoFalse_winsOverAnInclude_atSave() async throws {
        // Reviewer's case: top-level addversionno = true before an include that
        // also sets it true. The candidate has no -2.54 suffix, so the proposal
        // sets addversionno false; Save must make that the effective value.
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\naddversionno = true\ninclude common\n")
        try write("common.prf", "addversionno = true\n")
        let c = make("p", remote: Remote())
        _ = await c.runCheck()
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertEqual(c.checkResultForTesting?.proposal, .init(servercmd: "/opt/homebrew/bin/unison", setsAddversionnoFalse: true))
        XCTAssertTrue(c.advancedLinesForTesting.contains("addversionno = false"))
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        guard case .success(let e) = EffectiveProfile.load(profile: "p", unisonDirectory: dir) else { return XCTFail() }
        XCTAssertEqual(e.bool("addversionno"), false, "the saved profile runs the command that was verified")
        XCTAssertEqual(e.scalar("servercmd")?.value, "/opt/homebrew/bin/unison")
        XCTAssertEqual(RemoteSettings(profile: e).addversionno, false)
    }

    func test_userOverridesProposedAddversionno_inAdvanced_saveKeepsTheUsersValue() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\naddversionno = true\ninclude common\n")
        try write("common.prf", "addversionno = true\n")
        let c = make("p", remote: Remote())
        _ = await c.runCheck()
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertTrue(c.advancedLinesForTesting.contains("addversionno = false"))
        // The user deliberately puts it back to true before saving.
        c.setAdvancedLinesForTesting(c.advancedLinesForTesting.filter { !$0.hasPrefix("addversionno") } + ["addversionno = true"])
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        guard case .success(let e) = EffectiveProfile.load(profile: "p", unisonDirectory: dir) else { return XCTFail() }
        XCTAssertEqual(e.bool("addversionno"), true, "the user's edit wins; no hidden flag overrides it")
    }

    func test_editingAnSshField_afterAProposal_leavesTheAdvancedLineVisible() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\naddversionno = true\n")
        let c = make("p", remote: Remote())
        _ = await c.runCheck()
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertTrue(c.advancedLinesForTesting.contains("addversionno = false"))
        c.setRemoteFieldForTesting("sshargs", "-i /other"); c.setRootFieldForTesting(second: "ssh://bruno@demeter//x")
        XCTAssertTrue(c.advancedLinesForTesting.contains("addversionno = false"), "the visible line is ordinary editor state")
        XCTAssertNil(c.checkResultForTesting)
    }

    func test_includedSshRoot_failsStep1_beforeAnySession() async throws {
        try write("p.prf", "root = /a\nroot = ssh://demeter//x\ninclude common\n")
        try write("common.prf", "root = ssh://other//y\n")
        let remote = Remote()
        let c = make("p", remote: remote)
        let d = await c.runCheck()
        XCTAssertNil(d)
        XCTAssertEqual(c.checkStatusForTesting, "cannot synchronize more than one remote root")
        XCTAssertEqual(remote.sessions, 0)
    }

    func test_unsavedProfile_cannotBeChecked() async {
        let c = ProfileFormWindowController(unisonDirectory: dir, profileName: nil, onSaved: { _ in })
        c.suppressAlertsForTesting = true
        c.checkExecutorFactoryForTesting = { _ in Remote() }
        let d = await c.runCheck()
        XCTAssertNil(d)
        XCTAssertEqual(c.checkStatusForTesting, "Save the profile once before checking its remote command.")
    }

    func test_startFailureTexts() {
        XCTAssertEqual(ProfileFormWindowController.startFailureText(.roots("Wrong number of roots: x")), "Wrong number of roots: x")
        XCTAssertTrue(ProfileFormWindowController.startFailureText(.notApplicable(.socketRoot)).contains("socket://"))
        XCTAssertTrue(ProfileFormWindowController.startFailureText(.shellCommandNotFound(name: "nossh", searched: ["/usr/bin"])).contains("\"nossh\""))
        XCTAssertTrue(ProfileFormWindowController.startFailureText(.profile("Profile p not found")).hasPrefix("Unison would not load this profile as it is: "))
    }
}
