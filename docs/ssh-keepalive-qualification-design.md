# Design: SSH keepalive qualification (issue #55)

Status: **design / qualification pass, for adversarial review.** No runtime change,
no `patches/` change, no blob rebuild, and **no live blackhole matrix yet**. This
document maps how the transport is built, decides where keepalive/connect options can
be applied *safely*, defines the fail-closed rule, and specifies the reduced
phase-specific spike matrix to run **after** this design is reviewed.

Inherits the actionable residue of #41 (closed infeasible): the only failure class a
transport signal can address is a **dead socket**, and ssh keepalive is the safer
tool for the *established-session* part of it. See
`docs/transport-liveness-heartbeat-design.md`.

Grounding: upstream `remote.ml` / `uimacbridge.ml` (pinned checkout) + the app's
existing SSH plumbing. File:line citations are to `unison-ui-mac/` unless noted
`unison/`.

---

## 1. How the SSH transport is actually built

**The app never builds the sync-time ssh command.** It writes Unison preferences
(`sshargs`, `sshcmd`, `servercmd`, the `ssh://` root) into a `.prf`, and the vendored
OCaml engine assembles and spawns the real `ssh`. The app builds ssh argv itself only
for two *read-only probes* (version check, `ssh -G` qualification), never for the
transport.

Engine assembly (`unison/src/remote.ml`, two near-identical sites:
`buildShellConnection` ~1864 and the `ConnectByShell` path ~2160). Both produce:

```
<sshcmd>  [-l user]  [-p port]  <host>  -e none  <sshargs>  <servercmd -server ...>
```

Consequences that drive this design:

- **The app's only lever on the real transport is the `sshargs` preference** (and
  `sshcmd`). There is no engine API for keepalive; everything must be expressed as
  tokens in `sshargs`. Proven mechanism: a profile already carries
  `-o ServerAliveInterval=30` in `sshargs` in the test corpus
  (`Tests/VersionCheckTests.swift:27`).
- **Unison has no transport-topology awareness.** It always spawns one `ssh <host>`.
  ControlMaster / ProxyCommand / ProxyJump / multiplexing are **not** things Unison
  constructs; they emerge entirely from the user's `ssh_config` (or from options the
  user themselves put in `sshargs`).
- **`sshargs` lands after `<host>`, but OpenSSH honors it anyway.** OpenSSH's bundled
  getopt permutes argv, so post-host `-o` options are applied (this is why Unison's
  own `-e none`, also after `<host>`, has worked for years). Verified on
  OpenSSH_10.2p1.
- **`sshargs` tokenization is whitespace-split with no shell quoting**
  (`VersionCheck.tokenizeSSHArgs`, `VersionCheck.swift:621`). Injected tokens must be
  space-delimited and quote-free; `-o ServerAliveInterval=30` satisfies this.

## 2. OpenSSH option precedence — and why `ssh -G` cannot drive auto-injection

Verified facts (OpenSSH_10.2p1):

| Fact | Evidence |
|---|---|
| **First-value-wins** among command-line `-o` | `-o …=5 -o …=9` → `5` |
| **Command line beats `ssh_config`** | command-line `-o` reflected in `ssh -G` regardless of config |
| Appending app `-o` after user `-o` → user wins | `-o …=42 -o …=15` → `42` |
| Defaults | `ssh -G`: `serveraliveinterval 0`, `serveralivecountmax 3`, `connecttimeout none`, `controlmaster false` |

**Blocking correction (was "detect-then-skip"): `ssh -G` reports an effective value,
not its provenance.** It cannot distinguish:

- the **default** `ServerAliveInterval 0`, from
- a user **explicitly** setting `ServerAliveInterval 0` to *disable* keepalive.

Likewise `ConnectTimeout none`. So "inject when `ssh -G` shows the default" would
**override an explicit user choice to disable it**. There is no read-only probe that
recovers provenance. The only safe options are therefore:

1. **explicit user opt-in** (a visible per-profile setting the user turns on), or
2. **never inject automatically.**

**Automatic, invisible injection is not safe** and is removed from this design. The
precedence facts above still matter for one thing only: *if* a user opts in, the
visible `sshargs` they see must be exactly what runs, and any keepalive token they
themselves wrote must win — which "append after user tokens" (first-wins) preserves.

## 3. Qualification gate (OpenSSH **and** Unison-profile uncertainty)

Two independent sources of uncertainty must both fail closed:

- **OpenSSH config.** Reuse `SSHTransportQualifier`
  (`Sources/App/SSHTransportQualifier.swift`): it runs `ssh -G <args> <host>`
  (bounded, SIGTERM→SIGKILL reaped) and fails closed on a custom `sshcmd`, incomplete
  `ssh -G` output, or a set `ControlMaster` / `ControlPath` / `ProxyCommand` /
  `ProxyJump` (`classify`, 217–235). It resolves `ssh_config` + `Include` + `Match`.
