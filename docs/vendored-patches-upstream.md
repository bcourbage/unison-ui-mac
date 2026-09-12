# Vendored Unison patches — upstream-contribution reference

Details of every local patch applied to the vendored Unison engine, with an
explicit **additive-only** verdict per patch (does it only *add* lines, or does
it also modify/remove existing upstream lines?). Additive-only patches are the
lowest-risk to land upstream; patches that change existing lines need closer
review.

## Baseline

| Field | Value |
| --- | --- |
| Upstream | `bcpierce00/unison` **v2.54.0**, commit `91421d0617b0fb543c0eee51bcb4d4791d8b0631` (`v2.54.0-19-g91421d0`, `origin/master`) |
| Toolchain | OCaml 5.5.0 (pinned) |
| Apply mechanism | `scripts/apply-unison-patches.sh` (idempotent, per-patch dry-run detection); series in `patches/` |
| Already upstreamed | `0001-uimacbridge-register-abortAll` — **merged** as [PR #1198](https://github.com/bcpierce00/unison/pull/1198) (commit `2429c6c`), retired from this series. Precedent that the series-based flow works. |

## Summary

| Patch | Files (added / removed) | Additive only? | Scope | Upstream candidate |
| --- | --- | --- | --- | --- |
| 0002 closeConnection | `uimacbridge.ml` (+51 / −0) | **Yes** | macUI bridge | Low (macUI-only) |
| 0003 close-and-drain | `remote.ml` (+36/−0), `remote.mli` (+17/−0), `test.ml` (+96/−0), `uicommon.ml` (+4/−13) | **No** | general engine | **High** |
| 0004 transport-child reaper | `remote.ml` (+41/−0), `remote.mli` (+11/−0), `uimacbridge.ml` (+10/−0) | **Yes** | general hooks + macUI policy | Medium (hooks half) |
| 0005 sync-completion snapshot | `uimacbridge.ml` (+11/−2) | **No** | macUI bridge | Low (macUI perf) |
| 0006 register-lock | `uimacbridge.ml` (+59/−0) | **Yes** | macUI bridge | Low (macUI-only) |
| 0007 session-argv parser | `ubase/uarg.ml` (+82/−21), `ubase/uarg.mli` (+11/−0), `ubase/prefs.ml` (+28/−0), `ubase/prefs.mli` (+9/−0) | **No** | general engine (CLI parser) | Medium (backward-compatible, general) |
| 0008 session-argv bridge | `uimacbridge.ml` (additive + first-load contract) | **No** | macUI bridge | Low (macUI-only) |
| 0009 session-args extraction | `ubase/prefs.ml` (+~35/−0), `ubase/prefs.mli` (+~15/−0), `uimacbridge.ml` (+~6/−0) | **Yes** | general engine + macUI bridge | Low–Medium |

Four of the eight are strictly additive (0002, 0004, 0006, 0009). The four
non-additive ones each change a small, well-scoped piece of existing code (see
below); 0007's `uarg.ml` change is a behavior-preserving refactor, and 0008's
non-additive part is the first-load parse contract (both documented below).

---

## 0002 — `uimacbridge-register-closeConnection`

- **Additive only: YES** — `src/uimacbridge.ml` +51 / −0. Pure new callback
  registration; touches no existing lines.
- **What:** registers a `closeConnection` OCaml callback so the macUI bridge can
  cleanly tear down an established remote connection when the user leaves a
  profile (closes the connection's channels, unregisters it, drains). Issue #6.
- **Upstream relevance:** the bridge file is macUI-only, so this matters upstream
  only if the native macUI is to gain connection teardown. Depends on 0003's
  engine primitive.
- **Upstream-readiness (generalization in progress):** the exception-handler
  diagnostic emits a fork-neutral `closeConnection: <error>`; the downstream
  `unison-mac:` prefix is dropped. Any remaining downstream-specific elements are
  to be reviewed before 0002 is offered upstream. Tracked in `TODO.md`.

## 0003 — `remote-close-and-drain`

- **Additive only: NO.** Three files are purely additive — `src/remote.ml`
  (+36/−0), `src/remote.mli` (+17/−0), `src/test.ml` (+96/−0) — but
  **`src/uicommon.ml` is +4 / −13**: it *replaces* the existing inline
  post-close drain loop (the `loop_yield` + `for … Transport.maxThreads () …
  Lwt_unix.run` block) with a single call to the newly-added
  `Remote.drainDroppedConnectionThreads ~rounds:(Transport.maxThreads ())`.
  So the net change is a **refactor-extract**: existing behavior moved into a
  named, reusable `remote.ml` function, plus the new drain semantics.
- **What:** adds `Remote.drainDroppedConnectionThreads` and drives it from the
  close paths so a closed connection's dormant Lwt receiver thread cannot resume
  inside the *next* connection's `Lwt_unix.run` (issue #8).
- **Ships a test:** `src/test.ml` gains a no-network connection-lifecycle test
  (an ssh-replacement shell wrapper; Unix-only) — exactly the evidence upstream
  review expects.
- **Upstream relevance: HIGH.** Genuine engine-correctness fix in shared,
  non-GUI code, with a self-test. The strongest standalone contribution. Note
  for the PR: the `uicommon.ml` hunk is a behavioral change to a shared code
  path, so call it out explicitly rather than burying it under "additive".

## 0004 — `remote-transport-child-reaper`

- **Additive only: YES** — `src/remote.ml` (+41/−0), `src/remote.mli` (+11/−0),
  `src/uimacbridge.ml` (+10/−0). All hunks add lines; no existing line changed.
- **What:** adds overridable `Remote.register/retireTransportChild` hooks
  (**default no-ops**, so CLI/GTK behavior is unchanged); the macUI bridge sets
  them to track the exact transport (ssh) child PID at spawn and, at teardown,
  SIGKILL + remove it under a mutex before reaping. Design: `docs/ssh-reaper-design.md`.
- **Upstream relevance:** cleanly separable. The **hook mechanism in
  `remote.ml`/`.mli` is general and additive with no-op defaults** — plausibly
  upstreamable on its own. The PID-tracking *policy* lives in the macUI bridge
  and is macUI-specific.

## 0005 — `uimacbridge-sync-completion-snapshot`

- **Additive only: NO** — `src/uimacbridge.ml` +11 / −2. It **changes the
  signature of an existing `external`**: `syncComplete : unit -> unit` becomes
  `syncComplete : stateItem array -> unit`, and updates the one call site
  (`syncComplete ()` → `syncComplete !theState`). The other +lines are an
  explanatory comment.
- **What:** `syncComplete` now carries the final post-sync `stateItem array` so
  the bridge marshals ONE bulk completion snapshot (each row's final progress +
  details) in a single call, instead of the UI making O(n) per-row
  `unisonRiToDetails` round-trips at completion (Finding #10). Reuses
  already-registered accessors; no new OCaml allocation.
- **Upstream relevance: LOW.** A macUI-bridge performance change, and it alters
  a bridge external's ABI — only relevant if upstream evolves the native macUI.

## 0006 — `uimacbridge-register-lock`

- **Additive only: YES** — `src/uimacbridge.ml` +59 / −0. Pure new callback
  registration; touches no existing lines.
- **What:** registers a NARROW per-archive lock capability —
  `Callback.register "unisonLockAcquire" / "unisonLockRelease" /
  "unisonLockIsLocked"`. Each takes ONLY a validated 32-char lowercase-hex
  archive hash and builds `Util.fileInUnisonDir ("lk" ^ hash)` in OCaml over the
  raw `Lock` module (`src/lock.ml`), so the app's archive-mutation transaction
  can acquire the very `lk<hash>` a live Unison uses. The C/Swift side can never
  pass an arbitrary path or a wrong prefix, and `is_locked` is diagnostic-only.
- **Upstream relevance: LOW.** macUI-bridge-only surface; matters upstream only
  if the native macUI is to coordinate with the engine's per-archive locks. The
  underlying `Lock` module it wraps is already upstream.

## 0007 — `uarg-prefs-session-argv`

- **Additive only: NO** — `ubase/uarg.ml` +82/−21, `ubase/uarg.mli` +11/−0,
  `ubase/prefs.ml` +28/−0, `ubase/prefs.mli` +9/−0. The `uarg.ml` hunk factors the
  existing `parse` loop into a shared `parseCore` that raises `ParseError` instead
  of exiting; `parse` keeps its old behavior by catching that and doing the same
  print-and-exit (the removed lines reappear verbatim inside the new `parse`), so
  it is a **behavior-preserving refactor plus two additions**. Everything else is
  additive.
- **What:** adds `Uarg.parseArgv` (parse an explicit per-session argument vector,
  raising `Uarg.Bad` instead of exiting, leaving `Uarg.current` untouched) and
  `Prefs.parseCmdLineArgs` (the session-request counterpart of `parseCmdLine`:
  the engine's own option specs, arity, list accumulation, and precedence, fed a
  request's argument vector, raising `Util.Fatal` on bad input). This is what lets
  a graphical session apply its own `-path`/scalar/boolean/alias options without
  reproducing the option semantics in Swift and without exiting the process on a
  bad argument.
- **Evidence:** the parser variant was prototyped and compared against unmodified
  upstream (independent reference build) on `-path` (`CUSTOM`), repeated-list,
  CLI-versus-profile precedence, whitespace, and error exit/stdout/stderr; see
  `docs/cli-session-parser-report.md` and `docs/spikes/`.
- **Upstream relevance: MEDIUM.** General, non-GUI engine code; fully
  backward-compatible (existing `parse`/`parseCmdLine` unchanged). A raising,
  vector-taking parse entry point is plausibly useful upstream, though it is
  motivated here by the macUI session model.

## 0008 — `uimacbridge-session-argv`

- **Additive only: NO** — `src/uimacbridge.ml`. Adds a `sessionArgs` option ref,
  the store-only `unisonSetSessionArgs` callback, a test-only `connectSetupCount`
  and its read callback, and inside `do_unisonInit1` both a `Prefs.parseCmdLineArgs`
  apply and a counter bump. It also **changes the existing first-load parse
  block** so the legacy `Prefs.parseCmdLine` runs only when no explicit session
  arguments were supplied (see the contract below), so the two override sources
  cannot compete.
- **What:** gives the app a per-session option channel. Swift stores the current
  session's argument vector via the callback (which touches no preference), and
  `do_unisonInit1` applies it through 0007's parser on **every** (re)load — so a
  reconnecting rescan re-applies the session's scope, and a queued request cannot
  mutate an active session (storing is separate from applying). A bad argument
  raises before `openConnectionStart`, so a failed apply never begins a connection
  or scan; the next load resets clean.
- **First-load contract (why it is not additive):** `sessionArgs` is an OPTION.
  `None` means no explicit session arguments were supplied, so the legacy
  process-argv parse is preserved (first load only). `Some v` (even empty) means
  the caller owns this session's options: the process argv is **not** also parsed
  (avoiding double-counted list prefs and leaked launch options), and `v` is
  applied. The driver leaves it `None` only on the very first connect of the
  process when the session has no explicit overrides (so a launch command line is
  still honored); every later load sets `Some` (an empty vector resets), so no
  scope leaks between sessions.
- **`connectSetupCount`** is a monotonic counter bumped where `do_unisonInit1`
  reaches root validation + connection setup, i.e. strictly after session
  arguments are applied. It is read only through a test bridge accessor
  (`unison_bridge_test_connect_setup_count`) to prove a failed argument apply
  started no connection or scan.
- **Upstream relevance: LOW.** macUI-bridge-only surface; depends on 0007.

## 0009 — `cmdline-session-args-extraction`

- **Additive only: YES.** `ubase/prefs.ml` adds `isCliOnly` and
  `commandLineSessionArgs`; `ubase/prefs.mli` exposes them; `uimacbridge.ml`
  registers `unisonCommandLineSessionArgs`. No existing line changes.
- **What:** extracts a command line's SESSION-scoped options — the
  profile-settable ones, i.e. **not `cli_only`** — as an ordered argv suitable
  for `parseCmdLineArgs` (0007). The app delivers a launch's own options to its
  first session this way, instead of relying on the engine's first-load parse of
  the process argv.
- **Reuses the engine's own machinery:** it drives `argspecs` + `Uarg.parseArgv`
  (no separate arity table or argv parser). Each option's registered spec both
  consumes its value and dictates how the token is re-emitted; `cli_only` options
  are consumed but not emitted; anonymous arguments (the profile and any roots)
  are ignored by the anonfun, so profile/root removal follows the parser's own
  rules. It sets no preference (read-only) and raises `Util.Fatal` on a parse
  error, so the caller refuses rather than silently dropping input.
- **Classification note (`cli_only` as evidence):** the session/process-role
  split uses `cli_only` (verified: `-ui`/`-server`/`-socket`/`-doc`/… are
  `cli_only`; `-path`/`-ignore`/… are not). Roots given on the command line are a
  separate case, refused for graphical launches by `CommandLineGraphicalLaunch`
  before extraction is reached. The extraction is validated against the engine's
  own parsing by the fresh-process harness (`docs/spikes/run-cli-session-firstload.sh`:
  order, repeats, aliases, whitespace, option-like values, and
  extraction→application with profile precedence + list accumulation).
- **Upstream relevance: LOW–MEDIUM.** `isCliOnly` is a small general accessor;
  the extractor is general engine code but motivated by the macUI session model.

---

## Contribution decomposition

Group by generality, which is the natural PR split:

1. **General engine (realistic upstream PRs):**
   - **0003 close-and-drain** — highest value; already has a `test.ml` test.
     Flag the `uicommon.ml` behavioral hunk explicitly.
   - **0004's `remote.ml`/`.mli` hook half** — additive, no-op defaults; could
     be proposed independently of the macUI wiring.
2. **macUI-bridge only (lower value, harder to land):** 0002, 0005, 0006, and
   0004's `uimacbridge.ml` wiring — relevant only if upstream evolves the
   largely-unmaintained native macUI.

## Caveats before investing

- **Authorship / contribution policy.** This repo is LLM-assisted and upstream
  has been wary of LLM-authored contributions. These patches are small, but they
  are downstream-authored and not merely `Callback` registrations: some change
  shared engine behavior (0003: `remote.ml` / `uicommon.ml`) or the macUI bridge
  ABI (0005). 0001 already landed — but confirm
  upstream's current stance and present human-reviewed, minimal diffs.
- **Licensing:** non-issue. Everything is GPLv3-or-later, same as upstream;
  derivative-artifact provenance is documented in `vendor/README.md` §6.

## Supporting material for reviewers

- `docs/ssh-reaper-design.md` — 0004.
- Issue #8 — 0003 rationale.
- `vendor/README.md` — provenance, toolchain, and the full patch-set description.
