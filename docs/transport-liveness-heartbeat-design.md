# Feasibility spike: transport-liveness heartbeat (issue #41)

Status: **feasibility report, for review.** Supersedes the earlier "authoritative
heartbeat" design in this file. No blob rebuild, no `patches/` change, no
production behavior change was made for this spike. The verdict below narrows
#41's scope substantially and decouples it from #53.

Related: #33 (scan-stall status proxy, merged), #34 (sync-stall advisory,
merged), #53 (in-process interruption residual for non-direct transports), #55
(ssh keepalive), #24 (closed). See also `docs/scan-interruption-design.md`.

---

## 0. Summary of the correction

The original proposal claimed an **inbound-RPC-activity signal is an authoritative
liveness heartbeat** that would (a) make #34 fatal-actionable, (b) harden #33, and
(c) unlock interruption of non-direct transports (#53). The spike shows the core
premise is false:

> Inbound RPC silence does **not** mean the peer is dead, and inbound RPC activity
> does **not** prove it is healthy. A healthy remote doing CPU-bound work emits
> **the same wire signature as a frozen peer** (no application frames, socket open),
> because Unison's RPC runs on a **single cooperative Lwt scheduler** and a
> CPU-bound request handler that does not yield **monopolizes** that scheduler,
> starving the receive loop so it cannot read or answer anything, a ping included.

Consequences:

- An inbound-activity "heartbeat" cannot distinguish **busy-healthy** from **frozen**.
  Arming any *fatal* escalation on its staleness would false-positive on the exact
  case #33/#34 were deliberately kept conservative to protect (a slow-but-alive
  remote walk / throttled transfer).
- A genuine **active ping** does not rescue this. The receive loop *would* read a
  ping (the transport is not serial — Section 1a), but a CPU-bound handler that
  never yields holds the single scheduler thread, so the ping is neither processed
  nor answered until that handler returns — i.e., until the peer was going to become
  responsive anyway.
- #41 therefore **does not unlock #53.** A liveness signal, even a real one, can at
  most *detect* trouble. It cannot interrupt the bridge, reap a non-direct
  transport, or prove quiescence. Those remain #53's separate architecture.
