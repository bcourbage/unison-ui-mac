import XCTest
import AppKit
@testable import unison_ui_mac

/// The recovery reopen (fatal retry, Retry Ignoring Archives, Rescan Ignoring
/// Archives) starts a new session for the profile that is already open. The
/// profile file is read again, so its roots can differ from what the open gate
/// evaluated when the session started; the reopen must consult the same gate.
@MainActor
final class ReopenGateTests: XCTestCase {

    private typealias C = EngineSessionCoordinator

    private func makeDirectory(profile: String, roots: [String]) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rg-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try roots.map { "root = \($0)\n" }.joined().write(
            toFile: dir + "/\(profile).prf", atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// A scanned session for `profile`, awaiting the user (what the menu action requires).
    private func openToReady(_ e: C, profile: String, remote: Bool = false) {
        func begin(_ eff: [C.Effect]) -> (C.SessionID, C.OperationID)? {
            for x in eff { if case let .beginConnect(s, op, _, _) = x { return (s, op) } }
            return nil
        }
        let (s, op) = begin(e.requestOpen(profile: profile))!
        let scanning = e.connectFinished(s, op, result: remote ? .remote(interactive: false) : .local)
        var scanOp: C.OperationID?
        for x in scanning { if case let .beginScan(_, o) = x { scanOp = o } }
        _ = e.scanCompleted(s, scanOp!)
    }

    private func heldRecord(for hashes: [String]) -> AbandonedStaging {
        var m = StagingManifest(operation: "reset", hashes: hashes, payloadFiles: [],
                                createdAtISO8601: "2026-11-01T00:00:00Z")
        m.phase = StagingManifest.phaseStaging
        return AbandonedStaging(quarantineDir: "/q/held", manifest: m)
    }

    func test_reopen_isRefusedWhenTheProfilesCurrentArchivesAreHeld() throws {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }

        let base = try XCTUnwrap(ArchiveMatcher.realpathResolve(NSTemporaryDirectory()))
        let a = base + "/rg-a-" + UUID().uuidString, b = base + "/rg-b-" + UUID().uuidString
        for p in [a, b] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
        addTeardownBlock { for p in [a, b] { try? FileManager.default.removeItem(atPath: p) } }
        let dir = try makeDirectory(profile: "P", roots: [a, b])

        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting
        openToReady(e, profile: "P")                       // opened while nothing was held
        guard case .success(let hashes) = ArchiveHash.computeAll(forRoots: [a, b], hostname: ArchiveHash.systemHostname) else {
            return XCTFail("fixture roots must hash")
        }
        d.setAbandonedStagingForTesting([heldRecord(for: hashes.hashes)])   // held since

        d.reopenCurrentProfileFreshForTesting("P")

        if case .opening = e.phase { XCTFail("the reopen must not start a session for a profile whose archives are held") }
        XCTAssertNil(e.currentSession, "the stale session is released and nothing new is opened")
        XCTAssertEqual(d.recoveryOffersForTesting, 0, "recovery is offered from the picker, not from the teardown")
        XCTAssertTrue(d.pickerStateForTesting.visible, "the picker is shown after a blocked reopen")
        XCTAssertFalse(e.openRequestPending)
    }

    /// A remote session's close can still be pending when the reopen is refused.
    /// Recovery moves archive files, so it must not be offered then, and the
    /// recovery action itself must refuse while the engine is not idle.
    func test_blockedReopen_ofARemoteSession_doesNotOfferRecoveryWhileTheCloseIsPending() throws {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }

        let base = try XCTUnwrap(ArchiveMatcher.realpathResolve(NSTemporaryDirectory()))
        let a = base + "/rg-a-" + UUID().uuidString, b = base + "/rg-b-" + UUID().uuidString
        for p in [a, b] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
        addTeardownBlock { for p in [a, b] { try? FileManager.default.removeItem(atPath: p) } }
        let dir = try makeDirectory(profile: "P", roots: [a, "ssh://user@host//remote"])

        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting
        openToReady(e, profile: "P", remote: true)
        guard case .success(let hashes) = ArchiveHash.computeAll(forRoots: [a, "ssh://user@host//remote"],
                                                                 hostname: ArchiveHash.systemHostname) else {
            return XCTFail("fixture roots must hash")
        }
        let record = heldRecord(for: hashes.hashes)
        d.setAbandonedStagingForTesting([record])

