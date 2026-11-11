# Admission and retry boundaries: working design

Status: historical design record. Code references are to `main` at `c399020` and were re-read against that revision; line numbers will drift.

Outcome (1.0.1, published 2026-11-10 from `d3c5b4a`): F shipped in #219, A in #220, the first part of B in #221, D in #222 and G in #223; the remote-root open gate found by the combined review shipped in #226. G removed the temporary profile edit and its restore path, which resolved H. C's remaining early return was found unreachable. Follow-ups: the B reconnect transition is #229, E's two confirmed failures are #224 and #225, I is #231, and staging discovery after launch is #230 (with #217 and #218). The attended verification record is `docs/attended-1.0.1/run-sheet.md`. The sections below describe the design as it stood before implementation; where they differ from what shipped, the pull requests above are authoritative.

This is the working design for how `AppDelegate` admits an open and how it retries one. The companion document, `AppDelegate Lifecycle Review.md`, is the brief that tells the adversarial reviewer what to verify and report. That brief owns the verification method and the report format. This document owns the proposed designs, their tradeoffs, the decisions taken, and the questions still open.

Evidence labels used throughout:

- **Source** means established by reading the code at the cited revision.
- **Observed** means seen by running something. Each use says what was run.
- **Unverified** means a hypothesis that no one has reproduced.

Severity labels describe the consequence if the path is reachable. They are not statements about reachability.

## Decisions recorded

| Finding | Decision |
| --- | --- |
| F. Credential prompt during a takeover | Refuse the request while a credential prompt is open. Automatic dismissal and preconnection cancellation is a separate product decision and is not part of the maintenance fix. |
| G. Recovery scope | A recovery reopen preserves the original session's options. The contract is in finding G. A fixture must validate the implementation and the exact lifetime of the `ignorearchives` override before code is written. |
| A. Startup staging | The first change is the reorder alone: load staging state before exposing the listener or picker, and defer only the recovery dialog. No readiness flag. An explicit scan outcome and the treatment of undecodable manifests are tracked as #217 and #218, planned for 1.1 unless the review reproduces an affected profile opening while staging holds its archives. |
| B. Delayed admission | All three paths are specified: an immediate open, a queued open, and a reconnect. The reconnect gets a narrow new coordinator transition. B ships in two pull requests. The first, covering queued opens, the CLI pre-exit check, and a truthful reply when an immediate open is refused, is part of this release. The reconnect transition is a coordinator change that preserves the existing session and results, handles abandonment, and keeps Sync unavailable while disconnected, so it goes in a subsequent planned release with its own review. Until then the reconnect gap stays explicitly open. If the adversarial review reproduces a reconnect into held archives, its release priority is revisited. The window-closing fallback for a refused reconnect is rejected, and no defensive spinner-reset method is added. Discovery of new external staging after admission is outside B. |

## Purpose and scope

The reopen work followed a pattern. A safety rule existed (do not open a profile while interrupted archive staging exists for it), one entry point bypassed it, and fixing the bypass exposed a teardown-ordering problem: the rule had to be evaluated before the session was torn down, and the refusal branch had to restore what the teardown changed.

This document looks for the same pattern at two boundaries:

- **Admission.** The moment a request to open, reopen, or take over is accepted, and the later moment its effect runs. The question is which rules can refuse it, whether each is evaluated, and whether each is still true when init1 starts.
- **Retry.** Any path that tears a session down and starts another one to recover from an error or at the user's request. The question is whether the path always reaches a terminal state, carries the right session scope, and gives back everything it temporarily changed.

