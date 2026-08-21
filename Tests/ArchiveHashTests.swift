import XCTest
@testable import unison_ui_mac

/// Pinned tests for `ArchiveHash` — both the canonicalization rules
/// (which determine `thisRoot` / `rootsName`) and the MD5 digest of
/// the resulting input string. The reference digests in this file
/// come from running `md5(1)` on the exact strings the algorithm
/// builds, so a regression in either canonicalization OR digest
/// computation surfaces as a test failure.
///
/// **Don't regenerate these blindly.** If a test fails after a code
/// change, verify by hand against `md5(1)` (or
/// `unison -showArchiveName <profile>` on a real profile) that the
/// NEW value is the correct upstream-compatible one — otherwise we
/// risk losing Unison compatibility.
final class ArchiveHashTests: XCTestCase {

    // MARK: - Canonicalization

    func test_canonicalize_localAbsolutePath_isPrefixedWithDoubleSlashHost() {
        let (canonical, isLocal) = ArchiveHash.canonicalize(
            "/Users/bob/Documents", hostname: "mac.local"
        )
        // Upstream: `"//"^host^"/"^fspath` where fspath starts with `/`
        // → double slash between host and path.
        XCTAssertEqual(canonical, "//mac.local//Users/bob/Documents")
        XCTAssertTrue(isLocal)
    }

    func test_canonicalize_localTrailingSlash_isStripped() {
        // `/Volumes/Backup/` → `/Volumes/Backup`. Trailing slashes
        // would otherwise differ the hash for the "same" path.
        let (canonical, _) = ArchiveHash.canonicalize(
            "/Volumes/Backup/", hostname: "host"
        )
        XCTAssertEqual(canonical, "//host//Volumes/Backup")
    }

    func test_canonicalize_tildePath_isExpanded() {
        let (canonical, isLocal) = ArchiveHash.canonicalize(
            "~/Documents", hostname: "h"
        )
        XCTAssertTrue(isLocal)
        // expandingTildeInPath uses NSHomeDirectory(); we don't pin
        // the exact value (varies per test runner) but we DO pin the
        // shape: `//h/` prefix and the expansion happened (not
        // literally `~/...`).
        XCTAssertTrue(canonical.hasPrefix("//h/"),
                      "got: \(canonical)")
        XCTAssertFalse(canonical.contains("~"),
                       "tilde should be expanded; got: \(canonical)")
    }

    func test_canonicalize_sshRoot_passesThrough() {
        let (canonical, isLocal) = ArchiveHash.canonicalize(
            "ssh://alice@server//data", hostname: "ignored"
        )
        XCTAssertEqual(canonical, "ssh://alice@server//data")
        XCTAssertFalse(isLocal)
    }

    func test_canonicalize_socketRoot_passesThrough() {
        let (canonical, isLocal) = ArchiveHash.canonicalize(
            "socket://host:1234//srv/data", hostname: "ignored"
        )
        XCTAssertEqual(canonical, "socket://host:1234//srv/data")
        XCTAssertFalse(isLocal)
    }

    func test_canonicalize_fileSchemeHostform_isRemote() {
        // `file://host/path` has a host part → treated as remote.
        let (canonical, isLocal) = ArchiveHash.canonicalize(
            "file://otherhost/path", hostname: "myhost"
        )
        XCTAssertEqual(canonical, "file://otherhost/path")
        XCTAssertFalse(isLocal)
    }

    func test_canonicalize_fileSchemeLocalForm_isLocal() {
        // `file:///path` (three slashes — no host) → local. We treat
        // the path part as a plain absolute path.
        let (canonical, isLocal) = ArchiveHash.canonicalize(
            "file:///Users/bob/data", hostname: "myhost"
        )
        XCTAssertEqual(canonical, "//myhost//Users/bob/data")
        XCTAssertTrue(isLocal)
    }

