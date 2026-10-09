import AppKit

/// Quitting while a window-modal sheet is open.
///
/// AppKit refuses to terminate an app that has a window-modal sheet up: it logs
/// "App termination blocked by modal sheet" and aborts before the delegate is
/// consulted, so ⌘Q, the Quit menu item, the toolbar and picker Quit buttons, the
/// Dock's Quit and a Quit Apple event would all do nothing, silently, for as long
/// as a sync decision, a close confirmation or the restart notice sat on screen.
/// Quit is always available, so every route goes through here: the open sheets are
/// dismissed first (each sheet's own dismissal mapping applies: the sync decision
/// and close sheets treat a cancel as "keep syncing", which refuses any waiting
/// command-line caller cleanly), and the termination is requested once they are gone.
@MainActor
enum AppQuit {
    /// Ends every open sheet, returning how many were ended.
    @discardableResult
    static func dismissSheets(in app: NSApplication = NSApp) -> Int {
        var ended = 0
        // A sheet can itself host a sheet, so repeat until none is left; the bound
        // guards against a sheet that refuses to end.
        for _ in 0..<8 {
            let parents = app.windows.filter { $0.attachedSheet != nil }
            if parents.isEmpty { break }
            for parent in parents {
                if let sheet = parent.attachedSheet {
                    parent.endSheet(sheet, returnCode: .cancel)
                    ended += 1
                }
            }
        }
        return ended
    }

    /// Dismisses open sheets, then terminates. With no sheet open this is a plain
    /// `terminate`. With one, termination is requested on the next turn of the run
    /// loop, after AppKit has finished tearing the sheet down.
    static func quit(sender: Any? = nil, app: NSApplication = NSApp) {
        if dismissSheets(in: app) == 0 {
            app.terminate(sender)
        } else {
            DispatchQueue.main.async { app.terminate(sender) }
        }
    }

    /// Routes the Quit Apple event (the Dock's Quit, `tell application … to quit`,
    /// logout and restart) through `quit` instead of AppKit's default handler.
    static func installQuitEventHandler(target: AnyObject, selector: Selector) {
        NSAppleEventManager.shared().setEventHandler(
            target, andSelector: selector,
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication))
    }
}
