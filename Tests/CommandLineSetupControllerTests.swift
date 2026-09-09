import XCTest
@testable import unison_ui_mac

/// PR4: the preference and its 0.7.0 migration, the outcome status lines, Refresh
/// aging, the facts builder, and a coordinator add-then-remove round trip.
final class CommandLineSetupControllerTests: XCTestCase {

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "clctl-\(UUID().uuidString)")! }

    // MARK: Preference migration matrix

    func test_preference_migration_matrix() {
        // No prior key -> on; old key removed.
        var d = freshDefaults()
        XCTAssertTrue(CommandLineSetupPreference.keepInTerminal(defaults: d))
        XCTAssertNil(d.object(forKey: CommandLineSetupPreference.legacyDoNotAskKey))

        // doNotAsk true -> off.
        d = freshDefaults()
        d.set(true, forKey: CommandLineSetupPreference.legacyDoNotAskKey)
        XCTAssertFalse(CommandLineSetupPreference.keepInTerminal(defaults: d))
        XCTAssertNil(d.object(forKey: CommandLineSetupPreference.legacyDoNotAskKey))

        // doNotAsk false -> on.
        d = freshDefaults()
        d.set(false, forKey: CommandLineSetupPreference.legacyDoNotAskKey)
        XCTAssertTrue(CommandLineSetupPreference.keepInTerminal(defaults: d))
        XCTAssertNil(d.object(forKey: CommandLineSetupPreference.legacyDoNotAskKey))

        // Explicit off is honored (no migration).
        d = freshDefaults()
        CommandLineSetupPreference.setKeepInTerminal(false, defaults: d)
        XCTAssertFalse(CommandLineSetupPreference.keepInTerminal(defaults: d))
    }

    // MARK: Status lines

    func test_afterWrite_outcomes() {
        XCTAssertEqual(CommandLineSetupStatusLine.afterWrite(.mutated, postResolution: .thisApp), "Entry written and selected.")
        XCTAssertEqual(CommandLineSetupStatusLine.afterWrite(.mutated, postResolution: .anotherUnison(path: "/x")),
                       "Entry written; your shell still selects another unison.")
        XCTAssertEqual(CommandLineSetupStatusLine.afterWrite(.mutated, postResolution: .none),
                       "Entry written; your shell selects no unison.")
        XCTAssertEqual(CommandLineSetupStatusLine.afterWrite(.mutated, postResolution: .couldNotCheck),
                       "Entry written; command selection could not be checked.")
        XCTAssertEqual(CommandLineSetupStatusLine.afterWrite(.mutatedReadBackFailed, postResolution: .thisApp),
                       "Entry written; the result could not be read back.")
        XCTAssertEqual(CommandLineSetupStatusLine.afterWrite(.uncertain(reason: "x"), postResolution: .thisApp),
                       "The file operation's result could not be established.")
        XCTAssertEqual(CommandLineSetupStatusLine.afterWrite(.notMutated(reason: "R"), postResolution: .thisApp), "R")
    }

    func test_afterRewrite_andRemove() {
        XCTAssertEqual(CommandLineSetupStatusLine.afterRewrite(.mutated), "PATH entry updated to this app's location.")
        let (a, b) = CommandLineSetupStatusLine.afterRemove(.mutated, postResolution: .none)
        XCTAssertEqual(a, "PATH entry removed."); XCTAssertEqual(b, "Your shell now selects no unison.")
        let (c, d) = CommandLineSetupStatusLine.afterRemove(.notMutated(reason: "R"), postResolution: .none)
        XCTAssertEqual(c, "R"); XCTAssertNil(d)
    }

    // MARK: Aging

    func test_aging() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CommandLineSetupAging.checkedText(lastChecked: nil, now: base), "Not checked yet")
        XCTAssertEqual(CommandLineSetupAging.checkedText(lastChecked: base, now: base.addingTimeInterval(30)), "Checked just now")
        XCTAssertEqual(CommandLineSetupAging.checkedText(lastChecked: base, now: base.addingTimeInterval(60)), "Checked 1 minute ago")
        XCTAssertEqual(CommandLineSetupAging.checkedText(lastChecked: base, now: base.addingTimeInterval(180)), "Checked 3 minutes ago")
        XCTAssertEqual(CommandLineSetupAging.checkedText(lastChecked: base, now: base.addingTimeInterval(3600)), "Checked 1 hour ago")
    }

    // MARK: Facts builder

    func test_factsBuilder_blockPresence() {
        let fs = RealCommandLineToolFileSystem()
        let binDir = "/Applications/unison-ui-mac.app/Contents/SharedSupport/bin"
        let manualChoice = CommandLineSetupFileSelection.otherChoice()
        let f1 = CommandLineSetupFactsBuilder.build(resolution: .none, bundlePreconditionOK: true,
                                                    fileChoice: manualChoice, boundEvaluation: nil,
                                                    thisBinDirectory: binDir, fs: fs)
        XCTAssertNotNil(f1.manualSetupReason)

        let autoChoice = CommandLineSetupFileChoice(shell: .zsh, file: "/h/.zprofile", automatic: true,
                                                    manualReason: nil, createIfAbsent: false)
        let f2 = CommandLineSetupFactsBuilder.build(resolution: .none, bundlePreconditionOK: true,
                                                    fileChoice: autoChoice, boundEvaluation: .appendable,
                                                    thisBinDirectory: binDir, fs: fs)
        XCTAssertEqual(f2.block, .none)

        let f3 = CommandLineSetupFactsBuilder.build(
            resolution: .thisApp, bundlePreconditionOK: true, fileChoice: autoChoice,
            boundEvaluation: .rewritable(beginLine: 1, endLine: 4, currentDirectory: binDir),
            thisBinDirectory: binDir, fs: fs)
        XCTAssertEqual(f3.block, .ownedCurrent)

        let f4 = CommandLineSetupFactsBuilder.build(
            resolution: .thisApp, bundlePreconditionOK: true, fileChoice: autoChoice,
            boundEvaluation: .rewritable(beginLine: 1, endLine: 4, currentDirectory: "/gone/Contents/SharedSupport/bin"),
            thisBinDirectory: binDir, fs: fs)
        XCTAssertEqual(f4.block, .ownedElsewhere(.absentOrNotThisApp))
    }

    // MARK: Coordinator round trip (zsh, real temp files)

    private func makeFakeBundle(in root: URL) -> URL {
        let app = root.appendingPathComponent("unison-ui-mac.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        let bin = app.appendingPathComponent("Contents/SharedSupport/bin")
        try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: macos.appendingPathComponent("cltool").path,
                                       contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("unison").path,
                                                    withDestinationPath: "../../MacOS/cltool")
        // The Info.plist so bundleIdentifier reads our id (not strictly needed here).
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>\(CommandLineToolStatus.ourBundleIdentifier)</string></dict></plist>"
        try? plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return app
    }

    func test_coordinator_zsh_addThenRemove_roundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clcoord-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeFakeBundle(in: root)
        let zprofile = home.appendingPathComponent(".zprofile")
        try "export FOO=1\n".write(to: zprofile, atomically: true, encoding: .utf8)

        let defaults = freshDefaults()
        let fs = RealCommandLineToolFileSystem()
        let env = CommandLineSetupEnvironment(
            accountRecord: { .init(loginShellPath: "/bin/zsh", homeDirectory: home.path) },
            resolvedUnison: { _, _ in .empty },
            fishConfigDirectory: { _ in nil },
            etcZshenvExists: { false },
            homeZshenvExists: { _ in false },
            etcZprofileContents: { CommandLineSetupFileSelection.stockZprofileMacOS26 },
            zdotdirLaunchd: { .absent },
            zdotdirAppEnvironment: { false },
            parses: { _, _ in true },
            metadataOK: { _ in true })

        let report = CommandLineSetupCoordinator.status(bundleURL: app, environment: env, fs: fs, defaults: defaults)
        XCTAssertEqual(report.state.row, 12)  // no block, resolution none
        XCTAssertEqual(report.state.action, .add)

        let added = CommandLineSetupCoordinator.performAdd(report: report, bundleURL: app, rewrite: false,
                                                           environment: env, fs: fs, defaults: defaults)
        let afterAdd = try String(contentsOf: zprofile, encoding: .utf8)
        XCTAssertTrue(afterAdd.hasPrefix("export FOO=1\n"), "original text preserved")
        XCTAssertTrue(afterAdd.contains(CommandLineSetupBlock.beginMarker), "block written")
        XCTAssertTrue(CommandLineSetupPreference.keepInTerminal(defaults: defaults), "preference turned on")
        XCTAssertEqual(added.refreshed.state.action, .remove)  // owned block now present

        let removed = CommandLineSetupCoordinator.performRemove(report: added.refreshed, bundleURL: app,
                                                                environment: env, fs: fs, defaults: defaults)
        XCTAssertEqual(removed.statusLine, "PATH entry removed.")
        XCTAssertEqual(try String(contentsOf: zprofile, encoding: .utf8), "export FOO=1\n", "block removed, original byte-identical")
        XCTAssertFalse(CommandLineSetupPreference.keepInTerminal(defaults: defaults), "preference turned off")
        XCTAssertNil(CommandLineSetupRecordStore.confirmed(defaults: defaults), "record cleared")
    }
}
