import XCTest
@testable import unison_ui_mac

final class RemoteCheckOfferPolicyTests: XCTestCase {
    private var dir: String!
    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rcop-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }
    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }

    func test_offers_onlyForConnectFailures_withAnSshRoot() {
        XCTAssertTrue(RemoteCheckOfferPolicy.offers(failedWhileConnecting: true, roots: ["/a", "ssh://h//b"]))
        XCTAssertFalse(RemoteCheckOfferPolicy.offers(failedWhileConnecting: false, roots: ["/a", "ssh://h//b"]), "a scan or sync failure says nothing about the remote command")
        XCTAssertFalse(RemoteCheckOfferPolicy.offers(failedWhileConnecting: true, roots: ["/a", "/b"]), "a local-only profile has no remote command")
        XCTAssertFalse(RemoteCheckOfferPolicy.offers(failedWhileConnecting: true, roots: []))
        XCTAssertFalse(RemoteCheckOfferPolicy.offers(failedWhileConnecting: true, roots: ["ssh:/broken"]), "an unparsable root is not an ssh root")
    }

    func test_roots_comeFromTheEffectiveProfile_includesIncluded() throws {
        try write("p.prf", "root = /a\ninclude common\n")
        try write("common.prf", "root = ssh://h//b\n")
        XCTAssertEqual(RemoteCheckOfferPolicy.roots(profile: "p", unisonDirectory: dir), ["/a", "ssh://h//b"])
        try write("q.prf", "root = /a\nbogus line\n")
        XCTAssertEqual(RemoteCheckOfferPolicy.roots(profile: "q", unisonDirectory: dir), [], "a profile Unison rejects offers nothing")
        XCTAssertEqual(RemoteCheckOfferPolicy.roots(profile: "missing", unisonDirectory: dir), [])
    }

    func test_route_reusesSameProfile_blocksOther_opensWhenNone() {
        XCTAssertEqual(RemoteCheckOfferPolicy.route(openEditorProfile: nil, target: "p"), .openNew)
        XCTAssertEqual(RemoteCheckOfferPolicy.route(openEditorProfile: "p", target: "p"), .reuseOpen)
        XCTAssertEqual(RemoteCheckOfferPolicy.route(openEditorProfile: "other", target: "p"), .blockedBy("other"))
    }
}
