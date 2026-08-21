import AppKit
import Sparkle

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
let underXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let updaterController: SPUStandardUpdaterController? = underXCTest ? nil
    : SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)

// Under XCTest the menu still needs a non-nil target; a throwaway object keeps
// the item constructible without a live updater (tests build their own menu
// with an explicit target, so the app's runtime item is never exercised there).
app.mainMenu = MainMenu.build(pickerTarget: delegate,
                              updaterTarget: updaterController ?? NSObject())

app.run()
