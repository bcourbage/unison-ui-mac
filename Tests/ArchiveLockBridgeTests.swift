import XCTest
@testable import unison_ui_mac

/// SF2 — exercise the vendored blob's lock callbacks (patch 0006) through the
/// PRODUCTION C/Swift bridge (`ArchiveLock` → `unison_bridge_lock_*` →
/// `caml_named_value` → OCaml `Lock`). This is the acceptance gate for blob
/// `52540833…`: it proves the exact SHA behaves correctly, not merely that the
/// symbols/strings exist.
///
/// The lockfile is `lk<hash>` in the unison dir. Tests use throwaway 32-hex
/// hashes and ALWAYS clean up — raw `Lock.acquire` (deliberately not the
/// heldLocks-tracked wrapper) is not released by OCaml's at_exit, and the
/// runtime is shared across the hosted test process, so a leaked lock would
/// poison later runs.
final class ArchiveLockBridgeTests: XCTestCase {

    private var unisonDir: String { String(cString: unison_bridge_unison_directory()) }
    private func lockPath(_ hash: String) -> String { unisonDir + "/lk" + hash }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    private func rm(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    /// acquire → is_locked → re-acquire(refused) → release → gone.
    func test_acquire_isLocked_release_roundtrip() {
        let h = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"   // 32 lowercase hex
        rm(lockPath(h))
        defer { ArchiveLock.release(hash: h); rm(lockPath(h)) }

        XCTAssertEqual(ArchiveLock.isLocked(hash: h), .unlocked)
        XCTAssertEqual(ArchiveLock.acquire(hash: h), .acquired)
        XCTAssertTrue(exists(lockPath(h)), "acquire creates lk<hash> on disk")
        XCTAssertEqual(ArchiveLock.isLocked(hash: h), .locked)

        // Re-acquiring a lock we already hold must fail closed (the hard-link
        // file exists → the acquire hard-link dance yields nlink != 2 → false).
        XCTAssertEqual(ArchiveLock.acquire(hash: h), .alreadyHeld,
                       "re-acquiring an existing lock must not succeed")

        ArchiveLock.release(hash: h)
        XCTAssertEqual(ArchiveLock.isLocked(hash: h), .unlocked)
        XCTAssertFalse(exists(lockPath(h)), "release unlinks lk<hash>")
    }

    /// A pre-existing lockfile (as a live/other Unison would leave) is refused.
    /// Creating the file directly is the exact on-disk state another process's
    /// `Lock.acquire` produces, so this faithfully tests contention-refusal
    /// without a second live runtime.
    func test_existingLock_isRefused() {
        let h = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
        let p = lockPath(h)
        XCTAssertTrue(FileManager.default.createFile(atPath: p, contents: Data()),
                      "seed a foreign lock")
        // We did NOT acquire it, so we must NOT release it (that would unlink
        // another holder's lock); clean up the seeded file directly.
        defer { rm(p) }

        XCTAssertEqual(ArchiveLock.isLocked(hash: h), .locked)
        XCTAssertEqual(ArchiveLock.acquire(hash: h), .alreadyHeld,
                       "acquire must refuse a pre-existing lock")
        XCTAssertTrue(exists(p), "a refused acquire must not remove the foreign lock")
    }

    /// Only a 32-char lowercase-hex hash is a valid capability. Everything else
    /// is refused before any filesystem touch; is_locked returns diagnostic
    /// `.unknown`; release is a harmless no-op. No lockfile is ever created.
    func test_invalidHash_isRefused_andDiagnosticOnly() {
        let bad = [
            "",                                    // empty
            "nothex",                              // too short, non-hex
            "A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1",    // uppercase (not lowercase)
            "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a",     // 31 chars
            "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a",   // 33 chars
            "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1g1",    // contains 'g'
            "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 1",    // contains a space
        ]
        for b in bad {
            XCTAssertEqual(ArchiveLock.acquire(hash: b), .invalidHash,
                           "acquire(\(b.debugDescription)) must be refused as invalid")
            XCTAssertEqual(ArchiveLock.isLocked(hash: b), .unknown,
                           "isLocked(\(b.debugDescription)) is diagnostic-unknown, never a gate")
            ArchiveLock.release(hash: b)   // must not crash or unlink anything
        }
    }
}
