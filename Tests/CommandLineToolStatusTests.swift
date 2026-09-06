import XCTest
@testable import unison_ui_mac

/// The `unison`-on-PATH classifier, the PATH reconstructions, the action and
/// prompt gates, and the admin command builder. Classification is exercised
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
            try makeExecutable(bundle + "/Contents/MacOS/cltool")
        }
        return bundle
    }

    private func makeExecutable(_ path: String) throws {
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
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
        CommandLineToolStatus.classify(entryAtPath: entry, environment: e, fs: fs)
    }

    // MARK: classification, one fixture per case

    func test_thisInstallation() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin"); try link(bin + "/unison", to: app + "/Contents/MacOS/cltool")
        XCTAssertEqual(classify(bin + "/unison", env(thisBundle: app)), .thisInstallation)
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
        // Under the prefix, no receipt: location alone is not ownership.
        XCTAssertEqual(classify(bin + "/unison", env(thisBundle: app, brewPrefix: prefix, receipt: false)), .thisInstallation)
        // With the receipt: managed.
        guard case .homebrewManaged? = classify(bin + "/unison", env(thisBundle: app, brewPrefix: prefix, receipt: true)) else {
            return XCTFail("expected homebrewManaged")
        }
        // Receipt but the link is elsewhere: not managed.
        let other = try makeBin("usr/local/bin"); try link(other + "/unison", to: app + "/Contents/MacOS/cltool")
        XCTAssertEqual(classify(other + "/unison", env(thisBundle: app, brewPrefix: prefix, receipt: true)), .thisInstallation)
    }

    func test_brewFormula() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let prefix = root + "/opt/homebrew"
        let cellar = try makeBin("opt/homebrew/Cellar/unison/2.54.0/bin"); try makeExecutable(cellar + "/unison")
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
        try link(bin + "/unison", to: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool")
        XCTAssertEqual(classify(bin + "/unison", env(thisBundle: app)),
                       .danglingLauncherPath(target: "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"))
        let bin2 = try makeBin("bin2")
        try link(bin2 + "/unison", to: "/Applications/Unison.app/Contents/MacOS/cltool")
        XCTAssertEqual(classify(bin2 + "/unison", env(thisBundle: app)),
                       .danglingOther(target: "/Applications/Unison.app/Contents/MacOS/cltool"))
    }

    func test_danglingRelativeTarget_isResolvedAgainstTheLinkDirectory() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin")
        try link(bin + "/unison", to: "../gone/unison-ui-mac.app/Contents/MacOS/cltool")
        guard case .danglingLauncherPath(let target)? = classify(bin + "/unison", env(thisBundle: app)) else {
            return XCTFail("expected danglingLauncherPath")
        }
        XCTAssertEqual(target, bin + "/../gone/unison-ui-mac.app/Contents/MacOS/cltool")
    }

    func test_other_plainExecutable() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin"); try makeExecutable(bin + "/unison")
        guard case .other? = classify(bin + "/unison", env(thisBundle: app)) else { return XCTFail("expected other") }
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
        let cellar = try makeBin("opt/homebrew/Cellar/unison/2.54.0/bin"); try makeExecutable(cellar + "/unison")
        let brewBin = try makeBin("opt/homebrew/bin"); try link(brewBin + "/unison", to: "../Cellar/unison/2.54.0/bin/unison")

        let status = CommandLineToolStatus.scan(
            searchPath: [broken, brewBin, "/nonexistent"], label: "Terminal", caveat: "",
            environment: env(thisBundle: app, brewPrefix: prefix), fs: fs)
        XCTAssertEqual(status.first?.path, broken + "/unison")
        guard case .danglingLauncherPath? = status.first?.classification else { return XCTFail("first should be the dangling link") }
        XCTAssertEqual(status.executingWhenDifferent?.path, brewBin + "/unison")
        guard case .brewFormula? = status.executingWhenDifferent?.classification else { return XCTFail("executing should be the formula") }
    }

    func test_scan_firstIsExecuting_reportsNoDifference() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let bin = try makeBin("bin"); try link(bin + "/unison", to: app + "/Contents/MacOS/cltool")
        let status = CommandLineToolStatus.scan(searchPath: [bin], label: "", caveat: "", environment: env(thisBundle: app), fs: fs)
        XCTAssertEqual(status.first?.classification, .thisInstallation)
        XCTAssertNil(status.executingWhenDifferent)
    }

    func test_scan_emptyPath() throws {
        let app = try makeBundle("This.app", identifier: CommandLineToolStatus.ourBundleIdentifier)
        let status = CommandLineToolStatus.scan(searchPath: [root + "/nothing"], label: "", caveat: "", environment: env(thisBundle: app), fs: fs)
        XCTAssertNil(status.first)
        XCTAssertNil(status.executingWhenDifferent)
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

    func test_loginShellSearchPath_withShTrueBinary_returnsItsPath() {
        // /bin/sh -l -c 'printf %s "$PATH"' works without any user rc files.
        let path = CommandLineToolStatus.loginShellSearchPath(shell: "/bin/sh", timeout: 10)
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.isEmpty ?? true)
    }

    func test_loginShellSearchPath_missingShell_isNil() {
        XCTAssertNil(CommandLineToolStatus.loginShellSearchPath(shell: root + "/no-such-shell", timeout: 2))
    }

    // MARK: action gate

    private func ctx(_ first: CommandLineToolClassification?, path: String = "/x/unison",
                     executing: CommandLineToolEntry? = nil) -> CommandLineToolContextStatus {
        CommandLineToolContextStatus(label: "", caveat: "", searchPath: [],
                                     first: first.map { CommandLineToolEntry(path: path, classification: $0) },
                                     executingWhenDifferent: executing)
    }

    func test_action_installOnlyWhenBothContextsEmpty() {
        XCTAssertEqual(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil), ctx(nil)]), .install)
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil), ctx(.brewFormula(resolvedPath: "/c"))]))
    }

    func test_action_repairForDanglingLauncher_carriesOldTargetAndDisplaced() {
        let displaced = CommandLineToolEntry(path: "/opt/homebrew/bin/unison", classification: .brewFormula(resolvedPath: "/c"))
        let a = CommandLineToolActionPolicy.availableAction(contexts: [
            ctx(.danglingLauncherPath(target: "/old/cltool"), executing: displaced), ctx(nil)])
        XCTAssertEqual(a, .repair(oldTarget: "/old/cltool", displacing: "/opt/homebrew/bin/unison"))
    }

    func test_action_removeOnlyForThisInstallation() {
        XCTAssertEqual(CommandLineToolActionPolicy.availableAction(contexts: [ctx(.thisInstallation, path: "/usr/local/bin/unison"), ctx(nil)]),
                       .remove(linkPath: "/usr/local/bin/unison"))
        for c in [CommandLineToolClassification.otherCopyOfThisApp(bundlePath: "/o"),
                  .homebrewManaged(bundlePath: "/h"), .brewFormula(resolvedPath: "/c"),
                  .upstreamApp(bundlePath: "/u"), .danglingOther(target: "/d"), .other(resolvedPath: "/z")] {
            XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(c), ctx(nil)]), "\(c)")
        }
    }

    // MARK: admin commands

    func test_adminShellCommand_quotesAndFailsClosed() {
        let launcher = "/Applications/It's here.app/Contents/MacOS/cltool"
        let install = CommandLineToolActionPolicy.adminShellCommand(for: .install, launcherPath: launcher)
        XCTAssertEqual(install, "/bin/mkdir -p '/usr/local/bin' && /bin/ln -s '/Applications/It'\\''s here.app/Contents/MacOS/cltool' '/usr/local/bin/unison'")
        let repair = CommandLineToolActionPolicy.adminShellCommand(for: .repair(oldTarget: "/o", displacing: nil), launcherPath: launcher)
        XCTAssertTrue(repair.hasPrefix("[ -L '/usr/local/bin/unison' ] && ! [ -e '/usr/local/bin/unison' ] && /bin/ln -sfn "))
        let remove = CommandLineToolActionPolicy.adminShellCommand(for: .remove(linkPath: "/usr/local/bin/unison"), launcherPath: launcher)
        XCTAssertEqual(remove, "/bin/rm '/usr/local/bin/unison'")
    }

    func test_appleScript_escapesQuotesAndBackslashes() {
        let s = CommandLineToolActionPolicy.appleScript(runningAsAdmin: "echo \"a\\b\"")
        XCTAssertEqual(s, "do shell script \"echo \\\"a\\\\b\\\"\" with administrator privileges")
    }

    // MARK: prompt gate

    func test_prompt_installWhenBothEmpty_silentWhenSuppressedOrTestHost() {
        let empty = [ctx(nil), ctx(nil)]
        XCTAssertEqual(CommandLineToolPromptPolicy.prompt(contexts: empty, suppressed: false, isTestHost: false), .install)
        XCTAssertNil(CommandLineToolPromptPolicy.prompt(contexts: empty, suppressed: true, isTestHost: false))
        XCTAssertNil(CommandLineToolPromptPolicy.prompt(contexts: empty, suppressed: false, isTestHost: true))
    }

    func test_prompt_repairForDanglingLauncher() {
        XCTAssertEqual(CommandLineToolPromptPolicy.prompt(
            contexts: [ctx(.danglingLauncherPath(target: "/old")), ctx(nil)], suppressed: false, isTestHost: false),
            .repair(oldTarget: "/old"))
    }

    func test_prompt_silentWhenAnythingElseOwnsTheName() {
        for c in [CommandLineToolClassification.thisInstallation, .homebrewManaged(bundlePath: "/h"),
                  .brewFormula(resolvedPath: "/c"), .upstreamApp(bundlePath: "/u"),
                  .danglingOther(target: "/d"), .other(resolvedPath: "/z"), .otherCopyOfThisApp(bundlePath: "/o")] {
            XCTAssertNil(CommandLineToolPromptPolicy.prompt(contexts: [ctx(c), ctx(nil)], suppressed: false, isTestHost: false), "\(c)")
            XCTAssertNil(CommandLineToolPromptPolicy.prompt(contexts: [ctx(nil), ctx(c)], suppressed: false, isTestHost: false), "\(c) remote")
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

    func test_describe_namesThePathAndTheTarget() {
        XCTAssertEqual(CommandLineToolWording.describe(nil), "No unison command on this PATH.")
        let e = CommandLineToolEntry(path: "/usr/local/bin/unison", classification: .danglingLauncherPath(target: "/gone/cltool"))
        XCTAssertEqual(CommandLineToolWording.describe(e),
                       "/usr/local/bin/unison is a broken link to a former copy of this app's command (/gone/cltool).")
    }
}
