import XCTest
@testable import unison_ui_mac

/// PR3: the state table, file selection with the zsh bound, the probe's pure
/// classification and launchctl parse, and the view model wording.
final class CommandLineSetupStateTests: XCTestCase {

    // MARK: State table

    private func facts(resolution: CommandLineSetupResolution = .none,
                       manual: String? = nil,
                       precond: Bool = true,
                       block: CommandLineSetupBlockPresence = .none) -> CommandLineSetupFacts {
        CommandLineSetupFacts(resolution: resolution, manualSetupReason: manual,
                              bundlePreconditionOK: precond, block: block)
    }

    func test_row1_probeFailed_winsOverEverything() {
        let s = CommandLineSetupStateTable.evaluate(facts(resolution: .couldNotCheck, manual: "x", precond: false))
        XCTAssertEqual(s.row, 1)
        XCTAssertEqual(s.badge, .unknown)
        XCTAssertEqual(s.action, .none)
    }

    func test_row2_manual_beforePrecondition() {
        let s = CommandLineSetupStateTable.evaluate(facts(resolution: .thisApp, manual: "unsupported shell", precond: false))
        XCTAssertEqual(s.row, 2)
        XCTAssertEqual(s.badge, .manualSetup)
        XCTAssertEqual(s.note, "unsupported shell")
    }

    func test_row3_bundlePreconditionFailed() {
        let withBlock = CommandLineSetupStateTable.evaluate(facts(resolution: .thisApp, precond: false, block: .ownedCurrent))
        XCTAssertEqual(withBlock.row, 3)
        XCTAssertEqual(withBlock.action, .remove)
        XCTAssertEqual(withBlock.badge, .thisApp)
        let noBlock = CommandLineSetupStateTable.evaluate(facts(resolution: .thisApp, precond: false, block: .none))
        XCTAssertEqual(noBlock.row, 3)
        XCTAssertEqual(noBlock.action, .none)
    }

    func test_rows4to6_ownedElsewhere() {
        let r4 = CommandLineSetupStateTable.evaluate(facts(resolution: .thisApp, block: .ownedElsewhere(.otherExistingCopy)))
        XCTAssertEqual(r4.row, 4); XCTAssertEqual(r4.action, .useThisCopy); XCTAssertEqual(r4.startup, .none)
        let r5 = CommandLineSetupStateTable.evaluate(facts(block: .ownedElsewhere(.cannotInspect)))
        XCTAssertEqual(r5.row, 5); XCTAssertEqual(r5.action, .useThisCopy)
        let r6 = CommandLineSetupStateTable.evaluate(facts(block: .ownedElsewhere(.absentOrNotThisApp)))
        XCTAssertEqual(r6.row, 6); XCTAssertEqual(r6.action, .remove); XCTAssertEqual(r6.startup, .rewriteToCurrent)
    }

    func test_rows7to9_ownedCurrent_byResolution() {
        let r7 = CommandLineSetupStateTable.evaluate(facts(resolution: .thisApp, block: .ownedCurrent))
        XCTAssertEqual(r7.row, 7); XCTAssertEqual(r7.badge, .thisApp); XCTAssertEqual(r7.action, .remove); XCTAssertEqual(r7.startup, .none)
        let r8 = CommandLineSetupStateTable.evaluate(facts(resolution: .anotherUnison(path: "/x"), block: .ownedCurrent))
        XCTAssertEqual(r8.row, 8); XCTAssertEqual(r8.badge, .notThisApp)
        let r9 = CommandLineSetupStateTable.evaluate(facts(resolution: .none, block: .ownedCurrent))
        XCTAssertEqual(r9.row, 9); XCTAssertEqual(r9.badge, .notInstalled)
    }

    func test_rows10to12_noBlock_byResolution() {
        let r10 = CommandLineSetupStateTable.evaluate(facts(resolution: .thisApp, block: .none))
        XCTAssertEqual(r10.row, 10); XCTAssertEqual(r10.action, .add); XCTAssertEqual(r10.startup, .none)
        let r11 = CommandLineSetupStateTable.evaluate(facts(resolution: .anotherUnison(path: "/x"), block: .none))
        XCTAssertEqual(r11.row, 11); XCTAssertEqual(r11.startup, .offer)
        let r12 = CommandLineSetupStateTable.evaluate(facts(resolution: .none, block: .none))
        XCTAssertEqual(r12.row, 12); XCTAssertEqual(r12.startup, .offer)
    }

