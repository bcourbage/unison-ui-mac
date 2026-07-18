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
    /// Last SSH version-check result (profile + outcome), cached so the
    /// "Report an Issue" body can include the remote Unison version
    /// without re-probing. Set on every `handleVersionCheckOutcome`.
    private var lastVersionOutcome: (profile: String, outcome: VersionCheck.Outcome)?

    /// Pending restore for a one-shot `-ignorearchives` rescan: the
    /// `.prf` we temporarily injected `ignorearchives = true` into, plus
    /// its exact original contents. Restored the moment init1 has loaded
    /// the pref into Unison's memory (the in-memory value then survives
    /// init2 + the sync, so the archive still rebuilds — but the file is
    /// never permanently changed). See `rescanIgnoringArchives`.
    private var ignoreArchivesRestore: (url: URL, original: String)?

    /// Sentinel comment bracketing our injected line, so a stray copy
    /// (e.g. left by a crash mid-rescan) can be detected + stripped on
    /// next launch without touching a user's own `ignorearchives` line.
    private static let ignoreArchivesMarker =
        "# unison-ui-mac: one-shot -ignorearchives (auto-removed)"

    private let log = TraceLog.shared

    /// Serial queue for the BLOCKING OCaml connect/scan bridge calls —
    /// `init1`, the connection prompt loop, and `init2`. Each parks the
    /// calling thread inside `run_on_ocaml_thread` until OCaml returns;
    /// running them here instead of on the main thread means a slow or
    /// wedged SSH connection (bad host, bad key, bad `servercmd`) can't
    /// beachball the UI. The OCaml-side completion callbacks already hop
    /// back to the main queue, so all UI work stays main-isolated.
    private let connectQueue = DispatchQueue(label: "net.courbage.unison-ui.connect")

    /// Monotonic epoch for the current connect attempt. Bumped whenever
    /// an attempt is superseded or torn down (timeout, user cancel,
    /// fatal/warn abort) so a late callback from an abandoned attempt is
    /// ignored rather than driving the flow against stale UI.
    private var connectGeneration = 0

    /// Fires if the initial connect+scan doesn't resolve (items, a
    /// credential prompt, or an error) within `connectStallTimeout`. Without
    /// it a wedged SSH would leave the window spinning forever with no
    /// way out but force-quit. Lives on the main queue — which is now
    /// free to fire it precisely because the connect is off-main.
    private var connectWatchdog: DispatchWorkItem?

    /// The (profile, generation) the live watchdog belongs to, so a
    /// progress event can re-arm it without the caller threading those
    /// through. Non-nil iff a watchdog is currently armed.
    private var activeConnect: (profile: String, generation: Int)?

    // MARK: - Connection lifecycle state (issue #6, step 2b)

    /// True once the open profile is remote (init1 reported needs_prompt),
    /// i.e. there is an SSH/OCaml connection whose lifecycle we manage.
    /// False for local-only profiles (no connection to close/reopen).
    private var currentProfileIsRemote = false

    /// Whether we currently hold an established remote connection for the
    /// open profile — true from `connection_end` until we close it, false
    /// after a close or for a local profile. Drives whether Rescan reuses
    /// the live connection (init2 only) or must reopen it (init1 → init2).
    private var remoteConnectionOpen = false

    /// Ground-truth auth-cost signal for the current connect: nil until a
    /// connect is observed, `true` if we presented a password sheet,
    /// `false` if the connection came up with no interactive prompt (key
    /// or agent). Reset at the start of each fresh profile open.
    private var connectInteractiveAuthObserved: Bool?

    /// Backup auth-cost signal: set true when the `BatchMode=yes` version
    /// probe authenticated non-interactively (outcome match / compatible /
    /// mismatch — the probe SSH'd in without a password). Consulted only
    /// when `connectInteractiveAuthObserved` is nil.
    private var probeConfirmedNonInteractive = false

    /// The close policy's decision: does reopening this profile's
    /// connection require interactive credentials? Observed connect
    /// dominates; the BatchMode probe is the backup; absent both signals
    /// we default to "interactive" (conservative — never risk closing a
    /// connection whose reopen would silently re-prompt).
    private var requiresInteractiveAuth: Bool {
        if let observed = connectInteractiveAuthObserved { return observed }
        return !probeConfirmedNonInteractive
    }

    /// How long the connect/scan may go WITHOUT PROGRESS before the
    /// watchdog declares a timeout. This is a *stall* timer, not a
    /// total-elapsed budget: every scan-status message from Unison
    /// resets it (see `noteConnectProgress`), so a slow-but-progressing
    /// first scan of a large tree never trips it — only genuine silence
    /// (a hung ssh or a dropped connection) does. That's why a single
    /// generous value works for every profile without a per-profile knob.
    private let connectStallTimeout: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.write("applicationDidFinishLaunching start")

        // Test isolation: when hosted by XCTest, redirect Unison's directory
        // (where it reads profiles and writes `ar*`/`fp*` archives) to a
        // throwaway temp dir, so the suite never touches the user's real
        // ~/Library/Application Support/Unison. Must run BEFORE
        // unison_bridge_startup() below — that's when the OCaml runtime reads
        // $UNISON. (Closes the "isolate test archives" TODO.)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let testDir = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("unison-ui-mac-test-unisondir")
            try? FileManager.default.createDirectory(
                atPath: testDir, withIntermediateDirectories: true)
            setenv("UNISON", testDir, 1)
            log.write("XCTest host detected — UNISON redirected to \(testDir)")
        }

        logEnvSnapshot()

        // Ask for notification permission up front (only if the cue is
        // enabled, which it is by default) so the first sync-complete
        // banner can display. No-op when already determined. Install the
        // presentation delegate too, so banners show even while we're the
        // frontmost app (macOS otherwise suppresses them for the active
        // app and routes them to Notification Center only).
        SyncCompletionAnnouncer.installPresenter()
        SyncCompletionAnnouncer.requestAuthorizationIfEnabled()

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
            guard let self else { return }
            self.log.write("warn dismissed (cancelled=\(cancelled)): \(msg.prefix(120))")
            if cancelled {
                // The engine was answered "proceed" (never "exit", which
                // would quit the app), so the operation is still running.
                // Only flag an abort if a TRANSPORT is in flight — Abort.check
                // observes it there and stops the sync. Do NOT flag during a
                // scan: update detection never consults Abort, and setting the
                // flag mid-scan trips an assertion in update.ml (it's not a
                // no-op, it's actively harmful). A scan instead just finishes
                // in the background; its callback is generation-ignored.
                // (See TODO: scan-phase cancel isn't a true abort.) Either
                // way, tear the UI back down to the picker.
                if self.reconcileWindowController?.isSyncing == true {
                    DispatchQueue.global().async { unison_bridge_abort_sync() }
                }
                self.abortAllInFlight(reason: "cancelled at a warning")
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

        // "Retry Ignoring Archives" on the archive-inconsistency fatal:
        // close the broken reconcile state and re-run the same profile
        // with a one-shot `ignorearchives` override. Mirrors the
        // delete-orphans retry path above, but routes through the
        // .prf-injection helper instead of a plain re-open.
        UnisonBridge.fatalRetryIgnoreArchivesHandler = { [weak self] in
            guard let self, let profile = self.lastAttemptedProfile else { return }
            self.log.write("fatal recovery: retry ignoring archives for '\(profile)'")
            self.abortAllInFlight(reason: "retrying with ignorearchives",
                                  forceClose: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.rescanIgnoringArchives(profile: profile)
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

        // Defensive: strip any stray one-shot `ignorearchives` line left in
        // a .prf by a crash mid-rescan, so it never silently persists.
        Self.cleanupStrayIgnoreArchivesMarkers(in: unisonDirectory)

        showProfilePicker()

        NSApp.activate(ignoringOtherApps: true)

        // If the app crashed on a previous launch, offer (once) to send the
        // macOS crash report. Deferred to the next run-loop turn so the
        // picker is up first and the alert doesn't compete with launch.
        DispatchQueue.main.async { [weak self] in
            self?.checkForPriorCrashReport()
        }

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
            // A status message means the connect/scan is making progress
            // — reset the stall timer so a slow-but-live scan isn't
            // mistaken for a hang.
            self?.noteConnectProgress()
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
                // Leaving the profile ends the work unit: close the remote
                // connection so ssh children don't accumulate for the life
                // of the app. If a sync is still running (the user chose
                // "Close (let it run)" or "Abort & Close"), the transport is
                // still in use — defer the close until the background sync
                // signals completion rather than tearing it out now.
                if self.reconcileWindowController?.isSyncing == true {
                    self.scheduleConnectionCloseAfterSync()
                } else {
                    self.closeRemoteConnection(reason: "left profile")
                }
                self.reconcileWindowController = nil
                // Preserve which profile the user just worked with so
                // it's the highlighted row when they return to the
                // picker — saves a click if they want to re-run, or
                // simply makes the context continuous.
                self.showProfilePicker(select: profile)
            },
            onRescanRequested: { [weak self] in
                self?.rescanCurrentProfile(profile)
            },
            onCancelScan: { [weak self] in
                self?.cancelConnectInProgress(reason: "user pressed Stop")
            },
            onSyncDidComplete: { [weak self] in
                self?.handleSyncDidComplete()
            }
        )
        reconcile.showWindow(nil)
        reconcile.window?.makeKeyAndOrderFront(nil)
        reconcile.beginInitialScan()
        reconcileWindowController = reconcile
        profileWindowController?.close()

        // Fresh work unit: reset the per-profile connection-lifecycle
        // signals so a prior profile's auth/connection state can't leak
        // into this one's close policy.
        currentProfileIsRemote = false
        remoteConnectionOpen = false
        connectInteractiveAuthObserved = nil
        probeConfirmedNonInteractive = false

        // Kick off the SSH version check in the background. It probes
        // the remote with `BatchMode=yes` so it's silent if SSH keys
        // are configured normally — and bails out (no prompt, no
        // alert) if not. Result lands on the main queue; we surface a
        // warning alert ONLY on mismatch AND only if the user hasn't
        // suppressed this particular triple before. Runs in parallel
        // with init1/init2 — by the time Unison's own connection is
        // established, the probe is typically done.
        runVersionCheckIfNeeded(profile: profile)

        // Start a fresh connect attempt (bump epoch + arm watchdog), then
        // open the connection and scan.
        let generation = beginConnectAttempt(profile: profile)
        beginConnectAndScan(profile: profile, generation: generation, reconcile: reconcile)
    }

    /// Install the init1/init2 handlers for `generation` and kick off
    /// init1, populating `reconcile` when the scan completes. Shared by
    /// the first profile open and by a Rescan that must re-establish a
    /// connection we closed on sync-end (issue #6, step 2b).
    private func beginConnectAndScan(profile: String,
                                     generation: Int,
                                     reconcile: ReconcileWindowController?) {
        UnisonBridge.installInit1CompleteHandler { [weak self] needsPrompt in
            guard let self else { return }
            self.log.write("init1 complete (needs_prompt=\(needsPrompt))")
            guard self.isCurrentConnect(generation) else {
                self.log.write("init1 complete ignored — superseded/timed-out attempt")
                return
            }
            // needs_prompt distinguishes a remote root (a connection we
            // manage) from a local-only sync (nothing to close/reopen).
            self.currentProfileIsRemote = needsPrompt
            // init1 ran loadTheFile, so any one-shot `ignorearchives` is
            // now in Unison's in-memory prefs — safe to restore the .prf.
            self.restoreIgnoreArchivesPrfIfNeeded()
            if needsPrompt {
                self.drivePromptLoop(profile: profile, generation: generation)
            } else {
                self.log.write("init1 ok — calling init2")
                // Connect phase done — the scan (init2) is NOT watchdog'd.
                self.disarmConnectWatchdog()
                self.connectQueue.async { unison_bridge_init2() }
            }
        }
        UnisonBridge.installInit2CompleteHandler { [weak self, weak reconcile] items in
            guard let self else { return }
            guard self.isCurrentConnect(generation) else {
                self.log.write("init2 complete ignored — superseded/timed-out attempt")
                return
            }
            // Scan resolved within the window — stand the watchdog down.
            self.disarmConnectWatchdog()
            self.log.write("init2 complete — \(items.count) reconcile items")
            reconcile?.endRescan(newItems: items)
            // Autotest hooks live here so they run after the items land.
            // Compiled out in Release builds.
            #if DEBUG
            self.maybeRunAutotestHooks(reconcile: reconcile, items: items)
            #endif
        }

        // init1 BLOCKS until OCaml resolves the connection — run it off
        // the main thread (see `connectQueue`). The init1-complete
        // callback hops back to main on its own.
        connectQueue.async {
            profile.withCString { unison_bridge_init1($0) }
        }
    }

    /// SSH credential prompt loop. Runs after init1Complete with
    /// `needs_prompt = true`. Sheets are hosted by whichever window is
    /// currently active in the workflow — typically the reconcile window,
    /// since the picker has already closed by this point.
    private var pendingPasswordSheet: PasswordSheet?

    // MARK: - Connect attempt lifecycle (epoch + watchdog)

    /// Open a new connect attempt: bump the epoch and arm the watchdog.
    /// The watchdog covers ONLY the connect phase (init1 + the credential
    /// prompt fetch); it's disarmed before init2. Update detection can run
    /// silently for a long time on a large remote tree, so watchdogging it
    /// would false-fire — and the timeout poking the engine mid-scan is
    /// unsafe (it can trip an `update.ml` assertion or an Lwt "wakeup").
    /// A hung scan is instead handled by off-main + Stop.
    /// Returns the new generation for the init1/init2 handlers to capture.
    @discardableResult
    private func beginConnectAttempt(profile: String) -> Int {
        let generation = newConnectGeneration()
        armConnectWatchdog(profile: profile, generation: generation)
        return generation
    }

    /// Bump the connect epoch WITHOUT arming the watchdog — for rescan,
    /// which is scan-only (no connect phase to guard).
    private func newConnectGeneration() -> Int {
        connectGeneration += 1
        return connectGeneration
    }

    /// True when `generation` is still the live attempt. Handlers check
    /// this before acting so a callback from a timed-out / cancelled /
    /// superseded attempt is ignored.
    private func isCurrentConnect(_ generation: Int) -> Bool {
        generation == connectGeneration
    }

    /// Abandon the current attempt: bump the epoch (so in-flight
    /// callbacks no-op) and stand the watchdog down.
    private func invalidateConnect() {
        connectGeneration += 1
        disarmConnectWatchdog()
    }

    /// Cleanly close the established remote connection. Runs on
    /// `connectQueue` (off-main) because the underlying teardown waits on
    /// the ssh child. Safe/idempotent: a no-op for a local-only profile
    /// or when nothing is connected.
    ///
    /// Caller must ensure the engine is quiescent (no scan/sync in
    /// flight) before invoking — closing under an active transport would
    /// tear it out. See `unison_bridge_close_connection`.
    private func closeRemoteConnection(reason: String) {
        remoteConnectionOpen = false
        connectQueue.async {
            let status = unison_bridge_close_connection()
            // Off-main: log through the thread-safe TraceLog, not `self.log`
            // (which would be a main-actor hop).
            TraceLog.shared.write("closeConnection (\(reason)) -> status \(status)")
        }
    }

    /// A sync completed with the reconcile window still open (see
    /// `ReconcileWindowController.onSyncDidComplete`). Apply the close
    /// policy (issue #6, step 2b): for a non-interactive (key/agent)
    /// profile, close the connection now — a later Rescan reopens
    /// silently and can never reuse a connection that went stale while
    /// idle. For an interactive (password) profile, hold it so a
    /// same-session Rescan/re-sync doesn't re-prompt; it closes when the
    /// user leaves the profile instead.
    private func handleSyncDidComplete() {
        guard remoteConnectionOpen else { return }   // local, or already closed
        if requiresInteractiveAuth {
            log.write("sync complete — holding interactive-auth connection until leave")
        } else {
            log.write("sync complete — closing non-interactive connection")
            closeRemoteConnection(reason: "sync complete, non-interactive")
        }
    }

    /// The reconcile window was closed while a sync was still running
    /// ("Close (let it run)" or "Abort & Close"). Tearing the transport
    /// out now would kill the in-flight sync, so instead close the
    /// connection once the engine signals the sync is done. The window
    /// that owned the sync-complete handler is gone, so we install an
    /// app-level one; it fires once, closes the connection, then stands
    /// itself down so a stray late completion can't re-fire.
    ///
    /// Known limitation (issue #6, step 3): if the user opens another
    /// profile before this background sync finishes, that profile's
    /// reconcile window reinstalls the sync-complete handler and this
    /// deferred close is lost — the connection then falls back to
    /// app-exit reaping. The proper fix is gating profile-reopen on an
    /// engine-idle acknowledgement.
    private func scheduleConnectionCloseAfterSync() {
        log.write("sync still running on close — deferring connection close until it completes")
        UnisonBridge.installSyncCompleteHandler { [weak self] in
            guard let self else { return }
            self.log.write("background sync complete — closing deferred connection")
            self.closeRemoteConnection(reason: "background sync complete after leave")
            UnisonBridge.installSyncCompleteHandler { }   // one-shot: stand down
        }
    }

    /// (Re)schedule the watchdog for `generation`. Replaces any existing
    /// timer, so callers can use it both to reset the clock at each
    /// blocking phase boundary (init1 → prompt fetch → init2) and as the
    /// per-progress reset (`noteConnectProgress`).
    private func armConnectWatchdog(profile: String, generation: Int) {
        connectWatchdog?.cancel()
        activeConnect = (profile, generation)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrentConnect(generation) else { return }
            self.handleConnectTimeout(profile: profile, generation: generation)
        }
        connectWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + connectStallTimeout, execute: item)
    }

    private func disarmConnectWatchdog() {
        connectWatchdog?.cancel()
        connectWatchdog = nil
        activeConnect = nil
    }

    /// Reset the stall timer because the connect/scan reported progress.
    /// Called on every scan-status message while a watchdog is armed, so
    /// a long-but-progressing scan is never mistaken for a hang. No-op
    /// when no attempt is in flight (e.g. status during a sync, or while
    /// a credential sheet is open — both leave the watchdog disarmed).
    private func noteConnectProgress() {
        guard let (profile, generation) = activeConnect,
              isCurrentConnect(generation) else { return }
        armConnectWatchdog(profile: profile, generation: generation)
    }

    /// The connect phase went `connectStallTimeout` seconds without
    /// completing (init1 / the credential prompt fetch). Recover the UI by
    /// returning to the picker. Only fires during the connect phase — the
    /// watchdog is disarmed before the scan (see `beginConnectAttempt`).
    private func handleConnectTimeout(profile: String, generation: Int) {
        guard isCurrentConnect(generation) else { return }
        log.write("connect watchdog: '\(profile)' stalled \(Int(connectStallTimeout))s in connect phase — tearing down")
        // Invalidate first so any late init1/init2 callback (e.g. if the
        // OS eventually fails the ssh) is ignored, including ones that
        // could arrive while the alert below is modal.
        invalidateConnect()
        // Do NOT poke the engine here (no connection_cancel): cancelling a
        // half-open OCaml connection has proven unsafe — it can raise an Lwt
        // "wakeup" / trip an assertion. Recover the UI; a wedged ssh child is
        // harmless and reaped at app exit.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t connect to the remote"
        alert.informativeText =
            "Unison stopped responding while connecting to “\(profile)” "
            + "(no progress for \(Int(connectStallTimeout)) seconds). "
            + "This usually means the SSH host is unreachable, the key in sshargs is wrong, "
            + "or servercmd points at a unison that isn’t there. Check the profile’s root, "
            + "sshargs, and servercmd, then try again."
        alert.addButton(withTitle: "Back to Profiles")
        alert.runModal()
        // Close the spinning reconcile window; its onClose returns to the
        // picker. forceClose because we're not in a sync (isSyncing=false)
        // and want it gone regardless.
        abortAllInFlight(reason: "connect timed out", forceClose: true)
    }

    /// User pressed Stop while the connect/scan was in flight. Mirrors the
    /// timeout teardown minus the alert — they asked for it, no need to
    /// explain. Best-effort cancel of the OCaml connection, then close the
    /// window (→ picker). `abortAllInFlight` invalidates the attempt so a
    /// late callback is ignored.
    private func cancelConnectInProgress(reason: String) {
        log.write("connect: \(reason) — returning to picker")
        // Don't poke the engine: Stop can land during a scan, where
        // connection_cancel/abort can trip an assertion or an Lwt "wakeup".
        // Just tear the UI down to the picker (abortAllInFlight invalidates
        // the attempt so a late callback is ignored); the background op
        // settles on its own and any wedged ssh is reaped at exit. See TODO:
        // a true scan teardown needs caml_callback_exn hardening first.
        abortAllInFlight(reason: reason, forceClose: true)
    }

    private func drivePromptLoop(profile: String, generation: Int) {
        guard isCurrentConnect(generation) else { return }
        // Fetching the next prompt, replying, and ending the connection
        // all BLOCK on the OCaml worker, so run them on connectQueue.
        // Keep the watchdog armed across the (blocking) prompt fetch so a
        // wedge there is still caught; disarm only once we're actually
        // waiting on the user with a sheet open. The post-reply recursion
        // re-arms it for the next fetch.
        armConnectWatchdog(profile: profile, generation: generation)
        connectQueue.async {
            let cstr = unison_bridge_connection_prompt()
            guard let cstr else {
                // TraceLog.shared is thread-safe (the OCaml callbacks log
                // through it off-main too); `self.log` would be a main-actor hop.
                TraceLog.shared.write("connection: no more prompts — connection_end + init2")
                // Connect phase done — disarm on main (the scan is NOT
                // watchdog'd), then run connection_end + init2 on connectQueue.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.disarmConnectWatchdog()
                    // The remote connection is now established. If we reached
                    // here without ever showing a password sheet, this profile
                    // authenticates non-interactively (key/agent) — record it
                    // so the close policy can safely close on sync-end.
                    self.remoteConnectionOpen = true
                    if self.connectInteractiveAuthObserved == nil {
                        self.connectInteractiveAuthObserved = false
                    }
                    self.connectQueue.async {
                        unison_bridge_connection_end()
                        unison_bridge_init2()
                    }
                }
                return
            }
            let prompt = String(cString: cstr)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentConnect(generation) else { return }
                // Now waiting on the user — don't time out while the sheet is open.
                self.disarmConnectWatchdog()
                // We had to prompt: this profile needs interactive auth, so
                // reopening would re-prompt. Hold the connection until leave
                // rather than closing it on sync-end.
                self.connectInteractiveAuthObserved = true
                self.log.write("connection prompt: \(prompt)")
                let sheet = PasswordSheet(prompt: prompt) { [weak self] response in
                    guard let self, self.isCurrentConnect(generation) else { return }
                    self.pendingPasswordSheet = nil
                    guard let response else {
                        self.log.write("connection: user cancelled")
                        self.invalidateConnect()
                        self.connectQueue.async { unison_bridge_connection_cancel() }
                        // Cancelling drops us back to the picker — closing
                        // reconcile triggers the onClose -> showProfilePicker path.
                        self.reconcileWindowController?.close()
                        return
                    }
                    self.connectQueue.async { unison_bridge_connection_reply(response) }
                    // Next cycle re-arms the watchdog for the post-reply fetch.
                    self.drivePromptLoop(profile: profile, generation: generation)
                }
                self.pendingPasswordSheet = sheet
                if let parent = self.reconcileWindowController?.window ?? self.profileWindowController?.window {
                    sheet.runAsSheet(over: parent)
                }
            }
        }
    }

    /// Rescan the currently-open profile.
    ///
    /// If the remote connection is still open (interactive profile held,
    /// or a not-yet-synced non-interactive one), reuse it: re-run init2
    /// only — the profile is loaded and the connection is live. If we
    /// closed it on sync-end (non-interactive, issue #6 step 2b), reopen
    /// first by re-running the full init1 → connection → init2 flow, which
    /// for a key/agent profile is silent. Local profiles have no
    /// connection, so init2-only is always correct there.
    private func rescanCurrentProfile(_ profile: String) {
        guard let reconcile = reconcileWindowController else { return }
        reconcile.beginRescan()

        // Reopen path: remote profile whose connection we closed on
        // sync-end. Re-establish it (init1 arms the connect watchdog so a
        // wedged reopen is still recoverable), then init2 populates.
        if currentProfileIsRemote && !remoteConnectionOpen {
            log.write("rescan: connection was closed — reopening for '\(profile)'")
            let generation = beginConnectAttempt(profile: profile)
            beginConnectAndScan(profile: profile, generation: generation, reconcile: reconcile)
            return
        }

        // Reuse path: connection live (or local profile). init2 BLOCKS too,
        // so run it off-main under a fresh generation (so a late/superseded
        // callback is ignored). NO watchdog: a rescan is pure update
        // detection, which can legitimately run silent for a while on a
        // large remote tree — watchdogging it would false-fire.
        log.write("rescan: re-running init2 for profile '\(profile)'")
        let generation = newConnectGeneration()
        UnisonBridge.installInit2CompleteHandler { [weak self, weak reconcile] items in
            guard let self else { return }
            guard self.isCurrentConnect(generation) else {
                self.log.write("rescan: init2 complete ignored — superseded/timed-out")
                return
            }
            self.disarmConnectWatchdog()
            self.log.write("rescan: init2 complete — \(items.count) items")
            reconcile?.endRescan(newItems: items)
        }
        connectQueue.async { unison_bridge_init2() }
    }

    // MARK: - One-shot -ignorearchives recovery

    /// Recover from an "archive inconsistency" by re-running the profile
    /// once with `ignorearchives = true`. We temporarily append that line
    /// to the profile's `.prf` (which `do_unisonInit1`'s `loadTheFile`
    /// reads into Unison's in-memory prefs), re-run init1/init2, then
    /// restore the original `.prf` the instant init1 has consumed it. The
    /// in-memory pref outlives the file edit — init2 and the subsequent
    /// sync still ignore the archive and rebuild it — but the profile on
    /// disk is left byte-for-byte unchanged. No OCaml bridge change is
    /// needed, which is why this is a `.prf` edit rather than a pref call.
    private func rescanIgnoringArchives(profile: String) {
        let url = URL(fileURLWithPath: unisonDirectory)
            .appendingPathComponent("\(profile).prf")
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            log.write("ignorearchives: cannot read \(url.path)")
            NSSound.beep()
            return
        }
        ignoreArchivesRestore = (url, original)
        let injected = original
            + "\n\(Self.ignoreArchivesMarker)\nignorearchives = true\n"
        do {
            try injected.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.write("ignorearchives: write failed for \(url.path): \(error)")
            ignoreArchivesRestore = nil
            NSSound.beep()
            return
        }
        log.write("ignorearchives: injected into \(profile).prf — re-running profile")
        profileSelected(profile)
    }

    /// Restore the `.prf` we injected into, if any. Idempotent — safe to
    /// call from every completion/teardown path.
    private func restoreIgnoreArchivesPrfIfNeeded() {
        guard let (url, original) = ignoreArchivesRestore else { return }
        ignoreArchivesRestore = nil
        do {
            try original.write(to: url, atomically: true, encoding: .utf8)
            log.write("ignorearchives: restored \(url.lastPathComponent)")
        } catch {
            log.write("ignorearchives: RESTORE FAILED for \(url.path): \(error)")
        }
    }

    /// Action-menu entry point: confirm, then run the one-shot rescan for
    /// the profile currently open in the reconcile window.
    @objc func rescanIgnoringArchivesMenu(_ sender: Any?) {
        guard reconcileWindowController != nil,
              let profile = lastAttemptedProfile else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Rescan ignoring archives?"
        alert.informativeText =
            "Use this to recover from an “archive inconsistency” error. "
            + "Unison will compare the two replicas directly instead of "
            + "using its saved archive.\n\n"
            + "The scan may show more items than usual. Review them before "
            + "you sync. Your profile file is not changed."
        alert.addButton(withTitle: "Rescan Ignoring Archives")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rescanIgnoringArchives(profile: profile)
    }

    /// Strip a stray one-shot `ignorearchives` injection from any `.prf`
    /// carrying our sentinel marker (never a user's own `ignorearchives`
    /// line). Defensive cleanup at launch in case a crash mid-rescan left
    /// the file edited.
    private static func cleanupStrayIgnoreArchivesMarkers(in unisonDirectory: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: unisonDirectory) else { return }
        for name in names where name.hasSuffix(".prf") {
            let url = URL(fileURLWithPath: unisonDirectory).appendingPathComponent(name)
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  content.contains(ignoreArchivesMarker) else { continue }
            let lines = content.components(separatedBy: "\n")
            var kept: [String] = []
            var i = 0
            while i < lines.count {
                if lines[i].contains(ignoreArchivesMarker) {
                    if i + 1 < lines.count,
                       lines[i + 1].trimmingCharacters(in: .whitespaces) == "ignorearchives = true" {
                        i += 2   // drop marker + the injected pref line
                    } else {
                        i += 1   // drop marker only
                    }
                    continue
                }
                kept.append(lines[i])
                i += 1
            }
            try? kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            TraceLog.shared.write("ignorearchives: cleaned stray marker from \(name)")
        }
    }

    // MARK: - Menu validation

    // @objc so AppKit actually consults it during menu validation — a
    // plain Swift method here is invisible to the responder-chain
    // validation path, which left "Rescan Ignoring Archives…" enabled
    // (and a no-op) from the Profile Picker.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(rescanIgnoringArchivesMenu(_:)) {
            // Only meaningful with a reconcile window open on a profile.
            return reconcileWindowController != nil && lastAttemptedProfile != nil
        }
        if menuItem.action == #selector(showSettings(_:)) {
            // Grey out Settings while a profile is being edited (they're
            // mutually exclusive — see isEditProfileFormOpen).
            return !isEditProfileFormOpen
        }
        return true
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
        // Whatever the reason, the current connect attempt is over: stop
        // the watchdog and bump the epoch so any straggler init1/init2
        // callback is ignored rather than re-driving a torn-down window.
        invalidateConnect()
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
        // Cache for the issue-report body (remote Unison version).
        lastVersionOutcome = (profile, outcome)

        // Backup auth-cost signal (issue #6, step 2b): a successful probe
        // (we got a remote version back) means SSH authenticated with
        // `BatchMode=yes`, i.e. non-interactively. Only trust it for the
        // profile still being opened, and only as a fallback — the
        // observed connect (did we show a password sheet?) takes
        // precedence in `requiresInteractiveAuth`.
        if profile == lastAttemptedProfile {
            switch outcome {
            case .match, .compatibleMismatch, .mismatch:
                probeConfirmedNonInteractive = true
            case .noRemoteRoot, .probeFailed:
                break
            }
        }

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
            "here are on opposite sides of that change, so they cannot connect " +
            "to each other. Update the older side to a release >= 2.52.0.\n\n" +
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

    /// True when a single-profile edit form is open. Settings and that form
    /// are mutually exclusive (both can write logging state, which would
    /// diverge from an open, unsaved form).
    private var isEditProfileFormOpen: Bool {
        NSApp.windows.contains {
            ($0.windowController is ProfileFormWindowController) && $0.isVisible
        }
    }

    /// `<appname> → Settings…` (⌘,) — opens the Settings window. Singleton;
    /// reopening just brings the existing instance to front.
    @objc func showSettings(_ sender: Any?) {
        // Backstop: the menu item is disabled while editing (see
        // validateMenuItem), so this normally can't be reached then.
        guard !isEditProfileFormOpen else { return }
        if let existing = settingsWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let settings = SettingsWindowController(unisonDirectory: unisonDirectory)
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
        // Release on close so the next open rebuilds the window from
        // defaults (centering after a layout reset) instead of reusing a
        // stale, retained window object.
        editor.onClose = { [weak self] in self?.profileEditorWindowController = nil }
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
    // MARK: - Post-crash report prompt

    private static let crashReportMarkerKey = "crashReport.lastHandledDate"

    /// Offer (once) to send a crash report if the app crashed since we last
    /// asked. First run seeds the marker to "now" so reports predating this
    /// feature are never surfaced.
    private func checkForPriorCrashReport(defaults: UserDefaults = .standard) {
        guard let marker = defaults.object(forKey: Self.crashReportMarkerKey) as? Date else {
            defaults.set(Date(), forKey: Self.crashReportMarkerKey)
            return
        }
        let found = Self.collectCrashReports()
        guard let newest = CrashReportScanner.newestUnhandled(found.map(\.report), since: marker),
              let entry = found.first(where: { $0.report == newest }) else { return }
        log.write("crash report detected: \(newest.name) — offering to report")
        promptToSendCrashReport(report: newest, url: entry.url, defaults: defaults)
    }

    /// This app's crash reports in the standard macOS locations.
    private static func collectCrashReports() -> [(report: CrashReportScanner.Report, url: URL)] {
        let fm = FileManager.default
        let dirs = ["~/Library/Logs/DiagnosticReports",
                    "~/Library/Logs/DiagnosticReports/Retired"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var out: [(report: CrashReportScanner.Report, url: URL)] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for f in entries {
                let lower = f.lastPathComponent.lowercased()
                // macOS names crash reports "<procName>-<date>.ips"; our
                // process is "unison-ui-mac".
                guard lower.hasPrefix("unison-ui-mac-"), lower.hasSuffix(".ips") else { continue }
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                out.append((CrashReportScanner.Report(name: f.lastPathComponent, modified: mtime), f))
            }
        }
        return out
    }

    private func promptToSendCrashReport(report: CrashReportScanner.Report, url: URL,
                                         defaults: UserDefaults) {
        // Advance the marker first — one offer per crash regardless of the
        // user's choice, so the next launch doesn't re-ask for this report.
        defaults.set(report.modified, forKey: Self.crashReportMarkerKey)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unison-UI-Mac quit unexpectedly last time"
        alert.informativeText =
            "Sending the crash report helps find and fix the problem. It's a "
            + "technical stack trace with no personal data.\n\n"
            + "“Report…” opens a pre-filled GitHub issue and reveals the crash "
            + "report in Finder; just drag it into the issue."
        alert.addButton(withTitle: "Report…")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        revealCrashReportForAttachment(url)
        openIssueReport(context:
            "The app crashed on a previous launch. The macOS crash report "
            + "(`\(report.name)`) has been revealed in Finder. Please drag it into "
            + "this issue. It contains no personal data.")
    }

    /// Copy the `.ips` to a `.txt` in the temp dir (GitHub rejects the
    /// `.ips` extension for attachments) and reveal it in Finder so the
    /// user can drag it straight into the issue. Falls back to revealing
    /// the original on copy failure.
    private func revealCrashReportForAttachment(_ url: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent + ".txt")
        try? FileManager.default.removeItem(at: dest)
        let toReveal: URL
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            toReveal = dest
        } catch {
            toReveal = url
        }
        NSWorkspace.shared.activateFileViewerSelecting([toReveal])
    }

    @objc func reportIssue(_ sender: Any?) {
        openIssueReport()
    }

    /// Open the GitHub new-issue form with a pre-filled body. `context`
    /// (when set) prefills "What happened?" — used by the post-crash
    /// prompt to seed the report.
    func openIssueReport(context: String? = nil) {
        let body = makeIssueReportBody(context: context)
        var components = URLComponents(string: "https://github.com/bcourbage/unison-ui-mac/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Remote-Unison line for the issue report, derived from the last
    /// SSH version-check this session (`lastVersionOutcome`). nil when no
    /// profile was opened yet. The hostname is intentionally omitted
    /// (privacy); the profile name is kept for triage.
    private func remoteUnisonReportLine() -> String? {
        guard let (profile, outcome) = lastVersionOutcome else { return nil }
        let value: String
        switch outcome {
        case .match(let v):                 value = v
        case .compatibleMismatch(_, let r): value = r
        case .mismatch(_, let r, _):        value = r
        case .noRemoteRoot:                 value = "n/a (local-only profile)"
        // Don't surface the raw reason — it embeds the host/IP. The detail
        // is logged (Log.versionCheck) for triage; the report stays clean.
        case .probeFailed:                  value = "probe failed"
        }
        return "- **Remote Unison (profile “\(profile)”):** \(value)"
    }

    /// Builds the pre-filled body for the GitHub new-issue form.
    /// Pure-ish (reads bundle + ProcessInfo + the OCaml bridge); no
    /// side effects. Internal so a future XCTest can pin the shape
    /// against the bug-report template.
    internal func makeIssueReportBody(context: String? = nil) -> String {
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

        // Remote Unison version from the last SSH probe this session (if a
        // profile with a remote root was opened). Blank when there's no
        // remote context — e.g. a crash report filed before any sync.
        let remoteUnisonLine = remoteUnisonReportLine().map { "\n" + $0 } ?? ""

        // "What happened?" is prefilled when we have context (e.g. the
        // post-crash prompt passes the crash summary); otherwise the user
        // fills the placeholder.
        let whatHappened = context ?? "<!-- Describe the unexpected behavior. -->"

        // Keep this SHORT — a wall of text just doesn't get read. The
        // Environment block is auto-filled (the valuable, zero-effort part);
        // the user only writes "what happened". Crash reports are handled
        // automatically by the post-crash prompt, so there's no need to
        // explain the `.ips` dance here; logs are a one-line footnote for
        // the rare non-crash case where they're asked for.
        return """
        ## Environment

        - **App version:** \(appVersion)
        - **Embedded Unison:** \(unisonVersion)\(remoteUnisonLine)
        - **macOS:** \(osVersion)
        - **Architecture:** \(arch)

        ## What happened?

        \(whatHappened)

        ## Steps to reproduce

        1.
        2.

        ---
        <sub>If the app crashed, it offers to attach the crash report the next time you open it. Logs (only if asked): <code>log show --predicate 'subsystem == "net.courbage.unison-ui-mac"' --info --debug --last 30m</code></sub>
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
