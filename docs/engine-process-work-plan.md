# Engine-process work plan and progress

Last updated: **November 24, 2026**.

This is the living progress checklist for the engine-process work. It records the
two engineering lanes, their review gates, and the work that follows. It does not
authorize publication or imply that two workers are currently running.

The [design](engine-process-design.md) defines the technical contracts. Its sequence
and this checklist place the broad performance baseline in a quiet session before
C, outside immediate A work. The combined D/phase 2 investigation starts early,
but its implementation does not.

## Dashboard

Flags: **DONE** = completed within the stated scope; **PARTIAL** = evidence exists
but the gate is open; **NEXT** = next work; **WAIT** = depends on another result;
**LATER** = intentionally scheduled later; **CONDITIONAL** = requires a decision.
A checked task is not an accepted review gate. Record gate acceptance separately.

| Work | Flag | Where we stand | Next milestone |
|---|---|---|---|
| Design baseline | DONE | Brief, design and historical review prompt merged in #242 (`db739ff`). | Review changes if spike evidence alters a contract. |
| Lane 1: A, idle-after-scan failure | NEXT | Incident intake exists; maintainer supplied the workflow. Controlled reproduction and remedy selection remain. | G-A: select and size a remedy. |
| A1: interim fix in today's app | CONDITIONAL | No remedy selected or implemented. A separate release, potentially 1.0.2, is undecided. | Implement only after G-A; release decision follows qualification. |
| B: initial signed launch/TCC | PARTIAL | #243 merged (`db353a8`): separate signed probe passed current-machine launch and limited directory-access FDA tests. | Integrated installed-bundle and supported-platform qualification. |
| Lane 2: B, helper and prompt path | PARTIAL | Signed helper has 28 component observations plus nine unread-PTY observations. Review settled on retaining paused reading in phase 1. VM password and actual integration qualification remain. | G-B1: qualify the retained prompt behavior and password controls. |
| Combined D/phase 2 study | NEXT | Responsibilities and resource requirements are described in the design; the consolidated source study remains. | G-S: one written study and review. |
| macOS 15 environment | NEXT | Availability and setup have not been qualified by this work. Deployment target 15.0 is not a runtime test. | Environment ready for an integrated artifact. |
| Broad performance baseline | LATER | No baseline measured. | Quiet measurement session before C. |
| C: codec and fake worker | WAIT | No implementation. Prompt/cancellation contracts depend on B. | G-C: readiness review after relevant B findings, study and baseline. |
| E–G: phase 1 integration and cutover | LATER | No production engine-process integration yet. | Integrated qualification before cutover. |
| H1/H2/I: phase 2 concurrency | LATER | Investigation starts now; implementation and qualification come later. | Resource claims qualified before enabling overlap. |

## Execution and review rules

- Run **two engineering lanes**: A and B. The source study is background work,
  not a third implementation lane. Only one lane's technical issue should need
  a maintainer decision at a time where scheduling permits.
- Use separate worktrees, disposable Unison directories, archives, ports and
  owned test processes. Do not share the hosted-test OCaml engine between lanes.
- Keep failure injection and other load away from performance measurements.
- Batch reports at the milestones below. Interrupt earlier for a blocker, a
  material design change, an ownership/safety failure, or required attended work.
- Each gate gets a consolidated report, adversarial review and disposition of
  findings. Routine corrections stay in the lane. The maintainer decides product
  behavior, scope and acceptance of unresolved risk.
- An open gate pauses only the work that depends on it. Both lanes pause only
  when an unresolved shared contract affects both.
- Technical gate acceptance, merge approval and release/publication approval are
  separate. No release is automatic.

## Lane 1 — A: qualify the immediate problem

Owner: coder. Attended help: maintainer only where the fixture requires it.

Target workflow: a remote scan completes; the user returns after hours idle;
pressing Sync fails and requires restart. A timeout is a hypothesis, not an
established cause. Exact historical PID attribution is not a prerequisite for
testing a remedy.