    // MARK: File selection — zsh bound

    func test_zshAutomatic_onlyWhenStockLayout() {
        let stock = CommandLineSetupFileSelection.stockZprofileMacOS26
        func auto(_ etcZ: Bool, _ homeZ: Bool, _ zprof: String?, _ zd: CommandLineSetupZDOTDIRState, _ appEnv: Bool) -> Bool {
            CommandLineSetupFileSelection.zshAutomatic(etcZshenvExists: etcZ, homeZshenvExists: homeZ,
                                                       etcZprofileContents: zprof, zdotdir: zd, zdotdirInAppEnvironment: appEnv)
        }
        XCTAssertTrue(auto(false, false, stock, .absent, false))
        XCTAssertFalse(auto(true, false, stock, .absent, false))   // /etc/zshenv
        XCTAssertFalse(auto(false, true, stock, .absent, false))   // ~/.zshenv
        XCTAssertFalse(auto(false, false, nil, .absent, false))    // /etc/zprofile unreadable
        XCTAssertFalse(auto(false, false, "not stock\n", .absent, false))
        XCTAssertFalse(auto(false, false, stock, .present, false)) // ZDOTDIR in launchd
        XCTAssertFalse(auto(false, false, stock, .uncertain, false)) // uncertain is not absence
        XCTAssertFalse(auto(false, false, stock, .absent, true))   // ZDOTDIR in app env
    }

    func test_zshChoice_selectsZprofile() {
        let c = CommandLineSetupFileSelection.zshChoice(
            homeDirectory: "/Users/x", etcZshenvExists: false, homeZshenvExists: false,
            etcZprofileContents: CommandLineSetupFileSelection.stockZprofileMacOS26,
            zdotdir: .absent, zdotdirInAppEnvironment: false)
        XCTAssertEqual(c.file, "/Users/x/.zprofile")
        XCTAssertTrue(c.automatic)
        XCTAssertNil(c.manualReason)
    }

    func test_stockZprofile_matchesMeasuredBytes() {
        // The measured macOS 26.6.2 /etc/zprofile is 304 bytes; macOS 15.7.9's is
        // 255 (no LANG=C.UTF-8 block).
        XCTAssertEqual(CommandLineSetupFileSelection.stockZprofileMacOS26.utf8.count, 304)
        XCTAssertTrue(CommandLineSetupFileSelection.stockZprofileMacOS26.contains("export LANG=C.UTF-8"))
        XCTAssertEqual(CommandLineSetupFileSelection.stockZprofileMacOS15.utf8.count, 255)
        XCTAssertFalse(CommandLineSetupFileSelection.stockZprofileMacOS15.contains("LANG"))
        for text in [CommandLineSetupFileSelection.stockZprofileMacOS26, CommandLineSetupFileSelection.stockZprofileMacOS15] {
            XCTAssertTrue(text.contains("/usr/libexec/path_helper -s"))
            XCTAssertTrue(CommandLineSetupFileSelection.knownStockZprofileTexts.contains(text))
        }
    }

