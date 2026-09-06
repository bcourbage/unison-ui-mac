import XCTest
@testable import unison_ui_mac

/// The `unison`-on-PATH classifier, the PATH reconstructions, the action and
/// offer gates, and the admin command builder. Classification is exercised
/// against REAL fixture directories (bundles with Info.plist, a Cellar tree,
/// symlinks, dangling links) through the production filesystem adapter, so the
/// tests prove the layouts, not string comparisons on invented paths.
final class CommandLineToolStatusTests: XCTestCase {

    private var root: String = ""
    private let fs = RealCommandLineToolFileSystem()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "cli-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: fixtures

    /// A bundle with an Info.plist naming `identifier` and an executable cltool.
    @discardableResult
    private func makeBundle(_ name: String, identifier: String, launcher: Bool = true) throws -> String {
        let bundle = root + "/" + name
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(identifier)</string>
        <key>CFBundleExecutable</key><string>unison-ui-mac</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try plist.write(toFile: bundle + "/Contents/Info.plist", atomically: true, encoding: .utf8)
        if launcher {
            try makeExecutable(bundle + "/Contents/MacOS/cltool", body: "exit 0")
        }
        return bundle
    }

    private func makeExecutable(_ path: String, body: String) throws {
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func makeBin(_ name: String) throws -> String {
        let dir = root + "/" + name
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    private func env(thisBundle: String, brewPrefix: String? = nil, receipt: Bool = false) -> CommandLineToolStatus.Environment {
        .init(thisBundlePath: thisBundle, brewPrefix: brewPrefix, caskroomReceiptExists: receipt)
    }

    private func classify(_ entry: String, _ e: CommandLineToolStatus.Environment) -> CommandLineToolClassification? {
        CommandLineToolStatus.classify(entryAtPath: entry, environment: e, fs: fs)?.classification
    }

    // MARK: classification, one fixture per case

    func test_thisInstallation_andStoredTargetIsRecorded() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin"); try link(bin + "/unison", to: app + "/Contents/MacOS/cltool")
        let entry = CommandLineToolStatus.classify(entryAtPath: bin + "/unison", environment: env(thisBundle: app), fs: fs)
        XCTAssertEqual(entry?.classification, .thisInstallation)
        XCTAssertEqual(entry?.storedLinkTarget, app + "/Contents/MacOS/cltool")
    }

    func test_otherCopyOfThisApp() throws {
        let this = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let other = try makeBundle("Debug.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin"); try link(bin + "/unison", to: other + "/Contents/MacOS/cltool")
        guard case .otherCopyOfThisApp(let bundlePath)? = classify(bin + "/unison", env(thisBundle: this)) else {
            return XCTFail("expected otherCopyOfThisApp")
        }
        XCTAssertEqual(fs.realPath(ofPath: bundlePath), fs.realPath(ofPath: other))
    }

    func test_homebrewManaged_requiresPrefixBinAndReceipt() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let prefix = root + "/opt/homebrew"
        let bin = try makeBin("opt/homebrew/bin"); try link(bin + "/unison", to: app + "/Contents/MacOS/cltool")
        XCTAssertEqual(classify(bin + "/unison", env(thisBundle: app, brewPrefix: prefix, receipt: false)), .thisInstallation)
        guard case .homebrewManaged? = classify(bin + "/unison", env(thisBundle: app, brewPrefix: prefix, receipt: true)) else {
            return XCTFail("expected homebrewManaged")
        }
        let other = try makeBin("usr/local/bin"); try link(other + "/unison", to: app + "/Contents/MacOS/cltool")
        XCTAssertEqual(classify(other + "/unison", env(thisBundle: app, brewPrefix: prefix, receipt: true)), .thisInstallation)
    }

