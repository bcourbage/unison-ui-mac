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
            ?? ProfileWindowController(unisonDirectory: unisonDirectory) { [weak self] profile, items in
                self?.profileSelected(profile, items: items)
            }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        profileWindowController = controller
    }

    private func profileSelected(_ profile: String, items: [StateItem]) {
        log.write("AppDelegate: profile '\(profile)' returned \(items.count) items — opening reconcile window")
        let reconcile = ReconcileWindowController(
            profile: profile,
            items: items,
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
        reconcileWindowController = reconcile
        profileWindowController?.close()

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
    private func abortAllInFlight() {
        profileWindowController?.abortInFlight()
        // Reconcile-window aborts would close it; for now we just leave it
        // open since the failure usually happens during init, before the
        // reconcile window appears.
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
