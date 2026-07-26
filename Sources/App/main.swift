import AppKit

TraceLog.shared.write("main.swift: entering NSApplicationMain")

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Create the delegate BEFORE building the main menu so the Action ▸ Show
// Profile Picker item can be given an explicit, stable AppDelegate target
// (issue #38) — an app-global navigation command must not depend on transient
// responder-chain resolution.
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenu.build(pickerTarget: delegate)

app.run()
