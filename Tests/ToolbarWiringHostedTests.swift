import XCTest
import AppKit
@testable import unison_ui_mac

/// Hosted AppKit coverage that exercises the PRODUCTION toolbar wiring end to
/// end (issue #117 should-fix #2): a real `ReconcileWindowController` driven
/// through its real state-entry methods, a real `ReconcileToolbarDelegate`, real
/// `NSToolbarItem`s built by the delegate's own factory, and the real
/// `validateToolbarItem(_:)` — the exact call AppKit makes during validation.
///
/// The pure `ReconcileActionGate` / `StopItemAppearance` / `ProfilesHelp` tests
/// cannot catch a wiring regression: relabelling the Stop item back to "Return
/// to Profiles", breaking its enablement, or dropping the Profiles tooltip would
/// leave those green. These assertions fail on exactly those changes.
@MainActor
final class ToolbarWiringHostedTests: XCTestCase {

    private func stateItem(_ path: String) -> StateItem {
        StateItem(path: path, left: "f", right: "f", direction: "<-?->",
                  sizeBytes: 1, fileType: "file", progress: "", bytesTransferred: 0,
                  changedFromDefault: false)
    }

    private func makeController() -> ReconcileWindowController {
        ReconcileWindowController(
            profile: "T", mergeConfigured: false,
            onClose: {}, onRescanRequested: {},
            onSyncStart: {}, onSyncExit: { _ in }, onEngineUncertain: { _ in },
            onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused },
            onDiffAbandon: {})
    }

    /// Wire a real toolbar delegate to `c` and build the real production items via
    /// the delegate's own factory — exactly as `windowDidLoad` does
    /// (`toolbarDelegate.controller = self`; items come from the delegate).
    private func wire(_ c: ReconcileWindowController)
        -> (ReconcileToolbarDelegate, [NSToolbarItem.Identifier: NSToolbarItem]) {
        let delegate = ReconcileToolbarDelegate()
        delegate.controller = c
        let toolbar = NSToolbar(identifier: "ToolbarWiringHostedTests")
        var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
        for id in delegate.toolbarDefaultItemIdentifiers(toolbar) {
            if let it = delegate.toolbar(toolbar, itemForItemIdentifier: id,
                                         willBeInsertedIntoToolbar: true) {
                items[id] = it
            }
        }
        return (delegate, items)
    }

    // MARK: - Scanning

    func test_scanning_stopDisabledNeutral_profilesBackgroundHelp() {
        let c = makeController()
        c.beginInitialScan()   // isScanning = true, rows cleared
        let (d, items) = wire(c)
        let stop = items[DirectionAction.stopIdentifier]!
        let profiles = items[DirectionAction.profilesIdentifier]!

        XCTAssertFalse(d.validateToolbarItem(stop), "Stop is disabled during a scan")
        XCTAssertEqual(stop.label, "Stop", "Stop keeps its title during a scan (not relabelled)")

        XCTAssertTrue(d.validateToolbarItem(profiles), "Profiles is enabled during a scan")
        XCTAssertEqual(profiles.toolTip, ProfilesHelp.connectingOrScanning.toolTip,
                       "Profiles shows the connect/scan background-continuation help")

        XCTAssertFalse(d.validateToolbarItem(items[DirectionAction.goIdentifier]!),
                       "Go is disabled during a scan")
    }

    // MARK: - Ready (results shown)

    func test_ready_stopDisabledStop_goEnabled_profilesIdleHelp() {
        let c = makeController()
        c.replaceItems([stateItem("a.txt")])   // ready, with items
        let (d, items) = wire(c)
        let stop = items[DirectionAction.stopIdentifier]!
        let profiles = items[DirectionAction.profilesIdentifier]!

        XCTAssertFalse(d.validateToolbarItem(stop), "Stop is disabled when ready (no sync running)")
        XCTAssertEqual(stop.label, "Stop")
        XCTAssertTrue(d.validateToolbarItem(items[DirectionAction.goIdentifier]!),
                      "Go is enabled when ready with items")

        XCTAssertTrue(d.validateToolbarItem(profiles))
        XCTAssertEqual(profiles.toolTip, ProfilesHelp.idle.toolTip,
                       "Profiles shows the idle help when ready")
    }

    // MARK: - Syncing

    func test_syncing_stopEnabledRedStop_goDisabled_profilesSyncHelp() {
        let c = makeController()
        c.replaceItems([stateItem("a.txt")])
        c.enterSyncingUI()   // isSyncing = true, phase = .syncing
        let (d, items) = wire(c)
        let stop = items[DirectionAction.stopIdentifier]!
        let profiles = items[DirectionAction.profilesIdentifier]!

        XCTAssertTrue(d.validateToolbarItem(stop), "Stop is enabled during a sync")
        XCTAssertEqual(stop.label, "Stop", "the enabled control is 'Stop', not 'Return to Profiles'")

        XCTAssertFalse(d.validateToolbarItem(items[DirectionAction.goIdentifier]!),
                       "Go is disabled during a sync")

        XCTAssertTrue(d.validateToolbarItem(profiles))
        XCTAssertEqual(profiles.toolTip, ProfilesHelp.synchronizing.toolTip,
                       "Profiles warns a confirmation appears during a sync")
    }

    // MARK: - Spatial stability (positions never change)

    func test_stopTitleAndProfilesLabel_areIdenticalAcrossPhases() {
        // Stop's title is what drives its width; if it stays "Stop" in every phase
        // the item cannot reflow Go. Profiles' label is likewise constant.
        var stopTitles: Set<String> = []
        var profilesLabels: Set<String> = []
        for drive: (ReconcileWindowController) -> Void in [
            { $0.beginInitialScan() },
            { $0.replaceItems([self.stateItem("a.txt")]) },
            { $0.replaceItems([self.stateItem("a.txt")]); $0.enterSyncingUI() },
        ] {
            let c = makeController()
            drive(c)
            let (d, items) = wire(c)
            let stop = items[DirectionAction.stopIdentifier]!
            let profiles = items[DirectionAction.profilesIdentifier]!
            _ = d.validateToolbarItem(stop)
            _ = d.validateToolbarItem(profiles)
            stopTitles.insert(stop.label)
            profilesLabels.insert(profiles.label)
        }
        XCTAssertEqual(stopTitles, ["Stop"], "Stop's title must be 'Stop' in every phase")
        XCTAssertEqual(profilesLabels, ["Profiles"], "Profiles' label must be constant")
    }

    func test_defaultItemOrder_isPhaseIndependent_goBeforeStop() {
        // The default identifier list is static, so item positions do not depend on
        // phase. Prove it does not vary between scanning and syncing, and that Go
        // precedes Stop (the cluster whose reflow #117 was about).
        let scanning = makeController(); scanning.beginInitialScan()
        let syncing = makeController()
        syncing.replaceItems([stateItem("a.txt")]); syncing.enterSyncingUI()

        let toolbar = NSToolbar(identifier: "order")
        let ids1 = wireDelegate(scanning).toolbarDefaultItemIdentifiers(toolbar)
        let ids2 = wireDelegate(syncing).toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertEqual(ids1, ids2, "toolbar item positions must not depend on phase")

        let go = ids1.firstIndex(of: DirectionAction.goIdentifier)
        let stop = ids1.firstIndex(of: DirectionAction.stopIdentifier)
        XCTAssertNotNil(go); XCTAssertNotNil(stop)
        XCTAssertLessThan(go!, stop!, "Go precedes Stop in the fixed layout")
    }

    private func wireDelegate(_ c: ReconcileWindowController) -> ReconcileToolbarDelegate {
        let d = ReconcileToolbarDelegate(); d.controller = c; return d
    }
}
