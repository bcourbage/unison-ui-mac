import XCTest
@testable import unison_ui_mac

/// Resolution dependencies (present and absent lookup paths) and the
/// configuration token built over them and the form values.
final class RemoteCheckTokenTests: XCTestCase {
    private var dir: String!
    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rct-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(atPath: dir) } }
    private func write(_ name: String, _ text: String) throws { try text.write(toFile: "\(dir!)/\(name)", atomically: true, encoding: .utf8) }
    private func effective(_ p: String = "p") throws -> EffectiveProfile {
        switch EffectiveProfile.load(profile: p, unisonDirectory: dir) {
        case .success(let e): return e
        case .failure(let err): XCTFail(err.message); throw err
        }
    }
    private let form = RemoteCheckToken.FormValues(roots: ["/a", "ssh://h//b"], servercmd: "", sshcmd: "ssh", sshargs: "", addversionno: false)
    private let session = UUID()
    private func token() throws -> RemoteCheckToken { RemoteCheckToken.make(form: form, effective: try effective(), sessionID: session) }

    // MARK: - dependencies

    func test_dependencies_recordExactCandidate_prfFile_andAbsentOptional() throws {
        try write("p.prf", "include common\ninclude? extra\nsource? notes.txt\n")
        try write("common.prf", "root = /a\nroot = /b\n")
        let e = try effective()
        let deps = Dictionary(uniqueKeysWithValues: e.dependencies.map { ($0.path, $0.present) })
        XCTAssertEqual(deps["\(dir!)/p"], false, "exact-name candidate for the top-level profile, absent")
        XCTAssertEqual(deps["\(dir!)/p.prf"], true)
        XCTAssertEqual(deps["\(dir!)/common"], false, "exact-name candidate probed first")
        XCTAssertEqual(deps["\(dir!)/common.prf"], true)
        XCTAssertEqual(deps["\(dir!)/extra"], false)
        XCTAssertEqual(deps["\(dir!)/extra.prf"], false, "optional include's .prf form, absent")
        XCTAssertEqual(deps["\(dir!)/notes.txt"], false, "optional source, absent")
    }

    // MARK: - token

    func test_token_isStable_forUnchangedConfiguration() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "servercmd = /x\n")
        XCTAssertEqual(try token(), try token())
    }

    func test_token_changes_whenAFormValueChanges() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\n")
        let a = try token()
        var f2 = form; f2.roots = ["/a", "ssh://other//b"]
        XCTAssertNotEqual(a, RemoteCheckToken.make(form: f2, effective: try effective(), sessionID: session))
        var f3 = form; f3.sshargs = "-i /k"
        XCTAssertNotEqual(a, RemoteCheckToken.make(form: f3, effective: try effective(), sessionID: session))
        XCTAssertNotEqual(a, RemoteCheckToken.make(form: form, effective: try effective(), sessionID: UUID()), "another editor session")
    }

    func test_token_changes_whenAnIncludedFileChanges() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "servercmd = /x\n")
        let a = try token()
        try write("common.prf", "servercmd = /y\n")
        XCTAssertNotEqual(a, try token())
    }

    func test_token_changes_whenAnAbsentOptionalIncludeAppears() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude? extra\n")
        let a = try token()
        try write("extra.prf", "sshargs = -i /k\n")
        XCTAssertNotEqual(a, try token())
    }

    func test_token_changes_whenExactNameCandidateAppearsBesideUnchangedPrf() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\ninclude common\n")
        try write("common.prf", "servercmd = /x\n")
        let a = try token()
        try write("common", "servercmd = /shadow\n")   // exact name now exists and takes precedence
        XCTAssertNotEqual(a, try token())
    }

    func test_token_unreadablePresentDependency_isItsOwnState() throws {
        try write("p.prf", "root = /a\nroot = ssh://h//b\n")
        let e = try effective()
        let readable = RemoteCheckToken.make(form: form, effective: e, sessionID: session)
        let unreadable = RemoteCheckToken.make(form: form, effective: e, sessionID: session) { _ in nil }
        XCTAssertNotEqual(readable, unreadable)
    }
}
