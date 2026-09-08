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

    private func inputs(servercmd: String = "/opt/homebrew/bin/unison", roots: [String]? = nil) -> F.Inputs {
        F.Inputs(profile: "p", unisonDirectory: dir, roots: roots ?? ["/Users/me/Home", "ssh://bruno@demeter//Users/bruno/Home"],
                 servercmd: servercmd, sshcmd: "/usr/bin/ssh", sshargs: "-i /k",
                 localEngineVersion: "2.54.0 (ocaml 5.5.0)", sessionID: UUID())
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
        XCTAssertEqual(d.menu, [
            .currentEffect("Remote PATH decides which unison runs"),
            .candidate(path: "/opt/homebrew/bin/unison", versionLine: "unison version 2.54.0 (ocaml 5.5.0)",
                       storedTarget: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"),
            .keepCurrent,
        ])
        XCTAssertEqual(d.failureSentences, [])
    }

    func test_discover_failure_yieldsSentences_andNoMenu() async throws {
        let p = try prepared()
        let stub = Stub([.exited(status: 255, stdout: "", stderr: "bruno@demeter: Permission denied (publickey).\n")])
        let d = await F.discover(p, handle: .init(), makeExecutor: factory(stub))
        XCTAssertFalse(d.succeeded)
        XCTAssertEqual(d.menu, [])
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
        XCTAssertEqual(v.headline, "This check found no change to make.")
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