- [x] Record the maintainer's workflow and distinguish it from connection-time login-grace failure.
- [x] Preserve incident/source evidence and its attribution limits in the spike reports.
- [ ] Build a disposable completed-scan/ready fixture with controlled connection loss during idle time.
- [ ] Immediately before Sync, record the exact SSH child identity and termination evidence available through today's bridge.
- [ ] Distinguish already-exited SSH, still-running but failed/unresponsive connection, and a healthy control.
- [ ] Observe actual Sync failure, coordinator/restart state, locks and acknowledged connection cleanup.
- [ ] Assess prevention before Sync: can the existing `unison_bridge_transport_child_terminated` evidence help, or is a bounded round trip needed?
- [ ] Assess safe reconnect-and-rescan after failure and Relaunch and Reopen as alternatives.
- [ ] Specify what happens to displayed rows and decisions; a reconnect does not authorize replaying stale results.
- [ ] Produce one remedy recommendation with evidence, scope, tests, failure behavior and size.

### G-A — remedy selection

- [ ] Evidence report complete and adversarially reviewed.
- [ ] Cleanup and treatment of existing results are specified for the proposed remedy.
- [ ] Remedy selected, or decision recorded that no interim remedy qualifies.
- [ ] A1 estimate and regression/control cases agreed before implementation.

Decision / reviewer / date: **Pending**.

### A1 — conditional implementation and release

This targets **today's in-process app**, not the isolated-engine architecture.

- [ ] Implement the selected remedy with decisive regression and control cases.
- [ ] Review and qualify the combined change, including cleanup failure behavior.
- [ ] Record whether a separate release is worthwhile; version and timing remain undecided.
- [ ] If releasing, prepare the signed candidate, exact-byte record and attended acceptance.
- [ ] Obtain publication approval; verify the real Sparkle update and publication canaries.

**Integration obligation:** if A1 lands first, B must deliberately carry its
behavior forward when tracked-child evidence changes to actual transport-exit
evidence. Review the shared `AppDelegate`/bridge changes together and retain A1's
regression cases in B. Separate branches alone do not establish compatibility.

## Lane 2 — B: process ownership and prompt integration

Owner: coder. Batch maintainer-assisted password tests into a planned session.

### Evidence already collected

- [x] Merge initial spike results and signed launch/TCC pass in #243.
- [x] Test separate signed probe identity on Heracles: FDA missing, granted, retained and revoked; remove the probe's entry afterwards.
- [x] Record the standalone signed helper's 28 component observations, with failed exploratory runs retained separately.
- [x] Trace the unread-PTY stall in nine follow-up observations: drain control, resume reads, and owned-helper stop, three runs each.
- [x] Retain two stalled SSH stack samples: `readpassphrase -> tcsetattr -> ioctl`.
- [x] Verify resumed reads allow exit 255; owned-helper escalation completes cleanup while reads remain paused.
- [x] Adversarially review the latest unread-PTY evidence and its design implications; retain paused reading for phase 1.

These are component results. They do not qualify the actual AppKit/OCaml prompt
path. The loopback fixture tests client-key passphrases, **not server passwords**.

### Next: prompt behavior

- [x] Settle the scope: retain paused reading while a sheet is open; a separate reader is outside phase 1.
- [x] Document that exit evidence may be delayed until reads resume or teardown forces termination.
- [ ] Qualify the retained paused-reader behavior through the actual bridge, including prompt identity and safe handling of stale output.
- [ ] Measure Cancel and teardown at the intended production grace. Source default is 2 seconds; existing fixtures used 300 ms. Expect full-grace escalation to SIGKILL in the stalled state, then verified cleanup.
- [ ] Exercise login-grace expiry, connection closure, Cancel and a lingering descendant.
- [ ] Exercise both orders of prompt delivery and actual TransportExited evidence; absence of an exit event stays unknown.
- [ ] Run server-password authentication on the disposable VM, with the maintainer typing the password: correct password, wrong-password retry/#63, expiry and Cancel.
- [ ] Specify the bridge transport-exit integration and tests without adding an independent reader or a prompt-specific immediate-KILL policy.

### G-B1 — prompt-path decision

