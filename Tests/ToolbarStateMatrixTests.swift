import XCTest
@testable import unison_ui_mac

/// The issue #117 state matrix: for every reconcile phase, assert the Stop
/// item's title/tint/enablement together, the Rescan rule, and the Go/direction
/// gate — all derived from the single shared `ReconcileActionGate`.
///
/// This is the cross-cutting guard that ties presentation to enablement: the
/// toolbar item, the menu item (⌘.), the ⌘⇧R keyboard path, and the action
/// method boundaries all consume `gate.allows(_:)`, so pinning the gate here
/// pins all four. Presentation is built exactly as `validateToolbarItem` builds
/// it: `StopItemAppearance(canStop: gate.allows(.stop))`.
final class ToolbarStateMatrixTests: XCTestCase {
    private typealias Gate = ReconcileActionGate

    private struct Phase {
        let name: String
        let gate: Gate
        let stopEnabled: Bool     // gate.allows(.stop)
        let rescanEnabled: Bool   // gate.allows(.rescan)
        let goEnabled: Bool       // gate.isActionable (Go / direction)
    }

    private func phases() -> [Phase] {
        [
            Phase(name: "connect/scan",
                  gate: Gate(restartRequired: false, mutationInFlight: false,
                             isSyncing: false, isScanning: true,
                             phase: .ready, hasItems: false),
                  stopEnabled: false, rescanEnabled: false, goEnabled: false),
            Phase(name: "sync",
                  gate: Gate(restartRequired: false, mutationInFlight: false,
                             isSyncing: true, isScanning: false,
                             phase: .syncing, hasItems: true),
                  stopEnabled: true, rescanEnabled: false, goEnabled: false),
            Phase(name: "inert-ready",
                  gate: Gate(restartRequired: false, mutationInFlight: false,
                             isSyncing: false, isScanning: false,
                             phase: .ready, hasItems: true),
                  stopEnabled: false, rescanEnabled: true, goEnabled: true),
            Phase(name: "inert-done",
                  gate: Gate(restartRequired: false, mutationInFlight: false,
                             isSyncing: false, isScanning: false,
                             phase: .done, hasItems: true),
                  stopEnabled: false, rescanEnabled: true, goEnabled: false),
        ]
    }

    func test_stop_titleIsAlwaysStop_inEveryPhase() {
        for p in phases() {
            let a = StopItemAppearance(canStop: p.gate.allows(.stop))
            XCTAssertEqual(a.title, "Stop", "Stop title must be constant in \(p.name)")
        }
    }

    func test_stop_enablementMatchesMatrix() {
        for p in phases() {
            XCTAssertEqual(p.gate.allows(.stop), p.stopEnabled,
                           "Stop enablement wrong in \(p.name)")
        }
    }

    func test_stop_isDestructiveIffEnabled_inEveryPhase() {
        for p in phases() {
            let a = StopItemAppearance(canStop: p.gate.allows(.stop))
            let expected: StopItemAppearance.Tint = p.gate.allows(.stop) ? .destructive : .normal
            XCTAssertEqual(a.tint, expected, "Stop tint wrong in \(p.name)")
            // The refinement-#2 invariant, stated directly.
            if !p.gate.allows(.stop) {
                XCTAssertNotEqual(a.tint, .destructive,
                                  "disabled Stop must never be red (\(p.name))")
            }
        }
    }

    func test_rescan_enablementMatchesMatrix() {
        for p in phases() {
            XCTAssertEqual(p.gate.allows(.rescan), p.rescanEnabled,
                           "Rescan enablement wrong in \(p.name)")
        }
    }

    func test_rescan_disabledThroughoutConnectScanAndSync() {
        for p in phases() where p.name == "connect/scan" || p.name == "sync" {
            XCTAssertFalse(p.gate.allows(.rescan),
                           "Rescan must be disabled in \(p.name)")
        }
    }

    func test_go_enablementMatchesMatrix() {
        for p in phases() {
            XCTAssertEqual(p.gate.isActionable, p.goEnabled,
                           "Go/direction gate wrong in \(p.name)")
        }
    }

    func test_navigationAlwaysAvailable_inEveryPhase() {
        for p in phases() {
            XCTAssertTrue(p.gate.allows(.profiles), "Profiles must stay available in \(p.name)")
            XCTAssertTrue(p.gate.allows(.quit), "Quit must stay available in \(p.name)")
        }
    }
}
