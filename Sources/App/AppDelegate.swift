import AppKit
import Darwin   // utsname / uname for arch detection in reportIssue body

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, EngineActivityProviding {

    private var profileWindowController: ProfileWindowController?
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

    /// The in-flight SSH version probe and the session it belongs to. Kept so
    /// the probe can be cancelled on profile replacement, window close, or
    /// shutdown, and so a slow result is dropped when its session is no longer
    /// current — a stale probe must never update a replacement profile (#12).
    private var activeVersionProbe: VersionCheck.Handle?
    private var versionProbeSession: SessionID?

    /// APP-GLOBAL diff-request broker. The OCaml diff result carries no request
    /// id and is delivered through a single permanent handler, so at most one
    /// diff is outstanding across the whole app and its result is routed to the
    /// session that OWNS it (`diffRequestOwner`) — never to whatever session is
    /// merely current. A session abandoned while its diff is in flight drains
    /// before any new diff can be issued (see `DiffRequestBroker`).
    private var diffBroker = DiffRequestBroker()
    private var diffRequestOwner: SessionID?

    /// Pending restore for a one-shot `-ignorearchives` rescan: the `.prf`
    /// we temporarily appended the injected suffix to. Cleaned up the moment
    /// init1 has loaded the pref into Unison's memory (the in-memory value
    /// then survives init2 + the sync, so the archive still rebuilds — but the
    /// file is left as the user has it). We deliberately store ONLY the URL,
    /// not a saved copy of the original bytes: restoration re-reads the current
    /// file and strips exactly the app-owned trailing suffix, so it preserves
    /// any external edit made during the recovery window instead of clobbering
    /// it with a stale snapshot. See `rescanIgnoringArchives`.
    private var ignoreArchivesPendingRestore: URL?

    /// Sentinel comment bracketing our injected line, so a stray copy
    /// (e.g. left by a crash mid-rescan) can be detected + stripped on
    /// next launch without touching a user's own `ignorearchives` line.
    nonisolated static let ignoreArchivesMarker =
        "# unison-ui-mac: one-shot -ignorearchives (auto-removed)"

    /// The EXACT block appended to a `.prf` for a one-shot rescan. Injection
    /// (`rescanIgnoringArchives`) and crash cleanup
    /// (`contentByStrippingInjectedSuffix`) BOTH derive from this single
    /// definition so they can never drift. It is an app-owned suffix — a
    /// leading `\n` separates it from the user's content, and a trailing `\n`
    /// terminates the injected pref line.
    nonisolated static var ignoreArchivesInjectedSuffix: String {
        "\n\(ignoreArchivesMarker)\nignorearchives = true\n"
    }

    /// Pure crash-recovery transform. If `content` ends with EXACTLY the
    /// app-owned injected suffix, return the content with precisely those
    /// characters removed (the preceding UTF-8 content restored unchanged,
    /// character-for-character — including LF/CRLF and trailing-newline
    /// structure; this operates on the decoded Swift string, not raw bytes).
    /// Otherwise return nil — meaning "no mutation required". Deliberately
    /// anchored to the end of the document: it never scans for the marker
    /// substring or an isolated marker line elsewhere, so a user's own comment
    /// or `ignorearchives` line — even one identical to the marker — is never
    /// touched unless it IS the trailing app-owned block.
    nonisolated static func contentByStrippingInjectedSuffix(_ content: String) -> String? {
        guard content.hasSuffix(ignoreArchivesInjectedSuffix) else { return nil }
        return String(content.dropLast(ignoreArchivesInjectedSuffix.count))
    }

    /// The action `restoreIgnoreArchivesPrfIfNeeded` should take, decided purely
    /// from the CURRENT on-disk content re-read at restore time (never from a
    /// saved snapshot of the original). This is what makes restoration
    /// external-edit-safe: it strips exactly the app-owned trailing suffix off
    /// whatever the prefix currently is, so an edit made during the recovery
    /// window is preserved character-for-character.
    enum IgnoreArchivesRestoreAction: Equatable {
        /// Current content ends with the exact injected suffix → write this
        /// stripped content (its prefix is the current file's prefix verbatim).
        case write(String)
        /// Readable, but the injected suffix is already absent → no write, and
        /// this is NOT a failure (nothing to restore).
        case noWriteAbsent
        /// The file could not be read → never write a saved original over it;
        /// preserve the current file and log a cleanup FAILURE (not "restored").
        case noWriteUnreadable
    }

    /// Pure restore decision. `currentContent` is the freshly re-read file
    /// contents, or `nil` if the read failed. Reuses
    /// `contentByStrippingInjectedSuffix` for the exact-suffix match so the
    /// inject/cleanup/restore paths can never drift.
    nonisolated static func ignoreArchivesRestoreAction(
        currentContent: String?
    ) -> IgnoreArchivesRestoreAction {
        guard let content = currentContent else { return .noWriteUnreadable }
        if let stripped = contentByStrippingInjectedSuffix(content) {
            return .write(stripped)
        }
        return .noWriteAbsent
    }

    /// Outcome of a restore attempt, for accurate logging and testability.
    enum IgnoreArchivesRestoreResult: Equatable {
        case restored        // stripped current content written OK
        case nothingToDo     // suffix already absent — no write, benign
        case writeFailed     // decided to write but the write threw — suffix
                             // left in place for launch-time cleanup; NOT restored
        case readFailed      // file unreadable — current file preserved; NOT restored
    }

    /// Restore over injectable read/write seams so the full behavior (including
    /// read-failure and write-failure) is deterministically testable without a
    /// filesystem or an `AppDelegate` instance. `read` returns the current file
    /// contents (or nil on read failure); `write` persists the stripped content
    /// (throwing on write failure). Never writes anything except the stripped
    /// current content, and only when the exact suffix is present.
    nonisolated static func performIgnoreArchivesRestore(
        read: () -> String?,
        write: (String) throws -> Void
    ) -> IgnoreArchivesRestoreResult {
        switch ignoreArchivesRestoreAction(currentContent: read()) {
        case .write(let stripped):
            do { try write(stripped); return .restored }
            catch { return .writeFailed }
        case .noWriteAbsent:
            return .nothingToDo
        case .noWriteUnreadable:
            return .readFailed
        }
    }

    private let log = TraceLog.shared

    /// Serial queue for the BLOCKING OCaml connect/scan bridge calls —
    /// `init1`, the connection prompt loop, and `init2`. Each parks the
    /// calling thread inside `run_on_ocaml_thread` until OCaml returns;
    /// running them here instead of on the main thread means a slow or
    /// wedged SSH connection (bad host, bad key, bad `servercmd`) can't
    /// beachball the UI. The OCaml-side completion callbacks already hop
    /// back to the main queue, so all UI work stays main-isolated.
    private let connectQueue = DispatchQueue(label: "net.courbage.unison-ui.connect")

    // MARK: - Engine session coordinator (issue #6 — sole lifecycle authority)

    /// The single authority for the engine lifecycle. AppDelegate is its
    /// driver: it translates user intents into coordinator calls, runs the
    /// returned effects (in order), and feeds token-bound bridge callbacks
    /// back in. No lifecycle decision is made outside the coordinator.
    private let engine = EngineSessionCoordinator()

    private typealias SessionID = EngineSessionCoordinator.SessionID
    private typealias OperationID = EngineSessionCoordinator.OperationID
    private typealias OpenRequestID = EngineSessionCoordinator.OpenRequestID

    /// Exact identity of each in-flight bridge op, recorded when the op is
    /// STARTED (in response to a coordinator effect) and read back on its
    /// completion callback. Never "whatever op is active now". Not cleared
    /// on abandon — the terminal callback still owns the lease.
    private var pendingConnect: (SessionID, OperationID)?
    /// Assigning/clearing this slot is the single choke point for the init2/scan
    /// stall detector (issue #24): assigning a scan op arms it (remote scans
    /// only); clearing it — on success, failure, take-in-flight, or stall fire —
    /// disarms it. Crucially, `abandon()` does NOT clear this slot (abandonment
    /// is not idleness: the coordinator keeps the `.scanning(s,op)` phase), so the
    /// detector is RETAINED across UI abandonment and still fires
    /// `operationFailed` for the exact op → restart-required. Routing arm/disarm
    /// through `didSet` covers every existing `pendingScan = …` site.
    private var pendingScan: (SessionID, OperationID)? {
        didSet {
            if let (s, op) = pendingScan {
                if scanIsRemote { scanStall.arm(s, op) }
            } else {
                scanStall.disarm()
            }
        }
    }
    private var pendingSync: (SessionID, OperationID)?
    private var pendingClose: (SessionID, OperationID)?
    /// The session whose successful Ignore is awaiting its dedicated completion.
    /// Identity token (separate from `pendingScan`) so an Ignore completion can
    /// never satisfy a pending scan/rescan, and a stale/duplicate completion for
    /// a replaced session is dropped. Set by `performIgnore`, consumed by the
    /// ignore-complete handler.
    private var pendingIgnore: SessionID?

    /// Reconcile window per live session (keyed by SessionID, stable across
    /// connect→scan→ready→sync→rescan). Plus the single queued "waiting"
    /// window, promoted to `windowBySession` when its open starts.
    private var windowBySession: [SessionID: ReconcileWindowController] = [:]
    private var waitingWindow: (id: OpenRequestID, controller: ReconcileWindowController)?

    /// The profile each live session is showing (for window (re)creation
    /// and version-check). Cleared when the session ends.
    private var profileBySession: [SessionID: String] = [:]

    /// Whether a password sheet was shown during the current connect —
    /// ground truth for `connectFinished`'s interactive flag.
    private var sheetShownThisConnect = false

    /// Run coordinator effects in the order returned (order matters:
    /// showSession before beginConnect; presentSyncResults before
    /// closeConnection; a successful close before the queued session start).
    private func run(_ effects: [EngineSessionCoordinator.Effect]) {
        for effect in effects { execute(effect) }
        // The single funnel for EVERY coordinator mutation: `run(...)` wraps
        // all of them, and `runScanEffects` routes its remainder through here
        // too, so this notification fires on every engine-phase transition
        // (even a no-effect one). Any open Settings / Profile Editor / Clean
        // Stale window refreshes its destructive-action controls against the
        // new idle state.
        NotificationCenter.default.post(name: .engineActivityDidChange, object: self)
    }

    /// `EngineActivityProviding`: the app-side mirror of the coordinator's
    /// destructive-mutation policy. Windows recheck this immediately before
    /// mutating archive files.
    var allowsDestructiveArchiveMutation: Bool {
        engine.allowsDestructiveArchiveMutation
    }

    private func execute(_ effect: EngineSessionCoordinator.Effect) {
        switch effect {
        case .showSession(let s, let profile):
            driveShowSession(s, profile: profile)
        case .beginConnect(let s, let op, let profile):
            driveBeginConnect(s, op, profile: profile)
        case .beginScan(let s, let op):
            driveBeginScan(s, op)
        case .beginSync(let s, let op):
            driveBeginSync(s, op)
        case .closeConnection(let s, let op):
            driveCloseConnection(s, op)
        case .abortSync(let s, let op):
            driveAbortSync(s, op)
        case .showWaiting(let id, let profile):
            driveShowWaiting(id, profile: profile)
        case .presentScanResults:
            // Handled by the init2 completion handler, which holds the items
            // (see `runScanEffects(_:items:)`). No session-global work here.
            break
        case .presentSyncResults(let s, let snapshot):
            windowBySession[s]?.finalizeSyncUI(snapshot: snapshot)
        case .presentSyncUnavailable(let s, let reason):
            windowBySession[s]?.finalizeSyncUnavailable(reason: reason)
        case .restartRequired(let reason):
            driveRestartRequired(reason: reason)
        }
    }

    // MARK: - Effect executors (the driver side of the coordinator)

    /// Create (or promote the waiting window into) the session's reconcile
    /// window in scanning state, wire its callbacks to coordinator intents,
    /// and kick off the SSH version probe.
    private func driveShowSession(_ s: SessionID, profile: String) {
        lastAttemptedProfile = profile
        profileBySession[s] = profile

        // A queued "waiting" window (if any) must NOT be promoted into the live
        // session: its action callbacks are inert placeholders and its close
        // closure targets `cancelQueuedOpen`. Detach it (so closing it can't
        // cancel this now-authorized request) and discard it, then build a
        // fresh, fully-wired controller for the real session.
        if let waiting = waitingWindow {
            waiting.controller.window?.delegate = nil
            waiting.controller.close()
            waitingWindow = nil
        }
        let mergeConfigured = Self.readMergeConfigured(
            unisonDirectory: unisonDirectory, profile: profile)
        let reconcile = makeReconcileWindow(session: s, profile: profile,
                                            mergeConfigured: mergeConfigured)
        windowBySession[s] = reconcile
        reconcile.showWindow(nil)
        reconcile.window?.makeKeyAndOrderFront(nil)
        reconcile.beginInitialScan()
        profileWindowController?.close()

        runVersionCheckIfNeeded(profile: profile, session: s)
    }

    private func makeReconcileWindow(session s: SessionID, profile: String,
                                     mergeConfigured: Bool) -> ReconcileWindowController {
        ReconcileWindowController(
            profile: profile,
            mergeConfigured: mergeConfigured,
            onClose: { [weak self] in self?.handleWindowClosed(session: s, profile: profile) },
            onRescanRequested: { [weak self] in
                guard let self else { return }
                // Defensive (not solely AppKit validation): never authorize a
                // rescan while THIS session's Ignore publication is still in
                // flight — its new roots are installed but its rows haven't
                // landed, and a rescan would race the pending completion.
                guard self.pendingIgnore != s else {
                    self.log.write("deferring rescan — ignore completion pending for \(s)")
                    return
                }
                self.run(self.engine.requestRescan())
            },
            // Stop during connect/scan: tear the window down to the picker now
            // (leaving the lease with the in-flight op), rather than leaving it
            // spinning on "Cancelling…" until the background op settles.
            onCancelScan: { [weak self] in
                self?.leaveSession(s, profile: profile, closeWindow: true,
                                   reason: "Stop during connect/scan")
            },
            onSyncStart: { [weak self] in
                guard let self else { return }
                // Defensive: never authorize a sync while THIS session's Ignore
                // publication is still in flight (see onRescanRequested).
                guard self.pendingIgnore != s else {
                    self.log.write("deferring sync — ignore completion pending for \(s)")
                    return
                }
                self.run(self.engine.requestSync())
            },
            onSyncExit: { [weak self] intent in self?.run(self?.engine.requestSyncExit(intent) ?? []) },
            onEngineUncertain: { [weak self] reason in
                self?.run(self?.engine.engineBecameUncertain(reason: reason) ?? [])
            },
            onIgnore: { [weak self] action, row in
                self?.performIgnore(session: s, action: action, row: row) ?? UNISON_OP_INVALID
            },
            onDiffRequest: { [weak self] row in
                self?.requestDiff(session: s, row: row) ?? .refused
            },
            onDiffAbandon: { [weak self] in
                self?.abandonDiff(session: s)
            }
        )
    }

    /// Issue a diff for `row` on behalf of `session` through the app-global
    /// broker. Records the owner so the async result is routed back to THIS
    /// session's window, never to whatever session is current when it lands.
    private func requestDiff(session s: SessionID, row: Int) -> DiffRequestResult {
        switch diffBroker.request(owner: s.raw) {
        case .refuseInFlight, .refuseDraining:
            return .refused
        case .issue:
            diffRequestOwner = s
            // Synchronous dispatch; the result (if any) arrives async via the
            // diff/diff-err handler. A false return means the OCaml dispatch
            // raised: no result will arrive, so clear the pending request.
            if unison_bridge_run_show_diffs(Int32(row)) {
                return .issued
            }
            diffBroker.requestRaised(owner: s.raw)
            diffRequestOwner = nil
            return .raised
        }
    }

    /// The session's diff window closed, or the session itself is being torn
    /// down. If it owns the outstanding diff, the broker enters draining so the
    /// still-in-flight result is discarded before any new diff can be issued.
    private func abandonDiff(session s: SessionID) {
        diffBroker.abandon(owner: s.raw)
        if diffRequestOwner == s { diffRequestOwner = nil }
    }

    /// The user closed a live session's reconcile window (the ✕ button or
    /// ⌘W). Route it through the one session-teardown helper.
    private func handleWindowClosed(session s: SessionID, profile: String) {
        // The window is already mid-close (this fires from windowWillClose),
        // so don't re-close it — just detach + abandon + show the picker. The
        // version probe is cancelled inside leaveSession (the common path), so
        // BOTH this and the programmatic Stop-during-scan path tear it down.
        leaveSession(s, profile: profile, closeWindow: false, reason: "window closed")
    }

    /// Single, idempotent session→picker teardown, shared by the user closing
    /// the window (`handleWindowClosed`, `closeWindow: false`) and pressing
    /// Stop during connect/scan (`onCancelScan`, `closeWindow: true`).
    ///
    /// Ordering matters: detach the window's delegate FIRST so closing it
    /// can't re-enter `handleWindowClosed` (no double `abandon`), then drop
    /// the session mapping, then hand `abandon` to the coordinator, then show
    /// the picker. The pending connect/scan identity is deliberately NOT
    /// cleared — the in-flight op still owns the engine lease and its terminal
    /// callback (guarded by the coordinator's phase-exact checks) releases it.
    /// Idempotent via the `windowBySession[s]` guard: a second call for an
    /// already-torn-down session is a no-op.
    private func leaveSession(_ s: SessionID, profile: String,
                              closeWindow: Bool, reason: String) {
        guard let w = windowBySession[s] else { return }
        // Cancel THIS session's in-flight version probe here, in the common
        // session-leave path. Both entry points route through leaveSession:
        // the user closing the window (handleWindowClosed) and pressing Stop
        // during connect/scan (onCancelScan). Because leaveSession detaches the
        // window delegate before closing (so windowWillClose/handleWindowClosed
        // never re-fires), cancelling here is the only place that also covers
        // the programmatic Stop path — otherwise its probe would leak.
        if versionProbeSession == s {
            activeVersionProbe?.cancel()
            activeVersionProbe = nil
            versionProbeSession = nil
        }
        // If this session owns an outstanding diff, drain it so its late result
        // is discarded and can never be accepted as a replacement session's.
        abandonDiff(session: s)
        w.window?.delegate = nil            // prevent windowWillClose → re-entry
        windowBySession[s] = nil
        profileBySession[s] = nil
        if closeWindow { w.close() }
        run(engine.abandon(reason: reason))
        showProfilePicker(select: profile)
    }

    private func driveBeginConnect(_ s: SessionID, _ op: OperationID, profile: String) {
        pendingConnect = (s, op)
        sheetShownThisConnect = false
        // Show the scanning spinner for a reconnect (a rescan after we closed
        // a non-interactive connection on sync-end). The first open already
        // shows it via `beginInitialScan` in driveShowSession, so guard on the
        // window's own flag to avoid re-labelling it.
        if let w = windowBySession[s], !w.isScanning { w.beginRescan() }
        armConnectWatchdog()
        // init1 dispatches synchronously and returns a status. On success the
        // connect proceeds via installInit1CompleteHandler (prompt loop /
        // connectFinished); a non-OK status means the OCaml init raised, so that
        // completion will NEVER fire — route the failure here (with quiescence
        // UNproven → coordinator restart) instead of waiting for the watchdog.
        connectQueue.async { [weak self] in
            let status = profile.withCString { unison_bridge_init1($0) }
            guard status != UNISON_BRIDGE_OK else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
                self.pendingConnect = nil
                self.disarmConnectWatchdog()
                self.log.write("init1 (\(s)/\(op)) failed status \(status) — restart required")
                self.run(self.engine.operationFailed(
                    s, op, reason: "connect init failed (status \(status))",
                    engineIsQuiescent: false))
            }
        }
    }

    private func driveBeginScan(_ s: SessionID, _ op: OperationID) {
        pendingScan = (s, op)
        // Show the scanning spinner for a rescan (the initial scan already
        // shows it via beginInitialScan). Idempotent — guarded on isScanning.
        if let w = windowBySession[s], !w.isScanning { w.beginRescan() }
        // Same contract as init1: on success installInit2CompleteHandler fires
        // later; a non-OK status means the scan raised on dispatch and that
        // completion will never arrive, so route the failure immediately (with
        // quiescence UNproven → coordinator restart). That handles a scan that
        // fails to LAUNCH; a scan that launches but then wedges on a dead/wedged
        // transport (issue #24) is covered separately by the init2 scan stall
        // detector, armed for remote scans via `pendingScan.didSet`. (The 45s
        // stall detector in ReconcileWindowController covers only the SYNC/
        // transfer phase, NOT this scan phase — the earlier comment claiming it
        // did was wrong.)
        connectQueue.async { [weak self] in
            let status = unison_bridge_init2()
            guard status != UNISON_BRIDGE_OK else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingScan.map({ $0 == (s, op) }) ?? false else { return }
                self.pendingScan = nil
                self.log.write("init2 (\(s)/\(op)) failed status \(status) — restart required")
                self.run(self.engine.operationFailed(
                    s, op, reason: "scan failed (status \(status))",
                    engineIsQuiescent: false))
            }
        }
    }

    private func driveBeginSync(_ s: SessionID, _ op: OperationID) {
        pendingSync = (s, op)
        windowBySession[s]?.enterSyncingUI()   // syncing UI is the driver's job now
        // synchronize spawns its own OCaml thread and returns a dispatch status.
        // On success syncComplete arrives later; a non-OK status means the sync
        // never launched (OCaml raised) and syncComplete will never fire, so
        // route the failure with quiescence UNproven → coordinator restart.
        connectQueue.async { [weak self] in
            let status = unison_bridge_synchronize()
            guard status != UNISON_BRIDGE_OK else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingSync.map({ $0 == (s, op) }) ?? false else { return }
                self.pendingSync = nil
                self.log.write("synchronize (\(s)/\(op)) failed status \(status) — restart required")
                self.run(self.engine.operationFailed(
                    s, op, reason: "sync start failed (status \(status))",
                    engineIsQuiescent: false))
            }
        }
    }

    private func driveCloseConnection(_ s: SessionID, _ op: OperationID) {
        pendingClose = (s, op)
        connectQueue.async { [weak self] in
            let status = unison_bridge_close_connection()
            TraceLog.shared.write("closeConnection (\(s)/\(op)) -> status \(status)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingClose = nil
                self.run(self.engine.closeCompleted(s, op, status: status))
            }
        }
    }

    /// Perform an Ignore for session `s` through the bridge, binding the
    /// dedicated ignore completion to `s` first so its fresh rows are delivered
    /// back to that exact session (via the ignore-complete handler →
    /// `applyIgnoreResult`). Runs synchronously on the main thread (the bridge
    /// call blocks briefly, as it did before); the completion arrives on the next
    /// main turn. On any non-OK result no completion fires, so the token is
    /// cleared to avoid mis-attributing a later completion.
    private func performIgnore(session s: SessionID, action: IgnoreAction,
                               row: Int) -> unison_op_result_t {
        pendingIgnore = s
        let result = action.invoke(row: Int32(row))
        if result != UNISON_OP_OK { pendingIgnore = nil }
        return result
    }

    private func driveAbortSync(_ s: SessionID, _ op: OperationID) {
        // Blocker 5: route the abort through the SAME serial connectQueue that
        // driveBeginSync uses to launch the sync. Since the sync-launch was
        // enqueued first (at requestSync time) and `unison_bridge_synchronize`
        // returns as soon as it spawns the OCaml worker, FIFO ordering
        // guarantees the abort can never overtake the launch and set the flag on
        // a sync that hasn't started. On abort failure (flag not reliably set)
        // do NOT let the UI keep claiming "Cancelling…": route the sync op to
        // restart-required — the user's stop couldn't be honored and the engine
        // state is uncertain.
        connectQueue.async { [weak self] in
            let status = unison_bridge_abort_sync()
            guard status != UNISON_BRIDGE_OK else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.log.write("abort_sync (\(s)/\(op)) failed status \(status) — restart required")
                self.run(self.engine.operationFailed(
                    s, op, reason: "sync abort could not be requested (status \(status))",
                    engineIsQuiescent: false))
            }
        }
    }

    private func driveShowWaiting(_ id: OpenRequestID, profile: String) {
        // Replace any prior waiting window rather than reusing it: its close
        // closure captured an OLDER OpenRequestID, so reusing the controller
        // would target the wrong id in `cancelQueuedOpen`. Detach it first so
        // discarding it can't cancel the NEW queued request, then build a
        // fresh controller whose close closure captures THIS `id`.
        if let existing = waitingWindow {
            existing.controller.window?.delegate = nil
            existing.controller.close()
            waitingWindow = nil
        }
        let mergeConfigured = Self.readMergeConfigured(
            unisonDirectory: unisonDirectory, profile: profile)
        // A waiting window has no session and never becomes one — driveShowSession
        // discards it and builds a fresh session controller. So only its close
        // (→ cancelQueuedOpen for THIS id) is meaningful; the action callbacks
        // are deliberately inert.
        let controller = ReconcileWindowController(
            profile: profile,
            mergeConfigured: mergeConfigured,
            onClose: { [weak self] in
                guard let self, let w = self.waitingWindow, w.id == id else { return }
                self.run(self.engine.cancelQueuedOpen(id))
                self.waitingWindow = nil
                self.showProfilePicker(select: profile)
            },
            onRescanRequested: {},
            onCancelScan: {},
            onSyncStart: {},
            onSyncExit: { _ in },
            onEngineUncertain: { _ in },
            onIgnore: { _, _ in UNISON_OP_INVALID },
            onDiffRequest: { _ in .refused },
            onDiffAbandon: {}
        )
        waitingWindow = (id, controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.beginInitialScan()
        controller.updateScanStatus("Waiting for the previous operation to finish…")
        profileWindowController?.close()
    }

    private func driveRestartRequired(reason: String) {
        // Presentation only. The coordinator's `.restartRequired` phase is the
        // single source of truth (it refuses all new engine work); AppDelegate
        // keeps no parallel "restartRequired" boolean, and each window latches
        // its own display-gating flag in `showRestartRequired`.
        log.write("engine restart required: \(reason)")
        for (_, w) in windowBySession { w.showRestartRequired(reason: reason) }
        if let wc = waitingWindow?.controller { wc.showRestartRequired(reason: reason) }
        // Always surface a modal notice, not only the inline window text (issue
        // #35 correction 3): a fatal/restart condition must be unmissable even
        // when a reconcile or waiting window is open. Deduplicated by
        // `restartAlertVisible` so repeated `.restartRequired` effects (e.g. the
        // user keeps picking profiles) never stack a second dialog. The inline
        // latch above stays so the window still reflects the state behind/after
        // the modal (e.g. if the user chooses "Later").
        presentAppLevelRestartRequired(reason: reason)
    }

    /// True while the app-level restart-required alert is on screen, so
    /// repeated `.restartRequired` effects (e.g. the user keeps picking
    /// profiles) don't stack duplicate alerts.
    private var restartAlertVisible = false

    /// Application-level restart-required notice used when there is no
    /// reconcile/waiting window to latch the message into. Anchored to the
    /// picker when it's up, else app-modal. Offers Quit (the actual recovery)
    /// and Later (dismiss) — Quit stays available either way.
    private func presentAppLevelRestartRequired(reason: String) {
        guard !restartAlertVisible else { return }
        restartAlertVisible = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unison needs to be restarted"
        alert.informativeText = reason.isEmpty
            ? "Quit Unison and open it again to continue."
            : "\(reason)\n\nQuit Unison and open it again to continue."
        alert.addButton(withTitle: "Quit Unison")
        alert.addButton(withTitle: "Later")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            self?.restartAlertVisible = false
            if resp == .alertFirstButtonReturn { NSApp.terminate(nil) }
        }
        if let anchor = profileWindowController?.window {
            alert.beginSheetModal(for: anchor, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Apply scan-completion effects, threading the scanned items into the
    /// `.presentScanResults` effect (which the generic runner can't carry).
    private func runScanEffects(_ effects: [EngineSessionCoordinator.Effect],
                                items: [StateItem]) {
        // `.presentScanResults` carries the freshly-scanned row items, so it's
        // handled here; every other effect goes through `run` — the single
        // funnel that also fires the engine-activity notification. Routing the
        // remainder (even when empty) through `run` means an abandoned
        // local-only scan that transitions straight to idle with no effects
        // still notifies the maintenance windows.
        var rest: [EngineSessionCoordinator.Effect] = []
        for effect in effects {
            if case .presentScanResults(let s) = effect {
                windowBySession[s]?.endRescan(newItems: items)
            } else {
                rest.append(effect)
            }
        }
        run(rest)
    }

    // MARK: - Failure / recovery helpers (coordinator-routed)

    /// The reconcile window of the session the coordinator currently owns
    /// (nil when idle, closing-to-idle, or restart-required). Presentation
    /// reference only — never a lifecycle signal.
    private var currentReconcileWindow: ReconcileWindowController? {
        engine.currentSession.flatMap { windowBySession[$0] }
    }

    /// Take (and clear) the single in-flight op's token, so a terminal
    /// failure can be reported to the coordinator with the exact
    /// `(SessionID, OperationID)` it was started with. At most one of
    /// connect/scan/sync is pending at a time (each phase clears the prior
    /// slot), so priority here is just defensive ordering. Clearing prevents
    /// a dead op's token from leaking into a later failure report; the
    /// coordinator's phase-exact guards would ignore a stale token anyway.
    private func takeInFlightOp() -> (SessionID, OperationID)? {
        if let p = pendingSync { pendingSync = nil; return p }
        if let p = pendingScan { pendingScan = nil; return p }
        if let p = pendingConnect {
            pendingConnect = nil
            disarmConnectWatchdog()
            return p
        }
        return nil
    }

    /// Report a terminal failure of whatever op is in flight to the
    /// coordinator. `engineIsQuiescent` is the caller's proof that the OCaml
    /// worker actually unwound: true only when confirmed, false for
    /// uncertain (fatal-display-only / wedge) cases so the coordinator
    /// requires a restart rather than reusing a possibly contaminated runtime.
    private func failCurrentOp(reason: String, engineIsQuiescent: Bool) {
        guard let (s, op) = takeInFlightOp() else {
            log.write("failCurrentOp: no op in flight (\(reason)) — nothing to fail")
            return
        }
        run(engine.operationFailed(s, op, reason: reason,
                                   engineIsQuiescent: engineIsQuiescent))
    }

    /// Reopen `profile` as a brand-new session (a full init1+init2), tearing
    /// down whatever session is currently visible. Used by the recovery
    /// paths (delete-orphans / ignore-archives) and the "Rescan Ignoring
    /// Archives" menu action, all of which need init1 to re-read the profile
    /// — a connection-reusing rescan wouldn't.
    ///
    /// Entirely coordinator-driven: if an op is in flight it's failed with
    /// the unwind confirmed (so the connection closes and we reach idle);
    /// otherwise the visible `.ready` session is abandoned (same effect).
    /// The fresh open is then requested — the coordinator starts it
    /// immediately for a local profile, or queues it behind the connection
    /// close for a remote one and starts it once the close idles.
    ///
    /// Why `engineIsQuiescent: true` is sound here (verified against upstream
    /// `uimacbridge.ml`, Unison 2.54.0): the recoverable fatals that reach
    /// this path (archive inconsistency, orphan archives) are raised inside
    /// `do_unisonInit1` / `do_unisonInit2`, which run under `doInOtherThread`'s
    /// top-level `try … with Util.Fatal s -> fatalError s`. OCaml exception
    /// propagation unwinds the *entire* operation stack before that handler
    /// runs, and only from the handler does `fatalError → displayFatalError`
    /// invoke our Swift callback. So by the time this code executes, the op
    /// has provably unwound — the worker thread is exiting, not mid-operation.
    /// The one surviving piece of state is the established connection (a global
    /// in the ClientConn registry), which is now idle; the `.closeConnection`
    /// effect tears it down via the upstream-safe `Remote.clientCloseRootConnection`,
    /// serialized against the terminating worker by the OCaml runtime lock. The
    /// coordinator additionally gates the reopen on that close returning status
    /// 0 — an explicit terminal acknowledgement; any non-zero close escalates
    /// to restart-required instead of reusing the runtime.
    private func reopenCurrentProfileFresh(_ profile: String, failedReason: String) {
        // Detach + close the stale window WITHOUT its onClose→abandon path;
        // we drive the coordinator explicitly below (and a replacement window
        // opens synchronously in the same turn, so the app never sees a
        // last-window-closed moment).
        if let s = engine.currentSession, let w = windowBySession[s] {
            w.window?.delegate = nil
            w.close()
            windowBySession[s] = nil
            profileBySession[s] = nil
        }
        if let (s, op) = takeInFlightOp() {
            run(engine.operationFailed(s, op, reason: failedReason,
                                       engineIsQuiescent: true))
        } else {
            run(engine.abandon(reason: failedReason))
        }
        run(engine.requestOpen(profile: profile))
    }

    // MARK: - Permanent bridge handlers (installed once at launch)

    private func installPermanentBridgeHandlers() {
        // Finding 3: these five handlers must NOT add a second main-queue hop.
        // Each `UnisonBridge` trampoline already performs exactly one ordered
        // `DispatchQueue.main.async` handoff before invoking the handler, so the
        // handler body already runs on the main thread, in the bridge's emit
        // order. A second `DispatchQueue.main.async` here deferred the body one
        // extra run-loop turn, which could REORDER it after a later event (e.g.
        // a status arriving just before scan completion being applied after the
        // scan result). `MainActor.assumeIsolated` runs the body inline on the
        // already-current main turn — one ordered handoff, no reordering.
        UnisonBridge.installStatusHandler { [weak self] msg in
            TraceLog.shared.write("[ocaml→status] \(msg.prefix(200))")
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteConnectProgress()
                self.noteScanProgress()   // issue #24: scan status resets the scan stall timer (no-op outside .scanning)
                if let s = self.engine.currentSession, self.engine.isVisible(s) {
                    self.windowBySession[s]?.updateScanStatus(msg)
                }
            }
        }
        UnisonBridge.installProgressHandler { [weak self] fraction in
            MainActor.assumeIsolated {
                guard let self, let s = self.engine.currentSession else { return }
                self.windowBySession[s]?.updateGlobalProgress(fraction)
            }
        }
        UnisonBridge.installReloadRowHandler { [weak self] row, progress, bytes in
            MainActor.assumeIsolated {
                guard let self, let s = self.engine.currentSession else { return }
                self.windowBySession[s]?.reloadRow(row, progress: progress, bytesTransferred: bytes)
            }
        }
        UnisonBridge.installDiffHandler { [weak self] title, text in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Route to the OWNER of the outstanding request (not the current
                // session). The broker drops a result whose owning session was
                // abandoned (draining) or that nothing is awaiting.
                switch self.diffBroker.deliver() {
                case .apply(let owner):
                    if let s = self.diffRequestOwner, s.raw == owner {
                        self.windowBySession[s]?.showDiff(title: title, text: text)
                    }
                    self.diffRequestOwner = nil
                case .dropStale:
                    self.diffRequestOwner = nil
                }
            }
        }
        UnisonBridge.installDiffErrHandler { [weak self] err in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.diffBroker.deliver() {
                case .apply(let owner):
                    if let s = self.diffRequestOwner, s.raw == owner {
                        self.windowBySession[s]?.showDiffError(err)
                    }
                    self.diffRequestOwner = nil
                case .dropStale:
                    self.diffRequestOwner = nil
                }
            }
        }
        UnisonBridge.installInit1CompleteHandler { [weak self] needsPrompt in
            guard let self else { return }
            guard let (s, op) = self.pendingConnect else {
                self.log.write("dropping init1 completion — no pending connect"); return
            }
            self.log.write("init1 complete (needs_prompt=\(needsPrompt)) \(s)/\(op)")
            // `needs_prompt` is true iff a remote preconnection was walked, so it
            // is the reliable remote-vs-local signal for this connect (the else
            // branch finalizes `.local`). The scan stall detector (issue #24) is
            // remote-only, so record it before the scan starts.
            self.scanIsRemote = needsPrompt
            // init1 loaded the profile; restore any one-shot ignorearchives .prf.
            self.restoreIgnoreArchivesPrfIfNeeded()
            if needsPrompt {
                self.drivePromptLoop(s, op)          // remote: connectFinished at "no more prompts"
            } else {
                self.pendingConnect = nil
                self.disarmConnectWatchdog()
                self.run(self.engine.connectFinished(s, op, result: .local))
            }
        }
        UnisonBridge.installInit2CompleteHandler { [weak self] items in
            guard let self else { return }
            // Routed via the extracted RowCompletionRouter (same logic the tests
            // drive). A scan completion consumes ONLY pendingScan — an Ignore
            // completion arrives on a separate handler/token and can never land
            // here.
            guard case let .scan(s, op) =
                    RowCompletionRouter.routeScan(pendingScan: self.pendingScan) else {
                self.log.write("dropping init2 completion — no pending scan"); return
            }
            self.pendingScan = nil
            self.disarmConnectWatchdog()
            self.log.write("init2 complete — \(items.count) items \(s)/\(op)")
            self.runScanEffects(self.engine.scanCompleted(s, op), items: items)
            #if DEBUG
            self.maybeRunAutotestHooks(reconcile: self.windowBySession[s], items: items)
            #endif
        }
        // Dedicated Ignore completion (separate token + handler from scan). Binds
        // to the EXACT session that invoked the Ignore (pendingIgnore) and only
        // if that session is still live — a completion for a closed/replaced
        // session is dropped, never applied to a replacement. Updates that
        // session's rows in place; the window's mutation gate is lifted here.
        UnisonBridge.installIgnoreCompleteHandler { [weak self] items in
            guard let self else { return }
            let live = Set(self.windowBySession.keys)
            guard case let .ignore(s) =
                    RowCompletionRouter.routeIgnore(pendingIgnore: self.pendingIgnore,
                                                    liveSessions: live) else {
                self.log.write("dropping ignore completion — no live pending ignore")
                self.pendingIgnore = nil
                return
            }
            self.pendingIgnore = nil
            self.log.write("ignore complete — \(items.count) items \(s)")
            self.windowBySession[s]?.applyIgnoreResult(items)
        }
        // Terminal ASYNC scan failure (Blocker 2): a scan finished in OCaml but
        // its state could not be published, so init2CompleteHandler will never
        // fire. Route the pending scan op to restart-required (quiescence
        // unprovable after a mid-emission failure) so the coordinator leaves
        // .scanning rather than hanging. Token-bound via pendingScan.
        UnisonBridge.installScanFailedHandler { [weak self] in
            guard let self else { return }
            guard let (s, op) = self.pendingScan else {
                self.log.write("dropping scan-failed — no pending scan"); return
            }
            self.pendingScan = nil
            self.disarmConnectWatchdog()
            self.log.write("scan failed (state emission) \(s)/\(op) — restart required")
            self.run(self.engine.operationFailed(
                s, op, reason: "scan state could not be published",
                engineIsQuiescent: false))
        }
        UnisonBridge.installSyncCompleteHandler { [weak self] ok, rows in
            guard let self else { return }
            guard let (s, op) = self.pendingSync else {
                self.log.write("dropping sync completion — no pending sync"); return
            }
            self.pendingSync = nil
            self.log.write("sync complete \(s)/\(op) ok=\(ok) rows=\(rows.count)")
            // Bind the snapshot to the exact pending (s, op) via the coordinator.
            // ok == false ⇒ the per-row results couldn't be marshalled (engine is
            // quiescent — a read-only-results failure, not contamination).
            let results: EngineSessionCoordinator.SyncResults =
                ok ? .available(rows)
                   : .unavailable(reason: "the engine could not produce per-file results")
            self.run(self.engine.syncCompleted(s, op, results: results))
        }

        // Modal warning sheet. The OCaml worker parks on a condvar until the
        // user dismisses; the engine is always answered "proceed" (never
        // "exit", which would quit the app), so on cancel the op is still
        // running and we route the bail through the coordinator — never a
        // direct bridge abort.
        UnisonBridge.installWarnHandler { [weak self] msg, cancelled in
            guard let self else { return }
            self.log.write("warn dismissed (cancelled=\(cancelled)): \(msg.prefix(120))")
            guard cancelled else { return }
            guard let s = self.engine.currentSession else { return }
            if self.pendingSync != nil {
                // A transport is in flight — Abort.check observes the abort
                // and stops the sync. Route it exactly like the Stop button
                // (coordinator `.abortSync`, window kept, results presented).
                self.windowBySession[s]?.cancelSync()
            } else {
                // Scan/connect can't be aborted safely (flagging Abort mid-
                // update-detection trips an update.ml assertion). Leave the
                // profile: closing the window abandons the op via the
                // coordinator, which defers the connection close until the
                // background op actually terminates.
                self.windowBySession[s]?.close()
            }
        }

        // Modal fatal-error sheet. The bridge trampoline shows the alert
        // (including any Retry / Delete-Orphans recovery buttons) and then
        // calls us. The in-flight init1/init2/sync will NOT fire its normal
        // completion, so we MUST tell the coordinator the op failed.
        //
        //  - Recovery chosen (delete-orphans-and-retry, or the separate
        //    retry-ignoring-archives handler): these fatals are raised inside
        //    do_unisonInit1/2 under doInOtherThread's top-level try/with, so the
        //    operation stack has provably unwound before this callback runs
        //    (see reopenCurrentProfileFresh for the full evidence). We release
        //    the lease with the unwind confirmed (engineIsQuiescent: true) and
        //    reopen the SAME profile fresh (a full init1+init2). The reopen is
        //    gated on a clean connection close; a failed close escalates to
        //    restart-required on its own.
        //  - Display-only fatal: we can't prove the OCaml runtime unwound
        //    cleanly, so fail with engineIsQuiescent: false — the coordinator
        //    enters restart-required rather than reuse a possibly contaminated
        //    runtime.
        UnisonBridge.installFatalHandler { [weak self] msg, shouldRetry in
            guard let self else { return }
            self.log.write("fatal dismissed (retry=\(shouldRetry)): \(msg.prefix(120))")
            if shouldRetry, let profile = self.lastAttemptedProfile {
                self.reopenCurrentProfileFresh(
                    profile, failedReason: "retrying after deleting orphan archives")
            } else {
                self.failCurrentOp(reason: "fatal error: \(msg.prefix(200))",
                                   engineIsQuiescent: false)
            }
        }

        // "Retry Ignoring Archives" on an archive-inconsistency fatal: inject
        // a one-shot `ignorearchives` override into the .prf and reopen the
        // same profile fresh so init1 reads it. Routes through the same
        // coordinator-driven reopen as the other recovery paths.
        UnisonBridge.fatalRetryIgnoreArchivesHandler = { [weak self] in
            guard let self, let profile = self.lastAttemptedProfile else { return }
            self.log.write("fatal recovery: retry ignoring archives for '\(profile)'")
            self.rescanIgnoringArchives(profile: profile,
                                        failedReason: "retrying with ignorearchives")
        }
    }

    /// SSH credential prompt loop for connect op `(s, op)`. On "no more
    /// prompts" the connection is established → `connectFinished`.
    private func drivePromptLoop(_ s: SessionID, _ op: OperationID) {
        guard pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
        armConnectWatchdog()
        connectQueue.async { [weak self] in
            var promptPtr: UnsafePointer<CChar>? = nil
            let result = unison_bridge_connection_prompt(&promptPtr)
            // Blocker 3: an OCaml exception (or a vanished preconnection) is a
            // DISTINCT result from "no more prompts". Only UNISON_PROMPT_DONE may
            // proceed to connection_end; a prompt failure must NOT finalize the
            // connection — it retains the token, attempts preconnection cleanup
            // without declaring success, and lets that cleanup's status decide
            // clean-idle vs restart-required.
            guard result == UNISON_PROMPT_DONE || result == UNISON_PROMPT_AVAILABLE else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
                    let why = result == UNISON_PROMPT_EXN
                        ? "credential prompt raised"
                        : "no pending preconnection for prompt"
                    self.log.write("connection prompt failed (\(why)) — cleanup, no finalize")
                    self.cancelPreconnection(s, op, reason: why)
                }
                return
            }
            if result == UNISON_PROMPT_DONE {
                TraceLog.shared.write("connection: no more prompts — connection_end + init2")
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
                    // Finding 1: keep pendingConnect + the watchdog ACTIVE until
                    // connection_end actually returns (it can block on a wedged
                    // transport). On return, re-verify the exact (s, op): a
                    // watchdog timeout during the call invalidates the op, and a
                    // late success after that must be ignored. A nonzero status
                    // (OCaml raised / anomaly) routes through operationFailed
                    // with quiescence UNproven, so the coordinator restarts.
                    self.connectQueue.async { [weak self] in
                        let status = unison_bridge_connection_end()
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else {
                                // The op was invalidated (watchdog → restart-required)
                                // while connection_end ran. Do NOT revive the
                                // coordinator. But a status-0 return may have
                                // established a real connection that is now
                                // orphaned — enqueue a quiescent close-and-drain
                                // cleanup, restricted to the invalidated/restart
                                // path so it can never touch a newer session.
                                self.log.write("connection_end (\(s)/\(op)) -> \(status) after invalidation — not reviving")
                                if status == 0 {
                                    self.cleanupOrphanedConnectionAfterInvalidation(s, op)
                                }
                                return
                            }
                            self.pendingConnect = nil
                            self.disarmConnectWatchdog()
                            if status == 0 {
                                self.run(self.engine.connectFinished(
                                    s, op, result: .remote(interactive: self.sheetShownThisConnect)))
                            } else {
                                self.log.write("connection_end (\(s)/\(op)) failed status \(status) — restart required")
                                self.run(self.engine.operationFailed(
                                    s, op, reason: "connection finalize failed (status \(status))",
                                    engineIsQuiescent: false))
                            }
                        }
                    }
                }
                return
            }
            // UNISON_PROMPT_AVAILABLE — promptPtr is non-nil and bridge-owned;
            // copy it before leaving the worker.
            let prompt = promptPtr.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
                // Finding 2: if the connect was abandoned before this prompt
                // appeared, do NOT present a credential sheet over the picker.
                // Cancel the preconnection (no UI) and report the acknowledged
                // terminal result. Watchdog stays armed to cover a wedged cancel.
                if !self.engine.isVisible(s) {
                    self.log.write("connect \(s)/\(op) abandoned before credential prompt — cancelling, no UI")
                    self.cancelPreconnection(s, op, reason: "connect abandoned before credential prompt")
                    return
                }
                // Issue #35: a FATAL ssh transport error (login-grace timeout →
                // broken pipe / connection closed) is surfaced by the engine
                // through the SAME prompt channel as a real credential request.
                // Do NOT re-present it as a password sheet. Terminal evidence —
                // the tracked ssh child has gone/zombied — is authoritative; a
                // fatal-looking string is only a supplement. On fatal, tear the
                // half-open preconnection down and return to the picker with an
                // error dialog (no connection was established, so the engine is
                // quiescent once the cancel is acknowledged).
                let transportGone = unison_bridge_transport_child_terminated() != 0
                if case .fatal(let reason) = ConnectPromptClassifier.classify(
                    prompt: prompt, transportTerminated: transportGone) {
                    self.log.write("connect \(s)/\(op): fatal ssh output surfaced as a prompt "
                        + "(transportGone=\(transportGone)) — not re-prompting; teardown → picker")
                    self.failConnectFatal(s, op, message: reason)
                    return
                }
                self.disarmConnectWatchdog()
                self.sheetShownThisConnect = true
                self.log.write("connection prompt: \(prompt)")
                let sheet = PasswordSheet(prompt: prompt) { [weak self] response in
                    guard let self else { return }
                    guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
                    self.pendingPasswordSheet = nil
                    guard let response else {
                        self.log.write("connection: user cancelled prompt")
                        // Tear the window down BEFORE advancing the coordinator
                        // (its windowWillClose → abandon must not hit a
                        // freshly-started queued session). Then cancel — but
                        // RETAIN the op lease (pendingConnect + watchdog) until
                        // connection_cancel actually returns: only an
                        // acknowledged cancel declares the engine quiescent, and
                        // a cancel failure requires restart (finding 2).
                        let profile = self.profileBySession[s]
                        if let w = self.windowBySession[s] {
                            w.window?.delegate = nil
                            self.windowBySession[s] = nil
                            self.profileBySession[s] = nil
                            w.close()
                        }
                        self.cancelPreconnection(s, op, reason: "user cancelled connection")
                        self.showProfilePicker(select: profile)
                        return
                    }
                    // Blocker 3: check the reply status. On OK, loop back for the
                    // next prompt. On failure (the reply raised, or the
                    // preconnection vanished), do NOT continue the loop — attempt
                    // cleanup without declaring success; the cleanup's status
                    // routes to clean-idle or restart-required. Token re-checked
                    // after the async reply returns.
                    self.connectQueue.async { [weak self] in
                        let rc = unison_bridge_connection_reply(response)
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
                            if rc == UNISON_REPLY_OK {
                                self.drivePromptLoop(s, op)
                            } else {
                                // Issue #35: a reply that raised (e.g. EPIPE
                                // writing into an ssh that closed under us) is a
                                // fatal connect, not a loop-able retry. Fast-fail
                                // through the same teardown → picker + dialog path
                                // rather than a silent cleanup.
                                self.log.write("credential reply failed (rc \(rc)) — fatal connect; teardown → picker")
                                self.failConnectFatal(
                                    s, op, message: "The connection was lost during authentication.")
                            }
                        }
                    }
                }
                self.pendingPasswordSheet = sheet
                if let parent = self.windowBySession[s]?.window ?? self.profileWindowController?.window {
                    sheet.runAsSheet(over: parent)
                }
            }
        }
    }

    /// Abort a half-open preconnection for connect op `(s, op)` and report the
    /// acknowledged terminal result (finding 2). Retains the op lease
    /// (pendingConnect + a re-armed watchdog) until `connection_cancel`
    /// returns, so only an ACKNOWLEDGED cancel declares the engine quiescent; a
    /// cancel failure — or a watchdog timeout during the call — routes to
    /// restart-required instead. A late return after invalidation is ignored.
    private func cancelPreconnection(_ s: SessionID, _ op: OperationID, reason: String) {
        guard pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
        armConnectWatchdog()   // cover a wedged cancel
        connectQueue.async { [weak self] in
            let status = unison_bridge_connection_cancel()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else {
                    self.log.write("connection_cancel (\(s)/\(op)) -> \(status) after watchdog invalidation — ignored")
                    return
                }
                self.pendingConnect = nil
                self.disarmConnectWatchdog()
                if status == 0 {
                    // Acknowledged: no connection was established, so the engine
                    // is quiescent and operationFailed idles (nothing to close).
                    self.run(self.engine.operationFailed(
                        s, op, reason: reason, engineIsQuiescent: true))
                } else {
                    self.log.write("connection_cancel (\(s)/\(op)) failed status \(status) — restart required")
                    self.run(self.engine.operationFailed(
                        s, op, reason: "connection cancel failed (status \(status))",
                        engineIsQuiescent: false))
                }
            }
        }
    }

    /// Issue #35: a connect attempt hit a FATAL ssh transport error — the child
    /// closed (login-grace timeout / broken pipe / connection reset) and the
    /// engine surfaced that as a credential prompt, OR a credential reply raised.
    /// We must NOT re-prompt. Tear the half-open preconnection down
    /// (`connection_cancel` reaps the ssh child) and — only once the cancel is
    /// ACKNOWLEDGED (status 0), proving no connection was established and the
    /// engine is quiescent — return to the profile picker with an error dialog.
    /// A cancel that cannot prove quiescence routes to restart-required instead
    /// (the runtime may be contaminated). The op lease + a re-armed watchdog are
    /// retained across the cancel so a wedged cancel still resolves (the
    /// finding-2 cancel pattern). Presentation and destination FOLLOW the
    /// coordinator's quiescence decision; the dialog never decides it.
    private func failConnectFatal(_ s: SessionID, _ op: OperationID, message: String) {
        guard pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
        armConnectWatchdog()   // cover a wedged cancel
        connectQueue.async { [weak self] in
            let status = unison_bridge_connection_cancel()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pendingConnect.map({ $0 == (s, op) }) ?? false else {
                    self.log.write("connect fatal cancel (\(s)/\(op)) -> \(status) after invalidation — ignored")
                    return
                }
                self.pendingConnect = nil
                self.disarmConnectWatchdog()
                let profile = self.profileBySession[s]
                if status == 0 {
                    // Quiescent: no connection was established. Close the failed
                    // "Opening…" window, then present the OLD attempt's fatal
                    // notice EXACTLY ONCE and block on it (issue #35 correction
                    // 2). Only AFTER the user acknowledges do we advance the
                    // coordinator — so a queued replacement (the user's newer
                    // intent) is promoted and shown VISIBLY, never started hidden
                    // behind this dialog, and the picker is not reopened over it.
                    if let w = self.windowBySession[s] {
                        w.window?.delegate = nil
                        self.windowBySession[s] = nil
                        self.profileBySession[s] = nil
                        w.close()
                    }
                    self.presentConnectFatalModal(message: message, profile: profile)
                    // Post-acknowledgement: the coordinator promotes a queued open
                    // (→ showSession + beginConnect for it) or idles. If it idled
                    // (nothing queued, or the queued waiting window was closed
                    // before now → no ownerless start), show the picker. If a
                    // replacement was promoted, its own window is now up; do NOT
                    // reopen the picker over it.
                    self.run(self.engine.operationFailed(
                        s, op, reason: message, engineIsQuiescent: true))
                    if self.engine.isIdle {
                        self.showProfilePicker(select: profile)
                    }
                } else {
                    // Teardown could not prove quiescence: route through the
                    // coordinator to restart-required, which now surfaces a single
                    // modal notice even with a window open (correction 3).
                    self.log.write("connect fatal cancel (\(s)/\(op)) failed status \(status) — restart required")
                    self.run(self.engine.operationFailed(
                        s, op, reason: message, engineIsQuiescent: false))
                }
            }
        }
    }

    /// Modal OK dialog for a fatal connect failure (issue #35). Synchronous
    /// (`runModal`) on purpose: the caller must present it EXACTLY ONCE and only
    /// continue — idle to the picker, or promote a queued replacement — after the
    /// user acknowledges. Purely presentation: the engine state and destination
    /// are decided by the coordinator; this dialog only informs.
    private func presentConnectFatalModal(message: String, profile: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = profile.map { "Couldn’t connect to “\($0)”." }
            ?? "Couldn’t connect to the remote."
        let tail = "The connection closed before it could be established. "
            + "Returning to the profile list."
        alert.informativeText = message.isEmpty ? tail : "\(message)\n\n\(tail)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// A `connection_end` that returned status 0 AFTER its connect op was
    /// invalidated (watchdog → restart-required) may have established a real
    /// connection that no session now owns. Tear it down with a quiescent
    /// close-and-drain off the main thread, and log the result. Restricted to
    /// the invalidated/restart path: it only runs when NO session is live
    /// (`currentSession == nil`, i.e. idle/restartRequired), so even if the
    /// non-overlap invariant were ever broken it can never close a connection a
    /// newer session is using.
    private func cleanupOrphanedConnectionAfterInvalidation(_ s: SessionID, _ op: OperationID) {
        // Phase-exact: only clean up when the coordinator is specifically in
        // restartRequired (the state a watchdog-invalidated connect lands in).
        // `currentSession == nil` alone would also match ordinary .idle, which
        // is NOT an orphan state and where a stray close could disturb a
        // just-promoted queued open.
        guard engine.isRestartRequired else {
            log.write("connection_end orphan cleanup (\(s)/\(op)) skipped — coordinator not in restartRequired")
            return
        }
        connectQueue.async { [weak self] in
            let status = unison_bridge_close_connection()
            DispatchQueue.main.async {
                self?.log.write("connection_end orphan cleanup (\(s)/\(op)) -> close-and-drain status \(status)")
            }
        }
    }

    /// Fires if the connect phase (init1 + credential prompt) goes
    /// `connectStallTimeout` without progress. On timeout the connect op is
    /// failed with uncertain quiescence, so the coordinator requires a
    /// restart. Lives on the main queue.
    private var connectWatchdog: DispatchWorkItem?

    /// How long the connect/scan may go WITHOUT PROGRESS before the
    /// watchdog declares a timeout. This is a *stall* timer, not a
    /// total-elapsed budget: every scan-status message from Unison
    /// resets it (see `noteConnectProgress`), so a slow-but-progressing
    /// first scan of a large tree never trips it — only genuine silence
    /// (a hung ssh or a dropped connection) does. That's why a single
    /// generous value works for every profile without a per-profile knob.
    private let connectStallTimeout: TimeInterval = 60

    /// Init2/scan stall detector (issue #24). The connect watchdog is disarmed
    /// once `connection_end` returns; the scan (`init2`, update detection) that
    /// follows is otherwise un-timed, so a connection whose transport dies or
    /// freezes after auth (verified via a controlled frozen-remote proxy) hangs
    /// the `.scanning` phase with no automatic recovery. This is a no-progress
    /// timer bound to the exact scan `(SessionID, OperationID)`: armed when a
    /// REMOTE scan starts, reset on scan-status delivery, and on expiry it fails
    /// the op with quiescence UNPROVEN → coordinator restart-required. Local
    /// scans never arm it (`scanIsRemote`); it uses the monotonic
    /// `DispatchQueue.main.asyncAfter` clock.
    /// True iff the current/last connect established a REMOTE session (a
    /// preconnection was walked — the `needs_prompt` path; the else branch
    /// finalizes `.local`). Set in the init1 completion handler; gates the scan
    /// stall detector to remote scans so a fast local scan can never trip it.
    private var scanIsRemote = false
    /// Conservative bound: a wedged remote scan recovers within this window,
    /// while a valid large/slow scan that keeps delivering status is never
    /// false-failed (every status resets the timer).
    private let scanStallTimeout: TimeInterval = 120
    /// The detector instance. Armed/reset/disarmed via `pendingScan.didSet` and
    /// `noteScanProgress`; on expiry it routes the exact scan op to
    /// restart-required through `handleScanStall`.
    private lazy var scanStall = ScanStallTimer(timeout: scanStallTimeout) { [weak self] s, op in
        self?.handleScanStall(s, op)
    }

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

        // Install ALL bridge callbacks here, once, for the lifetime of the
        // app: the permanent status/progress/row/diff/init/sync handlers
        // (token-bound — each completion carries the op it belongs to) plus
        // the modal warn/fatal sheets. Installed BEFORE
        // unison_bridge_startup/init0 so the first OCaml status/warn can be
        // delivered. No handler is ever reinstalled per window — the
        // coordinator plus the session→window map decide which window (if
        // any) a callback presents into. This is the atomic authority switch:
        // one place installs the callbacks, one authority (the coordinator)
        // decides every lifecycle transition.
        installPermanentBridgeHandlers()

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
        // straight to stderr. Blocker 5: init0 failure leaves the runtime only
        // partly initialized — do NOT continue a normal launch; present an
        // unrecoverable startup error and terminate.
        let init0Status = unison_bridge_init0()
        if init0Status != UNISON_BRIDGE_OK {
            log.write("FATAL: unison init0 failed (status \(init0Status)) — aborting launch")
            presentUnrecoverableStartupError(
                detail: "The Unison engine could not be initialized (code \(init0Status)).")
            return
        }

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

    /// Blocker 5: engine initialization (`init0`) failed. The runtime is only
    /// partly wired, so there is no safe way to continue — present a terminal
    /// error and quit rather than limp along with a half-initialized engine.
    /// Under XCTest the host app has already started the runtime successfully,
    /// so this path is not exercised there; kept modal + terminating for the
    /// real app.
    private func presentUnrecoverableStartupError(detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Unison could not start"
        alert.informativeText = detail + " Please quit and try again; if it "
            + "keeps happening, reinstall Unison."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
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
        // Cancel any in-flight version probe. cancel() fires the child's
        // SIGTERM SYNCHRONOUSLY (deterministic teardown, not a flag noticed on
        // a later poll tick), then wait a bounded interval for the probe body
        // to finish its reap so we don't exit while the ssh child is still
        // being torn down. Bound = the executor's SIGTERM+SIGKILL grace budget
        // plus a small margin; if it somehow overruns we proceed anyway rather
        // than hang the quit.
        if let probe = activeVersionProbe {
            probe.cancel()
            probe.waitUntilFinished(
                timeout: .now() + (VersionCheck.terminateGrace * 2) + 0.5)
            activeVersionProbe = nil
            versionProbeSession = nil
        }
        unison_bridge_shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Window management

    private func showProfilePicker(select: String? = nil) {
        // Reconcile windows manage their own close (their onClose brings the
        // picker back), and the coordinator owns any still-live background
        // session, so the picker no longer force-closes a reconcile window
        // here — doing so was part of the old single-window authority.
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
    /// User picked a profile in the picker. Hand the intent to the
    /// coordinator, which decides open-now vs queue and returns the effects
    /// (window creation + connect, or a waiting window) we run.
    private func profileSelected(_ profile: String) {
        log.write("AppDelegate: profile '\(profile)' picked")
        run(engine.requestOpen(profile: profile))
    }

    /// SSH credential prompt sheet, retained while open.
    private var pendingPasswordSheet: PasswordSheet?

    // MARK: - Connect attempt lifecycle (watchdog)
    //
    // Two independent, complementary detectors cover the connect/scan path:
    //
    //   1. This connect watchdog covers ONLY the connect phase (init1 + the
    //      credential prompt fetch); it's disarmed at `connection_end`, before
    //      init2 begins. It never pokes the engine mid-scan (that could trip
    //      an `update.ml` assertion or an Lwt "wakeup").
    //
    //   2. `ScanStallTimer` (armed via `pendingScan.didSet`) covers the
    //      init2/scan phase — the first server round-trip, where a
    //      post-authentication transport stall wedges (issue #24). It is
    //      remote-only (local scans can't stall on a transport) and
    //      operation-bound to the exact (SessionID, OperationID); it resets on
    //      each scan status message and fires after `scanStallTimeout` of no
    //      progress. On fire it drives `operationFailed(engineIsQuiescent:
    //      false)`, which transitions the coordinator to `.restartRequired`
    //      (the wedged in-process op cannot be safely unwound — quit + reopen
    //      is the recovery). The detector is deliberately retained across UI
    //      abandonment (Stop), so it still fires for a session the user has
    //      already returned to the picker on.

    /// (Re)schedule the watchdog for the current connect op. Replaces any
    /// existing timer, so callers can use it both to reset the clock at each
    /// blocking phase boundary (init1 → prompt fetch) and as the per-progress
    /// reset (`noteConnectProgress`).
    private func armConnectWatchdog() {
        connectWatchdog?.cancel()
        guard let (s, op) = pendingConnect else { return }
        let item = DispatchWorkItem { [weak self] in self?.handleConnectTimeout(s, op) }
        connectWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + connectStallTimeout, execute: item)
    }

    private func disarmConnectWatchdog() {
        connectWatchdog?.cancel()
        connectWatchdog = nil
    }

    /// Reset the stall timer on connect-phase progress (a status message).
    /// No-op once the connect op is done (pendingConnect cleared).
    private func noteConnectProgress() {
        guard pendingConnect != nil else { return }
        armConnectWatchdog()
    }

    /// The connect phase (init1 / credential prompt fetch) stalled. We
    /// cannot prove the ssh child / init1 unwound, so fail the op with
    /// UNCERTAIN quiescence — the coordinator enters restart-required
    /// rather than reusing a possibly-wedged runtime.
    private func handleConnectTimeout(_ s: SessionID, _ op: OperationID) {
        guard pendingConnect.map({ $0 == (s, op) }) ?? false else { return }
        log.write("connect watchdog: \(s)/\(op) stalled \(Int(connectStallTimeout))s — restart required")
        disarmConnectWatchdog()
        pendingConnect = nil
        run(engine.operationFailed(
            s, op,
            reason: "Couldn’t connect to the remote (no progress for "
                + "\(Int(connectStallTimeout)) seconds). The connection may be wedged — "
                + "quit Unison and reopen the profile.",
            engineIsQuiescent: false))
    }

    // MARK: - Init2/scan stall detector (issue #24)

    /// Reset the scan stall timer on scan-specific progress. No-op unless a
    /// remote scan is pending, so unrelated bridge status (connect-phase or
    /// sync) can never reset it (`ScanStallTimer.reset()` is itself a no-op when
    /// not armed).
    private func noteScanProgress() {
        guard pendingScan != nil, scanIsRemote else { return }
        scanStall.reset()
    }

    /// The scan made no progress for `scanStallTimeout`. The transport is dead or
    /// wedged and the init2 worker cannot be proven unwound, so fail the EXACT
    /// scan op with quiescence UNPROVEN → the coordinator enters restart-required
    /// (never a premature idle / next-profile open). Exact-(s,op) guarded: a
    /// stale/duplicate expiry for a scan that already ended matches nothing and
    /// is a no-op. Because `abandon()` keeps the `.scanning(s,op)` phase and does
    /// not clear `pendingScan`, this still fires after UI abandonment and the
    /// coordinator's `operationFailed` matches — so an abandoned wedged scan is
    /// carried to restart-required rather than stranding a busy engine. Clearing
    /// `pendingScan` also disarms (didSet) and blocks any late scan callback from
    /// publishing stale results.
    private func handleScanStall(_ s: SessionID, _ op: OperationID) {
        guard pendingScan.map({ $0 == (s, op) }) ?? false else { return }
        log.write("scan watchdog: \(s)/\(op) stalled \(Int(scanStallTimeout))s — restart required")
        pendingScan = nil          // didSet → disarmScanStall()
        run(engine.operationFailed(
            s, op,
            reason: "Couldn’t reach the remote (no scan progress for "
                + "\(Int(scanStallTimeout)) seconds). The connection may be wedged — "
                + "quit Unison and reopen the profile.",
            engineIsQuiescent: false))
    }

    // MARK: - One-shot -ignorearchives recovery

    /// Recover from an "archive inconsistency" by re-running the profile
    /// once with `ignorearchives = true`. We temporarily append that line
    /// to the profile's `.prf` (which `do_unisonInit1`'s `loadTheFile`
    /// reads into Unison's in-memory prefs), re-run init1/init2, then
    /// restore the original `.prf` the instant init1 has consumed it. The
    /// in-memory pref outlives the file edit — init2 and the subsequent
    /// sync still ignore the archive and rebuild it — but the profile on
    /// disk is left character-for-character unchanged. No OCaml bridge change is
    /// needed, which is why this is a `.prf` edit rather than a pref call.
    /// `failedReason` labels the coordinator transition that releases the
    /// current session before the fresh reopen. It's carried through to
    /// `reopenCurrentProfileFresh`, which fails an in-flight op (fatal-retry
    /// path) or abandons a `.ready` one (menu path) as appropriate.
    private func rescanIgnoringArchives(profile: String, failedReason: String) {
        let url = URL(fileURLWithPath: unisonDirectory)
            .appendingPathComponent("\(profile).prf")
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            log.write("ignorearchives: cannot read \(url.path)")
            NSSound.beep()
            return
        }
        // Same single definition the crash-cleanup transform strips, so the two
        // can never drift.
        let injected = original + Self.ignoreArchivesInjectedSuffix
        // Bounded stale-read guard: this method reads `original` and then writes
        // `injected` with no in-process suspension between, so an in-process
        // change is impossible. Re-read immediately before the write to catch a
        // cross-process edit that landed in the tiny window since our read, and
        // abort rather than clobber it. This is best-effort — it cannot be
        // cross-process atomic (an edit after this re-read but before the write
        // still races), which is acceptable because a lost one-shot rescan is
        // recoverable, whereas silently overwriting the user's edit is not.
        if let recheck = try? String(contentsOf: url, encoding: .utf8), recheck != original {
            log.write("ignorearchives: \(profile).prf changed under us before injection — aborting to avoid clobbering an external edit")
            NSSound.beep()
            return
        }
        do {
            try injected.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.write("ignorearchives: write failed for \(url.path): \(error)")
            NSSound.beep()
            return
        }
        ignoreArchivesPendingRestore = url
        log.write("ignorearchives: injected into \(profile).prf — reopening profile fresh")
        // Reopen fresh so init1 re-reads the injected .prf; the injection is
        // restored the instant init1 has consumed it (see the init1-complete
        // handler → restoreIgnoreArchivesPrfIfNeeded).
        reopenCurrentProfileFresh(profile, failedReason: failedReason)
    }

    /// Restore the `.prf` we injected into, if any. Idempotent — safe to call
    /// from every completion/teardown path.
    ///
    /// External-edit-safe: it RE-READS the current file and strips exactly the
    /// app-owned trailing suffix off whatever the prefix now is, rather than
    /// writing back a saved snapshot. So an edit made during the recovery window
    /// is preserved. It never writes a saved original over the current file:
    /// - suffix still present → write the stripped current content;
    /// - suffix already absent → no write (benign, nothing to restore);
    /// - file unreadable → no write, logged as a FAILURE (not "restored");
    /// - write fails → the injected suffix is left in place for the launch-time
    ///   exact-suffix cleanup (`cleanupStrayIgnoreArchivesMarkers`), and is NOT
    ///   reported as restored.
    private func restoreIgnoreArchivesPrfIfNeeded() {
        guard let url = ignoreArchivesPendingRestore else { return }
        ignoreArchivesPendingRestore = nil
        let result = Self.performIgnoreArchivesRestore(
            read: { try? String(contentsOf: url, encoding: .utf8) },
            write: { try $0.write(to: url, atomically: true, encoding: .utf8) })
        switch result {
        case .restored:
            log.write("ignorearchives: restored \(url.lastPathComponent) (stripped injected suffix, current prefix preserved)")
        case .nothingToDo:
            log.write("ignorearchives: nothing to restore for \(url.lastPathComponent) — injected suffix already absent (no write)")
        case .writeFailed:
            log.write("ignorearchives: RESTORE WRITE FAILED for \(url.path) — injected suffix left for launch-time cleanup, NOT restored")
        case .readFailed:
            log.write("ignorearchives: RESTORE READ FAILED for \(url.path) — preserving current file, NOT writing a saved original, NOT restored")
        }
    }

    /// Action-menu entry point: confirm, then run the one-shot rescan for
    /// the profile currently open in the reconcile window.
    @objc func rescanIgnoringArchivesMenu(_ sender: Any?) {
        guard currentReconcileWindow != nil,
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
        rescanIgnoringArchives(profile: profile,
                               failedReason: "rescan ignoring archives")
    }

    /// Strip a stray one-shot `ignorearchives` injection left in a `.prf` by a
    /// crash mid-rescan. Thin filesystem wrapper over the pure
    /// `contentByStrippingInjectedSuffix`: it rewrites a profile ONLY when the
    /// file ends with EXACTLY the app-owned injected suffix (helper returns the
    /// restored content); when the helper returns nil ("no mutation required")
    /// it performs no write at all. It never scans for the marker substring or
    /// an isolated marker line, so a user's own comment or `ignorearchives`
    /// line is never touched.
    private static func cleanupStrayIgnoreArchivesMarkers(in unisonDirectory: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: unisonDirectory) else { return }
        for name in names where name.hasSuffix(".prf") {
            let url = URL(fileURLWithPath: unisonDirectory).appendingPathComponent(name)
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let restored = contentByStrippingInjectedSuffix(content) else { continue }
            do {
                try restored.write(to: url, atomically: true, encoding: .utf8)
                TraceLog.shared.write("ignorearchives: cleaned stray injected suffix from \(name)")
            } catch {
                TraceLog.shared.write(
                    "ignorearchives: cleanup FAILED for \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu validation

    // @objc so AppKit actually consults it during menu validation — a
    // plain Swift method here is invisible to the responder-chain
    // validation path, which left "Rescan Ignoring Archives…" enabled
    // (and a no-op) from the Profile Picker.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(rescanIgnoringArchivesMenu(_:)) {
            // Only meaningful with a reconcile window open on the live session.
            return currentReconcileWindow != nil && lastAttemptedProfile != nil
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
            let (result, dir, changed) = action.invoke(row: 0)
            let shown = result == UNISON_OP_OK ? "\(dir) (changed=\(changed))" : "<\(result.rawValue)>"
            log.write("  row 0 (\(items[0].path)): \(current) --[\(action.label)]--> \(shown)")
            if result == UNISON_OP_OK { current = dir }
        }
    }
    #endif

    // MARK: - Error recovery
    //
    // There is no `abortAllInFlight` anymore. Every failure/teardown path
    // now routes through the coordinator: a terminal failure goes through
    // `operationFailed` (see `failCurrentOp`), a recoverable fatal through
    // `reopenCurrentProfileFresh`, and a user leaving through `abandon` (via
    // the window's onClose). The coordinator — not an ad-hoc teardown helper
    // — is the single authority that decides whether the engine idles,
    // closes its connection, or requires a restart. The old helper's name
    // ("abort ALL in flight") also falsely implied it terminated engine
    // work, which it never did (the OCaml op kept running in the background).

    /// Spawn the SSH version probe for the given profile, surface a
    /// "version mismatch" alert if the result warrants it. No-op for
    /// local-only profiles (no SSH root). Silent on probe failure —
    /// Unison's own connection error will speak to any real problem.
    ///
    /// Runs in the background; completion comes back on the main
    /// queue and may show a modal alert *while init1/init2 is still
    /// running*. That's fine — init1/init2 are async on the OCaml
    /// side and don't block on the main queue.
    private func runVersionCheckIfNeeded(profile: String, session: SessionID) {
        // Supersede any earlier probe FIRST — before any early return. A new
        // open must always invalidate the previous session's probe, even if we
        // then can't start a new one (e.g. the version lookup below fails).
        // Clearing versionProbeSession also makes the old probe's `isCurrent`
        // guard fail, so its late result is dropped, not applied to us.
        activeVersionProbe?.cancel()
        activeVersionProbe = nil
        versionProbeSession = nil

        guard let localBridgeVersion = unison_bridge_get_version().map({ String(cString: $0) }) else {
            Log.versionCheck.warning("version check: unison_bridge_get_version returned nil")
            return
        }
        // Mint this probe's identity (the session) only once we're committed to
        // launching it.
        versionProbeSession = session
        Log.versionCheck.info("starting version check for profile '\(profile, privacy: .private)'")
        activeVersionProbe = VersionCheck.run(
            profile: profile,
            unisonDirectory: unisonDirectory,
            localBridgeVersion: localBridgeVersion,
            // Delivered only while this exact session is still the current one:
            // a reopened profile mints a new session, superseding this probe.
            isCurrent: { [weak self] in self?.versionProbeSession == session }
        ) { [weak self] outcome in
            guard let self else { return }
            self.handleVersionCheckOutcome(outcome, profile: profile)
            // This probe delivered; clear the active-probe state, but ONLY if it
            // is still the current probe. Delivery already required
            // `versionProbeSession == session`, but re-check defensively so a
            // newer probe that superseded us is never clobbered.
            if self.versionProbeSession == session {
                self.activeVersionProbe = nil
                self.versionProbeSession = nil
            }
        }
    }

    @MainActor
    private func handleVersionCheckOutcome(_ outcome: VersionCheck.Outcome,
                                           profile: String) {
        // Cache for the issue-report body (remote Unison version).
        lastVersionOutcome = (profile, outcome)

        // The version probe no longer feeds the auth-cost decision. Interactive
        // vs non-interactive is now determined solely by what the connect
        // actually did — whether a password sheet was shown — and passed to
        // the coordinator via `connectFinished(result: .remote(interactive:))`.
        // The old `probeConfirmedNonInteractive` fallback flag is gone.

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
            Log.versionCheck.info("no remote root in profile '\(profile, privacy: .private)' — skipping")
        case .probeFailed(let reason):
            // `reason` can embed the host, ssh stderr, or a servercmd path.
            Log.versionCheck.info("probe skipped/failed: \(reason, privacy: .private)")
        case .mismatch(let local, let remote, let host):
            if VersionCheck.Suppression.isSuppressed(host: host, local: local, remote: remote) {
                Log.versionCheck.info(
                    "mismatch \(local, privacy: .public) ↔ \(remote, privacy: .public) on \(host, privacy: .private) — suppressed"
                )
                return
            }
            Log.versionCheck.notice(
                "mismatch \(local, privacy: .public) ↔ \(remote, privacy: .public) on \(host, privacy: .private) — surfacing alert"
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
                "user suppressed mismatch alert for \(host, privacy: .private) @ \(local, privacy: .public)/\(remote, privacy: .public)"
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
        alert.informativeText = CrashReportCopy.alertInfo
        alert.addButton(withTitle: "Report…")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        revealCrashReportForAttachment(url)
        openIssueReport(context: CrashReportCopy.issueContext(reportName: report.name))
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