- The one failure class a transport signal *can* detect is a **dead socket** (dead
  host / dead network / dead ssh process). ssh keepalive (#55) addresses part of
  that class and is safer than an app-layer trigger because its probes are answered
  by the remote **sshd**, independent of Unison application busyness. But keepalive
  is **not** a general answer: it only helps *after* SSH is established, it cannot
  see a frozen `unison -server` behind a live socket, and whether its socket close
  actually unwinds each bridge phase cleanly is **unproven** and is #55's central
  question, not a result of this spike.

Net: the "authoritative heartbeat" is not feasible as conceived. What remains is a
clean, smaller decomposition (Section 5), with the useful part scoped to #55.

---

## 1. What was tested

Two independent lines of evidence: the RPC transport source, and direct
observation of the named scenarios.

### 1a. Source study (`src/remote.ml`, pinned checkout)

The vendored engine is a compiled blob; `remote.ml` is fetched + patched at build
time. The pinned source establishes:

1. **The RPC is not strictly serial.** The receive loop (`receive conn`, near
   `remote.ml:1060`) reads a message, and for a `Request` it **dispatches the
   handler on a detached cooperative thread and immediately loops** to read the next
   message:

   ```ocaml
   Request cmdName ->
     receivePacket conn >>= (fun buf ->
     (* We yield before starting processing the request. *)
     Lwt.ignore_result
       (Lwt_unix.yield () >>= (fun () -> processRequest conn id cmdName buf));
     receive conn)
   ```

   Multiple outstanding replies are tracked in a `receivers` map keyed by message
   id. So **concurrent cooperative requests are possible**; there is no
   one-request-at-a-time serialization at the protocol level. (The only out-of-band
   frame is a write-permission token, id 0, for flow control. There is no
   ping / keepalive / heartbeat message type.)

2. **The decisive limitation is scheduler monopolization, not serialization.** Lwt
   is single-threaded cooperative. A request handler yields the scheduler only when
   it performs a blocking I/O through the remote module or calls `Lwt_unix.yield`.
   Update detection / a large local walk is **CPU-bound and does not yield**. Once
   such a handler is running, it holds the single OS thread to completion, so the
   `receive` loop's next socket read is never scheduled and any detached
   ping-handler never runs. The transport's own contract states this expectation:

   > "Threads behave in a very controlled way: they only perform possibly blocking
   > I/Os through the remote module, and never call `Lwt_unix.yield`."

3. `emittedBytes` / `receivedBytes` are updated per I/O syscall, so byte-level
   activity *is* observable — but per (2) that activity is absent precisely when the
   peer is busy, which is the ambiguous case.

The net for #41: an inbound-activity signal cannot tell "no frames because the peer
is dead" from "no frames because the peer is busy and not yielding." That refutes
the "authoritative" claim regardless of the serial/concurrent distinction.

### 1b. Scenario observations

| Scenario | App-layer inbound frames | Socket state | ssh keepalive verdict | Distinguishable from frozen? |
|---|---|---|---|---|
| **Healthy remote CPU work** (large `init2` walk) | **none** for tens of seconds (observed: ~63 s of static "Waiting for changes from server" on the 1M-file dataset) | open, ESTABLISHED | N/A (session established, no probe miss) | **No** |
| **Throttled transfer** | sparse, irregular | open | N/A | Only by *threshold guessing*; sparse-healthy ≈ dying |
| **Frozen `unison -server`** (SIGSTOP past remote-wait) | **none** | open (local ssh child stays alive — confirmed in the #51 matrix) | **alive** — session survived 20 s at a 6 s threshold while the remote app was SIGSTOP'd (measured this spike) | — |
| **Dead host / network, initial connect** (blackhole `192.0.2.1`) | none (never establishes) | connect hangs | **not applicable** — keepalive acts only after establishment; this is bounded by `ConnectTimeout`, not `ServerAliveInterval` | Yes, but via `ConnectTimeout`, a different mechanism |
| **Dead network, established session** | frames stop | probes stop being answered | keepalive *should* trip within `ServerAliveInterval × CountMax` — **but the resulting engine unwind is unproven (see §3, §6)** | Yes, in principle |
| **ControlMaster** | as per underlying phase | master persists as its own process | a *newly created* master can carry keepalive options; an *already-running* master uses its established config and a later multiplexed session cannot necessarily retrofit them | No (frozen-app blind spot unchanged) |

The measured keepalive result is the linchpin for the #55 comparison:

```
ssh -o ServerAliveInterval=3 -o ServerAliveCountMax=2   # ~6 s liveness threshold
  → remote app SIGSTOP'd at t+2s
  → ssh session still alive at t+20s   (exit 0)
```

`ServerAliveInterval` is an **SSH-protocol** probe answered by the remote **sshd**,
not a kernel TCP keepalive and not the frozen `unison -server` behind it. So
keepalive **cannot** detect a frozen application; at most it detects a socket whose
sshd stops answering. This is a useful property (no false positives from Unison
application busyness) but it means keepalive and the proposed app-heartbeat cover
*disjoint* failure classes, and **neither** covers the frozen-server case that
motivated the scan-interruption work.

---

## 2. Why "inbound activity = liveness" is unsound

The original §8 claimed the no-false-positive case would hold because "a healthy
scan/transfer keeps the heartbeat ticking." Section 1 refutes exactly this: a
healthy remote CPU walk produces **no** inbound frames (the handler is monopolizing
the scheduler), so an inbound-activity heartbeat goes stale on a healthy peer. The
signal's stale state is **one-to-many** ambiguous:

```
heartbeat stale  ⇒  { busy-healthy remote walk,  throttled transfer,
                      frozen unison-server,       dead socket }
```

Only the last element is a fault requiring recovery, and only the last is *also*
addressable more cheaply and more safely by keepalive. The three non-fatal members
are indistinguishable from the fatal one at the application byte layer. Escalating
on staleness would convert today's conservative, correct behavior into a
false-positive generator on slow-but-alive links.

## 3. Why an active ping does not fix it

Moving from passive observation to an active probe fails on the same architecture.
The receive loop *would* read a ping (Section 1a shows it is not blocked at the
protocol level), but the ping's handler, like every handler, runs on the single
cooperative scheduler thread. While a CPU-bound update-detection handler is running
without yielding, nothing else on that thread runs, so the ping is neither processed
nor answered until the busy handler returns. It adds cost and a callback on the hot
path while proving nothing the timeout did not already tell us. (An engine fork that
inserted real `Lwt_unix.yield` points into update detection could change this, but
that is a substantial change to the scheduler contract, well beyond #41's "small
heartbeat patch," and is not proposed.)

## 4. #33 / #34 must not go fatal on stale ordinary traffic

Directly per the review: the detectors must **not** be made fatal on the basis of
stale inbound activity. Section 2 is the reason: staleness cannot be attributed to
death without also catching busy-healthy and throttled peers. The current posture
is correct and should stand:

- **#33** stays a **conservative no-progress timeout** (120 s after `sawRemoteWait`)
  → `.restartRequired`. It is a *bounded-patience* policy, not a liveness claim, and
  is honest about that. The status-string coupling remains guarded by the vendor-bump
  checklist + the pre-release attended frozen-server test. This spike does not tighten
  it; nothing found here can.
- **#34** stays a **non-fatal advisory.** There is no signal that makes a
  propagation stall confidently fatal without false-positiving on throttled /
  callback-sparse transfers.

## 5. What is actually feasible (revised scope)

Decompose "is the peer alive?" into three failure classes and assign each the only
mechanism that can serve it:

| Class | Symptom | Detectable? | By what |
|---|---|---|---|
| **A. Dead socket** | dead host, dead network, dead ssh process | **Partly** — see the caveats | Initial connect: `ConnectTimeout`. Established session: ssh keepalive (#55) *may* trip, but the engine unwind is unproven (§3, §6). Answered by sshd, so independent of Unison app busyness. |
| **B. Frozen app, live socket** | `unison -server` wedged (SIGSTOP-like), socket healthy | **No** — invisible to keepalive (sshd still answers) *and* to app-heartbeat (busy ≡ frozen) | Only a **conservative no-progress timeout** (today's #33). Cannot be tightened by any liveness signal. |
| **C. Healthy-but-silent** | large CPU walk / throttled transfer | must **not** be flagged | leave alone; this is the false-positive hazard that constrains A and B |

This collapses #41 from "an authoritative heartbeat that hardens #33, makes #34
fatal, and unlocks #53" down to:

1. **Investigate ssh keepalive (#55) for the established-session part of class A** —
   a config/transport change, *no blob rebuild*. This is the plausibly useful, lower
   risk outcome, but its benefit is **not yet demonstrated** (§3, §6). Its adoption
   is a **separate decision** and a separate spike.
2. **Keep the conservative timeout for class B** — unchanged. Accept that a frozen
   peer behind a live socket is only ever detectable by bounded patience.
3. **Do nothing that escalates on class C.**

Note: the initial-connect blackhole that motivated #38's connect watchdog is bounded
by **`ConnectTimeout`**, not keepalive; keepalive does not apply before establishment.

## 6. ssh keepalive (#55): comparison and open questions

Keepalive is complementary to, not a substitute for, the timeout:

- **May cover:** the established-session part of class A (a network loss after SSH is
  up). It probes the SSH session, not the ssh process topology.
- **Does not cover:** class B (frozen app). The measured 20 s-survival-past-SIGSTOP
  result proves keepalive is blind here — sshd keeps answering.
- **Does not cover:** the initial-connect blackhole (that is `ConnectTimeout`).
- **Safety:** its probes are answered independent of Unison application busyness, so
  it does not false-positive on a busy peer. It is **not** literally "no false
  positives": an overloaded host or an unresponsive `sshd` can still miss probes and
  trip a `CountMax` disconnect on a link that was merely slow.
- **ControlMaster caveat:** a newly created master can be given keepalive options; an
  already-running master uses its established configuration, and a later multiplexed
  session cannot necessarily retrofit `ServerAliveInterval`.

**The central unproven claim (was asserted as fact in the earlier draft; now an open
question for #55):** that when a post-establishment blackhole trips keepalive, ssh
exits, the engine observes an inbound EOF / connection loss, and **each affected
bridge phase (connect, scan, sync) unwinds cleanly to a quiescent, restartable
state**. This spike did *not* demonstrate that. It only demonstrated that keepalive
ignores a frozen Unison child. Treat EOF → unwind → quiescence as #55's primary
experimental target.

Because of these caveats, adoption is a **separate decision** and #55 warrants its
own feasibility spike covering, at minimum:

- initial-connect blackhole vs established-session network loss;
- direct SSH, newly-created ControlMaster, already-running ControlMaster,
  ProxyCommand, and custom `sshcmd`;
- connect, scan, and sync bridge-unwind behavior on socket loss;
- child/process cleanup and safe same-process reuse afterward;
- conservative thresholds and precedence with user-supplied SSH options
  (`sshargs` / profile config must win).

## 7. #53 is not unlocked by #41

Explicit correction of the original §6c. Interrupting a non-direct transport
(ControlMaster / ProxyCommand / custom `sshcmd`) needs three things a liveness
signal does not provide:

1. **A way to interrupt the bridge** — the engine must leave the receive/compute
   loop. A signal that the peer is dead does not make a CPU-bound local half yield,
   nor does it unwedge a `select()`-blocked sync. (Prior work on this project
   established that a sync wedged in `select()` cannot be rescued in-process;
   recovery there is quit-and-reopen, tracked under the connection-lifecycle work in
   issue #6 / PR #5 / PR #7.)
2. **A way to reap the transport** — #51's mechanism is a SIGKILL of the *single
   tracked* ssh child. A ControlMaster channel or a proxy chain is not that child;
   there is no process to reap without new transport-topology bookkeeping.
3. **A proof of quiescence** — before restarting, the app must know the old
   transport has released its side. A liveness signal says "the peer stopped
   talking," which is the opposite of a quiescence proof.

#53 therefore needs its own interruption + reaping + quiescence architecture. #41,
even at its best, is orthogonal to all three.

## 8. Recommendation

1. **Retire the "authoritative heartbeat" framing of #41.** Reword the issue as an
   infeasible proposal under the current cooperative scheduler and close it with a
   precise disposition, superseded in part by #55.
2. **Start #55 (ssh keepalive) as its own feasibility spike** with the scope in §6.
   That is where any real value lies, and its central claim (EOF → clean unwind) is
   still to be proven.
3. **Keep #33 conservative and #34 advisory** (Section 4). No blob change here.
4. **Leave #53 decoupled** (Section 7).
5. No blob rebuild is warranted for #41 as originally scoped. If a future upstream
   bump *already* touches the transport for other reasons, the cheapest honest
   addition is a passive `receivedBytes` age accessor used **only** to help *shorten*
   class-A recovery, never to fabricate a class-B verdict — and even that is largely
   subsumed by keepalive's EOF once §6's unwind question is settled. Treat it as
   optional, not a flagship.

## 9. What this spike did not do

No `patches/` edit, no blob rebuild, no engine behavior change, no production code
change. Evidence is (a) the pinned `remote.ml`, (b) the retained #51 / #38 live
observations, and (c) one added measurement (ssh keepalive vs a SIGSTOP'd remote
app). It did **not** prove keepalive-triggered engine recovery on a real
post-establishment blackhole; that is #55's job. Deterministic re-validation of
#33/#34 is unchanged because their behavior is unchanged. The next action is a review
decision on Section 8, then, if accepted, a separately scoped #55 spike.