In scope: the launch sequence, the open and reopen paths, command-line handoff decisions, the credential prompt during a takeover, the one-shot `ignorearchives` retry, and the fatal orphan removal. Out of scope: localization (#198), the attended 1.0.0 checks (#197), logging and `VersionCheck`, and any change to the Unison engine or its patches. This document authorizes no implementation, no pull request, and no release decision.

## Ownership to preserve

Each fix moves a check toward its owner. None adds a second copy of a rule.

| Concern | Owner | Notes |
| --- | --- | --- |
| Session phase and legal transitions | `EngineSessionCoordinator` | Phases `.idle`, `.opening`, `.scanning`, `.ready`, `.syncing`, `.diffing`, `.closing`, `.restartRequired`. It returns effects and never performs them. |
| Performing effects against the engine | `AppDelegate.run` and `execute` | The only caller of `unison_bridge_init1` and its siblings (`driveBeginConnect`, `AppDelegate.swift:644`). |
| Destructive archive mutation allowed | `allowsDestructiveArchiveMutation`, true only in `.idle` | Re-checked at each mutation site and again inside `ArchiveMutation.execute` (`ArchiveMutationTransaction.swift:294`). One path is a documented exception: the fatal orphan removal passes `isEngineIdle: { true }` while the coordinator still holds the failed operation (`UnisonBridge.swift:440`). See E. |
| Whether a profile may open while staging exists | `ProfileStagingGate`, computed by `AppDelegate.profileStagingGate` | Reads the in-memory `blockedArchiveHashes` and `abandonedStagings`. |
| Which file is the profile | `ProfileLookup` | Engine lookup for opening; exactly `P.prf` for the editor. |
| Session-scoped command-line options | `EngineSessionCoordinator.currentArgs` | Reapplied on reconnect and rescan-after-close; cleared in `finishToIdle` (`EngineSessionCoordinator.swift:608`). |
| The credential sheet | `pendingConnect` plus `pendingPasswordSheet` | The sheet's only exit today is its own response handler (`AppDelegate.swift:1516`). See F. |
| The one-shot `ignorearchives` edit | `ignoreArchivesPendingRestore` (`AppDelegate.swift:146`) | App-wide, not bound to a retry. See C, D, and H. |

Two properties hold today and must keep holding. The coordinator's header states that correctness rests on non-overlapping operations, so no fix may let two connects overlap. And apart from the fatal exception above, every mutation of the archive directory runs synchronously on the main thread in `.idle`, so nothing interleaves with it.

## Findings to challenge

The findings are lettered as in the reviewer's brief. F is first in review priority. Findings C, D, and H are designed together.

### F. A command-line takeover during a credential prompt orphans the password sheet

Severity if reachable: P1. Review priority: first. Decision: refuse the request while the prompt is open.

**Claim.** A second `unison-ui-mac <profile>` request that arrives while an SSH password sheet is showing closes the window under the sheet and never cancels the pending connect. The coordinator stays in `.opening` and the queued request never drains. The only exit is quitting the app.

**Source.**
- `currentHandoffActivity` (`AppDelegate.swift:2593`) maps `.opening` to `busyWillWait`, which includes the time the sheet is up.
- `handleCommandLineHandoff` (`:2259`) takes the `.acceptWaiting` branch, which calls `commandLineTakeover` (`:2339`). That calls `engine.admitCommandLineOpen`, which marks the session abandoned, then `detachSessionPresentation(closeWindow: true)` (`:625`), which calls `w.close()` on the window the sheet is attached to.
- Nothing in that path touches `pendingPasswordSheet` or `pendingConnect`. The sheet is created at `:1513` and stored at `:1563`. `pendingPasswordSheet` is cleared only inside the sheet's own response handler (`:1516`). The abandoned-while-prompting guard (`:1459`) runs before the sheet appears and never again.
- The connect watchdog is disarmed when the sheet is shown (`:1507`), so no timer recovers the state.

**Observed (mechanism only).** A throwaway AppKit script, since deleted, attached a sheet to a window and then closed the window. `sheetParent` stayed non-nil, the sheet became invisible, and the completion block never ran. `performClose` on a window with an attached sheet was ignored, so the user cannot leave through the window either. This shows how AppKit behaves. It does not show that the app reaches this state, because the script did not drive the app.

**Unverified.** That the app reaches the state end to end, and that nothing else (the engine, a transport timeout) ends the prompt. The v1.0.0 test notes list the takeover path as passing; whether that case included a credential prompt has not been checked.

**Would disprove it.** A driver reproduction in which the takeover during a prompt leaves the coordinator idle or opening the queued profile within the watchdog interval.

**Request for review.** An end-to-end driver reproduction: a remote profile that needs a password, the sheet up, then a handoff for another profile. Observe the reply the CLI caller receives, the coordinator phase over time, whether the sheet is still attached and answerable, and whether the queued request ever starts.

**Design: refuse while a credential prompt is open.** Add an `Activity` case for a showing credential sheet, decided in `currentHandoffActivity` from `pendingPasswordSheet != nil`, and map it in `CommandLineHandoff.decide` to a refusal that names the prompt and tells the caller to answer or cancel it and run the command again. This follows the existing `.editing` and `.restartRequired` refusals, which take the same shape (`CommandLineHandoff.swift:325-335`). It changes nothing the app does; it stops accepting a request the app cannot honor safely. The check belongs in `currentHandoffActivity` because that is where every other busy state is classified, so the sync-decision path inherits it.

Expected outcomes:
- **User:** the password sheet stays up, visible, and answerable. No window closes.
- **CLI caller:** a refusal that says why, with exit status and wording matching the other refusals.
- **Engine:** untouched. No cancel is issued and nothing is queued.
- **Filesystem:** untouched.

**Not chosen: automatic dismissal and preconnection cancellation.** On takeover, dismiss the sheet and call `cancelPreconnection(s, op, reason:)` (`:1577`). This is friendlier to a command-line user sitting at a prompt, but it is a behavior decision with its own requirements, so it is left for a later product decision:
- **Exactly-once dismissal.** The sheet's response handler (`:1516`) and the new path must not both run. The handler guards on `pendingConnect` matching, so the new path must clear `pendingPasswordSheet` and end the sheet before the cancel is issued, and the handler must observe that it was ended.
- **Acknowledged teardown.** The window cannot close until the cancel is acknowledged, because a failed cancel routes to restart-required. The takeover then has to wait for that outcome.
- **Caller reply.** The caller has been told "accepted, waiting"; the app must then deliver on it or fail visibly.

**Regression and control.**
- Red today: with a stub sheet and `pendingConnect` set for the current session in `.opening`, a handoff for another profile gets a refusal that names the prompt. Today the reply is "accepted, waiting". The test also asserts that the sheet is still present, the phase is unchanged, nothing is queued, and no cancel was issued.
- Control: the same handoff with no sheet showing is still accepted and waits.
- Control: a handoff while `.opening` for a local profile (no prompt possible) is unchanged.

**Size.** About fifteen lines in `AppDelegate` and `CommandLineHandoff`, plus one wording test and one driver test. Planning input only.

### A. Startup staging state is loaded after open entry points are exposed

Severity if reachable: P1. My assessment of likelihood: P2 until a race is shown. Decision: the reorder alone is the first change.

**Claim.** During launch the handoff listener starts and the picker is shown before the staging state is loaded. In that interval the gate evaluates against empty state and reports every profile as clear.

**Source (the ordering is confirmed).** In `applicationDidFinishLaunching`:
- `cleanupStrayIgnoreArchivesMarkers` runs at `:1861`.
- `routeCommandLineHandoff()` starts the listener at `:1871`.
- `showProfilePicker()` or `showProfilePicker(select:)` runs at `:1913` or `:1922`.
- The staging scan, `checkForAbandonedArchiveStaging()`, runs at `:1948` inside a `DispatchQueue.main.async` block queued at `:1946`, after `checkForPriorCrashReport()` at `:1947`.
- The Debug auto-open (`UNISON_AUTOTEST_PROFILE`, `:1970`) runs synchronously before that deferred block.
- `blockedArchiveHashes` and `abandonedStagings` start empty (`:86-87`), and `ProfileStagingGate.evaluate` reports `.clear` for a profile that matches nothing.
- The launch's own named profile is safe: `pendingLaunchProfile` opens only inside the deferred block, after the scan (`:1954`).

**Unverified (the production race).** No click can land in the interval, because it is one run-loop turn on the main thread. A handoff request can reach admission only if the socket thread's main-queue block is enqueued ahead of the deferred scan block, which requires the request to arrive while `applicationDidFinishLaunching` is still executing. Whether that ordering occurs, and how main-queue delivery interacts with AppKit modals during launch, has not been measured.

**Would disprove it.** A trace showing that no handoff block can be enqueued before the deferred block on the supported launch paths.

**Design.** Load the staging state before exposing any entry point, and defer only the recovery presentation.
- `refreshBlockedArchiveState()` (`:3287`) is already dialog-free and returns whether anything blocks. Call it once, after `unisonDirectory` is set and before `routeCommandLineHandoff()`.
- `checkForAbandonedArchiveStaging()` keeps its current place in the deferred block and keeps presenting recovery. It re-scans, which is cheap and keeps the dialog's inputs current.
- Crash-report presentation stays where it is. Loading state and showing UI are separate concerns, and the crash prompt must not delay the state that makes opens safe.

**No readiness flag.** A flag would record whether the scan ran. It cannot distinguish a successful empty scan from a failed scan that returns an empty array, which is the case that matters. If scan failure needs to block opens, the scanner itself must return an explicit outcome. Source shows the scanner can fail silently: `refreshBlockedArchiveState()` returns `false` for an empty `unisonDirectory` (`:3288`), `AbandonedStagingScan.find` returns no records when the directory cannot be listed (`ArchiveMutationTransaction.swift:452`), and it skips any quarantine entry whose manifest cannot be read or decoded (`:457-459`, `continue`). Those two behaviors are tracked as follow-ups and are separate decisions from startup order:
- #217: the staging scan reports a failed scan as "nothing blocks".
- #218: staging manifests the app cannot decode are skipped instead of blocking.

Both are planned for 1.1 as a pair, because the answer to #218 determines what the scanner outcome in #217 must report. They move into the maintenance release only if the adversarial review reproduces an affected profile opening while staging holds its archives. The reorder does not wait for either.

**Request for review.** A test of the actual startup sequence, not only of the gate in isolation. It should plant a held archive in an isolated directory, run the real launch path with a handoff request queued during it, and assert that the request is refused. Include a Finder launch, a launch that names a profile, the smoke launch, and the XCTest host, which skips handoff routing and keeps its own isolation. For #217 and #218, the reviewer should say whether each failure is reachable and from what sequence.

Expected outcomes:
- **User:** the first picker open of an affected profile is blocked, an unrelated profile opens, and recovery is offered after startup. Choosing Later leaves the block in force.
- **CLI caller:** a refusal for an affected profile from the first request on.
- **Engine and filesystem:** no init1 for an affected profile; no mutation.

**Regression and control.** Held archive plus a handoff during launch is refused. Control: an unrelated profile opens. Control: choosing Later keeps the block.

**Size.** About ten lines and one startup-sequence test.

### B. An open decision can go stale before init1

Severity if reachable: P1. My assessment: P2, because the staging half cannot change under a live session. Decision: all three paths are specified. This release gates immediate and queued fresh opens and adds the CLI pre-exit check; a narrow new coordinator transition handles a refused reconnect in a later release.

**Claim.** The staging gate runs when a request is made and never at the effect. The target's roots can change between the decision and the start.

**Source.**
- `profileSelected` (`:2089`), `handleCommandLineHandoff` (`:2259`) through `refusalForStagingOrDeadline` (`:2571`), and `reopenCurrentProfileFresh` each evaluate the gate once, when the request is made.
- A queued request drains in `finishToIdle` (`EngineSessionCoordinator.swift:603`), which calls `startFreshOpen`. That returns `.showSession` and `.beginConnect` together (`:575-584`).
- A reconnect re-runs `.beginConnect` for the current profile from `requestRescan` (`:347-356`) and `closeCompleted` (`:509-522`). Neither emits a new `.showSession`, because the session already has a window.
- `driveBeginConnect` (`AppDelegate.swift:644`) applies the session args and dispatches init1. It makes no staging decision.
- The two-phase sync decision checks the gate before raising the sheet (`:2316`). `resolveSyncLeaveChoice` (`:2542`) rechecks the session phase and the deadline, then requests the sync exit and calls the takeover. It does not recheck the target's gate.
- The staging state itself cannot change while the phase is non-idle, because every mutation requires `.idle`, with the fatal orphan removal as the exception (finding E).

**Unverified.** Whether any path blocks a profile edit while that profile's session is live. I found no such guard. The picker can be reopened during a ready session (`validateMenuItem` enables it for a current session that is not syncing), which suggests the edit is reachable, but I have not confirmed it.

**Two checks in this release, one in a later release.**

1. **Before the sync-exit effect (CLI pre-exit check).** In `resolveSyncLeaveChoice`, after the session and deadline checks and before `engine.requestSyncExit`, re-evaluate `profileStagingGate(name)` for the target, then recheck the deadline, because reading the profile's roots takes time. If either fails, refuse. This protects the current sync: a refusal here leaves the sync, its window, and its exit intent untouched, because nothing has been requested yet. Preserve the ticket claim, which `finishSyncDecision` already takes before any effect, and the monotonic deadline.
2. **At the fresh-open boundary (this release).** Gate immediate and queued fresh opens in `AppDelegate.run`, before any effect of the batch executes. A fresh open is the only thing that emits `.showSession`: `startFreshOpen` returns `[.showSession(s, ...), .beginConnect(s, op, ...)]` together (`EngineSessionCoordinator.swift:583`), and that is the only emission site. A reconnect returns `.beginConnect` alone, with no `.showSession`, because the session already has a window. So a batch that contains `.showSession` is a fresh open, and a batch that does not is a reconnect or some other effect. The gate keys on that, and `.opening(session, op)` never has to be interpreted. The gate does not live in `driveBeginConnect`, which both kinds of attempt share, so a reconnect cannot be given the fresh-open unwinding by accident.
3. **At the reconnect boundary (later release).** The reconnect transition below, which sits at the top of `driveBeginConnect` and applies only to a reconnect the coordinator has recorded.

Gating at the batch level has a second benefit. A refusal happens before `driveShowSession` runs, so no session window has been created and the picker has not yet been closed. There is nothing to tear down, and tests can reach the gate under `suppressEngineEffectsForTesting`, which skips `.beginConnect` but still executes `.showSession`.

The checks protect different boundaries. A pre-exit check cannot cover a queued open that drains later, and a fresh-open gate cannot undo a sync that was already aborted on a stale decision.

**What the fresh-open gate re-reads.** It re-reads the target's effective roots against the app's current staging snapshot. It does not refresh the snapshot from disk. That is enough for the reported case, in which the held archive is already known and the profile's roots or includes changed after admission. Discovery of new external staging after admission is outside B and is not promised here.

**Refusal outcomes.**

| Path | State when the gate fires | Resolution |
| --- | --- | --- |
| **Immediate open** (idle app, request or pick) | The request-time gate ran moments earlier in the same main-thread turn. | The in-app causes that could change the answer have no chance to run, but the profile is read from disk twice, and an external edit can land between the two reads, so this refusal is reachable and is tested. The coordinator has already entered `.opening` when it returns the batch, because `requestOpen` calls `startFreshOpen` first (`EngineSessionCoordinator.swift:270`, `:575`). Skipping `.showSession` and `.beginConnect` prevents the window and the bridge call but would leave the coordinator in `.opening` forever, so the refused operation is failed exactly, as for a queued open, below. The picker stays up, since the window and picker closing belong to `driveShowSession`, which never runs. The reply is tied to this exact request, below. |
| **Queued open** (drained by `finishToIdle`) | The batch contains `.showSession` and `.beginConnect` for the new session, and a waiting window may exist. The CLI caller already received "accepted, waiting". | Do not execute either effect. Fail the exact new operation, `(s2, op2)` from the batch, with `engineIsQuiescent: true`, which is sound because no bridge call was made; the coordinator then returns to idle through `beginClose(.toIdle)` and `finishToIdle`. Discard the waiting window the way `driveShowSession` would have, bring the picker back with the profile selected, and show `presentBlockedReopenNotice` (`:1146`) with a variant that says the profile became blocked while waiting. The refusal reaches the user only; any change to what the CLI learns after acceptance needs its own review. |
| **Reconnect** (rescan after a sync-end close, or on a disconnected ready session) | `.beginConnect` alone, for an existing session whose window holds results. | Not changed in this release. The gap is explicitly open until the later transition below. No window is closed. |

**The reply is tied to the exact request.** The picker admission result and the CLI reply must say what happened to this request, not what the engine happens to be doing. Derive it from this request's own effects and the state after they run:
- *Started.* The batch contained `.showSession(s2, ...)`, the gate passed, and after `run` the coordinator is in an operation phase for exactly `s2`. A failed session-args setter (`:659`) ends the operation and leaves the coordinator idle, so it correctly reports not started, which also fixes today's behavior of reporting success.
- *Queued.* The batch contained `.showWaiting(id, ...)`. The request is accepted for waiting, which is today's `true`, and the caller still gets "accepted, waiting".
- *Refused.* The batch contained `.pickBlockedByCommandLineRequest`, or the gate refused. The pick is not admitted, so `launchOverrides.didOpen(accepted: false)` leaves the launch's options for a later selection, as it does today for a blocked pick.
Queued-picker acceptance and launch-option handling are preserved: both started and queued return `true` and consume the options exactly as today; only the new refusal returns `false`.

**The same three outcomes apply to a command-line takeover.** `commandLineTakeover` (`AppDelegate.swift:2339`) calls `engine.admitCommandLineOpen`, which can promote the new request synchronously when the outgoing session has no live connection to close (`EngineSessionCoordinator.swift:307-321`: `started` is true when the queue drained inside the call). Today the function returns that Boolean as computed before the effects run, and it detaches and closes the outgoing window before `run(effects)`. With the fresh-open gate in `run`, the gate can refuse the promoted request after the outgoing window is already gone, so the stale `started` would tell the waiting CLI caller the open began. The takeover therefore returns the same three outcomes, derived from the request's own batch and the state after `run`: started, accepted and waiting, or refused. Both callers use it: the accept-and-wait branch of `handleCommandLineHandoff` (`:2311`) and `resolveSyncLeaveChoice` (`:2558`). On refusal:
- The caller, who is still waiting synchronously, receives `.refused(message:)` built from the gate's own refusal wording, not `.started` or `.acceptedWaiting`.
- The refused operation is failed exactly, so the coordinator returns to idle.
- Because takeover already detached the outgoing window, no window and no picker exist, so the picker is restored with the profile selected, and the blocked notice is shown.
- On the sync-leave path, the sync exit was requested before the takeover, so a refusal after the pre-exit check leaves that sync aborted or running in the background according to the user's choice. This is accepted rather than rolled back; the pre-exit check makes it rare, since it needs an external edit between two reads.
A takeover that does not promote synchronously (the outgoing session has a live connection to close) takes the queued-open path when it drains.

**The reconnect transition.** When the exact reconnect operation is refused before init1 is dispatched, end that attempt and return the existing session to a disconnected state, keep the results the window already shows, keep Sync unavailable until a reconnect succeeds, and let the user retry once the staging block is resolved.

- *Fits the existing state.* `.ready(session)` with the connection `.disconnected` is where a remote session sits after a sync-end close, and both reconnect sites begin from it. `requestSync` already refuses in `.disconnected` and says the user must rescan first (`EngineSessionCoordinator.swift:400-403`), so Sync stays unavailable without a new rule.
- *Reconnect identity.* `.opening(s, op)` looks the same for a first connect and a reconnect, and a refused first connect must still end idle. The coordinator therefore records the operation id of an in-flight reconnect at the two reconnect sites. The new transition takes `(session, op)` and applies only when it matches both the current `.opening(session, op)` and that record. A refusal that matches neither returns no effects. The record is cleared whenever the attempt ends: a successful connection, a failure, a refusal, or restart-required. Test: an old refusal arriving during a newer reconnect leaves the newer attempt intact.
- *Abandonment.* If the matching session was abandoned, the refusal uses the existing close-and-drain path (`beginClose(.toIdle)`, which reaches `finishToIdle`), so a queued request can proceed. Only a session that is still owned returns to disconnected-ready.
- *Rejected: closing the window.* The window-closing fallback is not used, because it discards results the user is reading.

**The window.** `ReconcileWindowController.beginScanning` clears the rows, the tree, the row overrides, and the details text before the spinner starts (`ReconcileWindowController.swift:722-745`). After the spinner has begun there is nothing to preserve, so the reconnect gate must run before `beginRescan` is called. `driveBeginConnect` calls `beginRescan` after the session args are applied (`:669`), so the reconnect gate belongs ahead of it. The window then keeps its results untouched, the user is told why the rescan was blocked, and no indicator was ever shown.

**Decision: no defensive spinner-reset method, and no empty-results fallback.** Both reconnect paths reach `driveBeginConnect` before any scanning presentation starts. The menu's rescan request is forwarded without starting a spinner (`windowRequestedRescan`, `AppDelegate.swift:476`), and a rescan requested while a remote close is in flight only records the intent (`requestRescan`, `EngineSessionCoordinator.swift:330-337`). The reconnect spinner starts later, in `driveBeginConnect` (`:669`). The test verifies that a refused reconnect leaves the summary, the rows, the selection, and the spinner state unchanged. If a supported path is found that already enters the scanning presentation before the gate can run, the response is to move the gate ahead of that path, not to accept an empty results window. Returning the user to an empty list would defeat the reason this design preserves results at all.

*Open, to check before the reconnect pull request:* how the window presents Sync today in the existing disconnected-ready state after a sync-end close. The refused reconnect should land in that same presentation, not a new one, and the Sync control should not look enabled when the coordinator will ignore it (`ReconcileWindowController.swift:642` gates on `actionGate.allows(.sync)`).

**Request for review.** A driver test that observes both the effects that executed and the coordinator's terminal outcome. Under `suppressEngineEffectsForTesting`, `.beginConnect` is skipped but `.showSession` still executes, so a gate at the batch level is reachable in tests, and the test must also prove that no bridge dispatch was attempted. Cases for the first pull request: queue an admissible profile behind a close, then edit its roots or an include to an already-known held family, complete the close, and verify no window and no init1; an immediate open whose profile is edited between the request-time check and the gate, which must refuse and report not started; a pre-exit refusal while the sync decision is pending, with the sync, its window, and its exit intent untouched; a takeover from a ready session with no live connection whose promoted request the gate refuses, which must report refused, fail the exact operation, restore the picker, and leave the outgoing window gone; for both the immediate and the queued refusal, an assertion that the engine returns to idle and that a subsequent valid open works; a reconnect batch (no `.showSession`) that the first pull request leaves alone; and an unchanged-profile control for each. For the reconnect pull request: a refused reconnect leaves the summary, rows, selection, and spinner unchanged. Coordinator unit tests for the reconnect transition: a refusal returns to disconnected-ready, a stale refusal is ignored, an abandoned session closes and drains the queue, a refused first connect still ends idle, and Sync stays unavailable.

**Tracked separately.** Discovery of new staging written by another process after admission. An in-memory snapshot cannot know it, and it needs its own decision about whether to rescan at the boundary and what that costs on a large Unison directory.

**Expected outcomes.**
- **User:** a blocked target never reaches init1. A queued refusal returns to the picker with a notice. A refused reconnect keeps the results on screen, Sync unavailable, and a notice, and a retry works once the block is resolved.
- **CLI caller:** a refusal before acceptance; no change after acceptance.
- **Engine:** no init1 for a blocked profile; no overlapping connects; no stale refusal affecting a replacement session.
- **Filesystem:** untouched.

**Size.** Planning inputs only. First pull request (fresh-open gate in `run`, CLI pre-exit check, request-tied reply): about thirty lines and five tests. Second pull request (reconnect transition): about fifteen lines in the coordinator, about fifteen in `AppDelegate` and the window (not yet specified), and four to five tests. The second is a coordinator change, so it is a design change rather than a maintenance fix. It is scheduled for a subsequent planned release and reviewed on its own.

### C, D, and H. Retry ownership, designed together

These three describe one problem: the one-shot `ignorearchives` edit and the retry that requested it have no shared owner.
- **C.** The fatal retry can return without ending the failed operation.
- **D.** The rescan confirmation can act on state that changed during its modal.
- **H.** Cancelling the waiting window leaves the injected edit in the profile.

Severity if reachable: C P2, D P2, H P3.

**Source.**
- *Fatal retry (C).* After the alert, `_swiftFatalTrampoline` calls `fatalRetryIgnoreArchivesHandler` if the user chose retry and `fatalDismissedHandler` otherwise (`UnisonBridge.swift:478-481`). Only the dismissed handler reaches `failCurrentOp` (`AppDelegate.swift:1360`, defined at `:1068`). The retry handler (`:1369`) returns silently when `lastAttemptedProfile` is nil and otherwise calls `rescanIgnoringArchives` (`:2790`), which has three early returns that beep and stop: the profile cannot be read (`:2793`), it changed during the stale-read recheck (`:2809`), and the write fails (`:2815`). On any of them no operation is failed and no teardown runs.
- *Stale confirmation (D).* `rescanIgnoringArchivesMenu` checks `RescanIgnoringArchivesGate` at `:2869`, runs `alert.runModal()` at `:2884`, then calls `rescanIgnoringArchives(profile:)` with the profile captured before the modal. It does not recheck the phase or that the same session still owns the reconcile window.
- *Edit ownership (H).* `ignoreArchivesPendingRestore` (`:146`, set at `:2821`) is a single app-wide URL. It is consumed by whichever init1 completion arrives next (`:1228`), by a blocked reopen (`:1134`), or by launch cleanup. The waiting window's `onClose` (`:815`) cancels the queued request but does not restore the edit.
- *A dropped completion leaks the edit.* The init1 completion handler returns before the restore when no connect is pending (`:1219`, "dropping init1 completion"), so a completion that arrives after the connect was invalidated leaves the suffix in the file.

**Observed.** Nothing in this group has been run in the app. D's consequence chain is inferred from source.

**Unverified.** That a handoff can be handled during `runModal` on the supported AppKit path. The existing code relies on that (the recovery offer rechecks after its modals for this reason), but D's trigger is a hypothesis until a driver shows it. Also unverified: whether the engine's own fatal handling leaves the coordinator idle by another route before the retry handler runs, which would make C harmless.

**The invariant.** The suffix is shared state: any init1 that loads the profile reads it. Binding a record to a retry therefore cannot, by itself, stop another open from picking the suffix up. What the record controls is cleanup timing. The invariant to keep is: the suffix is present in the file only between the write and the load performed by the operation that owns it.

**Design.** Give the edit an owner by binding it to the retry that requested it.

*One record per retry.* Replace the app-wide URL with a small record created when the edit is written: the profile, the file URL, the exact suffix written, the originating session and operation, and a state. A completion may consume a record only if it belongs to that record's session and operation.

*How the record transfers.* The record moves through four stages, and each transfer is made by the code that performs the step:
1. **Prepared.** Created in `rescanIgnoringArchives` after the write, bound to the originating session and operation.
2. **Queued.** `reopenCurrentProfileFresh` calls `requestOpen`. If the effects contain `.showWaiting(id, ...)`, the record binds to that `OpenRequestID`, because the open is waiting behind a close. If the effects instead contain `.beginConnect(s2, op2, ...)`, the open started immediately.
3. **Dispatched.** In `driveBeginConnect`, at the point init1 is dispatched, the record binds to `(s2, op2)`. From here the profile load may happen at any moment on the connect queue.
4. **Consumed.** The init1 completion for exactly `(s2, op2)`, or its failure status, consumes the record and restores the file.

*Before dispatch versus after dispatch.* The two cases need opposite handling.
- **Cancellation before dispatch.** The profile can no longer be loaded with the edit, so restore immediately. This covers a queued request cancelled from the waiting window (H), a queued request replaced by another, a refusal at the fresh-open gate (finding B), and a preparation failure.
- **Abandonment after dispatch.** Do not restore immediately. init1 runs on the connect queue and may not have read the file yet, so restoring now can remove the suffix before the load, and the recovery then silently runs without `ignorearchives`. Restore on the matching consumption signal, the completion or failure for `(s2, op2)`, or on evidence that the load can no longer happen. This also closes the dropped-completion leak above: a completion that arrives after invalidation must still restore the file, not return early. If no signal ever arrives, launch cleanup is the fallback.

*Terminal outcomes.*

| Branch | Outcome |
| --- | --- |
| Preparation fails (read, stale-read, write, no profile) | No edit remains. The failed operation ends through the same path as the dismissed button, and the user is told why the retry did not start. |
| Prepared but refused at the gate (blocked reopen) | Restore immediately, as `restoreIgnoreArchivesPrfIfNeeded` does today at `:1134`. |
| Queued, then cancelled from the waiting window (H) | Restore immediately. |
| Queued, then replaced by another request | Restore immediately. The replacement does not inherit the record. |
| Refused at the fresh-open gate, before dispatch | Restore immediately. |
| Dispatched, completion or failure for this session and operation | Consume, then restore. This is today's `:1228` behavior, now identity-checked and also reached when the completion arrives late. |
| Dispatched, then abandoned or invalidated | Restore on the matching signal, not before. |
| Terminal failure or quit | Restore if possible; launch cleanup remains the crash fallback. |

*External edits.* Restoration keeps the rule it has today (`:2842` onward): re-read the file, strip exactly the app-owned suffix from whatever the content now is, and never write back a saved snapshot. An edit made during the retry window survives. If restoration itself fails, leave the suffix for launch cleanup and do not report it as restored.

*Revalidate the session after the confirmation (D).* Capture the session id and the reconcile window identity when the menu action runs. After the modal returns, run `RescanIgnoringArchivesGate` again and compare the session. If either differs, beep and return with no edit and no teardown. A profile-name comparison alone is not enough: a same-name replacement session must also fail the check. Put the same recheck at the top of `rescanIgnoringArchives`, so the one function that edits the profile is the one that asserts it is allowed.

*Two authorizations, kept apart.* The menu action starts from `.ready` and its authorization is "this ready session is quiescent". A fatal retry starts from a failed operation that the coordinator still holds, and its authorization is "this session's failed operation may be finished". They share the edit-and-reopen steps but not the check. The menu path must keep `engineIsQuiescent: true` sound by requiring `.ready` at the boundary. The fatal path must instead end the failed operation by session and operation, through the existing failure path, and must not be refused by the `.ready` check.

**Request for review.** Drive the confirmation callback after replacing the originating session, and after making it busy; assert no file edit, no teardown, no queued open. Include a same-name replacement and an unchanged-session positive control. Inject a read failure and a write failure into the fatal retry and assert the failed operation reaches a deliberate terminal outcome. Cover refusal, cancellation before dispatch, abandonment after dispatch with a late completion, replacement before init1, and a matching completion, and assert an unrelated completion cannot consume the record. Keep the #212 regressions. If D's live trigger cannot be produced, name the guarantee that prevents it and where a future change could break it.

Expected outcomes:
- **User:** a retry that cannot start says so and leaves a usable picker. A stale confirmation does nothing visible. The profile file ends as it started, plus any edit the user made meanwhile.
- **CLI caller:** unaffected, except that a takeover during a confirmation no longer gets its session failed.
- **Engine:** no teardown of a session the confirmation did not originate from; no completion consumed by the wrong retry.
- **Filesystem:** the injected suffix is removed on every terminal branch, never before the owning load, with launch cleanup as the fallback only.

**Regression and control.** Red today: stale confirmation edits `A.prf` and fails the takeover's session; read or write failure leaves the operation unfailed; cancelling the waiting window leaves the suffix; a late completion leaves the suffix. Controls: an unchanged `.ready` session confirms and reopens; a successful retry restores the file on consumption; an external edit made during the retry survives restoration.

**Size.** About sixty to seventy lines including the record type, plus seven to nine tests. This is the largest item and the one most likely to want a short transition table in its pull request. It starts after G's fixture has validated the recovery contract, because G determines what the reopen carries.

### E. Fatal orphan removal: investigation

Severity: unknown until the investigation runs.

**Claim to investigate.** The "Delete orphan archives and retry" button calls `ArchiveMaintenance.mutate` with `isEngineIdle: { true }` and `revalidate: { _ in true }` (`UnisonBridge.swift:440`). The code comment says the failed operation has already unwound. That explains the failed worker. It does not establish either of two properties the removal needs: that the original operation still has authority after the modal, and that the archive candidates are still valid under lock.

**Source.**
- The recovery description, including `localOrphanHashes`, is computed before the main-queue hop (`UnisonBridge.swift:396`), so the candidate list is fixed before the alert is shown and is not recomputed afterward.
- The OCaml worker thread is parked on a condition variable inside the fatal callback until Swift calls `unison_bridge_fatal_response` (`UnisonBridgeC.c`, the modal handoff described around `:232-272`). That call happens after the mutation, at `UnisonBridge.swift:477`. The mutation therefore runs while the worker is blocked inside the callback, not after it returned.
- An unwound operation stack and a parked worker can coexist. `reopenCurrentProfileFresh`'s documentation (`AppDelegate.swift:1090-1105`) argues from upstream `uimacbridge.ml` that the exception has unwound the whole operation stack before the handler runs. That is an argument about the OCaml side. It does not say which archive locks the engine still holds while it is parked.
- The coordinator still holds the failed operation's phase during the modal, because `fatalDismissedHandler` has not run. `.idle` is therefore false, and `isEngineIdle: { true }` asserts a state that does not exist.
- Under lock, `ArchiveMutation.execute` acquires each archive's lock, derives the payload set from what exists at that moment (`ArchiveMutationTransaction.swift:364`), then calls `revalidate(plan)` (`:367`). The fatal path passes `{ _ in true }`, so nothing checks that the files under lock are the orphans the alert described.

**Questions the investigation must answer.**
1. *Authority after the modal.* While the modal is up, which transitions can the coordinator accept? A takeover can abandon the failed session and queue a request. Can any path start init1, close the connection, or mutate archives before the fatal response? Trace the bridge acknowledgement, the coordinator phase, and the socket and main-queue scheduling.
2. *What the engine holds.* At the moment the modal is shown, does the parked worker or the established connection hold archive locks (`lk` files) or other state on the candidate hashes? This is observable: on a fixture that triggers an archive-inconsistency fatal, list the lock files while the alert is up.
3. *Candidate validity.* Between the pre-alert computation and the mutation, can the orphan set change, whether by another Unison process, a user edit, or the profile's own roots? What does the per-archive lock establish against an external process, and what does the unconditional revalidation leave unverified?
4. *Whether the safe path needs `.idle`.* The fatal path may legitimately retain a coordinator lease. Requiring `.idle` blindly would break it. If a stale action can reach the mutation, the narrow fix is an operation-bound authorization and an under-lock check, not a phase check.

**Decision to make.** Either record the evidence that the lifecycle rules out a competing transition and the candidates are adequately validated, and test that guarantee, or propose an operation-bound authorization plus a real under-lock revalidation. Naming the constant or counting its uses in source proves neither property, so a naming change or a source scan alone does not resolve this.

**Evidence to request.** Hold the dialog open, or use a seam at its completion, attempt a competing transition, and show whether the archive transaction can proceed under stale authority. Make an external change to the candidate set during the dialog and show what the transaction does. If a fix is proposed, preserve the ordinary authorized orphan-recovery path and its blocked-by-lock outcome handling (`UnisonBridge.swift:450-475`).

**Size.** Not estimated. It depends on the answers above.

### G. Recovery scope

Decision: a recovery reopen preserves the original session's options. A recovery of the same session keeps the scope the user chose. If the session was opened with `-path Documents`, recovering from an archive error does not silently widen the scan to the rest of the profile, especially because ignoring archives can make existing items appear new. The picker's rule stays as it is: a picker selection is a new session with no inherited options.

**Source.** `reopenCurrentProfileFresh` calls `run(engine.requestOpen(profile: profile))` with no args (`AppDelegate.swift:1141`), and the coordinator clears `currentArgs` in `finishToIdle`. The same call is at `:1100` in v1.0.0, so this is not a regression.

**Contract to implement, subject to the fixture:**

| Transition | Path scope | `ignorearchives` |
| --- | --- | --- |
| First Retry Ignoring Archives or Rescan Ignoring Archives | Same effective scope as the original session. | Forced on for the recovery load. |
| Rescan that reuses the recovered engine state | Same scope. | The recovery setting may still be in memory. Describe it as one fresh load unless the app explicitly clears it after the first scan. |
| Later reconnect that reloads the profile | Same scope, with the original session options reapplied. | The restored profile and the original session options are used. The temporary recovery override is gone. If the user originally requested `ignorearchives`, that setting still applies. |

**Why the fixture decides the details.**
- *Source.* `do_unisonInit1` runs `resetToDefaults` and `loadTheFile` on every re-entry, then applies the stored session vector through the engine's parser after the profile is loaded (`patches/0008-uimacbridge-session-argv.patch`). So the injected `ignorearchives` line is read when the profile loads, and the session args are applied afterward.
- *Source.* A list option such as `-path` combines with the profile's own paths. It does not replace them (`docs/cli-session-requests-design.md`, the session-overrides section).
- *Unverified.* Because session options are applied after the profile loads, an original session option that explicitly disables `ignorearchives` could override the temporary profile line, so the recovery action would do nothing. The fixture must test that case, and the contract must say what the app does if it occurs. Also unverified: whether the recovery override affects only the load that read it, which decides whether a later reconnect behaves differently from the first recovered scan.

**Request for review.** An isolated fixture with two paths of distinguishable contents, a session scoped to one of them, then the first recovered scan and a later reconnect. The fixture verifies what the engine actually scans, not only which arguments Swift passes. It checks that the excluded path stays excluded, that the override takes effect on the first load, that the profile file is restored, and what happens when the original options explicitly disable `ignorearchives`.

Expected outcomes:
- **User:** the recovered scan covers the same paths as the original session.
- **Engine:** init1 receives the same vector, plus the one-shot profile edit.
- **Filesystem:** unchanged beyond the one-shot edit.

**Regression and control.** Open with `["-path","Documents"]`, recover, and assert the next connect carries the same vector and scans only that path. Control: a picker-opened session recovers with an empty vector.

**Size.** About three lines to carry the options, plus the fixture. It is designed together with C, D, and H, because the retry record should carry the originating session's args.

### I. Secondary-launch suffix cleanup: hypothesis

**Claim.** Launch-time cleanup runs before the process learns whether it is a primary or a secondary instance. A secondary instance could strip a still-live primary retry's `ignorearchives` marker from a shared profile.

**Source.** `cleanupStrayIgnoreArchivesMarkers` runs at `AppDelegate.swift:1861` and rewrites any `.prf` that ends with exactly the app-owned suffix (`:2897`). `routeCommandLineHandoff()` runs after it, at `:1871`. Both instances share the same Unison directory. A primary that has written the suffix and not yet consumed it holds a live marker that the cleanup cannot tell apart from a stray one left by a crash.

**Election outcomes matter.** Moving the cleanup below the routing call does not make it safe on its own. An instance that loses the election with no profile request continues running without a listener (`.lostElection` at `:2214`), and an instance that cannot elect continues as a plain launch (`.couldNotElect` at `:2224`). Such an instance is not the owner of the shared state, and it would still reach a cleanup placed after routing.

**Unverified.** Reachability. The window is the time between the primary writing the suffix and its init1 reading it. That is short for a local profile and longer for a remote one, where the reopen waits for the connection close. A second instance must also arrive inside it. If the suffix is stripped, the primary's retry loads the profile without `ignorearchives` and could hit the same inconsistency again, which would look like a failed recovery. I have not reproduced this.

**Would disprove it.** Showing that a second instance cannot reach the cleanup while a primary's marker is live on any supported path, or that the cleanup cannot match a suffix the primary wrote in the same session.

**Questions for review.** Can a second instance reach `:1861` while a primary's marker is live? If so, the fix has to require demonstrated ownership before removing a potentially live marker, for example by having the primary record its live marker where cleanup can recognize it, or by cleaning up only as the elected listener. The per-retry record in C, D, and H gives a primary a way to identify its own marker, which is a reason to review this after that design is settled.

**Size.** Not estimated.

## Cross-checks and where the brief takes over

The reviewer's brief owns the cross-checks and the report format. Four checks matter most to the designs here:

- Every init1 producer, including initial opens, queued picker and CLI opens, the two-phase CLI decision, reconnect, and fresh retry, to find any path that reads a profile after the last safety decision.
- Cancellation and stale-completion handling at each asynchronous or modal boundary, reviewed for ordering and not only identity.
- Whether a test seam suppresses the very boundary under test. `suppressEngineEffectsForTesting` bypasses the effect executor, so a test of the init1 boundary must also show whether dispatch was attempted.
- Which cases failed on the old revision and passed with a candidate change, kept separate from tests that hung before running.

## Proposed sequence

One branch and one pull request per concern. Each has a test that is red against current `main` before the fix. Sizes are planning inputs, not commitments. Whether any item blocks the release candidate is the maintainer's decision; the table gives an order only.

| Order | Concern | Findings | Condition | Approx. size | Regression and control | Expected outcomes |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Refuse handoff while a credential prompt is open | F | If the driver reproduction confirms the hang | ~15 lines, 2 tests | Red: handoff during prompt is refused and the sheet, phase and queue are unchanged. Control: no sheet, request still waits; local `.opening` unchanged. | User keeps the sheet. CLI gets a refusal. Engine and files untouched. |
| 2 | Load staging state before exposing entry points | A | If the ordering or a race is confirmed on the real launch sequence | ~10 lines, 1 sequence test | Red: held archive plus handoff during launch is refused. Controls: unrelated profile opens; Later keeps the block. | First affected open blocked. Recovery offered after startup. |
| 3 | Delayed admission, first part: fresh-open gate (immediate and queued), CLI pre-exit check, request-tied reply | B | Independent of 1 and 2; ships in this release | ~30 lines, 5 tests | Red: edited queued profile creates no window and starts no init1; immediate open edited between reads refuses and reports not started; pre-exit refusal leaves the sync running. Controls: unchanged profile opens; admissible sync decision proceeds; a reconnect batch is not gated. | Blocked target never reaches init1. Queued refusal returns to the picker with a notice. CLI refusal only before acceptance. |
| 4 | Delayed admission, second part: narrow reconnect transition | B | Subsequent planned release; revisit if the review reproduces a reconnect into held archives | ~30 lines, no window method, 4 to 5 tests | Red: refused reconnect returns to disconnected-ready; stale refusal ignored; abandoned session closes and drains; first connect still ends idle; Sync unavailable. | Summary, rows, selection, and spinner state unchanged; Sync unavailable; notice shown; retry works after the block clears. |
| 5 | Retry ownership, with the recovery scope | C, D, H, G | After G's fixture validates the contract | ~60 to 70 lines, 7 to 9 tests | Red: stale confirmation, unended fatal retry, suffix after cancel, suffix after late completion. Controls: unchanged session reopens; external edit survives; matching completion consumes. | Edit restored on every terminal branch and never before its load. No teardown of another session. Recovery keeps the original scope. |
| 6 | Fatal orphan removal | E | Investigation first | Not estimated | Held dialog with a competing transition; external change to the candidate set. | Per findings. |
| 7 | Secondary-launch cleanup | I | Investigation; review after 5 | Not estimated | A second instance launched during a live retry marker. | Per findings. |
| Later | Scan outcome and undecodable manifests | #217, #218 | Planned for 1.1 unless the review reproduces an affected profile opening | Not estimated | Per the issues. | Per the issues. |

F and A are independent small changes and can go first if confirmed. B is two pull requests: the first touches the open path with no coordinator change and ships in this release, and the second adds the narrow reconnect transition in a subsequent planned release. C, D, and H move together, and G's contract is validated before they start. E and I stay investigations until their questions are answered.

## Decisions and evidence still needed

**Decisions taken.** F refuses during a credential prompt. G preserves the original session's options. A ships as the reorder alone, with #217 and #218 as follow-ups. B specifies all three paths with the narrow reconnect transition and the window-closing fallback rejected.

**Settled since the first draft.** B's first pull request ships in this release and the reconnect transition follows in a subsequent planned release, with the gap kept explicitly open. No defensive spinner-reset method is added.

**Still open, for the maintainer.** Nothing blocks starting the work on F, A, and B's first pull request. The release priority of B's second pull request is revisited only if the review reproduces a reconnect into held archives.

**Evidence the reviewer's report should supply.**
1. F: an end-to-end driver reproduction of the prompt-plus-takeover state.
2. A: the real launch ordering, including whether a handoff can be enqueued ahead of the deferred scan; and whether the #217 and #218 failures are reachable.
3. B: whether any guard blocks a profile edit during a live session of the same profile (which decides whether a reconnect into held archives is reachable); how the window presents Sync in the existing disconnected-ready state.
4. C and D: whether a handoff can run during `runModal` on the supported path, and whether the coordinator can already be idle by another route before the fatal retry handler runs.
5. E: the lock files present while the fatal alert is up, and the outcome of an external change to the candidate set during the dialog.
6. G: what the engine actually scans on the first recovered scan and on a later reconnect, and what happens when the original options explicitly disable `ignorearchives`.
7. I: whether a second instance can reach the cleanup while a primary's marker is live.

Notes the review also produced that need no action in this release: the coordinator's `admitCommandLineOpen` has no phase guard of its own and relies on its caller, which is unreachable today; quit and last-window close have no phase arbitration, so ⌘Q during a sync ends a background sync, which is a product decision; and the `pendingIgnore` guard covers rescan and sync but not diff or reopen.
