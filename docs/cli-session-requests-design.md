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
| Synchronizing | Present the existing Keep Syncing / Abort & Close / Close (let it run) decision. |
| Results after synchronization | Leave the current session and open the requested session after any outstanding cleanup. |
| Profile editor open | Refuse the request, name the profile being edited, and ask the user to close the editor and run the command again. Preserve all edits. |
| Restart required or unresolved recovery | Refuse with the applicable recovery instruction. Do not bypass the recovery restriction. |

Leaving a scan does not forcibly interrupt the engine. The new session waits for the existing engine operation to finish safely.

### During synchronization

The dialog's choices have explicit consequences for the incoming request:

- **Keep Syncing:** preserve the current session and reject the incoming request.
- **Abort & Close:** request the existing supported abort behavior; open the incoming session only after the engine finishes aborting and cleanup completes.
- **Close (let it run):** let the existing synchronization finish in the background; keep the incoming session waiting until the engine is available.

No incoming CLI request silently aborts a synchronization or chooses a dialog response.

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

Existing installation and Unison-directory compatibility checks remain unless separately redesigned and reviewed. This design removes dependence on the receiver's original launch options; it does not authorize routing a request to an incompatible app installation or configuration directory.

Invalid or unsupported requests are rejected before disturbing the current session where validation permits. Errors must not terminate the running app.

Arguments are transported as structured values, preserving their boundaries and order. They are not reconstructed as a shell command.

## Engine integration

The preferred implementation reuses upstream's preference parsing and validation rather than reproducing option semantics in Swift or adding a separate setter for each option.

For each fresh session load, the engine should:

1. Establish the requested profile's effective settings.
2. Apply that session's explicit overrides with upstream-compatible precedence and parsing.
3. Connect and scan using the resulting configuration.

The same session overrides are reapplied when reconnecting requires a fresh preference load. A new session receives its own overrides, including an empty set for an ordinary picker selection.

Preference changes occur only when the engine is available for that operation. They must not alter an earlier scan or synchronization still running in the background.

Temporary edits to profile files and mutation of the process-wide command line are not the intended mechanism. Parser failure must leave the app in a defined state and must never cause a partially configured session to synchronize.

The exact bridge and parser changes require implementation investigation. Reuse of upstream parsing is the preferred approach, not an assertion that the current bridge already exposes the necessary API.

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

- A CLI session with `-path Documents` scans only that path; local rescans and remote reconnecting rescans preserve it.
- A later CLI request with different overrides uses only its own overrides.
- A later picker selection, of either the same or a different profile, uses no previous CLI overrides.
- An option-bearing launch without a profile applies its overrides to the first selected session only.
- Requests received during scan, reconciliation, synchronization, and post-sync cleanup follow the state table.
- Each synchronization-dialog choice produces the specified result.
- An open editor retains its contents and causes a clear refusal.
- A second pending request cannot replace the first.
- Expired requests cannot start later; lost replies do not cause retries or duplicate opens.
- Invalid options do not terminate the app or disturb an active synchronization.
- Relative arguments retain their intended meaning across handoff.
- Installation, configuration-directory, and recovery restrictions remain effective.

Tests involving synchronization use disposable local and remote roots. Release acceptance runs against the signed RC and records the exact build and results.

## Delivery approach

The engine's session-specific option handling is established and reviewed first, including initial loads and reconnects. The running-instance transitions and caller-result handling follow on that foundation.

Removing the current handoff refusals alone does not complete this design. The release includes the behavior only when option lifetime, queued-request handling, and the live acceptance scenarios are verified.