    func test_brewFormula_underAResolvedPrefix() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let prefix = root + "/opt/homebrew"   // under /var → realpath /private/var
        let cellar = try makeBin("opt/homebrew/Cellar/unison/2.54.0/bin"); try makeExecutable(cellar + "/unison", body: "exit 0")
        let bin = try makeBin("opt/homebrew/bin"); try link(bin + "/unison", to: "../Cellar/unison/2.54.0/bin/unison")
        guard case .brewFormula(let resolved)? = classify(bin + "/unison", env(thisBundle: app, brewPrefix: prefix, receipt: true)) else {
            return XCTFail("expected brewFormula")
        }
        XCTAssertTrue(resolved.hasSuffix("/Cellar/unison/2.54.0/bin/unison"))
    }

    func test_upstreamApp() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let upstream = try makeBundle("Unison.app", identifier: CommandLineToolStatus.upstreamBundleIdentifier)
        let bin = try makeBin("usr/local/bin"); try link(bin + "/unison", to: upstream + "/Contents/MacOS/cltool")
        guard case .upstreamApp(let bundlePath)? = classify(bin + "/unison", env(thisBundle: app)) else {
            return XCTFail("expected upstreamApp")
        }
        XCTAssertEqual(fs.realPath(ofPath: bundlePath), fs.realPath(ofPath: upstream))
    }

    func test_danglingLauncherPath_vs_danglingOther() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin")
        let target = "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"
        try link(bin + "/unison", to: target)
        XCTAssertEqual(classify(bin + "/unison", env(thisBundle: app)),
                       .danglingLauncherPath(storedTarget: target, resolvedTarget: target))
        let bin2 = try makeBin("bin2")
        try link(bin2 + "/unison", to: "/Applications/Unison.app/Contents/MacOS/cltool")
        XCTAssertEqual(classify(bin2 + "/unison", env(thisBundle: app)),
                       .danglingOther(target: "/Applications/Unison.app/Contents/MacOS/cltool"))
    }

    func test_danglingRelativeTarget_keepsStoredForm_andResolvesForDisplay() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin")
        let stored = "../gone/unison-ui-mac.app/Contents/MacOS/cltool"
        try link(bin + "/unison", to: stored)
        XCTAssertEqual(classify(bin + "/unison", env(thisBundle: app)),
                       .danglingLauncherPath(storedTarget: stored, resolvedTarget: bin + "/" + stored))
    }

    func test_other_plainExecutable_hasNoStoredTarget() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin"); try makeExecutable(bin + "/unison", body: "exit 0")
        let entry = CommandLineToolStatus.classify(entryAtPath: bin + "/unison", environment: env(thisBundle: app), fs: fs)
        guard case .other? = entry?.classification else { return XCTFail("expected other") }
        XCTAssertNil(entry?.storedLinkTarget)
    }

    func test_launcherInBundleWithForeignIdentifier_isOther() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let foreign = try makeBundle("Foreign.app", identifier: "com.example.other")
        let bin = try makeBin("bin"); try link(bin + "/unison", to: foreign + "/Contents/MacOS/cltool")
        guard case .other? = classify(bin + "/unison", env(thisBundle: app)) else { return XCTFail("expected other") }
    }

    func test_noEntry_isNil() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin")
        XCTAssertNil(classify(bin + "/unison", env(thisBundle: app)))
    }

    // MARK: scanning a PATH

    func test_scan_firstEntryIsDangling_executingIsLaterFormula() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let prefix = root + "/opt/homebrew"
        let broken = try makeBin("usr/local/bin")
        try link(broken + "/unison", to: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool")
        let cellar = try makeBin("opt/homebrew/Cellar/unison/2.54.0/bin"); try makeExecutable(cellar + "/unison", body: "exit 0")
        let brewBin = try makeBin("opt/homebrew/bin"); try link(brewBin + "/unison", to: "../Cellar/unison/2.54.0/bin/unison")

        let status = CommandLineToolStatus.scan(
            searchPath: [broken, brewBin, "/nonexistent"], label: "Terminal", caveat: "",
            environment: env(thisBundle: app, brewPrefix: prefix), fs: fs)
        XCTAssertEqual(status.first?.path, broken + "/unison")
        guard case .danglingLauncherPath? = status.first?.classification else { return XCTFail("first should be the dangling link") }
        XCTAssertEqual(status.executingWhenDifferent?.path, brewBin + "/unison")
        guard case .brewFormula? = status.executingWhenDifferent?.classification else { return XCTFail("executing should be the formula") }
        XCTAssertFalse(status.isKnownEmpty)
    }

    func test_scan_firstIsExecuting_reportsNoDifference() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin"); try link(bin + "/unison", to: app + "/Contents/MacOS/cltool")
        let status = CommandLineToolStatus.scan(searchPath: [bin], label: "", caveat: "", environment: env(thisBundle: app), fs: fs)
        XCTAssertEqual(status.first?.classification, .thisInstallation)
        XCTAssertNil(status.executingWhenDifferent)
    }

    func test_scan_knownEmpty_vs_unknownPath() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let empty = CommandLineToolStatus.scan(searchPath: [root + "/nothing"], label: "", caveat: "", environment: env(thisBundle: app), fs: fs)
        XCTAssertNil(empty.first); XCTAssertTrue(empty.isKnownEmpty)
        let unknown = CommandLineToolStatus.scan(searchPath: nil, label: "", caveat: "", environment: env(thisBundle: app), fs: fs)
        XCTAssertNil(unknown.first); XCTAssertFalse(unknown.isKnownEmpty)
    }

    // MARK: PATH reconstructions

    func test_parsePathsFile() {
        XCTAssertEqual(CommandLineToolStatus.parsePathsFile("/usr/local/bin\n/usr/bin\n\n  /bin  \n"),
                       ["/usr/local/bin", "/usr/bin", "/bin"])
    }

    func test_remoteCommandSearchPath_etcPathsThenPathsD_inNameOrder_deduplicated() throws {
        let etc = root + "/etc"
        try FileManager.default.createDirectory(atPath: etc + "/paths.d", withIntermediateDirectories: true)
        try "/usr/local/bin\n/usr/bin\n/bin\n".write(toFile: etc + "/paths", atomically: true, encoding: .utf8)
        try "/opt/tool/bin\n".write(toFile: etc + "/paths.d/20-tool", atomically: true, encoding: .utf8)
        try "/usr/bin\n/opt/a/bin\n".write(toFile: etc + "/paths.d/10-a", atomically: true, encoding: .utf8)
        let path = CommandLineToolStatus.remoteCommandSearchPath(fs: fs, etcPaths: etc + "/paths", etcPathsD: etc + "/paths.d")
        XCTAssertEqual(path, ["/usr/local/bin", "/usr/bin", "/bin", "/opt/a/bin", "/opt/tool/bin"])
    }

    func test_splitSearchPath_dropsEmptyEntries() {
        XCTAssertEqual(CommandLineToolStatus.splitSearchPath("/a::/b:"), ["/a", "/b"])
    }

    func test_loginShellSearchPath_withSh_returnsItsPath() {
        let path = CommandLineToolStatus.loginShellSearchPath(shell: "/bin/sh", timeout: 10)
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.isEmpty ?? true)
    }

    func test_loginShellSearchPath_missingShell_isNil() {
        XCTAssertNil(CommandLineToolStatus.loginShellSearchPath(shell: root + "/no-such-shell", timeout: 2))
    }

    func test_loginShellSearchPath_stalledShell_returnsNilWithinTheTimeout() throws {
        // A "shell" that sleeps past the timeout, then would print a PATH.
        let slow = root + "/slow-shell"
        try makeExecutable(slow, body: "sleep 3; printf /late/bin")
        let start = Date()
        let path = CommandLineToolStatus.loginShellSearchPath(shell: slow, timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(path, "a stalled probe must not be reported as a PATH")
        XCTAssertLessThan(elapsed, 1.5, "the timeout must bound the wait; took \(elapsed)s")
    }

    func test_loginShellSearchPath_nonZeroExit_isNil() throws {
        let failing = root + "/failing-shell"
        try makeExecutable(failing, body: "printf /x/bin; exit 3")
        XCTAssertNil(CommandLineToolStatus.loginShellSearchPath(shell: failing, timeout: 5))
    }

    // MARK: action gate

    private func entry(_ c: CommandLineToolClassification, path: String = "/x/unison", stored: String? = nil) -> CommandLineToolEntry {
        CommandLineToolEntry(path: path, classification: c, storedLinkTarget: stored)
    }

    private func ctx(_ first: CommandLineToolEntry?, known: Bool = true,
                     executing: CommandLineToolEntry? = nil) -> CommandLineToolContextStatus {
        CommandLineToolContextStatus(label: "", caveat: "", searchPath: known ? ["/x"] : nil,
                                     first: first, executingWhenDifferent: executing)
    }

    func test_action_installOnlyWhenBothContextsKnownAndEmpty() {
        XCTAssertEqual(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil), ctx(nil)]), .install)
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil), ctx(entry(.brewFormula(resolvedPath: "/c")))]))
        // An unobtained PATH is not an absence.
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil, known: false), ctx(nil)]))
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil), ctx(nil, known: false)]))
    }

    func test_action_repairUsesTheDetectedLinkPath_andCarriesTargetAndDisplaced() {
        let displaced = entry(.brewFormula(resolvedPath: "/c"), path: "/opt/homebrew/bin/unison")
        let broken = entry(.danglingLauncherPath(storedTarget: "../old/cltool", resolvedTarget: "/home/bin/../old/cltool"),
                           path: "/home/bin/unison", stored: "../old/cltool")
        XCTAssertEqual(CommandLineToolActionPolicy.availableAction(contexts: [ctx(broken, executing: displaced), ctx(nil)]),
                       .repair(linkPath: "/home/bin/unison", oldTarget: "../old/cltool", displacing: "/opt/homebrew/bin/unison"))
    }

    func test_action_removeOnlyForThisInstallation_withItsStoredTarget() {
        let mine = entry(.thisInstallation, path: "/usr/local/bin/unison", stored: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool")
        XCTAssertEqual(CommandLineToolActionPolicy.availableAction(contexts: [ctx(mine), ctx(nil)]),
                       .remove(linkPath: "/usr/local/bin/unison", expectedTarget: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"))
        for c in [CommandLineToolClassification.otherCopyOfThisApp(bundlePath: "/o"),
                  .homebrewManaged(bundlePath: "/h"), .brewFormula(resolvedPath: "/c"),
                  .upstreamApp(bundlePath: "/u"), .danglingOther(target: "/d"), .other(resolvedPath: "/z")] {
            XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(entry(c)), ctx(nil)]), "\(c)")
        }
    }

    // MARK: admin commands re-verify at execution time

    func test_adminShellCommand_install_neverOverwrites() {
        let launcher = "/Applications/It's here.app/Contents/MacOS/cltool"
        XCTAssertEqual(CommandLineToolActionPolicy.adminShellCommand(for: .install, launcherPath: launcher),
                       "/bin/mkdir -p '/usr/local/bin' && /bin/ln -s '/Applications/It'\\''s here.app/Contents/MacOS/cltool' '/usr/local/bin/unison'")
    }

    func test_adminShellCommand_repair_actsOnTheDetectedLink_andChecksItsStoredTarget() {
        let cmd = CommandLineToolActionPolicy.adminShellCommand(
            for: .repair(linkPath: "/home/bin/unison", oldTarget: "../old/cltool", displacing: nil), launcherPath: "/L/cltool")
        XCTAssertEqual(cmd,
            "[ -L '/home/bin/unison' ] && ! [ -e '/home/bin/unison' ] && [ \"$(/usr/bin/readlink '/home/bin/unison')\" = '../old/cltool' ] && /bin/ln -sfn '/L/cltool' '/home/bin/unison'")
        XCTAssertFalse(cmd.contains("/usr/local/bin/unison"), "repair must not touch a path other than the detected one")
    }

    func test_adminShellCommand_remove_checksOwnershipBeforeDeleting() {
        let cmd = CommandLineToolActionPolicy.adminShellCommand(
            for: .remove(linkPath: "/usr/local/bin/unison", expectedTarget: "/A/unison-ui-mac.app/Contents/MacOS/cltool"), launcherPath: "/L")
        XCTAssertEqual(cmd,
            "[ -L '/usr/local/bin/unison' ] && [ \"$(/usr/bin/readlink '/usr/local/bin/unison')\" = '/A/unison-ui-mac.app/Contents/MacOS/cltool' ] && /bin/rm '/usr/local/bin/unison'")
    }

    /// Run the generated commands unprivileged against fixtures: they must act
    /// only when their preconditions hold and change nothing otherwise.
    func test_adminShellCommands_executeOnlyWhenPreconditionsHold() throws {
        let bin = try makeBin("bin")
        let launcher = root + "/L/cltool"; try makeBin("L"); try makeExecutable(launcher, body: "exit 0")
        func sh(_ cmd: String) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        // Repair: dangling link with the expected target → replaced.
        try link(bin + "/unison", to: "../gone/cltool")
        XCTAssertEqual(sh(CommandLineToolActionPolicy.adminShellCommand(
            for: .repair(linkPath: bin + "/unison", oldTarget: "../gone/cltool", displacing: nil), launcherPath: launcher)), 0)
        XCTAssertEqual(fs.linkTarget(atPath: bin + "/unison"), launcher)
        // Repair: link now resolves → refused, unchanged.
        XCTAssertNotEqual(sh(CommandLineToolActionPolicy.adminShellCommand(
            for: .repair(linkPath: bin + "/unison", oldTarget: launcher, displacing: nil), launcherPath: "/elsewhere")), 0)
        XCTAssertEqual(fs.linkTarget(atPath: bin + "/unison"), launcher)
        // Remove: stored target differs from the expected one → refused, link kept.
        XCTAssertNotEqual(sh(CommandLineToolActionPolicy.adminShellCommand(
            for: .remove(linkPath: bin + "/unison", expectedTarget: "/somebody/else"), launcherPath: launcher)), 0)
        XCTAssertTrue(fs.entryExists(atPath: bin + "/unison"))
        // Remove: expected target matches → deleted.
        XCTAssertEqual(sh(CommandLineToolActionPolicy.adminShellCommand(
            for: .remove(linkPath: bin + "/unison", expectedTarget: launcher), launcherPath: launcher)), 0)
        XCTAssertFalse(fs.entryExists(atPath: bin + "/unison"))
        // Remove: a regular file at the path is not a link → refused, file kept.
        try makeExecutable(bin + "/unison", body: "exit 0")
        XCTAssertNotEqual(sh(CommandLineToolActionPolicy.adminShellCommand(
            for: .remove(linkPath: bin + "/unison", expectedTarget: launcher), launcherPath: launcher)), 0)
        XCTAssertTrue(fs.entryExists(atPath: bin + "/unison"))
    }

    func test_appleScript_escapesQuotesAndBackslashes() {
        let s = CommandLineToolActionPolicy.appleScript(runningAsAdmin: "echo \"a\\b\"")
        XCTAssertEqual(s, "do shell script \"echo \\\"a\\\\b\\\"\" with administrator privileges")
    }

    // MARK: first-launch offer gate

    func test_offer_installWhenBothKnownEmpty_silentWhenSuppressedOrTestHost() {
        let empty = [ctx(nil), ctx(nil)]
        XCTAssertEqual(CommandLineToolPromptPolicy.offer(contexts: empty, suppressed: false, isTestHost: false), .install)
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: empty, suppressed: true, isTestHost: false))
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: empty, suppressed: false, isTestHost: true))
    }

    func test_offer_silentWhenAPathIsUnknown() {
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [ctx(nil, known: false), ctx(nil)], suppressed: false, isTestHost: false))
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [ctx(nil), ctx(nil, known: false)], suppressed: false, isTestHost: false))
    }

    func test_offer_repairCarriesLinkPathAndDisplacedCommand() {
        let displaced = entry(.brewFormula(resolvedPath: "/c"), path: "/opt/homebrew/bin/unison")
        let broken = entry(.danglingLauncherPath(storedTarget: "/old/cltool", resolvedTarget: "/old/cltool"),
                           path: "/usr/local/bin/unison", stored: "/old/cltool")
        XCTAssertEqual(CommandLineToolPromptPolicy.offer(contexts: [ctx(broken, executing: displaced), ctx(nil)], suppressed: false, isTestHost: false),
                       .repair(linkPath: "/usr/local/bin/unison", oldTarget: "/old/cltool", displacing: "/opt/homebrew/bin/unison"))
    }

    func test_offer_silentWhenAnythingElseOwnsTheName() {
        for c in [CommandLineToolClassification.thisInstallation, .homebrewManaged(bundlePath: "/h"),
                  .brewFormula(resolvedPath: "/c"), .upstreamApp(bundlePath: "/u"),
                  .danglingOther(target: "/d"), .other(resolvedPath: "/z"), .otherCopyOfThisApp(bundlePath: "/o")] {
            XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [ctx(entry(c)), ctx(nil)], suppressed: false, isTestHost: false), "\(c)")
            XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [ctx(nil), ctx(entry(c))], suppressed: false, isTestHost: false), "\(c) remote")
        }
    }

    func test_suppression_persistsInDefaults() {
        let suite = "cli-prompt-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CommandLineToolPromptPolicy.isSuppressed(defaults: defaults))
        CommandLineToolPromptPolicy.suppress(defaults: defaults)
        XCTAssertTrue(CommandLineToolPromptPolicy.isSuppressed(defaults: defaults))
    }

    // MARK: wording

    func test_describe_entry_and_context() {
        XCTAssertEqual(CommandLineToolWording.describe(nil as CommandLineToolEntry?), "No unison command on this PATH.")
        let e = entry(.danglingLauncherPath(storedTarget: "../g/cltool", resolvedTarget: "/gone/cltool"), path: "/usr/local/bin/unison")
        XCTAssertEqual(CommandLineToolWording.describe(e),
                       "/usr/local/bin/unison is a broken link to a former copy of this app's command (/gone/cltool).")
        let unknown = CommandLineToolContextStatus(label: "Terminal", caveat: "The login shell did not report its PATH.",
                                                   searchPath: nil, first: nil, executingWhenDifferent: nil)
        XCTAssertEqual(CommandLineToolWording.describe(unknown), "The login shell did not report its PATH.")
        let displaced = entry(.brewFormula(resolvedPath: "/c"), path: "/opt/homebrew/bin/unison")
        let withDisplaced = CommandLineToolContextStatus(label: "", caveat: "C.", searchPath: ["/x"], first: e, executingWhenDifferent: displaced)
        XCTAssertTrue(CommandLineToolWording.describe(withDisplaced).contains("The command that actually runs is /opt/homebrew/bin/unison is the Homebrew unison formula"))
    }

    func test_repairDetails_namesTheDisplacedCommand() {
        let text = CommandLineToolWording.repairDetails(linkPath: "/usr/local/bin/unison", oldTarget: "/old", displacing: "/opt/homebrew/bin/unison")
        XCTAssertTrue(text.contains("/usr/local/bin/unison"))
        XCTAssertTrue(text.contains("/old"))
        XCTAssertTrue(text.contains("/opt/homebrew/bin/unison"))
        XCTAssertFalse(CommandLineToolWording.repairDetails(linkPath: "/l", oldTarget: "/o", displacing: nil).contains("currently runs"))
    }
}
