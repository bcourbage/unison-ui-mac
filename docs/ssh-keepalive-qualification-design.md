# Design: SSH keepalive qualification (issue #55)

Status: **design / qualification pass, for adversarial review.** No runtime change,
no `patches/` change, no blob rebuild, and **no live blackhole matrix yet**. This
document maps how the transport is built, decides where keepalive/connect options
can be applied *safely*, defines the fail-closed rule, and specifies the
phase-specific live matrix to run **after** this design is reviewed.

Inherits the actionable residue of #41 (closed infeasible): the only failure class a
transport signal can address is a **dead socket**, and ssh keepalive is the safer
tool for the *established-session* part of it. See
`docs/transport-liveness-heartbeat-design.md`.

Grounding: upstream `remote.ml` (pinned checkout) + the app's existing SSH plumbing.
File:line citations are to `unison-ui-mac/` unless noted `unison/`.

---

## 1. How the SSH transport is actually built

**The app never builds the sync-time ssh command.** It writes Unison preferences
(`sshargs`, `sshcmd`, `servercmd`, the `ssh://` root) into a `.prf`, and the
vendored OCaml engine assembles and spawns the real `ssh`. The app builds ssh argv
itself only for two *read-only probes* (version check, `ssh -G` qualification),
never for the transport.

Engine assembly (`unison/src/remote.ml`, two near-identical sites:
`buildShellConnection` ~1864 and the `ConnectByShell` path ~2160). Both produce:

```
<sshcmd>  [-l user]  [-p port]  <host>  -e none  <sshargs>  <servercmd -server ...>
```

Consequences that drive this design:

- **The app's only lever on the real transport is the `sshargs` preference**
  (and `sshcmd`). There is no engine API for keepalive; everything must be
  expressed as tokens in `sshargs`. Proven: a profile already carries
  `-o ServerAliveInterval=30` in `sshargs` in the test corpus
  (`Tests/VersionCheckTests.swift:27`).
- **Unison has no transport-topology awareness.** It always spawns one
  `ssh <host>`. ControlMaster / ProxyCommand / ProxyJump / multiplexing are **not**
  things Unison constructs; they emerge entirely from the user's `ssh_config` (or
  from options the user themselves put in `sshargs`). So "new/existing
  ControlMaster, ProxyCommand" are environmental, not app-controlled.
