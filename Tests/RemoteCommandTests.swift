import XCTest
@testable import unison_ui_mac

/// Root parsing (`src/clroot.ml`), the root rules (`globals.ml`,
/// `uicommon.ml`), the remote command (`remote.ml` `buildShellConnection`)
/// and `servercmd` proposal composition, against upstream v2.54.0.
final class RemoteCommandTests: XCTestCase {

    // MARK: - UnisonRoot.parse

    func test_parse_localPaths() throws {
        XCTAssertEqual(try UnisonRoot.parse("/Users/me/Sync"), .local("/Users/me/Sync"))
        XCTAssertEqual(try UnisonRoot.parse("  relative/dir "), .local("relative/dir"))
        XCTAssertEqual(try UnisonRoot.parse("//host/share/dir"), .local("//host/share/dir"))
        XCTAssertEqual(try UnisonRoot.parse("file://host/share/dir"), .local("//host/share/dir"))
        XCTAssertEqual(try UnisonRoot.parse("file:///abs/dir"), .local("abs/dir"))
    }

    func test_parse_sshForms() throws {
        XCTAssertEqual(try UnisonRoot.parse("ssh://alice@example.com//srv/data"),
                       .shell(shell: "ssh", host: "example.com", user: "alice", port: nil, path: "/srv/data"))
        XCTAssertEqual(try UnisonRoot.parse("ssh://example.com/relative/path"),
                       .shell(shell: "ssh", host: "example.com", user: nil, port: nil, path: "relative/path"))
        XCTAssertEqual(try UnisonRoot.parse("ssh://demeter:2222/"),
                       .shell(shell: "ssh", host: "demeter", user: nil, port: "2222", path: nil))
        XCTAssertEqual(try UnisonRoot.parse("ssh://demeter"),
                       .shell(shell: "ssh", host: "demeter", user: nil, port: nil, path: nil))
        // The user class contains `@`: the greedy match ends at the last `@`.
        XCTAssertEqual(try UnisonRoot.parse("ssh://a@b@host/p"),
                       .shell(shell: "ssh", host: "host", user: "a@b", port: nil, path: "p"))
        XCTAssertEqual(try UnisonRoot.parse("ssh://[fe80::1%25en0]:22/p"),
                       .shell(shell: "ssh", host: "fe80::1%25en0", user: nil, port: "22", path: "p"))
    }

    func test_parse_socketForms() throws {
        XCTAssertEqual(try UnisonRoot.parse("socket://host:5000/p"), .socket(host: "host", port: "5000", path: "p"))
        XCTAssertEqual(try UnisonRoot.parse("socket://{/tmp/unison.sock}/p"),
                       .socket(host: "{/tmp/unison.sock}", port: "", path: "p"))
    }

    func test_parse_errors_useUpstreamWording() {
        func message(_ s: String) -> String? {
            do { _ = try UnisonRoot.parse(s); return nil } catch let e as UnisonRoot.ParseError { return e.message } catch { return nil }
        }
        XCTAssertEqual(message("ssh:///x"), "\"ssh:///x\": missing host")
        XCTAssertEqual(message("socket://host/p"), "\"socket://host/p\": ill-formed (must give a port number with socket)")
        XCTAssertEqual(message("socket://u@host:1/p"), "\"socket://u@host:1/p\": ill-formed (cannot use a user with socket)")
        XCTAssertEqual(message("file://host:1/p"), "\"file://host:1/p\": ill-formed (cannot use a port number with file)")
        XCTAssertEqual(message("ssh:host/p"), "ill-formed root specification \"ssh:host/p\" (ssh: must be followed by //)")
        XCTAssertEqual(message("ssh://host^/p"), "ill-formed root specification ssh://host^/p")
        XCTAssertEqual(message("rsh://host/p"),
                       "protocol rsh has been deprecated, use ssh instead (optionally specifying a different sshcmd preference)")
        XCTAssertEqual(message("unison://host/p"), "protocol unison has been deprecated, use file, ssh, or socket instead")
        XCTAssertEqual(message("ftp://host/p"), "\"ftp://host/p\": unrecognized protocol ftp")
        // Not a URI at all: a local path that happens to contain a colon.
        XCTAssertEqual(try? UnisonRoot.parse("c:/dir"), .local("c:/dir"))
    }

