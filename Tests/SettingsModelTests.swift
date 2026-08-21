import XCTest
@testable import unison_ui_mac

/// Tests for `SettingsModel` — the pure-logic backing for the Settings
/// window. Every test uses an isolated `UserDefaults(suiteName:)` so
/// nothing leaks into the real preference domain.
///
/// The model is responsible for:
///   1. Reading counts (hidden / ordered profiles, frames, toolbars,
///      suppressions) from defaults.
///   2. Resetting each category without touching the others.
///   3. Round-tripping `VersionSuppression` tokens with VersionCheck's
///      stored shape.
final class SettingsModelTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SettingsModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Profile picker layout

    func test_profilePickerCounts_emptyDefaults_returnsZero() {
        let counts = SettingsModel.profilePickerCounts(in: defaults)
        XCTAssertEqual(counts.hidden, 0)
        XCTAssertEqual(counts.ordered, 0)
    }

    func test_profilePickerCounts_populated_returnsLengths() {
        ProfilePreferences(hidden: ["x", "y"],
                           order: ["a", "b", "c"]).save(to: defaults)
        let counts = SettingsModel.profilePickerCounts(in: defaults)
        XCTAssertEqual(counts.hidden, 2)
        XCTAssertEqual(counts.ordered, 3)
    }

    func test_resetProfilePickerLayout_clearsBothKeys() {
        ProfilePreferences(hidden: ["x"], order: ["a", "b"]).save(to: defaults)
        SettingsModel.resetProfilePickerLayout(in: defaults)
        let counts = SettingsModel.profilePickerCounts(in: defaults)
        XCTAssertEqual(counts.hidden, 0)
        XCTAssertEqual(counts.ordered, 0)
    }

    func test_resetProfilePickerLayout_leavesUnrelatedKeysAlone() {
        ProfilePreferences(hidden: ["x"], order: ["a"]).save(to: defaults)
        VersionCheck.Suppression.suppress(
            host: "mac.local", local: "2.54.0", remote: "2.51.0",
            defaults: defaults)
        SettingsModel.resetProfilePickerLayout(in: defaults)
        let suppressions = SettingsModel.versionMismatchSuppressions(in: defaults)
        XCTAssertEqual(suppressions.count, 1, "picker reset must not touch suppressions")
    }

    // MARK: - VersionSuppression token round-trip

    func test_versionSuppression_tokenRoundTrips() {
        let s = SettingsModel.VersionSuppression(
            host: "mac.local",
            localVersion: "2.54.0",
            remoteVersion: "2.51.2"
        )
        XCTAssertEqual(s.token, "mac.local|2.54.0|2.51.2")
        XCTAssertEqual(SettingsModel.VersionSuppression.parse(s.token), s)
    }

    func test_versionSuppression_parseMatchesVersionCheckTokenShape() {
        // VersionCheck.Suppression.token produces the canonical form.
        // SettingsModel must read what VersionCheck wrote — pin the
        // exact byte equality so a future divergence breaks loudly.
        let token = VersionCheck.Suppression.token(
            host: "alice@host", local: "2.54.0", remote: "2.54.3")
        let parsed = SettingsModel.VersionSuppression.parse(token)
        XCTAssertEqual(parsed?.host, "alice@host")
        XCTAssertEqual(parsed?.localVersion, "2.54.0")
        XCTAssertEqual(parsed?.remoteVersion, "2.54.3")
    }

    func test_versionSuppression_parseRejectsMalformed() {
        XCTAssertNil(SettingsModel.VersionSuppression.parse("only-one-field"))
        XCTAssertNil(SettingsModel.VersionSuppression.parse("two|fields"))
        XCTAssertNil(SettingsModel.VersionSuppression.parse("four|fields|here|too"))
    }

    // MARK: - SSH suppressions

    func test_versionMismatchSuppressions_emptyDefaults_returnsEmpty() {
        XCTAssertTrue(SettingsModel.versionMismatchSuppressions(in: defaults).isEmpty)
    }

    func test_versionMismatchSuppressions_returnsParsedTriples() {
        VersionCheck.Suppression.suppress(
            host: "host1", local: "2.54.0", remote: "2.51.0",
            defaults: defaults)
        VersionCheck.Suppression.suppress(
            host: "host2", local: "2.54.0", remote: "2.54.3",
            defaults: defaults)
        let list = SettingsModel.versionMismatchSuppressions(in: defaults)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].host, "host1")
        XCTAssertEqual(list[1].remoteVersion, "2.54.3")
    }

    func test_versionMismatchSuppressions_skipsMalformedTokensSilently() {
        // Direct write to simulate a stray hand-edited plist value.
        defaults.set(["host|2.54.0|2.51.0", "garbage", "also|missing"],
                     forKey: VersionCheck.Suppression.key)
        let list = SettingsModel.versionMismatchSuppressions(in: defaults)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].host, "host")
    }

    func test_removeSuppression_removesOnlyTheTarget() {
        VersionCheck.Suppression.suppress(
            host: "host1", local: "2.54.0", remote: "2.51.0",
            defaults: defaults)
        VersionCheck.Suppression.suppress(
            host: "host2", local: "2.54.0", remote: "2.54.3",
            defaults: defaults)
        let target = SettingsModel.VersionSuppression(
            host: "host1", localVersion: "2.54.0", remoteVersion: "2.51.0")
        SettingsModel.removeSuppression(target, in: defaults)
        let remaining = SettingsModel.versionMismatchSuppressions(in: defaults)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].host, "host2")
    }

    func test_removeSuppression_missingTarget_isANoOp() {
        VersionCheck.Suppression.suppress(
            host: "host1", local: "2.54.0", remote: "2.51.0",
            defaults: defaults)
        let phantom = SettingsModel.VersionSuppression(
            host: "ghost", localVersion: "1.0", remoteVersion: "2.0")
        SettingsModel.removeSuppression(phantom, in: defaults)
        XCTAssertEqual(SettingsModel.versionMismatchSuppressions(in: defaults).count, 1)
    }

    func test_removeSuppression_emptiesThenClearsKeyEntirely() {
        // After removing the only suppression, the underlying key should
        // disappear from defaults (not just become an empty array) — keeps
        // `defaults read` output clean.
        VersionCheck.Suppression.suppress(
            host: "host1", local: "2.54.0", remote: "2.51.0",
            defaults: defaults)
        let target = SettingsModel.VersionSuppression(
            host: "host1", localVersion: "2.54.0", remoteVersion: "2.51.0")
        SettingsModel.removeSuppression(target, in: defaults)
        XCTAssertNil(defaults.object(forKey: VersionCheck.Suppression.key))
    }

    func test_clearAllSuppressions_removesEverythingFromTheKey() {
        for i in 0..<3 {
            VersionCheck.Suppression.suppress(
                host: "host\(i)", local: "2.54.0", remote: "2.51.\(i)",
                defaults: defaults)
        }
        SettingsModel.clearAllSuppressions(in: defaults)
        XCTAssertTrue(SettingsModel.versionMismatchSuppressions(in: defaults).isEmpty)
        XCTAssertNil(defaults.object(forKey: VersionCheck.Suppression.key))
    }

    func test_clearAllSuppressions_leavesUnrelatedKeysAlone() {
        VersionCheck.Suppression.suppress(
            host: "host1", local: "2.54.0", remote: "2.51.0",
            defaults: defaults)
        ProfilePreferences(hidden: ["secret"], order: []).save(to: defaults)
        SettingsModel.clearAllSuppressions(in: defaults)
        let (hidden, _) = SettingsModel.profilePickerCounts(in: defaults)
        XCTAssertEqual(hidden, 1, "suppressions reset must not touch picker layout")
    }

    // MARK: - Window & toolbar layout

    func test_windowAndToolbarCounts_emptyDefaults_returnsZero() {
        let counts = SettingsModel.windowAndToolbarCounts(in: defaults)
        XCTAssertEqual(counts.frames, 0)
        XCTAssertEqual(counts.toolbars, 0)
    }

    func test_windowAndToolbarCounts_countsKnownFramesAndToolbars() {
        // Simulate AppKit's autosave write for two of our window frames
        // and one toolbar config. The values don't have to be realistic
        // frame strings — SettingsModel just checks key presence.
        defaults.set("placeholder", forKey: SettingsModel.windowFrameKey("ProfileWindow"))
        defaults.set("placeholder", forKey: SettingsModel.windowFrameKey("ReconcileWindow"))
        defaults.set(["foo": "bar"],
                     forKey: "NSToolbar Configuration ReconcileToolbar.v4")
        let counts = SettingsModel.windowAndToolbarCounts(in: defaults)
        XCTAssertEqual(counts.frames, 2)
        XCTAssertEqual(counts.toolbars, 1)
    }

    func test_resetWindowAndToolbarLayout_clearsKnownKeys() {
        for name in SettingsModel.windowFrameAutosaveNames {
            defaults.set("placeholder", forKey: SettingsModel.windowFrameKey(name))
        }
        for key in SettingsModel.toolbarConfigurationKeys {
            defaults.set(["foo": "bar"], forKey: key)
        }
        SettingsModel.resetWindowAndToolbarLayout(in: defaults)
        let counts = SettingsModel.windowAndToolbarCounts(in: defaults)
        XCTAssertEqual(counts.frames, 0)
        XCTAssertEqual(counts.toolbars, 0)
    }

    func test_resetWindowAndToolbarLayout_leavesUnknownFramesAlone() {
        // Some other app (or AppKit auto-tracking for a window we don't
        // own) put a frame key in this domain. Our reset must not blast
        // unrelated entries.
        defaults.set("placeholder", forKey: "NSWindow Frame SomeoneElsesWindow")
        defaults.set("placeholder", forKey: SettingsModel.windowFrameKey("ProfileWindow"))
        SettingsModel.resetWindowAndToolbarLayout(in: defaults)
        XCTAssertNotNil(defaults.object(forKey: "NSWindow Frame SomeoneElsesWindow"))
        XCTAssertNil(defaults.object(forKey: SettingsModel.windowFrameKey("ProfileWindow")))
    }

    // MARK: - Catalog completeness

    func test_windowFrameAutosaveNames_includesEveryControllersAutosaveName() {
        // If you add a new windowFrameAutosaveName in a controller,
        // extend this list — otherwise "reset frames" will silently
        // skip the new window. Pinning the exact set so the test fails
        // loudly when a new entry is needed.
        let expected: Set<String> = [
            "ProfileWindow",
            "ProfileEditorWindow",
            "ProfileFormWindow",        // orphaned after the .v2 rename; kept so reset cleans it
            "ProfileFormWindow.v2",
            "ReconcileWindow",
            "DiffWindow",
            "SettingsWindow",
        ]
        XCTAssertEqual(Set(SettingsModel.windowFrameAutosaveNames), expected)
    }

    func test_windowFrameKey_matchesAppKitNamingScheme() {
        XCTAssertEqual(SettingsModel.windowFrameKey("FooWindow"),
                       "NSWindow Frame FooWindow")
    }

    // MARK: - Reconcile display (layoutMode + expandPolicy)

    func test_reconcileLayoutMode_defaultIsNestedCollapsed() {
        // Key absent from defaults → default to nestedCollapsed
        // (matches upstream Unison's default for the equivalent
        // segmented control).
        XCTAssertEqual(SettingsModel.reconcileLayoutMode(in: defaults),
                       .nestedCollapsed)
    }

    func test_reconcileLayoutMode_roundTrip() {
        SettingsModel.setReconcileLayoutMode(.flat, in: defaults)
        XCTAssertEqual(SettingsModel.reconcileLayoutMode(in: defaults), .flat)
        SettingsModel.setReconcileLayoutMode(.nestedFull, in: defaults)
        XCTAssertEqual(SettingsModel.reconcileLayoutMode(in: defaults), .nestedFull)
        SettingsModel.setReconcileLayoutMode(.nestedCollapsed, in: defaults)
        XCTAssertEqual(SettingsModel.reconcileLayoutMode(in: defaults), .nestedCollapsed)
    }

    func test_reconcileLayoutMode_garbageValue_fallsBackToDefault() {
        // Hand-edited plist with a stale enum value shouldn't crash —
        // fall back to the default.
        defaults.set("legacy-mode-name", forKey: SettingsModel.reconcileLayoutModeKey)
        XCTAssertEqual(SettingsModel.reconcileLayoutMode(in: defaults),
                       .nestedCollapsed)
    }

    func test_reconcileExpandPolicy_defaultIsSmart() {
        XCTAssertEqual(SettingsModel.reconcileExpandPolicy(in: defaults), .smart)
    }

    func test_reconcileExpandPolicy_roundTrip() {
        SettingsModel.setReconcileExpandPolicy(.all, in: defaults)
        XCTAssertEqual(SettingsModel.reconcileExpandPolicy(in: defaults), .all)
        SettingsModel.setReconcileExpandPolicy(.rootOnly, in: defaults)
        XCTAssertEqual(SettingsModel.reconcileExpandPolicy(in: defaults), .rootOnly)
        SettingsModel.setReconcileExpandPolicy(.smart, in: defaults)
        XCTAssertEqual(SettingsModel.reconcileExpandPolicy(in: defaults), .smart)
    }

    func test_reconcileExpandPolicy_garbageValue_fallsBackToDefault() {
        defaults.set("aggressive", forKey: SettingsModel.reconcileExpandPolicyKey)
        XCTAssertEqual(SettingsModel.reconcileExpandPolicy(in: defaults), .smart)
    }

    func test_resetReconcileDisplay_clearsBothKeys() {
        SettingsModel.setReconcileLayoutMode(.flat, in: defaults)
        SettingsModel.setReconcileExpandPolicy(.all, in: defaults)
        SettingsModel.resetReconcileDisplay(in: defaults)
        // Back to defaults after reset.
        XCTAssertEqual(SettingsModel.reconcileLayoutMode(in: defaults),
                       .nestedCollapsed)
        XCTAssertEqual(SettingsModel.reconcileExpandPolicy(in: defaults), .smart)
    }

    func test_resetReconcileDisplay_leavesOtherSettingsAlone() {
        SettingsModel.setReconcileLayoutMode(.flat, in: defaults)
        ProfilePreferences(hidden: ["x"], order: ["a"]).save(to: defaults)
        SettingsModel.resetReconcileDisplay(in: defaults)
        let (hidden, ordered) = SettingsModel.profilePickerCounts(in: defaults)
        XCTAssertEqual(hidden, 1,
                       "reconcile reset must not touch picker layout")
        XCTAssertEqual(ordered, 1)
    }

    // MARK: - Sync-completion cues

    func test_notifyOnSyncComplete_defaultsToTrue() {
        XCTAssertTrue(SettingsModel.notifyOnSyncComplete(in: defaults),
                      "absent key must read as opt-out default ON")
    }

    func test_soundOnSyncComplete_defaultsToTrue() {
        XCTAssertTrue(SettingsModel.soundOnSyncComplete(in: defaults),
                      "absent key must read as opt-out default ON")
    }

    func test_notifyOnSyncComplete_roundTripsExplicitFalse() {
        SettingsModel.setNotifyOnSyncComplete(false, in: defaults)
        XCTAssertFalse(SettingsModel.notifyOnSyncComplete(in: defaults),
                       "explicit false must not collapse to the true default")
        SettingsModel.setNotifyOnSyncComplete(true, in: defaults)
        XCTAssertTrue(SettingsModel.notifyOnSyncComplete(in: defaults))
    }

    func test_soundOnSyncComplete_roundTripsExplicitFalse() {
        SettingsModel.setSoundOnSyncComplete(false, in: defaults)
        XCTAssertFalse(SettingsModel.soundOnSyncComplete(in: defaults))
        SettingsModel.setSoundOnSyncComplete(true, in: defaults)
        XCTAssertTrue(SettingsModel.soundOnSyncComplete(in: defaults))
    }

    func test_syncCompletionCues_areIndependent() {
        SettingsModel.setNotifyOnSyncComplete(false, in: defaults)
        XCTAssertTrue(SettingsModel.soundOnSyncComplete(in: defaults),
                      "disabling notification must not affect the sound cue")
        SettingsModel.setSoundOnSyncComplete(false, in: defaults)
        SettingsModel.setNotifyOnSyncComplete(true, in: defaults)
        XCTAssertFalse(SettingsModel.soundOnSyncComplete(in: defaults),
                       "re-enabling notification must not flip the sound cue")
    }

    // MARK: - composeLogfile (per-mode logfile path)

    func test_composeLogfile_sameFile_usesSharedFile_ignoringName() {
        let path = SettingsModel.composeLogfile(
            mode: .sameFile, name: "Ignored.log",
            sharedFile: "/logs/All.log",
            sharedDirectory: "/logs", perProfileFolder: "/per")
        XCTAssertEqual(path, "/logs/All.log")
    }

    func test_composeLogfile_sameDirectory_joinsSharedDirAndName() {
        let path = SettingsModel.composeLogfile(
            mode: .sameDirectory, name: "Photos.log",
            sharedFile: "/logs/All.log",
            sharedDirectory: "/logs", perProfileFolder: "/per")
        XCTAssertEqual(path, "/logs/Photos.log")
    }

    func test_composeLogfile_perProfile_joinsProfileFolderAndName() {
        let path = SettingsModel.composeLogfile(
            mode: .perProfile, name: "Photos.log",
            sharedFile: "/logs/All.log",
            sharedDirectory: "/logs", perProfileFolder: "/Users/me/PhotoLogs")
        XCTAssertEqual(path, "/Users/me/PhotoLogs/Photos.log")
    }
}
