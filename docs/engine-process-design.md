# Engine processes and concurrent sessions

Proposed design for adversarial review and qualification. Written November 23, 2026.
Source baseline `013274e3ec5b9420f493811a57ec1463e154ed0c`.
Companion problem statement [engine-process-brief.md](engine-process-brief.md).

This design covers process isolation and concurrent sessions together. Phase 1 limits the
scheduler to one admitted session. Phase 2 permits several sessions after overlap detection
has passed qualification. Both use the same session identities, process ownership, protocol,
archive-maintenance exclusion, and request lifecycle. Phase 1 uses one global session lease.
Phase 2 adds resource claims and the engine preparation boundary they require.

The choices below are proposals for review. Numeric bounds are hypotheses pending baseline measurements.
TCC attribution, transport supervision, remote root identity, and the cost of separating
profile preparation from connection setup require experiments before production implementation.
The architecture has not been qualified. Standalone unsigned prototype checks have begun;
qualification reports and experimental evidence are maintained separately from this design.
The remaining guarantees and limits are recorded in section 4.
No signed-build, authenticated-SSH or macOS 15 experiment was performed by this author.

## 1. Outcomes and scope

A failed engine becomes a failed session with an explicit rescan offer. Other sessions and the
GUI remain usable. A replacement engine starts after user authorization and renewed admission.
A scan can be stopped by terminating its engine. A sync first receives cooperative Stop, with
forced termination available when that abort cannot complete.

Phase 2 admits sessions whose replica trees and archive resources are demonstrably disjoint.
Uncertain identity results in serialization with an explanation. Existing profiles, archive
formats, server protocols, and ordered session options remain compatible. An ordinary external
text-mode Unison continues to behave as it does today.

The app coordinates its own GUI sessions. External Unison processes still participate through
Unison's archive locks. Those locks do not protect every possible pair of overlapping replica
trees with different archives. Cross-application filesystem exclusion is outside the guarantee.

## 2. Evidence and current constraints

| Current component | Constraint the design must preserve or replace |
|---|---|
| `EngineSessionCoordinator.swift` | One global phase, one queue, exact session/operation terminal guards, and a distinction between abandoning UI and ending engine work. |
| `AppDelegate.swift` | Global pending bridge operations and callbacks, per-session windows, staging checks, CLI admission, and fatal recovery. |
| `UnisonBridgeC.h` / `.c` and `UnisonBridge.swift` | Global OCaml roots, callback handlers, blocking modal replies, credential preconnection state, and row operations tied to the current scan. |
| `StateItem.swift` | Value snapshots include direction, size, progress, transferred bytes, and the engine's `changedFromDefault` fact. |
| `main.swift`, `CommandLineInvocationPolicy.swift` | Shell parsing happens before AppKit. Server stdout is a wire protocol. User arguments retain order and are interpreted by Unison. |
| `ArchiveMutationTransaction.swift` | Durable intent before acquisition, under-lock planning, staged families, commit/rollback state, and lock identity evidence. |
| `ArchiveLock.swift` and patch 0006 | Actual acquisition authorizes mutation. A lock-file observation cannot substitute for acquisition. |
| `ssh-reaper-design.md`, patch 0004 | Exact child identity and signal-before-retirement prevent PID-reuse mistakes. The current reaper disappears when the engine dies. Its tracked-child terminal check also drives #35 prompt classification and must follow the actual transport rather than the helper. |

The local upstream checkout was also read. `terminal.ml` calls `setsid()` on its PTY path.
Therefore a process group containing the engine cannot be assumed to contain its transports.
`uicommon.ml` has `doTransportFailCleanup`, and GTK enables Rescan from its fatal handler.
That source reading establishes candidate interim recovery paths. It does not qualify reuse
after the November incidents or prove that the local checkout matches every published blob.
Record upstream revision, patch set, and blob checksum with the spike.

Incident qualification must establish the process that ran each sync, process continuity
between the November failures, and whether restart-required was entered or dismissed after
the first failure. A process appearing in unified logs does not by itself identify the writer
of the shared sync log or establish the coordinator's state. Do not assume independent fresh
engines or use nearby framework activity as an exact failure timestamp. Distinguish observed
process/timing evidence from the stale-connection, sleep and retained-state hypotheses.

## 3. Ownership and process layout

```text
GUI process (AppKit, session registry, admission, presentation)
  +-- engine role A (OCaml bridge, one session)
  |     +-- lifeline helper A1 (outside transport group G1)
  |           +-- transport A1 (unreaped leader of G1)
  |                 +-- in-group descendants G1
  +-- engine role B (phase 2, same ownership model)
```

Each engine is a direct child of the GUI. Each transport starts through a lifeline helper
owned by its engine. This is the first topology to qualify. The maintainer rejected signaling
forwarded numeric PIDs and accepting escaped transports as the normal cleanup policy. A
supported transport must pass the lifeline cleanup gates before this architecture ships.
A guardian/broker is a more expensive alternative if qualification shows it is necessary.

Internal roles use the installed executable and are selected before AppKit, Sparkle, handoff
routing, or ordinary Unison startup. They require an inherited private channel and a launch
handshake. Internal arguments are consumed before invoking the public profile/option parser.

### GUI responsibilities and retained runtime

The parent owns windows, session clients, CLI requests, prompt presentation, the global phase 1
session lease, mutation authorization, and persistent preferences. It stores immutable results
for display and calls an asynchronous EngineClient for session operations. Phase 2 extends the
admission authority with resource claims without changing callback ownership.

Keep the parent's existing OCaml runtime for launch parsing, profile selection, version and
directory queries, and archive-lock operations. There is no demonstrated restart-required path
from those calls today. Audit them for blocking/error behavior and execute runtime work on its
existing worker boundary. File operations can still stall even when they use no remote Lwt
connection, so responsiveness must be measured rather than inferred from their small size.

The GUI runtime must never run session init1/init2, credentials, row commands, Diff, Sync, or
connection close for isolated sessions. Enforce that boundary through the clients and tests.
Existing Finder and shell parsing continue to use Unison as the authority. No bootstrap or
maintenance child is required for phase 1. Reconsider moving these residual calls only after
an observed problem or a measured simplification justifies it.

### Engine responsibilities

Each child initializes its own runtime and owns one session and one scan generation at a time.
Its OCaml pointers, callback state, preconnection and row indices stay local. It connects,
scans, changes row actions, diffs and syncs. A qualified clean reconnect may reuse that child.
A failed or uncertain child receives disposal and cleanup, followed by a user-authorized retry
in a fresh process. A clean reconnect within a live child follows the helper-retirement barrier
in section 4 before any replacement transport starts. Children inherit the intended Unison directory explicitly.

An independent C control thread monitors GUI-channel closure and can invoke the adapted C
transport-disposal path and terminate the process without requiring OCaml progress. The thread must
be running before any session operation can spawn a transport. Its liveness descriptor is
close-on-exec for every engine-spawned process so descendants cannot mask GUI death.