    // MARK: - RootRules

    private let ssh1 = "ssh://demeter//Users/me/Sync"
    private let ssh2 = "ssh://other//srv"
    private let sock = "socket://demeter:5000//srv"

    func test_rootRules_oneRoot_wrongNumber() {
        XCTAssertEqual(RootRules.evaluate(roots: ["/a"]),
            .failure(.fatal("Wrong number of roots: 2 expected, but 1 provided (/a)\n"
                            + "(Maybe you specified roots both on the command line and in the profile?)")))
    }

    func test_rootRules_threeLocalRoots_wrongNumber() {
        XCTAssertEqual(RootRules.evaluate(roots: ["/a", "/b", "/c"]),
            .failure(.fatal("Wrong number of roots: 2 expected, but 3 provided (/a, /b, /c)\n"
                            + "(Maybe you specified roots both on the command line and in the profile?)")))
    }

    func test_rootRules_noRoots_wrongNumber() {
        XCTAssertEqual(RootRules.evaluate(roots: []),
            .failure(.fatal("Wrong number of roots: 2 expected, but 0 provided ()\n"
                            + "(Maybe you specified roots both on the command line and in the profile?)")))
    }

    func test_rootRules_twoSshRoots_moreThanOneRemote() {
        XCTAssertEqual(RootRules.evaluate(roots: [ssh1, ssh2]),
                       .failure(.fatal("cannot synchronize more than one remote root")))
    }

    func test_rootRules_sshAndSocket_moreThanOneRemote() {
        XCTAssertEqual(RootRules.evaluate(roots: [ssh1, sock]),
                       .failure(.fatal("cannot synchronize more than one remote root")))
    }

    func test_rootRules_threeRootsTwoRemote_remoteCountIsCheckedFirst() {
        XCTAssertEqual(RootRules.evaluate(roots: ["/a", ssh1, sock]),
                       .failure(.fatal("cannot synchronize more than one remote root")))
    }

    func test_rootRules_socketAndLocal_notApplicable() {
        XCTAssertEqual(RootRules.evaluate(roots: ["/a", sock]), .success(.notApplicable(.socketRoot)))
    }

    func test_rootRules_twoLocal_notApplicable() {
        XCTAssertEqual(RootRules.evaluate(roots: ["/a", "file://host/b"]), .success(.notApplicable(.noRemoteRoot)))
    }

    func test_rootRules_sshAndLocal_applies_inEitherOrder() {
        let expected = RootRules.Outcome.ssh(
            remote: .shell(shell: "ssh", host: "demeter", user: nil, port: nil, path: "/Users/me/Sync"),
            local: .local("/a"))
        XCTAssertEqual(RootRules.evaluate(roots: ["/a", ssh1]), .success(expected))
        XCTAssertEqual(RootRules.evaluate(roots: [ssh1, "/a"]), .success(expected))
    }

    func test_rootRules_parseFailure_carriesUicommonPrefix() {
        XCTAssertEqual(RootRules.evaluate(roots: ["/a", "ssh:///x"]),
                       .failure(.fatal("There's a problem with one of the roots:\n\"ssh:///x\": missing host")))
    }

    // MARK: - RemoteCommand.compose

    private let plainRoot = UnisonRoot.shell(shell: "ssh", host: "demeter", user: nil, port: nil, path: "/x")
    private let fullRoot = UnisonRoot.shell(shell: "ssh", host: "demeter", user: "alice", port: "2222", path: "/x")

    private func compose(_ settings: RemoteSettings, root: UnisonRoot? = nil) -> RemoteCommand {
        RemoteCommand.compose(settings: settings, root: root ?? plainRoot, majorVersion: "2.54")!
    }

