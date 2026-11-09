import XCTest
import AppKit
@testable import unison_ui_mac

/// The "Rescan Ignoring Archives" confirmation belongs to the session and window
/// it was raised from. Its modal can outlive them (a command-line takeover is
/// served while it is open), so it is checked again before the profile is
/// edited or a reopen is requested.
@MainActor
final class RescanConfirmationTests: XCTestCase {

    private typealias C = EngineSessionCoordinator
    private typealias Effect = EngineSessionCoordinator.Effect

    private func makeDelegate() throws -> (AppDelegate, String) {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }
        let dir = NSTemporaryDirectory() + "rc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        try "root = \(dir)/a\nroot = \(dir)/b\n".write(toFile: dir + "/P.prf", atomically: true, encoding: .utf8)
        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        d.suppressEngineEffectsForTesting = true
        return (d, dir)
    }

    private func prf(_ dir: String) throws -> String {
        try String(contentsOfFile: dir + "/P.prf", encoding: .utf8)
    }

    private func connect(_ e: [Effect]) -> (C.SessionID, C.OperationID)? {
        for x in e { if case let .beginConnect(s, op, _, _) = x { return (s, op) } }
        return nil
    }
    private func scanOp(_ e: [Effect]) -> C.OperationID? {
        for x in e { if case let .beginScan(_, op) = x { return op } }; return nil
    }

    /// Open `P` as a local session through the real driver and bring it to
    /// `.ready` with a window installed, as a user's session would be.
    private struct SetupFailure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    private func openReady(_ d: AppDelegate) throws -> C.SessionID {
        let e = d.engineForTesting
        _ = d.runPickerOpenForTesting("P")
        guard case .opening(let s, let op) = e.phase else {
            throw SetupFailure(description: "expected opening after the pick, got \(e.phase)")
        }
        _ = d.runForTesting(e.connectFinished(s, op, result: .local))
        guard case .scanning(_, let scan) = e.phase else {
            throw SetupFailure(description: "expected scanning after connect, got \(e.phase)")
        }
        _ = d.runForTesting(e.scanCompleted(s, scan))
        guard e.phase == .ready(s) else {
            throw SetupFailure(description: "expected ready after the scan, got \(e.phase)")
        }
        return s
    }

    func test_control_unchangedSession_confirms_startsTheOneShotReopen_andLeavesTheProfileUnchanged() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        let original = try prf(dir)
        let s = try openReady(d)
        let origin = try XCTUnwrap(d.rescanConfirmationOriginForTesting())

        d.completeRescanConfirmationForTesting(origin)

        XCTAssertEqual(try prf(dir), original, "the profile file is not edited")
        let firstLoad = d.effectsReachedForTesting.reversed().compactMap { x -> [String]? in
            if case .beginConnect(_, _, _, let args) = x { return args }; return nil }.first
        XCTAssertEqual(firstLoad, ["-ignorearchives=true"], "the reopen carries the one-shot override")
        XCTAssertFalse(d.hasWindowForTesting(s), "the old window is torn down for the reopen")
        guard case .opening(let s2, _) = e.phase else { return XCTFail("a fresh open should have started, got \(e.phase)") }
        XCTAssertNotEqual(s2, s)
    }

    func test_replacementSessionWithTheSameProfile_makesTheConfirmationStale() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        let original = try prf(dir)
        try openReady(d)
        let origin = try XCTUnwrap(d.rescanConfirmationOriginForTesting())

        // A command-line takeover replaces the session while the modal is open; the
        // replacement shows the same profile name.
        XCTAssertTrue(d.commandLineTakeoverForTesting(name: "P").started)
        guard case .opening(let b, let bop) = e.phase else { return XCTFail("replacement not opening: \(e.phase)") }
        _ = d.runForTesting(e.connectFinished(b, bop, result: .local))
        guard case .scanning(_, let scan) = e.phase else { return XCTFail("replacement not scanning: \(e.phase)") }
        _ = d.runForTesting(e.scanCompleted(b, scan))
        XCTAssertEqual(e.phase, .ready(b))
        XCTAssertTrue(d.hasWindowForTesting(b))

        d.completeRescanConfirmationForTesting(origin)

        XCTAssertEqual(try prf(dir), original, "no edit")
        XCTAssertEqual(e.phase, .ready(b), "the replacement session is not torn down")
        XCTAssertTrue(d.hasWindowForTesting(b))
        XCTAssertFalse(e.openRequestPending, "nothing is queued")
    }

    func test_sessionThatBecameBusy_makesTheConfirmationStale() throws {
        let (d, dir) = try makeDelegate()
        let e = d.engineForTesting
        let original = try prf(dir)
        let s = try openReady(d)
        let origin = try XCTUnwrap(d.rescanConfirmationOriginForTesting())

        let sync = e.requestSync()   // the same session is now synchronizing
        XCTAssertNotNil(sync.first(where: { if case .beginSync = $0 { return true }; return false }))
        let busy = e.phase

        d.completeRescanConfirmationForTesting(origin)

        XCTAssertEqual(try prf(dir), original, "no edit")
        XCTAssertEqual(e.phase, busy, "the running sync is untouched")
        XCTAssertTrue(d.hasWindowForTesting(s), "its window stays")
    }

    func test_windowReplacedUnderTheSameSession_makesTheConfirmationStale() throws {
        let (d, dir) = try makeDelegate()
        let original = try prf(dir)
        let s = try openReady(d)
        let origin = try XCTUnwrap(d.rescanConfirmationOriginForTesting())
        let w = ReconcileWindowController(
            profile: "P", mergeConfigured: false,
            onClose: {}, onRescanRequested: {}, onSyncStart: {}, onSyncExit: { _ in },
            onEngineUncertain: { _ in }, onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused }, onDiffAbandon: {})
        d.installWindowForTesting(s, w)

        d.completeRescanConfirmationForTesting(origin)

        XCTAssertEqual(try prf(dir), original)
        XCTAssertEqual(d.engineForTesting.phase, .ready(s))
    }
}
