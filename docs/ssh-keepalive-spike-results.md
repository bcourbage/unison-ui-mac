# SSH keepalive — Phase-0 spike results (issue #55)

Status: **decided — not viable as a production "bounded active-work failure" feature.**
No runtime change, no `patches/` change, no blob rebuild. A rigorous, deterministic,
transport-level diagnostic (direct `ssh -vvv` evidence, structural archive isolation,
no GUI-timing dependence) resolved the earlier inconclusive results. Do **not** merge,
do **not** implement, do **not** close #55.

## Bottom line

- **Transport-level keepalive is reliable.** In an isolated CLI harness, `ServerAlive*`
  reliably terminates the SSH transport during clean scan and clean sync (and idle),
  on schedule, with direct protocol evidence.
- **But it does not deliver app-level recovery during an active scan.** In the real
  app, the keepalive *protocol* fires identically (probes sent, timeout printed) — yet
  the ssh child **does not exit**, because the OCaml bridge is wedged in the scan and
  does not drain ssh's stdout, so ssh blocks on teardown. The transport never dies, the
  engine never sees EOF, and the app **hangs** (no `restartRequired`).
- **Decision (per the review's rule):** keepalive is useful for *idle / dead-socket*
  detection, but is **insufficient to promise bounded failure during active scan**.
  #55 is **not** viable as a production feature, and no profile UI should be built
  around it.

## 1. Transport gate — CLI, isolated, confound-free (PASSES)

Method: CLI `unison` over a temp non-root sshd (:45872); **per-run unique archive dirs
on both sides** (remote via a `servercmd` wrapper + `SendEnv`/`AcceptEnv REMOTE_UNISON`);
`ssh -vvv -E` capturing the keepalive protocol (`type 80` = ServerAlive probe sent,
`type 81` = response); bidirectional PF blackhole applied **only after the phase was
positively identified**; window up to ~150 s. `ServerAliveInterval=5 CountMax=3`.

| Case | phase confirmation | death after block | probes (type 80) | responses (type 81) | "not responding" | SendQ at block |
|---|---|---|---|---|---|---|
| idle control (`sleep 60`) | n/a | 16.9 s | 3 | 0 | yes | 0 |
| clean scan #1 | "Looking for changes" | 16.3 s | 3 | 0 | yes | 0 |
| clean scan #2 | "Looking for changes" | 16.8 s | 3 | 0 | yes | 0 |
| clean sync #1 | partial file growing | 18.4 s | 3 | 0 | (died) | 144 |
| clean sync #2 | partial file growing | 19.4 s | 3 | 0 | (died) | 576 |

The transport-level result is repeatable and unambiguous. `SendQ` stayed tiny
throughout, so the earlier "full send buffer prevented keepalive counting" hypothesis
is **refuted**.

## 2. App-level — the decisive finding (recovery FAILS during active scan)

Same profile and `sshargs` as the passing CLI gate (keepalive verified present on the
app's own `-server` ssh child), archive-isolated, `-vvv -E` on the app's ssh child, app
launched detached with a PF-flush trap and a >120 s window.

- The app's ssh child, after the blackhole, sent **3 keepalive probes**, got **0
  responses**, and printed **"Timeout, server 192.168.2.35 not responding"** — the
  protocol fires **identically to the CLI**.
- **But the ssh child did not exit** (alive 30 s+ after the timeout; in a 170 s run the
  transport never died, the phase stayed `scanning`, no `restartRequired`, and the
  remote `unison -server` was orphaned).

**Mechanism.** The difference is *teardown coupling*, not keepalive. In the CLI, `unison`
continuously drains ssh's stdout, so ssh's post-timeout cleanup completes and it exits;
the client then sees EOF and unwinds. In the app, the OCaml bridge is wedged in the scan
(`select()`-blocked on RPC data that never arrives), so it does not drain ssh's stdout;
ssh blocks flushing its final output and does not exit. The transport therefore does not
die and the engine never observes EOF. This matches the connection-lifecycle conclusion
that a scan/sync wedged in `select()` **cannot be rescued in-process**; recovery is
quit+reopen or a timer-based watchdog — **not** ssh keepalive.

(For this scan case the app's `"Waiting for changes from server"` marker never latched,
so the 120 s scan-stall watchdog would not have fired either — the app would hang
indefinitely.)

## 3. What was NOT established (honest gaps)

- **App sync-loss was not re-tested with instrumentation this pass.** During an active
  transfer the bridge *is* draining ssh's stdout (receiving the file), so ssh may exit
  cleanly on keepalive timeout and the app may recover — the opposite of the scan case.
  Pass-1 observed an app sync-loss recovering at ~18 s, consistent with this, but that
  run was later flagged confounded, so treat app-sync recovery as **plausible but not
  firmly re-established**.
- **Same-process engine reuse was not tested.** Its precondition — reaching a clean
  `restartRequired` — does not occur via keepalive during scan (the app hangs), so the
  question is moot for that path. It was not otherwise exercised.
- `ConnectTimeout` (initial-connect) works, unchanged from earlier (separate mechanism).

## 4. Superseded / withdrawn

The first-pass "proven" verdict was withdrawn (archive-state confound). This pass then
showed the confound story was itself incomplete: with clean isolation the **CLI**
transport dies on schedule, but the **app** does not, for the teardown-coupling reason
above. All prior "quiescent / same-process reusable / reliably fires in the app"
statements remain **withdrawn**.

## 5. Decision & recommendation (item 8)

Keepalive detects a **dead socket / idle-peer** reliably and could shorten recovery for
those classes. It does **not** provide bounded failure recovery for the app during an
active scan, because ssh's exit is coupled to the wedged engine. Therefore:

- **Do not ship #55 as a production "bounded active-scan/sync failure" feature**, and do
  not build a per-profile keepalive UI around a guarantee it cannot keep for active work.
- If any keepalive value is pursued later, it is only for the **idle / dead-socket**
  class, and it must be paired with the real recovery path for wedged active work
  (quit+reopen / a timer watchdog), which is the existing `#33`/`#34` + 120 s watchdog
  direction — unchanged here.
- The genuinely useful, separable follow-up would be to fix the **app-side teardown
  coupling** (so a keepalive-killed ssh child actually unwinds the engine), which is a
  connection-lifecycle problem, not a keepalive feature.

Evidence: `~/u55-spike-evidence/diag/` (transport-gate summary, per-run `-vvv` logs and
timelines, and `DECISIVE-app-vs-cli.md`). Instrumentation was Debug-only (absent from
Release) and has been reverted. Stopping here for review.
