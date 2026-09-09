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
        // The measured macOS 26.6.2 /etc/zprofile is 304 bytes.
        XCTAssertEqual(CommandLineSetupFileSelection.stockZprofileMacOS26.utf8.count, 304)
        XCTAssertTrue(CommandLineSetupFileSelection.stockZprofileMacOS26.contains("export LANG=C.UTF-8"))
        XCTAssertTrue(CommandLineSetupFileSelection.stockZprofileMacOS26.contains("/usr/libexec/path_helper -s"))
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
        let ok = CommandLineSetupFileSelection.fishChoice(configDirectory: "/Users/x/.config/fish")
        XCTAssertEqual(ok.file, "/Users/x/.config/fish/conf.d/unison-ui-mac.fish"); XCTAssertTrue(ok.automatic)
        let bad = CommandLineSetupFileSelection.fishChoice(configDirectory: nil)
        XCTAssertFalse(bad.automatic)
        XCTAssertFalse(CommandLineSetupFileSelection.otherChoice().automatic)
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
}
