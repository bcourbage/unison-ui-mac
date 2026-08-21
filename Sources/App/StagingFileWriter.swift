import Foundation

/// A failure encountered while writing + finalizing a staging file descriptor,
/// before it is atomically installed. Every one of these MUST prevent the
/// staging file from being renamed into place.
enum StagingWriteError: Error, Equatable {
    /// `fchmod` on the staging fd failed.
    case fchmodFailed(errno: Int32)
    /// A positive-length `write()` returned 0 before all bytes were written —
    /// treated as a FAILURE (a partially written file), never success.
    case shortWrite(written: Int, expected: Int)
    /// `write()` returned a hard error.
    case writeFailed(errno: Int32)
    /// `fsync` (flush to disk for durability) failed.
    case fsyncFailed(errno: Int32)
    /// `close` failed — on some filesystems a deferred write-back error surfaces
    /// only here, so it can indicate lost bytes and must not be ignored.
    case closeFailed(errno: Int32)

    var operation: String {
        switch self {
        case .fchmodFailed: return "fchmod"
        case .shortWrite:   return "write (short write)"
        case .writeFailed:  return "write"
        case .fsyncFailed:  return "fsync"
        case .closeFailed:  return "close"
        }
    }

    /// The associated errno (0 for `shortWrite`, which is not an errno failure).
    var code: Int32 {
        switch self {
        case .fchmodFailed(let e), .writeFailed(let e), .fsyncFailed(let e), .closeFailed(let e):
            return e
        case .shortWrite:
            return 0
        }
    }

    var message: String {
        switch self {
        case .shortWrite(let w, let e):
            return "wrote only \(w) of \(e) bytes (write returned 0)"
        default:
            return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Injectable POSIX syscalls used by `StagingFileWriter`. Defaults are the real
/// syscalls, so production behavior is unchanged; tests inject fakes to exercise
/// short-write / fchmod / fsync / close failure paths deterministically. This is
/// NOT a production-accessible test hook — it is an ordinary struct with syscall
/// defaults; nothing reads it from a Release entry point.
struct POSIXFileSyscalls {
    var writeFn:  (Int32, UnsafeRawPointer, Int) -> Int   = { write($0, $1, $2) }
    var fchmodFn: (Int32, mode_t) -> Int32                = { fchmod($0, $1) }
    var fsyncFn:  (Int32) -> Int32                        = { fsync($0) }
    var closeFn:  (Int32) -> Int32                        = { close($0) }
}

enum StagingFileWriter {
    /// Write ALL of `data` to `fd`, set `mode`, `fsync` (durability), then
    /// `close` — surfacing every failure. Guarantees:
    /// - a positive-length `write()` returning 0 is a `shortWrite` FAILURE;
    /// - all bytes are verified written before success is reported;
    /// - `fchmod`, `fsync`, and `close` failures are surfaced, never ignored;
    /// - `fd` is ALWAYS closed exactly once (even after an earlier failure) so
    ///   it never leaks, and the FIRST failure is the one reported;
    /// - returns `nil` only when every step succeeded — the caller may then, and
    ///   only then, install the staging file.
    static func writeAllAndFinalize(
        fd: Int32, data: Data, mode: mode_t, sys: POSIXFileSyscalls = .init()
    ) -> StagingWriteError? {
        // Always close the fd; report `pending` (an earlier failure) if present,
        // otherwise a close failure.
        func closeReporting(_ pending: StagingWriteError?) -> StagingWriteError? {
            let rc = sys.closeFn(fd)
            let closeErrno = errno
            if let pending { return pending }
            return rc == 0 ? nil : .closeFailed(errno: closeErrno)
        }

        // Mode first, on the still-empty file — fail fast before writing.
        if sys.fchmodFn(fd, mode) != 0 {
            return closeReporting(.fchmodFailed(errno: errno))
        }

        var failure: StagingWriteError?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var ptr = raw.baseAddress else { return }   // empty data → 0-byte file (valid)
            var remaining = raw.count
            while remaining > 0 {
                let n = sys.writeFn(fd, ptr, remaining)
                if n < 0 {
                    let e = errno
                    if e == EINTR { continue }                // interrupted → retry
                    failure = .writeFailed(errno: e); return
                }
                if n == 0 {
                    // A positive-length write MUST make progress; 0 means the
                    // file is short. Never treat this as success.
                    failure = .shortWrite(written: raw.count - remaining, expected: raw.count)
                    return
                }
                ptr = ptr.advanced(by: n); remaining -= n
            }
        }
        if let failure { return closeReporting(failure) }

        // Flush to disk BEFORE the atomic rename so a committed profile survives
        // a crash (satisfies the "durable" contract).
        if sys.fsyncFn(fd) != 0 {
            return closeReporting(.fsyncFailed(errno: errno))
        }
        return closeReporting(nil)
    }
}