    func test_compose_defaults() {
        let c = compose(RemoteSettings())
        XCTAssertEqual(c.shellCommand, "ssh")
        XCTAssertEqual(c.upstreamArguments, ["demeter", "-e", "none", "unison", "-server", "__new-rpc-mode"])
        XCTAssertEqual(c.remoteCommandString, "unison -server __new-rpc-mode")
        XCTAssertEqual(c.versionCommandString, "unison -version")
    }

    func test_compose_servercmdSet() {
        let c = compose(RemoteSettings(servercmd: "/opt/homebrew/bin/unison"))
        XCTAssertEqual(c.remoteCommandString, "/opt/homebrew/bin/unison -server __new-rpc-mode")
        XCTAssertEqual(c.versionCommandString, "/opt/homebrew/bin/unison -version")
    }

    func test_compose_addversionno_appendsMajor() {
        XCTAssertEqual(compose(RemoteSettings(addversionno: true)).remoteCommandString,
                       "unison-2.54 -server __new-rpc-mode")
        XCTAssertEqual(compose(RemoteSettings(servercmd: "/usr/local/bin/unison", addversionno: true)).versionCommandString,
                       "/usr/local/bin/unison-2.54 -version")
    }

    func test_compose_escapedSpace_reachesRemoteShellUnescaped() {
        let c = compose(RemoteSettings(servercmd: "/Volumes/My\\ Disk/unison"))
        XCTAssertEqual(c.remoteCommandWords, ["/Volumes/My Disk/unison", "-server", "__new-rpc-mode"])
        XCTAssertEqual(c.remoteCommandString, "/Volumes/My Disk/unison -server __new-rpc-mode")
    }

    func test_compose_quotedValue_isSplitAtSpaces_andRejoined() {
        let c = compose(RemoteSettings(servercmd: "\"/Volumes/My Disk\"/unison"))
        XCTAssertEqual(c.remoteCommandWords, ["\"/Volumes/My", "Disk\"/unison", "-server", "__new-rpc-mode"])
        XCTAssertEqual(c.remoteCommandString, "\"/Volumes/My Disk\"/unison -server __new-rpc-mode")
    }

    func test_compose_userPortAndSshargs_inUpstreamOrder() {
        let c = compose(RemoteSettings(servercmd: "/opt/homebrew/bin/unison",
                                       sshcmd: "/usr/bin/ssh",
                                       sshargs: "-i /Users/me/.ssh/Demeter  -o ServerAliveInterval=30"),
                        root: fullRoot)
        XCTAssertEqual(c.shellCommand, "/usr/bin/ssh")
        XCTAssertEqual(c.upstreamArguments, [
            "-l", "alice", "-p", "2222", "demeter", "-e", "none",
            "-i", "/Users/me/.ssh/Demeter", "-o", "ServerAliveInterval=30",
            "/opt/homebrew/bin/unison", "-server", "__new-rpc-mode",
        ])
        XCTAssertEqual(c.sshargsWords, ["-i", "/Users/me/.ssh/Demeter", "-o", "ServerAliveInterval=30"])
    }

    func test_compose_nonSshRoot_isNil() {
        XCTAssertNil(RemoteCommand.compose(settings: RemoteSettings(), root: .local("/a"), majorVersion: "2.54"))
        XCTAssertNil(RemoteCommand.compose(settings: RemoteSettings(),
                                           root: .socket(host: "h", port: "1", path: nil), majorVersion: "2.54"))
    }

    func test_checkArguments_matchTheDesignSpecification() {
        let c = compose(RemoteSettings(sshargs: "-i /k"), root: fullRoot)
        XCTAssertEqual(c.checkArguments(connectTimeout: 5, remoteCommand: "printf 'M'; /opt/homebrew/bin/unison -version"), [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
            "-l", "alice", "-p", "2222", "demeter", "-e", "none", "-i", "/k",
            "printf 'M'; /opt/homebrew/bin/unison -version",
        ])
        let plain = compose(RemoteSettings())
        XCTAssertEqual(plain.checkArguments(connectTimeout: 5, remoteCommand: "unison -version"), [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
            "demeter", "-e", "none", "unison -version",
        ])
    }

