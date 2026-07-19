# SSH-reaper: exact-child-PID registry + pure-C shutdown reaper

## Defect

The embedded engine spawns one `ssh` child per remote connection (`remote.ml`,
both the synchronous `buildShellConnection` and the async
`openConnectionStart`/`End`/`Cancel` path the macOS GUI uses). Normal OCaml
termination runs the `at_exit`-registered `end_ssh`, which reaps it. But the
AppKit host can terminate the process **without driving OCaml `at_exit`**:
`applicationWillTerminate → unison_bridge_shutdown` is a bounded C helper that
does not run `at_exit`. And a sync **wedged** on a frozen remote is blocked on
the transport socket, so closing fds does not make the child exit. The `ssh`
child then survives app exit as an orphan (observed alive t+19s…t+230s, ppid 1;
died only when the remote was killed).

## Contract (Option b — pure-C exact-child-PID registry)

Its guarantee depends on **no OCaml/Lwt progress at shutdown**. Three C
operations, all serialized by one leaf mutex:

- **`track(pid)`** — OCaml records the exact pid immediately after spawn.
  Deduplicated: a repeat `track` of the same pid is a no-op, so a single
  `retire` fully removes it. If the registry is already `closing`, or full, the
  pid can't be tracked and is `SIGKILL`ed at once (see cases below).
- **`retire(pid)`** — OCaml's teardown calls this **before** it
  `waitpid`/`close_session`s the child. Under the mutex, and **only while the
  pid is still registered**, it `SIGKILL`s the exact pid and removes it. The
  precise guarantee is not that the child has *exited* by the time `kill()`
  returns, but that **SIGKILL has been issued before the pid is removed**: the
  child is thereafter irrevocably terminating (SIGKILL can't be caught or
  blocked), and its pid stays reserved until the following `waitpid`. Idempotent:
  a second `retire` finds nothing and never signals.
- **`reap()`** — the pure-C shutdown pass. Under the mutex it sets `closing`,
  `SIGKILL`s every still-registered pid, then clears the set.

**Every `kill(2)` is issued while holding the mutex, before the pid is
removed.** No process enumeration, no name/command/host/pgroup matching — exact
registered pids only.

## Lifecycle invariant

> **I:** a pid is in the registry from immediately after `track` (spawn) until
> `retire`/`reap` removes it. Removal happens **only** in the same critical
> section that first `SIGKILL`s the pid. Therefore a registered pid always
> denotes a still-reserved child (un-reaped: OCaml only `waitpid`s a child
> *after* `retire` removed it), and a removed pid has already been sent
> `SIGKILL`.

There is deliberately **no** claim that closing stdio makes the child exit — a
wedged (or merely slow) child can stay alive after fd closure, which is exactly
why removal is coupled to `SIGKILL` rather than to "we asked it to stop".

## Adversarial proof

Let `C` be a transport child at any instant.

**No live-untracked window.** `C` leaves the registry only via `retire`/`reap`,
each of which `SIGKILL`s it in the same locked section that removes it. So the
transition "in registry" → "not in registry" is simultaneous with "signalled
with SIGKILL". There is no reachable state where `C` is running and absent from
the registry: while registered it is covered by `reap`; once removed it has
already been `SIGKILL`ed. (Contrast the earlier unregister-before-waitpid
design, where a child could be removed while still alive and then be missed by
a racing shutdown — that window is gone.)

**No PID-reuse signal.** A pid is `SIGKILL`ed only while it is present in the
registry (in `retire`/`reap`), and it is present only while un-reaped: OCaml
`waitpid`s a child strictly after `retire` has removed it under the mutex. So at
the moment of any `kill(2)`, the pid still denotes the exact intended child (or
its not-yet-reaped zombie — a harmless no-op). A concurrent OCaml `waitpid`
cannot free the pid mid-signal, because the signal and the removal are one
atomic mutex-held step, and OCaml cannot reach its `waitpid` until that step has
completed. `reap` likewise signals under the mutex, so it cannot race a
`retire` on the same pid.

**Spawn racing shutdown (`track` after `closing`).** If `track` runs after
`reap` set `closing`, the pid missed the shutdown pass, so `track` `SIGKILL`s it
immediately under the mutex — it cannot escape. The tiny window between
`create_process` returning and the very next `track` call (no blocking call
between) is covered separately: such a child is freshly forked with stdio wired
to the app and not yet wedged, so the imminent app exit closes its fds and it
dies; it cannot be a wedged orphan.

**Registry full.** If `MAX_TRANSPORT_CHILDREN` is exceeded, `track` cannot
record the pid, so it `SIGKILL`s it rather than leave an untracked child
running. (64 concurrent transport children is far beyond any real profile set.)

**Stopped / wedged child.** `SIGKILL` (never `SIGTERM`) is used everywhere: a
`SIGSTOP`ped or unresponsive child cannot catch, block, or indefinitely defer
it. `reap` does not `waitpid` (the process is exiting; `init` reaps the
transient zombies), so shutdown never blocks and there is no double-reap race.

**Idempotency.** `reap` clears the set, so a second `reap` (or a duplicate
`unison_bridge_shutdown`) is a no-op. `retire` on an already-removed pid is a
no-op (and, crucially, does not signal — so it can't hit a reused pid).

## CLI/GTK safety

`remote.ml` references the hooks only through `(int -> unit) ref` values that
default to no-ops; it declares no bridge symbols. The `external`s and the
`Remote.{register,retire}TransportChild := …` installs live in `uimacbridge.ml`,
compiled only into the macOS UI blob. CLI (`unison`, text UI) and GTK builds omit
`uimacbridge`, so they link with no bridge symbols and keep exactly the previous
`at_exit`/`close_session` behavior (verified: the text UI links with zero
`unison_bridge_*` symbols). On the macOS GUI, `retire` `SIGKILL`s the child on
normal teardown too; the pty is app-internal (no user terminal to restore), and
the remote server exits on the resulting connection drop as it would on any
close.
