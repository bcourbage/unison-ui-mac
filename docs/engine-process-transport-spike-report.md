# Signed transport supervision and SSH/PTY spike

November 23, 2026. Step B component experiment; **not production qualification**.

PR #243 was squash-merged as `db353a8e3921da4df0f9e3ad47b28a287fd13e51` after Build
+ test and Build product site passed on `9497004`. Local main is current. This work
starts from that merge on `spike/engine-transport-supervision`. Only standalone
spike code, reports and evidence change; no product/OCaml/release/CI source changes.

## Boundary under test

A new standalone C lifeline is Developer ID signed with hardened runtime, secure
timestamp, minimum macOS 15.0 and an explicit probe signing identifier:
`net.courbage.unison-ui-mac.engine-transport-spike.lifeline`. It is not notarized.
The parent actor is a Python harness. The real AppKit/OCaml engine, prompt classifier
and patch 0004 disposal paths are not integrated by this experiment.

Changes relative to the earlier helper:

- Checked two-way child-ready/parent-release setup, group creation and PTY foreground
  handoff. Stop signals stay blocked across fork until the child's default handlers
  are installed; the durable stop flag handles earlier registration windows.
- Separate transport-exit and cleanup-complete events. waitid/WNOWAIT observes exit
  while retaining the direct child's identity. Reaping happens only after cleanup.
- Growing membership buffers, complete proc-info checks, a listed-leader consistency
  check and unknown results that retain the cleanup block. The helper resets its own
  SIGCHLD disposition so inherited auto-reaping cannot break ownership.
- Nonblocking status/lifecycle channels, inherited SIGPIPE preservation, explicit
  environment/descriptor cleanup and repeated KILL-phase group signals.

The lifecycle record `TransportStarted` means setup accepted before exec release;
it is not proof of successful exec or current liveness. A no-child setup failure
uses childPID 0 in CleanupComplete and a synthetic setup status. The consumer must
not label that as an actual SSH exit. The prototype wire format is not the final
engine protocol.

See [source and commands](../spikes/engine-process/transport/README.md).

## Current-machine results

Heracles: arm64, macOS 27.2.1, Apple clang 21.0.0, OpenSSH 10.5p1. The final signed
helper's exact source/binary identity is in the
[manifest](evidence/engine-transport-spike-2026-11-23/manifest.json).

The final artifact passed **22 normal cases, one deferred-consumer ordering case,
and five additional setup/environment cases**. Failed exploratory runs below are
not included in those 28 passed observations.

| Area | Observed result |
|---|---|
| Ordinary exit and failed exec | Exit 7 and exit 127 preserved; status and lifecycle completion agree. |
| Startup windows | Stop before watch/start/fork, child setup failure, release EOF and post-release/pre-exec stop do not execute the marker command. |
| Early exit with a lingering descendant | Transport exit is reported before completion; the helper keeps ownership through escalation. |
| Closed status/lifecycle readers | Cleanup continues and status is preserved. Missing completion evidence stays missing; it is not silently synthesized. |
| Full start pipe | No successful S, no transport start; helper exits 71. |
| Membership query returns zero/EIO | U is observed and no D/Complete is offered while the fault is active. Clearing it permits normal completion. This is an injected API-return case, not an actual kernel permission error. |
| Membership list grows past initial capacity | Eight stubborn descendants with a two-slot test buffer complete after growth and escalation. |
| Spawner ignores SIGCHLD | Helper still owns/reaps its child and preserves exit 7. |
| Simulated engine death | Killing the owned Python parent actor produces completed helper cleanup. This is not signed AppKit GUI/engine death qualification. |
| PTY foreground | Child group equals terminal foreground group. |
| Real SSH key authentication | Disposable loopback server authenticates and returns its forced marker. |
| Encrypted fixture key through PTY | Correct passphrase, wrong-then-correct passphrase and cancel all behave as expected; cancellation preserves signal 15. No real account password is used. |
| Real login-grace failure with lingering descendant | SSH exits 255; exit evidence precedes cleanup by about 0.36 seconds. |
| Consumer delivery order | Ordinary run observes final terminal text before TransportExited. Deferred delivery observes TransportExited before the terminal notification, while the PTY is continuously drained. |
| Additional negative setup | Fork failure, missing lifecycle channel and PTY setup failure execute no marker. |
| SIGPIPE and helper environment | Both default and ignored dispositions survive to the transport, and helper-only environment variables are absent. |