    func test_settingsFromEffectiveProfile() throws {
        let dir = NSTemporaryDirectory() + "RemoteCommandTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "servercmd = /a\ninclude common\naddversionno = true\n".write(toFile: dir + "/p.prf", atomically: true, encoding: .utf8)
        try "servercmd = /b\nsshargs = -i /k\n".write(toFile: dir + "/common.prf", atomically: true, encoding: .utf8)
        guard case .success(let p) = EffectiveProfile.load(profile: "p", unisonDirectory: dir) else { return XCTFail() }
        XCTAssertEqual(RemoteSettings(profile: p),
                       RemoteSettings(servercmd: "/b", sshcmd: "ssh", sshargs: "-i /k", addversionno: true))
    }

    func test_majorVersion() {
        XCTAssertEqual(RemoteCommand.majorVersion(fromEngineVersion: "2.54.0 (ocaml 5.5.0)"), "2.54")
        XCTAssertEqual(RemoteCommand.majorVersion(fromEngineVersion: "2.53.7"), "2.53")
        XCTAssertNil(RemoteCommand.majorVersion(fromEngineVersion: "unknown"))
        XCTAssertNil(RemoteCommand.majorVersion(fromEngineVersion: "2"))
    }

    // MARK: - ServercmdProposal

    func test_proposal_addversionnoFalse_usesPathAsIs() {
        XCTAssertEqual(ServercmdProposal.compose(selectedPath: "/opt/homebrew/bin/unison", addversionno: false, majorVersion: "2.54"),
                       .success(.init(servercmd: "/opt/homebrew/bin/unison", setsAddversionnoFalse: false)))
    }

    func test_proposal_addversionnoTrue_stripsMatchingSuffix() {
        XCTAssertEqual(ServercmdProposal.compose(selectedPath: "/usr/local/bin/unison-2.54", addversionno: true, majorVersion: "2.54"),
                       .success(.init(servercmd: "/usr/local/bin/unison", setsAddversionnoFalse: false)))
    }

    func test_proposal_addversionnoTrue_withoutSuffix_setsItFalse() {
        XCTAssertEqual(ServercmdProposal.compose(selectedPath: "/opt/homebrew/bin/unison", addversionno: true, majorVersion: "2.54"),
                       .success(.init(servercmd: "/opt/homebrew/bin/unison", setsAddversionnoFalse: true)))
    }

    func test_proposal_unsafeCharacters_produceNoProposal() {
        XCTAssertEqual(ServercmdProposal.compose(selectedPath: "/Applications/My Apps/unison", addversionno: false, majorVersion: "2.54"),
                       .failure(.unsafeCharacters([" "])))
        XCTAssertEqual(ServercmdProposal.compose(selectedPath: "/a/b$c'd$", addversionno: true, majorVersion: "2.54"),
                       .failure(.unsafeCharacters(["$", "'"])))
        XCTAssertEqual(ServercmdProposal.compose(selectedPath: "/a/é", addversionno: false, majorVersion: "2.54"),
                       .failure(.unsafeCharacters(["é"])))
    }

    func test_proposal_relativePath_isRefused() {
        XCTAssertEqual(ServercmdProposal.compose(selectedPath: "unison", addversionno: false, majorVersion: "2.54"),
                       .failure(.notAbsolute))
    }

    func test_proposal_safeSet() {
        for s in "ABCxyz019._/+-".unicodeScalars { XCTAssertTrue(ServercmdProposal.isSafe(s), String(s)) }
        for s in " \t~$'\";&|<>*?()[]{}=:,@!#%^`é".unicodeScalars { XCTAssertFalse(ServercmdProposal.isSafe(s), String(s)) }
    }
}
