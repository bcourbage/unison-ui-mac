import AppKit

/// The single three-way "a synchronization is running" decision, shared by the
/// two contexts that must raise it, with context-specific wording but ONE
/// presentation and ONE choice mapping:
///
///   - an ordinary window close during a sync (the ✕, ⌘W, or Profiles), and
///   - an incoming command-line request that arrives while a session is syncing.
///
/// Both present a non-blocking window-modal sheet (never `runModal`) with the
/// same button order and the same three outcomes; only the wording and what each
/// outcome does afterwards differ. The content is pure and unit-tested; the
/// AppKit presentation is a thin wrapper over `NSAlert.beginSheetModal`.
enum SyncDecisionContext: Equatable {
    /// The user is trying to close a window whose session is syncing. The
    /// associated value is that session's profile name.
    case windowClose(profile: String)
    /// A command-line request arrived while a session is syncing. `current` is
    /// the syncing profile; `requested` is the profile the command wants to open.
    case commandLineRequest(current: String, requested: String)
}

/// The unified outcome, identical across both contexts:
///   - `keep`       — do not touch the sync (window close: keep the window open;
///                     CLI: refuse the request). The default, and what any
///                     dismissal maps to.
///   - `background` — let the current sync finish in the background, then complete
///                     the context's action (close the window / open the request).
///   - `stop`       — stop the current sync, then complete the context's action.
enum SyncDecisionChoice: Equatable { case keep, background, stop }

/// One button spec, in NSAlert add order (first = default). Pure/testable.
struct SyncDecisionButton: Equatable {
    let title: String
    let choice: SyncDecisionChoice
    let isDefault: Bool
    let isDestructive: Bool
}

/// Pure, testable sheet content. `buttons` are in NSAlert add order; the first is
/// the default and is always the `keep` choice, so a dismissal maps to `keep`.
struct SyncDecisionContent: Equatable {
    let title: String
    let body: String
    let buttons: [SyncDecisionButton]

    /// The choice a dismissal (Escape / sheet ended without an explicit button)
    /// resolves to — always `keep`, the default button's choice.
    var dismissChoice: SyncDecisionChoice {
        buttons.first(where: { $0.isDefault })?.choice ?? .keep
    }
}

enum SyncDecisionSheet {
    /// The second body sentence, identical in both contexts, so the safety caveat
    /// reads the same everywhere. Uses "Stop" consistently.
    static let stopCaveat =
        "Stopping does not undo completed changes. Transfers already underway may finish."

    /// Whether the command-line buttons repeat the requested profile name. Long
    /// names make three name-bearing buttons unwieldy, so the buttons name only
    /// the consequence (the sheet title already names the profiles); this keeps
    /// the consequence rather than truncating it. See the layout note in the PR.
    static let commandLineButtonsNameProfile = false

    static func content(for context: SyncDecisionContext) -> SyncDecisionContent {
        switch context {
        case .windowClose(let profile):
            return SyncDecisionContent(
                title: "Close the window while syncing?",
                body: "“\(profile)” is still synchronizing. Closing the window can leave the sync "
                    + "running in the background.\n" + stopCaveat,
                buttons: [
                    SyncDecisionButton(title: "Keep Window Open",      choice: .keep,       isDefault: true,  isDestructive: false),
                    SyncDecisionButton(title: "Continue in Background", choice: .background, isDefault: false, isDestructive: false),
                    SyncDecisionButton(title: "Stop Syncing & Close",   choice: .stop,       isDefault: false, isDestructive: true),
                ])
        case .commandLineRequest(let current, let requested):
            let openReq  = commandLineButtonsNameProfile ? "Open “\(requested)”" : "Open"
            let dontOpen = commandLineButtonsNameProfile ? "Don’t Open “\(requested)”" : "Don’t Open"
            return SyncDecisionContent(
                title: "Open “\(requested)” while “\(current)” is syncing?",
                body: "You can finish the current sync before opening “\(requested)”, or stop it "
                    + "and open “\(requested)” after cleanup.\n" + stopCaveat,
                buttons: [
                    SyncDecisionButton(title: "Keep Syncing; \(dontOpen)",     choice: .keep,       isDefault: true,  isDestructive: false),
                    SyncDecisionButton(title: "Finish Sync, Then \(openReq)",   choice: .background, isDefault: false, isDestructive: false),
                    SyncDecisionButton(title: "Stop Sync, Then \(openReq)",     choice: .stop,       isDefault: false, isDestructive: true),
                ])
        }
    }

    /// Build the `NSAlert` for `content`. Returned so the caller can dismiss it
    /// (`endSheet`) if the underlying state changes before the user chooses.
    @MainActor
    static func makeAlert(_ content: SyncDecisionContent) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.body
        for spec in content.buttons {
            let button = alert.addButton(withTitle: spec.title)
            if spec.isDestructive { button.hasDestructiveAction = true }
        }
        return alert
    }

    /// Present `content` as a NON-BLOCKING window sheet on `window` and deliver the
    /// chosen `SyncDecisionChoice` (a dismissal maps to keep). Returns the `NSAlert`
    /// so the caller can dismiss it (`endSheet`) if state changes first.
    ///
    /// Return triggers the default (keep) — NSAlert's first button. Escape also
    /// cancels to keep via a local key monitor scoped to this sheet: NSAlert cannot
    /// make one button both the Return default and the Escape cancel, so the monitor
    /// ends the sheet on Escape (and is torn down when the sheet closes by any path).
    @MainActor
    static func present(_ content: SyncDecisionContent,
                        on window: NSWindow,
                        completion: @escaping (SyncDecisionChoice) -> Void) -> NSAlert {
        let alert = makeAlert(content)
        var escapeMonitor: Any?
        alert.beginSheetModal(for: window) { response in
            if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor); escapeMonitor = nil }
            completion(choice(for: response, content: content))
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak alert] event in
            guard event.keyCode == 53,                       // Escape
                  let sheet = alert?.window, sheet.isVisible else { return event }
            window?.endSheet(sheet, returnCode: .cancel)     // → completion → keep (and monitor teardown)
            return nil
        }
        return alert
    }

    /// Map an `NSAlert` sheet response to the unified choice for `content`. Any
    /// non-button response (dismissal) maps to `content.dismissChoice` (keep).
    static func choice(for response: NSApplication.ModalResponse,
                       content: SyncDecisionContent) -> SyncDecisionChoice {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < content.buttons.count else { return content.dismissChoice }
        return content.buttons[index].choice
    }
}
