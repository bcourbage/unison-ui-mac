import XCTest
@testable import unison_ui_mac

/// SF6 — the Clean Stale window's selection/mutation guards, now pure and
/// verified: Select-All covers only actionable rows, the mutation set is
/// checked-AND-actionable (a non-actionable row is never acted on even if
/// checked), and every non-actionable row has a concrete refusal reason.
final class CleanStalePolicyTests: XCTestCase {

    func test_selectableIndices_actionableOnly() {
        XCTAssertEqual(
            CleanStalePolicy.selectableIndices(actionable: [true, false, true, false]),
            [0, 2])
        XCTAssertEqual(CleanStalePolicy.selectableIndices(actionable: [false, false]), [])
    }

    func test_mutationHashes_excludesNonActionable_evenWhenChecked() {
        let hashes = ["h0", "h1", "h2"]
        // Row 1 is checked but NOT actionable → must be excluded (authority).
        let out = CleanStalePolicy.mutationHashes(
            hashes: hashes, actionable: [true, false, true], checked: [true, true, false])
        XCTAssertEqual(out, ["h0"], "checked-but-not-actionable and actionable-but-unchecked both excluded")
    }

    func test_mutationHashes_actionableAndChecked() {
        let out = CleanStalePolicy.mutationHashes(
            hashes: ["a", "b"], actionable: [true, true], checked: [true, true])
        XCTAssertEqual(out, ["a", "b"])
    }

    func test_refusalReason_nilWhenActionable() {
        XCTAssertNil(CleanStalePolicy.refusalReason(
            actionable: true, uncertain: false, reason: .superseded))
    }

    func test_refusalReason_uncertain() {
        let r = CleanStalePolicy.refusalReason(actionable: false, uncertain: true, reason: .superseded)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.lowercased().contains("report-only"))
    }

    func test_refusalReason_orphan() {
        let r = CleanStalePolicy.refusalReason(actionable: false, uncertain: false, reason: .orphan)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.lowercased().contains("orphan"))
    }

    func test_refusalReason_supersededWithoutLiveGeneration() {
        let r = CleanStalePolicy.refusalReason(actionable: false, uncertain: false, reason: .superseded)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.lowercased().contains("supersede"))
    }
}