All final runs use the same signed helper. Most use a 300 ms test grace; the
post-release injection uses 1000 ms. The source default remains 2000 ms. These are
fixture timings, not approved production bounds or a performance baseline. The
normal-case driver snapshot is retained as `harness-used-normal.py`; the consumer-
delivery correction is separately identified by current source hashes.

## What failed during the experiment

1. **Harness setup:** duplicate environment-key construction stopped the initial run
   before another helper spawned. Two earlier cases had passed. The correction and
   old harness hash are recorded in `attempt1/failure.json`.
2. **Login-grace expectation:** an initial assertion failed without retaining the
   actual value. An instrumented repeat showed exit 0 and successful authentication
   after a 1.5-second pause. It was not an expired-connection result. The corrected
   fixture pauses 6 seconds and observes actual exit 255/closed-connection output.
3. **Unread-PTY experiment:** stopping PTY reads while waiting for TransportExited
   timed out, and its cleanup wait also reported incomplete. That instance's detailed
   state was not retained. The experiment introduced I/O backpressure instead of
   delaying a notification. The corrected ordering driver always drains output and
   defers only delivery. That isolates notification ordering but does not qualify
   the app's paused-reader prompt path. The underlying cause was not traced during
   that first run; the follow-up below reproduces and locates the stall.

These outcomes remain in the evidence. They are not hidden by the final passes or
counted as helper qualification. The final signed helper also moved the enumeration
fault to the real zero-return handling boundary; the full case set was rerun on
those final bytes.

## Unread PTY follow-up (November 24)

The app's `drivePromptLoop` requests another terminal read only after the sheet's
answer is submitted through `unison_bridge_connection_reply`. Upstream's
`Terminal.handlePasswordRequests` continues its read loop while a user answer is
pending. Thus continuously draining the PTY in the ordering fixture does not model
this app's prompt path. The failed no-drain run cannot be dismissed as irrelevant
harness behavior.

The new `trace-unread-pty.py` uses the same signed transport-v2 helper and disposable
loopback key fixture. Lifecycle/status readers keep running independently. After
the server's login grace expires, the driver sends the fixture-key passphrase and
either drains the PTY, pauses reads then resumes, or pauses reads and stops its
owned helper. It records `ps` state, independent kqueue NOTE_EXIT notifications,
helper lifecycle events, output chunks, and cleanup. Two complete repetitions and
one further repetition with stack sampling produced nine observations:

| Case (three runs each) | Observation |
|---|---|
| Continuously drained control | SSH exits 255 and cleanup completes before the two-second post-answer observation. |
| Reads paused, then resumed | At two seconds SSH is still alive (`S+`); no kernel exit event, TransportExited or CleanupComplete. Resuming reads allows exit 255 and verified cleanup. |
| Reads paused, owned helper stopped | The same stall precedes the stop. Without resuming reads, the helper's TERM/KILL sequence ends SSH by SIGKILL (9) and produces TransportExited and verified cleanup. |

In both sampled stalled runs, SSH's main thread is in
`readpassphrase -> tcsetattr -> ioctl -> __ioctl`. This locates the blocked terminal
attribute operation; it does not establish the exact ioctl flags or kernel wait
implementation. No terminal-buffer-size theory or exit-wait bound is inferred from
these samples. Once reads resume, the captured chunks contain a two-byte newline
and a short connection-closed message, rather than a large diagnostic flood.

Evidence is retained under `unread-pty/` and `unread-pty-sampled/`, including sanitized
stack samples. Original sample headers, image paths and temporary files are not
retained. The sample calls succeeded; no app or OCaml process was involved. These
observations locate a component stall, not a reproduced AppKit-sheet failure or a
qualified prompt-reader fix. They add no passes to the earlier 28-case count.

Actual exit evidence remains authoritative once observed, but cannot make SSH exit
while the terminal operation is blocked. Missing evidence remains unknown. Do not
classify a new credential request solely from the lack of an exit event.

