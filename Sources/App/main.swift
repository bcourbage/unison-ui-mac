import AppKit
import CoreGraphics
import Sparkle

let underXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let underSmoke = ProcessInfo.processInfo.environment["UNISON_UI_SMOKE"] != nil

// Shell launches are decided before anything AppKit or Sparkle runs. The
// `unison` launcher (Sources/CLTool/cltool.c) execs this executable with the
// caller's arguments, and a remote peer's `ssh host unison -server` arrives the
// same way. For the headless roles the engine takes over the process here and
// never returns; for `-ui graphic` the engine is started with the full argv and
// the graphical launch below continues. Nothing on this path may write to
// stdout: for `-server` it is the wire protocol. See
// docs/cli-launcher-design.md and CommandLineInvocationPolicy.
// The launcher marks the process it execs; read it and remove it so nothing the
// app later spawns (diff, merge, ssh) inherits it.
let launchedByLauncher = getenv(CommandLineInvocationPolicy.launcherMarker) != nil
unsetenv(CommandLineInvocationPolicy.launcherMarker)
let hasWindowServerSession = CGSessionCopyCurrentDictionary() != nil

switch CommandLineInvocationPolicy.launchKind(
    arguments: CommandLine.arguments,
    launchedByLauncher: launchedByLauncher,
    hasWindowServerSession: hasWindowServerSession,
    isTestHost: underXCTest || underSmoke) {
case .gui:
    break
case .shell:
    // Returns only when the effective interface is graphical and a session
    // exists; every other role exits inside the engine or here.
    CommandLineEngineLaunch.run(arguments: CommandLine.arguments,
                                hasWindowServerSession: hasWindowServerSession)
}

TraceLog.shared.write("main.swift: entering NSApplicationMain")

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Create the delegate BEFORE building the main menu so the Action ▸ Show
// Profile Picker item can be given an explicit, stable AppDelegate target
// (issue #38) — an app-global navigation command must not depend on transient
// responder-chain resolution.
let delegate = AppDelegate()
app.delegate = delegate

// Sparkle updater controller. Created before the menu so the App ▸ "Check for
// Updates…" item can target it directly — the controller supplies both the
// checkForUpdates: action and the validateMenuItem: that disables the item
// while a check is already in flight. Held by a top-level binding so it lives
// for the whole process. startingUpdater:true performs Sparkle's normal
// post-launch background check (on first launch Sparkle prompts the user
// whether to check automatically; SUEnableAutomaticChecks is left unset).
//
// NOT started under XCTest: the test bundle is hosted inside this app, so
// applicationDidFinishLaunching (and this file) run in the test process. A live
// updater there would schedule Sparkle's first-launch permission prompt and a
// background feed check inside the headless host — main-thread activity that
// perturbs timing-sensitive tests. Mirrors the app's other XCTest guards (e.g.
// the UNISON-directory redirect in AppDelegate).
// Also skip Sparkle under UNISON_UI_SMOKE (the macOS-baseline launch check):
// the smoke launches the release-built app to exercise the OCaml runtime on the
// deployment-floor OS and exits immediately, so a live updater's first-launch
// permission prompt / background feed check would only add a network dependency
// and modal noise to a check that must be deterministic.
let updaterController: SPUStandardUpdaterController? = (underXCTest || underSmoke) ? nil
    : SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)

// Hand the updater to the delegate so the Settings window can expose the
// automatic-check and system-profile toggles (see UpdatePreferences). Nil under
// XCTest, where the Settings window omits the Updates tab.
delegate.updater = updaterController?.updater

// Under XCTest there is no live updater. The menu is still built, but because
// NSMenuItem.target is a WEAK reference the throwaway fallback is released
// immediately, so the runtime item's updater target ends up nil. That is
// harmless: the test host never invokes Check for Updates, and the unit tests
// build their own menu with a retained target. In production updaterController
// is a strong top-level binding, so the real item's target stays retained.
app.mainMenu = MainMenu.build(pickerTarget: delegate,
                              updaterTarget: updaterController ?? NSObject())

app.run()