        d.reopenCurrentProfileFreshForTesting("P")

        XCTAssertFalse(e.allowsDestructiveArchiveMutation,
                       "a released remote session is not idle yet (\(e.phase))")
        XCTAssertEqual(d.recoveryOffersForTesting, 0)

        // The user is left with the picker, the blocked profile selected.
        let picker = d.pickerStateForTesting
        XCTAssertTrue(picker.visible, "the notice must leave a picker to act from")
        XCTAssertEqual(picker.selected, "P")

        // Choosing it while the remote close is still pending refuses recovery and opens nothing.
        XCTAssertFalse(d.profileSelectedForTesting("P", args: []))
        XCTAssertEqual(d.recoveryOffersForTesting, 0, "recovery must refuse while the engine is not idle")
        d.offerRecoveryForTesting([record])
        XCTAssertEqual(d.recoveryOffersForTesting, 0)
        if case .opening = e.phase { XCTFail("nothing may be opened for a blocked profile") }
        XCTAssertFalse(e.openRequestPending, "no reopen may be queued")
    }

    func test_recoveryIsOfferedWhenTheEngineIsIdle() {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }
        let d = AppDelegate()
        XCTAssertTrue(d.engineForTesting.allowsDestructiveArchiveMutation)
        d.offerRecoveryForTesting([heldRecord(for: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])])
        XCTAssertEqual(d.recoveryOffersForTesting, 1)
    }

    /// Rescan Ignoring Archives edits the profile before it reopens. When the gate
    /// refuses the reopen, that edit must not be left in the profile.
    func test_rescanIgnoringArchives_refusedByTheGate_leavesTheProfileUnchanged() throws {
        AppDelegate.testRecoveryPromptSuppressed = true
        addTeardownBlock { @MainActor in AppDelegate.testRecoveryPromptSuppressed = false }

        let base = try XCTUnwrap(ArchiveMatcher.realpathResolve(NSTemporaryDirectory()))
        let a = base + "/rg-a-" + UUID().uuidString, b = base + "/rg-b-" + UUID().uuidString
        for p in [a, b] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
        addTeardownBlock { for p in [a, b] { try? FileManager.default.removeItem(atPath: p) } }
        let dir = try makeDirectory(profile: "P", roots: [a, b])
        let original = try String(contentsOfFile: dir + "/P.prf", encoding: .utf8)

        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        openToReady(d.engineForTesting, profile: "P")
        guard case .success(let hashes) = ArchiveHash.computeAll(forRoots: [a, b], hostname: ArchiveHash.systemHostname) else {
            return XCTFail("fixture roots must hash")
        }
        d.setAbandonedStagingForTesting([heldRecord(for: hashes.hashes)])

        d.rescanIgnoringArchivesForTesting("P")

        XCTAssertEqual(try String(contentsOfFile: dir + "/P.prf", encoding: .utf8), original,
                       "a refused reopen must not leave the ignorearchives edit in the profile")
        XCTAssertNil(d.engineForTesting.currentSession)
    }

    func test_reopen_proceedsWhenNothingIsHeld() throws {
        let dir = try makeDirectory(profile: "P", roots: ["/Users/test/Documents", "/Users/test/Backup"])
        let d = AppDelegate()
        d.setUnisonDirectoryForTesting(dir)
        let e = d.engineForTesting
        openToReady(e, profile: "P")

        d.reopenCurrentProfileFreshForTesting("P")

        guard case .opening = e.phase else { return XCTFail("expected a fresh open, got \(e.phase)") }
    }
}
