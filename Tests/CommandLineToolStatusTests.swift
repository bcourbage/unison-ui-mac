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
        // Targets under the fixture root, so they are absent regardless of what
        // is installed in /Applications on the machine running the tests.
        let bin = try makeBin("bin")
        let target = root + "/gone/unison-ui-mac.app/Contents/MacOS/cltool"
        try link(bin + "/unison", to: target)
        XCTAssertEqual(classify(bin + "/unison", env(thisBundle: app)),
                       .danglingLauncherPath(storedTarget: target, resolvedTarget: target))
        let bin2 = try makeBin("bin2")
        let other = root + "/gone/Unison.app/Contents/MacOS/cltool"
        try link(bin2 + "/unison", to: other)
        XCTAssertEqual(classify(bin2 + "/unison", env(thisBundle: app)), .danglingOther(target: other))
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
        try link(broken + "/unison", to: root + "/gone/unison-ui-mac.app/Contents/MacOS/cltool")
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

    // MARK: the remote context is never determined

    func test_remoteCommandStatus_isUnknown_neverKnownEmpty_andSaysSo() {
        let remote = CommandLineToolStatus.remoteCommandStatus()
        XCTAssertNil(remote.searchPath)
        XCTAssertNil(remote.first)
        XCTAssertFalse(remote.isKnownEmpty, "an undetermined PATH must never read as an absence")
        XCTAssertTrue(remote.caveat.hasPrefix("Not determined locally."))
        XCTAssertTrue(remote.caveat.contains("servercmd"))
        XCTAssertEqual(CommandLineToolWording.describe(remote), remote.caveat)
    }

    func test_currentStatus_secondContextIsTheUndeterminedRemoteOne() {
        // The probe runs the real login shell; only the shape of the second
        // context is asserted here.
        let contexts = CommandLineToolStatus.currentStatus(fs: fs)
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts[1], CommandLineToolStatus.remoteCommandStatus())
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

    /// The reviewer's fixture: a login script prints a banner before the PATH.
    /// Only the marked PATH may be parsed, so the banner never becomes a first
    /// directory that hides the real one.
    func test_loginShellSearchPath_ignoresBannerOutput() throws {
        let bin = try makeBin("bin"); try makeExecutable(bin + "/unison", body: "exit 0")
        let shell = root + "/banner-shell"
        // Prints a banner, then runs the requested command with PATH set.
        try makeExecutable(shell, body: "printf 'Welcome\\n'; PATH='\(bin):/usr/bin:/bin'; export PATH; eval \"$3\"")
        let path = CommandLineToolStatus.loginShellSearchPath(shell: shell, timeout: 10)
        XCTAssertEqual(path, [bin, "/usr/bin", "/bin"])
        let status = CommandLineToolStatus.scan(searchPath: path, label: "", caveat: "",
                                                environment: env(thisBundle: root + "/none.app"), fs: fs)
        XCTAssertEqual(status.first?.path, bin + "/unison")
        XCTAssertFalse(status.isKnownEmpty)
    }

    func test_loginShellSearchPath_withoutMarkers_isUnknown() throws {
        // A shell that ignores the command and prints something else entirely.
        let shell = root + "/mute-shell"
        try makeExecutable(shell, body: "printf '/fake/bin:/usr/bin'")
        XCTAssertNil(CommandLineToolStatus.loginShellSearchPath(shell: shell, timeout: 10))
    }

    func test_extractMarkedPath() {
        let s = CommandLineToolStatus.pathMarkerStart, e = CommandLineToolStatus.pathMarkerEnd
        XCTAssertEqual(CommandLineToolStatus.extractMarkedPath(from: "Welcome\n\(s)/a:/b\(e)"), "/a:/b")
        XCTAssertEqual(CommandLineToolStatus.extractMarkedPath(from: "\(s)\(e)trailing banner"), "")
        XCTAssertNil(CommandLineToolStatus.extractMarkedPath(from: "/a:/b"))
        XCTAssertNil(CommandLineToolStatus.extractMarkedPath(from: "\(e)/a\(s)"), "out of order")
        XCTAssertNil(CommandLineToolStatus.extractMarkedPath(from: "\(s)/a"), "unterminated")
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

    func test_action_installRequiresTheTerminalPathKnownAndEmpty() {
        let remote = CommandLineToolStatus.remoteCommandStatus()   // always undetermined
        // Terminal obtained and empty: Install, regardless of the undetermined remote context.
        XCTAssertEqual(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil), remote]), .install)
        // Terminal PATH not obtained: nothing. Unknown is not absence.
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil, known: false), remote]))
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil, known: false), ctx(nil)]))
        // The remote context can neither enable nor block: identical answers
        // whether it is undetermined or (hypothetically) holds an entry.
        XCTAssertEqual(CommandLineToolActionPolicy.availableAction(contexts: [ctx(nil), ctx(entry(.brewFormula(resolvedPath: "/c")))]), .install)
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [ctx(entry(.brewFormula(resolvedPath: "/c"))), remote]))
    }

    func test_undeterminedContext_canNeverSatisfyAGateRequiringKnownAbsence() {
        // A gate written against the remote context alone would never fire.
        let remote = CommandLineToolStatus.remoteCommandStatus()
        XCTAssertNil(CommandLineToolActionPolicy.availableAction(contexts: [remote, ctx(nil)]))
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [remote, ctx(nil)], suppressed: false, isTestHost: false))
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

    func test_adminShellCommand_install_requiresAnAbsentDestination() {
        let launcher = "/Applications/It's here.app/Contents/MacOS/cltool"
        XCTAssertEqual(CommandLineToolActionPolicy.adminShellCommand(for: .install, launcherPath: launcher),
                       "/bin/mkdir -p '/usr/local/bin' && ! [ -e '/usr/local/bin/unison' ] && ! [ -L '/usr/local/bin/unison' ] && /bin/ln -s '/Applications/It'\\''s here.app/Contents/MacOS/cltool' '/usr/local/bin/unison'")
    }

    /// The reviewer's fixture: the destination has become a directory while the
    /// dialog was open. `ln -s` alone would create `unison/cltool` inside it and
    /// exit 0; the generated command must refuse and leave it untouched.
    func test_install_refusesWhenDestinationIsADirectory_orAnyEntry() throws {
        let launcher = root + "/L/cltool"; try makeBin("L"); try makeExecutable(launcher, body: "exit 0")
        let bin = try makeBin("bin")
        let dest = bin + "/unison"
        func sh(_ cmd: String) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        let install = CommandLineToolActionPolicy.adminShellCommand(for: .install, launcherPath: launcher, installLinkPath: dest)
        // Directory at the destination: refused, nothing created inside.
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        XCTAssertNotEqual(sh(install), 0)
        XCTAssertFalse(fs.entryExists(atPath: dest + "/cltool"))
        try FileManager.default.removeItem(atPath: dest)
        // Dangling link at the destination: refused (-e is false, -L is true).
        try link(dest, to: "/gone")
        XCTAssertNotEqual(sh(install), 0)
        XCTAssertEqual(fs.linkTarget(atPath: dest), "/gone")
        try FileManager.default.removeItem(atPath: dest)
        // Regular file: refused, kept.
        try makeExecutable(dest, body: "exit 0")
        XCTAssertNotEqual(sh(install), 0)
        XCTAssertNil(fs.linkTarget(atPath: dest))
        try FileManager.default.removeItem(atPath: dest)
        // Absent: created, pointing at the launcher.
        XCTAssertEqual(sh(install), 0)
        XCTAssertEqual(fs.linkTarget(atPath: dest), launcher)
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

    func test_offer_installWhenTerminalKnownEmpty_silentWhenSuppressedOrTestHost() {
        let contexts = [ctx(nil), CommandLineToolStatus.remoteCommandStatus()]
        XCTAssertEqual(CommandLineToolPromptPolicy.offer(contexts: contexts, suppressed: false, isTestHost: false), .install)
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: contexts, suppressed: true, isTestHost: false))
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: contexts, suppressed: false, isTestHost: true))
    }

    func test_offer_silentWhenTheTerminalPathIsUnknown_remoteNeverCounts() {
        let remote = CommandLineToolStatus.remoteCommandStatus()
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [ctx(nil, known: false), remote], suppressed: false, isTestHost: false))
        // The remote context is informational only: a hypothetical entry there
        // does not silence an offer the Terminal context justifies, and its
        // undetermined state does not enable one the Terminal context does not.
        XCTAssertEqual(CommandLineToolPromptPolicy.offer(contexts: [ctx(nil), ctx(entry(.brewFormula(resolvedPath: "/c")))], suppressed: false, isTestHost: false), .install)
        XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [ctx(entry(.brewFormula(resolvedPath: "/c"))), remote], suppressed: false, isTestHost: false))
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
            XCTAssertNil(CommandLineToolPromptPolicy.offer(contexts: [ctx(entry(c)), CommandLineToolStatus.remoteCommandStatus()], suppressed: false, isTestHost: false), "\(c)")
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
