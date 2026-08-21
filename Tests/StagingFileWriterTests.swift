import XCTest
@testable import unison_ui_mac

/// `StagingFileWriter.writeAllAndFinalize` — write-completion hardening for the
/// exclusive install path. All syscalls are injected so every failure mode is
/// deterministic. Invariants: a positive-length `write` returning 0 is a
/// FAILURE; all bytes are verified; fchmod/fsync/close failures are surfaced;
/// the fd is always closed exactly once; the first failure is reported.
final class StagingFileWriterTests: XCTestCase {

    private let payload = Data("root = /a\nroot = /b\nlog = true\n".utf8)

    /// A configurable fake with call counters.
    private final class Fake {
        var closeCount = 0
        var writeCalls = 0
        var bytesAccepted = 0
        var fchmodCalls = 0
        var fsyncCalls = 0
        var sys = POSIXFileSyscalls()
    }

    private func fake(
        write: @escaping (Int32, UnsafeRawPointer, Int) -> Int,
        fchmod: @escaping (Int32, mode_t) -> Int32 = { _, _ in 0 },
        fsync: @escaping (Int32) -> Int32 = { _ in 0 },
        close: @escaping (Int32) -> Int32 = { _ in 0 }
    ) -> (Fake, POSIXFileSyscalls) {
        let f = Fake()
        var sys = POSIXFileSyscalls()
        sys.writeFn = { fd, p, n in f.writeCalls += 1; let r = write(fd, p, n); if r > 0 { f.bytesAccepted += r }; return r }
        sys.fchmodFn = { fd, m in f.fchmodCalls += 1; return fchmod(fd, m) }
        sys.fsyncFn = { fd in f.fsyncCalls += 1; return fsync(fd) }
        sys.closeFn = { fd in f.closeCount += 1; return close(fd) }
        return (f, sys)
    }

    func test_fullSuccess_writesAllBytes_fsyncs_closesOnce() {
        let (f, sys) = fake(write: { _, _, n in n })   // accepts everything in one call
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertNil(err)
        XCTAssertEqual(f.bytesAccepted, payload.count)
        XCTAssertEqual(f.fsyncCalls, 1)
        XCTAssertEqual(f.closeCount, 1)
    }

    func test_partialWrites_accumulateToFullSuccess() {
        // Accept at most 4 bytes per call → multiple iterations, all bytes land.
        let (f, sys) = fake(write: { _, _, n in min(n, 4) })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertNil(err)
        XCTAssertEqual(f.bytesAccepted, payload.count)
        XCTAssertGreaterThan(f.writeCalls, 1)
        XCTAssertEqual(f.closeCount, 1)
    }

    func test_shortWrite_zeroReturn_isFailureNotSuccess() {
        // First call accepts some, then write() returns 0 with bytes remaining.
        var call = 0
        let (f, sys) = fake(write: { _, _, n in call += 1; return call == 1 ? min(n, 3) : 0 })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        guard case .shortWrite(let written, let expected)? = err else {
            return XCTFail("expected shortWrite, got \(String(describing: err))")
        }
        XCTAssertEqual(written, 3)
        XCTAssertEqual(expected, payload.count)
        XCTAssertEqual(f.closeCount, 1, "fd is still closed on a short write (no leak)")
    }

    func test_writeHardError_isSurfacedWithErrno() {
        let (f, sys) = fake(write: { _, _, _ in errno = EIO; return -1 })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertEqual(err, .writeFailed(errno: EIO))
        XCTAssertEqual(f.closeCount, 1)
    }

    func test_EINTR_retriesThenSucceeds() {
        var call = 0
        let (f, sys) = fake(write: { _, _, n in
            call += 1
            if call == 1 { errno = EINTR; return -1 }   // interrupted once
            return n
        })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertNil(err)
        XCTAssertEqual(f.bytesAccepted, payload.count)
    }

    func test_fchmodFailure_surfaced_beforeAnyWrite() {
        let (f, sys) = fake(write: { _, _, n in n }, fchmod: { _, _ in errno = EPERM; return -1 })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertEqual(err, .fchmodFailed(errno: EPERM))
        XCTAssertEqual(f.writeCalls, 0, "no bytes written after a fchmod failure")
        XCTAssertEqual(f.closeCount, 1)
    }

    func test_fsyncFailure_surfaced_neverReportedSuccess() {
        let (_, sys) = fake(write: { _, _, n in n }, fsync: { _ in errno = EIO; return -1 })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertEqual(err, .fsyncFailed(errno: EIO))
    }

    func test_closeFailure_surfaced() {
        let (_, sys) = fake(write: { _, _, n in n }, close: { _ in errno = EIO; return -1 })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertEqual(err, .closeFailed(errno: EIO))
    }

    func test_firstFailureWins_writeFailureReportedEvenIfCloseAlsoFails() {
        let (f, sys) = fake(write: { _, _, _ in errno = EIO; return -1 },
                            close: { _ in errno = EBADF; return -1 })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: payload, mode: 0o644, sys: sys)
        XCTAssertEqual(err, .writeFailed(errno: EIO), "the earlier write failure is reported, not the close")
        XCTAssertEqual(f.closeCount, 1, "fd still closed exactly once")
    }

    func test_emptyData_valid_noWriteCalls() {
        let (f, sys) = fake(write: { _, _, _ in XCTFail("write should not be called for empty data"); return 0 })
        let err = StagingFileWriter.writeAllAndFinalize(fd: 7, data: Data(), mode: 0o644, sys: sys)
        XCTAssertNil(err)
        XCTAssertEqual(f.writeCalls, 0)
        XCTAssertEqual(f.fsyncCalls, 1)
        XCTAssertEqual(f.closeCount, 1)
    }
}
