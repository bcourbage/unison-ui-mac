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
> **exactly the same wire signature as a frozen peer** (no application frames,
> socket open), because Unison's RPC transport runs on a single global cooperative
> Lwt scheduler and its request handlers, by design, never yield mid-computation.

Consequences:

- An inbound-activity "heartbeat" cannot distinguish **busy-healthy** from **frozen**.
  Arming any *fatal* escalation on its staleness would false-positive on the exact
  case #33/#34 were deliberately kept conservative to protect (a slow-but-alive
  remote walk / throttled transfer).
- A genuine **active ping** does not rescue this: a CPU-bound `unison -server`
  cannot service or answer an out-of-band request until it returns to the receive
  loop, so the ping is stuck behind the very work whose liveness it was meant to
  probe.
- #41 therefore **does not unlock #53.** A liveness signal, even a real one, can at
  most *detect* trouble. It cannot interrupt the bridge, reap a non-direct
  transport, or prove quiescence. Those remain #53's separate architecture.
- The one failure class a transport signal *can* detect reliably is a **dead
  socket** (dead host / dead network / dead ssh process). That is precisely
  ssh keepalive's job (#55), and keepalive is the safer mechanism because the OS /
  sshd answer its probes independently of the application, so it does not
  false-positive on a busy peer. But keepalive equally **cannot** see a frozen
  `unison -server` behind a live socket.

Net: the "authoritative heartbeat" is not feasible as conceived. What remains is a
clean, smaller decomposition (Section 5).

---

## 1. What was tested

Two independent lines of evidence: the RPC transport source, and direct
observation of the five scenarios the review named.

### 1a. Source study (pinned upstream 2.54.0 `src/remote.ml`)

The vendored engine is a compiled blob; `remote.ml` is fetched + patched at build
time (`patches/0003…`, `0004…`). The upstream source at the pinned tag establishes:

1. **The RPC is strictly serial request/response** over one connection. Each
   request carries a message id; a single `receivers` map matches a reply to its
   id. There is **no pipelining and no concurrent second request** in flight.
2. **A single receiver loop** (`receive conn`) reads and dispatches every inbound
   frame, bound together with Lwt's `>>=`. It is cooperative, not preemptive.
3. The only out-of-band frame is a **write-permission token** (message id 0) used
   for flow control. There is **no ping / keepalive / heartbeat message type** and
   no side channel that could carry one.
4. **Decisive:** request handlers are documented to run to completion without
   yielding. The transport's own comment:

   > "Threads behave in a very controlled way: they only perform possibly blocking
   > I/Os through the remote module, and never call `Lwt_unix.yield`."

   So while the server computes a reply (update detection, a CPU-bound walk), the
   Lwt scheduler is **not** running the receiver loop. The socket is not read. Any
   inbound frame, including a hypothetical ping, waits until the handler returns.
5. `emittedBytes` / `receivedBytes` are updated per I/O syscall, so byte-level
   activity *is* observable — but per (4) that activity is absent precisely when
   the peer is busy, which is the ambiguous case.

### 1b. Scenario observations

