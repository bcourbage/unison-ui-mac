# Engine-process spikes: initial evidence

Date: November 23, 2026. Status: **in progress**. This is the first isolated part of
step B, plus source/provenance intake for A. It does not qualify the architecture
or complete either step. The later [signed launch/TCC pass](engine-process-signed-launch-tcc-report.md)
is recorded separately. See [the design](engine-process-design.md).

Work starts from `f8d6d28cb3d24721f4f8be83645ecf8be2c5b93e`, the documentation
commit used by PR #242. The spike has its own worktree and branch,
`spike/engine-process-qualification`. The initial process-only pass changed no product
source, project, vendor checkout, release artifact, installed application, real profile
or TCC setting. The later signed pass temporarily changed only the separate probe's FDA
entry and removed it afterwards; details are in its own report.
Spike results are maintained separately from the design PR. Documentation-only corrections were
subsequently committed and pushed to #242 as recorded below.

## Reviewer report disposition

All three final notes are accepted:

1. Save and restore the **inherited** SIGPIPE disposition. Default and ignored
   dispositions both matter.
2. Set O_NONBLOCK on the status writer at channel creation in the GUI. Copies of
   that writer share an open-file description, so helpers must not independently
   change its flags. This does not mean the pipe's separate read endpoint shares
   the writer's flags.
3. Correlate transport evidence with each prompt, record arrival ordering and keep
   unknown distinct from alive. The signed integration spike must still establish
   the bounded refresh/defer behavior for ambiguous output, with genuine password
   and host-key prompts as controls. A prompt-time snapshot alone does not prevent
   the transport exiting while the message is in flight.

The design includes those clarifications and the startup-stop finding below.

## Environment and retained inputs

- Heracles, arm64, macOS 27.2.1 (26B131).
- Apple clang 21.0.0 (clang-2100.4.1.1).
- Reviewer v3 source copied out of the reboot-volatile scratchpad. Original copies
  remain preserved in the author's workspace; runnable copies and logs accompany
  this report under [evidence](evidence/engine-process-spike-2026-11-23/manifest.json).
- Both C programs compiled with `-Wall -Wextra -Werror -O2`.
- The initial process-only pass ran **unsigned**, outside the app and hosted XCTest process.
- The sandboxed signing-identity query reported zero identities. An unsandboxed,
  read-only query found an Apple Development identity and a Developer ID
  Application identity for the maintainer. Signing was not exercised. The first
  result must not be treated as evidence that signing credentials are absent.

The harness uses disposable child processes and recorded groups. Its detached-child
case was adapted to capture the exact child's PID through a private fixture file,
rather than killing processes found through a shared command substring. The nine
original scenarios were retained. The externally killed helper case intentionally
leaves a transport; the harness removes that recorded test group afterwards. The
escaped-child case similarly removes its own recorded child. No process-name kill
or signal to an existing app was used.

## Independent process and reporting results

These were run independently by the author, rather than copied from the reviewer's
report. Exact output is retained in
[original-cases.log](evidence/engine-process-spike-2026-11-23/original-cases.log) and
[reporting-cases.log](evidence/engine-process-spike-2026-11-23/reporting-cases.log).

| Case | Observed result |
|---|---|
| Ordinary transport exit with a TERM-ignoring descendant | Helper preserved exit 7; group empty at D/EOF, approximately 2.27 s with a 2 s grace. |
| Engine SIGKILL while transport and descendant run | Matching S/D, EOF and no live group members. |
| Engine death before helper watch | No S and no transport observed. This is a scheduling test, not exhaustive coverage of every startup instruction. |
| SIGTERM retirement | Transport signal 15 preserved; no live group members at EOF. |
| Failed transport exec | Exit 127, matching S/D. |
| Helper SIGKILL | S remained unmatched; result unknown; transport survived until harness cleanup. |
| PTY | Transport group equalled foreground terminal group; S/D completed. This was not a password-authenticated session. |
| Real ssh with sleeping ProxyCommand | SSH and proxy shared the owned group and were gone after engine death. No network authentication was attempted. |
| Descendant deliberately leaves the group | In-group cleanup completed while the detached child survived. This confirms the documented boundary, not containment of escaped tools. |
| Reader closed after S | Helper preserved exit 7 and no stubborn descendant survived. |
| Pipe full before S | Helper exited 71; no transport was observed. |
| Reader stays open but stops draining | Helper exited 7 in approximately 0.29 s; S without D, correctly unknown. |
| Inherited SIGPIPE default / ignored | Transport observed default / ignored respectively. |

