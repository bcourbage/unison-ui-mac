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
        /// The login shell has no `unison` in PATH: a bare-name command fails 127.
        var bareUnisonMissing = false
        var sessions = 0
        var remoteCommands: [String] = []
        func execute(_ config: VersionCheck.ProbeConfig, deadline: TimeInterval, canceller: VersionCheck.ProbeCanceller) -> VersionCheck.RawExecResult {
            sessions += 1
            let remote = config.arguments.last ?? ""
            remoteCommands.append(remote)
            if let r = remote.range(of: "M=") {
                let m = String(remote[r.upperBound...].prefix { $0 != ";" })
                return .exited(status: 0, stdout: "\(m) BEGIN\nuname: Darwin\npath: /opt/homebrew/bin/unison\nkind: regular\nversion: \(version)\nabsent: /usr/local/bin/unison\ncommandv: \n\(m) END\n", stderr: "")
            }
            if let r = remote.range(of: "printf '") {
                let m = String(remote[r.upperBound...].prefix { $0 != "'" })
                if bareUnisonMissing, remote.contains("; unison -version") {
                    return .exited(status: 127, stdout: m, stderr: "zsh:1: command not found: unison\n")
                }
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

    func test_checkRow_sitsRightUnderRemoteUnison_atAnyWindowHeight_everyOpen() throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\nservercmd = /opt/homebrew/bin/unison\n")
        var gaps: [CGFloat] = []
        for height in [640, 1100, 1500] {
            let c = make("p", remote: Remote())
            c.window?.setContentSize(NSSize(width: 900, height: CGFloat(height)))
            c.showSectionForTesting(title: "Roots")
            gaps.append(c.checkRowGapForTesting)
            c.close()
        }
        for g in gaps {
            XCTAssertGreaterThanOrEqual(g, 0, "\(gaps)")
            XCTAssertLessThanOrEqual(g, 24, "the row must not float away from its field: \(gaps)")
        }
        XCTAssertEqual(Set(gaps.map { Int($0.rounded()) }).count, 1, "same gap at every height: \(gaps)")
    }

    func test_checkStatusRow_takesNoHeightUntilThereIsAStatus() async throws {
        try write("p.prf", "root = /a\nroot = /b\n")
        let c = make("p", remote: Remote())
        XCTAssertTrue(c.checkStatusRowHiddenForTesting)
        _ = await c.runCheck()
        XCTAssertFalse(c.checkStatusRowHiddenForTesting)
        XCTAssertEqual(c.checkHelpTextForTesting.first, "Which command should I use?")
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

    func test_check_verifiesTheCurrentCommandFirst_andReportsNoChangeNeeded() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\nservercmd = /opt/homebrew/bin/unison\n")
        let remote = Remote()
        let c = make("p", remote: remote)
        let d = await c.runCheck()
        XCTAssertEqual(d?.succeeded, true)
        XCTAssertEqual(remote.sessions, 2, "discovery, then the current command, with no question asked")
        XCTAssertEqual(c.checkStatusForTesting, "No change needed.")
        XCTAssertEqual(c.checkReportForTesting.first, "No change needed.")
        XCTAssertEqual(c.checkReportForTesting.last, "Only a synchronization confirms the server protocol; run the profile to test that.")
        XCTAssertTrue(c.checkReportForTesting.contains("ssh connected to demeter as bruno without prompting."))
        XCTAssertFalse(c.checkReportForTesting.joined().contains("inside a unison-ui-mac.app bundle"))
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison", "unchanged")
        XCTAssertEqual(c.checkAlternativesForTesting?.map(\.kind), [.keepCurrent], "the only installation found is the current one")
        XCTAssertFalse(c.chooseButtonVisibleForTesting, "nothing else to choose")
    }

    func test_candidate_fillsField_andSaveWritesIt() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\ninclude common\n")
        try write("common.prf", "sshargs = -i /k\n")
        let remote = Remote()
        let c = make("p", remote: remote)
        _ = await c.runCheck()
        XCTAssertEqual(c.checkStatusForTesting, "No change needed.", "the PATH-resolved command answered")
        XCTAssertEqual(c.checkAlternativesForTesting?.map(\.kind), [.keepCurrent, .direct])
        XCTAssertEqual(c.checkAlternativesForTesting?.first?.subtitle, "Currently configured for this profile; the remote PATH decides which unison runs.")
        XCTAssertTrue(c.chooseButtonVisibleForTesting)
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison")
        XCTAssertEqual(c.checkStatusForTesting, "The command you selected started over ssh and reported its version. Remote unison is set to it; Save to keep the change.")
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting)
        XCTAssertEqual(try read("p.prf"), "root = /a\nroot = ssh://bruno@demeter//x\ninclude common\nservercmd = /opt/homebrew/bin/unison\n")
    }

    func test_currentCommandNotFound_statusPointsAtTheInstallationsFound_detailsOnlyWhenMore() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\n")
        let remote = Remote(); remote.bareUnisonMissing = true
        let c = make("p", remote: remote)
        _ = await c.runCheck()
        XCTAssertEqual(c.checkStatusForTesting,
                       "The remote shell emitted the start marker; the command line then exited with status 127; stderr: zsh:1: command not found: unison. "
                       + "Choose Another Command lists the installation found on demeter.")
        XCTAssertTrue(c.chooseButtonVisibleForTesting)
        XCTAssertTrue(c.detailsButtonVisibleForTesting, "discovery's command -v observation is one more fact")
        XCTAssertTrue(c.checkReportForTesting.contains("During discovery, command -v unison printed nothing inside sh either."))
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "", "a failed current command proposes nothing by itself")
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison")
        XCTAssertTrue(c.detailsButtonVisibleForTesting)
    }

    func test_checkResult_doesNotWidenTheWindow() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\n")
        let c = make("p", remote: Remote())
        c.window?.setContentSize(NSSize(width: 620, height: 720))
        c.showSectionForTesting(title: "Roots")
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let before = c.window!.frame.width
        _ = await c.runCheck()
        c.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(c.chooseButtonVisibleForTesting && c.detailsButtonVisibleForTesting, "both secondary buttons are showing")
        XCTAssertEqual(c.window!.frame.width, before, "a result must not resize the editor")
    }

    func test_keepCurrentSetting_afterAProposal_restoresTheFormAndTheCurrentResult() async throws {
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\naddversionno = true\n")
        let c = make("p", remote: Remote())
        _ = await c.runCheck()
        await c.chooseCandidate(.candidate("/opt/homebrew/bin/unison"))
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "/opt/homebrew/bin/unison")
        XCTAssertTrue(c.advancedLinesForTesting.contains("addversionno = false"))
        c.restoreCurrentSetting()
        XCTAssertEqual(c.remoteFieldForTesting("servercmd"), "")
        XCTAssertEqual(c.advancedLinesForTesting, ["addversionno = true"])
        XCTAssertEqual(c.checkStatusForTesting, "No change needed.")
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting, "the restored form matches the checked configuration")
        XCTAssertEqual(try read("p.prf"), "root = /a\nroot = ssh://bruno@demeter//x\naddversionno = true\n")
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
        XCTAssertNil(c.checkAlternativesForTesting)
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

    func test_changedAddversionno_checkVerifiesTheCommandSaveWillRun() async throws {
        // Reviewer's case: local true before an include also setting true; the user
        // changes Advanced to false and checks the current command. Save places the
        // changed value after the include, so the check must verify the unversioned
        // command and its token must stay valid through Save.
        try write("p.prf", "root = /a\nroot = ssh://bruno@demeter//x\naddversionno = true\ninclude common\n")
        try write("common.prf", "addversionno = true\n")
        let remote = Remote()
        let c = make("p", remote: remote)
        c.setAdvancedLinesForTesting(c.advancedLinesForTesting.filter { !$0.hasPrefix("addversionno") } + ["addversionno = false"])
        _ = await c.runCheck()
        await c.chooseCandidate(.keepCurrent)
        let verified = remote.remoteCommands.last ?? ""
        XCTAssertTrue(verified.contains("unison -version"), verified)
        XCTAssertFalse(verified.contains("unison-2.54"), verified)
        c.invokeSaveForTesting()
        XCTAssertNil(c.lastAlertForTesting, "the token still describes the saved profile")
        guard case .success(let e) = EffectiveProfile.load(profile: "p", unisonDirectory: dir) else { return XCTFail() }
        XCTAssertEqual(RemoteSettings(profile: e).addversionno, false)
        XCTAssertEqual(try read("p.prf"), "root = /a\nroot = ssh://bruno@demeter//x\ninclude common\n# Overrides common.prf: set here so this value takes effect\naddversionno = false\n")
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
