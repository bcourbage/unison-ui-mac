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
        // Prefer CFBundleDisplayName / CFBundleName so the user-visible
        // app name (e.g. "Unison-UI-Mac") is what appears in the App
        // menu's "About / Hide / Quit" items and the Help menu —
        // rather than ProcessInfo.processName, which returns the
        // executable file name (lowercase `unison-ui-mac`).
        let info = Bundle.main.infoDictionary
        let appName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName

        // No File menu: this isn't a document-based app. We had one with
        // a single "Show Profiles" item, but closing the reconcile window
        // already returns to the picker (which is the only sensible
        // navigation), so the menu entry was redundant. Standard window
        // commands (⌘W to close, ⌘M to minimize) still work via the
        // Window menu / responder chain — they don't need File menu
        // entries. Apple's own non-document apps (Calculator, System
        // Settings) ship without a File menu.
        let main = NSMenu()
        main.addItem(makeAppMenu(appName: appName))
        main.addItem(makeEditMenu())
        main.addItem(makeActionMenu())
        main.addItem(makeWindowMenu())
        main.addItem(makeHelpMenu(appName: appName))
        return main
    }

    private static func makeHelpMenu(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")

        // Per Apple HIG: no ellipsis on items that perform their action
        // immediately (these open a URL in the default browser; they
        // don't prompt the user for further input first). Two related
        // help entries, no separator between them — separators are for
        // grouping unrelated items.
        //
        // Help for THIS UI — has the ⌘? shortcut because it's the more
        // common "I don't know what this app does" entry point.
        menu.addItem(withTitle: "\(appName) Help",
                     action: #selector(AppDelegate.openUiMacHelp(_:)),
                     keyEquivalent: "?")
        // Help for the upstream synchronizer — the file-format reference,
        // the preference list, the conflict-resolution semantics live there.
        menu.addItem(withTitle: "Unison File Synchronizer Help",
                     action: #selector(AppDelegate.openUnisonProjectHelp(_:)),
                     keyEquivalent: "")

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

        // macOS-idiomatic Settings entry. ⌘, is the canonical shortcut;
        // ellipsis because the action opens a window (not an instant
        // toggle). The window owns its own UI — see SettingsWindowController.
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(AppDelegate.showSettings(_:)),
                        keyEquivalent: ",")
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

    /// Edit menu: standard text ops + the per-row Ignore items +
    /// Profile Editor entry point. Direction overrides + Diff + the
    /// selection helpers (Select Conflicts, Revert) live in the
    /// separate Action menu to keep this one focused.
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

        menu.addItem(.separator())
        // Ignore actions — target is nil so they dispatch through the responder
        // chain and land on ReconcileWindowController when the reconcile window
        // is key. AppKit's automatic menu-item validation greys them out when
        // no responder claims the selector.
        //
        // Selector name must match the @objc method in ReconcileWindowController.
        // Tags must match IgnoreAction.menuTag so the receiver can re-derive
        // which action was picked without looking up by title.
        let ignoreSelector = Selector(("ignoreMenuAction:"))
        for action in IgnoreAction.all {
            let mi = NSMenuItem(title: action.label, action: ignoreSelector, keyEquivalent: "")
            mi.tag = action.menuTag
            menu.addItem(mi)
        }

        // Profile management — opens the Profile Editor manager window
        // (lists every .prf with edit / delete / reorder / hide
        // affordances). Single menu entry replaces what used to be
        // separate Edit / Delete items.
        menu.addItem(.separator())
        let editor = NSMenuItem(title: "Profile Editor…",
                                action: #selector(AppDelegate.showProfileEditor(_:)),
                                keyEquivalent: "e")
        editor.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(editor)
        item.submenu = menu
        return item
    }

    /// Action menu: workflow controls (Go/Stop/Rescan) on top, then
    /// per-row reconcile operations (direction overrides, diff,
    /// selection helpers). Matches the legacy uimac app's structure
    /// for the per-row half. Every item targets nil — the responder
    /// chain delivers them to `ReconcileWindowController` when the
    /// reconcile window is key.
    private static func makeActionMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Action")

        // Workflow primary/escape actions. Canonical macOS shortcuts:
        // ⌘⏎ for the "submit / run" primary action (matches Mail's
        // Send, etc.); ⌘. (Command-Period) for "cancel currently
        // running operation," which macOS has used since System 6.
        // ⌘⇧R for Rescan keeps it parallel to Safari/Mail "Reload All"
        // — and avoids colliding with the Profile Editor's ⌘R button.
        let goItem = NSMenuItem(title: "Go",
                                action: Selector(("goMenuAction:")),
                                keyEquivalent: "\r")
        goItem.keyEquivalentModifierMask = [.command]
        menu.addItem(goItem)

        let stopItem = NSMenuItem(title: "Stop",
                                  action: Selector(("stopMenuAction:")),
                                  keyEquivalent: ".")
        stopItem.keyEquivalentModifierMask = [.command]
        menu.addItem(stopItem)

        let rescanItem = NSMenuItem(title: "Rescan",
                                    action: Selector(("rescanMenuAction:")),
                                    keyEquivalent: "r")
        rescanItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(rescanItem)

        // Navigate back to the launch view (closes the reconcile
        // window; the AppDelegate onClose handler reopens the picker
        // with the just-run profile pre-selected). ⌘⇧P parallels the
        // ⌘⇧E shortcut for "Profile Editor" — both are profile-
        // navigation primary actions with a Shift+letter mnemonic.
        let pickerItem = NSMenuItem(
            title: "Show Profile Picker",
            action: Selector(("showProfilePickerMenuAction:")),
            keyEquivalent: "p")
        pickerItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pickerItem)

        menu.addItem(.separator())

        // Direction overrides — the "decide what to sync" core. Order
        // matches the legacy app's reading order (direction →
        // alternatives → mtime variants).
        let directionSelector = Selector(("directionMenuAction:"))
        for action in DirectionAction.menuActions {
            let mi = NSMenuItem(title: action.label,
                                action: directionSelector,
                                keyEquivalent: "")
            mi.tag = action.menuTag
            menu.addItem(mi)
        }

        // Diff — pop a window with the unified diff of the selected
        // row. No keyboard shortcut yet; ⌘D is taken by "Don't Save"
        // in document dialogs and we don't want to compete.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Diff",
                     action: Selector(("diffMenuAction:")),
                     keyEquivalent: "")

        // Selection helpers — non-mutating (Select Conflicts) vs.
        // mutating (Revert). Both look at the controller's
        // rowOverrides + items to compute their target set; the rules
        // live in `RowSelectionRules`.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select Conflicts",
                     action: Selector(("selectConflictsAction:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Revert to Unison's Recommendation",
                     action: Selector(("revertSelectionAction:")),
                     keyEquivalent: "")

        item.submenu = menu
        return item
    }

    private static func makeWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        // ⌘W normally lives under File → Close in document-based
        // apps. We have no File menu (not document-based), so the
        // shortcut migrates here. NSWindow.performClose routes
        // through windowShouldClose so the reconcile window's
        // mid-sync confirmation still gets a chance to intercept.
        menu.addItem(withTitle: "Close Window",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
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
