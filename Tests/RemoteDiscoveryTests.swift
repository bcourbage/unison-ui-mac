import XCTest
@testable import unison_ui_mac

final class RemoteDiscoveryTests: XCTestCase {
    private typealias D = RemoteDiscovery

    // Recorded from Demeter on 2026-09-07 with the discovery script.
    private static let demeterStdout = """
    UUM BEGIN
    uname: Darwin
    path: /opt/homebrew/bin/unison
    link: /Applications/unison-ui-mac.app/Contents/MacOS/cltool
    real: /Applications/unison-ui-mac.app/Contents/MacOS/cltool
    version: unison version 2.54.0 (ocaml 5.5.0)
    absent: /usr/local/bin/unison
    path: /Applications/unison-ui-mac.app/Contents/MacOS/cltool
    kind: regular
    real: /Applications/unison-ui-mac.app/Contents/MacOS/cltool
    version: unison version 2.54.0 (ocaml 5.5.0)
    absent: /usr/bin/unison
    commandv: 
    UUM END

    """

    func test_plan_absoluteSafeExecutable_isProbedFirst_withoutDuplicates() {
        let p = D.plan(effectiveExecutable: "/usr/local/bin/unison")
        XCTAssertEqual(p.candidatePaths, ["/usr/local/bin/unison", "/opt/homebrew/bin/unison",
                                          "/Applications/unison-ui-mac.app/Contents/SharedSupport/bin/unison",
                                          "/Applications/unison-ui-mac.app/Contents/MacOS/cltool", "/usr/bin/unison"])
        XCTAssertNil(p.unprobedExecutable)
        let q = D.plan(effectiveExecutable: "/srv/bin/unison-2.54")
        XCTAssertEqual(q.candidatePaths.first, "/srv/bin/unison-2.54")
        XCTAssertEqual(q.candidatePaths.count, 6)
    }

    func test_plan_bareName_isNotProbed() {
        let p = D.plan(effectiveExecutable: "unison")
        XCTAssertEqual(p.candidatePaths, D.wellKnownCandidates)
        XCTAssertEqual(p.unprobedExecutable, .bareName("unison"))
    }

    func test_plan_unsafePath_isNotProbed() {
        let p = D.plan(effectiveExecutable: "/Volumes/My Disk/unison")
        XCTAssertEqual(p.candidatePaths, D.wellKnownCandidates)
        XCTAssertEqual(p.unprobedExecutable, .unsafePath("/Volumes/My Disk/unison"))
    }

