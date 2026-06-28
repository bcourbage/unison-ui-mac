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

    // MARK: - tokenizeSSHArgs

    func test_tokenizeSSHArgs_nil_isEmpty() {
        XCTAssertEqual(VersionCheck.tokenizeSSHArgs(nil), [])
    }

    func test_tokenizeSSHArgs_blank_isEmpty() {
        XCTAssertEqual(VersionCheck.tokenizeSSHArgs("   "), [])
    }

    func test_tokenizeSSHArgs_typicalKeyAndOptions() {
        // The real Sync-Home-Demeter sshargs shape.
        let args = VersionCheck.tokenizeSSHArgs(
            "-i /Users/bcourbage/.ssh/Demeter -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new")
        XCTAssertEqual(args, [
            "-i", "/Users/bcourbage/.ssh/Demeter",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new",
        ])
    }

    func test_tokenizeSSHArgs_collapsesRunsOfWhitespaceAndTabs() {
        XCTAssertEqual(VersionCheck.tokenizeSSHArgs("-i\t/key   -p  2222"),
                       ["-i", "/key", "-p", "2222"])
    }

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

    // MARK: - parseSemver

    func test_parseSemver_threeComponent() {
        let s = VersionCheck.parseSemver("2.54.0")
        XCTAssertEqual(s?.major, 2)
        XCTAssertEqual(s?.minor, 54)
        XCTAssertEqual(s?.patch, 0)
    }

    func test_parseSemver_twoComponentDefaultsPatchZero() {
        let s = VersionCheck.parseSemver("2.51")
        XCTAssertEqual(s?.major, 2)
        XCTAssertEqual(s?.minor, 51)
        XCTAssertEqual(s?.patch, 0)
    }

    func test_parseSemver_largePatchAndMinor() {
        let s = VersionCheck.parseSemver("2.40.102")
        XCTAssertEqual(s?.major, 2)
        XCTAssertEqual(s?.minor, 40)
        XCTAssertEqual(s?.patch, 102)
    }

    func test_parseSemver_rejectsSingleComponent() {
        XCTAssertNil(VersionCheck.parseSemver("2"))
    }

    func test_parseSemver_rejectsNonNumeric() {
        XCTAssertNil(VersionCheck.parseSemver("foo.bar"))
        XCTAssertNil(VersionCheck.parseSemver(""))
        XCTAssertNil(VersionCheck.parseSemver("2.x"))
    }

    func test_parseSemver_extraComponentIgnored() {
        // We only care about major.minor.patch. Anything trailing
        // (rare in Unison's versioning, but defensively handled) is
        // dropped silently. Don't claim this in the docstring as a
        // feature — it's the natural fall-out of split(by: ".")
        // followed by indexed access.
        let s = VersionCheck.parseSemver("2.54.0.1")
        XCTAssertEqual(s?.major, 2)
        XCTAssertEqual(s?.minor, 54)
        XCTAssertEqual(s?.patch, 0)
    }

    // MARK: - isPre252 boundary

    func test_isPre252_trueForOldProtocolReleases() {
        // Concrete historical releases that used the old wire
        // protocol. Pulled from upstream's tag history.
        XCTAssertTrue(VersionCheck.isPre252("2.40.102"))
        XCTAssertTrue(VersionCheck.isPre252("2.48.4"))
        XCTAssertTrue(VersionCheck.isPre252("2.51.0"))
        XCTAssertTrue(VersionCheck.isPre252("2.51.5"))
        // Two-component variants seen in older `-version` output.
        XCTAssertTrue(VersionCheck.isPre252("2.51"))
    }

    func test_isPre252_falseAtBoundary() {
        // 2.52.0 is the first new-protocol release — NOT pre-2.52.
        XCTAssertFalse(VersionCheck.isPre252("2.52.0"))
        XCTAssertFalse(VersionCheck.isPre252("2.52"))
    }

    func test_isPre252_falseForNewProtocolReleases() {
        XCTAssertFalse(VersionCheck.isPre252("2.52.1"))
        XCTAssertFalse(VersionCheck.isPre252("2.53.0"))
        XCTAssertFalse(VersionCheck.isPre252("2.53.8"))
        XCTAssertFalse(VersionCheck.isPre252("2.54.0"))
    }

    func test_isPre252_defensiveOnUnparseable() {
        // Garbage input: we err on the side of "new protocol" so
        // we don't false-positive an incompatibility alert.
        XCTAssertFalse(VersionCheck.isPre252(""))
        XCTAssertFalse(VersionCheck.isPre252("not a version"))
        XCTAssertFalse(VersionCheck.isPre252("foo"))
    }

    func test_isPre252_majorVersionsBeyondTwo() {
        // Pre-1.0 hypothetical: definitely pre-2.52.
        XCTAssertTrue(VersionCheck.isPre252("0.9.0"))
        XCTAssertTrue(VersionCheck.isPre252("1.0.0"))
        // Hypothetical future 3.x: not pre-2.52.
        XCTAssertFalse(VersionCheck.isPre252("3.0.0"))
        XCTAssertFalse(VersionCheck.isPre252("10.0.0"))
    }

    // MARK: - Compatibility classification — known versions
    //
    // These tests pin the practical behavior end-users will see. The
    // version pairs come from realistic deployment scenarios:
    //   - The bridge always reports 2.54.0 (what we vendor at v0.1.x).
    //   - Remote sides are whatever the user happens to have on the
    //     remote (varies — Homebrew, distro packages, hand-built).
    //
    // Wire-protocol compatibility rule: anything >=2.52.0 ↔
    // anything >=2.52.0 negotiates fine via feature negotiation in
    // the new wire protocol. Anything straddling the 2.52 boundary
    // fails. Same-side-of-boundary mismatches are NOT a user-visible
    // warning anymore.

    func test_classify_exactMatch_currentRelease() {
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "2.54.0"),
            .exactMatch
        )
    }

    // --- Known-compatible (no user alert) ---

    func test_classify_compatible_2_53_8_to_2_54_0() {
        // Realistic deployment scenario: a user on 2.53.8 syncing
        // with a 2.54.0-embedded UI. Both new-protocol, so the
        // classifier should treat them as compatible.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "2.53.8"),
            .compatibleNewProtocol(local: "2.54.0", remote: "2.53.8")
        )
    }

    func test_classify_compatible_minorAhead() {
        // Hypothetical 2.55.0 upstream (after we ship); the new
        // wire protocol should still negotiate features.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "2.55.0"),
            .compatibleNewProtocol(local: "2.54.0", remote: "2.55.0")
        )
    }

    func test_classify_compatible_2_52_0_to_2_54_0() {
        // 2.52.0 — first new-protocol release. Bare minimum to
        // talk to a 2.54.0 client.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "2.52.0"),
            .compatibleNewProtocol(local: "2.54.0", remote: "2.52.0")
        )
    }

    func test_classify_compatible_patchVersionDiff() {
        // 2.54.0 ↔ 2.54.1 — patch-level diff within the same
        // minor. Trivially negotiates.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "2.54.1"),
            .compatibleNewProtocol(local: "2.54.0", remote: "2.54.1")
        )
    }

    func test_classify_compatible_bothOldProtocol() {
        // 2.51.0 ↔ 2.51.5 — both pre-2.52, both speak the old
        // wire protocol. Rare scenario (this UI ships an embedded
        // 2.54.0, so local will always be new-protocol), but the
        // classifier handles it correctly: same-side-of-boundary
        // counts as compatible.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.51.0", remote: "2.51.5"),
            .compatibleOldProtocol(local: "2.51.0", remote: "2.51.5")
        )
    }

    // --- Known-incompatible (user alert fires) ---

    func test_classify_incompatible_2_51_to_2_52() {
        // The precise wire-protocol boundary: last old-protocol
        // release vs. first new-protocol release. Two integers
        // apart on the minor; an ocean apart on the protocol.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.52.0", remote: "2.51.5"),
            .incompatibleAcrossBoundary(local: "2.52.0", remote: "2.51.5")
        )
    }

    func test_classify_incompatible_2_40_to_2_54() {
        // Long-tail remote (some users still running ancient
        // distro packages) vs. our vendored 2.54.0.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "2.40.102"),
            .incompatibleAcrossBoundary(local: "2.54.0", remote: "2.40.102")
        )
    }

    func test_classify_incompatible_2_51_to_2_54() {
        // Last release before the boundary vs. current vendored.
        // Common scenario for users who haven't touched their
        // remote in a while.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "2.51.0"),
            .incompatibleAcrossBoundary(local: "2.54.0", remote: "2.51.0")
        )
    }

    func test_classify_incompatible_directionSymmetric() {
        // Whichever side is the older one, we still flag it.
        // (The alert text will say "the older one needs to be
        // upgraded" regardless of which is local vs. remote.)
        XCTAssertEqual(
            VersionCheck.classify(local: "2.51.0", remote: "2.54.0"),
            .incompatibleAcrossBoundary(local: "2.51.0", remote: "2.54.0")
        )
    }

    // --- Boundary edge case ---

    func test_classify_boundaryExactPair() {
        // 2.51.0 ↔ 2.52.0 — minor-version diff of 1, but it's
        // the protocol boundary. Specifically the case that
        // motivated splitting the predicate at 2.52.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.51.0", remote: "2.52.0"),
            .incompatibleAcrossBoundary(local: "2.51.0", remote: "2.52.0")
        )
    }

    func test_classify_unparseable_defaultsToCompatible() {
        // If a remote returns garbage, isPre252 defensively reports
        // false (new-protocol), so the classifier treats it as
        // compatibleNewProtocol against any new-protocol local.
        // Better to skip a possibly-spurious alert than to alarm
        // the user on noise.
        XCTAssertEqual(
            VersionCheck.classify(local: "2.54.0", remote: "garbage"),
            .compatibleNewProtocol(local: "2.54.0", remote: "garbage")
        )
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
