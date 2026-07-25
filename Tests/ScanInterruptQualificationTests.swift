import XCTest
@testable import unison_ui_mac

/// Phase 1a (issue #24, Wiring PR): the pure profile→qualification-plan mapping
/// and the connection-bound qualification cache. The subprocess probe +
/// classifier are tested in `SSHTransportQualifierTests`.
final class ScanInterruptQualificationTests: XCTestCase {

    private typealias Q = ScanInterruptQualification

    // MARK: - Not a candidate (skip, never probe)

    func test_localOnlyProfile_isSkip() {
        let prf = "root = /Users/me/Documents\nroot = /Volumes/Backup/Documents\n"
        guard case .skip = Q.plan(profileText: prf) else { return XCTFail("local↔local must skip") }
    }

    func test_socketProfile_isSkip() {
        let prf = "root = /Users/me/data\nroot = socket://server.example.com:9999//data\n"
        guard case .skip = Q.plan(profileText: prf) else { return XCTFail("socket:// → skip") }
    }

    func test_emptyProfile_isSkip() {
        guard case .skip = Q.plan(profileText: "") else { return XCTFail("no root → skip") }
    }

    // MARK: - Candidate (qualify)

    func test_sshRoot_isQualify_withHostFromRoot() {
        let prf = "root = /Users/me/data\nroot = ssh://bruno@demeter.local//data\n"
        guard case .qualify(let host, let extraArgs) = Q.plan(profileText: prf) else {
            return XCTFail("ssh:// root must qualify")
        }
        XCTAssertEqual(host, "bruno@demeter.local")
        XCTAssertTrue(extraArgs.isEmpty)
    }

    func test_sshRoot_noUser_hostOnly() {
        let prf = "root = /d\nroot = ssh://demeter.local//data\n"
        guard case .qualify(let host, _) = Q.plan(profileText: prf) else { return XCTFail() }
        XCTAssertEqual(host, "demeter.local")
    }

    func test_sshArgs_arePassedThrough() {
        let prf = """
        root = /d
        root = ssh://bruno@demeter.local//data
        sshargs = -i /Users/bruno/.ssh/demeter -o BatchMode=yes
        """
        guard case .qualify(_, let extraArgs) = Q.plan(profileText: prf) else { return XCTFail() }
        XCTAssertEqual(extraArgs, ["-i", "/Users/bruno/.ssh/demeter", "-o", "BatchMode=yes"])
    }

    func test_systemSshCmd_exact_isQualified() {
        let prf = """
        root = /d
        root = ssh://demeter.local//data
        sshcmd = /usr/bin/ssh
        """
        guard case .qualify = Q.plan(profileText: prf) else {
            return XCTFail("exact /usr/bin/ssh is the system OpenSSH → qualify")
        }
    }

    // MARK: - Blocker 4 / Finding 2: fail closed on ambiguity/unproven command

    func test_multipleSshRoots_isSkip_notFirstWins() {
        let prf = "root = ssh://first.example.com//a\nroot = ssh://second.example.com//b\n"
        guard case .skip(let reason) = Q.plan(profileText: prf) else {
            return XCTFail("multiple ssh roots must skip")
        }
        XCTAssertTrue(reason.lowercased().contains("ambiguous"))
    }

    func test_includeDirective_isSkip() {
        let prf = "include common\nroot = /d\nroot = ssh://demeter.local//data\n"
        guard case .skip = Q.plan(profileText: prf) else { return XCTFail("include must fail closed") }
    }

    func test_sourceDirective_isSkip() {
        let prf = "source /etc/unison/base.prf\nroot = /d\nroot = ssh://demeter.local//data\n"
        guard case .skip = Q.plan(profileText: prf) else { return XCTFail("source must fail closed") }
    }

    func test_absoluteNonSystemSshCmd_isSkip() {
        // Upstream runs the configured sshcmd DIRECTLY — a custom binary is NOT
        // /usr/bin/ssh, so qualifying via OpenSSH would describe the wrong
        // transport. Fail closed.
        let prf = "root = /d\nroot = ssh://demeter.local//data\nsshcmd = /opt/homebrew/bin/ssh\n"
        guard case .skip = Q.plan(profileText: prf) else {
            return XCTFail("custom absolute sshcmd must fail closed")
        }
    }

    func test_bareSshCmd_isSkip() {
        // A bare wrapper (`plink`, a shell shim) is executed as-is, not
        // /usr/bin/ssh. Fail closed (was previously mis-qualified as system ssh).
        let prf = "root = /d\nroot = ssh://demeter.local//data\nsshcmd = plink\n"
        guard case .skip = Q.plan(profileText: prf) else {
            return XCTFail("bare sshcmd must fail closed")
        }
    }