The reporting harness checks the corrected copy, not the defective v2 source.
Closing during every U/D write boundary remains to be instrumented explicitly;
this pass must not be described as exhaustive reporting-failure coverage.

## Startup stop: reproduced gap and narrow experiment

A spike-only hook sends SIGTERM to the helper immediately after handler installation
and before kqueue filter registration. The unmodified handler consumes it and the
transport runs normally. A copy that only blocks stop signals until registration
also ran the transport to completion in this experiment. That unsuccessful attempt
is retained in
[early-stop-attempt1.log](evidence/engine-process-spike-2026-11-23/early-stop-attempt1.log)
and `lifeline-blocked-only.c`; its assertion failed, and it is not counted as a pass.

A second copy both blocks during setup and records a handled stop in durable
`sig_atomic_t` state. It checks that state before S/fork and at the wait boundary.
With the same injected stop, it returned 143, emitted no S and started no transport.
The untouched control returned 0 after its two-second transport completed.
[early-stop.log](evidence/engine-process-spike-2026-11-23/early-stop.log) records the
paired result; the repeated run log records the additional controls.

This is a deterministic test of one registration boundary. It is not a complete
helper implementation: the original prototype still has unchecked setup/handshake
paths and incomplete membership observation. The other startup intervals still need explicit fault injection. The child signal-reset/exec
boundary was subsequently exercised as recorded below.

## Child signal-reset window: independent follow-up

The reviewer's `base.c`, `late.c`, `late-fixed.c` and `probe.py` were copied out of
scratch storage into [child-window](evidence/engine-process-spike-2026-11-23/child-window/results.log).
Both variants were compiled with the same warning/error settings and independently
run three times each. The hook widens the interval after the setup handshake and
before exec, then injects a stop; it does not exercise a natural timing occurrence.

| Variant | Three observed outcomes |
|---|---|
| Reset only just before exec | SIGKILL; 2.29 s, 2.14 s, 2.12 s. |
| Reset immediately after fork | SIGTERM; 0.22 s, 0.11 s, 0.11 s. |

The low-severity finding is confirmed: cleanup completes, but a stop consumed by an
inherited helper handler wastes the grace period and changes the terminal status.
A new standalone `lifeline-child-reset.c` moves the reset before child setup and
removes its redundant late reset. The nine process-ownership cases all passed on
that copy; see [the control log](evidence/engine-process-spike-2026-11-23/child-window/nine-cases-after-reset.log).
Earlier sources remain unchanged so their recorded hashes and results stay valid.

The design also requires the checked setup handshake to establish that the child's
signal setup is complete before release. Moving the reset alone does not qualify
all possible fork-to-first-instruction or setup-error intervals. Those remain part
of the full handshake/startup gate. This pass used unsigned standalone helpers.

## A: incident and baseline intake

- Vendored blob SHA-256 is
  `99ffc936559bc5b104b60bc5006d43db52a7e2ea4e6d30de29126ca4643cf1a3`, matching
  the repository's provenance record.
- Local upstream HEAD is `4f6e8c78b80c21d45b02807071f5dc2715a7eac4`.
  It differs from the vendored upstream base, `91421d0617b0fb543c0eee51bcb4d4791d8b0631`,
  and has modifications in remote.ml, remote.mli, test.ml, uicommon.ml and
  uimacbridge.ml. That checkout was read only and was not rebuilt or patched.
