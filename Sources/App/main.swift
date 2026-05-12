import AppKit

TraceLog.shared.write("main.swift: entering NSApplicationMain")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.mainMenu = MainMenu.build()

let delegate = AppDelegate()
app.delegate = delegate
app.run()
