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
3. **Wrong ordering experiment:** stopping PTY reads while waiting for TransportExited
   timed out, and its cleanup wait also reported incomplete. That instance's detailed
   state was not retained. The experiment introduced I/O backpressure instead of
   delaying a notification. The corrected driver always drains output and defers
   only delivery. The underlying kernel reason for the earlier stall was not traced.

These outcomes remain in the evidence. They are not hidden by the final passes or
counted as helper qualification. The final signed helper also moved the enumeration
fault to the real zero-return handling boundary; the full case set was rerun on
those final bytes.

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

## Cleanup and remaining gates

Only disposable high-port loopback SSH servers and fixture keys were used. They used
a private AuthorizedKeysFile/known_hosts and a forced marker command. No system SSH
configuration, real SSH keys/agent, account passwords, profiles, archives or TCC
settings were changed. Private fixtures were removed. Read-only process checks found
no known helpers/transports or fixture listener processes remaining; no process-name
signals were sent.

Still required: real engine/GUI ownership and patch integration; the actual #35
prompt consumer and reconnect barrier; complete signed failure/backpressure/error
and churn qualification; externally killed-helper behavior; notarization, production
identity and macOS 15. These results do not approve a production cutover or declare
step B complete. The normal product unit suite was not rerun for these standalone
files; it does not execute this harness.