- Independently read `src/uicommon.ml` at the vendored base with `git show`:
  `doTransportFailCleanup` is defined at line 753 and called at line 798. It closes
  the remote connection and drains dropped work. The candidate path exists in the
  shipped base, but safe runtime reuse after these incidents remains unproven.

The first pass did not locate the incident log. The reviewer supplied its path,
`~/Library/Application Support/Unison/Unison-Sync.log`; an unsandboxed read succeeded.
The source is 164,105,668 bytes. It was not copied. A reproducible read-only
[extractor](evidence/engine-process-spike-2026-11-23/extract-incident-summaries.py)
retains only start timestamps, counters and fixed error text for the two windows,
plus selected power events. The evidence records the source log's SHA-256 without
retaining personal file paths.

| Incident | Path-free log evidence | Nearest recorded client power events |
|---|---|---|
| Nov 19, 09:41:51.45 | Lost connection; no propagation-finished record before the next propagation start. | Full wake at 09:38:50, about 3 minutes earlier; next sleep at 09:43:05. |
| Nov 22, 14:24:28.86 | Lost connection; no propagation-finished record before the next propagation start. | Last preceding wake in the captured log is Nov 21 at 16:39:25; next sleep is Nov 22 at 15:49:42. |

Both windows have 65 `[BGN]` entries and no `[END]` entries. These are logging
observations, not proof that no user-file writes occurred. The error lines do not
carry their own timestamps, so the start times cannot be used as exact failure times.
[Incident summaries](evidence/engine-process-spike-2026-11-23/incident-windows.json)
and [power summaries](evidence/engine-process-spike-2026-11-23/sleep-wake-windows.json)
retain line references and the selected records.

These records do not establish one client-sleep trigger for both failures. Nov 19
is compatible with an idle connection surviving a sleep/wake interval, but connection
creation time and remote-side evidence are missing. Nov 22 does not show a nearby
preceding local sleep/wake event in this extraction. Server sleep, transport lifetime,
network loss and actual cleanup are still unqualified. No interim remedy is selected.
Real Home-profile and synthetic 100k-row baseline measurements have not run.

## Unified-log process history: follow-up evidence

Independently queried the app process around both incidents and the reported relaunch
using `/usr/bin/log show --style json --info`, outside the sandbox. The bounded query
windows and path-free metadata are retained in
[unified-process-windows.json](evidence/engine-process-spike-2026-11-23/unified-process-windows.json).
Raw messages are not part of the repository evidence.

| Observation | What it establishes |
|---|---|
| Nov 19 incident window: 31 records from PID 97809. Nov 22 incident window: 6 from PID 97809. Same boot and executable UUID. | Strong support for a continuing GUI process across the incidents. These exports contain no process-birth identifier; matching PID/boot/image alone is not a strict exclusion of PID reuse. |
| Nov 19 framework burst starts at 09:42:09.584604; notification-center creation at 09:42:09.828230. | Framework activity approximately 18 seconds after propagation started, and 55 seconds before the lid-close sleep. It does not identify a fatal, a dialog or a coordinator transition. |
| Nov 22 later window: 25 records from PID 61068, first at 15:43:07.252191; its notification center is created at 15:43:07.430450. | A different app PID appears about 79 minutes after the failed sync start, consistent with the reported relaunch. First retained activity is not itself a process-birth record. |
| No own-subsystem trace records in these selected queries. | These records cannot establish whether restart-required was entered, a notice was dismissed, or a later operation was admitted. This is not a claim about all retained logs outside the queried windows. |

The framework burst may be the failure appearing on screen, but that is an inference.
If so, the following lid closure cannot have caused that failure. The records do not
establish that either sync was run by the GUI PID: the sync log is shared with other
profiles/clients. Nor do the 65 starts and zero ends prove that no file writes occurred.
They support an early-stall hypothesis without establishing the exact failure time.

Step A must now distinguish these possibilities before selecting an interim fix:

- A normal completed operation with per-row failures, a top-level fatal, a failed
  dispatch and a stalled operation are different terminal paths. Check the actual
  coordinator transition rather than treating every Lost connection line as a fatal.
