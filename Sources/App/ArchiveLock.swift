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

        /// What this result establishes about the lock file on disk. Crucially,
        /// a failure to acquire is NOT proof the lock is absent: `.exception`
        /// (OCaml raised — patch 0006 returns code 2 without checking state) and
        /// `.bridgeMissing`/`.invalidHash` (can't check at all) are UNKNOWN, not
        /// unlocked. Only `.alreadyHeld` proves a lock exists.
        enum LockEvidence: Equatable {
            case held      // a lock file exists (foreign or stale)
            case absent    // the lock is known not to exist (we just acquired it)
            case unknown   // could not be established — treat conservatively
        }
        var lockEvidence: LockEvidence {
            switch self {
            case .acquired:                                return .absent
            case .alreadyHeld:                             return .held
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
}