- **Unison profile.** `ssh -G` does **not** resolve Unison's own `include` / `source`
  directives, nor duplicate/overriding effective `sshargs` within a profile tree. The
  design must **also** reuse the fail-closed rules in
  `ScanInterruptQualification.plan` (`Sources/App/ScanInterruptQualification.swift`),
  which already assembles the profile's effective port + `sshargs` and gates on
  Unison-side uncertainty.

**`Match exec` remains a genuine TOCTOU** that no probe can close: `ssh -G` cannot
prove what a future `Match exec` will evaluate to at connect time. Fail closed on it
(the qualifier already treats uncertain `ssh -G` as unsupported); accept that as a
deliberate limitation.

Only a profile that both qualifiers deem a **plain, direct, single-child OpenSSH
transport** is eligible for keepalive at all.

## 4. Fail-closed rule

Keepalive is a **direct-SSH-only** capability. For every fail-closed case the app does
nothing and relies unchanged on the existing app-level watchdogs (60s connect / 120s
scan → `.restartRequired`). Per transport:

- **All ControlMaster configurations — fail closed, unconditionally.** A reused client
  "reuse[s] the master instance's network connection" (ssh_config(5)); the master owns
  the transport, so keepalive on the client is inert and the app cannot observe the
  master's health via its own child. A *new* master introduces a `ControlPath`-socket
  race the app cannot observe at spawn. Both stay fail-closed; do not special-case a
  new master.
- **ProxyCommand / ProxyJump — fail closed.** Keepalive *might* reach the target, but
  the app tracks only the **outer** ssh child pid and the reaper SIGKILLs exact pids
  only; proxy/jump descendants are not guaranteed reaped. **Descendant cleanup is a
  separate #53-adjacent reaper issue, not #55**, and is out of scope here.
- **custom `sshcmd` — fail closed.** Opaque wrapper.

