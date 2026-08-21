import AppKit
import Sparkle

/// Builds the application's main menu bar programmatically. Macos doesn't
/// give us a menu for free without a storyboard, so we assemble the
/// expected App / File / Edit / Window / Help structure here.
///
/// The App menu's `Quit` is wired by AppKit automatically once we attach
/// the menu to `NSApp.mainMenu`; the rest of the items target `AppDelegate`
/// (or AppKit's first-responder action chain for the standard ones).
///
/// `@MainActor` because every method here touches main-actor-isolated AppKit
/// state (`NSApp.helpMenu`, `NSApp.servicesMenu`, `NSApp.windowsMenu`) and
/// is only ever called from `main.swift`'s entry point. Annotating the enum
/// makes that contract explicit — required for Swift 6 strict concurrency
/// on Xcode 16.x (CI), tolerated implicitly by newer Xcode locally.
@MainActor
enum MainMenu {

    /// `pickerTarget` is the explicit, stable target for the Action ▸ Show
    /// Profile Picker command (issue #38) — the `AppDelegate`. Required (not
    /// optional): the explicit target IS the fix, and the controller-owned
    /// selector has been removed, so omitting it would break the command rather
    /// than silently fall back. Passing an explicit target detaches that
    /// app-global navigation command from transient responder-chain resolution.
    /// `updaterTarget` is the Sparkle `SPUStandardUpdaterController`, the
    /// explicit target for the App ▸ "Check for Updates…" item. Sparkle's
    /// controller owns both the `checkForUpdates:` action and the
    /// `validateMenuItem:` that greys the item while a check is running, so
    /// binding it as the item's target is all the wiring the command needs.
    static func build(pickerTarget: AnyObject, updaterTarget: AnyObject) -> NSMenu {
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
        main.addItem(makeAppMenu(appName: appName, updaterTarget: updaterTarget))
        main.addItem(makeEditMenu())
        main.addItem(makeActionMenu(pickerTarget: pickerTarget))
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
        // The full Unison reference manual — file-format details, the
        // preference list, conflict-resolution semantics. Bundled with
        // the app as a rendered HTML copy of upstream's
        // `doc/unison-manual.tex` (see `make vendor-manual`), so it
        // works offline; the handler falls back to the upstream wiki
        // if the bundled resource is missing.
        menu.addItem(withTitle: "Unison File Synchronizer Manual",
                     action: #selector(AppDelegate.openUnisonProjectHelp(_:)),
                     keyEquivalent: "")

        // Report-an-Issue — separator above because this is a different
        // category of action (file feedback) than the two help docs
        // above (read docs). Ellipsis is debatable: per HIG, "performs
        // its action immediately" gets no ellipsis, and this just
        // opens a URL — but the URL leads to a form the user fills
        // out, which is closer to the "prompts for more input"
        // ellipsis criterion. We side with no-ellipsis to match the
        // other URL-opening Help items above.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Report an Issue",
                     action: #selector(AppDelegate.reportIssue(_:)),
                     keyEquivalent: "")

        // Donate — its own separator: supporting the project is a distinct
        // category from reading docs or filing feedback. No ellipsis, matching
        // the other URL-opening Help items; opens the GitHub Sponsors page.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Donate",
                     action: #selector(AppDelegate.donate(_:)),
                     keyEquivalent: "")

        // Wire as the official Help menu so the system's "Help search"
        // (the Spotlight-style menu-item finder) lives here.
        NSApp.helpMenu = menu
        item.submenu = menu
        return item
    }

    private static func makeAppMenu(appName: String, updaterTarget: AnyObject) -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)

        // Use our custom action so we can populate the panel with the
        // Unison version we're linked against (rather than just our
        // bundle's CFBundleShortVersionString).
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(AppDelegate.showAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        // Check for Updates… — the Sparkle updater. Explicit target is the
        // SPUStandardUpdaterController; it supplies the action and the
        // validation that disables the item during an in-flight check.
        // Ellipsis because it opens update UI rather than acting instantly.
        // App-menu placement is the macOS convention for this command.
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        checkForUpdates.target = updaterTarget
        appMenu.addItem(checkForUpdates)
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
    /// for the per-row half. Most items target nil — the responder
    /// chain delivers them to `ReconcileWindowController` when the
    /// reconcile window is key. The exception is Show Profile Picker,
    /// which has an explicit `pickerTarget` (the AppDelegate) — issue #38.
    private static func makeActionMenu(pickerTarget: AnyObject) -> NSMenuItem {
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

        // Recovery variant of Rescan: re-open the profile with a one-shot
        // `ignorearchives` so Unison rebuilds its state from the replicas
        // directly (escape from "archive inconsistency"). No shortcut —
        // deliberate recovery action. Handled by AppDelegate at the
        // responder-chain tail; validated there too.
        menu.addItem(withTitle: "Rescan Ignoring Archives…",
                     action: Selector(("rescanIgnoringArchivesMenu:")),
                     keyEquivalent: "")

        // Navigate back to the launch view (closes the reconcile
        // window; the AppDelegate onClose handler reopens the picker
        // with the just-run profile pre-selected). ⌘⇧P parallels the
        // ⌘⇧E shortcut for "Profile Editor" — both are profile-
        // navigation primary actions with a Shift+letter mnemonic.
        // Issue #38: app-global navigation command with an EXPLICIT AppDelegate
        // target + compile-time selector, so its enablement/dispatch does not
        // depend on the transient reconcile-window responder chain (an
        // intermittent responder-chain/validation failure that occasionally
        // greyed this item at first menu-open during `.opening`). AppDelegate
        // validates it via the shared `ShowProfilePickerMenuPolicy` routing
        // decision and navigates the current session or the queued-open waiting
        // window back to the picker — the same navigation-only paths as the
        // toolbar.
        let pickerItem = NSMenuItem(
            title: "Show Profile Picker",
            action: #selector(AppDelegate.showProfilePickerAppAction(_:)),
            keyEquivalent: "p")
        pickerItem.keyEquivalentModifierMask = [.command, .shift]
        pickerItem.target = pickerTarget
        menu.addItem(pickerItem)

        menu.addItem(.separator())

        // Direction overrides — the "decide what to sync" core. Order
        // matches the legacy app's reading order (direction →
        // alternatives → mtime variants).
        let directionSelector = Selector(("directionMenuAction:"))
        for action in DirectionAction.menuActions {
            let mi = NSMenuItem(title: action.label,
                                action: directionSelector,
                                keyEquivalent: action.keyEquivalent)
            // No-modifier single keys (> < /) à la Unison's text UI.
            mi.keyEquivalentModifierMask = []
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