| Scenario | App-layer inbound frames | Socket state | ssh keepalive verdict | Distinguishable from frozen? |
|---|---|---|---|---|
| **Healthy remote CPU work** (large `init2` walk) | **none** for tens of seconds (observed: ~63 s of static "Waiting for changes from server" on the 1M-file dataset) | open, ESTABLISHED | alive (kernel/sshd answer) | **No** |
| **Throttled transfer** | sparse, irregular | open | alive | Only by *threshold guessing*; sparse-healthy ≈ dying |
| **Frozen `unison -server`** (SIGSTOP past remote-wait) | **none** | open (local ssh child stays alive — confirmed in the #51 matrix, e.g. child PID persisted through the SIGSTOP) | **alive** — keepalive survived 20 s with a 6 s threshold while the remote app was SIGSTOP'd (measured this spike) | — |
| **Dead host / network** (blackhole `192.0.2.1`) | none (never establishes, or EOF mid-stream) | connect hangs / RST / silent drop | **fails** within `ServerAliveInterval × CountMax` → this is keepalive's true positive | Yes, but this is the *dead-socket* class, not the frozen-app class |
| **ControlMaster** | as per underlying phase | master persists as its own process | probes the master socket; a frozen `unison -server` channel behind a live master is still invisible | No (same blind spot) |

The measured keepalive result is the linchpin for the #55 comparison:

```
ssh -o ServerAliveInterval=3 -o ServerAliveCountMax=2   # ~6 s liveness threshold
  → remote app SIGSTOP'd at t+2s
  → ssh session still alive at t+20s   (exit 0)
```

ssh keepalive is answered by the remote **sshd / OS**, not by the frozen
`unison -server` behind it. So keepalive **cannot** detect a frozen application; it
detects a dead *socket*. This is a feature (no false positives on a busy peer), but
it means keepalive and the proposed app-heartbeat cover *disjoint* failure classes,
and **neither** covers the frozen-server case that motivated the scan-interruption
work.

---

## 2. Why "inbound activity = liveness" is unsound

The original §8 claimed the no-false-positive case would hold because "a healthy
scan/transfer keeps the heartbeat ticking." Section 1 refutes exactly this: a
healthy remote CPU walk produces **no** inbound frames, so an inbound-activity
heartbeat goes stale on a healthy peer. The signal's stale state is
**one-to-many** ambiguous:

```
heartbeat stale  ⇒  { busy-healthy remote walk,  throttled transfer,
                      frozen unison-server,       dead socket }
```

Only the last element is a genuine fault requiring the connection object, and only
the last is *also* detectable more cheaply and more safely by keepalive. The three
non-fatal members are indistinguishable from the fatal one at the application byte
layer. Escalating on staleness would convert today's conservative, correct
behavior into a false-positive generator on slow-but-alive links.

## 3. Why an active ping does not fix it

Moving from passive observation to an active probe fails on the same architecture.
An out-of-band ping would have to be (a) *sent* — but the client's own write side is
governed by the same single scheduler and the write-permission token, and (b)
*answered by the server* — but a CPU-bound server is not in the receive loop to see
it (Section 1a, point 4). The ping is enqueued behind the in-flight handler and is
answered only when the server was going to become responsive anyway. It adds cost
and a callback on the hot path while proving nothing the timeout did not already
tell us. (An engine fork that inserted real `Lwt_unix.yield` points into update
detection could change this, but that is a substantial upstream-scale change to the
scheduler contract, well beyond #41's "small heartbeat patch," and is not proposed.)

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
| **A. Dead socket** | dead host, dead network, dead ssh process | **Yes, safely** | **ssh keepalive (#55)** — `ServerAliveInterval`/`CountMax`. Answered below the app, so no false positive on a busy peer. Surfaces as connect failure or inbound EOF. |
| **B. Frozen app, live socket** | `unison -server` wedged (SIGSTOP-like), socket healthy | **No** — invisible to keepalive (socket up) *and* to app-heartbeat (busy ≡ frozen) | Only a **conservative no-progress timeout** (today's #33). Cannot be tightened by any liveness signal. |
| **C. Healthy-but-silent** | large CPU walk / throttled transfer | must **not** be flagged | leave alone; this is the false-positive hazard that constrains A and B |

This collapses #41 from "an authoritative heartbeat that hardens #33, makes #34
fatal, and unlocks #53" down to:

1. **Adopt ssh keepalive (#55) for class A** — a config/transport change, *no blob
   rebuild*. This is the genuinely useful, low-risk outcome. Its adoption remains a
   **separate decision** (Section 6), but the spike finds no obstacle and a clear
   benefit: it bounds the "ssh feels hung forever" firewall-drop case that motivated
   #38's connect watchdog, at the socket layer, without touching engine internals.
2. **Keep the conservative timeout for class B** — unchanged. Accept that a frozen
   peer behind a live socket is only ever detectable by bounded patience.
3. **Do nothing that escalates on class C.**

## 6. ssh keepalive (#55): comparison and the separate decision

Keepalive is complementary to, not a substitute for, the timeout:

- **Covers:** class A (dead socket) — including the ControlMaster master connection
  and non-direct transports, because it probes the socket, not the ssh process
  topology.
- **Does not cover:** class B (frozen app). The measured 20 s-survival-past-SIGSTOP
  result proves keepalive is blind here by design.
- **Safety:** no false positives on class C, because the probe is answered by the
  peer OS/sshd regardless of application busyness. This is strictly safer than an
  app-layer staleness trigger.
- **Interaction with the timeout:** when keepalive *does* close a dead socket, the
  engine sees an inbound EOF / connection loss, which unwinds through the existing
  `lostConnection` / drain path (`patches/0003`) faster than the 120 s timeout would.
  So keepalive mostly *shortens* class-A recovery; it never makes class B or C worse.

Adoption is a **separate decision** because it carries its own trade-offs (choosing
`ServerAliveInterval`/`CountMax`; interaction with `ControlPersist`; whether to set
it via `sshargs` per-profile or globally; and confirming it does not clip a
legitimately slow class-C link — its threshold must sit above the worst healthy
*socket-idle* interval, which is *not* the same as the app-frame-silent interval,
since the kernel keepalive is answered regardless). Recommended as the next step
**after** this report is accepted, scoped as a #55 change, not folded into #41.

## 7. #53 is not unlocked by #41

Explicit correction of the original §6c. Interrupting a non-direct transport
(ControlMaster / ProxyCommand / custom `sshcmd`) needs three things a liveness
signal does not provide:

1. **A way to interrupt the bridge** — the engine must leave the receive/compute
   loop. A signal that the peer is dead does not make a CPU-bound local half yield,
   nor does it unwedge a `select()`-blocked sync (see
   [[unison-ui-mac-connection-lifecycle]]: a sync wedged in `select()` cannot be
   rescued in-process; recovery is quit+reopen).
2. **A way to reap the transport** — #51's mechanism is a SIGKILL of the *single
   tracked* ssh child. A ControlMaster channel or a proxy chain is not that child;
   there is no process to reap without new transport-topology bookkeeping.
3. **A proof of quiescence** — before restarting, the app must know the old
   transport has released its side. A liveness signal says "the peer stopped
   talking," which is the opposite of a quiescence proof.

#53 therefore needs its own interruption + reaping + quiescence architecture. #41,
even at its best, is orthogonal to all three.

## 8. Recommendation

1. **Retire the "authoritative heartbeat" framing of #41.** Reword the issue to
   reflect Sections 0–5: an inbound-activity heartbeat is not authoritative and does
   not unlock #34-fatal, #33-hardening-beyond-the-string-guard, or #53.
2. **Promote #55 (ssh keepalive) to the actionable follow-up for class A**, as its
   own scoped change with the threshold analysis in Section 6. This is where the
   real, low-risk value is.
3. **Keep #33 conservative and #34 advisory** (Section 4). No blob change here.
4. **Leave #53 decoupled** (Section 7).
5. No blob rebuild is warranted for #41 as originally scoped. If a future upstream
   bump *already* touches the transport for other reasons, the cheapest honest
   addition is a passive `receivedBytes` age accessor used **only** to *shorten*
   class-A recovery (EOF surfaced sooner), never to fabricate a class-B verdict —
   and even that is largely subsumed by keepalive's EOF. Treat it as optional, not a
   flagship.

## 9. What this spike did not do

No `patches/` edit, no blob rebuild, no engine behavior change, no production code
change. Evidence is (a) the pinned upstream `remote.ml`, (b) the retained #51 / #38
live observations, and (c) one added measurement (ssh keepalive vs a SIGSTOP'd
remote app). Deterministic re-validation of #33/#34 is unchanged because their
behavior is unchanged. The next action is a review decision on Section 8, then, if
accepted, a separately scoped #55 spike.