    func test_remoteCommand_isSingleQuotedShScript_withoutInnerQuotes() {
        let cmd = D.remoteCommand(marker: "UUM-1", plan: D.plan(effectiveExecutable: "unison"))
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.hasSuffix("'"))
        let inner = cmd.dropFirst("sh -c '".count).dropLast()
        XCTAssertFalse(inner.contains("'"), "the script must not contain a single quote")
        XCTAssertTrue(inner.contains("M=UUM-1"))
        XCTAssertTrue(inner.contains("for p in /opt/homebrew/bin/unison /usr/local/bin/unison /Applications/unison-ui-mac.app/Contents/SharedSupport/bin/unison /Applications/unison-ui-mac.app/Contents/MacOS/cltool /usr/bin/unison; do"))
        XCTAssertTrue(inner.contains("command -v unison"))
        // The only redirections are to /dev/null or stderr-to-stdout merges.
        let redirections = inner.replacingOccurrences(of: ">/dev/null", with: "").replacingOccurrences(of: "2>&1", with: "")
        XCTAssertFalse(redirections.contains(">"), "nothing is written on the remote: \(inner)")
        XCTAssertFalse(inner.contains("do;"), "no stray separator after do")
    }

    func test_remoteCommand_runsUnderLocalSh_andParsesBack() throws {
        // The script itself, executed by the local /bin/sh as a stand-in for
        // the remote shell, against a temp directory of candidates.
        let dir = NSTemporaryDirectory() + "RemoteDiscoveryTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = dir + "/real-unison"
        try "#!/bin/sh\necho unison version 2.53.5 \\(ocaml 4.14.1\\)\n".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real)
        let link = dir + "/unison"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "real-unison")
        let plan = D.Plan(candidatePaths: [link, real, dir + "/absent"], unprobedExecutable: nil)
        let cmd = D.remoteCommand(marker: "UUM-t", plan: plan)
        let raw = VersionCheck.SubprocessProbeExecutor().execute(
            VersionCheck.ProbeConfig(executable: "/bin/sh", arguments: ["-c", cmd], host: "local"),
            deadline: 10, canceller: VersionCheck.ProbeCanceller())
        guard case .exited(let status, let stdout, let stderr) = raw else { return XCTFail("\(raw)") }
        XCTAssertEqual(status, 0, stderr)
        let r = D.parse(stdout: stdout, marker: "UUM-t")
        XCTAssertTrue(r.complete)
        XCTAssertEqual(r.uname, "Darwin")
        XCTAssertEqual(r.candidate(at: link)?.kind, .symlink(storedTarget: "real-unison"))
        XCTAssertEqual(r.candidate(at: link)?.versionLine, "unison version 2.53.5 (ocaml 4.14.1)")
        XCTAssertEqual(r.candidate(at: real)?.kind, .regular)
        // realpath(3), not NSString.resolvingSymlinksInPath, which strips /private.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let expectedReal = realpath(real, &buf).map { String(cString: $0) }
        XCTAssertEqual(r.candidate(at: real)?.resolvedPath, expectedReal)
        XCTAssertEqual(r.absent, [dir + "/absent"])
        XCTAssertNotNil(r.commandV)
    }

    func test_parse_demeterRecord() {
        let r = D.parse(stdout: Self.demeterStdout, marker: "UUM")
        XCTAssertTrue(r.complete)
        XCTAssertEqual(r.uname, "Darwin")
        XCTAssertEqual(r.present.count, 2)
        XCTAssertEqual(r.present[0], .init(path: "/opt/homebrew/bin/unison",
                                           kind: .symlink(storedTarget: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"),
                                           resolvedPath: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool",
                                           versionLine: "unison version 2.54.0 (ocaml 5.5.0)"))
        XCTAssertEqual(r.present[1].kind, .regular)
        XCTAssertEqual(r.absent, ["/usr/local/bin/unison", "/usr/bin/unison"])
        XCTAssertEqual(r.commandV, "")
        XCTAssertTrue(r.wasAbsent("/usr/bin/unison"))
        XCTAssertFalse(r.wasAbsent("/opt/homebrew/bin/unison"))
    }

    func test_parse_ignoresBannerOutsideMarkers_andCRLF() {
        let s = "Welcome to the box\r\nUUM BEGIN\r\nuname: Linux\r\nabsent: /usr/bin/unison\r\ncommandv: /usr/local/bin/unison\r\nUUM END\r\ntrailing noise\r\n"
        let r = D.parse(stdout: s, marker: "UUM")
        XCTAssertTrue(r.complete)
        XCTAssertEqual(r.uname, "Linux")
        XCTAssertEqual(r.absent, ["/usr/bin/unison"])
        XCTAssertEqual(r.commandV, "/usr/local/bin/unison")
    }

    func test_parse_incompleteRecord_isMarkedIncomplete() {
        let r = D.parse(stdout: "UUM BEGIN\nuname: Darwin\npath: /usr/bin/unison\nkind: regular\n", marker: "UUM")
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.present.first?.path, "/usr/bin/unison")
        XCTAssertNil(r.commandV)
        XCTAssertEqual(D.parse(stdout: "", marker: "UUM"), .init(complete: false, uname: nil, present: [], absent: [], commandV: nil))
    }

    func test_pathIdentity_byPathTextOnly() {
        XCTAssertEqual(D.PathIdentity.classify("/Applications/unison-ui-mac.app/Contents/MacOS/cltool"), .unisonUIMacBundle)
        XCTAssertEqual(D.PathIdentity.classify("/opt/homebrew/Cellar/unison/2.53.7/bin/unison"), .homebrewCellar)
        XCTAssertEqual(D.PathIdentity.classify("/Applications/Unison.app/Contents/MacOS/cltool"), .upstreamUnisonApp)
        XCTAssertEqual(D.PathIdentity.classify("/usr/local/bin/unison"), .unknown)
    }
}
