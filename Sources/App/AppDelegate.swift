import AppKit
import Darwin   // utsname / uname for arch detection in reportIssue body

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var profileWindowController: ProfileWindowController?
    private var reconcileWindowController: ReconcileWindowController?
    /// "Profile Editor" manager window (lists every .prf, supports
    /// edit/duplicate/rename/delete/reorder/hide). One at a time;
    /// reopened = brought to front. The manager owns the single-profile
    /// form internally, so AppDelegate doesn't need to track it.
    private var profileEditorWindowController: ProfileEditorWindowController?
    /// Settings window — `<appname> → Settings…` (⌘,). One at a time;
    /// reopening just brings the existing instance to front.
    private var settingsWindowController: SettingsWindowController?
    private var unisonDirectory: String = ""
    /// Tracks the profile we last asked OCaml to load. Used by the fatal
    /// recovery path to re-run init1+init2 against the same profile after
    /// the user accepts an "auto-fix" action (e.g. orphan archive cleanup).
    private var lastAttemptedProfile: String?

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
                self?.abortAllInFlight(reason: "you cancelled the warning")
            }
        }
        UnisonBridge.installFatalHandler { [weak self] msg, shouldRetry in
            guard let self else { return }
            self.log.write("fatal dismissed (retry=\(shouldRetry)): \(msg.prefix(120))")
            if shouldRetry, let profile = self.lastAttemptedProfile {
                self.log.write("recovery: re-running profileSelected for '\(profile)'")
                // Retry path: force the window closed so the deferred
                // profileSelected can open a fresh one. Keeping the
                // window in place would race the new init1+init2 calls
                // against stale state.
                self.abortAllInFlight(reason: "retrying after recovery",
                                      forceClose: true)
                // Tiny defer so the reconcile-window close has flushed
                // before we re-open with the same profile.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.profileSelected(profile)
                }
            } else {
                self.abortAllInFlight(reason: "fatal error")
            }
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
        // CLI without UI automation. Compiled out in Release builds — see the
        // top-of-file comment on the `#if DEBUG` block at the end.
        #if DEBUG
        if let autoProfile = ProcessInfo.processInfo.environment["UNISON_AUTOTEST_PROFILE"] {
            log.write("AUTOTEST: triggering profile '\(autoProfile)'")
            profileWindowController?.autoSelectAndOpen(profile: autoProfile)
        }
        #endif
    }

    /// Last hook before the process exits. The OCaml runtime is still
    /// alive here — we use it to release our retained generational
    /// global roots (preconnection + per-row stateItems) so
    /// leak-checking tools (`leaks(1)`, ASan) don't flag them as
    /// retained OCaml values. Mostly cosmetic since macOS tears down
    /// the runtime on process exit anyway; the hygiene matters for
    /// release-gate `make leaks` runs.
    func applicationWillTerminate(_ notification: Notification) {
        log.write("applicationWillTerminate — releasing bridge roots")
        unison_bridge_shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Window management

    private func showProfilePicker(select: String? = nil) {
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
        // Apply explicit selection AFTER showing/keying — the
        // `windowDidBecomeKey` auto-reload would otherwise overwrite
        // our preference. `reloadProfiles(select:)` runs through
        // `reload(preferredSelection:)` which honors the request.
        if let select {
            controller.reloadProfiles(select: select)
        }
        profileWindowController = controller
    }

    /// User picked a profile in the picker. Open the reconcile window
    /// in its "scanning" state immediately, then drive init1 → (prompts) →
    /// init2 → populate. The user sees the destination window right away
    /// rather than waiting in the picker.
    private func profileSelected(_ profile: String) {
        log.write("AppDelegate: profile '\(profile)' picked — opening reconcile window in scanning state")
        lastAttemptedProfile = profile

        // Mirror OCaml status messages into the reconcile window's summary
        // line so the user sees "Looking for changes ..." live. Also keep
        // logging to TraceLog for dev visibility.
        UnisonBridge.installStatusHandler { [weak self] msg in
            TraceLog.shared.write("[ocaml→status] \(msg.prefix(200))")
            self?.reconcileWindowController?.updateScanStatus(msg)
        }

        // Inspect the .prf for a `merge` pref so the reconcile window
        // knows whether to surface the Merge toolbar item / menu entry.
        // The `merge` pref is a Pred (list of pathspec→cmd rules) — we
        // treat the presence of any `merge = …` line as "configured".
        // We don't follow `include` directives; a merge declared in an
        // inherited profile would slip through, but that's rare and the
        // worst case is just an unhelpful Merge button (existing
        // behavior).
        let mergeConfigured = Self.readMergeConfigured(
            unisonDirectory: unisonDirectory, profile: profile
        )
        log.write("profile '\(profile)' mergeConfigured=\(mergeConfigured)")

        let reconcile = ReconcileWindowController(
            profile: profile,
            mergeConfigured: mergeConfigured,
            onClose: { [weak self] in
                guard let self else { return }
                self.log.write("reconcile window closed — returning to picker")
                self.reconcileWindowController = nil
                // Preserve which profile the user just worked with so
                // it's the highlighted row when they return to the
                // picker — saves a click if they want to re-run, or
                // simply makes the context continuous.
                self.showProfilePicker(select: profile)
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

        // Kick off the SSH version check in the background. It probes
        // the remote with `BatchMode=yes` so it's silent if SSH keys
        // are configured normally — and bails out (no prompt, no
        // alert) if not. Result lands on the main queue; we surface a
        // warning alert ONLY on mismatch AND only if the user hasn't
        // suppressed this particular triple before. Runs in parallel
        // with init1/init2 — by the time Unison's own connection is
        // established, the probe is typically done.
        runVersionCheckIfNeeded(profile: profile)

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
            // Compiled out in Release builds.
            #if DEBUG
            self?.maybeRunAutotestHooks(reconcile: reconcile, items: items)
            #endif
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

    // MARK: - Autotest hooks (Debug-only)
    //
    // The `UNISON_AUTOTEST_*` env vars exist so we can exercise the
    // init1 → init2 → ri-set → sync flow from the command line without
    // UI automation. They're explicitly NOT for end users — they bypass
    // the picker, mutate row state without confirmation, and trigger
    // a real sync. Hence #if DEBUG so the entire block compiles out
    // of Release builds.

    #if DEBUG
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
        // Cycle every action on row 0 to verify each transition reaches
        // OCaml and the direction reads back correctly. Uses
        // `DirectionAction.invoke` so the autotest exercises the same
        // bridge path as the toolbar/menu actions — no duplicate switch
        // here that would drift from the enum.
        var current = items[0].direction
        let cycle: [DirectionAction] = [
            .toSecond, .toFirst, .skip, .merge, .forceOlder, .forceNewer, .toSecond,
        ]
        for action in cycle {
            let raw = action.invoke(row: 0).flatMap { String(cString: $0) }
            log.write("  row 0 (\(items[0].path)): \(current) --[\(action.label)]--> \(raw ?? "<nil>")")
            current = raw ?? current
        }
    }
    #endif

    // MARK: - Error recovery

    /// Reset every active window's in-flight UI state. Called after a
    /// fatal or warn-cancel alert is dismissed — OCaml's worker thread
    /// is unwinding past the failure point, so no completion callback
    /// will arrive on its own.
    ///
    /// **Reconcile-window strategy depends on phase:**
    /// - **Reconcile phase** (`!isSyncing`): the user has no per-row
    ///   detail to inspect yet (init1/init2 either never produced rows
    ///   or aborted partway). Close the window so the picker comes
    ///   back. The user can re-pick the profile to try again.
    /// - **Sync phase** (`isSyncing`): rows have completed-or-FAILED
    ///   progress text that's user-actionable info. Reset the sync UI
    ///   in place (clear progress bar, flip `isSyncing` to false,
    ///   update the summary line to "Sync interrupted") and keep the
    ///   window open. The user can then inspect FAILED rows, retry,
    ///   or close manually.
    /// - **Force-close override** (`forceClose: true`): the retry path
    ///   needs a fresh reconcile window (it calls `profileSelected`
    ///   to re-run init1+init2). Close regardless of phase. The
    ///   caller is responsible for the re-open after a short deferral.
    ///
    /// `reason` is appended to the in-place summary text so the user
    /// sees why the abort happened ("fatal error" vs "you cancelled
    /// the warning").
    private func abortAllInFlight(reason: String, forceClose: Bool = false) {
        if let sheet = pendingPasswordSheet?.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        pendingPasswordSheet = nil
        guard let reconcile = reconcileWindowController else { return }
        if forceClose || !reconcile.isSyncing {
            log.write("abortAllInFlight: closing reconcile window (forceClose=\(forceClose), reason=\(reason))")
            reconcile.close()
            // onClose handler will reopen the picker.
        } else {
            log.write("abortAllInFlight: sync was in-flight — resetting UI in place (reason=\(reason))")
            reconcile.resetSyncUIAfterAbort(reason: reason)
        }
    }

    /// Spawn the SSH version probe for the given profile, surface a
    /// "version mismatch" alert if the result warrants it. No-op for
    /// local-only profiles (no SSH root). Silent on probe failure —
    /// Unison's own connection error will speak to any real problem.
    ///
    /// Runs in the background; completion comes back on the main
    /// queue and may show a modal alert *while init1/init2 is still
    /// running*. That's fine — init1/init2 are async on the OCaml
    /// side and don't block on the main queue.
    private func runVersionCheckIfNeeded(profile: String) {
        guard let localBridgeVersion = unison_bridge_get_version().map({ String(cString: $0) }) else {
            Log.versionCheck.warning("version check: unison_bridge_get_version returned nil")
            return
        }
        Log.versionCheck.info("starting version check for profile '\(profile, privacy: .public)'")
        VersionCheck.run(
            profile: profile,
            unisonDirectory: unisonDirectory,
            localBridgeVersion: localBridgeVersion
        ) { [weak self] outcome in
            self?.handleVersionCheckOutcome(outcome, profile: profile)
        }
    }

    @MainActor
    private func handleVersionCheckOutcome(_ outcome: VersionCheck.Outcome,
                                           profile: String) {
        switch outcome {
        case .match(let v):
            Log.versionCheck.info("version match: \(v, privacy: .public) on both sides")
        case .compatibleMismatch(let local, let remote):
            // Different versions but both on the same side of the
            // 2.52 wire-protocol boundary — feature negotiation
            // handles it. No alert, just a log line for diagnosis
            // if the user later reports something odd.
            Log.versionCheck.info(
                "compatible-mismatch \(local, privacy: .public) ↔ \(remote, privacy: .public) — new wire protocol negotiates, no alert"
            )
        case .noRemoteRoot:
            Log.versionCheck.info("no remote root in profile '\(profile, privacy: .public)' — skipping")
        case .probeFailed(let reason):
            Log.versionCheck.info("probe skipped/failed: \(reason, privacy: .public)")
        case .mismatch(let local, let remote, let host):
            if VersionCheck.Suppression.isSuppressed(host: host, local: local, remote: remote) {
                Log.versionCheck.info(
                    "mismatch \(local, privacy: .public) ↔ \(remote, privacy: .public) on \(host, privacy: .public) — suppressed"
                )
                return
            }
            Log.versionCheck.notice(
                "mismatch \(local, privacy: .public) ↔ \(remote, privacy: .public) on \(host, privacy: .public) — surfacing alert"
            )
            showVersionMismatchAlert(local: local, remote: remote, host: host)
        }
    }

    @MainActor
    private func showVersionMismatchAlert(local: String, remote: String, host: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unison wire-protocol incompatibility"
        alert.informativeText =
            "This Mac has Unison \(local). The remote (\(host)) is running \(remote). " +
            "Unison changed its wire protocol at version 2.52.0, and the two sides " +
            "here are on opposite sides of that change — they cannot connect to " +
            "each other. Update the older side to a release >= 2.52.0.\n\n" +
            "Upstream FAQ: https://github.com/bcpierce00/unison/wiki/FAQ"
        // NSAlert.showsSuppressionButton is purpose-built for this —
        // adds a checkbox the user toggles, no need for a custom
        // accessoryView.
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't remind me again for this host (until either version changes)"
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
        if alert.suppressionButton?.state == .on {
            VersionCheck.Suppression.suppress(host: host, local: local, remote: remote)
            Log.versionCheck.info(
                "user suppressed mismatch alert for \(host, privacy: .public) @ \(local, privacy: .public)/\(remote, privacy: .public)"
            )
        }
    }

    /// Returns true if the profile's `.prf` contains at least one
    /// `merge = …` line. Reads + parses the .prf file directly rather
    /// than going through OCaml — there's no upstream callback for
    /// querying a Pred's contents and patching `uimacbridge.ml` is
    /// off-limits for this project.
    ///
    /// Failures (missing file, parse error) return `false` — better to
    /// hide a useful button than show a non-functional one. The
    /// reconcile window's existing fatal-error path will surface any
    /// real "profile won't load" condition.
    private static func readMergeConfigured(unisonDirectory: String,
                                            profile: String) -> Bool {
        let url = URL(fileURLWithPath: unisonDirectory)
            .appendingPathComponent("\(profile).prf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let doc = ProfileDocument.parse(text)
        return !doc.values(forKey: "merge").isEmpty
    }

    // MARK: - Diagnostics

    private func logEnvSnapshot() {
        let env = ProcessInfo.processInfo.environment
        let keys = ["HOME", "USER", "PATH", "SSH_AUTH_SOCK", "TMPDIR", "SHELL", "LANG"]
        for k in keys {
            log.write("env \(k)=\(env[k] ?? "<unset>")")
        }
        // Log SSH-key reachability — useful diagnostic when remote
        // connections fail with "Permission denied (publickey)". We
        // enumerate ~/.ssh dynamically (rather than checking specific
        // filenames) so the log is portable across users and key
        // layouts. Log only filenames + readability — never key
        // contents. Missing directory is fine (no SSH configured).
        let fm = FileManager.default
        let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        log.write("readable \(sshDir): \(fm.isReadableFile(atPath: sshDir))")
        if let entries = try? fm.contentsOfDirectory(atPath: sshDir) {
            for entry in entries.sorted() {
                let full = (sshDir as NSString).appendingPathComponent(entry)
                log.write("readable \(sshDir)/\(entry): \(fm.isReadableFile(atPath: full))")
            }
        }
    }

    // MARK: - Menu actions

    /// `<appname> → Settings…` (⌘,) — opens the Settings window. Singleton;
    /// reopening just brings the existing instance to front. The window
    /// itself owns its content (see SettingsWindowController).
    @objc func showSettings(_ sender: Any?) {
        if let existing = settingsWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let settings = SettingsWindowController()
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
        settingsWindowController = settings
    }

    /// Edit → Profile Editor…  — opens the multi-profile manager window
    /// with the full list of .prf files. From there the user can
    /// edit/delete/reorder/hide; changes feed back to the picker via
    /// the manager's onProfilesChanged callback.
    @objc func showProfileEditor(_ sender: Any?) {
        if let existing = profileEditorWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let editor = ProfileEditorWindowController(
            unisonDirectory: unisonDirectory
        ) { [weak self] in
            // Picker preferences (hide / order) changed, or a profile was
            // saved/deleted — refresh the picker to reflect the new state.
            self?.profileWindowController?.reloadProfiles()
        }
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        profileEditorWindowController = editor
    }

    @objc func openUnisonProjectHelp(_ sender: Any?) {
        // The Unison reference manual, rendered as HTML and bundled in
        // the .app's Resources directory by `make vendor-manual`
        // (hevea — upstream's own TeX→HTML toolchain). Opens in the
        // user's default browser via NSWorkspace; works offline.
        //
        // Look up by filename prefix rather than hardcoding the
        // version, so bumping the vendored manual to a new Unison
        // version (e.g. `unison-manual-2.55.0.html`) doesn't silently
        // fall through to the wiki fallback. We just pick the first
        // match — only one `unison-manual-*.html` ships per build.
        if let urls = Bundle.main.urls(forResourcesWithExtension: "html",
                                       subdirectory: nil),
           let manualURL = urls.first(where: {
               $0.lastPathComponent.hasPrefix("unison-manual-")
           }) {
            NSWorkspace.shared.open(manualURL)
            return
        }
        // Fall back to upstream's wiki if the bundled resource is
        // missing — defensive for builds done before this resource
        // was added, or hand-stripped bundles.
        if let url = URL(string: "https://github.com/bcpierce00/unison/wiki") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openUiMacHelp(_ sender: Any?) {
        // Help for THIS UI specifically. Points at MANUAL.md — the
        // feature-by-feature user guide — rather than the README,
        // which is more developer-oriented (build steps, architecture).
        // The repo is currently private, so non-collaborators get a
        // sign-in prompt; flip the repo public to unblock that (see
        // P3 "Public help target" in TODO.md).
        if let url = URL(string: "https://github.com/bcourbage/unison-ui-mac/blob/main/MANUAL.md") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Help → "Report an Issue". Opens GitHub's new-issue form with
    /// an Environment block pre-filled — app version, embedded Unison
    /// version, macOS version, architecture. The repo's
    /// `.github/ISSUE_TEMPLATE/bug_report.md` provides the rest of
    /// the structure when the user clicks New Issue from the GitHub
    /// UI directly; we override the body here because GitHub's URL
    /// API can't combine `?template=` and `?body=` (body wins), and
    /// the highest-value thing we can pre-fill is the version info
    /// the user would otherwise have to look up.
    @objc func reportIssue(_ sender: Any?) {
        let body = makeIssueReportBody()
        var components = URLComponents(string: "https://github.com/bcourbage/unison-ui-mac/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Builds the pre-filled body for the GitHub new-issue form.
    /// Pure-ish (reads bundle + ProcessInfo + the OCaml bridge); no
    /// side effects. Internal so a future XCTest can pin the shape
    /// against the bug-report template.
    internal func makeIssueReportBody() -> String {
        // App version: prefer the human-facing CFBundleShortVersionString
        // ("0.1.0"); fall back to CFBundleVersion ("1") if absent.
        let info = Bundle.main.infoDictionary
        let marketing = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info?["CFBundleVersion"] as? String) ?? "unknown"
        let appVersion = "\(marketing) (build \(build))"

        // Embedded Unison version comes from the OCaml bridge — same
        // call the About panel uses. This is the line the user could
        // otherwise only get from About, so pre-filling it removes
        // the most common bug-report friction.
        let unisonVersion = unison_bridge_get_version().map { String(cString: $0) } ?? "unknown"

        // macOS version + architecture. operatingSystemVersionString
        // returns something like "Version 15.0 (Build 24A335)" —
        // verbose but unambiguous; bug reports thank us for it later.
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        // ARM64 vs x86_64 — relevant since we ship arm64-only. The
        // `utsname.machine` field is a fixed-size C char array;
        // `withUnsafeBytes` + `String(cString:)` reads it without
        // hardcoding the buffer size.
        var sysinfo = utsname()
        uname(&sysinfo)
        let arch = withUnsafeBytes(of: &sysinfo.machine) { rawBuffer in
            rawBuffer.bindMemory(to: CChar.self).baseAddress
                .map { String(cString: $0) } ?? "unknown"
        }

        // The body is plain Markdown — GitHub's new-issue form
        // renders it as Markdown in the preview tab. The "What
        // happened?" / "Steps to reproduce" headers nudge the user
        // toward an actionable report; the Environment block at the
        // top is what bug triage needs first.
        return """
        ## Environment

        - **App version:** \(appVersion)
        - **Embedded Unison:** \(unisonVersion)
        - **macOS:** \(osVersion)
        - **Architecture:** \(arch)

        ## What happened?

        <!-- Describe the unexpected behavior. -->

        ## Steps to reproduce

        1.
        2.
        3.

        ## Expected behavior

        <!-- What should have happened instead? -->

        ## Logs (optional but helpful)

        <details>
        <summary>Unified log slice</summary>

        ```
        # Capture and paste:
        # log show --predicate 'subsystem == "net.courbage.unison-ui-mac"' --last 10m
        ```

        </details>
        """
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let unisonVersion = unison_bridge_get_version().map { String(cString: $0) } ?? "unknown"
        // We can't put HTML in NSAttributedString easily via the about
        // panel's "Credits" key without an RTF, so plain attributed text
        // with the Unison version + GPL attribution is the path of least
        // resistance.
        // The About panel's credits area is narrow and wraps automatically,
        // so we use single-line paragraphs separated by blank lines and
        // let AppKit do the wrapping. Avoid hardcoded newlines inside a
        // paragraph — they produce mid-sentence breaks at narrow widths.
        let credits = NSAttributedString(
            string: """
                A native macOS UI for Unison File Synchronizer.

                Embeds Unison \(unisonVersion).

                Distributed under the GNU GPL v3, like the upstream project. See NOTICE.md in the source tree for attribution.
                """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        // Use the bundle's display name (CFBundleDisplayName → "Unison-UI-Mac")
        // rather than a hardcoded string so the About panel title follows
        // any future rename done through the plist.
        let info = Bundle.main.infoDictionary
        let appName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Unison-UI-Mac"
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: appName,
        ])
    }
}
