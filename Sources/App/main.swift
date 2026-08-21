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
let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil)

app.mainMenu = MainMenu.build(pickerTarget: delegate, updaterTarget: updaterController)

app.run()
