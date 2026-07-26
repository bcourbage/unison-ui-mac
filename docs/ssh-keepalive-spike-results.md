# SSH keepalive — Phase-0 spike results (issue #55)

Status: **transport-positive, app-inconclusive → #55 will not be implemented.** No
runtime change, no `patches/` change, no blob rebuild. A deterministic transport-level
diagnostic (direct `ssh -vvv` evidence, structural per-side archive isolation) gave a
repeatable positive result at the SSH transport layer, but did **not** establish
bounded failure recovery in the application. A user-facing feature cannot promise
behavior the application did not demonstrate, so #55 is a **no-go** as a production
keepalive feature. Do not merge for implementation; this PR records the disposition.

## Bottom line

- **CLI transport behavior is repeatably positive.** In an isolated CLI harness,
  `ServerAlive*` reliably terminates the SSH transport during clean scan, clean sync,
  and idle, on schedule, with direct protocol evidence.
- **App-level bounded recovery is not established.** In the real app the keepalive
  *protocol* was observed to fire, but the app did not reach an error or
  `restartRequired` within the observation window, and the post-timeout process/bridge
  state was not resolved by the monitoring used.
- **Decision:** keepalive is a demonstrated positive for *idle / dead-socket* SSH, but
  its value for *active* Unison work in the app is **unproven**. #55 will **not** be
  implemented, and no per-profile keepalive UI will be built. `#33`/`#34` + the 120 s
  watchdog remain the recovery path, unchanged.

## 1. Transport gate — CLI, isolated (repeatably positive)

Method: CLI `unison` over a temp non-root sshd (:45872); **per-run unique archive dirs
on both sides** (remote via a `servercmd` wrapper + `SendEnv`/`AcceptEnv REMOTE_UNISON`);
`ssh -vvv -E` capturing the keepalive protocol (`type 80` = ServerAlive probe sent,
`type 81` = response); bidirectional PF blackhole applied **only after the phase was
positively identified**; window up to ~150 s. `ServerAliveInterval=5 CountMax=3`.

| Case | phase confirmation | ssh child exit after block | probes (type 80) | responses (type 81) | "not responding" | SendQ at block |
|---|---|---|---|---|---|---|
| idle control (`sleep 60`) | n/a | 16.9 s | 3 | 0 | yes | 0 |
| clean scan #1 | "Looking for changes" | 16.3 s | 3 | 0 | yes | 0 |
| clean scan #2 | "Looking for changes" | 16.8 s | 3 | 0 | yes | 0 |
| clean sync #1 | partial file growing | 18.4 s | 3 | 0 | (exit observed) | 144 |
| clean sync #2 | partial file growing | 19.4 s | 3 | 0 | (exit observed) | 576 |

Here the tracked ssh child process actually exited (`kill -0` began failing) on schedule.
`SendQ` stayed tiny throughout, so the earlier "full send buffer prevented keepalive
counting" hypothesis is **refuted**.

## 2. App-level — what was actually observed (inconclusive)

Same profile and `sshargs` as the CLI gate; the app's own `-server` ssh child was
verified established and carrying `ServerAliveInterval`; `-vvv -E` on that child; app
launched detached with a PF-flush trap; observation window 170 s.

**Observed (facts):**
- The app's exact transport ssh child emitted **three keepalive probes** (`type 80`),
  received **zero responses** (`type 81`), and printed OpenSSH's terminal
  **"Timeout, server 192.168.2.35 not responding"** message.
- The app nevertheless **remained in `.scanning`** and did **not** reach an error or
  `restartRequired` during the full **170 s** observation.
- `remoteWaitLatched` remained **false** (the app's `"Waiting for changes from server"`
  marker never appeared; only `"Looking for changes"`).
- The remote `unison -server` process was still listed at the end of the run.

**Not resolved (limits of the monitoring):**
- The process monitor (`kill -0` / `pgrep`) **did not distinguish a running child from a
  zombie / unreaped child**, and the final `pgrep` lookup for the transport was empty.
- Therefore the **exact post-timeout process and bridge state is unresolved**: it is not
  established whether the ssh child was still running, exiting, or a zombie, nor what the
  OCaml bridge was doing. The remote server still being listed does **not** by itself
  prove the local ssh child was alive.

**Interpretation (explicitly not proven):** an earlier draft of this document narrated a
specific mechanism (ssh blocked flushing stdout because the OCaml bridge was
`select()`-blocked and therefore not draining the pipe, i.e. an "app-side teardown
coupling" defect). That narrative is **superseded inference**, not evidence — the
monitoring above cannot support it. It is not asserted here and no defect is claimed.
See the correction note in the evidence directory.

## 3. Untested (and, given the no-go, not to be tested)

- **App sync-loss** was not re-tested with instrumentation this pass.
- **Same-process engine reuse** was not tested (its precondition — reaching a clean
  `restartRequired` during scan — was not observed).

These are recorded as gaps only. Once the conservative no-go decision is made they are
**unnecessary**, and no further live testing is requested.

## 4. `ConnectTimeout` (separate, positive)

`ConnectTimeout` bounds the initial-connect case (ssh stuck `SYN_SENT`, exits at the
configured timeout) and was demonstrated positively. It is a **separate mechanism** from
`ServerAlive*`; the no-go on ServerAlive-based active-work recovery does **not** bear on
`ConnectTimeout`.

## 5. Disposition

- CLI scan/sync/idle transport behavior is repeatably positive.
- App-level bounded recovery during active work is **not established**.
- A user-facing feature cannot promise behavior the application did not demonstrate.
- **Therefore #55 will not be implemented** — no runtime change, no per-profile keepalive
  UI. `#33`/`#34` + the 120 s watchdog remain the recovery path.

Evidence: `~/u55-spike-evidence/diag/` (transport-gate summary, per-run `-vvv` logs and
timelines, and `DECISIVE-app-vs-cli.md` with its correction note). Instrumentation was
Debug-only (verified absent from Release) and has been reverted. Recorded for review.
