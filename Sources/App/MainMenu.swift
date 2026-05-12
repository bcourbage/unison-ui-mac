import AppKit

/// Builds the application's main menu bar programmatically. Macos doesn't
/// give us a menu for free without a storyboard, so we assemble the
/// expected App / File / Edit / Window / Help structure here.
///
/// The App menu's `Quit` is wired by AppKit automatically once we attach
/// the menu to `NSApp.mainMenu`; the rest of the items target `AppDelegate`
/// (or AppKit's first-responder action chain for the standard ones).
enum MainMenu {

    static func build() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName

        let main = NSMenu()
        main.addItem(makeAppMenu(appName: appName))
        main.addItem(makeFileMenu())
        main.addItem(makeEditMenu())
        main.addItem(makeWindowMenu())
        main.addItem(makeHelpMenu(appName: appName))
        return main
    }

    private static func makeHelpMenu(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Unison Online Help",
                     action: #selector(AppDelegate.openUnisonOnlineHelp(_:)),
                     keyEquivalent: "?")
        // Wire as the official Help menu so the system's "Help search"
        // (the Spotlight-style menu-item finder) lives here.
        NSApp.helpMenu = menu
        item.submenu = menu
        return item
    }

    private static func makeAppMenu(appName: String) -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)

        // Use our custom action so we can populate the panel with the
        // Unison version we're linked against (rather than just our
        // bundle's CFBundleShortVersionString).
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(AppDelegate.showAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    private static func makeFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Profile…",
                     action: #selector(AppDelegate.newProfile(_:)),
                     keyEquivalent: "n")
        menu.addItem(withTitle: "Open Profile…",
                     action: #selector(AppDelegate.openProfile(_:)),
                     keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    private static func makeEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    private static func makeWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }
}
