import XCTest
@testable import unison_ui_mac

/// Phase 1a (issue #24): the pure `ssh -G` parser + transport-ownership
/// classifier. The subprocess runner (`qualify`) is a thin deadline-bounded
/// shell exercised live in the Wiring PR; here we prove the decision logic.
final class SSHTransportQualifierTests: XCTestCase {

    private typealias Q = SSHTransportQualifier
    private typealias Cfg = SSHEffectiveConfig

    // MARK: parse

    func test_parse_directConfig() {
        let out = """
        host demeter
        user bcourbage
        port 22
        controlmaster none
        controlpath none
        proxycommand none
        proxyjump none
        """
        let cfg = Cfg.parse(out)
        XCTAssertEqual(cfg.controlMaster, "none")
        XCTAssertEqual(cfg.controlPath, "none")
        XCTAssertEqual(cfg.proxyCommand, "none")
        XCTAssertEqual(cfg.proxyJump, "none")
    }

    func test_parse_multiplexed() {
        let cfg = Cfg.parse("controlmaster auto\ncontrolpath /tmp/ssh-%r@%h:%p")
        XCTAssertEqual(cfg.controlMaster, "auto")
        XCTAssertEqual(cfg.controlPath, "/tmp/ssh-%r@%h:%p")
    }

    // MARK: classify — supported

    func test_classify_direct_isSupported() {
        let cfg = Cfg(controlMaster: "none", controlPath: "none",
                      proxyCommand: "none", proxyJump: "none")
        XCTAssertEqual(Q.classify(cfg, customSshCmd: false), .supportedDirect)
    }

    func test_classify_emptyValues_isSupported() {
        XCTAssertEqual(Q.classify(Cfg(), customSshCmd: false), .supportedDirect)
    }

    // MARK: classify — unsupported

    func test_classify_controlMaster_unsupported() {
        let cfg = Cfg(controlMaster: "auto")
        XCTAssertFalse(Q.classify(cfg, customSshCmd: false).isSupported)
    }

    func test_classify_controlPath_unsupported() {
        let cfg = Cfg(controlMaster: "none", controlPath: "/tmp/mux")
        XCTAssertFalse(Q.classify(cfg, customSshCmd: false).isSupported)
    }

    func test_classify_proxyCommand_unsupported() {
        XCTAssertFalse(Q.classify(Cfg(proxyCommand: "nc %h %p"), customSshCmd: false).isSupported)
    }

    func test_classify_proxyJump_unsupported() {
        XCTAssertFalse(Q.classify(Cfg(proxyJump: "jump.example.com"), customSshCmd: false).isSupported)
    }

    func test_classify_customSshCmd_unsupported_evenIfConfigDirect() {
        let cfg = Cfg(controlMaster: "none", controlPath: "none",
                      proxyCommand: "none", proxyJump: "none")
        XCTAssertFalse(Q.classify(cfg, customSshCmd: true).isSupported)
    }

    func test_parseThenClassify_directEndToEnd() {
        let out = "controlmaster none\ncontrolpath none\nproxycommand none\nproxyjump none\n"
        XCTAssertEqual(Q.classify(Cfg.parse(out), customSshCmd: false), .supportedDirect)
    }
}