- [x] Component evidence reviewed, including the unread-terminal finding; actual bridge evidence remains to be collected.
- [x] Phase 1 behavior agreed: paused reading, delayed exit evidence, expected TERM/KILL grace and verified cleanup; no separate reader.
- [ ] Password controls completed, or any missing case explicitly prevents qualification of that behavior.
- [ ] Integration approach and remaining risks recorded.

Decision / reviewer / date: **Paused reading selected; reviewer concurrence relayed
by the maintainer, November 24, 2026. Qualification gate remains open pending actual
bridge/password controls and the integration report.**

### Then: actual ownership integration

- [ ] Integrate all real transport spawn paths: PTY, non-PTY and fallback.
- [ ] Adapt patch 0004 retirement without killing the helper before it can clean up.
- [ ] Wire actual transport-exit evidence into #35, separately from helper completion.
- [ ] Enforce the same-engine reconnect barrier before spawning a replacement transport.
- [ ] Qualify engine/GUI/helper failures, startup intervals, status/lifecycle errors, backpressure and membership churn.
- [ ] Verify exit status, inherited signals, descriptor/environment ownership and no remaining owned transport groups.
- [ ] Carry A1 forward if it has landed, including pre-Sync regression cases.
- [ ] Inspect helper signing identity and crash-report role attribution.
- [ ] Qualify a useful integrated artifact: signed/hardened, notarized and installed, with production-identity/grant behavior and macOS 15.

### G-B2 — integrated ownership

- [ ] Integrated evidence reviewed against the completion proof and failure cases.
- [ ] Prompt/exit/cancel and reconnect contracts demonstrated through the actual bridge.
- [ ] Platform results and unqualified limits recorded explicitly.
- [ ] B accepted, or remaining blockers and their dependent work identified.

Decision / reviewer / date: **Pending**.

G-B2 is not the final phase 1 release gate. C can proceed once G-C's actual
dependencies are satisfied; an unrelated outstanding platform case need not stop
fake-worker work, but it still blocks the corresponding production qualification.

## Background — one D/phase 2 study

Produce one written source investigation, not implementation in a third lane.

- [ ] Enumerate parent parsing, metadata, directory/version and archive-lock calls that remain in-process.
- [ ] Define parent/child role and runtime ownership, including persistent and first-load arguments.
- [ ] Investigate effective selected paths, includes, symlinks, aliases, remote identity, archive families and other shared resources.
- [ ] Assess shared logging and the Pictures/FlightSim and selected Home/Pictures acceptance cases.
- [ ] Identify requirements phase 2 places on phase 1 and separate those from changes that can wait.
- [ ] Record uncertain claims and proposed experiments without adding unused protocol fields.

### G-S — combined study

- [ ] One report reviewed and findings disposed of.
- [ ] Phase 1 boundaries confirmed or design amendments agreed before C is locked.

Decision / reviewer / date: **Pending**.

## Environment preparation and deferred measurement

- [ ] Confirm availability and setup requirements for a macOS 15 UTM VM or suitable machine.
- [ ] Prepare that environment with maintainer participation where required; do not infer runtime support from the deployment target.
- [ ] Schedule notarization/installed-bundle qualification when an integrated artifact is ready, rather than repeating it on an interim probe.
- [ ] Immediately before C, reserve a quiet measurement session with exact build/platform, fixture size and cache conditions recorded.
- [ ] Measure current scan time, memory and results-window behavior using disposable representative fixtures and the synthetic large list.
- [ ] Obtain explicit permission before using real profile data for a baseline; use a disposable equivalent otherwise.
- [ ] Set initial snapshot/backpressure targets from those results. Small timing measurements needed for A or B can happen earlier; they are not the broad baseline.

### G-C — readiness for codec and fake worker

- [ ] Relevant B prompt/cancellation/lifecycle contracts are settled; record G-B1 and any applicable G-B2 findings.
- [ ] G-S accepted and parent/phase 2 requirements reflected in the design.
- [ ] Quiet baseline reviewed and initial data-volume/performance targets recorded.
- [ ] Current message set, identities, terminal outcomes and test scope reviewed.
- [ ] C implementation authorized; no unused phase 2 reservation fields.