- **`sshargs` lands after `<host>`, but OpenSSH honors it anyway.** OpenSSH's
  bundled getopt permutes argv, so post-host `-o` options are applied (this is why
  Unison's own `-e none`, also after `<host>`, has worked for years). Verified on
  OpenSSH_10.2p1: `ssh -G localhost -o serveraliveinterval=222` → `222`.
- **`sshargs` tokenization is whitespace-split with no shell quoting**
  (`VersionCheck.tokenizeSSHArgs`, `VersionCheck.swift:621`). Any injected tokens
  must be space-delimited and quote-free. `-o ServerAliveInterval=30` satisfies this
  (each token has no internal space); a value requiring quoting is out of scope.

## 2. OpenSSH option precedence (verified, OpenSSH_10.2p1)

| Fact | Evidence | Design impact |
|---|---|---|
| **First-value-wins** among command-line `-o` | `-o …=5 -o …=9` → `5` | To let a user override, the app's injected `-o` must come **after** the user's on the line. |
| **Command line beats `ssh_config`** | command-line `-o` reflected in `ssh -G` regardless of config | A blind command-line inject would **override** a user's `ssh_config` keepalive: a "respect user options" violation unless gated. |
| Appending app `-o` after user `-o` → user wins | `-o …=42 -o …=15` → `42` | Gives a clean "respect explicit `sshargs`" mechanism. |
| Defaults | `ssh -G`: `serveraliveinterval 0`, `serveralivecountmax 3`, `connecttimeout none`, `controlmaster false` | Unset by default, so a conservative inject is meaningful; but "unset" must be *detected*, not assumed. |

**The precedence trap and its resolution.** Because command-line beats `ssh_config`,
naive injection would silently override a user who set `ServerAliveInterval` in
`~/.ssh/config`. The app cannot read `~/.ssh/config` directly — **but it can read the
*effective* value via `ssh -G`** (which resolves `ssh_config` + `Include` + `Match` +
any `sshargs` passed as probe args). So the safe rule is **detect-then-skip**, not
inject-and-override:

> Run `ssh -G <profile args> <host>`; read effective `serveraliveinterval` /
> `serveralivecountmax` / `connecttimeout`. Inject **only** the keys the user has
> **not** already set (effective interval `0` / connecttimeout `none`). If the user
> set any, respect it verbatim and inject nothing for that key.

This sidesteps first-wins entirely (we never emit a competing `-o`) and honors the
user's config *and* their `sshargs`.

## 3. The qualification gate (reuse `SSHTransportQualifier`)

The app already has the right gate: `SSHTransportQualifier`
(`Sources/App/SSHTransportQualifier.swift`), built for scan-interruption (#24). It
runs `/usr/bin/ssh -G <extraArgs> <host>` (bounded, SIGTERM→SIGKILL reaped, 5s
deadline) and **fails closed** to `.unsupported` on any of: a custom `sshcmd`
(short-circuit, no spawn); incomplete `ssh -G` output; or a set `ControlMaster` /
`ControlPath` / `ProxyCommand` / `ProxyJump` (`classify`, lines 217–235). It honors
`~/.ssh/config` because it reads effective config, not raw `sshargs` strings.

Keepalive qualification should **reuse this same classifier** (it is not yet wired
into the open path per its own header, so both features converge on wiring it once),
extended to also extract effective `serveraliveinterval` / `serveralivecountmax` /
`connecttimeout` for the detect-then-skip rule. The applicability decision:

| Effective config (from `ssh -G`) | Keepalive decision |
|---|---|
| Plain direct SSH, no master/proxy, interval `0` | **Inject** conservative `ServerAliveInterval`/`CountMax` (and `ConnectTimeout` if `none`) into the session `sshargs`. |
| Plain direct SSH, interval already non-zero | **Respect user; inject nothing** for that key. |
| `ControlMaster` not `false`, or `ControlPath` set | **Fail closed** (Section 4). |
| `ProxyCommand` / `ProxyJump` set | **Fail closed** (Section 4). |
| custom `sshcmd`, or `ssh -G` incomplete/uncertain | **Fail closed.** |

## 4. Fail-closed rule (transports the app cannot reliably configure or observe)

Keepalive is a **direct-SSH-only optimization**. For every fail-closed case the app
injects nothing and relies unchanged on the existing app-level watchdogs (60s connect
/ 120s scan → `.restartRequired`). Rationale per transport:

- **Existing ControlMaster.** A reused client "reuse[s] the master instance's network
  connection" (ssh_config(5)); the master owns the transport, so
  `ServerAliveInterval` on the reused client does not govern TCP liveness and is
  effectively inert. The app also cannot observe the master's health via its own
  child. → no keepalive claim.
- **New ControlMaster.** If *this* invocation creates the master, its keepalive
  *would* govern, but whether the app's ssh is the master-creator or a client is a
  `ControlPath`-socket race the app cannot observe at spawn time. → treat as
  unknown, fail closed.
- **ProxyCommand / ProxyJump.** Keepalive is protocol-level and *may* reach the
  target, but (a) the app tracks only the **outer** ssh child pid
  (`registerTransportChild`), and the reaper SIGKILLs exact pids only — a
  `ProxyCommand` subprocess / jump chain is **not guaranteed reaped**
  (`VersionCheck.swift:336,372`; `SSHTransportQualifier` 146–148); and (b)
  distinguishing a dead proxy from a dead target is unproven. → fail closed until the
  live matrix demonstrates clean teardown.
- **custom `sshcmd`.** Opaque wrapper; the app cannot reason about its option
  handling. → fail closed.

**Overarching principle:** keepalive is an *optimization that shortens class-A
recovery when it provably applies*, never the sole mechanism. The 60s/120s watchdogs
remain the backstop in every case, including direct SSH (keepalive can only make
class-A recovery faster/cleaner, never replace the frozen-server 120s path from #41).

## 5. Injection mechanism: session-scoped, not `.prf` mutation

The app must **not** rewrite the user's `.prf` to add keepalive (surprising,
persistent, and it would show up in the user's own `sshargs` field). Instead compose
the effective `sshargs` **for the engine session only**: read the profile's
`sshargs` (`ProfileDocument.firstValue(forKey:"sshargs")`), append the injected
tokens, and hand that to the engine as the session's `sshargs` preference without
touching the file.

**Open design question (flag for review / resolve in impl):** confirm the bridge can
set the `sshargs` preference *after* profile load and *before* connect (Unison
supports setting `sshargs` as a preference; the app currently writes it only via the
`.prf`). If session-scoped override is not cleanly supported, the fallback is a
transparent, clearly-labeled managed token in the `.prf` — less desirable. The live
matrix must verify whichever path is chosen actually reaches the engine's argv (via
the `remote.ml` debug "Shell connection:" line).

## 6. ConnectTimeout vs keepalive: separate mechanisms, separate tests

They do not overlap and must be validated independently:

- **`ConnectTimeout`** bounds **only pre-establishment** (TCP connect + banner/auth);
  default `none`. It governs the **initial-connect blackhole** (the #38 scenario).
  The app already has a 60s connect watchdog (`handleConnectTimeout`,
  `AppDelegate.swift:1875`) that forces `.restartRequired` but does **not** touch the
  ssh child. A `ConnectTimeout` inject is a transport-level complement that makes the
  ssh child self-exit at the bound.
- **`ServerAliveInterval` × `CountMax`** bounds **only post-establishment silence**.
  Governs **established-session network loss**. Default `0` (off).

The two faults get separate matrix rows (Section 7); never conflate "connect hangs"
with "established link dropped."

## 7. Phase-specific live matrix (to run after review)

Three faults × three phases × the transport set, pruned by applicability. Each cell
must capture the **exact evidence** columns below; a cell "passes" only with all six.

### Faults (clean separation)

- **A. Initial-connect blackhole** (pre-establishment): route to a SYN-dropped host
  (`192.0.2.1`, TEST-NET-1). Expect: with `ConnectTimeout=N` injected, the ssh child
  self-exits at ~N; otherwise the app's 60s connect watchdog fires. *Not* a keepalive
  test.
- **B. Established-session network loss** (post-establishment): establish, then drop
  the established flow (e.g. a `pfctl` block on the connection's 5-tuple; requires
  sudo on the test Mac). Expect: with keepalive injected, ssh self-exits at
  ~`interval × countmax`; pipe EOF → engine unwind. This is keepalive's core proof.
- **C. Frozen `unison -server`** (SIGSTOP, socket alive): keepalive does **not** fire
  (proven in #41: 20s survival at a 6s threshold). Expect the 120s scan watchdog to
  be the backstop. Confirms no regression and no false reliance on keepalive.

### Phases

- **connect** (init0/init1/init2, pre-`ready`)
- **scan** (post-`sawRemoteWait`, in update detection)
- **sync** (propagation)

### Transports

T1 direct SSH · T2 new ControlMaster · T3 existing ControlMaster · T4 ProxyJump (`-J`)
· T5 ProxyCommand · T6 custom `sshcmd` wrapper.

### Exact evidence per cell (all six required)

1. **ssh child exit** — tracked pid absent (`ps`/`sysctl`), exit signal/status, and
   *time-to-exit* vs the expected threshold (distinguishes keepalive-driven exit from
   watchdog-driven restart).
2. **pipe EOF at the engine** — engine observes connection loss on the pipe
   (`lostConnection` / drain path, `patches/0003`); captured via the engine debug log
   and the `receivedBytes` stall→EOF transition.
3. **bridge unwind** — coordinator phase transition is clean (→ `.restartRequired` or
   a clean terminal fail), no deadlock, no SIGTRAP, no wedged Lwt.
4. **child cleanup** — no zombie beyond OCaml's `waitpid`; **no orphaned descendant**
   (the decisive column for T5/T4: the reaper misses proxy/jump subprocesses); process
   table clean; `retireTransportChild` ran (direct) or the child self-exited
   (keepalive/connect-timeout).
5. **quiescence** — engine reports idle (`engineIsQuiescent`), archives not mid-write,
   no half-open fds (`lsof` on the app process), lock files released.
6. **same-process reuse** — a fresh open of the same profile on the **same app
   process** completes connect + scan (the close→reopen invariant from issue #6 /
   PR #5 / PR #7).

### Pruned cell plan (not a full 3×3×6)

- **T1 × {A, B, C} × {connect, scan, sync}** — the core keepalive proof set. (Fault A
  is largely phase-independent; run it once at connect.)
- **T3 (existing master) × B × scan** — prove keepalive is *ineffective* here, the
  watchdog backstops, and reaping the tracked client child does **not** kill the
  master (evidence: master persists; is that correct/desired?).
- **T5 (ProxyCommand) × B × scan** and **T4 (ProxyJump) × B × scan** — characterize
  the **orphaned proxy/jump subprocess** the exact-pid reaper misses (column 4).
- **T2 (new master) × B × scan** — determine empirically whether the app's ssh is the
  master-creator and whether its keepalive governs; decide if T2 can ever leave
  fail-closed.
- **T6 (custom sshcmd) × qualify** — assert fail-closed (no spawn, no injection).

### Tooling / environment

`ssh -G` for effective config; `pfctl` for the established-flow drop (sudo on the
test Mac); `lsof` / `ps` / `sysctl` for child + fd state; the app debug log for phase
+ EOF markers; the reusable 120s-watchdog rig from the #51 live matrix. Drive the
**app** (not CLI `unison`, which is a GUI app on the test host per project notes).
Client = Heracles, server = Demeter (Demeter sudo needs a password;
`pfctl` on the *client* is where the established-flow drop is applied).

## 8. Recommendation

1. **Adopt keepalive as a bounded, direct-SSH-only optimization**, gated by
   `SSHTransportQualifier` (Section 3), using **detect-then-skip** to respect any user
   `ServerAliveInterval` / `ConnectTimeout` from `ssh_config` *or* `sshargs`
   (Section 2), injected **session-scoped** (Section 5).
2. **Fail closed** (no keepalive; watchdogs backstop) for existing/new ControlMaster,
   ProxyCommand, ProxyJump, custom `sshcmd`, and any uncertain `ssh -G` (Section 4).
3. **Handle `ConnectTimeout` separately** as a pre-establishment complement to the
   existing 60s connect watchdog (Section 6).
4. **Do not weaken #33/#34.** Keepalive never covers the frozen-server class; the 120s
   scan watchdog remains authoritative there (#41).
5. **Prove before promising.** The central claim — established-loss → ssh exit → pipe
   EOF → clean unwind → quiescence → same-process reuse — is **unproven** and is the
   live matrix's job (Section 7). Adoption of defaults (the exact `interval`/`countmax`
   / `connecttimeout` values) is a decision to make **after** the matrix, not now.

## 9. Open questions for the reviewer

- **Session-scoped `sshargs` override** (Section 5): is post-load pref-setting cleanly
  available through the bridge, or must we fall back to a managed `.prf` token?
- **`ssh -G` TOCTOU**: effective config at qualification may differ from connect if the
  user uses `Match exec` or time-varying directives. The qualifier already treats
  uncertainty as unsupported; is fail-closed-on-`Match exec` acceptable, or do we want
  a re-check at connect?
- **Default thresholds**: propose conservative starting points (e.g.
  `ServerAliveInterval=15`, `ServerAliveCountMax=3` → ~45s; `ConnectTimeout=~30s`) —
  but these must be justified by the matrix against the worst healthy *socket-idle*
  interval (which is not the app-frame-silent interval, since sshd answers keepalive
  regardless of Unison busyness). Values are deliberately left open here.
- **T2 (new master)**: is it worth the complexity to ever treat a new master as
  keepalive-eligible, or should all ControlMaster stay fail-closed for simplicity?
- **ProxyCommand orphan** (column 4, T5): if the matrix confirms orphaned proxy
  subprocesses, is that a #55 concern or a separate reaper-scope issue (#53-adjacent)?

## 10. What this pass did not do

No runtime change, no `patches/`/blob change, no live blackhole matrix. Empirical work
was limited to non-connecting `ssh -G` option-precedence probes (Section 2) and a
read of the engine + app transport code. The next step is adversarial review of this
design, then — only if accepted — the Section 7 live matrix.
