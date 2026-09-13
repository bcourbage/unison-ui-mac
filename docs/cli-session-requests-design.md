# Command-line requests as independent profile sessions

**Status:** Proposed design
**Scope:** Graphical command-line launches, requests sent to a running app, and profile-session option handling.

## Purpose

Each graphical `unison` command requests a new profile session with its own options. Its behavior depends on what the app is currently doing, not on whether the app originally started through Finder or the command line.

For example:

```sh
unison home -path Documents
```

opens `home` scoped to `Documents`. A later:

```sh
unison work -path Projects
```

requests a new session for `work`, scoped to `Projects`. Neither session inherits the other's command-line overrides.

Opening a profile authorizes connection and scanning only. Applying synchronization changes still requires the user's action.

## Session and option lifetime

A session begins when a requested profile opens and continues through its scans, synchronization, rescans, and connection re-establishment.

The session retains its own command-line overrides throughout that lifetime:

- Initial scan, in-place Rescan, and reconnecting Rescan use the same overrides.
- Synchronization operates on the reconciliation results produced for that session.
- Returning to the picker and selecting a profile begins a new session, even when selecting the same profile.
- A picker selection supplies no command-line overrides.
- A new CLI request supplies only that request's overrides.
- Ending a session does not persist its overrides into profile files.

Thus `-path Documents` remains effective after a non-interactive connection closes at synchronization completion and Rescan reconnects.

The app's original process arguments are not the authority for later sessions.

## Entry points

Initial graphical CLI launches and requests handed to a running app use the same session-request model and option semantics.

A graphical launch without a profile shows the picker. If that launch includes profile options, those options belong to its first selected profile session; subsequent ordinary picker selections have no overrides.

Text mode, server mode, version queries, help, and other process-level roles retain their separate behavior. They do not become graphical session requests.

## Behavior when a request arrives

The transition follows the existing **Profiles → select profile** interaction, while preserving the additional obligations to the CLI caller.

