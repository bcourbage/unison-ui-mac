# Running the engine in a child process: brief

Status: proposal. This brief states the problem and the plan; the design documents it calls for
come next and carry the detail.

## Business problem

The app sometimes stops and shows "Unison needs to be restarted. Quit Unison and open it again to
continue." The user then has to quit, reopen the app, choose the profile again and wait for a full
rescan. If the stop happened during a sync, part of the sync has run and the rest has not, so the
user has to come back to it.

To the user this looks like an unreliable app, even though it is a deliberate safety stop. It is
the most visible rough edge left after 1.0, and on this point the app does worse than upstream:
upstream's GTK interface shows the same errors and then offers Rescan (`uigtk3.ml`,
`fatalErrorHandler`).

The cost is real on the maintainer's own machines. The Unison log on Heracles shows the
Pictures-to-Demeter profile losing its connection at the very start of a sync on Nov 19 and on
Nov 22, 2026. Both failures fall under the restart rule. After the Nov 22 restart, the same sync
completed.

A related limitation follows from the same cause. Only one profile can be open at a time.
Profiles that share nothing, such as Pictures and FlightSim, still have to run one after the
other. A command-line request that arrives during a sync cannot run alongside it: the app asks
the user to keep syncing without opening it, finish the sync and then open it, or stop the sync
and then open it.

## Cause

The Unison engine (the vendored OCaml build plus `uimacbridge.ml`) runs inside the app's own
process. Its state is global, and it was written for programs that run one session and exit.
When an operation dies partway through, the app cannot prove that the engine finished unwinding:
a fatal error the user dismisses, a connection that stops responding, a scan that stalls or a
close that fails all leave the engine in an unknown state. Reusing an engine in that state can
corrupt the conversation with the server, which is what issue #8 measured before its fix. The
app therefore refuses to continue (`EngineSessionCoordinator.enterRestartRequired`), and the only
way to get a fresh engine is a fresh process.

A clean close followed by a reopen works since the #8 fix. What the app will not reuse is an
engine whose operation was cut off. That rule is stricter than upstream's. Upstream continues
after an error, relying on cleanup inside the engine: when a sync fails, `Uicommon.transportItems`
aborts the transfers, closes the connection and drains the dropped threads
(`doTransportFailCleanup`) before the error reaches the interface. The app adopted its rule after
#8 showed in-process reuse corrupting the protocol, and has not yet qualified which failures that
cleanup makes safe.

The Nov 19 and Nov 22 failures fit a connection that died while the scanned profile sat open,
then failed on the first round trip of the sync. Whether the Mac's sleep caused that is not yet
verified.

## Possible solution

Run the engine in a child process, one per session, using the app's own executable in a new
headless role. When the engine fails, the app ends that child, keeps the window, and offers a
rescan with a fresh engine instead of a restart notice. The replacement engine starts only when
the user accepts the offer.

The executable already runs the engine without windows: `unison -server` (what a remote peer
spawns over SSH) and `unison -ui text` both go through it today
(`CommandLineInvocationPolicy.swift`, `Sources/CLTool/cltool.c`). The proposed engine role uses
that executable. A separate small C lifeline helper is added for transport cleanup and included
in signing/notarization qualification. The new role needs launch-routing, signing/notarization and TCC qualification under the actual
launch topology. The design selects inherited Unix socket pairs. Embedded XPC is an alternative
if the selected topology fails qualification.

Alternatives considered:

- **Drive the stock `unison -ui text`.** Unison 2.54 has no machine-readable interface, so the
  app would have to parse output written for people and would lose the reconcile tree, diffs,
  progress and the prompt sheets. Rejected.
- **Recover in process, as upstream does.** For failures where upstream's cleanup is known to run,
  such as a lost connection during a sync, the app could treat the engine as reusable and offer a
  rescan. This may be the cheapest fix for the Nov 19 and Nov 22 failures, and it needs a
  qualification pass that proves the cleanup ran before the error reached the app. It does not
  cover stalls, Stop on a scan, or several syncs at once. Evaluated in step 1 of the plan as an
  interim fix, and kept as the fallback if the spike fails.
- **A "Relaunch and Reopen" button on the restart notice.** Small, and it helps in every case,
  but the restart still happens. Worth building only if the child process is more than a release
  or two away.

## Changes to the app

### Phase 1: one engine process per session