    func test_duplicateSshCmd_isSkip() {
        let prf = """
        root = /d
        root = ssh://demeter.local//data
        sshcmd = /usr/bin/ssh
        sshcmd = /usr/bin/ssh
        """
        guard case .skip(let reason) = Q.plan(profileText: prf) else {
            return XCTFail("duplicate sshcmd must fail closed")
        }
        XCTAssertTrue(reason.lowercased().contains("duplicate"))
    }

    func test_duplicateSshArgs_isSkip() {
        let prf = """
        root = /d
        root = ssh://demeter.local//data
        sshargs = -i /a
        sshargs = -i /b
        """
        guard case .skip(let reason) = Q.plan(profileText: prf) else {
            return XCTFail("duplicate sshargs must fail closed")
        }
        XCTAssertTrue(reason.lowercased().contains("duplicate"))
    }

    // MARK: - Port carried to ssh -G

    func test_port_isCarriedAsExplicitPortArg() {
        let prf = "root = /d\nroot = ssh://bruno@demeter.local:2222//data\n"
        guard case .qualify(let host, let extraArgs) = Q.plan(profileText: prf) else { return XCTFail() }
        XCTAssertEqual(host, "bruno@demeter.local")   // host arg carries no port
        XCTAssertEqual(Array(extraArgs.prefix(2)), ["-p", "2222"])
    }

    func test_port_andSshArgs_bothPresent_portFirst() {
        let prf = """
        root = /d
        root = ssh://demeter.local:2222//data
        sshargs = -i /Users/b/.ssh/k
        """
        guard case .qualify(_, let extraArgs) = Q.plan(profileText: prf) else { return XCTFail() }
        XCTAssertEqual(extraArgs, ["-p", "2222", "-i", "/Users/b/.ssh/k"])
    }
}

/// Connection-bound qualification cache (round 2 Finding 3): a verdict never
/// outlives the connection generation that produced it, and a stale probe
/// cannot overwrite a newer one.
final class ScanInterruptQualCacheTests: XCTestCase {

    private typealias SID = EngineSessionCoordinator.SessionID
    private let s = EngineSessionCoordinator.SessionID(raw: 1)

    func test_appliedResult_forCurrentGeneration_isSupported() {
        var c = ScanInterruptQualCache()
        c.beginGeneration(session: s, generation: 10)
        XCTAssertTrue(c.apply(session: s, generation: 10, .supportedDirect))
        XCTAssertTrue(c.supported(session: s))
    }

    func test_newGeneration_invalidatesVerdict_untilRequalified() {
        var c = ScanInterruptQualCache()
        c.beginGeneration(session: s, generation: 10)
        c.apply(session: s, generation: 10, .supportedDirect)
        XCTAssertTrue(c.supported(session: s))
        // Rescan → a new connection generation: the old verdict is invalidated
        // (interruption must NOT be offered against the new transport yet).
        c.beginGeneration(session: s, generation: 11)
        XCTAssertFalse(c.supported(session: s))
    }

    func test_staleGenerationResult_isDropped() {
        var c = ScanInterruptQualCache()
        c.beginGeneration(session: s, generation: 11)   // current gen is 11
        // A late probe from the OLD generation 10 must not apply.
        XCTAssertFalse(c.apply(session: s, generation: 10, .supportedDirect))
        XCTAssertFalse(c.supported(session: s))
    }

    func test_olderProbeCannotOverwriteNewer() {
        var c = ScanInterruptQualCache()
        c.beginGeneration(session: s, generation: 11)
        c.apply(session: s, generation: 11, .supportedDirect)   // newer says supported
        // Older gen-10 result arrives late saying unsupported → dropped.
        XCTAssertFalse(c.apply(session: s, generation: 10, .unsupported(reason: "stale")))
        XCTAssertTrue(c.supported(session: s), "newer verdict must survive")
    }

    func test_clear_dropsVerdictAndGeneration() {
        var c = ScanInterruptQualCache()
        c.beginGeneration(session: s, generation: 10)
        c.apply(session: s, generation: 10, .supportedDirect)
        c.clear(session: s)
        XCTAssertFalse(c.supported(session: s))
        // After clear, even the same generation number cannot re-apply.
        XCTAssertFalse(c.apply(session: s, generation: 10, .supportedDirect))
    }
}
