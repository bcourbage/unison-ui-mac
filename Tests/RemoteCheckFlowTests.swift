import XCTest
@testable import unison_ui_mac

/// The check flow over stubbed sessions: Step 1 failures, the discovery menu,
/// verification outcomes and their sentences, proposals, and the token check.
final class RemoteCheckFlowTests: XCTestCase {
    private typealias F = RemoteCheckFlow
    private var dir: String!
    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rcf-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }
    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }

    /// Returns canned results in order; records the argv it was given.
    private final class Stub: VersionCheck.VersionProbeExecutor, @unchecked Sendable {
        var results: [VersionCheck.RawExecResult]
        var configs: [VersionCheck.ProbeConfig] = []
        let lock = NSLock()
        init(_ results: [VersionCheck.RawExecResult]) { self.results = results }
        func execute(_ config: VersionCheck.ProbeConfig, deadline: TimeInterval, canceller: VersionCheck.ProbeCanceller) -> VersionCheck.RawExecResult {
            lock.lock(); defer { lock.unlock() }
            configs.append(config)
            return results.isEmpty ? .launchFailed("no canned result") : results.removeFirst()
        }
    }
    private func factory(_ stub: Stub) -> F.ExecutorFactory { { _ in stub } }

    private let sessionID = UUID()
    private func inputs(servercmd: String = "/opt/homebrew/bin/unison", roots: [String]? = nil) -> F.Inputs {
        F.Inputs(profile: "p", unisonDirectory: dir, roots: roots ?? ["/Users/me/Home", "ssh://bruno@demeter//Users/bruno/Home"],
                 servercmd: servercmd, sshcmd: "/usr/bin/ssh", sshargs: "-i /k",
                 localEngineVersion: "2.54.0 (ocaml 5.5.0)", sessionID: sessionID)
    }
    private func prepared(_ i: F.Inputs? = nil) throws -> F.Prepared {
        try write("p.prf", "root = /Users/me/Home\nroot = ssh://bruno@demeter//Users/bruno/Home\n")
        switch F.prepare(i ?? inputs()) {
        case .success(let p): return p
        case .failure(let f): XCTFail("\(f)"); throw NSError(domain: "t", code: 1)
        }
    }
    /// Discovery stdout as the remote sh prints it, with the marker the flow will use replaced at parse time.
    private func discoveryStdout(marker: String) -> String {
        """
        \(marker) BEGIN
        uname: Darwin
        path: /opt/homebrew/bin/unison
        link: /Applications/unison-ui-mac.app/Contents/MacOS/cltool
        real: /Applications/unison-ui-mac.app/Contents/MacOS/cltool
        version: unison version 2.54.0 (ocaml 5.5.0)
        absent: /usr/local/bin/unison
        commandv: 
        \(marker) END

        """
    }
    /// The stub cannot know the marker in advance; it echoes back the marker found in the argv it received.
    private final class EchoingDiscoveryStub: VersionCheck.VersionProbeExecutor, @unchecked Sendable {
        let body: (String) -> String
        init(_ body: @escaping (String) -> String) { self.body = body }
        func execute(_ config: VersionCheck.ProbeConfig, deadline: TimeInterval, canceller: VersionCheck.ProbeCanceller) -> VersionCheck.RawExecResult {
            let remote = config.arguments.last ?? ""
            // discovery: "sh -c 'M=<marker>; …" ; verification: "printf '<marker>'; …"
            let marker: String
            if let r = remote.range(of: "M=") { marker = String(remote[r.upperBound...].prefix { $0 != ";" }) }
            else if let r = remote.range(of: "printf '") { marker = String(remote[r.upperBound...].prefix { $0 != "'" }) }
            else { marker = "" }
            return .exited(status: 0, stdout: body(marker), stderr: "")
        }
    }

    // MARK: - prepare

    func test_prepare_composesCommandAndToken() throws {
        let p = try prepared()
        XCTAssertEqual(p.host, "demeter"); XCTAssertEqual(p.user, "bruno")
        XCTAssertEqual(p.command.versionCommandString, "/opt/homebrew/bin/unison -version")
        XCTAssertEqual(p.executable, "/usr/bin/ssh")
        XCTAssertEqual(p.majorVersion, "2.54"); XCTAssertEqual(p.localVersion, "2.54.0")
        XCTAssertTrue(F.tokenStillValid(p))
    }

    func test_prepare_failures() throws {
        guard case .failure(.profile(let missing)) = F.prepare(inputs()) else { return XCTFail() }
        XCTAssertEqual(missing, "Profile p not found (looking for file \(dir!)/p.prf)")
        try write("p.prf", "root = /a\nroot = /b\n")
        guard case .failure(.roots(let m)) = F.prepare(inputs(roots: ["/a"])) else { return XCTFail() }
        XCTAssertTrue(m.hasPrefix("Wrong number of roots"))
        guard case .failure(.notApplicable(.socketRoot)) = F.prepare(inputs(roots: ["/a", "socket://h:1//b"])) else { return XCTFail() }
        guard case .failure(.notApplicable(.noRemoteRoot)) = F.prepare(inputs(roots: ["/a", "/b"])) else { return XCTFail() }
        var i = inputs(); i.sshcmd = "nossh"
        guard case .failure(.shellCommandNotFound(let name, _)) = F.prepare(i, shellExists: { _ in false }) else { return XCTFail() }
        XCTAssertEqual(name, "nossh")
        var j = inputs(); j.localEngineVersion = "unknown"
        guard case .failure(.localVersion) = F.prepare(j) else { return XCTFail() }
    }

    func test_prepare_appliesRootRulesToEffectiveRoots_includingIncludes() throws {
        // Two form roots (one ssh) plus an included ssh root: upstream refuses.
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "root = ssh://other//c\n")
        guard case .failure(.roots(let m)) = F.prepare(inputs(roots: ["/a", "ssh://h//b"])) else { return XCTFail("expected a root-rule failure") }
        XCTAssertEqual(m, "cannot synchronize more than one remote root")
    }

    func test_pendingRoots_replaceTopLevelRootsAtTheirPosition() throws {
        try write("p.prf", "root = /old1\ninclude common\nroot = /old2\n")
        try write("common.prf", "root = /inc\n")
        guard case .success(let e) = EffectiveProfile.load(profile: "p", unisonDirectory: dir) else { return XCTFail() }
        XCTAssertEqual(F.pendingRoots(inputs: inputs(roots: ["/new1", "/new2"]), effective: e), ["/new1", "/new2", "/inc"])
        try write("q.prf", "include common\n")
        guard case .success(let q) = EffectiveProfile.load(profile: "q", unisonDirectory: dir) else { return XCTFail() }
        var i = inputs(roots: ["/n1", "/n2"]); i.profile = "q"
        XCTAssertEqual(F.pendingRoots(inputs: i, effective: q), ["/inc", "/n1", "/n2"], "no top-level roots: form roots go where a save would append them")
    }

    func test_alternatives_groupPathsToOneInstallation_andStateConsequences() throws {
        typealias Cand = RemoteDiscovery.Candidate
        let cltool = "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"
        let record = RemoteDiscovery.Record(complete: true, uname: "Darwin", present: [
            Cand(path: "/opt/homebrew/bin/unison", kind: .symlink(storedTarget: cltool), resolvedPath: cltool, versionLine: "unison version 2.54.0 (ocaml 5.5.0)"),
            Cand(path: "/usr/local/bin/unison", kind: .regular, resolvedPath: "/usr/local/bin/unison", versionLine: "unison version 2.51.5 (ocaml 4.14.0)"),
            Cand(path: cltool, kind: .regular, resolvedPath: cltool, versionLine: "unison version 2.54.0 (ocaml 5.5.0)"),
            Cand(path: "/usr/bin/unison", kind: .directory, resolvedPath: nil, versionLine: nil),
        ], absent: [], commandV: nil)
        // The current setting is the link: it and the program it reaches form one group, listed first.
        let p = try prepared(inputs(servercmd: "/opt/homebrew/bin/unison"))
        XCTAssertEqual(F.alternatives(for: p, record: record), [
            .init(kind: .header, title: "Two paths to the same installation", path: nil, subtitle: ""),
            .init(kind: .keepCurrent, title: "Keep current setting", path: "/opt/homebrew/bin/unison", subtitle: "Currently configured for this profile."),
            .init(kind: .direct, title: "Use this installation directly", path: cltool,
                  subtitle: "Uses the program at this location, even if the link is redirected. Version 2.54.0."),
            .init(kind: .direct, title: "Use this installation directly", path: "/usr/local/bin/unison",
                  subtitle: "Uses the program at this location. Version 2.51.5, cannot connect to this Mac's 2.54.0."),
        ])
        // The current setting is elsewhere: Keep current setting first, the group after.
        let q = try prepared(inputs(servercmd: "/usr/local/bin/unison"))
        let rows = F.alternatives(for: q, record: record)
        XCTAssertEqual(rows.map(\.kind), [.keepCurrent, .header, .link, .direct])
        XCTAssertEqual(rows[2].subtitle, "Uses whichever installation this link points to; now \(cltool). Version 2.54.0.")
        XCTAssertEqual(F.helpText.first, "Which command should I use?")
        XCTAssertEqual(F.helpText.count, 4)
    }

    func test_pendingAddversionno_followsThePendingDocumentsIncludeOrder() throws {
        // Untouched local false before an include setting true: Unison uses true.
        try write("p.prf", "root = /a\nroot = ssh://h//b\naddversionno = false\ninclude common\n")
        try write("common.prf", "addversionno = true\n")
        var i = inputs(); i.addversionnoAdvancedAtLoad = ["false"]; i.addversionnoAdvanced = ["false"]
        guard case .success(let p) = F.prepare(i) else { return XCTFail() }
        XCTAssertTrue(p.settings.addversionno)
        XCTAssertEqual(p.command.versionCommandString, "/opt/homebrew/bin/unison-2.54 -version")
        // The user deletes the sole assignment from Advanced: the include still wins.
        i.addversionnoAdvanced = []
        guard case .success(let q) = F.prepare(i) else { return XCTFail() }
        XCTAssertTrue(q.settings.addversionno)
        // Without the include, deleting the assignment restores the default false.
        try write("common.prf", "sshargs = -i /k\n")
        guard case .success(let r) = F.prepare(i) else { return XCTFail() }
        XCTAssertFalse(r.settings.addversionno)
        XCTAssertEqual(r.command.versionCommandString, "/opt/homebrew/bin/unison -version")
        // Local assignment after the include (Advanced writes at that position): local wins.
        try write("q.prf", "root = /a\nroot = ssh://h//b\ninclude common2\naddversionno = false\n")
        try write("common2.prf", "addversionno = true\n")
        var j = inputs(); j.profile = "q"; j.addversionnoAdvancedAtLoad = ["false"]; j.addversionnoAdvanced = ["false"]
        guard case .success(let s) = F.prepare(j) else { return XCTFail() }
        XCTAssertFalse(s.settings.addversionno)
    }

    func test_pendingAddversionno_changedAssignmentWinsOverTheInclude_asSavePlacesIt() throws {
        // Local true before an include also setting true; the user changes Advanced
        // to false. Save places the changed value after the include, so the check
        // must verify the unversioned command.
        try write("p.prf", "root = /a\nroot = ssh://h//b\naddversionno = true\ninclude common\n")
        try write("common.prf", "addversionno = true\n")
        var i = inputs(); i.addversionnoAdvancedAtLoad = ["true"]; i.addversionnoAdvanced = ["false"]
        guard case .success(let p) = F.prepare(i) else { return XCTFail() }
        XCTAssertFalse(p.settings.addversionno)
        XCTAssertEqual(p.command.versionCommandString, "/opt/homebrew/bin/unison -version")
        // The same lines untouched: the include's true stands.
        i.addversionnoAdvanced = ["true"]
        guard case .success(let q) = F.prepare(i) else { return XCTFail() }
        XCTAssertTrue(q.settings.addversionno)
        // Deleting the assignment is a change, but with no value to place the include wins.
        i.addversionnoAdvanced = []
        guard case .success(let r) = F.prepare(i) else { return XCTFail() }
        XCTAssertTrue(r.settings.addversionno)
    }

    func test_tokenStillValid_isFalse_whenTheCurrentFormDiffers() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\n")
        guard case .success(let p) = F.prepare(inputs()) else { return XCTFail() }
        XCTAssertTrue(F.tokenStillValid(p, current: inputs()))
        var changed = inputs(); changed.addversionnoAdvanced = ["true"]
        XCTAssertFalse(F.tokenStillValid(p, current: changed), "an Advanced edit to addversionno changes the pending configuration")
    }

    func test_tokenStillValid_isFalse_afterAnIncludeChanges() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "sshargs = -i /k\n")
        guard case .success(let p) = F.prepare(inputs()) else { return XCTFail() }
        XCTAssertTrue(F.tokenStillValid(p))
        try write("common.prf", "sshargs = -i /other\n")
        XCTAssertFalse(F.tokenStillValid(p))
    }

    // MARK: - discover

    func test_discover_buildsMenu_withCurrentEffectWhenFieldEmpty() async throws {
        let p = try prepared(inputs(servercmd: ""))
        let text = discoveryStdout(marker: "")
        let stub = EchoingDiscoveryStub { m in text.replacingOccurrences(of: " BEGIN", with: "\(m) BEGIN").replacingOccurrences(of: " END", with: "\(m) END") }
        let d = await F.discover(p, handle: .init(), makeExecutor: { _ in stub })
        XCTAssertTrue(d.succeeded)
        XCTAssertEqual(d.rows, [
            .init(kind: .keepCurrent, title: "Keep current setting", path: nil,
                  subtitle: "No command is set for this profile; the remote PATH decides which unison runs."),
            .init(kind: .link, title: "Use the command link", path: "/opt/homebrew/bin/unison",
                  subtitle: "Uses whichever installation this link points to; now /Applications/unison-ui-mac.app/Contents/MacOS/cltool. Version 2.54.0."),
        ])
        XCTAssertEqual(d.failureSentences, [])
    }

    func test_discover_failure_yieldsSentences_andNoMenu() async throws {
        let p = try prepared()
        let stub = Stub([.exited(status: 255, stdout: "", stderr: "bruno@demeter: Permission denied (publickey).\n")])
        let d = await F.discover(p, handle: .init(), makeExecutor: factory(stub))
        XCTAssertFalse(d.succeeded)
        XCTAssertEqual(d.rows, [])
        XCTAssertEqual(d.failureSentences.first, "No start marker was received before ssh exited (status 255, bruno@demeter: Permission denied (publickey).).")
        XCTAssertEqual(d.failureSentences.last, RemoteCheckWording.closingAfterFailure)
        // The discovery argv is the check's vector with the sh script last.
        XCTAssertEqual(stub.configs.first?.arguments.prefix(6).map { $0 }, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes"])
        XCTAssertTrue(stub.configs.first?.arguments.last?.hasPrefix("sh -c '") ?? false)
    }

    // MARK: - verify

    private func verifiedStub(version: String = "2.54.0 (ocaml 5.5.0)") -> EchoingDiscoveryStub {
        EchoingDiscoveryStub { marker in "\(marker)unison version \(version)\n" }
    }

    func test_verify_keepCurrent_compatible_noChangeHeadline() async throws {
        let p = try prepared()
        let record = RemoteDiscovery.parse(stdout: discoveryStdout(marker: "X"), marker: "X")
        let stub = verifiedStub()
        let v = await F.verify(p, selection: .keepCurrent, discovery: record, handle: .init(), makeExecutor: { _ in stub })
        XCTAssertEqual(v.verdict, .verified(version: "2.54.0", firstLine: "unison version 2.54.0 (ocaml 5.5.0)"))
        XCTAssertEqual(v.headline, "No change needed.")
        XCTAssertEqual(v.closing, "Only a synchronization confirms the server protocol; run the profile to test that.")
        XCTAssertNil(v.proposal); XCTAssertEqual(v.compatible, true)
        XCTAssertEqual(v.details, [
            "ssh connected to demeter as bruno without prompting.",
            "/opt/homebrew/bin/unison on demeter is a symlink whose stored target is /Applications/unison-ui-mac.app/Contents/MacOS/cltool.",
            "Fully resolved by the remote: /Applications/unison-ui-mac.app/Contents/MacOS/cltool.",
            "/opt/homebrew/bin/unison -version printed unison version 2.54.0 (ocaml 5.5.0).",
            "2.54.0 (this Mac) and 2.54.0 (demeter) are on the same side of the 2.52 boundary.",
            "A plain sh on demeter found no unison on its PATH through command -v; the login shell and Unison's ssh command may resolve differently.",
        ])
        XCTAssertFalse(v.details.joined().contains("inside a unison-ui-mac.app bundle"), "no identity sentence")
    }

    func test_verify_candidate_compatible_proposes() async throws {
        let p = try prepared(inputs(servercmd: ""))
        let stub = verifiedStub()
        let v = await F.verify(p, selection: .candidate("/opt/homebrew/bin/unison"), discovery: nil, handle: .init(), makeExecutor: { _ in stub })
        XCTAssertEqual(v.headline, "The command you selected started over ssh and reported its version.")
        XCTAssertEqual(v.proposal, .init(servercmd: "/opt/homebrew/bin/unison", setsAddversionnoFalse: false))
        XCTAssertTrue(v.details.contains("This profile does not set servercmd, so the remote machine's PATH decides which unison runs; the check cannot see that PATH."))
    }

    func test_verify_incompatibleVersion_isNotNothingToChange_andNoProposal() async throws {
        let p = try prepared()
        let stub = verifiedStub(version: "2.51.5")
        let v = await F.verify(p, selection: .candidate("/opt/homebrew/bin/unison"), discovery: nil, handle: .init(), makeExecutor: { _ in stub })
        XCTAssertEqual(v.compatible, false)
        XCTAssertNil(v.proposal)
        XCTAssertEqual(v.headline, "The command started over ssh and reported version 2.51.5. 2.51.5 (demeter) and 2.54.0 (this Mac) are on opposite sides of the 2.52 boundary and cannot connect.")
        XCTAssertFalse(v.headline.contains("no change"))
    }

    func test_verify_failure_splitsHeadlineDetailsClosing() async throws {
        let p = try prepared()
        let record = RemoteDiscovery.Record(complete: true, uname: "Darwin", present: [], absent: ["/opt/homebrew/bin/unison"], commandV: "")
        let stub = EchoingDiscoveryStub { marker in marker }   // marker then nothing; exit 0 → not a version line
        let v0 = await F.verify(p, selection: .keepCurrent, discovery: record, handle: .init(), makeExecutor: { _ in stub })
        XCTAssertEqual(v0.verdict, .notVerified)
        XCTAssertTrue(v0.headline.hasPrefix("The remote shell emitted the start marker; the command line printed nothing"))
        XCTAssertEqual(v0.closing, RemoteCheckWording.closingAfterFailure)
        XCTAssertFalse(v0.details.contains(RemoteCheckWording.closingAfterFailure))
    }

    func test_verify_unsafeCandidate_isRefusedWithoutASession() async throws {
        let p = try prepared()
        let stub = Stub([])   // any session would hit "no canned result"
        let v = await F.verify(p, selection: .candidate("/Volumes/My Disk/unison"), discovery: nil, handle: .init(), makeExecutor: factory(stub))
        XCTAssertEqual(v.proposalRefusal, .unsafeCharacters([" "]))
        XCTAssertTrue(stub.configs.isEmpty, "no ssh session ran")
        XCTAssertTrue(v.headline.contains("characters the check does not propose"))
    }
}