Decision / reviewer / date: **Pending**.

## Later implementation and release gates

The A–I labels below match the design. They are not all spikes.

| Stage | Work still to do | Review boundary |
|---|---|---|
| C | Codec/fake worker, snapshots, backpressure, identities, prompt/cancel/EOF cases. | Protocol implementation and adversarial failure tests before real-client adoption. |
| D implementation | Role routing and retained parent-runtime/argv parity controls. | Boundary and compatibility review; source study alone does not complete D. |
| E | Real isolated EngineClient, session reducer/registry and one global lease. | End-to-end connect/scan/rows/diff/sync with identity and isolation controls. |
| F | Recovery, leave-scan disposal, cooperative/forced Sync Stop and cleanup-blocked behavior. | User behavior plus acknowledged cleanup and archive-maintenance exclusion. |
| G | Signed phase 1 qualification, production cutover and bake. | Explicit phase 1 acceptance before cutover/release; publishing remains separately approved. |
| H1 | Preparation/connect split and effective resource claims. | Claims, overlap and real-profile benefit qualified before raising capacity. |
| H2 | Concurrent scheduler and per-window CLI/prompt/quit routing. | Concurrency and stale-event isolation review. |
| I | Signed phase 2 failure/overlap/performance qualification and bake. | Explicit phase 2 acceptance before enabling production concurrency/release. |

- [ ] Re-estimate remaining effort after A and B produce their next reviewed results.
- [ ] Revisit the design's original phase 1/2 ranges with measurements; parallelism reduces elapsed time, not engineering effort automatically.

## Decisions and gate record

Fill in this table when a gate closes. Link the reviewed report and exact revision;
do not turn a local successful run into an accepted gate without review.

| Gate | Status | Evidence / revision | Decision, reviewer and date |
|---|---|---|---|
| G-A | Open | Pending controlled A fixture | Pending |
| A1 release decision | Conditional | No implementation | Pending; no release committed |
| G-B1 | Scope decided; qualification open | Component report and nine unread-PTY observations | Retain paused reading; reviewer concurrence relayed November 24. Actual bridge/password controls remain. |
| G-S | Open | Study not written | Pending |
| G-B2 | Open | Actual integration not implemented | Pending |
| G-C | Waiting | Contracts, study and baseline outstanding | Pending |
| Phase 1 acceptance | Later | Pending integrated qualification | Pending |
| Phase 2 acceptance | Later | Pending concurrency qualification | Pending |

## Evidence and update log

- [Design and effort ranges](engine-process-design.md)
- [Initial spike/incident intake](engine-process-spike-report.md)
- [Signed launch and TCC report](engine-process-signed-launch-tcc-report.md)
- [Transport and unread-PTY report](engine-process-transport-spike-report.md)
- [Unread-PTY evidence manifest](evidence/engine-transport-spike-2026-11-23/unread-pty-manifest.json)

| Date | Update | Effect on next work |
|---|---|---|
| 2026-11-24 | Adopted this two-lane working checklist; deferred C and broad baseline; combined D/phase 2 study. | A and B can proceed independently, with milestone reports. |
| 2026-11-24 | Unread-PTY stall reproduced and sampled; cleanup completes on resumed reads or owned-helper escalation. | Prompt-reading decision remains open; actual exit evidence is not a guarantee of immediate SSH exit. |
| 2026-11-24 | Prompt decision settled: paused reading stays in phase 1; separate reader deferred. Full-grace TERM/KILL teardown is expected in the stalled state. | Measure production-setting Cancel/teardown and qualify the actual bridge/password path; no new reader experiment. |
| 2026-11-24 | Aligned the design sequence and acceptance matrix with this checklist; moved model assignments to PR #244's description. | A requires no additional historical forensics; the broad baseline stays in a quiet session before C. |

At each milestone, update the dashboard, task boxes and gate record together.
Keep historical evidence intact; link a new result rather than overwriting the
record of a failed experiment. Update this log for decisions or scope changes,
not every commit.