The GUI's EngineProcessSupervisor owns the engine's OS child handle through exit and reaping.
The engine owns the lifelines as direct children. Its C cleanup path requests lifeline
shutdown without depending on OCaml progress. Track/retire telemetry sent to the GUI is
asynchronous diagnostic information and does not authorize numeric-PID signaling. The GUI
never waits for a main-thread acknowledgement before allowing a transport to start.

## 4. Transport supervision and failure containment

### Lifeline ownership and startup

Package a small C helper alongside cltool, with its own signing and notarized-bundle inventory
coverage. At all three GUI-engine remote transport spawn sites, execute the helper with the
transport's exact argv. Cover the PTY, non-PTY and openpty-fallback paths. Preserve prompt
stderr, terminal modes, exact argument order and required descriptors.

The engine supplies its actual PID. Before creating the transport, the helper arms kqueue
EVFILT_PROC/NOTE_EXIT for that PID and then verifies getppid still matches. A dead engine during
pre-exec setup is caught by the watch or parent check. Reading getppid alone can select launchd
after early engine death. Block the handled stop signals before installing handlers and kqueue
filters, then unblock after registration. Preserve a handled stop in durable sig_atomic_t state and
check it before publishing S/forking and at the wait boundary; registration alone must not
lose a stop already delivered to a handler. Test a stop arriving in each startup interval.

The helper stays outside the transport's process group. Its child becomes leader of a separate
group G and waits behind a setup handshake. On the PTY path the helper remains the session
leader and explicitly gives G foreground terminal ownership. Verify group setup, terminal
handoff and the release handshake before allowing transport exec. EOF or a failed handshake
must abort the waiting child. Reset the transport child's SIGTERM, SIGHUP and SIGINT
handlers to default immediately after fork, before group setup or waiting for the handshake;
it must not consume a group stop through the helper's handler before exec. The qualified
handshake must ensure child signal setup is complete before the group is released. Inject
a stop after handshake release and before exec, as well as at the other startup boundaries.
Parent-watch/group/pipe failures are checked and fail closed.
Remove helper-only environment variables from the transport and close private status/liveness
FDs before exec. Test the authenticated prompt path rather than relying on a tty-only probe.

The helper retains its direct transport child unreaped until G has no live members. That child
keeps G's numeric identity reserved for every group signal. The helper signals only its own
unreaped child and that reserved group. It never signals its own group. The engine owns the
helper until reaping. Forwarded PID signals are excluded. GUI registration/telemetry is
asynchronous and has no role in permitting spawn or authorizing cleanup.

### Stop, ordinary exit and S/U/D completion records

Use a private status pipe with bounded atomic records. Each helper has a unique nonce and emits
these records. The implementation must validate complete record delivery and parsing.

| Record | Meaning |
|---|---|
| S nonce helper-identity | A start record successfully published before any transport is forked. |
| U nonce live-or-unknown-state | Escalation has not established group termination. Repeat at a bounded rate while retaining cleanup ownership. |
| D nonce transport-wait-status | Group termination was observed, the transport's status was collected, and this helper has completed cleanup. |

A complete S write is a prerequisite to transport creation. Handle EINTR, EPIPE, malformed FDs
and other errors explicitly. A failed or incomplete S write cannot be followed by fork. A
failed D write leaves S unmatched and cleanup unknown. Ignore SIGPIPE in the helper before
any status write so a closed reader produces EPIPE rather than terminating the cleanup owner.
An EPIPE on S forbids fork. An EPIPE on U or D disables that failed reporting endpoint while
the helper continues group cleanup and eventually preserves the transport's status. Losing a
reader never authorizes the helper to abandon its group. Save the SIGPIPE disposition the
helper inherited before ignoring it, and restore that inherited disposition in the transport
child just before exec. This preserves an engine's ignored disposition as well as the default.
Records fit the qualified PIPE_BUF atomic bound. A helper cannot discard failed status writes and continue as if they succeeded.

Engine exit, a stop signal, or ordinary transport exit starts the same group cleanup. Send
SIGTERM to G, wait a bounded grace interval, then enter the KILL phase if needed. While live
members remain, re-send SIGKILL to the reserved G on each bounded observation round, covering
members forked during escalation. Unknown membership retains the block and the qualified
retry policy. Retain the unreaped leader until observation establishes completion, so every
repeated group signal still targets the reserved identity. The helper remains
outside G throughout. While members remain or enumeration is uncertain, retain the unreaped
leader, emit U, and continue observing. Preserve ordinary transport exit code and signal even
when descendants require escalation.

Group completion means a qualified membership query finds no live members. Zombies are exited
and are counted separately. Handle enumeration errors, truncation, buffer growth and per-process
lookup failures conservatively. A fixed buffer that can omit surviving members cannot establish
completion. Check complete proc_pidinfo results and distinguish a disappeared process from an
unreadable one. The validity of this observation under fork/exit churn is a qualification gate.

After observed group termination, stop issuing group signals, reap the direct transport once,
write D with its actual status, and exit with equivalent status. No group signal is allowed
after reaping frees the group's reserved identity. An unexpected helper crash before D leaves
its S unresolved even if cleanup might already have happened.

The GUI considers local cleanup verified only when the engine has exited and been reaped,
the status pipe has reached EOF with no partial/unparseable record, and every valid S has one
matching D. U, a missing D, invalid/duplicate state transitions or a broken stream retains the
cleanup block. A healthy engine can have retired helpers, but the engine session's final
cleanup decision waits for its own exit as well. Ordinary archive admission remains a separate
requirement before another writer is admitted.

EOF alone means writer closure. S/D adds the helper's qualified observation of group termination.
The no-S case is safe only because all covered spawn paths forbid transport creation before a
successful S. The GUI must know status-channel setup succeeded before authorizing engine work.

Close GUI writer duplicates. The engine retains a writer while further helper spawns are
possible, closes it on disposal/exit, and never lets the actual transport inherit it. Each
helper keeps its writer through cleanup. Keep draining the pipe on a dedicated reader so GUI
modals and blocked OCaml work cannot fill it. Pending status writes and malformed streams have
explicit failure behavior. The GUI sets O_NONBLOCK on the status writer when it creates the
channel, before passing copies to the engine or helpers. They share that open-file description;
a helper must not silently change the flags for all writers. A full pipe must not block cleanup
indefinitely. Use a qualified bounded/nonblocking reporting path. Failure to publish S prevents launch, while U/D reporting
failure preserves cleanup ownership and an unknown reporting outcome. Test the reader closing
during S, U and D, and test a live reader that stops draining. Test inherited-writer leaks, premature closure and backpressure.

### Actual transport exit and reconnect barriers