**Overarching principle:** keepalive is at most an optimization that shortens class-A
(dead-socket) recovery on a qualified direct-SSH transport. The 60s/120s watchdogs
remain the backstop in every case, and keepalive never covers the frozen-server class
(#41).

## 5. There is no current session-scoped injection point

**Blocking correction.** `do_unisonInit1` (`unison/src/uimacbridge.ml:237`) calls
`Prefs.loadTheFile()` (255) and then **immediately** `Remote.openConnectionStart r`
(283) — profile load and transport spawn happen back-to-back inside one
`doInOtherThread`. The `SSHTransportQualifier` also begins alongside `init1`. So there
is **no window** in which Swift can apply an extra preference between profile load and
transport spawn. A genuine session-only override would require a **new pre-connect
coordinator phase plus a bridge/blob API** to set `sshargs` after load and before
`openConnectionStart`.

**Do not fall back to a hidden `.prf` mutation** (surprising, persistent, and it would
silently appear in the user's own `sshargs`).

Because of this, **the spike itself does not inject anything.** It uses **dedicated
throwaway profiles that contain explicit `sshargs`** (keepalive / `ConnectTimeout`
written by hand). Product injection is designed **only after** the spike proves the
mechanism has value — and then only as one of the two safe forms in §8.

## 6. ConnectTimeout vs keepalive: separate mechanisms, separate tests

- **`ConnectTimeout`** bounds **only pre-establishment**: the TCP connection **plus the
  SSH handshake / key exchange** — **not** interactive authentication. Default `none`.
  Governs the **initial-connect** fault. The app already has a 60s connect watchdog
  (`handleConnectTimeout`, `AppDelegate.swift:1875`) that forces `.restartRequired` but
  does not touch the ssh child; a `ConnectTimeout` in a throwaway profile makes the
  ssh child self-exit at the bound.
- **`ServerAliveInterval` × `CountMax`** bounds **only post-establishment silence**.
  Governs **established-session network loss**. Default `0` (off).

They do not overlap; separate matrix rows.

## 7. Reduced Phase-0 spike matrix (throwaway profiles; run after review)

Scope: **only the supported direct-SSH transport is fault-injected.** For every
unsupported transport, the spike proves **qualification refusal deterministically** and
does **not** characterize its descendants live.

### Faults

- **A. Initial-connect fault** (`ConnectTimeout`, pre-establishment): connect to a
  **dedicated unreachable endpoint/port** whose reachability is controlled by a
  **narrowly scoped PF anchor** that cannot affect the user's own manual SSH sessions.
  Do **not** assume `192.0.2.1` is a silent blackhole (it may fail immediately rather
  than hang). Expect: ssh child self-exits at ~`ConnectTimeout`; otherwise the 60s
  connect watchdog fires.
- **B. Established-session network loss** (keepalive, post-establishment): establish,
  then drop the established flow via the same scoped PF anchor (never a global rule).
  Expect: ssh self-exits at ~`interval × countmax`; pipe EOF → engine unwind. Run at
  **connect, scan, and sync**.
- **C. Frozen `unison -server`** (SIGSTOP, negative control): keepalive does **not**
  fire (proven in #41). Expect the 120s scan watchdog to backstop. Confirms no
  regression and no false reliance on keepalive.

### Evidence per cell — three distinct outcomes, not one pass/fail

`engineIsQuiescent` is a **driver assertion, not an engine report**, and must not be
used as the quiescence proof. Capture and **classify** each cell into one of:

1. **Transport exits on schedule** — tracked pid absent (`ps`/`sysctl`), exit
   signal/status, and *time-to-exit* vs the expected threshold (distinguishes
   keepalive/ConnectTimeout-driven exit from a watchdog-driven restart).
2. **Engine unwinds but requires restart** — coordinator reaches `.restartRequired`
   cleanly (no deadlock/SIGTRAP), the exact operation is terminal, child reaped, locks
   released. **This is a useful keepalive outcome on its own.**
3. **Engine proves reusable in-process** — additionally, a fresh open of the same
   profile on the **same app process** completes connect + scan (the close→reopen
   invariant, issue #6 / PR #5 / PR #7).

**Same-process reuse is not mandatory for every cell** — restart-required is an
acceptable, valuable result. The quiescence evidence set is: **exact operation
terminal + close acknowledgement where applicable + child reap + released locks +
successful same-process reopen** (the last only for outcome 3), captured from the app
debug log, `ps`/`sysctl`, and `lsof` — not from a driver flag.

### Cell plan

- **Direct SSH (supported)** × **{A at connect; B at connect, scan, sync; C at scan}**
  — the entire fault-injection set, each cell classified into outcome 1/2/3.
- **ControlMaster (any) / ProxyCommand / ProxyJump / custom `sshcmd`** — assert
  **deterministic qualification refusal** (no spawn of a fault-injected transport, no
  keepalive). No live descendant characterization.

### Tooling / environment

`ssh -G` for effective config; a **scoped PF anchor + dedicated endpoint/port** for
faults A/B (must not touch the user's manual SSH); `lsof` / `ps` / `sysctl` for child
+ fd + lock state; the app debug log for phase, EOF (`lostConnection` / drain,
`patches/0003`), and terminal-routing markers; the reusable 120s-watchdog rig from the
#51 live matrix. Drive the **app** (not CLI `unison`, a GUI app on the test host).
Client = Heracles, server = Demeter (Demeter sudo needs a password; PF is applied on
the **client**).

## 8. Recommendation

1. **No automatic, invisible injection** (§2). If the spike proves value, the safe
   production forms are exactly two:
   - an **explicit per-profile keepalive setting** that **visibly updates `sshargs`**
     (the user sees and owns the tokens), or
   - a **separate bridge/blob proposal** for a true **session-scoped** override (new
     pre-connect coordinator phase + API, §5).
2. **Qualify with both gates** — `SSHTransportQualifier` (OpenSSH) **and**
   `ScanInterruptQualification.plan` (Unison profile) — and **fail closed** on all
   ControlMaster, ProxyCommand/Jump, custom `sshcmd`, `Match exec`, and any uncertain
   resolution (§3, §4).
3. **Handle `ConnectTimeout` separately** as a pre-establishment complement to the 60s
   connect watchdog (§6).
4. **Do not weaken #33/#34.** Keepalive never covers the frozen-server class (#41).
5. **Prove before promising.** The value claim (established-loss → ssh exit → EOF →
   clean terminal/restart, sometimes in-process reuse) is unproven; the reduced spike
   (§7) is the test. Adopt nothing — mechanism or defaults — before it.

## Revised sequence (per review)

1. **Amend PR #60** with these corrections.
2. **Merge the docs** after exact-head green CI.
3. **Run the reduced Phase-0 matrix** (§7) using explicit throwaway-profile options:
   `ConnectTimeout` initial-connect fault; established-flow loss during connect, scan,
   and sync; frozen-server negative control; classify each by child exit, terminal
   routing, cleanup, and restart/reuse outcome.
4. **Stop for review** before choosing any production mechanism (§8).

## 9. Open questions for the reviewer

- **`Match exec` TOCTOU** (§3): fail-closed-on-`Match exec` is the current stance — is
  that acceptable, or is a connect-time re-check wanted despite its cost?
- **Session-override API** (§5): is a new pre-connect coordinator phase + bridge/blob
  API worth building for an invisible session override, or is the explicit-visible
  per-profile setting the preferred production form outright?
- **Default thresholds**: deliberately left open, to be justified by the spike against
  the worst healthy *socket-idle* interval (not the app-frame-silent interval, since
  sshd answers keepalive regardless of Unison busyness).
- **ProxyCommand descendant cleanup**: confirmed out of scope for #55 and routed to a
  separate #53-adjacent reaper issue — should that issue be filed now or after the
  spike?

## 10. What this pass did not do

No runtime change, no `patches/`/blob change, no live matrix. Empirical work was
limited to non-connecting `ssh -G` option-precedence probes (§2) and a read of the
engine + bridge + app transport code. The next step is adversarial review of this
design, then — only if accepted — the reduced §7 spike, then a stop for review before
any production mechanism.
