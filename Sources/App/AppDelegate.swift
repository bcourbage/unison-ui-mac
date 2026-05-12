import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var profileWindowController: ProfileWindowController?
    private var reconcileWindowController: ReconcileWindowController?
    private var unisonDirectory: String = ""

    private let log = TraceLog.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.write("applicationDidFinishLaunching start")
        logEnvSnapshot()

        UnisonBridge.installStatusHandler { [log] status in
            log.write("[ocaml→status] \(status)")
        }
        UnisonBridge.installProgressHandler { [log] fraction in
            log.write("[ocaml→progress] \(fraction)")
        }
        // Modal warning + fatal-error sheets. Install before any OCaml call
        // that might warn — the OCaml worker thread blocks on user dismissal.
        // On fatal (or on warn-cancel) the in-flight init1/init2 won't fire
        // its completion handler; we have to reset the busy UI ourselves.
        UnisonBridge.installWarnHandler { [weak self] msg, cancelled in
            self?.log.write("warn dismissed (cancelled=\(cancelled)): \(msg.prefix(120))")
            if cancelled {
                self?.abortAllInFlight()
            }
        }
        UnisonBridge.installFatalHandler { [weak self] msg in
            self?.log.write("fatal dismissed: \(msg.prefix(120))")
            self?.abortAllInFlight()
        }

        // Spin up the OCaml runtime on its dedicated thread. This blocks
        // briefly (~hundreds of ms) — acceptable during launch.
        //
        // Pass only argv[0]: OCaml's Prefs.parseCmdLine rejects anything it
        // doesn't recognize. macOS / XCTest pass us flags like
        // `-NSTreatUnknownArgumentsAsOpen` which would cause Unison to print
        // its help text and exit. The GUI doesn't expose CLI args — profile
        // selection happens through the picker — so a clean argv is correct.
        let programName = CommandLine.arguments.first ?? "unison-ui-mac"
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(programName), nil]
        cArgs.withUnsafeMutableBufferPointer { buf in
            unison_bridge_startup(1, buf.baseAddress)
        }
        for p in cArgs { free(p) }

        if let v = unison_bridge_get_version() {
            log.write("unison bridge ready: \(String(cString: v))")
        }

        // Wire Trace.messageDisplayer := displayStatus on the OCaml side.
        // Without this, Trace.status output bypasses our handler and goes
        // straight to stderr.
        unison_bridge_init0()

        if let cstr = unison_bridge_unison_directory() {
            unisonDirectory = String(cString: cstr)
        } else {
            unisonDirectory = NSString(string: "~/Library/Application Support/Unison")
                .expandingTildeInPath
        }

        showProfilePicker()

        NSApp.activate(ignoringOtherApps: true)

        // Dev-only autotest hook: if UNISON_AUTOTEST_PROFILE is set, select it
        // and trigger init1 right away. Lets us exercise the init flow from
        // CLI without UI automation.
        if let autoProfile = ProcessInfo.processInfo.environment["UNISON_AUTOTEST_PROFILE"] {
            log.write("AUTOTEST: triggering profile '\(autoProfile)'")
            profileWindowController?.autoSelectAndOpen(profile: autoProfile)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Window management

    private func showProfilePicker() {
        // If a reconcile window is up, close it first — the workflow is
        // single-window: picker OR reconcile, not both.
        if let reconcile = reconcileWindowController {
            reconcile.window?.delegate = nil  // skip the onClose -> showPicker recursion
            reconcile.close()
            reconcileWindowController = nil
        }
        let controller = profileWindowController
            ?? ProfileWindowController(unisonDirectory: unisonDirectory) { [weak self] profile in
                self?.profileSelected(profile)
            }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        profileWindowController = controller
    }

    /// User picked a profile in the picker. Open the reconcile window
    /// in its "scanning" state immediately, then drive init1 → (prompts) →
    /// init2 → populate. The user sees the destination window right away
    /// rather than waiting in the picker.
    private func profileSelected(_ profile: String) {
        log.write("AppDelegate: profile '\(profile)' picked — opening reconcile window in scanning state")

        // Mirror OCaml status messages into the reconcile window's summary
        // line so the user sees "Looking for changes ..." live. Also keep
        // logging to TraceLog for dev visibility.
        UnisonBridge.installStatusHandler { [weak self] msg in
            TraceLog.shared.write("[ocaml→status] \(msg.prefix(200))")
            self?.reconcileWindowController?.updateScanStatus(msg)
        }

        let reconcile = ReconcileWindowController(
            profile: profile,
            onClose: { [weak self] in
                guard let self else { return }
                self.log.write("reconcile window closed — returning to picker")
                self.reconcileWindowController = nil
                self.showProfilePicker()
            },
            onRescanRequested: { [weak self] in
                self?.rescanCurrentProfile(profile)
            }
        )
        reconcile.showWindow(nil)
        reconcile.window?.makeKeyAndOrderFront(nil)
        reconcile.beginInitialScan()
        reconcileWindowController = reconcile
        profileWindowController?.close()

        // Wire init1/init2 handlers, then kick off init1. Init2Complete will
        // populate the reconcile window via endRescan/replaceItems.
        UnisonBridge.installInit1CompleteHandler { [weak self] needsPrompt in
            self?.log.write("init1 complete (needs_prompt=\(needsPrompt))")
            guard let self else { return }
            if needsPrompt {
                self.drivePromptLoop()
            } else {
                self.log.write("init1 ok — calling init2")
                unison_bridge_init2()
            }
        }
        UnisonBridge.installInit2CompleteHandler { [weak self, weak reconcile] items in
            self?.log.write("init2 complete — \(items.count) reconcile items")
            reconcile?.endRescan(newItems: items)
            // Autotest hooks live here so they run after the items land.
            self?.maybeRunAutotestHooks(reconcile: reconcile, items: items)
        }

        profile.withCString { unison_bridge_init1($0) }
    }

    /// SSH credential prompt loop. Runs after init1Complete with
    /// `needs_prompt = true`. Sheets are hosted by whichever window is
    /// currently active in the workflow — typically the reconcile window,
    /// since the picker has already closed by this point.
    private var pendingPasswordSheet: PasswordSheet?

    private func drivePromptLoop() {
        guard let cstr = unison_bridge_connection_prompt() else {
            log.write("connection: no more prompts — calling connection_end + init2")
            unison_bridge_connection_end()
            unison_bridge_init2()
            return
        }
        let prompt = String(cString: cstr)
        log.write("connection prompt: \(prompt)")
        let sheet = PasswordSheet(prompt: prompt) { [weak self] response in
            guard let self else { return }
            self.pendingPasswordSheet = nil
            guard let response else {
                self.log.write("connection: user cancelled")
                unison_bridge_connection_cancel()
                // Cancelling drops us back to the picker — closing reconcile
                // triggers the onClose -> showProfilePicker path.
                self.reconcileWindowController?.close()
                return
            }
            unison_bridge_connection_reply(response)
            self.drivePromptLoop()
        }
        pendingPasswordSheet = sheet
        if let parent = reconcileWindowController?.window ?? profileWindowController?.window {
            sheet.runAsSheet(over: parent)
        }
    }

    /// Re-run init2 against the currently-open profile without re-running
    /// init1 (the profile is already loaded, the SSH connection (if any)
    /// is established). When init2Complete fires we ask the reconcile
    /// window to replace its items in place.
    private func rescanCurrentProfile(_ profile: String) {
        guard let reconcile = reconcileWindowController else { return }
        log.write("rescan: re-running init2 for profile '\(profile)'")
        reconcile.beginRescan()
        UnisonBridge.installInit2CompleteHandler { [weak self, weak reconcile] items in
            self?.log.write("rescan: init2 complete — \(items.count) items")
            reconcile?.endRescan(newItems: items)
        }
        unison_bridge_init2()
    }

    private func maybeRunAutotestHooks(reconcile: ReconcileWindowController?, items: [StateItem]) {
        if ProcessInfo.processInfo.environment["UNISON_AUTOTEST_RI_OPS"] != nil {
            log.write("AUTOTEST_RI_OPS: starting direction-override test")
            DispatchQueue.main.async { [weak self] in
                self?.runRiOpsAutotest(items: items)
            }
        }
        if ProcessInfo.processInfo.environment["UNISON_AUTOTEST_SYNC"] != nil {
            log.write("AUTOTEST_SYNC: triggering startSync")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak reconcile] in
                reconcile?.startSync()
            }
        }
    }

    private func runRiOpsAutotest(items: [StateItem]) {
        guard items.indices.contains(0) else { return }
        // Cycle all 4 actions on row 0 to verify each transition reaches OCaml
        // and the direction reads back correctly.
        var current = items[0].direction
        for action in [DirectionAction.toRemote, .toLocal, .skip, .merge, .toRemote] {
            let raw: String? = {
                switch action {
                case .toRemote: return unison_bridge_ri_set_to_remote(0).flatMap { String(cString: $0) }
                case .toLocal:  return unison_bridge_ri_set_to_local(0).flatMap { String(cString: $0) }
                case .skip:     return unison_bridge_ri_set_skip(0).flatMap { String(cString: $0) }
                case .merge:    return unison_bridge_ri_set_merge(0).flatMap { String(cString: $0) }
                }
            }()
            log.write("  row 0 (\(items[0].path)): \(current) --[\(action.label)]--> \(raw ?? "<nil>")")
            current = raw ?? current
        }
    }

    // MARK: - Error recovery

    /// Reset every active window's in-flight UI state. Called after a fatal
    /// alert is dismissed — OCaml's worker thread is unwinding past the
    /// failure point, so no completion callback will arrive on its own.
    /// Strategy now that the scan happens in the reconcile window: close
    /// the reconcile window, which routes via onClose back to the picker.
    private func abortAllInFlight() {
        if let sheet = pendingPasswordSheet?.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        pendingPasswordSheet = nil
        if let reconcile = reconcileWindowController {
            log.write("abortAllInFlight: closing reconcile window")
            reconcile.close()
            // onClose handler will reopen the picker.
        }
    }

    // MARK: - Diagnostics

    private func logEnvSnapshot() {
        let env = ProcessInfo.processInfo.environment
        let keys = ["HOME", "USER", "PATH", "SSH_AUTH_SOCK", "TMPDIR", "SHELL", "LANG"]
        for k in keys {
            log.write("env \(k)=\(env[k] ?? "<unset>")")
        }
        let fm = FileManager.default
        for path in ["/Users/bcourbage/.ssh", "/Users/bcourbage/.ssh/Demeter", "/Users/bcourbage/.ssh/known_hosts"] {
            log.write("readable \(path): \(fm.isReadableFile(atPath: path))")
        }
    }

    // MARK: - Menu actions

    @objc func newProfile(_ sender: Any?) {
        log.write("menu: New Profile (not yet implemented)")
        NSSound.beep()
    }

    @objc func openProfile(_ sender: Any?) {
        log.write("menu: Open Profile -> showing picker")
        showProfilePicker()
    }
}