Helper liveness and transport liveness are separate facts. The helper may remain alive while
cleaning up descendants after SSH exits. The existing unison_bridge_transport_child_terminated
check and AppDelegate's credential loop use tracked-child termination to reject leftover SSH
errors as prompts (#35). Watching the helper PID would regress that behavior.

Add a correlated per-helper lifecycle channel to the engine's independent C reader. On first
observing transport exit without reaping the leader, the helper publishes TransportExited with
nonce, transport identity and available exit/signal evidence before entering group cleanup.
Publish CleanupComplete only after the same observed-empty/reap condition that authorizes D.
Neither notification may block cleanup indefinitely. Apply the SIGPIPE/error rules to this
channel too. Transport status can be deferred if only exit, rather than its final wait status,
is initially available. A missing/broken evidence channel means unknown, never evidence that
SSH is still waiting for a password or that cleanup finished.

Update the #35 consumer to consult actual TransportExited evidence for the current connection.
Attach the engine's current correlated transport-evidence state and ordering information to
each prompt when it is sent. Prompt and TransportExited notifications can arrive in either order;
absence of an exit notification is unknown, not positive evidence of a live transport. Do not
present ambiguous leftover output as a credential request on that basis. The spike must qualify
a bounded refresh/defer decision for unknown evidence while keeping genuine prompts usable.
Keep fatal-text classification as a supplementary check. Positive exit evidence suppresses
stale credential output immediately while helper cleanup continues. Terminal-evidence channel
failure produces connection failure/cleanup rather than a new password prompt. Qualify login-grace timeout and broken pipe with a lingering descendant,
plus normal password retry, successful authentication and Cancel controls. Record prompt/exit
arrival order in the login-grace case and force both orders in integration tests.

A reused live engine must retire its previous connection completely before creating another
transport. The GUI waits for matching D records for earlier helpers, and the engine checks its
correlated CleanupComplete state at the spawn boundary. A helper that is still active, has U,
or has an unmatched/failed completion keeps reconnect waiting or cleanup-blocked. Final engine
EOF is not required for this per-connection barrier. A TransportExited event alone never
satisfies it. Test a reconnect requested during grace, KILL and U, and late lifecycle messages
from an old helper. Only a new connection after the old cleanup barrier may proceed.

### Engine retirement and shutdown

Patch 0004's retire, track-while-closing and reap paths must request helper cleanup with SIGTERM.
They must never escalate to SIGKILL of a helper that owns cleanup. Preserve signal-before-remove
under the registry mutex, then waitpid outside it. Registry removal prevents later signals to
a helper whose PID has already been reaped. The helper's parent watch remains active after
registry removal and independently detects engine death.

Waiting for a stuck helper can block inside the disposable engine. It must not block the GUI
or hold the registry mutex. If the engine's disposal deadline expires, the GUI may SIGKILL its
own unreaped engine child. Helpers continue cleanup through the parent watch and U records.
The session stays cleanup-blocked until the verified S/D rule passes. Test track racing shutdown,
all retire branches, waiting outside the mutex, engine force-stop and no-helper cases.

### Failure sequence and supported limits

1. Mark the engine disposing and reject new session work.
2. For Sync Stop, attempt cooperative abort and report its terminal result if it completes.
3. On disposal, request helper cleanup through the engine's independent C thread. If the engine
   dies, each helper's parent watch triggers the same cleanup without GUI registration.
4. Observe the engine through the GUI's direct-child handle and reap it once. Drain and
   validate the S/U/D status stream through EOF under the completion rule above.
5. Retain the lease while any covered transport cleanup or archive admission is unresolved.

GUI death closes the engine control channel, and the C thread disposes that engine. Simultaneous
GUI/engine death is covered by helper watches once qualified. The helper itself being externally
SIGKILLed, deliberately detached descendants such as a configured ControlPersist master, and
remote work persisting after disconnect require explicit handling or a documented supported
configuration boundary. They cannot be silently classified as successful cleanup.

Inventory custom sshcmd, ProxyCommand, diff, merge and detached tools. Each engine-owned tool
needs its appropriate lifetime owner. A detached editor is a distinct user action. Avoid a
promise that the SSH helper contains arbitrary scripts that deliberately escape its group.
No process-name, hostname or broad command-line kill is authorized.

### Audit-token option outside phase 1

The phase 1 design has no direct orphan-signaling requirement. The GUI signals its owned
engine, the engine requests cleanup from its owned helpers, and helpers signal a reserved
transport group. Keep proc_signal_with_audittoken as an investigative option if a later
requirement cannot use those relationships. No numeric-PID fallback is allowed.

The supplied experiments report stale/wrong-version rejection, orphan signaling, post-exec
token capture and ad-hoc hardened-runtime behavior. Developer ID/notarized builds, macOS 15,
API availability and its lack of ordinary behavioral documentation remain unqualified. These
are requirements for adopting that option, rather than phase 1 shipping gates.

### Prototype evidence and qualification status

The original prototype failed the normal-exit/stubborn-descendant case independently run by
the author. Its EOF rule and self-killing group topology are superseded by v2 above.

The reviewer reports three unprivileged v2 runs on Heracles/macOS 27.2.1 covering ordinary and
signal exit status, engine death before registration, PTY foreground group setup, stubborn
descendants and S/D/EOF verification. The reviewer also reports that external helper SIGKILL
leaves an unmatched S, as required for unknown cleanup. Those exact v2 runs were not independently
repeated by this author; later v3 checks are recorded separately with the spike evidence. Source inspection found unchecked writes/setup and fixed-buffer
membership observation in the prototype. Those are implementation/qualification tasks, not
properties established by the reported successful cases.

Experimental sources are preserved in the author's workspace under
engine-process-evidence/lifeline and engine-process-evidence/lifeline-v2, outside the repository.
A later reviewer probe reproduced SIGPIPE termination after closing the status reader. Source
inspection also found that the current terminal-evidence API would watch the helper, and v2
issues group SIGKILL only once. These findings add qualification cases beyond the original v2
runs. The author verified the source paths. Later v3 closed-reader checks are recorded separately with the spike evidence.
Transfer reviewed sources/harnesses into a development branch before relying on them. Fix the
startup signal-registration race, SIGPIPE/reporting failure behavior, actual-transport exit
notifications, repeated KILL observation, reconnect barrier, setup error handling and complete
group observation before treating v2 as the spike implementation.

The corrected reviewer v3 sources and later standalone checks belong to the spike evidence,
not this design's qualification claims. Successful cases do not establish integrated engine,
authenticated-SSH, signed-build or supported-platform behavior. Keep exact source identities,
unsuccessful attempts and remaining gates with each spike report.

Outstanding gates include signal registration, start/completion write failures, membership
truncation/errors/churn, group/terminal handshake failures, actual patch 0004 and #35 integration, closed/non-draining status readers, same-engine reconnect,
status preservation, private FD/environment cleanup, real password-authenticated SSH,
Developer ID/hardened builds and macOS 15. Preserve exact source/toolchain/artifact identity.

### Alternatives if lifeline qualification fails

- **Guardian with transport broker.** A runtime-free owner can spawn/reap transports directly,
  pass PTY descriptors, and substitute opaque handles for OCaml waitpid assumptions. This
  requires invasive Terminal/Remote adapters and has a separate size estimate in section 11.
- **Embedded XPC service.** Evaluate process lifetime and TCC under the app's signed bundle.
  Its attribution and descendant cleanup still require tests on supported macOS releases.
- **User-domain launchd agent.** A separate option with unverified TCC and lifecycle behavior.
  It is excluded from the default topology until access to the actual protected paths passes.
  The reported earlier system-domain TCC denial is a warning to investigate, not evidence
  about user-domain behavior. A system-domain daemon is outside this proposal.

### Provisional deadline hypotheses

| Action | Initial value to evaluate after baseline capture |
|---|---|
| Engine startup handshake | 5 seconds, distinct from connection timeout |
| Scan Stop to engine exit and observed transport cleanup | 3 seconds on a responsive OS |
| Cooperative sync abort grace | 10 seconds, then offer Force Stop. Completion still wins. |
| Forced cleanup | 3 seconds from the request on a responsive OS |
| Control acknowledgement | 2 seconds for dispatch/liveness, excluding human response |

Deadlines exclude machine suspension and uninterruptible OS/filesystem waits. Define the
suspend/resume clock policy during qualification. A control heartbeat is distinct from engine
operation progress. All deadlines and performance targets remain provisional until steps A/B
record the current app and spike measurements.

### When cleanup cannot finish

Show “Cleanup has not finished” in the affected session, identify any known remaining local
process and uncertain remote work, and disable retry/Sync against those resources. Offer
Retry Cleanup, Copy Diagnostics, and Close Window. Closing the window leaves its cleanup record
visible in the picker. Quit remains available with a warning that unresolved work may remain.

At phase 1's capacity of one, a verified-live engine that cannot be terminated occupies the
slot and prevents another session. State that limitation directly. Quitting and reopening the
GUI does not by itself make that process or its locks safe. Persist a small private cleanup
record containing instance identity, diagnostic process birth data and unresolved domains so
startup can surface the condition. The record is evidence to inspect, not authority to signal
a PID or delete a lock. Distinguish exited-but-unreaped from verified-live or unknown processes.

If diagnostics establish that no local process remains, reassess ordinary archive admission.
Uncertain stale locks use the explicit recovery path. If OS-level work cannot be terminated,
the user may need to end the responsible remote process or recover the machine before retrying.
Avoid another generic restart notice that implies restarting the GUI resolves this condition.
Phase 2 may continue proven-unrelated work when the retained uncertainty has a bounded domain.

### Remote work after local termination

Local engine or SSH exit does not establish remote server exit. A partition can leave remote
work running. Keep affected domains uncertain until a new connection establishes Unison's
normal locking/recovery preconditions. If that fails, explain the block and preserve recovery
evidence. Qualify disconnect/unwind behavior with remote observation in isolated tests.

## 5. Launch, options and the phase 2 preparation boundary

### Phase 1

Retain the existing Finder/shell routing and parent-side Unison argument parser. Headless
server/text modes retain stdout and argument semantics. The parent passes the selected profile,
explicit Unison directory and ordered persistent session vector to the child's Connect command.
The child calls the current argument setter and init1. Admission runs immediately before that
command, using the existing conservative staging gate and refreshed staging evidence.

The parent-side runtime never connects on behalf of a GUI session. Compare quoted and repeated
options, unknown options, missing profiles, two roots and graphical launches with no WindowServer
against the current behavior. TCC and update installation need qualification for the actual
child-launch mechanism even though the executable stays in the existing bundle.

Preserve persistent session argv exactly. A recovery OpenRequest separately owns
firstLoadArgs = ["-ignorearchives=true"], appended after persistent args for that first load.
Replacement/cancellation destroys the request's one-shot args. A reconnect receives the
original vector, including an explicit user -ignorearchives=false.

The existing gate's ignorance of identity-changing options (#238) remains a separate fix and
qualification item. Moving sessions into children does not resolve it. Phase 1 must state its
actual supported admission behavior and any remaining uncertainty at release review.

### Phase 2 requirement, specified now and implemented with concurrency

Concurrent admission needs effective claims before scan or archive side effects. Add a
preparation boundary around the engine's parser that resolves exact profile lookup, includes,
profile preferences and ordered session overrides before connection/scan work. The current
init1 mixes preparation with setup. Determine its actual archive side effects before choosing
the boundary. The vendored preparation split is phase 2 work, rather than a prerequisite for
phase 1 recovery.

Prepare returns effective scope and resources and retains those parsed preferences. Connect
uses that prepared state. If any implementation reloads files, it repeats preparation and
admission before side effects. Report include identities and content changes to support queue
promotion/revalidation. A profile edit cannot change a reservation silently.

Phase 1 implements only the messages it uses and holds a global lease. Both peers ship from
the same bundle. Add/version preparation and claim messages with phase 2, retaining the
per-session identity and lifecycle contracts specified here.

## 6. Protocol and data transfer

### Transport and trust

Use inherited Unix-domain socket pairs with a length-prefixed, versioned message protocol.
Separate control/prompt traffic from bulk snapshots so a full results queue cannot indefinitely
prevent cancellation. The child control reader operates independently of OCaml workers. No discoverable engine socket
or shell command string is used. Only the app's existing CLI handoff endpoint is public.

The first exchange checks protocol version, parent launch nonce, role, app build, and blob
identity. All peers are launched from the same installed bundle path. An incompatible child
fails startup visibly. An app update waits until engines have exited and parent-side archive maintenance has finished.
Handshake identity checks prevent accidental cross-wiring. The security boundary remains the
inherited descriptors and process ownership. They are not a sandbox against arbitrary code
running as the user.

Proposed encoding is UTF-8 JSON with typed Codable payloads for the first spike. Use explicit
integer widths and finite numeric validation. Preserve filesystem bytes using an explicit byte
field when needed. Keep lossy display strings compatible with today's String(cString:) path
rendering. Row actions use engine/generation/row IDs and must continue to work for a non-UTF-8
remote name. Preserve raw bytes through any operation that must send a path back. If a specific
argument cannot be represented safely, refuse that operation with an explanation rather than
failing the entire session or changing its target. A 4-byte network-order length precedes each frame.
Initial limits are 1 MiB per frame, 4 MiB queued control data and 8 MiB queued bulk data per
session. Snapshot size is streamed and governed by a measured memory budget, not by that
per-frame cap. Oversize or malformed traffic fails the affected session.

### Message identity

Every message identifies protocol version, session UUID, engine incarnation UUID, operation ID,
and per-channel sequence number. Commands expecting replies also have a request ID. Prompt
requests have their own ID and parent operation. A row reference is `(engine, scan generation,
row ID)` and cannot be sent to another generation.

Each operation accepts one terminal result. Duplicate terminals are ignored and diagnosed.
Unknown or obsolete prompt answers are rejected. Channel EOF consumes outstanding operations
as failed once. No pending command is replayed into a new child automatically. This includes
mutating row actions and Sync, whose effects may already have occurred before the reply was lost.

### Message families

| Commands | Events/replies |
|---|---|
| Connect(profile reference, persistent argv, first-load argv, global admission token) in phase 1 | Prompt request, connect complete, connect failure |
| Prepare and ConnectPrepared in phase 2 | Effective configuration/resources, reservation validation, or preparation failure |
| Scan / rescan | Snapshot begin, row chunks, snapshot end, scan failure |
| Set direction, skip, merge, force, revert | Authoritative updated row facts or refused command |
| Ignore | Affected rows and authoritative result, including partial failure |
| Diff | Capability, streamed output, completion or failure |
| Sync | Progress updates, final per-row snapshot and committed completion, or failure |
| Cooperative abort, dispose engine | Acknowledgement and later terminal/cleanup result |
| Warning/fatal answer | Exactly one correlated response and lifecycle outcome |
| Transport lifecycle and disposal control | Registration/retirement identity, cleanup result, observed/unknown exit evidence |

Synchronous C bridge getters become worker-local calls followed by asynchronous replies. The
main thread never blocks awaiting an engine. Retain engine-computed `changedFromDefault`, diff
eligibility, and partial mutation facts instead of reconstructing them from display strings.

Commands for one engine are serialized against that engine's operation state. A row mutation
reply must be acknowledged before Sync can start using it. If a mutation reply is lost, disable
Sync and refresh the authoritative snapshot or dispose the engine. Do not guess which direction
was applied. A terminal state update precedes any UI action becoming available.

A snapshot has generation, row count and ordered chunk numbers. Build it off the main thread,
then atomically publish it after the end marker and validation. A dropped chunk or child exit
leaves the prior snapshot as historical display, with actions disabled. Prefer transferring
ownership of buffers to keeping multiple full copies. Progress is coalesced by row and rate
limited. Final results and terminal events are never discarded to relieve pressure.

Operations and prompts have separate deadlines. A human password or warning answer is not
limited by the normal acknowledgement deadline. Closing a session with a prompt cancels it and
begins disposal. On failure or EOF, the worker's independent control loop wakes blocking C
requests with cancellation/fatal termination. If the runtime cannot return, the independent
control thread or parent ends the engine under the cleanup policy in section 4. AppKit sheets
use asynchronous completion so one sheet cannot starve another session's handoff or progress
delivery. Queue application-wide warnings centrally and cancel queued
presentation when its session/engine dies.

### Crash-report classification and fault injection

The current AppDelegate.collectCrashReports matches unison-ui-mac-*.ips, and
CrashReportScanner selects by modification time. An engine role uses the same executable and
can produce a matching report. Classify GUI crashes and unexpected engine failures separately.
A handled engine failure may still be a reportable defect. Offer “Report Engine Failure” with
profile/session context while retaining the recovery offer, instead of implying that the GUI
crashed. Keep per-report deduplication and separate GUI/engine handling so one marker cannot
hide an unrelated report. Missing identity metadata remains explicitly unclassified.

Correlate crash-report metadata with recorded role, PID, process start and incarnation, build,
and launch/exit timestamps. parentProc is a candidate discriminator to test, not a sufficient
rule by itself. Verify report arrival delay and GUI startup with engine reports pending.

Use SIGKILL for death tests that need only abrupt exit. Real SIGSEGV/SIGABRT tests remain
necessary for crash classification and are run in an isolated account/fixture with known role
identities. Prevent expected test reports from triggering later hosted-test startup prompts
without disabling real production reporting or altering the user's real crash marker. Preserve
reports as test evidence and include scanner regression coverage for each role.

## 7. Session state and user recovery

Use one reducer per session, with an app-level registry owning their clients and windows.
A single serial admission authority changes reservations and starts reducer effects on the
main actor. Process I/O, parsing, filesystem work and process cleanup run off the main thread.

| State | Accepted actions and exit |
|---|---|
| Waiting | Cancel request or acquire the phase 1 global lease / phase 2 resource reservation. No active engine row commands. |
| Preparing (phase 2) | Cancel, receive effective resources, then pass final admission and connect, or remain blocked. |
| Connecting | Answer credentials, cancel, or fail. Successful connect starts scan. |
| Scanning | Show progress, Stop, or return to picker and dispose the scan engine. Publish one complete snapshot on success. |
| Ready | Change directions, ignore, diff, Sync when connection valid, rescan, or end session. |
| Diffing | Return to Ready on success/failure when engine remains qualified. An uncertain engine goes through disposal. |
| Syncing | Cooperative Stop, keep running, or close into background according to recorded intent. |
| Disposing | Reject new engine commands and wait for cleanup. Reservations remain held. |
| Failed | Retain historical results, disable engine-dependent actions, offer rescan after cleanup and staging admission permit it. |
| Blocked | Show the admission/recovery cause, then retry admission or close. Historical results remain visible when present. |
| Ended | Window may be closed. No engine, process ownership, reservation, or pending request remains. |

Connection state stays distinct from phase. Local-only sessions and disconnected remote sessions
have different Sync eligibility. A remote Sync requires a current connection and a valid scan.
A closed connection can reconnect/rescan after revalidation. A new engine always scans before
Sync becomes available.

### Presentation contract proposed for approval

After failure, retain the last complete snapshot with a visible historical-results label.
Retain acknowledged per-row outcomes from a partial sync. Rows without confirmed terminal
outcomes show that their outcome is unknown. The app never reports an entire interrupted sync
as completed based on the absence of an error message.

Disable direction changes, ignore, Diff and Sync against a dead engine. Preserve the old row
decisions for inspection, but do not replay them automatically into a fresh scan. Changed files
can make an old decision unsafe. A successful new scan supplies new defaults. Preserve selection
and expanded folders by relative path when still present, plus immutable session options.

Offer Rescan and Close after cleanup. A fatal dialog may additionally offer Retry Ignoring
Archives or validated orphan recovery under existing authorization rules. Closing the window
or abandoning its session invalidates a pending retry choice. No late fatal can resurrect it.

Once the scan-termination and archive-recovery gates pass, returning to the picker during a
scan disposes that engine, as does Stop Scan. Show cleanup progress and queue the next request
until its lease can be released. This removes the abandon-and-drain delay that in-process
safety required. Any exception that keeps a scan draining needs an explicit product decision
and an explanation in the UI. During sync, Keep Window Open keeps it
visible, Continue in Background retains its engine, and Stop Syncing and Close waits for the
abort or explicit force-stop result. Each background session remains accessible from the picker
in phase 2.

## 8. Shared admission and overlap model

### Shared session model, staged reservation implementation

An `OpenRequest` has an immutable request ID, origin, profile reference, persistent argv,
first-load argv, acceptance deadline and cancellation state. The phase 1 lease or phase 2 resource reservation names the session and incarnation.
A session cannot begin connection/scan work without that phase's admission token.

Phase 1 uses a global session capacity of one. It still stores a collection of session records,
per-session clients, and a queue keyed by request ID. Phase 2 implements resource claims and
supports a collection of concurrent sessions. Two sessions are the first qualification scenario.
No product cap of two is selected. Set any default limit from aggregate memory, CPU and I/O
measurements. Callback and prompt ownership always remain per session.

Phase 2 resource claims contain both replica locations and archive identities, plus shared writable
backup/staging destinations and side-effecting hooks when configured. Shared log output needs
an append-safety qualification or a serialized writer. Arbitrary user commands whose effects
cannot be bounded make concurrency uncertain. Profile options can create conflicts outside
the two roots, so disjoint replicas alone are insufficient.

Resource claims contain explicit uncertainty when these effects cannot be resolved. They are held throughout
Connecting, Scanning, Ready, Diffing, Syncing and Disposing. Ready has an engine and live row
state, so releasing its claim merely because no bytes are moving would permit stale decisions
to act after a conflicting session changed its files. To allow another conflicting session,
the user ends the first engine session. Its old results can remain visible as historical data.

### Conflict decisions

Use the outcomes proven disjoint, overlapping, and unknown. Only proven disjoint claims can
run concurrently. Unknown claims reserve a conservative domain and report the reason they are
waiting. No checkbox bypasses an unresolved conflict.

| Resource | Rule |
|---|---|
| Local replica | Compare canonical existing root identity and ancestor relationships by path components, respecting the actual volume's case behavior. Same object or ancestor/descendant means conflict. |
| Missing local root | Canonicalize the deepest existing ancestor and retain the unresolved suffix. If that cannot prove disjointness, classify unknown. |
| Local aliases | Resolve symlinks and effective engine root aliases. Volume identity and file identity help detect alternate mounts. Unsupported alias/hard-link cases remain unknown. |
| Remote replica | Require qualified endpoint identity and canonical remote path evidence. SSH config names, ports, DNS names or user strings alone do not prove distinct hosts or storage. |
| Socket root | Treat as unknown remote identity until the server's identity and canonical root can be qualified. |
| Archive | Equal archive-family identities conflict even if replica claims appear disjoint. Apply effective identity-changing session options. |
| Session scope | Derive effective selected subtrees from profile path preferences plus ordered session -path arguments. Narrow claims only for patterns whose traversal and write scope are qualified. Unknown patterns/follow behavior fall back to whole roots. Ignore patterns alone do not prove disjointness. |

Preparation can identify local roots without connecting. A remote identity that requires a
connection first takes a broad unknown-remote reservation. Other remote candidates wait while
that connection resolves identity. Refine the reservation atomically only after qualified facts
are available, and before any replica scan or archive write. The engine must stop at that
boundary. If existing init1 performs such writes earlier, splitting that boundary is required.

Remote concurrency is a qualification decision. Existing Unison canonical-root exchange may
supply useful identity, but must be tested against host aliases, symlinks, alternate mounts and
user-dependent paths. Until evidence supports refinement, unknown remote claims serialize.
Shared-log append behavior, effective path scope and canonical remote identity are phase 2
critical-path work. Qualify concurrent Pictures and FlightSim on Demeter, and Home with Pictures
when Home's effective selected paths exclude Pictures. All four Sync-* profiles set logfile to the same Unison-Sync.log, and Home's configured path
list excludes Pictures. These are acceptance-fixture inputs. Use disposable equivalents for
concurrent write tests and recheck configuration if the profiles change.

An initial phase 2 result that admits only disjoint local profiles does not meet the intended
real-profile concurrency outcome. Remote-host aliases, remote symlink paths and the shared log
must be measured before claiming that outcome. If they cannot qualify, return the reduced
benefit and cost to the maintainer for a scope decision.

Directory identity can change after preparation through an external rename, symlink swap or
mount change. Repeat identity checks before scan and Sync, and invalidate rows/admission if
claims changed. This narrows races but cannot provide filesystem isolation against arbitrary
external mutation. The concurrency guarantee requires stable topology during an admitted
operation. Unknown or changing topology produces a refusal rather than a proof of disjointness.

### Scope and log qualification

Profile path entries and command-line -path arguments both contribute to the effective engine
scope. Read the applied result through preparation rather than independently merging raw
strings in Swift. Qualify literal subtrees first, then any supported patterns. Include root
metadata, deletions, followed links, backups and hooks when determining the complete write set.
Distinct selected paths still conflict if they share an archive family or another write domain.

For the shared Unison-Sync.log, inspect the engine's actual open/write/flush behavior and run
concurrent tagged log fixtures. Accept the shared file only if writes are safely appended with
the required record integrity. If it fails, choose an explicit serialized logging adapter or
per-session log strategy with a compatibility decision. A permanently global log conflict would
defeat the real-profile concurrency goal and must be reported as such.

### Queue policy and editing

Maintain FIFO admission among conflicting requests. Later independent requests may proceed if
capacity is available and they cannot prolong an earlier request's resource conflict. A request
that is accepted remains identifiable and visible until started, refused or explicitly cancelled.
A picker selection cannot silently replace an accepted CLI request.

Reprepare queued profiles and includes at promotion, recheck deadlines and staging state, then
atomically reserve the newly computed claims. A changed target can become refused or remain
waiting with an explanation. Never retain an old claim and start a new configuration.

Editing a profile affects future preparation. Before rescan/reconnect or Sync, changed identity
causes readmission and a new scan as necessary. Same-name profile sessions remain distinct IDs.
An ordinary duplicate open of the same profile/options focuses its existing session in phase 2.
An explicit request with differing options is independently evaluated and may conflict.

## 9. Archive maintenance and crash recovery

Process isolation removes unsafe runtime reuse. It does not make archive files transactional
by itself. Preserve `ArchiveMutationTransaction`, its durable manifest states and lock identity
checks. A killed sync can leave engine-owned temporary/lock state that is different from the
app's staging manifests. The recovery UI must distinguish them.

The first concurrent implementation gives archive maintenance a global exclusive lease for the
relevant Unison directory. A maintenance request blocks new admission. Existing sessions must
finish and dispose, or the user must explicitly stop/close them. It never silently aborts other
syncs. This policy intentionally includes ready sessions with live engines. Later work can
qualify family-specific exclusion, using the same reservation authority.

With the exclusive lease held, use the parent's existing archive-lock bridge and Swift durable
transaction. Revalidate the requested operation under lock and retain the existing ownership,
rollback and Trash rules. A GUI crash mid-transaction leaves its manifest for explicit recovery.
Parent runtime isolation is a later alternative if qualification shows the retained path can
hang or compromise GUI recovery. The design does not require a new maintenance process.

Refresh abandoned-staging evidence at launch and admission. A scan failure or undecodable
manifest is an uncertain state that blocks affected work with an actionable message. Address
#217/#218 while introducing this boundary. Effective session options and remote identities must
participate in archive attribution (#238). Existing conservative remote blocking remains until
actual family identity is proven.

Never remove a stale-looking lock solely because this child died, its PID vanished, or its
name matches a profile. The file may belong to another process or have been replaced. Safe
cleanup requires acquisition/ownership evidence accepted by the existing recovery protocol or
Unison's explicit stale-lock procedure. If that cannot be automated safely, show the existing
manual recovery path and keep the session blocked. A fresh process is useful recovery, not
permission to bypass locks.

Implement under-lock orphan revalidation (#224) and originating session/operation authority
(#225) in the new recovery route. Those fixes can land independently before the process work.
The parent records diagnostics and outcomes and owns the maintenance lock lifetime through
its existing bridge.

## 10. Phase 2 UI, CLI, prompts and quitting

The picker shows active, background, waiting, blocked and failed sessions. Each row can focus
its window. Windows, menus, toolbar actions, status callbacks and diffs route through an
explicit session ID. AppDelegate becomes the composition root. It does not infer a target
from a single `currentSession` or `lastAttemptedProfile` value.

A disjoint graphical CLI request opens alongside existing sessions. An overlapping request
gets a message naming the conflict and an offer to wait or cancel. A sync-exit decision names
the exact conflicting session. If several sessions conflict, the first version offers waiting
or cancellation and directs the user to the named windows. It does not apply a single Stop
choice ambiguously to several sessions.

Phase 1 preserves the existing three-way sync-exit contract and the one pending CLI request
limit. Phase 2 permits multiple pending requests with independent IDs and bounded capacity.
The public handoff protocol needs version negotiation for that change. Started, accepted and
waiting, refused, and outcome unconfirmed retain their current meanings. Started means the
request reached its own opening state, not that its scan or future sync succeeded. Acceptance
and final admission are separate, and delayed refusals remain visible in the app.

The GUI listener remains app-global. Headless roles never elect or serve as a GUI primary.
Resolve the survivor/listener ownership gap in #240 before enabling concurrent GUI sessions.
A second installed GUI instance must not become a second scheduler over the same directory.
This control is separate from archive locks and does not prohibit ordinary text-mode Unison.

Present credential sheets per session with the profile named. A reply belongs only to its
prompt ID and is never broadcast. Phase 1 retains SSH-prompt handoff refusal. Phase 2 can admit
an unrelated session while another credential sheet is open after the UI no longer uses a
global blocking modal. Contradictory warnings or maintenance confirmations are queued centrally.
Passwords travel only in private messages, are excluded from logs and manifests, and are
released from application-owned buffers promptly. The engine's own buffer handling remains
subject to upstream constraints.

Quit presents one summary naming running syncs, scans and waiting requests. The user can cancel
Quit or authorize shutdown of the displayed work. After confirmation, revalidate the listed
session IDs, cancel queued requests, cooperatively abort active syncs, and dispose engines.
If the set changed while the confirmation was open, update the decision before acting on new
work. Unresponsive syncs get the force-stop choice. Engine control-thread cleanup handles GUI death
under the qualified limits in section 4. Sparkle installation waits for engines to end and
parent-side maintenance to finish before replacing the
bundle, and the application-level handoff owner stops accepting requests during that interval.

## 11. Migration, implementation sequence and size budget

The following are engineering estimates for one implementer, including focused tests and
review corrections. They are planning ranges, not delivery promises. Attended qualification,
external review, access to supported machines, and daily-use bake time add elapsed time.
Estimates must be replaced after the first spike establishes the actual bridge work.

| Step | Deliverable and review boundary | Initial effort range |
|---|---|---|
| A | Qualify November failures and a narrow interim remedy. Record log/pmset correlation, process continuity and restart-state behavior, versions, cleanup evidence, and current Home-profile plus synthetic-list performance. | 2–4 engineering days |
| A1 (conditional) | Implement and qualify the interim remedy selected by A, then release and record it independently if authorized. Skip if no remedy qualifies. | Budget after A sizes the chosen fix. A narrow qualified fix provisionally needs 2–5 additional days. |
| B | Signed engine/lifeline launch, TCC, parent watches, retire/shutdown adaptation, completion proof and failure injection. Measure normal/stubborn descendants, engine/GUI/helper death, PTY prompts and packaging. | 6–12 days |
| C | Versioned codec and fake worker, snapshots, backpressure, operation/prompt identities and cancellation. Implement current messages only. | 3–6 days |
| D | Audit and retain parent parsing/metadata/archive calls. Add role routing and persistent/one-shot argv parity controls. No prepare/connect split here. | 1–3 days |
| E | Real EngineClient for connect/scan/rows/diff/sync, per-session reducer and registry with one global lease. | 6–12 days |
| F | Failure recovery, leave-scan disposal, cooperative/forced Sync Stop, cleanup-blocked presentation and existing maintenance exclusion. | 4–8 days |
| G | Signed phase 1 qualification, integration regressions, production session-path cutover and bake. | 4–8 days plus bake |
| H1 | Effective preparation/connect split and claims. Qualify shared log, path scope, remote identity, aliases and real-profile benefit before raising capacity. | 7–15 days |
| H2 | Concurrent scheduler, resource conflicts, per-window CLI/prompt/quit routing and picker status. | 5–10 days |
| I | Signed phase 2 isolation, overlap, remote failure and concurrent performance qualification, then bake. | 4–8 days plus bake |

Phase 1 totals approximately 26–53 engineering days on these assumptions, excluding conditional
A1. Phase 2 adds 16–33. A1's estimate is a planning allowance until A sizes the actual option.
The v2 completion protocol is specified but its error paths and platform behavior still need
qualification. Re-estimate B after that spike.
The combined work remains a multi-month project for one implementer with substantial uncertainty.

A guardian plus transport-broker alternative could add roughly 10–20 days for PTY/spawn/wait
adapters and process qualification, with vendor-level uncertainty. Removing the parent runtime
could add another 4–8 days for bootstrap/maintenance routing and compatibility checks. These
alternatives need evidence and a new estimate before entering scope.

The overlap investigation starts during A/B because it checks that phase 1's session and
ownership contracts can support phase 2. Preparation messages and the resource scheduler are
implemented with phase 2. Phase 1 uses its global lease without unused reserved fields.

Retain pure reducer/model tests where their contracts persist. Replace singleton session
callback seams with injected EngineClient and supervisor clients. Fake clients never drive the
shared hosted-test engine. Use isolated-process integration tests for the real bridge and
disposable directories for kill/crash experiments. Termination targets come from test-owned
handles, never an executable-name search.

Developer builds can select the legacy session path at launch for comparisons. Qualify the
isolated production path before cutover. A live runtime toggle would double the session and
recovery contracts and is not proposed. Existing profile/archive formats allow release rollback
subject to explicit cleanup of owned processes and interrupted transactions.

## 12. Qualification and acceptance matrix

| Area | Required evidence before its phase ships |
|---|---|
| Launch and packaging | macOS 15 and current macOS, signed/notarized installed app, Finder and cltool paths, same-bundle role validation, missing/mismatched child failure, retained parent parser parity and Sparkle replacement waits. |
| TCC | Photos library and FDA paths, existing and fresh grants, denial, signed launch topology and prompt attribution recorded. Test intended user paths with permission and disposable payloads. |
| Process ownership | Kill engine during spawn/auth/scan/sync/close and kill GUI/engine together. Exercise pre-watch/pre-fork/post-fork intervals, startup signal races, failed S/D writes, group/PTY handshake errors, membership truncation/errors/churn and repeated KILL, stubborn descendants, helper SIGKILL, delayed retire, closed S/U/D readers, non-draining readers, same-engine reconnect barriers, inherited FDs/environment/signal dispositions and tool escapes. Require engine reaping plus complete S/D matching plus EOF. Verify preserved transport status and no unrelated signal. |
| Protocol | Split/coalesced/truncated/oversize frames, malformed values, sequence violations, late/duplicate terminal and prompt replies, EOF in each phase, full bulk queue with timely cancellation. |
| Prompt terminal evidence | #35 login-grace timeout/broken pipe with SSH exited and a lingering descendant. Keep actual transport exit distinct from helper liveness. Cover broken lifecycle channels, wrong-password retry, authentication and Cancel. |
| Profile and argv | Includes, lookup collision, quoted/repeated options, persistent -path, explicit ignorearchives false/true, request-owned override through queue replacement/cancel and later real remote reconnect. |
| Rows and tools | Direction/force/revert/ignore partial failures, changedFromDefault, stale-generation rejection, local/remote Diff and merge completion/cancel, plus non-UTF-8 remote names that display lossily but retain working row actions. |
| Failure presentation | Connect, scan, diff, sync and close failure, retained results, unknown partial outcomes, abandoned-window late fatal, user-authorized rescan, engine-independent GUI remains responsive. |
| Archives | Kill at deterministic acquisition/staging/rollback/commit boundaries and actual engine archive write. Test foreign/replaced locks, missing/invalid manifests, external repair while fatal confirmation is open, and blocked reconnect. Never test by deleting real archives. |
| Phase 2 exclusion | Equal roots, ancestor paths, symlinks, path case, includes, effective options, host aliases, socket roots, unknown roots, changed profiles while queued, effective profile and CLI path selections, shared-log append behavior, maintenance exclusion, and external Unison contention. |
| Phase 2 isolation | Pictures/FlightSim and disjoint Home/Pictures equivalents, one crashes/stops/prompts without changing the other, shared log integrity, separate row generations, background windows, several CLI requests and Quit races. Test two first, then more sessions to size any resource limit. |
| Performance | Record current app numbers for the Home profile and a reproducible 100k-row fixture in A/B. Compare scan-to-display, control latency, summed RSS, process startup and recovery overhead on the same machine and fixture. Separate root scan/network cost from IPC delivery. |
| Crash reporting | Distinguish GUI, engine, helper and expected fault-injection reports, delayed report arrival, failed correlation, deduplication and startup after tests. Test parentProc classification before relying on it. |
| Attended behavior | Keyboard/VoiceOver prompt focus, sync outcome, background completion, cancellation, signed protected-path access and real remote recovery. Link existing #197 candidates and explicitly choose their disposition. |

Before setting performance gates, record baseline distributions across repeated current-app
runs and spike runs. Keep CPU/OS/toolchain, fixture, row count and cache conditions comparable.
Use disposable copies for writes and obtain permission for any real Home-profile measurement.

Initial discussion values are 250 ms control latency under load, scan-to-display overhead below
10% or 250 ms (whichever is larger), summed RSS below 1.5 times baseline, and recovery overhead
of cleanup plus 1 second. They are provisional hypotheses. Review the measurements to retain,
replace or remove each before implementation acceptance. Never hide a miss with unbounded
buffers or a silent timeout increase. Report cleanup-blocked cases separately from successful
fresh-engine recovery.

Keep evidence with exact source commit, signed artifact hash, upstream/blob identity, platform,
fixture and failure-injection boundary. Daily use alone is insufficient for rare crash and
archive transitions. Release version and scope are maintainer decisions after spike evidence.

## 13. Decisions requiring approval or qualification

| Decision | Proposed default | What can change it |
|---|---|---|
| Parent engine | Retain existing parsing, metadata and archive-lock runtime | Audit finds a concrete reliability or responsiveness problem |
| IPC | Inherited Unix socket pairs, framed typed JSON | Measured bulk cost or signed launch constraints |
| Cleanup topology | GUI/engine with v2 lifelines outside transport groups and S/U/D completion records | Reliable records, complete group observation, adapted reaper, authenticated SSH and signed/macOS 15 qualification |
| Ready-session reservation | Hold while engine and row state remain usable | A separately designed detach/snapshot/revalidate feature |
| Concurrent scope | Qualify effective selected paths and remote identity, uncertainty serializes | Pictures/FlightSim and disjoint Home/Pictures acceptance tests, log append and option semantics |
| Retry presentation | Historical results, no automatic row override replay | Product review of partial-sync and scan-retry examples |
| Stop and cleanup limits | Provisional values in section 4 | Baselines, failure-injection measurements, OS constraints and explicit residual-risk acceptance |
| Phase 1/2 release versions | Undecided | Maintainer scope and spike outcome |

## 14. Review questions

1. Which tools escape the existing transport hooks, including PTY, custom shell, proxy,
   diff and merge paths? Does the parent watch cover engine death before telemetry, and does
   helper shutdown preserve child ownership and group cleanup on every exit branch?
2. Can a request change effective roots/options between preparation, reservation and use?
   Does any preparation step write archives before admission?
3. Can one ready session mutate stale row state after another is admitted to overlapping files?
4. Can a duplicate completion, a stale sheet answer or a lost reply cause a second operation?
5. Can uncertain lock ownership be turned into permission merely by killing a child?
6. Can a blocked engine prevent the C control thread or GUI cleanup, and does the
   cleanup-blocked UI explain the remaining limitation?
7. Does the signed process topology retain the expected TCC attribution on macOS 15?
8. What supported configurations must serialize because identity or descendant cleanup cannot
   be proven, and does the UI explain that limitation?

An accepted design must answer these with implementation boundaries and qualification evidence.
The first review should challenge the lifeline completion proof, helper-retirement protocol,
signed platform behavior and phase 2 benefit using measured evidence. Revisit the more expensive alternatives only when the evidence or
required guarantee warrants their cost.

## 15. Outstanding work before implementation approval

The selected topology is v2 lifelines with owned-group signaling and verified S/D completion.
The following remain open, rather than being implied complete by the prototype reports.

- Correct the prototype's signal-registration window, SIGPIPE and closed/full-reader behavior,
  ignored write/setup errors, repeated KILL-phase signaling, and bounded membership enumeration. Reproduce failure cases and verify the completion rule fails closed.
- Integrate all transport spawn and patch 0004 disposal paths, validate signal/exit status and
  pipe/environment/signal ownership, and exercise engine/GUI/helper failures without real profiles.
  Separate #35 actual-transport exit evidence from helper completion. Enforce and test the
  per-connection barrier before reconnecting within a live engine.
- Qualify password-authenticated SSH, Developer ID/hardened/notarized packaging, macOS 15 and
  TCC under the actual topology. Validate crash-report role classification and test isolation.
- Perform step A's incident qualification and baseline measurements. Select and size any
  interim remedy, then review numeric deadlines, performance targets and effort estimates.
- Approve the proposed retry/partial-result presentation and supported boundaries for escaped
  descendants. Cleanup-blocked behavior is required whenever the completion rule cannot pass.
- Qualify phase 2 effective scope, remote identity and shared logging against the real-profile
  acceptance cases before enabling concurrency. Choose a capacity policy from measurements.

Audit-token signaling is a future option. It is absent from phase 1's critical path.
