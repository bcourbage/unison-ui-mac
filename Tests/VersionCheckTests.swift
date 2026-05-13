import XCTest
@testable import unison_ui_mac

/// Pure-function coverage for `VersionCheck`. We can't easily test the
/// SSH subprocess from XCTest (it'd require a reachable SSH endpoint),
/// so the tests focus on the deterministic pieces:
///   - SSH URL parsing — every shape we expect to see in a .prf
///   - Version-string parsing — both upstream's `unison -version`
///     output AND the bridge's `unison_bridge_get_version()` format
///   - Suppression persistence — round-trip through an isolated
///     UserDefaults suite so we don't pollute the real domain
final class VersionCheckTests: XCTestCase {

    // MARK: - SSHRoot.parse

    func test_sshRoot_userAtHostAbsolutePath() {
        let r = VersionCheck.SSHRoot.parse("ssh://alice@example.com//srv/data")
        XCTAssertEqual(r, .init(user: "alice", host: "example.com", port: nil))
    }

    func test_sshRoot_hostOnly_relativePath() {
        let r = VersionCheck.SSHRoot.parse("ssh://example.com/relative/path")
        XCTAssertEqual(r, .init(user: nil, host: "example.com", port: nil))
    }

    func test_sshRoot_userAtHostPort() {
        let r = VersionCheck.SSHRoot.parse("ssh://alice@example.com:2222//srv")
        XCTAssertEqual(r, .init(user: "alice", host: "example.com", port: 2222))
    }

    func test_sshRoot_userAtIPv4() {
        let r = VersionCheck.SSHRoot.parse("ssh://bob@192.168.1.10//data")
        XCTAssertEqual(r, .init(user: "bob", host: "192.168.1.10", port: nil))
    }

    func test_sshRoot_noPath_isStillValid() {
        // `ssh://host` with no path — unusual but parseable.
        let r = VersionCheck.SSHRoot.parse("ssh://example.com")
        XCTAssertEqual(r, .init(user: nil, host: "example.com", port: nil))
    }

    func test_sshRoot_trailingPort_butPathNumeric_doesntMisparse() {
        // The port detection looks for the LAST `:` in authority — the
        // path part is excluded from authority by the first `/`. So a
        // path like `/22/foo` doesn't get interpreted as port 22.
        let r = VersionCheck.SSHRoot.parse("ssh://example.com/22/foo")
        XCTAssertEqual(r, .init(user: nil, host: "example.com", port: nil))
    }

    func test_sshRoot_nonSSHRoot_returnsNil() {
        XCTAssertNil(VersionCheck.SSHRoot.parse("/Users/me/Documents"))
        XCTAssertNil(VersionCheck.SSHRoot.parse("socket://host:1234//srv"))
        XCTAssertNil(VersionCheck.SSHRoot.parse("file:///path"))
        XCTAssertNil(VersionCheck.SSHRoot.parse(""))
    }

    func test_sshRoot_whitespaceTrimmed() {
        let r = VersionCheck.SSHRoot.parse("  ssh://alice@host//data  ")
        XCTAssertEqual(r, .init(user: "alice", host: "host", port: nil))
    }

    // MARK: - parseVersionString

    func test_parseVersion_upstreamCliFormat() {
        // What `unison -version` prints on stdout.
        XCTAssertEqual(
            VersionCheck.parseVersionString("unison version 2.54.0 (ocaml 4.14.3)"),
            "2.54.0"
        )
    }

    func test_parseVersion_bridgeFormat() {
        // What `unison_bridge_get_version()` returns. Pure version
        // prefix, OCaml suffix.
        XCTAssertEqual(
            VersionCheck.parseVersionString("2.54.0 (ocaml 5.4.1)"),
            "2.54.0"
        )
    }

    func test_parseVersion_twoComponentForm() {
        // Some upstream releases (and dev branches) print only X.Y.
        XCTAssertEqual(VersionCheck.parseVersionString("unison version 2.51"), "2.51")
    }

    func test_parseVersion_extractsFirstMatch() {
        // If the string mentions multiple version-like substrings,
        // the FIRST match wins — matches both the bridge format
        // (version → ocaml) and the cli format (unison version → ocaml).
        let cli = "unison version 2.54.0 (ocaml 4.14.3)"
        XCTAssertEqual(VersionCheck.parseVersionString(cli), "2.54.0")
    }

