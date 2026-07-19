# SSH-reaper: exact-child-PID registry + pure-C shutdown reaper

## Defect (recap)

The embedded engine spawns one `ssh` child per remote connection
(`remote.ml:buildShellConnection`). Normal OCaml termination runs the
`at_exit`-registered `end_ssh`, which reaps it. But the AppKit host can
terminate the process **without driving OCaml `at_exit`**:
`applicationWillTerminate → unison_bridge_shutdown` is a bounded C helper that
only releases OCaml roots; it does not run `at_exit`. And a sync **wedged** on a
frozen remote is blocked on the transport socket, not on stdio, so closing the
stdio pipes does not wake the child. The `ssh` child then survives app exit as
an orphan (observed alive t+19s…t+230s, ppid 1; died only when the remote was
killed).

## Design (Option b from the reviewed assessment)

A **pure-C, mutex-protected, exact-child-PID registry**, consumed by C during
`unison_bridge_shutdown`. Its guarantee depends on **no OCaml/Lwt progress at
shutdown**.

- OCaml `remote.ml` calls two overridable hooks (default no-ops, so CLI/GTK
  builds link and behave unchanged): `registerTransportChild pid` immediately
  after a successful spawn, `unregisterTransportChild pid` strictly before the
  OCaml reap on every teardown path. The macOS bridge (`uimacbridge.ml`)
  installs the real hooks, which call the C registry.
- C keeps a fixed array of exact pids under a leaf mutex plus a `closing` flag.
  `unison_bridge_reap_transport_children()` (called first thing in
  `unison_bridge_shutdown`, pure C) atomically flips `closing` + detaches the
  set under the mutex, then `SIGKILL`s the snapshot **outside** the mutex.
- **No process enumeration** — no name/command/host/pgroup matching. Only exact
  registered pids, and only while still un-reaped.
- `SIGKILL` (not `SIGTERM`): a stopped/wedged child may defer or never act on
  `SIGTERM`; `SIGKILL` cannot be caught, blocked, or deferred.
- C does **not** `waitpid` at shutdown: the process is exiting, so `init` reaps
  the transient zombies. This keeps shutdown non-blocking and avoids a
  double-reap race with a concurrent OCaml `waitpid`.

## Lifecycle invariant

> **I:** a pid is in the registry from immediately after spawn until strictly
> before its `waitpid`. `unregister` precedes `waitpid` on every path, and is
> itself preceded by the child being placed on its death path (connection/stdio
> closed). Registration happens under the C mutex; a register that arrives after
> `closing` is refused and the child `SIGKILL`ed at once.

## Adversarial proof: no window leaks a running child, no reused pid is killed

Consider child `C` at the instant the shutdown reaper runs its atomic
detach+`closing` step. Cases:

1. **Spawned, registered, no teardown started** (live sync, or wedged): `C ∈`
   snapshot → `SIGKILL`. ✓ killed.
2. **Teardown in progress on thread `T`** (`clientCloseRootConnection →
   cleanup`), which does *(close connection/stdio) → unregister → waitpid*:
   - reaper detaches **before** `T`'s unregister → `C ∈` snapshot → `SIGKILL`;
     `T`'s later unregister is a no-op (set consumed), `T`'s `waitpid` reaps the
     killed child. ✓ killed.
   - reaper detaches **after** `T`'s unregister → `C ∉` snapshot, but `T`
     unregistered ⟹ the connection/stdio were already closed ⟹ `C` is on its
     death path. A child reaching normal `cleanup` is **responsive** (a wedged
     connection never takes the normal-close path; its recovery is
     quit→shutdown, i.e. case 1), so `C` dies from fd closure. ✓ dies anyway.
3. **Just forked, not yet registered** (between `create_process` returning and
   the very next `registerTransportChild` call — no blocking call in between):
   `C ∉` snapshot. But `C` just forked with stdio connected to the app; the
   imminent app exit closes those fds and `C` (not yet wedged — no bytes
   exchanged) dies from EOF. ✓ dies anyway. Window shrunk to a few
   non-blocking instructions.
4. **Register races `closing`**: the register hook, under the mutex, sees
   `closing` and refuses to store; it `SIGKILL`s the just-spawned pid at once. ✓
   killed, cannot escape.
5. **Already reaped** (teardown completed pre-shutdown): unregister-before-
   waitpid removed `C` while it was still reserved; after `waitpid` the pid may
   be reused, but `C ∉` registry, so the reaper never targets it. ✓ no
   wrong-kill.

**PID-reuse safety:** a pid is in the registry only while un-reaped (reserved by
the OS), because unregister strictly precedes `waitpid`. Any pid the reaper
`SIGKILL`s therefore still denotes the exact child (or its not-yet-reaped
zombie — a harmless no-op), never a reused unrelated process.

**Why not reap-first-then-unregister:** that would retain a pid after `waitpid`
makes it reusable; a reaper racing between `waitpid` and unregister could
`SIGKILL` a reused, unrelated pid. Rejected.

**Idempotent shutdown:** the atomic detach empties the set; a second reaper call
(or a duplicate `unison_bridge_shutdown`) finds nothing → no-op.

## CLI/GTK safety

`remote.ml` references the hooks only through `(int -> unit) ref` values that
default to no-ops; it declares no bridge symbols. The `external`s and the
`Remote.registerTransportChild := …` install live in `uimacbridge.ml`, compiled
only into the macOS UI blob. CLI (`unison`, text UI) and GTK builds omit
`uimacbridge`, so they link with no bridge symbols and keep exactly the previous
`at_exit`-based behavior.