- Determine the writer/session for each incident and whether the same GUI/runtime
  really handled both. Confirm the running build, not only today's source.
- Reproduce idle-connection loss with disposable remote fixtures, recording dispatch,
  fatal/completion callbacks, pending operation identity and restart-required state.
  Establish whether recovery/admission remained possible after the first failure.
- Treat retained state from Nov 19 contributing to Nov 22 as a hypothesis, alongside
  sleep/network/remote lifetime hypotheses. No current evidence chooses between them.

The brief no longer states that both observed failures necessarily entered the restart
rule. This is an incident-qualification question, not a confirmed new product defect.

## Branch and review record

PR #242 was maintained as the design-review branch through its final cleanup. The design clarifications were moved
there and committed as `56bb830`, along with the brief's incident-claim correction
and a historical-status note on the original review prompt. That commit was pushed;
it changes only the three documentation files already in #242. A follow-up,
`bf8e587`, replaces inaccessible workspace references and rewraps recent prose. The
historical prompt also has no personal home-directory path. The design has no
link dependency on this unmerged spike report. Those edits preceded the authorized merge.

Both Build + test and Build product site passed on `bf8e587` in run
`45331618539`. The final-head check record is retained as `design-pr-ci.json`;
this validates the documentation PR, not the engine topology. The user then authorized
the squash merge: #242 merged as `db739ff843a2191acd9d5604bc8fdd28b6ff8f2b`.

The spike branch first fast-forwarded to the latest design commit, then merged
`origin/main` as `05e994c` after the squash merge. Results, evidence and standalone spike code are kept on this branch; there is no
separate design diff or product-source change. Future design changes need a new review now that #242 is merged. Retain
the exact SHAs and source hashes used for every experiment. The original tests remain attributed to `f8d6d28`; subsequent
documentation changes do not retroactively change their tested source identity.

## Historical-source archive

The unchanged v1 and v2 sources are now preserved with these results under
[historical/](evidence/engine-process-spike-2026-11-23/historical/README.md), including
v1's `review-result.md` recording the original EOF counterexample. The archive has
its own copied-file hash manifest. No historical probe was rerun during this cleanup;
these are superseded experiments, not current qualification. No binaries are included.

## Next gates

1. Extend the initial signed/TCC prototype pass to actual engine integration and
   supported-platform qualification. The separate FDA fresh/granted/relaunch/revoked
   cases passed on Heracles; notarization, production identity and macOS 15 remain
   open. Obtain permission for additional protected targets or changed access scope.
2. Complete the spike helper's checked group/PTY handshake, inherited FD/environment
   audit, bounded membership enumeration and error/churn injection. Move nonblocking
   setup to the channel creator. The retained v3 source is not production ready.
3. Add actual TransportExited evidence and exercise prompt/exit reordering, login-grace
   timeout with a lingering descendant, genuine retries, Cancel and the reconnect
   completion barrier. Patch 0004's real disposal paths are not integrated yet.
4. Finish A's connection/cleanup evidence, cause qualification and comparable baseline
   distributions; select and size
   any interim remedy from those findings. No interim fix has been selected.
5. Revisit B's estimate from the signed and integration evidence. No numeric acceptance
   deadline or phase 2 capacity has been validated by these short tests.

## Repeating the retained experiments

Run from `docs/evidence/engine-process-spike-2026-11-23` on macOS with process visibility.
Review the harnesses first: they intentionally kill their own engines/helpers and
exercise one detached-child limit. They are development probes, not app tests.

```sh
clang -Wall -Wextra -Werror -O2 lifeline.c -o lifeline
clang -Wall -Wextra -Werror -O2 pipedisp.c -o pipedisp
python3 harness-owned.py
python3 harness3.py "$PWD/lifeline"
clang -Wall -Wextra -Werror -O2 lifeline-early-stop.c -o lifeline-early-stop
clang -Wall -Wextra -Werror -O2 lifeline-blocked-stop.c -o lifeline-blocked-stop
python3 early-stop.py
```

No full app suite was run: these probes do not modify the application build path.