    // The embedded stock constants must stay byte-for-byte identical to the
    // fixtures the CI gate compares the runner's /etc/zprofile against, so the two
    // sources of truth cannot drift.
    func test_stockZprofileConstants_matchFixtureFiles() throws {
        let repo = URL(fileURLWithPath: #filePath)   // Tests/CommandLineSetupStateTests.swift
            .deletingLastPathComponent()             // Tests/
            .deletingLastPathComponent()             // repo root
        let fixtures = repo.appendingPathComponent("scripts/fixtures")
        let f15 = try String(contentsOf: fixtures.appendingPathComponent("stock-zprofile-macos15.txt"), encoding: .utf8)
        let f26 = try String(contentsOf: fixtures.appendingPathComponent("stock-zprofile-macos26.txt"), encoding: .utf8)
        XCTAssertEqual(CommandLineSetupFileSelection.stockZprofileMacOS15, f15, "macOS 15 constant must match its fixture")
        XCTAssertEqual(CommandLineSetupFileSelection.stockZprofileMacOS26, f26, "macOS 26 constant must match its fixture")
    }

    // MARK: File selection — bash / fish / other

    func test_bashChoice_candidatesAndCreation() {
        // None exists: create ~/.bash_profile.
        let none = CommandLineSetupFileSelection.bashChoice(homeDirectory: "/h", existing: { _ in false }, readable: { _ in true })
        XCTAssertEqual(none.file, "/h/.bash_profile"); XCTAssertTrue(none.createIfAbsent); XCTAssertTrue(none.automatic)
        // .bash_login exists and readable, .bash_profile does not: pick .bash_login.
        let login = CommandLineSetupFileSelection.bashChoice(
            homeDirectory: "/h",
            existing: { $0 == "/h/.bash_login" },
            readable: { _ in true })
        XCTAssertEqual(login.file, "/h/.bash_login"); XCTAssertTrue(login.automatic)
        // Exists but unreadable: manual.
        let unreadable = CommandLineSetupFileSelection.bashChoice(
            homeDirectory: "/h",
            existing: { $0 == "/h/.bash_profile" },
            readable: { _ in false })
        XCTAssertFalse(unreadable.automatic); XCTAssertNotNil(unreadable.manualReason)
    }

    func test_fishChoice_andOther() {
        // Automatic only when the directory is absolute AND exists.
        let ok = CommandLineSetupFileSelection.fishChoice(configDirectory: "/Users/x/.config/fish",
                                                          directoryExists: { _ in true })
        XCTAssertEqual(ok.file, "/Users/x/.config/fish/conf.d/unison-ui-mac.fish"); XCTAssertTrue(ok.automatic)
        // Absolute but not existing: Manual setup (the design's requirement).
        let missing = CommandLineSetupFileSelection.fishChoice(configDirectory: "/Users/x/.config/fish",
                                                               directoryExists: { _ in false })
        XCTAssertFalse(missing.automatic); XCTAssertNotNil(missing.manualReason)
        // A relative path is never accepted, even if it "exists".
        let relative = CommandLineSetupFileSelection.fishChoice(configDirectory: "relative/dir",
                                                                directoryExists: { _ in true })
        XCTAssertFalse(relative.automatic)
        // No directory reported at all.
        let bad = CommandLineSetupFileSelection.fishChoice(configDirectory: nil, directoryExists: { _ in true })
        XCTAssertFalse(bad.automatic)
        XCTAssertFalse(CommandLineSetupFileSelection.otherChoice().automatic)
    }

    // Regression: the fish probe preserves the reported directory exactly. A
    // legitimate trailing space must not be trimmed to a different, existing dir.
    func test_fishConfigDirectory_preservesReportedPathExactly() {
        let s = CommandLineToolStatus.pathMarkerStart
        let e = CommandLineToolStatus.pathMarkerEnd
        XCTAssertEqual(CommandLineSetupProbe.fishConfigDirectory(fromProbeStdout: "\(s)/Users/x/config/fish \(e)"),
                       "/Users/x/config/fish ")
        XCTAssertEqual(CommandLineSetupProbe.fishConfigDirectory(fromProbeStdout: "\(s)/Users/x/.config/fish\(e)"),
                       "/Users/x/.config/fish")
        XCTAssertNil(CommandLineSetupProbe.fishConfigDirectory(fromProbeStdout: "\(s)\(e)"))       // empty
        XCTAssertNil(CommandLineSetupProbe.fishConfigDirectory(fromProbeStdout: "no markers"))     // absent
        XCTAssertNil(CommandLineSetupProbe.fishConfigDirectory(fromProbeStdout: nil))              // probe failed
    }

    func test_shellKind() {
        XCTAssertEqual(CommandLineSetupShellKind.of(loginShellPath: "/bin/zsh"), .zsh)
        XCTAssertEqual(CommandLineSetupShellKind.of(loginShellPath: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertEqual(CommandLineSetupShellKind.of(loginShellPath: "/bin/bash"), .bash)
        XCTAssertEqual(CommandLineSetupShellKind.of(loginShellPath: "/usr/bin/ksh"), .other)
    }

    // MARK: Probe classification

    func test_probe_classify() {
        let cltool = "/Applications/unison-ui-mac.app/Contents/MacOS/cltool"
        let realPathOf: (String) -> String? = { $0 }  // identity
        XCTAssertEqual(CommandLineSetupProbe.classify(.failed, thisLauncherPath: cltool, realPathOf: realPathOf), .couldNotCheck)
        XCTAssertEqual(CommandLineSetupProbe.classify(.empty, thisLauncherPath: cltool, realPathOf: realPathOf), .none)
        XCTAssertEqual(CommandLineSetupProbe.classify(.path(cltool), thisLauncherPath: cltool, realPathOf: realPathOf), .thisApp)
        XCTAssertEqual(CommandLineSetupProbe.classify(.path("/usr/local/bin/unison"), thisLauncherPath: cltool, realPathOf: realPathOf),
                       .anotherUnison(path: "/usr/local/bin/unison"))
    }

    // Regression (finding 1): a shell that ignores SIGTERM and blocks must not
    // leave the probe running past its deadline. Routing through the hardened
    // executor escalates to SIGKILL, so the probe returns within deadline+grace
    // rather than after the shell's own sleep.
    func test_resolvedUnison_stallingSigtermIgnoringShell_returnsWithinDeadline() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("stall.sh")
        try "#!/bin/sh\ntrap '' TERM\nsleep 120\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)

        // Teardown is bounded by the executor's constants (deadline 1s + a 2s
        // SIGTERM grace + a 2s SIGKILL grace + a 5s output settle ≈ 10s), well
        // under the shell's 120s sleep.
        let start = Date()
        let out = CommandLineSetupProbe.resolvedUnison(shellPath: shell.path, kind: .zsh, timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out, .failed)
        XCTAssertLessThan(elapsed, 20, "the probe returns within the deadline plus teardown grace, not after the sleep")
    }

    func test_parseLaunchctlZDOTDIR() {
        let present = "some = 1\nenvironment = {\n\tPATH => /bin\n\tZDOTDIR => /Users/x/zsh\n}\n"
        XCTAssertEqual(CommandLineSetupProbe.parseLaunchctlZDOTDIR(present), .present)
        let absent = "environment = {\n\tPATH => /bin\n\tLANG => C\n}\n"
        XCTAssertEqual(CommandLineSetupProbe.parseLaunchctlZDOTDIR(absent), .absent)
        let noSection = "domain = gui\nservices = {\n}\n"
        XCTAssertEqual(CommandLineSetupProbe.parseLaunchctlZDOTDIR(noSection), .uncertain)
    }

    // MARK: View model

    func test_viewModel_verdictsAndBadges() {
        XCTAssertEqual(CommandLineSetupViewModel.verdict(for: .thisApp), "This app selected by the check")
        XCTAssertEqual(CommandLineSetupViewModel.verdict(for: .manualSetup), "Needs manual setup")
        XCTAssertEqual(CommandLineSetupViewModel.badgeText(for: .notInstalled), "Not installed")
        XCTAssertEqual(CommandLineSetupViewModel.actionTitle(for: .add), "Add Terminal Setup…")
        XCTAssertEqual(CommandLineSetupViewModel.actionTitle(for: .remove), "Remove Terminal Setup…")
        XCTAssertEqual(CommandLineSetupViewModel.actionTitle(for: .useThisCopy), "Use This Copy…")
        XCTAssertNil(CommandLineSetupViewModel.actionTitle(for: .none))
    }

    func test_viewModel_abbreviatedPath() {
        XCTAssertEqual(
            CommandLineSetupViewModel.abbreviatedPath("/Applications/unison-ui-mac.app/Contents/SharedSupport/bin/unison"),
            "unison-ui-mac.app › SharedSupport/bin/unison")
        XCTAssertEqual(CommandLineSetupViewModel.abbreviatedPath("/usr/local/bin/unison"), "/usr/local/bin/unison")
    }

    func test_viewModel_pathLine_andRow() {
        let thisCmd = "/Applications/unison-ui-mac.app/Contents/SharedSupport/bin/unison"
        XCTAssertEqual(CommandLineSetupViewModel.pathLine(resolution: .none, thisCommandPath: thisCmd), "No unison command")
        // A check that did not complete has no path line and does not state absence.
        XCTAssertEqual(CommandLineSetupViewModel.pathLine(resolution: .couldNotCheck, thisCommandPath: thisCmd), "")
        XCTAssertEqual(CommandLineSetupViewModel.pathLine(resolution: .thisApp, thisCommandPath: thisCmd),
                       "unison-ui-mac.app › SharedSupport/bin/unison")
        let state = CommandLineSetupStateTable.evaluate(facts(resolution: .thisApp, block: .ownedCurrent))
        let vm = CommandLineSetupViewModel.rowViewModel(state: state, resolution: .thisApp, thisCommandPath: thisCmd)
        XCTAssertEqual(vm.badgeText, "This app")
        XCTAssertEqual(vm.actionTitle, "Remove Terminal Setup…")
    }

    func test_viewModel_commandPathNeedsCare() {
        XCTAssertFalse(CommandLineSetupViewModel.commandPathNeedsCare("/Applications/unison-ui-mac.app/Contents/SharedSupport/bin/unison"))
        XCTAssertTrue(CommandLineSetupViewModel.commandPathNeedsCare("/Users/My Apps/unison.app/x"))
    }

    func test_viewModel_actionFootnote() {
        XCTAssertEqual(CommandLineSetupViewModel.actionFootnote(action: .add, shell: .zsh, file: "/h/.zprofile"),
                       "Adds this app's command to your Terminal by writing one marked block to /h/.zprofile, the file your login shell reads.")
        XCTAssertEqual(CommandLineSetupViewModel.actionFootnote(action: .remove, shell: .zsh, file: "/h/.zprofile"),
                       "Removes this app's block from /h/.zprofile. Another link may still select this app.")
        XCTAssertEqual(CommandLineSetupViewModel.actionFootnote(action: .add, shell: .fish, file: "/h/x.fish"),
                       "Adds this app's command to your Terminal by writing a dedicated file in your fish configuration.")
        XCTAssertNil(CommandLineSetupViewModel.actionFootnote(action: .none, shell: .zsh, file: "/h/.zprofile"))
        XCTAssertNil(CommandLineSetupViewModel.actionFootnote(action: .add, shell: .zsh, file: nil))
    }

    // P2 #4: zsh keeps ~/.zprofile as the name, but the destination is established
    // only when nothing redirects where the login shell reads.
    func test_zshChoice_destinationEstablished() {
        let stock = CommandLineSetupFileSelection.stockZprofileMacOS26
        func choice(_ etcZ: Bool, _ homeZ: Bool, _ zd: CommandLineSetupZDOTDIRState, _ appEnv: Bool) -> CommandLineSetupFileChoice {
            CommandLineSetupFileSelection.zshChoice(homeDirectory: "/h", etcZshenvExists: etcZ, homeZshenvExists: homeZ,
                                                    etcZprofileContents: stock, zdotdir: zd, zdotdirInAppEnvironment: appEnv)
        }
        XCTAssertTrue(choice(false, false, .absent, false).destinationEstablished)
        XCTAssertFalse(choice(false, false, .present, false).destinationEstablished)   // ZDOTDIR in launchd
        XCTAssertFalse(choice(false, false, .uncertain, false).destinationEstablished) // uncertain is not absent
        XCTAssertFalse(choice(false, false, .absent, true).destinationEstablished)      // ZDOTDIR in app env
        XCTAssertFalse(choice(true, false, .absent, false).destinationEstablished)      // .zshenv redirect
        // A non-stock /etc/zprofile can itself set ZDOTDIR, so it leaves the
        // destination uncertain: not established.
        let nonStock = CommandLineSetupFileSelection.zshChoice(
            homeDirectory: "/h", etcZshenvExists: false, homeZshenvExists: false,
            etcZprofileContents: "not stock\n", zdotdir: .absent, zdotdirInAppEnvironment: false)
        XCTAssertFalse(nonStock.automatic)
        XCTAssertFalse(nonStock.destinationEstablished, "a non-stock /etc/zprofile leaves the destination uncertain")
        // Unreadable /etc/zprofile: also uncertain.
        let unreadable = CommandLineSetupFileSelection.zshChoice(
            homeDirectory: "/h", etcZshenvExists: false, homeZshenvExists: false,
            etcZprofileContents: nil, zdotdir: .absent, zdotdirInAppEnvironment: false)
        XCTAssertFalse(unreadable.destinationEstablished)
    }
}
