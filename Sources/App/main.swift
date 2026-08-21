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
