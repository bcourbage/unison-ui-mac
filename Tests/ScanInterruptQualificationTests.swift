import XCTest
@testable import unison_ui_mac

/// Phase 1a (issue #24, Wiring PR): the pure profile→qualification-plan mapping.
/// Decides — from `.prf` text alone — whether an in-flight scan is even a
/// CANDIDATE for in-process interruption, and how to run the `ssh -G` probe.
/// The subprocess probe + classifier are tested in `SSHTransportQualifierTests`.
final class ScanInterruptQualificationTests: XCTestCase {

    private typealias Q = ScanInterruptQualification

    // MARK: - Not a candidate (skip, never probe)

    func test_localOnlyProfile_isSkip() {
        let prf = "root = /Users/me/Documents\nroot = /Volumes/Backup/Documents\n"
        guard case .skip = Q.plan(profileText: prf) else {
            return XCTFail("local↔local must skip")
        }
    }

    func test_socketProfile_isSkip() {
        let prf = "root = /Users/me/data\nroot = socket://server.example.com:9999//data\n"
        guard case .skip = Q.plan(profileText: prf) else {
            return XCTFail("socket:// has no ssh child to signal → skip")
        }
    }

    func test_emptyProfile_isSkip() {
        guard case .skip = Q.plan(profileText: "") else { return XCTFail("no root → skip") }
    }

    // MARK: - Candidate (qualify)

    func test_sshRoot_isQualify_withHostFromRoot() {
        let prf = "root = /Users/me/data\nroot = ssh://bruno@demeter.local//data\n"
        guard case .qualify(let host, let extraArgs, let custom) = Q.plan(profileText: prf) else {
            return XCTFail("ssh:// root must qualify")
        }
        XCTAssertEqual(host, "bruno@demeter.local")
        XCTAssertTrue(extraArgs.isEmpty)
        XCTAssertFalse(custom)
    }

    func test_sshRoot_noUser_hostOnly() {
        let prf = "root = /d\nroot = ssh://demeter.local//data\n"
        guard case .qualify(let host, _, _) = Q.plan(profileText: prf) else {
            return XCTFail()
        }
        XCTAssertEqual(host, "demeter.local")
    }

    func test_sshArgs_arePassedThrough() {
        // -i <key> etc. must reach `ssh -G` so it resolves the same effective
        // config the real sync uses.
        let prf = """
        root = /d
        root = ssh://bruno@demeter.local//data
        sshargs = -i /Users/bruno/.ssh/demeter -o BatchMode=yes
        """
        guard case .qualify(_, let extraArgs, _) = Q.plan(profileText: prf) else {
            return XCTFail()
        }
        XCTAssertEqual(extraArgs, ["-i", "/Users/bruno/.ssh/demeter", "-o", "BatchMode=yes"])
    }

    func test_absoluteSshCmd_marksCustom() {
        // An absolute custom ssh binary means we are not driving /usr/bin/ssh →
        // the qualifier will refuse (customSshCmd = true).
        let prf = """
        root = /d
        root = ssh://demeter.local//data
        sshcmd = /opt/homebrew/bin/ssh
        """
        guard case .qualify(_, _, let custom) = Q.plan(profileText: prf) else {
            return XCTFail()
        }
        XCTAssertTrue(custom)
    }

    func test_bareSshCmd_isNotCustom() {
        // A non-absolute sshcmd falls back to /usr/bin/ssh in both the real
        // connection and the probe, so it is NOT treated as custom.
        let prf = """
        root = /d
        root = ssh://demeter.local//data
        sshcmd = ssh
        """
        guard case .qualify(_, _, let custom) = Q.plan(profileText: prf) else {
            return XCTFail()
        }
        XCTAssertFalse(custom)
    }

    func test_firstSshRootWins_whenMultiple() {
        let prf = """
        root = ssh://first.example.com//a
        root = ssh://second.example.com//b
        """
        guard case .qualify(let host, _, _) = Q.plan(profileText: prf) else {
            return XCTFail()
        }
        XCTAssertEqual(host, "first.example.com")
    }
}
