import XCTest
@testable import unison_ui_mac

/// The exact executable and argument vector the guided remote check hands to
/// the executor, for both of its sessions (discovery and verification). The
/// vector is pinned at the executor boundary so the code that composes it can
/// change shape without changing what ssh is asked to run.
final class RemoteCheckArgvBaselineTests: XCTestCase {
    private typealias F = RemoteCheckFlow
    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rca-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }

    private final class Recorder: VersionCheck.VersionProbeExecutor, @unchecked Sendable {
        let lock = NSLock()
        private var _configs: [VersionCheck.ProbeConfig] = []
        var configs: [VersionCheck.ProbeConfig] { lock.lock(); defer { lock.unlock() }; return _configs }
        func execute(_ config: VersionCheck.ProbeConfig, deadline: TimeInterval,
                     canceller: VersionCheck.ProbeCanceller) -> VersionCheck.RawExecResult {
            lock.lock(); _configs.append(config); lock.unlock()
            return .launchFailed("recorded only")
        }
    }

    private struct Case {
        let name: String
        let remoteRoot: String
        let servercmd: String
        let sshargs: String
        let addversionno: Bool
        /// Everything before the remote command string.
        let argvBeforeRemote: [String]
        /// The remote command's version part, the tail of the verification session's command.
        let versionCommand: String
        /// The first entry of the discovery script's candidate list: the
        /// configured executable when it is an absolute safe path, otherwise
        /// the first well-known path (a bare name is reported as unprobed).
        let discoveryFirstCandidate: String
    }

    /// The quoted `sshargs` case pins upstream's behavior as ported: words split
    /// on whitespace and quote characters stay in the words.
    private let fixedPrefix = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes"]

    private var cases: [Case] {
        [
            Case(name: "user, port, quoted sshargs, addversionno",
                 remoteRoot: "ssh://bruno@demeter:2222//Users/bruno/Home",
                 servercmd: "/opt/homebrew/bin/unison", sshargs: "-i '/Users/me/my key' -o Foo=bar", addversionno: true,
                 argvBeforeRemote: fixedPrefix + ["-l", "bruno", "-p", "2222", "demeter", "-e", "none",
                                                  "-i", "'/Users/me/my", "key'", "-o", "Foo=bar"],
                 versionCommand: "/opt/homebrew/bin/unison-2.54 -version",
                 discoveryFirstCandidate: "/opt/homebrew/bin/unison-2.54"),
            Case(name: "default remote settings, explicit ssh executable",
                 remoteRoot: "ssh://demeter//Users/bruno/Home",
                 servercmd: "", sshargs: "", addversionno: false,
                 argvBeforeRemote: fixedPrefix + ["demeter", "-e", "none"],
                 versionCommand: "unison -version",
                 discoveryFirstCandidate: RemoteDiscovery.wellKnownCandidates[0]),
            Case(name: "multi-word servercmd",
                 remoteRoot: "ssh://bruno@demeter//Users/bruno/Home",
                 servercmd: "sudo -u unison /opt/unison/bin/unison", sshargs: "-i /k", addversionno: false,
                 argvBeforeRemote: fixedPrefix + ["-l", "bruno", "demeter", "-e", "none", "-i", "/k"],
                 versionCommand: "sudo -u unison /opt/unison/bin/unison -version",
                 discoveryFirstCandidate: RemoteDiscovery.wellKnownCandidates[0]),
        ]
    }

    private func prepared(_ c: Case) throws -> F.Prepared {
        try "root = /Users/me/Home\nroot = \(c.remoteRoot)\n"
            .write(toFile: "\(dir!)/p.prf", atomically: true, encoding: .utf8)
        var inputs = F.Inputs(profile: "p", unisonDirectory: dir,
                              roots: ["/Users/me/Home", c.remoteRoot],
                              servercmd: c.servercmd, sshcmd: "/usr/bin/ssh", sshargs: c.sshargs,
                              localEngineVersion: "2.54.0 (ocaml 5.5.0)", sessionID: UUID())
        // The form's Advanced `addversionno` line, changed since load.
        if c.addversionno { inputs.addversionnoAdvanced = ["true"] }
        switch F.prepare(inputs) {
        case .success(let p): return p
        case .failure(let f): XCTFail("\(c.name): \(f)"); throw NSError(domain: "t", code: 1)
        }
    }

    func test_discoverySession_executableAndArgv() async throws {
        for c in cases {
            let rec = Recorder()
            _ = await F.discover(try prepared(c), handle: .init(), makeExecutor: { _ in rec })
            let cfg = try XCTUnwrap(rec.configs.first, c.name)
            XCTAssertEqual(rec.configs.count, 1, c.name)
            XCTAssertEqual(cfg.executable, "/usr/bin/ssh", c.name)
            XCTAssertEqual(Array(cfg.arguments.dropLast()), c.argvBeforeRemote, c.name)
            let script = try XCTUnwrap(cfg.arguments.last, c.name)
            XCTAssertTrue(script.hasPrefix("sh -c '"), c.name)
            // The configured executable (or, for a bare name, its absence) shows
            // in the candidate list; the marker varies, this fragment does not.
            XCTAssertTrue(script.contains("; for p in \(c.discoveryFirstCandidate) "), "\(c.name): \(script)")
            XCTAssertTrue(script.contains("seen=\" \(c.discoveryFirstCandidate) "), "\(c.name): \(script)")
        }
    }

    func test_verificationSession_executableAndArgv() async throws {
        for c in cases {
            let rec = Recorder()
            _ = await F.verify(try prepared(c), selection: .keepCurrent, discovery: nil,
                               handle: .init(), makeExecutor: { _ in rec })
            let cfg = try XCTUnwrap(rec.configs.first, c.name)
            XCTAssertEqual(rec.configs.count, 1, c.name)
            XCTAssertEqual(cfg.executable, "/usr/bin/ssh", c.name)
            XCTAssertEqual(Array(cfg.arguments.dropLast()), c.argvBeforeRemote, c.name)
            let remote = try XCTUnwrap(cfg.arguments.last, c.name)
            XCTAssertTrue(remote.hasPrefix("printf '"), "\(c.name): \(remote)")
            XCTAssertTrue(remote.hasSuffix("'; " + c.versionCommand), "\(c.name): \(remote)")
        }
    }

    func test_verificationSession_candidateSelection_usesTheProposedServercmd() async throws {
        let c = cases[0]
        let rec = Recorder()
        _ = await F.verify(try prepared(c), selection: .candidate("/usr/local/bin/unison-2.54"), discovery: nil,
                           handle: .init(), makeExecutor: { _ in rec })
        let cfg = try XCTUnwrap(rec.configs.first)
        XCTAssertEqual(Array(cfg.arguments.dropLast()), c.argvBeforeRemote)
        XCTAssertTrue(cfg.arguments.last?.hasSuffix("'; /usr/local/bin/unison-2.54 -version") ?? false, "\(cfg.arguments.last ?? "")")
    }
}