    func test_parseVersion_noMatch_returnsNil() {
        XCTAssertNil(VersionCheck.parseVersionString("could not connect"))
        XCTAssertNil(VersionCheck.parseVersionString(""))
        XCTAssertNil(VersionCheck.parseVersionString("ocaml version"))
        // "ocaml 5.4.1" alone (no Unison context) is NOT a real
        // unison-version output — but our parser is loose enough
        // that it'd extract "5.4.1". That's a false positive; we
        // accept it because the alternative (require "unison" prefix)
        // would reject the bridge's "2.54.0 (ocaml ...)" format too.
        // Documented; not currently fixed.
    }

    // MARK: - Suppression

    func test_suppression_roundTrip() {
        let suite = "VersionCheckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Initially not suppressed.
        XCTAssertFalse(VersionCheck.Suppression.isSuppressed(
            host: "h1", local: "2.54.0", remote: "2.54.3", defaults: defaults
        ))

        VersionCheck.Suppression.suppress(
            host: "h1", local: "2.54.0", remote: "2.54.3", defaults: defaults
        )

        // Now suppressed for that exact triple.
        XCTAssertTrue(VersionCheck.Suppression.isSuppressed(
            host: "h1", local: "2.54.0", remote: "2.54.3", defaults: defaults
        ))

        // But NOT for a different host…
        XCTAssertFalse(VersionCheck.Suppression.isSuppressed(
            host: "h2", local: "2.54.0", remote: "2.54.3", defaults: defaults
        ))

        // …nor for different versions (user upgraded one side; we
        // re-prompt so they confirm again).
        XCTAssertFalse(VersionCheck.Suppression.isSuppressed(
            host: "h1", local: "2.54.1", remote: "2.54.3", defaults: defaults
        ))
        XCTAssertFalse(VersionCheck.Suppression.isSuppressed(
            host: "h1", local: "2.54.0", remote: "2.54.4", defaults: defaults
        ))
    }

    func test_suppression_isIdempotent() {
        let suite = "VersionCheckTests-idemp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Calling suppress() twice for the same triple shouldn't
        // create duplicate entries in the persisted array.
        VersionCheck.Suppression.suppress(
            host: "h", local: "a", remote: "b", defaults: defaults
        )
        VersionCheck.Suppression.suppress(
            host: "h", local: "a", remote: "b", defaults: defaults
        )
        let stored = defaults.stringArray(forKey: VersionCheck.Suppression.key) ?? []
        XCTAssertEqual(stored.count, 1)
    }

    func test_suppression_token_usesPipeSeparator() {
        // Token shape is part of the on-disk contract. Defensive test
        // so we notice if a refactor changes the field separator
        // (which would silently invalidate every user's existing
        // suppressions).
        let t = VersionCheck.Suppression.token(
            host: "example.com", local: "2.54.0", remote: "2.54.3"
        )
        XCTAssertEqual(t, "example.com|2.54.0|2.54.3")
    }

    // MARK: - runSync — end-to-end without subprocess

    func test_runSync_localOnlyProfile_returnsNoRemoteRoot() throws {
        // Write a temp profile with only local roots; runSync should
        // bail without spawning ssh.
        let tmp = NSTemporaryDirectory() as NSString
        let dir = tmp.appendingPathComponent("vc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let prfPath = (dir as NSString).appendingPathComponent("p.prf")
        try """
            root = /tmp/a
            root = /tmp/b
            """.write(toFile: prfPath, atomically: true, encoding: .utf8)

        let outcome = VersionCheck.runSync(
            profile: "p",
            unisonDirectory: dir,
            localBridgeVersion: "2.54.0 (ocaml 5.4.1)"
        )
        XCTAssertEqual(outcome, .noRemoteRoot)
    }

    func test_runSync_missingProfile_returnsProbeFailed() throws {
        let tmp = NSTemporaryDirectory() as NSString
        let dir = tmp.appendingPathComponent("vc-missing-\(UUID().uuidString)")
        // Don't create the directory — the .prf can't be read.
        let outcome = VersionCheck.runSync(
            profile: "ghost",
            unisonDirectory: dir,
            localBridgeVersion: "2.54.0"
        )
        switch outcome {
        case .probeFailed: break  // expected
        default: XCTFail("expected probeFailed, got \(outcome)")
        }
    }
}