| Current app state | Behavior |
|---|---|
| Idle at the picker | Open the requested session and start scanning. |
| Scanning | Leave the current view using the existing abandonment behavior. Show the requested session waiting until the prior operation and required connection cleanup finish, then open and scan it. |
| Reconciliation results, before synchronization | Leave the current session, complete required cleanup, then open and scan the requested session. |
| Synchronizing | Present the shared three-way sync decision (Keep Syncing; Don't Open / Finish Sync, Then Open / Stop Sync, Then Open) as a non-blocking sheet. |
| Results after synchronization | Leave the current session and open the requested session after any outstanding cleanup. |
| Profile editor open | Refuse the request, name the profile being edited, and ask the user to close the editor and run the command again. Preserve all edits. |
| Restart required or unresolved recovery | Refuse with the applicable recovery instruction. Do not bypass the recovery restriction. |

Leaving a scan does not forcibly interrupt the engine. The new session waits for the existing engine operation to finish safely.

### During synchronization

The sheet is the same shared presentation used for an ordinary window close during
a sync; only the wording differs. Its choices have explicit consequences for the
incoming request:

- **Keep Syncing; Don't Open:** preserve the current session and reject the incoming request. (The default; a dismissal resolves here.)
- **Finish Sync, Then Open:** let the existing synchronization finish in the background; keep the incoming session waiting until the engine is available.
- **Stop Sync, Then Open:** stop the current synchronization; open the incoming session only after the engine finishes stopping and cleanup completes.

No incoming CLI request silently stops a synchronization or chooses a sheet response.

The three-way decision is raised only for an active synchronization the user is watching — one whose window is on screen. A synchronization the user already sent to the background (via Close let it run, so its window is gone) offers no decision surface and needs none: that session is already leaving, so a request there is simply accepted-and-waiting and opens when the background synchronization finishes.

**Caller experience (decided).** While the decision is open the caller waits, within the admission deadline, rather than being told a terminal result prematurely. The primary first sends an immediate notice — a synchronization is running and a decision is required in the app, including the timeout — and the caller keeps waiting on the same connection while the app and server stay responsive. After the choice it reports the accurate outcome: Started, Accepted and waiting, or Refused. The admission deadline is enforced: on expiry the request can no longer be started by a later choice and its pending slot is released. Once a request is accepted, it may wait for engine cleanup beyond the admission deadline (that later wait is the app's, not the caller's). A lost final reply is Outcome unconfirmed and is never retried automatically.

## Pending requests and caller results

At most one external request may be pending, including one awaiting a dialog decision or engine availability. Further CLI requests are refused clearly; they never replace an acknowledged request.

The CLI distinguishes these outcomes:

| Outcome | Meaning |
|---|---|
| Started | The requested profile began opening. This does not mean scanning or synchronization completed. |
| Accepted and waiting | The app accepted responsibility for the request, but opening is waiting for the current operation and cleanup. |
| Refused | The request was not accepted. The response explains why and any appropriate next step. |
| Outcome unconfirmed | Communication ended without a conclusive reply. The caller should inspect the app before retrying. |

An accepted-and-waiting request is visible in the app. If it later fails or is cancelled, the app reports that outcome rather than silently dropping it.

A request still awaiting a user decision is not reported as accepted. Admission has a bounded deadline. Once the request expires, a later dialog response cannot start it.

A lost reply does not trigger an automatic retry: the original request may already have been accepted.

The implementation must also prevent ordinary picker actions from silently replacing an accepted pending CLI request. Any cancellation or replacement must be explicit and visible.

## Request context and validation

A request contains enough information to reproduce the caller's intended graphical profile session, including its profile, ordered option arguments, and any caller context needed to interpret relative paths.

Relative arguments follow each option's own upstream interpretation. In particular, `-path Documents` is a path within the synchronization roots, not the caller's working directory, and is never rewritten against a cwd. Caller context such as the working directory travels only for arguments whose upstream semantics require it, and the app never changes its own process-wide working directory to serve a request.

Existing installation and Unison-directory compatibility checks remain unless separately redesigned and reviewed. This design removes dependence on the receiver's original launch options; it does not authorize routing a request to an incompatible app installation or configuration directory.

Invalid or unsupported requests are rejected before disturbing the current session where validation permits. Errors must not terminate the running app. Because a mutating parser changes global preferences, validation is itself subject to the concurrency rule in **Engine integration**: a queued request only stores its arguments, and neither applying them nor any preference-touching validation runs until the prior operation and its cleanup finish.

Arguments are transported as structured values, preserving their boundaries and order. They are not reconstructed as a shell command.

## Engine integration

The preferred implementation reuses upstream's preference parsing and validation rather than reproducing option semantics in Swift or adding a separate setter for each option.

For each fresh session load, the engine should:

1. Establish the requested profile's effective settings.
2. Apply that session's explicit overrides with upstream-compatible precedence and parsing.
3. Connect and scan using the resulting configuration.

The same session overrides are reapplied when reconnecting requires a fresh preference load. A new session receives its own overrides, including an empty set for an ordinary picker selection.

Preference changes occur only when the engine is available for that operation. They must not alter an earlier scan or synchronization still running in the background. A queued request only stores its arguments; nothing that touches engine preferences, including validation, runs until the prior operation and its cleanup finish.

Session overrides must match upstream's own parsing, including list accumulation and command-line versus profile precedence. A list option such as `-path` follows upstream's rule for combining a command-line value with the profile's configured paths; it must not be assumed to replace them. Scalar, boolean, alias, and repeated-list options are all in scope.

Temporary edits to profile files and mutation of the process-wide command line are not the intended mechanism. Parser failure must leave the app in a defined state: a partially applied option set must not begin connection or scanning either, not only synchronization. After a failure the app establishes a clean configuration before another request runs, or requires a restart. Catching the parser's error is not sufficient; the recovered state must be demonstrably clean.

The exact bridge and parser changes require implementation investigation, in this order:

1. First investigate an **app-owned adapter** that reaches existing OCaml APIs (for example `Prefs.loadStrings`, which is **not** currently exposed as a Swift/C bridge capability) **without changing upstream engine source**. Establish how the adapter reaches those APIs through the bridge.
2. Distinguish avoiding an upstream **source patch** from avoiding a **blob rebuild**: exposing a new bridge callback still rebuilds the blob (via the repository's existing `unison/src/Makefile.OCaml` path invoked by `make vendor-blob`, not a new `opam`/`dune` install), but it does not patch the engine's own parser.
3. If the adapter would require substantial duplication of the command-line option semantics, report that tradeoff before choosing an upstream source patch.

Neither approach is promised to work until the prototype demonstrates it, including its invalid-input and parser-parity cases.

## User-facing presentation

The app makes three facts clear:

- Which profile the request concerns.
- Whether it is waiting, opening, or refused.
- Which command-line overrides apply to that session.

Temporary overrides must remain distinguishable from saved profile settings, particularly when they change the scan's scope. The presentation should not imply that a picker-opened session retains overrides from an earlier CLI launch.

Refusal messages describe the actual restriction. The obsolete "this app was launched with options" refusal disappears once session-specific option handling is established.

## Verification

Acceptance covers the real engine and running-instance path, not only decision helpers.

Required scenarios include:

- A CLI session with `-path Documents`, on a profile that configures no additional paths, scans only that path; local rescans and remote reconnecting rescans preserve it.
- Scalar, boolean, alias, and repeated-list options each match upstream's parsing, including list accumulation and command-line versus profile precedence, not only `-path` on an otherwise empty profile.
- A later CLI request with different overrides uses only its own overrides.
- A later picker selection, of either the same or a different profile, uses no previous CLI overrides.
- An option-bearing launch without a profile applies its overrides to the first selected session only.
- Requests received during scan, reconciliation, synchronization, and post-sync cleanup follow the state table.
- Each synchronization-dialog choice produces the specified result.
- An open editor retains its contents and causes a clear refusal.
- A second pending request cannot replace the first.
- Expired requests cannot start later; lost replies do not cause retries or duplicate opens.
- Holding session A active, a received request B leaves A's effective settings unchanged, and no preference-touching validation of B runs while A is active.
- A failure after an earlier option has already been applied leaves no partial state: the next request cannot inherit it, and it does not begin connection or scanning; the app reaches a clean configuration or requires a restart. Catching the exception alone does not satisfy this.
- Invalid options do not terminate the app or disturb an active synchronization.
- Relative arguments retain their intended meaning across handoff, `-path` included as a root-relative path.
- Installation, configuration-directory, and recovery restrictions remain effective.

Tests involving synchronization use disposable local and remote roots. Release acceptance runs against the signed RC and records the exact build and results.

## Delivery approach

The first deliverable is a bounded engine prototype and an evidence report: A with overrides, then reload A, then B with different or no overrides, plus invalid-input recovery and parser parity. The report identifies the supported options, the limitations, the required build changes, and whether avoiding an upstream source patch actually reduces maintenance. The prototype uses the repository's existing OCaml build path (`unison/src/Makefile.OCaml`, invoked by `make vendor-blob`), not a new toolchain install, and adds no UI or socket changes.

On that basis, the engine's session-specific option handling is established and reviewed first, including initial loads and reconnects. The running-instance transitions and caller-result handling follow.

Removing the current handoff refusals alone does not complete this design. The release includes the behavior only when option lifetime, queued-request handling, and the live acceptance scenarios are verified. #161, the interim removal of the picker "launched with options" refusal, is a separate change and remains independent of this design.