    func test_canonicalize_trimsLeadingTrailingWhitespace() {
        // The .prf might have `root = /Users/bob/Documents  ` with
        // trailing whitespace; we shouldn't let that into the hash.
        let (canonical, _) = ArchiveHash.canonicalize(
            "  /Users/bob/Documents  ", hostname: "h"
        )
        XCTAssertEqual(canonical, "//h//Users/bob/Documents")
    }

    // MARK: - MD5 of the final hash input

    func test_md5_emptyString_isKnownConstant() {
        // Sanity check on the MD5 implementation itself. The MD5 of
        // "" is a well-known constant; if this fails the CommonCrypto
        // wiring is broken.
        XCTAssertEqual(ArchiveHash.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
    }

    // MARK: - End-to-end hash from .prf text

    func test_compute_localAndSshProfile_matchesReferenceDigest() {
        // Reference computed with:
        //   echo -n "//mac.local//Users/bob/Documents;//mac.local//Users/bob/Documents, ssh://alice@server//data;23" | md5
        let text = """
            root = /Users/bob/Documents
            root = ssh://alice@server//data
            """
        let result = ArchiveHash.computeFromProfileText(text, hostname: "mac.local")
        switch result {
        case .failure(let why):
            XCTFail("expected success, got \(why)")
        case .success(let r):
            XCTAssertEqual(r.thisRoot, "//mac.local//Users/bob/Documents")
            // rootsName: sorted lexicographically — `/` (0x2F) < `s` (0x73)
            // so the local form sorts first.
            XCTAssertEqual(r.rootsName,
                           "//mac.local//Users/bob/Documents, ssh://alice@server//data")
            XCTAssertEqual(r.hash, "5c9dadacf03564570125e8874b374b9f")
        }
    }

    func test_compute_twoLocalRoots_thisRootIsTheFirstLocal() {
        // Reference:
        //   echo -n "//host//tmp/a;//host//tmp/a, //host//tmp/b;23" | md5
        let text = """
            root = /tmp/a
            root = /tmp/b
            """
        let result = ArchiveHash.computeFromProfileText(text, hostname: "host")
        switch result {
        case .success(let r):
            XCTAssertEqual(r.thisRoot, "//host//tmp/a",
                           "first local root becomes thisRoot")
            XCTAssertEqual(r.rootsName, "//host//tmp/a, //host//tmp/b")
            XCTAssertEqual(r.hash, "f5058025b969c32f90b801dac5f77294")
        case .failure(let why):
            XCTFail("expected success, got \(why)")
        }
    }

    func test_compute_sortOrderMatchesUpstream_alphabeticalByByte() {
        // Reference:
        //   echo -n "//host//Volumes/Backup;//host//Volumes/Backup, ssh://user@example.com//srv/data;23" | md5
        // The local `//host//Volumes/...` sorts before `ssh://...` because
        // `/` (0x2F) < `s` (0x73). The hash MUST reflect that ordering;
        // a stable sort going the other way would break upstream
        // compatibility.
        let text = """
            root = /Volumes/Backup
            root = ssh://user@example.com//srv/data
            """
        let result = ArchiveHash.computeFromProfileText(text, hostname: "host")
        switch result {
        case .success(let r):
            XCTAssertEqual(r.hash, "7b602be9978e9adc4a9dc8ed0f1ca5cf")
            XCTAssertTrue(r.rootsName.hasPrefix("//host//Volumes/Backup"),
                          "local form should sort first")
        case .failure(let why):
            XCTFail("expected success, got \(why)")
        }
    }

    func test_compute_noRoots_failsWithNoRoots() {
        let text = """
            # All comment, no roots
            batch = true
            """
        let result = ArchiveHash.computeFromProfileText(text, hostname: "h")
        XCTAssertEqual(result, .failure(.noRoots))
    }

    func test_compute_allRemoteRoots_failsWithNoLocalRoot() {
        // Both replicas are remote — archive files live on those
        // remote machines, not here, so we can't compute thisRoot
        // for this machine. The UI surfaces this as "run from the
        // local-replica machine".
        let text = """
            root = ssh://a@host1//srv/a
            root = ssh://b@host2//srv/b
            """
        let result = ArchiveHash.computeFromProfileText(text, hostname: "h")
        XCTAssertEqual(result, .failure(.noLocalRoot))
    }

    // MARK: - Stability across profile-name changes (the key insight)

    func test_compute_isUnaffectedByProfileName() {
        // The whole reason we don't warn on rename: the profile
        // filename is NOT input to the hash. Two profiles with the
        // same roots produce the same hash, period. This is what
        // makes rename safe for archive state.
        let text = """
            root = /tmp/a
            root = /tmp/b
            """
        // Both calls use the same text — the profile name doesn't
        // enter the function. We compute the hash directly from text.
        let a = ArchiveHash.computeFromProfileText(text, hostname: "h")
        let b = ArchiveHash.computeFromProfileText(text, hostname: "h")
        XCTAssertEqual(a, b)
    }

    func test_computeAll_twoLocalRoots_yieldsTwoDistinctHashes() {
        // A local↔local profile keeps a separate archive per local root,
        // each with that root as `thisRoot` but a shared rootsName.
        // computeAll must surface BOTH so reset/cleanup covers them.
        let text = """
            root = /tmp/a
            root = /tmp/b
            """
        guard case .success(let multi) =
                ArchiveHash.computeAllFromProfileText(text, hostname: "h") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(multi.entries.count, 2)
        XCTAssertEqual(Set(multi.hashes).count, 2, "hashes must differ per local root")
        // Shared rootsName; thisRoot differs.
        XCTAssertEqual(multi.entries[0].rootsName, multi.entries[1].rootsName)
        XCTAssertEqual(multi.entries[0].thisRoot, "//h//tmp/a")
        XCTAssertEqual(multi.entries[1].thisRoot, "//h//tmp/b")
        // compute() (singular) returns the first entry — back-compat.
        let single = ArchiveHash.computeFromProfileText(text, hostname: "h")
        XCTAssertEqual(try? single.get(), multi.entries[0])
    }

    func test_computeAll_localRemoteProfile_yieldsSingleHash() {
        // The common case: one local root, one ssh root → one archive
        // family locally. No behavior change vs. the old single-hash path.
        let text = """
            root = /tmp/a
            root = ssh://host//data
            """
        guard case .success(let multi) =
                ArchiveHash.computeAllFromProfileText(text, hostname: "h") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(multi.entries.count, 1)
        XCTAssertEqual(multi.entries[0].thisRoot, "//h//tmp/a")
    }

    func test_systemHostname_matchesPosixGethostname_notProcessInfo() {
        // Regression: the default hostname MUST be POSIX gethostname(2)
        // (what Unison's Os.localCanonicalHostName uses to name archives),
        // NOT ProcessInfo.hostName, which on macOS returns the Bonjour
        // ".local" name and produced a hash matching no archive on disk.
        // Compute gethostname independently here and require equality.
        var buffer = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(gethostname(&buffer, buffer.count), 0)
        let expected = String(cString: buffer)

        // Only meaningful when the env override is absent.
        if ProcessInfo.processInfo.environment["UNISONLOCALHOSTNAME"] == nil {
            XCTAssertEqual(ArchiveHash.systemHostname, expected)
            // And it must NOT carry the ".local" suffix that the wrong
            // API appends when HostName has no domain.
            XCTAssertFalse(
                ArchiveHash.systemHostname.hasSuffix(".local")
                    && !expected.hasSuffix(".local"),
                "systemHostname leaked a .local suffix; using ProcessInfo.hostName again?"
            )
        }
    }

    func test_systemHostname_honorsEnvOverride() throws {
        // UNISONLOCALHOSTNAME wins over gethostname, matching upstream.
        // Can only assert when the override is actually set in the env.
        if let override = ProcessInfo.processInfo.environment["UNISONLOCALHOSTNAME"],
           !override.isEmpty {
            XCTAssertEqual(ArchiveHash.systemHostname, override)
        } else {
            throw XCTSkip("UNISONLOCALHOSTNAME not set in this environment")
        }
    }
}