**Settled phase 1 decision (November 24): retain paused terminal reading while a
sheet is open.** Exit evidence may be delayed until reads resume or teardown forces
termination. The initial recommendation to add a bounded independent reader is
superseded: it would change credential handling beyond today's behavior and is a
separate improvement outside phase 1. The real bridge must still qualify the
retained behavior and server-password controls.

In all three stopped-while-unread observations, SSH ended by SIGKILL. Expect that
state's Cancel/teardown to use the full TERM grace before KILL, followed by verified
cleanup. These fixtures used 300 ms; the source default is 2 seconds and its actual
end-to-end cancellation delay remains unmeasured. Measure the intended production
setting during integrated qualification, including overhead. SIGKILL in this
deliberate teardown is expected, not evidence of failed cleanup. The hypothesis
that readpassphrase catches TERM and blocks again restoring terminal settings is
consistent with the samples but unproven. Skipping the grace when a prompt is
pending is a possible later decision, not a new implementation task here.

## API/source checks

The local owned-child probe found its unreaped group leader listed after exit.
The helper uses its own waitid result for that child; proc_pidinfo for the exited
leader returned no structure. A NULL-buffer estimate was not treated as actual group
membership. The observation and source are retained as `group-observation.*`.

[Apple's libproc wrapper](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)
can turn an underlying process-list error into zero. The helper therefore requires
its still-owned leader in a usable list, rather than equating zero with completion.
This source check and the injected return do not qualify every platform/churn case.

[Upstream OpenSSH's timer](https://github.com/openssh/openssh-portable/blob/master/sshd-session.c)
adds up to four seconds of login-grace jitter. That made 1.5 seconds an unsuitable
fixture assumption. This is upstream source context, not verification of the exact
Apple-patched implementation; the local test's actual closed connection is recorded.

## Maintainer clarification for step A

The maintainer reports this workflow for the November failures: the remote scan took
a long time; they stepped away for several hours; the scan had completed on return;
Sync then failed and explicitly required an app restart. An intervening timeout was
their hypothesis.

This defines A's primary reproduction case. Exact historical timeout/PID attribution
need not be a prerequisite for testing a remedy. The next A fixture should target
completed-scan/ready state, an idle or deliberately closed disposable connection,
then Sync. It must observe the actual fatal/completion and cleanup/coordinator state
before deciding whether a fresh reconnect/rescan is safe. Relaunch-and-reopen stays
the smaller fallback. No interim fix is selected or implemented here, and current
performance measurements remain open. The connection-time login-grace test above
does not reproduce this ready-after-scan failure.

Immediately before Sync, record the current connection's exact SSH identity and
whether it is already terminated, using the #35 evidence where applicable. Distinguish
that from a still-running SSH process whose connection may be dead. Evaluate a
pre-Sync prevention check as well as post-failure recovery: known termination can
support an early refusal/rescan offer; process liveness alone cannot establish a
healthy remote connection, and a still-live failure may require a bounded round-trip
test. This is an experiment/decision, not an implemented health check or permission
to replay the old scan's decisions after reconnecting.

## Cleanup and remaining gates

Only disposable high-port loopback SSH servers and fixture keys were used. They used
a private AuthorizedKeysFile/known_hosts and a forced marker command. No system SSH
configuration, real SSH keys/agent, account passwords, profiles, archives or TCC
settings were changed. Private fixtures were removed. Read-only process checks found
no known helpers/transports or fixture listener processes remaining; no process-name
signals were sent.

Still required: real engine/GUI ownership and patch integration; the actual #35
prompt consumer, pending-sheet PTY-drain behavior and reconnect barrier;
server-password-authenticated SSH (correct password, wrong-password retry/#63,
login-grace expiration and Cancel), distinct from client-key passphrase tests;
complete signed failure/backpressure/error
and churn qualification; externally killed-helper behavior; notarization, production
identity and macOS 15. These results do not approve a production cutover or declare
step B complete. The normal product unit suite was not rerun for these standalone
files; it does not execute this harness.

The server-password pass should use the disposable VM account, with the maintainer
typing the password. It was not run in this follow-up. The loopback fixture disables
password and keyboard-interactive authentication; its successful key-passphrase
cases provide no server-password qualification.
