import Foundation

/// Typed façade over the vendored blob's archive-lock bridge (patch 0006).
///
/// Acquires the SAME per-archive lock a live Unison uses, so the archive-
/// mutation transaction can exclude concurrent access before it deletes or
/// resets archive state. Pass the 32-char lowercase-hex archive hash (from
/// `ar<hash>` / `lk<hash>`); OCaml validates it and builds the lockfile path.
///
/// A successful `.acquired` is the ONLY authority to mutate that archive.
/// Anything else — `.alreadyHeld`, `.exception`, `.invalidHash`,
/// `.bridgeMissing` — means fail closed: do not mutate. `isLocked` is
/// diagnostic-only and must never gate a mutation (a concurrent Unison can take
/// the lock between a check and a mutate; only a successful acquire is safe).
enum ArchiveLock {

    enum AcquireResult: Equatable {
        case acquired       // we now hold it — the sole mutation authority
        case alreadyHeld    // a live Unison or a stale lock holds it — fail closed
        case exception      // OCaml raised (Unix error) — fail closed
        case invalidHash    // not a 32-char lowercase-hex hash — refused
        case bridgeMissing  // callback not registered (old blob) — fail closed

        /// True only for `.acquired`. Every other outcome must block mutation.
        var didAcquire: Bool { self == .acquired }

        /// What an acquisition attempt established. Crucially, a failure to acquire
        /// is NOT proof the lock is absent: `.exception` (OCaml raised — patch 0006
        /// returns code 2 without checking state) and `.bridgeMissing`/`.invalidHash`
        /// (can't check at all) are UNKNOWN, not unlocked. Only `.acquired` means we
        /// now own the lock; only `.alreadyHeld` proves another holder.
        enum AcquisitionDisposition: Equatable {
            case acquiredByUs   // we now own the lock (it exists, held by this process)
            case heldByAnother  // a lock file exists (a live Unison or a stale lock)
            case unknown        // could not be established — treat conservatively
        }
        var acquisitionDisposition: AcquisitionDisposition {
            switch self {
            case .acquired:                                return .acquiredByUs
            case .alreadyHeld:                             return .heldByAnother
            case .exception, .invalidHash, .bridgeMissing: return .unknown
            }
        }
    }

    enum LockState: Equatable {
        case unlocked
        case locked
        case unknown        // exception or invalid hash — diagnostic only
        case bridgeMissing
    }

    /// Atomically acquire the archive lock. On `.acquired`, the caller owns it
    /// and must `release` it on every success/error/shutdown path.
    static func acquire(hash: String) -> AcquireResult {
        // Codes mirror UNISON_LOCK_* in UnisonBridgeC.h.
        switch unison_bridge_lock_acquire(hash) {
        case 0:  return .acquired      // UNISON_LOCK_ACQUIRED
        case 1:  return .alreadyHeld   // UNISON_LOCK_HELD
        case 2:  return .exception     // UNISON_LOCK_EXN
        case 3:  return .invalidHash   // UNISON_LOCK_INVALID_HASH
        default: return .bridgeMissing // UNISON_LOCK_MISSING (-1) or unexpected
        }
    }

    /// Release a lock THIS process acquired. Best-effort; no-op on an invalid
    /// hash or a missing callback. Never release a lock you did not acquire.
    static func release(hash: String) {
        unison_bridge_lock_release(hash)
    }

    /// Diagnostic only — NEVER gate a mutation on this.
    static func isLocked(hash: String) -> LockState {
        switch unison_bridge_lock_is_locked(hash) {
        case 0:  return .unlocked
        case 1:  return .locked
        case 2:  return .unknown
        default: return .bridgeMissing
        }
    }

    /// Absolute path of the `lk<hash>` lock file, inside the same unison directory
    /// OCaml uses (`Util.fileInUnisonDir`). Used to capture / verify a lock's
    /// identity; NEVER to hand-roll acquisition (that stays atomic via the bridge).
    static func lockPath(hash: String) -> String? {
        guard let c = unison_bridge_unison_directory() else { return nil }
        return (String(cString: c) as NSString).appendingPathComponent("lk" + hash)
    }
}

/// A durable fingerprint of a specific lock FILE on disk, so recovery can prove an
/// existing `lk<hash>` is the very one an interrupted transaction created — not a
/// lock a different process (CLI, cron, second app, incoming Unison) acquired for
/// the same hash after the crash. `st_dev` + `st_ino` identify the inode; the
/// change time distinguishes a reused inode. An empty hard-link lock has no
/// content, so there is nothing else to digest.
struct LockIdentity: Codable, Equatable {
    let dev: Int64
    let ino: UInt64
    let ctimeSec: Int64
    let ctimeNsec: Int64

    init(dev: Int64, ino: UInt64, ctimeSec: Int64, ctimeNsec: Int64) {
        self.dev = dev; self.ino = ino; self.ctimeSec = ctimeSec; self.ctimeNsec = ctimeNsec
    }

    /// Capture the identity of the file at `path`. nil if it can't be statted
    /// (absent or unreadable) — the caller must then fail closed, never adopt.
    init?(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        self.dev = Int64(st.st_dev)
        self.ino = UInt64(st.st_ino)
        self.ctimeSec = Int64(st.st_ctimespec.tv_sec)
        self.ctimeNsec = Int64(st.st_ctimespec.tv_nsec)
    }
}