- **Recovery contract.** One decision is made: after a failure the app offers a rescan and never
  starts one automatically, especially after a partial sync. The rest is open and must be
  answered before coordinator implementation: what stays visible after a failure, what happens to
  the rows and to row decisions the user made, how a partially completed sync is reported, and
  what authorizes starting the replacement engine.
- **Engine role.** A hidden launch mode that hosts the existing bridge and talks to the parent
  over inherited Unix socket pairs, as selected in the design.
- **Protocol.** The bridge's callbacks become messages: status, progress, scan and sync
  completion, reconcile rows, row reloads, ignore results, diffs, and the scan-failed signal.
  Three exchanges block the engine until the user answers: the SSH password or host-key prompt,
  the warning sheet and the fatal-error sheet. Those become request and reply, and each must be
  released on Cancel, on a fatal response, when the channel closes and when the app quits.
  Messages carry their session, engine, operation and prompt-request identities, and every
  terminal reply (a completion, a failure, an answer to a prompt) is consumed exactly once, so a
  late reply, a duplicate completion from the same engine or a closed channel can never act twice
  or reach a replacement engine or a later session. The design defines how. Reconcile lists can be
  large and need an efficient encoding.
- **Stopping the engine.** Stop during a scan ends the child; today a hung remote scan needs a quit
  and relaunch, because interrupting a scan in process was never made safe (#53, #94). Stop
  during a sync stays cooperative first: today's abort lets transfers unwind and reports partial
  results. Forced termination during a sync is the last resort, used when the abort cannot be
  requested or does not finish within a bound that the design sets. After a forced termination,
  the next scan must handle the archive lock and any interrupted state.
- **Supervisor and cleanup.** The GUI owns the engine. Each transport starts through a signed
  v2 lifeline helper that watches engine exit and stays outside the transport's process group.
  It retains the transport leader unreaped while it signals and observes the group. Before
  spawning it must publish a start record, and after observed cleanup it publishes a completion
  record. Local cleanup requires engine reaping, all start/completion records matched, and pipe
  EOF. EOF alone is insufficient. The engine requests helper cleanup with SIGTERM and never
  kills the helper to force a deadline. Unresolved cleanup remains visible and blocked. Record
  delivery, group observation, patch integration and platform behavior remain qualification gates.
  A closed/full status reader must not kill or stall the cleanup owner. The credential loop
  needs actual SSH exit evidence separately from helper liveness. A same-engine reconnect waits
  for the previous helpers' verified completion before starting another transport.
- **Crash reporting.** Distinguish a handled engine crash from a GUI crash while offering an
  appropriately worded report for unexpected engine defects. Contain deliberate test crashes
  so they do not trigger later hosted-test startup prompts.
- **Coordinator.** Restart-required becomes "engine ended", followed by the recovery contract
  above. Some of the logic that proves quiescence becomes unnecessary; how much depends on the
  next point.
- **The parent's own engine.** Retain launch parsing, profile selection, version/directory
  lookups and archive-lock calls in the parent initially. Isolate all session work in children.
  Audit the retained call boundaries and responsiveness. A bootstrap or maintenance worker is
  an alternative if evidence justifies its cost.
- **Unchanged.** Profiles, archive files, the remote side, the command-line tool and the user's
  workflow.

### Phase 2: several syncs at once

- **Session model.** The coordinator holds one phase and one queued request today. It becomes one
  coordinator per session, with windows and menus that act on their own session.
- **Overlap detection.** Two sessions must not touch the same files, and deciding that is a design
  problem of its own. Unison's lock already stops two profiles with the same roots from running
  together, but profiles with different, overlapping roots each have their own archive and
  nothing stops them; `Sync-Home-Demeter` and `Sync-Documents-iCloud` both sync `~/Documents`.
  Comparing root strings is not enough: local symlinks, includes, aliases, session options such
  as `-path`, remote host aliases, and parent and child paths all change the answer, as the app's
  existing archive-ownership and staging gates already show. It gets its own investigation before
  the app promises safe concurrency.
- **Command line.** A request for a profile that does not overlap a running session opens
  alongside it instead of going through the sync decision.
- **Prompts and quitting.** Two sessions can ask for a password at once; each prompt names its
  profile. Quit with several syncs running asks once for all of them.
- **Status.** The picker shows which profiles are running.
- **Resources.** Profiles that share a link or a disk compete for it (Pictures and FlightSim both
  write to Demeter's `/Volumes/Media`), so running them together is not always faster. A
  per-host limit is a candidate setting, not a requirement.

## Development plan

1. **Verify the current cause and size an interim fix.** Confirm or rule out sleep as what ends
   the idle connection, using the Unison log and `pmset -g log` around the Nov 19 and Nov 22
   failures. Then decide whether in-process recovery for a lost connection during a sync, the
   relaunch button, or neither ships before phase 1. The design includes a conditional interim
   implementation/release step after that qualification, sized from its result.
2. **Combined design document: engine processes and concurrent sessions.** The recovery contract and the parent's own
   engine come first, then the launch role, channel, message set and its lifetime rules,
   supervisor and cleanup, stopping, coordinator states and failure model.
3. **Spike** (Debug-only, behind a launch flag), against these gates:

   | Gate | What it must demonstrate |
   |---|---|
   | TCC | The signed child reaches the real protected paths (the Pictures profile's Photos library, a Full Disk Access path) under the intended launch mechanism, including a fresh grant and a denied one. Measured first, as the largest risk. |
   | Process cleanup | Qualify engine/GUI death, v2 helper Stop, stubborn descendants, reliable S/D records, group observation and adapted retire/shutdown paths. Verify engine reaping plus matched S/D plus EOF. Test failures as well as happy paths. |
   | Archive recovery | A kill during scan, during transfer and during the archive write leads to a next scan that handles the lock and the interrupted state correctly. |
   | Protocol lifetime | Late replies, duplicate completions, cancellation and a closed channel cannot affect a replacement engine or session. |
   | Reconcile data | Delivery time, peak memory and responsiveness for the largest profile, against today, including the case where both processes hold the list. |
   | Prompts | Password retries, Cancel, fatal responses and quitting the app all release the blocked engine exchange. |

4. **Implementation, phase 1**, in reviewable PRs: engine role and channel, supervisor and cleanup,
   coordinator rewiring and the recovery contract, Stop, archive maintenance, then removal of the
   in-process session path.
5. **Bake.** Daily use on Heracles before release, with the attended checks for connect, scan,
   sync, Stop, prompts and recovery.
6. **Investigation: overlap detection**, then the **design document for several syncs at once**
   (phase 2).
7. **Implementation and bake, phase 2.**

## Risks

- **TCC.** Grants are expected to apply to a child of the app, but this project has been caught
  out by TCC attribution before. The spike measures it before any production work.
- **Cleanup after a forced stop or ordinary transport exit.** Transport children, archive locks and interrupted writes must
  be handled by a process that survives the engine, and something must still clean up when the
  app itself dies.
- **Blocking prompts across processes.** Timeouts, cancel and the app quitting while a prompt is
  up all need defined behavior.
- **Large reconcile lists.** Encoding and transfer must not make big profiles slower to show or
  double their memory cost.
- **Retained parent runtime.** The parent keeps limited global engine state and bridge
  machinery. Its session-work exclusion and responsiveness need qualification.
- **Size.** See [the design's step estimates](engine-process-design.md#11-migration-implementation-sequence-and-size-budget).
  Phase 1 is estimated at 26–53 engineering days plus bake, excluding a conditional interim fix.
  Phase 2 adds 16–33 days plus bake. Lifeline integration and platform qualification can change
  those estimates. The bridge and its in-process test machinery require substantial rework.

## Success measures

- No restart notice in normal use. A lost connection, a stall or a failed close ends in an offer
  to rescan, with the outcome of any partial sync shown.
- Stop ends a stuck remote scan within seconds.
- Transport children of an engine that was stopped, crashed or killed, or of an app that quit or
  crashed, have verified cleanup within the qualified deadline, or the session stays in
  cleanup-blocked state with the reason. Local cleanup is never reported complete without
  matched start/completion records, engine reaping and status-pipe EOF.
- Recovery after an engine failure, including cleanup and lock handling before the fresh scan,
  adds a measured overhead over a fresh open of the same profile, with a target set in the
  design.
- Phase 2: two non-overlapping profiles sync at the same time, and an overlapping pair is refused
  or queued with a message that names the conflict.

## Open questions

- Version: does phase 1 ship as 1.x or as 2.0?
- During the bake, does the in-process path stay available as a fallback setting, or is the switch
  all at once?
- Which interim fix, if any, ships while phase 1 is built: in-process recovery after a failed
  sync, the relaunch button, or closing the connection before sleep?
